#!/bin/bash
# delegate-route のテスト — 判定は決定的なので LLM も外部 API も呼ばない。
# 実ログを汚さないよう DELEGATE_LOG_DIR は必ず一時ディレクトリを指す。
set -u
BIN="$(cd "$(dirname "$0")" && pwd)/delegate-route"
PROD_MODELS_FILE="$(dirname "$BIN")/../models.json"
# 本番台帳を更新するときは、同じコミットでこの期待値も更新する。
PROD_TIER_LUNA="gpt-6-luna"
PROD_TIER_TERRA="gpt-6-sol"
PROD_TIER_SOL="gpt-6-sol"
PROD_TIER_ASTRA="gpt-6-astra"
PASS=0; FAIL=0

TMP="$(mktemp -d)"
export DELEGATE_LOG_DIR="$TMP/logs"
export DELEGATE_MODELS_FILE="$(cd "$(dirname "$0")" && pwd)/testdata/models.fixture.json"
MODELS_FILE="$DELEGATE_MODELS_FILE"
export DELEGATE_ROUTE_TODAY="2026-09-19"   # today-6 = 2026-09-13 / today-7 = 2026-09-12
mkdir -p "$DELEGATE_LOG_DIR"
# 既存の昇格ケースも、検証可能な Terra / Sol の失敗履歴を持つ。
printf '%s\n' \
  '{"run_id":"run_20260918-1","cause":"model","model":"gpt-5.6-terra","resumes":1}' \
  '{"run_id":"run_20260918-2","cause":"model","model":"gpt-5.6-sol","resumes":1}' \
  '{"run_id":"run_pivot","cause":"model","model":"gpt-5.6-terra","resumes":1}' \
  > "$DELEGATE_LOG_DIR/delegation-log.jsonl"

INSTR="$TMP/instr.md"
printf '%s\n' '実装指示書。対象は `src/a.ts` と `src/b.ts`。' > "$INSTR"
INSTR_MANY="$TMP/instr-many.md"
printf '%s\n' '対象は `src/a.ts` `src/b.ts` `src/c.ts` `src/d.ts` `src/e.ts` `src/f.ts`。' > "$INSTR_MANY"
INSTR_RISK="$TMP/instr-risk.md"
printf '%s\n' '認証まわりの変更。`src/auth.ts` を触る。' > "$INSTR_RISK"
INSTR_SPACE="$TMP/instruction with spaces.md"
printf '%s\n' '空白を含むパスの指示書。`src/a.ts` を触る。' > "$INSTR_SPACE"

run()  {
  OUT="$("$@" 2>"$TMP/stderr")"; CODE=$?
  printf '%s\n' "$OUT" >> "$TMP/route-output.txt"
  cat "$TMP/stderr" >> "$TMP/route-output.txt"
}
runE() {
  OUT="$("$@" 2>&1)"; CODE=$?
  printf '%s\n' "$OUT" >> "$TMP/route-output.txt"
}
ok()   { PASS=$((PASS+1)); }
ng()   { FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "  ---- output ----"; echo "$OUT" | sed 's/^/  /'; }
assert_exit()     { [ "$CODE" -eq "$2" ] && ok || ng "$1(exit $CODE ≠ $2)"; }
assert_contains() { case "$OUT" in *"$2"*) ok ;; *) ng "$1(期待文字列なし: $2)" ;; esac; }
assert_not_contains() { case "$OUT" in *"$2"*) ng "$1(禁止文字列あり: $2)" ;; *) ok ;; esac; }
jget() { printf '%s' "$OUT" | jq -r "$1" 2>/dev/null; }
assert_j() { V="$(jget "$2")"; [ "$V" = "$3" ] && ok || ng "$1($2 = $V / 期待 $3)"; }
assert_gather_fact_closes() {  # $1=軸 $2=期待値 $3=route_id。案内文から facts を無加工で渡す。
  local axis="$1" expected="$2" route_id="$3" facts
  facts="$(jget '.open[0].question | split("--human-facts \u0027")[1] | split("\u0027")[0]')"
  if [ -z "$facts" ] || [ "$facts" = "null" ]; then ng "gather $axis: 案内文から facts を抽出できる"; return; fi
  ok
  run "$BIN" --route-id "$route_id" --human-facts "$facts"
  assert_exit "gather $axis: 案内文の facts をそのまま受理" 0
  assert_j "gather $axis: 案内文の値は閉じる値" ".human_facts.$axis" "$expected"
  assert_j "gather $axis: 再判定で軸が open から消える" "[.open[] | select(.reason==\"$axis\")] | length" "0"
}

BASE='{"judge":"claude-agent:sonnet",
 "difficulty":{"score":2.1,"confidence":0.92},
 "regression":{"score":1.0,"confidence":0.95},
 "ambiguity":{"score":0.4,"confidence":0.9},
 "mechanical":0.05,"high_stakes":0.1,"splittable":0.85,
 "tier":{"choice":"terra","confidence":0.9},
 "scope_defined":0.95,"behavior_defined":0.9,"done_defined":0.9,"product_decision":0.05}'
sig() { printf '%s' "$BASE" | jq -c "${1:-.}"; }

# ── 本番台帳: fixture と分離して現在の台帳を検査 ──────────────────────
runE env DELEGATE_MODELS_FILE="$PROD_MODELS_FILE" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)"
assert_exit "本番台帳: delegate-route で判定できる" 0
OUT="$(jq -c . "$PROD_MODELS_FILE" 2>/dev/null)"; CODE=$?
assert_j "本番台帳: luna のモデル ID" '.tiers.luna.model' "$PROD_TIER_LUNA"
assert_j "本番台帳: terra のモデル ID" '.tiers.terra.model' "$PROD_TIER_TERRA"
assert_j "本番台帳: sol のモデル ID" '.tiers.sol.model' "$PROD_TIER_SOL"
assert_j "本番台帳: astra のモデル ID" '.tiers.astra.model' "$PROD_TIER_ASTRA"
assert_j "本番台帳: efforts_allowed は efforts_supported の部分集合" \
  '[. as $ledger | .tiers[] | . as $tier | $tier.efforts_allowed[] | . as $effort | ($ledger.models[$tier.model].efforts_supported | index($effort) != null)] | all' "true"
assert_j "本番台帳: default_effort は efforts_allowed に含まれる" \
  '[.tiers[] | .default_effort as $default | (.efforts_allowed | index($default) != null)] | all' "true"
assert_j "本番台帳: fallback は null または models に存在する" \
  '.models as $models | [$models[] | .fallback as $fallback | ($fallback == null or ($models | has($fallback)))] | all' "true"
PROD_RUN_DIR="$TMP/prod-ledger-repo"; mkdir -p "$PROD_RUN_DIR"; git -C "$PROD_RUN_DIR" init -q
runE env DELEGATE_MODELS_FILE="$PROD_MODELS_FILE" "$(dirname "$BIN")/delegate-run" --dry-run --force-astra --cli codex --mode write --model "$PROD_TIER_ASTRA" --effort high --cd "$PROD_RUN_DIR" --prompt-file "$INSTR"
assert_exit "本番台帳: delegate-run のスキーマ検証を通る" 0

# ── signals 検証 ───────────────────────────────────────
runE "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig 'del(.mechanical)')"
assert_exit "signals: 項目欠落は exit 2" 2
assert_contains "signals: 欠落項目を名指し" "mechanical: 必須項目が無い"

runE "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.difficulty.score = 5')"
assert_exit "signals: difficulty 範囲外は exit 2" 2
assert_contains "signals: 範囲外の項目を名指し" "difficulty.score: 範囲外"

runE "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.regression.score = 3.5')"
assert_exit "signals: regression 範囲外(0〜3)は exit 2" 2

runE "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.mechanical = 1.5')"
assert_exit "signals: noul 範囲外は exit 2" 2

runE "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.tier.choice = "gpt5"')"
assert_exit "signals: 不正な tier.choice は exit 2" 2
assert_contains "signals: tier.choice の許容値を表示" "tier.choice: luna|terra|sol|astra"

runE "$BIN" --instruction "$INSTR" --kind 実装 --signals 'not json'
assert_exit "signals: JSON でなければ exit 2" 2

runE "$BIN" --instruction "$INSTR" --kind 発明 --signals "$(sig)"
assert_exit "kind: 許容外は exit 2" 2

# decisions は任意。存在する場合だけ構造と選択肢を検証する。
DECISION='{"id":"overflow_behavior","kind":"spec","question":"超過時は?","options":[{"label":"切り捨てる","tradeoff":"超過分は失う"},{"label":"エラー","tradeoff":"呼び出し側で対処"}],"recommended":"エラー","why_unresolved":"指示なし"}'
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)"
assert_j "decisions: キーがない旧 signals を受理" '.gate' "confirmed"
for EXPR in \
  '.decisions = {}' \
  '.decisions = [{id:"bad-id",kind:"spec",question:"Q",options:[{label:"A",tradeoff:""},{label:"B",tradeoff:""}]}]' \
  '.decisions = [{id:"a",kind:"spec",question:"Q",options:[{label:"A",tradeoff:""},{label:"B",tradeoff:""}]},{id:"a",kind:"spec",question:"Q",options:[{label:"A",tradeoff:""},{label:"B",tradeoff:""}]}]' \
  '.decisions = [{id:"a",kind:"spec",question:"Q",options:[{label:"A",tradeoff:""}]}]' \
  '.decisions = [{id:"a",kind:"spec",question:"Q",options:[{label:"A",tradeoff:""},{label:"A",tradeoff:""}]}]' \
  '.decisions = [{id:"a",kind:"spec",question:"Q",options:[{label:"A",tradeoff:""},{label:"B",tradeoff:""}],recommended:"C"}]' \
  '.decisions = [{id:"a",kind:"other",question:"Q",options:[{label:"A",tradeoff:""},{label:"B",tradeoff:""}]}]' \
  '.decisions = [{id:"a",kind:"spec",question:"",options:[{label:"A",tradeoff:""},{label:"B",tradeoff:""}]}]' \
  '.decisions = [{id:"a",kind:"spec",question:"Q",options:[{label:"A",tradeoff:0},{label:"B",tradeoff:""}]}]'; do
  runE "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig "$EXPR")"
  assert_exit "decisions: 不正な構造を exit 2 にする($EXPR)" 2
  assert_contains "decisions: signals 検証エラーを出す" "signals 検証: decisions"
done
runE "$BIN" --instruction "$INSTR" --kind 実装 --human-facts '{"decision_answers":{"a":""}}'
assert_exit "decision_answers: 空文字列を拒否" 2
runE "$BIN" --instruction "$INSTR" --kind 実装 --human-facts '{"decision_answers":[]}'
assert_exit "decision_answers: オブジェクト以外を拒否" 2

runE "$BIN" --instruction "$TMP/no-such.md" --kind 実装 --signals "$(sig)"
assert_exit "指示書が無ければ exit 2" 2

# ── 推奨ティアの各分岐 ──────────────────────────────────
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)"
assert_exit "基本形: 判定できたら exit 0" 0
assert_j "基本形: terra/high" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-terra/high"
assert_j "基本形: gate confirmed" '.gate' "confirmed"
assert_j "基本形: 推奨と一致なら不一致の記録は null" '.tier_disagreement' "null"
assert_j "台帳: policy_version" '.policy_version' "0.28.0"
assert_j "台帳: ledger_version" '.ledger_version' "2026-09-22.1"
assert_j "台帳: available なら理由は null" '.unavailable_reason' "null"
assert_j "alternatives: terra/high → sol/high" '.alternatives | tojson' '[{"model":"gpt-5.6-sol","effort":"high"}]'
assert_j "基本形: features.scope_files" '.features.scope_files' "2"
EXPECTED_SHA="$(shasum -a 256 "$INSTR" | awk '{print $1}')"
assert_j "基本形: instruction_sha256 を記録" '.instruction_sha256' "$EXPECTED_SHA"

run "$BIN" --instruction "$INSTR_SPACE" --kind 実装 --signals "$(sig)"
assert_exit "指示書パスに空白: 判定成功" 0
assert_j "指示書パスに空白: 絶対パスを保持" '.instruction' "$INSTR_SPACE"
assert_j "指示書パスに空白: sha を記録" '.instruction_sha256' "$(shasum -a 256 "$INSTR_SPACE" | awk '{print $1}')"

run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.difficulty.score = 1.0')"
assert_j "difficulty<1.5: terra/medium" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-terra/medium"
assert_j "alternatives: terra/medium → terra/high" '.alternatives | tojson' '[{"model":"gpt-5.6-terra","effort":"high"}]'

run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.mechanical = 0.9')"
assert_j "mechanical>=0.8: luna/medium" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-luna/medium"
assert_j "alternatives: luna/medium → terra/medium" '.alternatives | tojson' '[{"model":"gpt-5.6-terra","effort":"medium"}]'

run "$BIN" --instruction "$INSTR_MANY" --kind 実装 --signals "$(sig '.mechanical = 0.9')"
assert_j "mechanical + 6ファイル: terra/medium" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-terra/medium"
assert_j "mechanical + 6ファイル: scope_files" '.features.scope_files' "6"

run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.difficulty.score = 2.6 | .tier.choice = "sol"')"
assert_j "difficulty>=2.5: sol/high" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"
assert_j "alternatives: sol/high → terra/high" '.alternatives | tojson' '[{"model":"gpt-5.6-terra","effort":"high"}]'

run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.regression.score = 2 | .tier.choice = "sol"')"
assert_j "regression>=2: sol/high" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"

run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.difficulty.score = 3.5 | .splittable = 0.9 | .tier.choice = "terra"')"
assert_j "difficulty>=3.2 かつ分割可: terra/high" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-terra/high"
assert_j "difficulty>=3.2 かつ分割可: 分割を勧告" '.advice' "split"
assert_j "difficulty>=3.2 かつ分割可: Astra 候補でない" '.astra_candidate' "false"

run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.difficulty.score = 3.5 | .splittable = 0.1 | .tier.choice = "astra"')"
assert_j "difficulty>=3.2 かつ分割不可: astra/high" '.recommend.model + "/" + .recommend.effort' "gpt-6-astra/high"
assert_j "difficulty>=3.2 かつ分割不可: Astra 候補" '.astra_candidate' "true"
assert_j "alternatives: astra/high → sol/high" '.alternatives | tojson' '[{"model":"gpt-5.6-sol","effort":"high"}]'

run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.high_stakes = 0.9 | .tier.choice = "astra"')"
assert_j "high_stakes>=0.8: astra/max" '.recommend.model + "/" + .recommend.effort' "gpt-6-astra/max"
assert_j "alternatives: astra/max → sol/high" '.alternatives | tojson' '[{"model":"gpt-5.6-sol","effort":"high"}]'

run "$BIN" --instruction "$INSTR" --kind 実装 --escalate-from run_20260918-1 --signals "$(sig '.tier.choice = "astra"')"
assert_j "escalate-from: astra/high" '.recommend.model + "/" + .recommend.effort' "gpt-6-astra/high"
assert_j "escalate-from: 記録される" '.escalate_from' "run_20260918-1"

run "$BIN" --instruction "$INSTR" --kind 調査 --escalate-from run_20260918-2 --signals "$(sig '.tier.choice = "astra"')"
assert_j "kind=調査 + escalate-from: sol/high" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"

# ── 固定ルール: 調査/相談/レビューでは Astra を使わない ──
for K in 調査 相談 レビュー; do
  run "$BIN" --instruction "$INSTR" --kind "$K" --signals "$(sig '.high_stakes = 0.9 | .tier.choice = "astra"')"
  assert_j "kind=$K: Astra を sol/high に落とす" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"
  assert_j "kind=$K: rules_applied" '.rules_applied | join(",")' "no_astra_for_kind"
  assert_j "kind=$K: astra_candidate を落とす" '.astra_candidate' "false"
  assert_j "kind=$K: astra_approval を聞かない" '[.open[] | select(.reason=="astra_approval")] | length' "0"
  assert_j "kind=$K: 固定ルール適用後の推奨と比較する" '.tier_disagreement.formula' "sol"
done
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.high_stakes = 0.9 | .tier.choice = "astra"')"
assert_j "kind=実装: Astra 候補は残る" '.astra_candidate' "true"

# ── Astra 承認: 予算内は自動 / human_facts は優先 ──
ASTRA_SIG="$(sig '.high_stakes = 0.9 | .tier.choice = "astra"')"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$ASTRA_SIG"
assert_j "astra: 予算内は confirmed" '.gate' "confirmed"
assert_j "astra: 承認質問なし" '.open | tojson' '[]'
assert_j "astra: 自動承認済み" '.astra_approved' "true"
assert_j "astra: 承認元は budget_auto" '.astra_approval_source' "budget_auto"
assert_j "astra: 予算集計は維持" '.budget.astra_count_7d' "0"
RID_ASTRA="$(jget '.route_id')"

run "$BIN" --route-id "$RID_ASTRA" --human-facts '{"astra_approved":true}'
assert_j "astra_approved=true: astra のまま" '.recommend.model + "/" + .recommend.effort' "gpt-6-astra/max"
assert_j "astra_approved=true: confirmed" '.gate' "confirmed"
assert_j "astra_approved=true: 出力に反映" '.astra_approved' "true"
assert_j "astra_approved=true: 承認元は human" '.astra_approval_source' "human"
assert_j "astra_approved=true: round が進む" '.round' "2"

run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$ASTRA_SIG"
RID_ASTRA2="$(jget '.route_id')"
run "$BIN" --route-id "$RID_ASTRA2" --human-facts '{"astra_approved":false}'
assert_j "astra_approved=false: sol/high に落とす" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"
assert_j "astra_approved=false: confirmed" '.gate' "confirmed"
assert_j "astra_approved=false: 承認元は human" '.astra_approval_source' "human"
assert_j "astra_approved=false: 再質問しない" '[.open[] | select(.reason=="astra_approval")] | length' "0"
assert_j "astra_approved=false: Sol への切替で不一致を作らない" '.tier_disagreement' "null"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.high_stakes = 0.9')" --human-facts '{"astra_approved":false}'
assert_j "astra_approved=false: 切替前の推奨を不一致に記録" '.tier_disagreement | tojson' '{"judge":"terra","judge_confidence":0.9,"formula":"astra","gap":2}'
assert_j "astra_approved=false: 実際の推奨は Sol" '.recommend.model' "gpt-5.6-sol"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)" --human-facts '{"astra_approved":true}'
assert_j "非 Astra 推奨: 従来どおり人間の承認 fact を記録" '.astra_approved' "true"
assert_j "非 Astra 推奨: 承認元は null" '.astra_approval_source' "null"

# budget_auto の記録を delegate-run の実際の Astra ゲートへ渡す。
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$ASTRA_SIG"
RID_AUTO="$(jget '.route_id')"
assert_j "astra: 実行用 route は budget_auto" '.astra_approval_source' "budget_auto"
runE "$(dirname "$BIN")/delegate-run" --dry-run --cli codex --mode write \
  --model gpt-6-astra --effort max --cd "$PROD_RUN_DIR" --prompt-file "$INSTR" --route-id "$RID_AUTO"
assert_exit "astra: budget_auto route で delegate-run ゲート通過" 0
assert_contains "astra: 実行コマンドに Astra を指定" "gpt-6-astra"
runE "$(dirname "$BIN")/delegate-run" --dry-run --cli codex --mode write \
  --model gpt-6-astra --effort high --cd "$PROD_RUN_DIR" --prompt-file "$INSTR" --route-id "$RID_AUTO"
assert_exit "astra: budget_auto route でも effort 不一致を拒否" 2

# ── 予算の境界 ────────────────────────────────────────
bud() {  # $1=ログ本文(printf 済み文字列) → OUT に --budget の JSON
  BDIR="$TMP/bud-$RANDOM"; mkdir -p "$BDIR"
  printf '%s' "$1" > "$BDIR/delegation-log.jsonl"
  run env DELEGATE_LOG_DIR="$BDIR" "$BIN" --budget
}
astra_rows() {  # $1=件数 $2=1件あたり tokens $3=date
  local i=1
  while [ "$i" -le "$1" ]; do
    printf '{"date":"%s","model":"gpt-6-astra","tokens":%s}\n' "$3" "$2"
    i=$((i+1))
  done
}

bud "$(astra_rows 1 79999999 2026-09-19)"
assert_j "予算: 79,999,999 は上限未満" '.over' "false"
assert_j "予算: トークン合計" '.astra_tokens_7d' "79999999"
bud "$(astra_rows 1 80000000 2026-09-19)"
assert_j "予算: 80,000,000 で over" '.over' "true"
bud "$(astra_rows 7 1 2026-09-19)"
assert_j "予算: 7 件は over でない" '.over' "false"
assert_j "予算: 件数" '.astra_count_7d' "7"
bud "$(astra_rows 8 1 2026-09-19)"
assert_j "予算: 8 件で over" '.over' "true"
bud "$(astra_rows 1 1000 2026-09-13)"
assert_j "予算: 今日-6日は窓に含む" '.astra_count_7d' "1"
bud "$(astra_rows 1 1000 2026-09-12)"
assert_j "予算: 今日-7日は窓に含まない" '.astra_count_7d' "0"
assert_j "予算: 窓外はトークンも 0" '.astra_tokens_7d' "0"
bud '{"date":"2026-09-19","model":"gpt-6-astra","tokens":null}
{"date":"2026-09-19","model":"gpt-6-astra","tokens":500}
{"date":"2026-09-19","model":"gpt-5.6-sol","tokens":999999999}
'
assert_j "予算: tokens null は 0 として数える" '.astra_tokens_7d' "500"
assert_j "予算: null 行の件数を出す" '.tokens_null' "1"
assert_j "予算: null 行も件数に含む" '.astra_count_7d' "2"
assert_j "予算: 他モデルは数えない" '.over' "false"
bud '{"date":"2026/09/19 extra","model":"  GPT-6-ASTRA  ","tokens":"125"}
'
assert_j "予算: model の大小文字と前後空白を正規化" '.astra_count_7d' "1"
assert_j "予算: date の slash・先頭10文字と数値文字列 tokens を許容" '.astra_tokens_7d' "125"
assert_j "予算: 正規化できる date は invalid でない" '.date_invalid' "0"
bud '{"date":"not-a-date","model":"gpt-6-astra","tokens":7}
{"date":"2026-09-12","model":"gpt-6-astra","tokens":1000}
'
assert_j "予算: 形式不正 date は窓内として数える" '.astra_count_7d' "1"
assert_j "予算: 形式不正 date の tokens を集計" '.astra_tokens_7d' "7"
assert_j "予算: date_invalid を計上" '.date_invalid' "1"
bud '{"date":"2026-09-19","model":"gpt-6-astra","tokens":"abc"}
{"date":"2026-09-19","model":"gpt-6-astra","tokens":{"value":10}}
'
assert_j "予算: 非数値 tokens は 0" '.astra_tokens_7d' "0"
assert_j "予算: 非数値文字列・オブジェクトを tokens_null に含める" '.tokens_null' "2"
run "$BIN" --budget
assert_exit "予算: ログが無くても成功" 0
assert_j "予算: ログが無ければ 0" '.astra_tokens_7d' "0"
assert_j "予算: 既定 cap" '.cap' "80000000"
assert_j "予算: 既定 count_cap" '.count_cap' "8"

# ── 予算超過時の Astra 候補の扱い ──
OVERDIR="$TMP/over"; mkdir -p "$OVERDIR"
astra_rows 8 10000000 2026-09-19 > "$OVERDIR/delegation-log.jsonl"
run env DELEGATE_LOG_DIR="$OVERDIR" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$ASTRA_SIG"
assert_j "予算超過: 推奨は sol/high" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"
assert_j "予算超過: Astra 候補のまま" '.astra_candidate' "true"
assert_j "予算超過: confirmed" '.gate' "confirmed"
assert_j "予算超過: 質問なし" '.open | tojson' '[]'
assert_j "予算超過: 承認なし" '.astra_approved' "false"
assert_j "予算超過: 承認元なし" '.astra_approval_source' "null"
assert_j "予算超過: 消費量を保持" '.budget.astra_count_7d' "8"
assert_j "予算超過: rules_applied" '.rules_applied | join(",")' "astra_budget_over"
assert_j "予算超過: Sol への切替で不一致を作らない" '.tier_disagreement' "null"
RID_OVER="$(jget '.route_id')"
run env DELEGATE_LOG_DIR="$OVERDIR" "$BIN" --route-id "$RID_OVER" --human-facts '{"astra_approved":true}'
assert_j "予算超過 + astra_approved=true: astra のまま" '.recommend.model + "/" + .recommend.effort' "gpt-6-astra/max"
assert_j "予算超過 + astra_approved=true: confirmed" '.gate' "confirmed"
assert_j "予算超過 + astra_approved=true: 承認元 human" '.astra_approval_source' "human"
run env DELEGATE_LOG_DIR="$OVERDIR" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.high_stakes = 0.9')"
assert_j "予算超過: 不一致の formula は切替前の Astra" '.tier_disagreement.formula' "astra"
assert_j "予算超過: 不一致を記録しても実際の推奨は Sol" '.recommend.model' "gpt-5.6-sol"

run env DELEGATE_MODELS_FILE="$PROD_MODELS_FILE" "$BIN" --instruction "$INSTR" --kind 実装 --human-facts '{"high_stakes":true}'
assert_j "fallback: 本番台帳で Astra 相当は Sol/xhigh" '.recommend.model + "/" + .recommend.effort' "gpt-6-sol/xhigh"
assert_j "fallback: 本番台帳でも自動承認なし" '.astra_approval_source' "null"

# ── 内容の確定条件 ────────────────────────────────────
for PAIR in "scope_defined|.scope_defined = 0.5" "behavior_defined|.behavior_defined = 0.5" \
            "done_defined|.done_defined = 0.5" "product_decision|.product_decision = 0.5" \
            "ambiguity|.ambiguity.score = 2"; do
  AX="${PAIR%%|*}"; EXPR="${PAIR#*|}"
  run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig "$EXPR")"
  EXPECT_GATE=gather_context; EXPECT_RESOLUTION=gather
  assert_j "内容軸 $AX: 未達で $EXPECT_GATE" '.gate' "$EXPECT_GATE"
  assert_j "内容軸 $AX: content 軸の質問が出る" "[.open[] | select(.reason==\"$AX\" and .axis==\"content\")] | length" "1"
  assert_j "内容軸 $AX: resolution" '.open[0].resolution' "$EXPECT_RESOLUTION"
done
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.scope_defined = 0.5 | .high_stakes = 0.5')"
assert_j "open の並び: content 軸が先頭" '.open[0].axis' "content"
assert_j "open の並び: model 軸は出ない" '[.open[].axis] | tojson' '["content"]'
assert_j "モデルと gather の混在: gather_context" '.gate' "gather_context"
assert_j "モデルと gather の混在: high_stakes は自動採用" '.auto_decided | tojson' '["high_stakes"]'

DECISIONS_SIG="$(printf '%s' "$BASE" | jq -c --argjson d "$DECISION" '.scope_defined = 0.5 | .behavior_defined = 0.5 | .done_defined = 0.5 | .product_decision = 0.5 | .ambiguity.score = 2 | .decisions = [$d, {id:"storage_policy",kind:"approach",question:"保存方式は?",options:[{label:"DB",tradeoff:"永続"},{label:"ファイル",tradeoff:"簡便"}],recommended:null}]')"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$DECISIONS_SIG"
assert_j "decisions: ask_human" '.gate' "ask_human"
assert_j "decisions: ask が先で signals 順" '[.open[].reason] | tojson' '["decision","decision","scope_defined","done_defined"]'
assert_j "decisions: decision_id を保持" '.open[0].decision_id' "overflow_behavior"
assert_j "decisions: kind を保持" '.open[1].kind' "approach"
assert_j "decisions: 質問文を保持" '.open[0].question' "超過時は?"
assert_j "decisions: 推奨選択肢を先頭に" '.open[0].options | tojson' '["エラー","切り捨てる"]'
assert_j "decisions: tradeoff も同じ順" '.open[0].option_details | tojson' '[{"label":"エラー","tradeoff":"呼び出し側で対処"},{"label":"切り捨てる","tradeoff":"超過分は失う"}]'
assert_j "decisions: recommended を保持" '.open[0].recommended' "エラー"
assert_j "decisions: 推奨なしは null" '.open[1].recommended' "null"
assert_j "decisions: decision は must_decide なし" '.open[0].must_decide' "false"
RID_DECISIONS="$(jget '.route_id')"
run "$BIN" --route-id "$RID_DECISIONS" --human-facts '{"decision_answers":{"overflow_behavior":"自由記述の案"}}'
assert_j "decision_answers: 回答済み id を除外" '[.open[].decision_id] | map(select(. != null)) | tojson' '["storage_policy"]'
assert_j "decision_answers: 回答は facts に保持" '.human_facts.decision_answers.overflow_behavior' "自由記述の案"
assert_j "decision_answers: confirmed_axes に混ぜない" '.confirmed_axes | index("decision_answers")' "null"
run "$BIN" --route-id "$RID_DECISIONS" --human-facts '{"decision_answers":{"storage_policy":"DB"}}'
assert_j "decision_answers: 全回答後は内容軸の gather" '[.open[].reason] | tojson' '["scope_defined","behavior_defined","done_defined","product_decision","ambiguity"]'
assert_j "decision_answers: 全回答後は gather_context" '.gate' "gather_context"
assert_j "decision_answers: 先行ラウンドの scope は must_decide" '.open[0].must_decide' "true"
assert_j "decision_answers: decision は streak の対象でない" '[.open[] | select(.reason=="decision")] | length' "0"

# 内容軸が確定域でも判定者の decision は必ず ask にする。推奨省略と null は同じ扱い。
DECISIONS_CONFIRMED_SIG="$(sig '.behavior_defined = 0.95 | .product_decision = 0.05 | .ambiguity.score = 0.2 | .decisions = [
  {id:"a",kind:"spec",question:"A?",options:[{label:"一案",tradeoff:"短い"},{label:"二案",tradeoff:"長い"}]},
  {id:"b",kind:"approach",question:"B?",options:[{label:"先行",tradeoff:"速い"},{label:"後行",tradeoff:"安全"}],recommended:null}]')"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$DECISIONS_CONFIRMED_SIG"
assert_j "decisions: 内容軸が確定域でも ask_human" '.gate' "ask_human"
assert_j "decisions: 内容軸が確定域でも両 decision を出す" '[.open[].decision_id] | tojson' '["a","b"]'
assert_j "decisions: recommended 省略と null は同じ" '[.open[].recommended] | tojson' '[null,null]'
assert_j "decisions: recommended 省略でも元の選択肢順" '.open[0].options | tojson' '["一案","二案"]'
assert_j "decisions: recommended null でも元の選択肢順" '.open[1].options | tojson' '["先行","後行"]'
RID_DECISIONS_CONFIRMED="$(jget '.route_id')"
run "$BIN" --route-id "$RID_DECISIONS_CONFIRMED" --human-facts '{"decision_answers":{"a":"x"}}'
assert_j "decision_answers: a 回答後は b だけ ask" '[.open[].decision_id] | tojson' '["b"]'
run "$BIN" --route-id "$RID_DECISIONS_CONFIRMED" --human-facts '{"decision_answers":{"b":"y"}}'
assert_j "decision_answers: 部分マージ後は両方再質問しない" '.open | tojson' '[]'
assert_j "decision_answers: 部分マージ後は confirmed" '.gate' "confirmed"
assert_j "decision_answers: a の回答を保持" '.human_facts.decision_answers.a' "x"
assert_j "decision_answers: b の回答を保持" '.human_facts.decision_answers.b' "y"

# ── モデルの確定条件 ──────────────────────────────────
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.high_stakes = 0.5')"
assert_j "モデル軸: high_stakes 中間値でも質問なし" '.open | tojson' '[]'
assert_j "モデル軸: high_stakes 中間値は自動採用" '.auto_decided | tojson' '["high_stakes"]'
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.mechanical = 0.5')"
assert_j "モデル軸: mechanical 中間値でも質問なし" '.open | tojson' '[]'
assert_j "モデル軸: mechanical 中間値は自動採用" '.auto_decided | tojson' '["mechanical"]'
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.high_stakes = 0.5 | .splittable = 0.5 | .mechanical = 0.5 | .regression.score = 2 | .regression.confidence = 0.5 | .difficulty.score = 3.5 | .difficulty.confidence = 0.5')"
assert_j "モデル軸: 複数未確定でも open は空" '.open | tojson' '[]'
assert_j "モデル軸: auto_decided は指定順で重複なし" '.auto_decided | tojson' '["high_stakes","splittable","mechanical","regression","difficulty"]'
assert_j "モデル軸: 複数未確定でも confirmed" '.gate' "confirmed"
# difficulty は常に判定者の score を決定式へ渡し、従来質問になった条件だけ自動採用として記録する
runE "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.difficulty.confidence = 0.5')"
assert_j "difficulty: 低確信 + しきい値近傍(2.1)でも質問しない" '[.open[] | select(.reason=="difficulty")] | length' "0"
assert_j "difficulty: 低確信 + しきい値近傍(2.1)は自動採用" '.auto_decided | tojson' '["difficulty"]'
assert_contains "difficulty: 自動採用を stderr に補足する" "自動採用: difficulty(score=2.1 / confidence=0.5)"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.difficulty.confidence = 0.95')"
assert_j "difficulty: 高確信(2.1)は自動採用しない" '.auto_decided | tojson' '[]'
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.difficulty.score = 0.5 | .difficulty.confidence = 0.5')"
assert_j "difficulty: 低確信でもしきい値から遠い(0.5)なら自動採用しない" '.auto_decided | tojson' '[]'
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.difficulty.score = 2.0 | .difficulty.confidence = 0.5')"
assert_j "difficulty: しきい値 ±0.5 の境界(2.0)も質問しない" '[.open[] | select(.reason=="difficulty")] | length' "0"
assert_j "difficulty: しきい値 ±0.5 の境界(2.0)は自動採用" '.auto_decided | tojson' '["difficulty"]'
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.difficulty.score = 2.1')"
assert_j "difficulty: 高確信なら近傍でも自動採用しない" '.auto_decided | tojson' '[]'

run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.regression.score = 1.8 | .regression.confidence = 0.5')"
assert_j "モデル軸: regression 低確信 + 2 近傍も質問なし" '.open | tojson' '[]'
assert_j "モデル軸: regression 低確信 + 2 近傍は自動採用" '.auto_decided | tojson' '["regression"]'
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.regression.confidence = 0.5')"
assert_j "モデル軸: regression 低確信でも 2 から遠ければ聞かない(score=1.0)" '[.open[] | select(.reason=="regression")] | length' "0"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.regression.score = 1.5 | .regression.confidence = 0.5')"
assert_j "モデル軸: regression の境界(1.5)は自動採用" '.auto_decided | tojson' '["regression"]'

# difficulty / regression 以外の規則で推奨が決まる場合は、低確信でも両軸を聞かない
PIVOT='.difficulty.score = 2.5 | .difficulty.confidence = 0.65 | .regression.score = 2 | .regression.confidence = 0.75'
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.difficulty.score = 2.1 | .difficulty.confidence = 0.5 | .high_stakes = 0.9 | .tier.choice = "astra"')"
assert_j "difficulty: high_stakes=0.9 では低確信・近傍でも自動採用しない" '.auto_decided | tojson' '[]'
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig "$PIVOT | .high_stakes = 0.85 | .tier.choice = \"terra\"")"
assert_j "モデル軸: high_stakes 決定時は difficulty を聞かない" '[.open[] | select(.reason=="difficulty")] | length' "0"
assert_j "モデル軸: high_stakes>=0.8 では difficulty を自動採用しない" '.auto_decided | tojson' '[]'
assert_j "モデル軸: high_stakes 決定時は regression を聞かない" '[.open[] | select(.reason=="regression")] | length' "0"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig "$PIVOT | .mechanical = 0.9")"
assert_j "モデル軸: mechanical 決定時は difficulty を聞かない" '[.open[] | select(.reason=="difficulty")] | length' "0"
assert_j "モデル軸: mechanical 決定時は regression を聞かない" '[.open[] | select(.reason=="regression")] | length' "0"
run "$BIN" --instruction "$INSTR" --kind 実装 --escalate-from run_pivot --signals "$(sig "$PIVOT | .tier.choice = \"astra\"")"
assert_j "モデル軸: escalate 決定時は difficulty を聞かない" '[.open[] | select(.reason=="difficulty")] | length' "0"
assert_j "モデル軸: escalate 決定時は regression を聞かない" '[.open[] | select(.reason=="regression")] | length' "0"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig "$PIVOT | .tier.choice = \"sol\"")"
assert_j "モデル軸: score 決定時も difficulty を質問しない" '[.open[] | select(.reason=="difficulty")] | length' "0"
assert_j "モデル軸: score 決定時は regression と difficulty を自動採用する" '.auto_decided | tojson' '["regression","difficulty"]'
assert_j "モデル軸: score 決定時も regression を聞かない" '[.open[] | select(.reason=="regression")] | length' "0"

# 判定者と決定式が割れたら材料軸だけを確認し、確定済みなら決定式を採用する
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.tier.confidence = 0.5')"
assert_j "不一致なし: 低確信でも質問しない" '.open | tojson' '[]'
assert_j "不一致なし: 低確信でも記録は null" '.tier_disagreement' "null"
assert_j "不一致なし: 低確信でも confirmed" '.gate' "confirmed"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.tier.choice = "sol"')"
assert_j "不一致: 1段違い + 高確信でも記録する" '.tier_disagreement | tojson' '{"judge":"sol","judge_confidence":0.9,"formula":"terra","gap":1}'
assert_j "不一致: 材料確定済みなら高確信でも confirmed" '.gate' "confirmed"
DISAGREE_SIG="$(sig '.tier.choice = "sol" | .tier.confidence = 0.55')"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$DISAGREE_SIG"
assert_j "不一致: 低確信でも材料確定済みなら confirmed" '.gate' "confirmed"
assert_j "不一致: 材料確定済みなら open は空" '.open | tojson' '[]'
assert_j "不一致: 決定式の Terra を採用" '.recommend.model' "gpt-5.6-terra"
assert_j "不一致: 判定者の候補" '.tier_disagreement.judge' "sol"
assert_j "不一致: 判定者の確信度" '.tier_disagreement.judge_confidence' "0.55"
assert_j "不一致: 決定式の推奨" '.tier_disagreement.formula' "terra"
assert_j "不一致: 段差" '.tier_disagreement.gap' "1"
RID_DISAGREE="$(jget '.route_id')"
OUT="$(cat "$TMP/stderr")"
DISAGREE_NOTE='判定者の候補 sol と決定式の推奨 terra が異なるが、材料軸は確定済みのため決定式を採用(tier_disagreement に記録)'
assert_contains "不一致: 採用理由を stderr に補足" "$DISAGREE_NOTE"
OUT="$(printf '%s\n' "$OUT" | grep -cF "$DISAGREE_NOTE")"
[ "$OUT" = "1" ] && ok || ng "不一致: stderr の補足は 1 行だけ"
OUT="$(jq -c --arg rid "$RID_DISAGREE" 'select(.route_id == $rid)' "$DELEGATE_LOG_DIR/route-decisions.jsonl")"
assert_j "不一致: 記録行にも候補・確信度・推奨・段差を保存" '.tier_disagreement | tojson' '{"judge":"sol","judge_confidence":0.55,"formula":"terra","gap":1}'
run "$BIN" --show "$RID_DISAGREE"
assert_j "不一致: --show でも保存した値を返す" '.tier_disagreement | tojson' '{"judge":"sol","judge_confidence":0.55,"formula":"terra","gap":1}'
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.tier.choice = "astra"')"
assert_j "不一致: 2段違いでも材料確定済みなら confirmed" '.gate' "confirmed"
assert_j "不一致: 2段違いでも質問しない" '.open | tojson' '[]'
assert_j "不一致: 2段違いも記録する" '.tier_disagreement.gap' "2"

run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(printf '%s' "$DISAGREE_SIG" | jq -c '.regression.confidence = 0.5')"
assert_j "不一致: しきい値から遠い低確信 regression も質問なし" '.open | tojson' '[]'
assert_j "不一致: regression は自動採用" '.auto_decided | tojson' '["regression"]'
assert_j "不一致: 材料軸のまま confirmed" '.gate' "confirmed"
RID_REG="$(jget '.route_id')"
OUT="$(cat "$TMP/stderr")"
assert_contains "不一致: モデル軸は司令塔が採用と補足" "材料軸は確定済み"
run "$BIN" --route-id "$RID_REG" --human-facts '{"regression":2}'
assert_j "不一致: 人間の regression 回答で Sol へ変わる" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"
assert_j "不一致: 回答で一致すれば null に戻る" '.tier_disagreement' "null"
assert_j "不一致: 回答済みなら confirmed" '.gate' "confirmed"
for CONF in 0.899 0.9; do
  run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig ".tier.choice = \"sol\" | .regression.confidence = $CONF")"
  case "$CONF" in 0.899) EXPECT_OPEN=1 ;; *) EXPECT_OPEN=0 ;; esac
  assert_j "不一致: regression の自動採用境界($CONF)" '[.auto_decided[] | select(.=="regression")] | length' "$EXPECT_OPEN"
  assert_j "不一致: 確信度に関係なく質問なし($CONF)" '.open | tojson' '[]'
done

# Astra 承認だけで未確定の材料を確定扱いにしない。回答済みの材料は再質問しない。
for APPROVAL in false true; do
  run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.tier.choice = "astra" | .regression.confidence = 0.5')" \
    --human-facts "{\"astra_approved\":$APPROVAL}"
  assert_j "不一致: astra_approved=$APPROVAL でも regression を自動採用" '.auto_decided | tojson' '["regression"]'
  assert_j "不一致: astra_approved=$APPROVAL でも質問なし" '.open | tojson' '[]'
done
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.tier.choice = "astra" | .regression.confidence = 0.5')" \
  --human-facts '{"high_stakes":false,"regression":1}'
assert_j "不一致: regression 回答済みなら質問しない" '.open | tojson' '[]'
assert_j "不一致: 回答済みでも不一致自体は記録する" '.tier_disagreement.formula' "terra"
assert_j "不一致: 材料回答済みなら confirmed" '.gate' "confirmed"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.tier.choice = "astra" | .regression.confidence = 0.5')" \
  --human-facts '{"high_stakes":false,"difficulty":2.1}'
assert_j "不一致: 別の材料への回答でも regression を自動採用" '.auto_decided | tojson' '["regression"]'
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.tier.choice = "sol" | .high_stakes = 0.5 | .mechanical = 0.5')"
assert_j "不一致: high_stakes/mechanical は質問せず自動採用" '.auto_decided | tojson' '["high_stakes","mechanical"]'
assert_j "不一致: モデル軸の open は空" '.open | tojson' '[]'
RID_MATERIAL="$(jget '.route_id')"
run "$BIN" --route-id "$RID_MATERIAL" --human-facts '{"high_stakes":false,"mechanical":true}'
assert_j "不一致: mechanical 回答を決定式へ反映" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-luna/medium"
assert_j "不一致: high_stakes/mechanical 回答済みなら confirmed" '.gate' "confirmed"
assert_j "不一致: 回答後の推奨との段差を記録" '.tier_disagreement.gap' "2"

# 一致時の splittable 条件は従来どおり。不一致時だけ difficulty >= 2.5 へ広げる。
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.splittable = 0.5')"
assert_j "splittable: difficulty<3.2 なら除外" '[.open[] | select(.reason=="splittable")] | length' "0"
assert_j "splittable: 除外時は confirmed" '.gate' "confirmed"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.difficulty.score = 3.5 | .splittable = 0.5 | .tier.choice = "terra"')"
assert_j "splittable: difficulty>=3.2 なら自動採用" '.auto_decided | tojson' '["splittable"]'
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.difficulty.score = 2.6 | .splittable = 0.5')"
assert_j "splittable: 判定者 Terra と決定式 Sol が不一致" '.tier_disagreement.formula' "sol"
assert_j "splittable: 不一致なら difficulty=2.6 でも自動採用" '.auto_decided | tojson' '["splittable"]'
RID_SPLIT="$(jget '.route_id')"
run "$BIN" --route-id "$RID_SPLIT" --human-facts '{"splittable":true}'
assert_j "splittable: 回答済みなら不一致のままでも confirmed" '.gate' "confirmed"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.difficulty.score = 2.6 | .splittable = 0.5 | .tier.choice = "sol"')"
assert_j "splittable: 一致なら difficulty=2.6 では聞かない" '.open | tojson' '[]'
assert_j "splittable: 一致なら不一致の記録は null" '.tier_disagreement' "null"
for SCORE in 2.49 2.5; do
  run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig ".difficulty.score = $SCORE | .splittable = 0.5 | .tier.choice = \"astra\"")"
  case "$SCORE" in 2.49) EXPECT_OPEN=0 ;; *) EXPECT_OPEN=1 ;; esac
  assert_j "splittable: 不一致時の difficulty 境界($SCORE)" '[.auto_decided[] | select(.=="splittable")] | length' "$EXPECT_OPEN"
  assert_j "splittable: 不一致時も質問なし($SCORE)" '.open | tojson' '[]'
done
for SPLIT in 0.2 0.21 0.79 0.8; do
  run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig ".difficulty.score = 2.6 | .splittable = $SPLIT")"
  case "$SPLIT" in 0.2|0.8) EXPECT_OPEN=0 ;; *) EXPECT_OPEN=1 ;; esac
  assert_j "splittable: 不一致でも自動採用の境界は同じ($SPLIT)" '[.auto_decided[] | select(.=="splittable")] | length' "$EXPECT_OPEN"
done

# ── human_facts: 優先・再質問しない・未知キー拒否 ──
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.high_stakes = 0.5')"
RID_HF="$(jget '.route_id')"
assert_j "human_facts 前: high_stakes は自動採用" '.auto_decided | tojson' '["high_stakes"]'
run "$BIN" --route-id "$RID_HF" --human-facts '{"high_stakes":true}'
assert_exit "human_facts: 再判定に成功" 0
assert_j "human_facts: 信号を 1.0 に上書きし推奨が astra 候補へ" '.astra_candidate' "true"
assert_j "human_facts: 答えた軸は再質問しない" '[.open[] | select(.reason=="high_stakes")] | length' "0"
assert_j "human_facts: confirmed_axes に載る" '[.confirmed_axes[] | select(. == "high_stakes")] | length' "1"
assert_j "human_facts: 指示書と kind を引き継ぐ" '.kind' "実装"

runE "$BIN" --route-id "$RID_HF" --human-facts '{"unknown_axis":true}'
assert_exit "human_facts: 未知キーは exit 2" 2
assert_contains "human_facts: 未知キーを名指し" "未知のキー: unknown_axis"
runE "$BIN" --route-id "$RID_HF" --human-facts '{"tier":"gpt5"}'
assert_exit "human_facts: 不正な tier は exit 2" 2
runE "$BIN" --route-id "$RID_HF" --human-facts '{"mechanical":0.5}'
assert_exit "human_facts: noul は true/false のみ" 2
runE "$BIN" --route-id "$RID_HF" --human-facts '{"difficulty":4.1}'
assert_exit "human_facts: difficulty 範囲外は exit 2" 2
assert_contains "human_facts: difficulty 範囲外を表示" "difficulty: 範囲外"
runE "$BIN" --route-id "$RID_HF" --human-facts '{"regression":-1}'
assert_exit "human_facts: regression 範囲外は exit 2" 2
runE "$BIN" --route-id "$RID_HF" --human-facts '{"ambiguity":3.1}'
assert_exit "human_facts: ambiguity 範囲外は exit 2" 2
runE "$BIN" --route-id rt_nosuch --human-facts '{}'
assert_exit "human_facts: 未知 route_id は exit 2" 2

# human_facts の difficulty は score を上書きして決定式に使い、自動採用にはしない
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.difficulty.score = 1.0')"
RID_HF_DIFF="$(jget '.route_id')"
assert_j "human_facts difficulty 前: score=1 で terra/medium" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-terra/medium"
run "$BIN" --route-id "$RID_HF_DIFF" --human-facts '{"difficulty":3}'
assert_j "human_facts difficulty: score を 3 に上書き" '.human_facts.difficulty' "3"
assert_j "human_facts difficulty: 決定式へ効かせる" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"
assert_j "human_facts difficulty: 自動採用しない" '.auto_decided | tojson' '[]'

# 人間の tier 指定は決定式より優先し、モデル軸を確定扱いにする
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.difficulty.confidence = 0.4 | .tier.confidence = 0.4')"
RID_TIER="$(jget '.route_id')"
run "$BIN" --route-id "$RID_TIER" --human-facts '{"tier":"sol"}'
assert_j "tier 指定: 推奨を固定" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"
assert_j "tier 指定: モデル軸は確定扱い" '.gate' "confirmed"
assert_j "tier 指定: difficulty を自動採用しない" '.auto_decided | tojson' '[]'
assert_j "tier 指定: 不一致の記録は null" '.tier_disagreement' "null"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)"
RID_TIER2="$(jget '.route_id')"
run "$BIN" --route-id "$RID_TIER2" --human-facts '{"tier":"astra"}'
assert_j "tier 指定 astra: high_stakes<0.8 なら high" '.recommend.effort' "high"
assert_j "tier 指定 astra: 予算内は自動承認" '.astra_approval_source' "budget_auto"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.high_stakes = 0.9 | .tier.choice = "astra"')"
RID_TIER3="$(jget '.route_id')"
run "$BIN" --route-id "$RID_TIER3" --human-facts '{"tier":"astra","astra_approved":true}'
assert_j "tier 指定 astra: high_stakes>=0.8 なら max" '.recommend.effort' "max"

# delegated_to_commander は確定扱い(記録のみ)
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.mechanical = 0.5')"
RID_DC="$(jget '.route_id')"
run "$BIN" --route-id "$RID_DC" --human-facts '{"delegated_to_commander":["mechanical"]}'
assert_j "delegated_to_commander: 確定扱い" '[.open[] | select(.reason=="mechanical")] | length' "0"
assert_j "delegated_to_commander: confirmed_axes に載る" '[.confirmed_axes[] | select(. == "mechanical")] | length' "1"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.difficulty.confidence = 0.5')"
RID_DC_DIFF="$(jget '.route_id')"
run "$BIN" --route-id "$RID_DC_DIFF" --human-facts '{"delegated_to_commander":["difficulty"]}'
assert_j "delegated_to_commander: difficulty を自動採用しない" '.auto_decided | tojson' '[]'
assert_j "delegated_to_commander: difficulty を confirmed_axes に載せる" '[.confirmed_axes[] | select(. == "difficulty")] | length' "1"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.scope_defined = 0.5 | .behavior_defined = 0.5 | .done_defined = 0.5 | .product_decision = 0.5 | .ambiguity.score = 2')" \
  --human-facts '{"delegated_to_commander":["scope_defined","behavior_defined","done_defined","product_decision","ambiguity"]}'
assert_j "delegated_to_commander: 内容の5軸を受理" '.gate' "confirmed"
assert_j "delegated_to_commander: 5軸を記録" '.confirmed_axes | tojson' '["ambiguity","behavior_defined","done_defined","product_decision","scope_defined"]'
runE "$BIN" --route-id "$RID_DC" --human-facts '{"delegated_to_commander":["astra_approval"]}'
assert_exit "delegated_to_commander: astra_approval は拒否" 2
assert_contains "delegated_to_commander: astra_approval を名指し" "astra_approval"
runE "$BIN" --route-id "$RID_DC" --human-facts '{"delegated_to_commander":["unknown_axis"]}'
assert_exit "delegated_to_commander: 未知の軸は拒否" 2

# ── instruction_changed は signals の再指定を必須にする ──
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.behavior_defined = 0.3')"
RID_IC="$(jget '.route_id')"
runE "$BIN" --route-id "$RID_IC" --human-facts '{"instruction_changed":true}'
assert_exit "instruction_changed: signals 無しは exit 2" 2
assert_contains "instruction_changed: 理由表示" "--signals の再指定が必須"
run "$BIN" --route-id "$RID_IC" --human-facts '{"instruction_changed":true}' --signals "$(sig)"
assert_exit "instruction_changed: signals ありなら成功" 0
assert_j "instruction_changed: 新 signals で内容軸を再評価" '.gate' "confirmed"

# 指示書の実内容が変わった場合は明示フラグを必須にし、Astra 承認を失効させる
INSTR_CHANGE="$TMP/instr-change.md"
printf '%s\n' '初版。`src/a.ts` を変更する。' > "$INSTR_CHANGE"
run "$BIN" --instruction "$INSTR_CHANGE" --kind 実装 --signals "$ASTRA_SIG"
RID_CHANGE="$(jget '.route_id')"
run "$BIN" --route-id "$RID_CHANGE" --human-facts '{"astra_approved":true}'
assert_j "指示書改稿前: Astra 承認済み" '.astra_approved' "true"
printf '%s\n' '改稿版。`src/a.ts` と `src/b.ts` を変更する。' > "$INSTR_CHANGE"
runE "$BIN" --route-id "$RID_CHANGE" --signals "$ASTRA_SIG"
assert_exit "指示書改稿: instruction_changed 無しは exit 2" 2
assert_contains "指示書改稿: 再判定方法を表示" "instruction_changed:true"
run "$BIN" --route-id "$RID_CHANGE" --signals "$ASTRA_SIG" --human-facts '{"instruction_changed":true}'
assert_exit "指示書改稿: instruction_changed ありなら成功" 0
assert_j "指示書改稿: 累積 astra_approved を除去" '.human_facts | has("astra_approved")' "false"
assert_j "指示書改稿: 新しいラウンドで予算内なら自動承認" '.astra_approval_source' "budget_auto"
assert_j "指示書改稿: 旧承認は引き継がないが新承認は有効" '.astra_approved' "true"
assert_j "指示書改稿: 新しい sha を記録" '.instruction_sha256' "$(shasum -a 256 "$INSTR_CHANGE" | awk '{print $1}')"

INSTR_CHANGE_FALSE="$TMP/instr-change-false.md"
printf '%s\n' '初版。`src/a.ts` を変更する。' > "$INSTR_CHANGE_FALSE"
run "$BIN" --instruction "$INSTR_CHANGE_FALSE" --kind 実装 --signals "$ASTRA_SIG"
RID_CHANGE_FALSE="$(jget '.route_id')"
run "$BIN" --route-id "$RID_CHANGE_FALSE" --human-facts '{"astra_approved":true}'
printf '%s\n' '改稿版。`src/a.ts` と `src/b.ts` を変更する。' > "$INSTR_CHANGE_FALSE"
run "$BIN" --route-id "$RID_CHANGE_FALSE" --signals "$ASTRA_SIG" \
  --human-facts '{"instruction_changed":true,"astra_approved":false}'
assert_j "指示書改稿 + 新しい承認false: astra_declined" '.rules_applied | join(",")' "astra_declined"
assert_j "指示書改稿 + 新しい承認false: sol/high" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"
assert_j "指示書改稿 + 新しい承認false: confirmed" '.gate' "confirmed"
assert_j "指示書改稿 + 新しい承認false: 今回factsを保持" '.human_facts.astra_approved' "false"

INSTR_CHANGE_TRUE="$TMP/instr-change-true.md"
printf '%s\n' '初版。`src/a.ts` を変更する。' > "$INSTR_CHANGE_TRUE"
run "$BIN" --instruction "$INSTR_CHANGE_TRUE" --kind 実装 --signals "$ASTRA_SIG"
RID_CHANGE_TRUE="$(jget '.route_id')"
run "$BIN" --route-id "$RID_CHANGE_TRUE" --human-facts '{"astra_approved":false}'
printf '%s\n' '改稿版。`src/a.ts` と `src/b.ts` を変更する。' > "$INSTR_CHANGE_TRUE"
run "$BIN" --route-id "$RID_CHANGE_TRUE" --signals "$ASTRA_SIG" \
  --human-facts '{"instruction_changed":true,"astra_approved":true}'
assert_j "指示書改稿 + 新しい承認true: astra_approved" '.rules_applied | join(",")' "astra_approved"
assert_j "指示書改稿 + 新しい承認true: astra/max" '.recommend.model + "/" + .recommend.effort' "gpt-6-astra/max"
assert_j "指示書改稿 + 新しい承認true: confirmed" '.gate' "confirmed"
assert_j "指示書改稿 + 新しい承認true: 今回factsを保持" '.human_facts.astra_approved' "true"

# ── 収束保証: 同じ軸が 3 ラウンド目も未確定なら must_decide ──
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.behavior_defined = 0.3')"
RID_MD="$(jget '.route_id')"
assert_j "must_decide: round1 は立たない" '[.open[] | select(.reason=="behavior_defined")][0].must_decide' "false"
run "$BIN" --route-id "$RID_MD" --human-facts '{"mechanical":false}'
assert_j "must_decide: round2 も立たない" '[.open[] | select(.reason=="behavior_defined")][0].must_decide' "false"
run "$BIN" --route-id "$RID_MD" --human-facts '{"splittable":true}'
assert_j "must_decide: round3 で立つ" '[.open[] | select(.reason=="behavior_defined")][0].must_decide' "true"
assert_j "must_decide: 3 回目も gather" '.open[0].resolution' "gather"
assert_j "must_decide: 3 回目も gather_context" '.gate' "gather_context"
assert_j "must_decide: round 3" '.round' "3"

# ── series: モデル軸だけ 24 時間保持する ──
run "$BIN" --instruction "$INSTR" --kind 実装 --series-key S7 --signals "$(sig '.scope_defined = 0.5')"
RID_S="$(jget '.route_id')"
assert_j "series: series_key を記録" '.series_key' "S7"
run "$BIN" --route-id "$RID_S" \
  --human-facts '{"tier":"sol","astra_approved":true,"scope_defined":true,"series_apply":true}'
assert_exit "series: 保持の書き込みに成功" 0
[ -s "$DELEGATE_LOG_DIR/route-series.json" ] && ok || ng "series: route-series.json が作られる"
OUT="$(cat "$DELEGATE_LOG_DIR/route-series.json")"
assert_j "series: モデル軸(tier)を保持" '.S7.facts.tier' "sol"
assert_j "series: astra_approved は保持しない" '.S7.facts | has("astra_approved")' "false"
assert_j "series: 内容軸は保持しない" '.S7.facts | has("scope_defined")' "false"

run "$BIN" --instruction "$INSTR" --kind 実装 --series-key S11 --signals "$(printf '%s' "$BASE" | jq -c --argjson d "$DECISION" '.behavior_defined = 0.5 | .decisions = [$d]')" --human-facts '{"decision_answers":{"overflow_behavior":"エラー"},"series_apply":true}'
assert_j "series: decision_answers は route の facts に保持" '.human_facts.decision_answers.overflow_behavior' "エラー"
OUT="$(cat "$DELEGATE_LOG_DIR/route-series.json")"
assert_j "series: decision_answers は series に保持しない" '.S11.facts | has("decision_answers")' "false"

run "$BIN" --instruction "$INSTR" --kind 実装 --series-key S7 --signals "$(sig '.difficulty.confidence = 0.3')"
assert_j "series: 初回ラウンドから tier を適用" '.human_facts.tier' "sol"
assert_j "series: 適用後の推奨" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"
assert_j "series: 内容軸は毎回判定する" '.human_facts | has("scope_defined")' "false"
run "$BIN" --instruction "$INSTR" --kind 実装 --series-key S7 --signals "$(sig '.high_stakes = 0.9 | .tier.choice = "astra"')"
assert_j "series: astra_approved は適用しない" '.human_facts | has("astra_approved")' "false"

run "$BIN" --instruction "$INSTR" --kind 実装 --series-key S9 --signals "$(sig)"
assert_j "series: 別キーには適用しない" '.human_facts | has("tier")' "false"

jq '.S7.ts_epoch = 1' "$DELEGATE_LOG_DIR/route-series.json" > "$DELEGATE_LOG_DIR/route-series.tmp" \
  && mv "$DELEGATE_LOG_DIR/route-series.tmp" "$DELEGATE_LOG_DIR/route-series.json"
run "$BIN" --instruction "$INSTR" --kind 実装 --series-key S7 --signals "$(sig)"
assert_j "series: 24 時間で失効する" '.human_facts | has("tier")' "false"

# ── fallback: 質問なし。材料があれば擬似信号で決定式 ──
run "$BIN" --instruction "$INSTR" --kind 実装
assert_exit "fallback: signals 無しでも exit 0" 0
assert_j "fallback: gate" '.gate' "fallback"
assert_j "fallback: facts なしは terra/medium" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-terra/medium"
assert_j "fallback: 人間への質問ゼロ" '.open | tojson' '[]'
assert_j "fallback: signals は null" '.signals' "null"
assert_j "fallback: 不一致の記録は null" '.tier_disagreement' "null"
assert_j "fallback: difficulty を自動採用しない" '.auto_decided | tojson' '[]'
RID_FB="$(jget '.route_id')"
run "$BIN" --route-id "$RID_FB" --human-facts '{"mechanical":false}'
assert_j "fallback: 1 軸だけでも決定式" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-terra/medium"
assert_j "fallback: 1 軸でも gate は fallback" '.gate' "fallback"
assert_j "fallback: 1 軸の回答を記録" '.confirmed_axes | tojson' '["mechanical"]'
assert_j "fallback: 回答しても質問ゼロ" '.open | tojson' '[]'
run "$BIN" --route-id "$RID_FB" --human-facts '{"regression":2}'
assert_j "fallback: 一部 facts の regression=2 で sol/high" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"
assert_j "fallback: regression だけでも fallback" '.gate' "fallback"
run "$BIN" --route-id "$RID_FB" --human-facts '{"mechanical":true}'
assert_j "fallback: mechanical=true なら luna/medium" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-luna/medium"
assert_j "fallback: mechanical=true でも fallback" '.gate' "fallback"
run "$BIN" --route-id "$RID_FB" --human-facts '{"mechanical":false,"high_stakes":true}'
assert_j "fallback: high_stakes=true は Astra 候補" '.astra_candidate' "true"
assert_j "fallback: 承認なしは Sol/high(fixture の既定 effort)" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"
assert_j "fallback: Astra の質問もゼロ" '.open | tojson' '[]'
assert_j "fallback: 自動承認しない" '.astra_approved' "false"
assert_j "fallback: 承認元なし" '.astra_approval_source' "null"
assert_j "fallback: Astra 相当も gate は fallback" '.gate' "fallback"
run env ASTRA_WEEKLY_COUNT_CAP=0 "$BIN" --route-id "$RID_FB" --allow-unattended
assert_j "fallback: 予算超過も Sol/high" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"
assert_j "fallback: 予算超過も質問ゼロ" '.open | tojson' '[]'
assert_j "fallback: unattended でも fallback" '.gate' "fallback"
run "$BIN" --route-id "$RID_FB" --human-facts '{"astra_approved":true}'
assert_j "fallback: 人間が承認すれば Astra/max" '.recommend.model + "/" + .recommend.effort' "gpt-6-astra/max"
assert_j "fallback: 人間の承認元" '.astra_approval_source' "human"
assert_j "fallback: 人間の承認後も gate は fallback" '.gate' "fallback"
run "$BIN" --route-id "$RID_FB" --human-facts '{"astra_approved":false}'
assert_j "fallback: 人間が拒否すれば Sol/high" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"
assert_j "fallback: 人間の拒否後も gate は fallback" '.gate' "fallback"
run "$BIN" --instruction "$INSTR" --kind 実装 --human-facts '{"tier":"terra"}'
assert_j "fallback: tier 指定でも gate は fallback" '.gate' "fallback"
assert_j "fallback: tier 指定が推奨になる" '.recommend.model' "gpt-5.6-terra"
assert_j "fallback: tier 指定でも質問ゼロ" '.open | tojson' '[]'
run "$BIN" --instruction "$INSTR" --kind 実装 --human-facts '{"tier":"astra"}'
assert_j "fallback: 明示 tier astra でも自動承認しない" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"
assert_j "fallback: 明示 tier astra も gate は fallback" '.gate' "fallback"
run "$BIN" --instruction "$INSTR" --kind 実装 --human-facts '{"mechanical":false,"high_stakes":false,"regression":1}'
assert_j "fallback: 3 軸指定でも fallback" '.gate' "fallback"
assert_j "fallback: 3 軸なら terra/medium" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-terra/medium"
run "$BIN" --instruction "$INSTR_MANY" --kind 実装 --human-facts '{"mechanical":true}'
assert_j "fallback: mechanical + 6 ファイルの既存規則" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-terra/medium"
run "$BIN" --instruction "$INSTR" --kind 調査 --human-facts '{"high_stakes":true}'
assert_j "fallback: 調査では高リスクでも sol/high" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"
assert_j "fallback: 調査でも gate は fallback" '.gate' "fallback"
run "$BIN" --instruction "$INSTR_RISK" --kind 実装
assert_j "fallback: facts なしなら高リスク語で sol/high" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"
assert_j "fallback: risk_terms を出す" '.features.risk_terms | join(",")' "認証,auth"
RID_FB_RISK="$(jget '.route_id')"
run "$BIN" --route-id "$RID_FB_RISK" --human-facts '{"mechanical":true}'
assert_j "fallback: facts があれば静的推奨より決定式" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-luna/medium"
assert_j "fallback: 擬似信号は保存しない" '.signals' "null"

# ── allow-unattended ─────────────────────────────────
run "$BIN" --instruction "$INSTR" --kind 実装 --allow-unattended --signals "$(sig '.difficulty.confidence = 0.5')"
assert_j "unattended: difficulty のみなら confirmed" '.gate' "confirmed"
assert_j "unattended: 質問が無いため印を立てない" '.unattended' "false"
run "$BIN" --instruction "$INSTR" --kind 実装 --allow-unattended --signals "$(sig '.scope_defined = 0.5')"
assert_j "unattended: gather の内容軸が残るなら不可" '.gate' "gather_context"
assert_j "unattended: 不可なら印も立たない" '.unattended' "false"
run "$BIN" --instruction "$INSTR" --kind 実装 --allow-unattended --signals "$ASTRA_SIG"
assert_j "unattended: 予算内 Astra は自動承認" '.gate' "confirmed"
run "$BIN" --instruction "$INSTR" --kind 実装 --allow-unattended
assert_j "unattended: 信号が無ければ fallback のまま" '.gate' "fallback"
assert_j "unattended: fallback は印も立たない" '.unattended' "false"
assert_j "unattended: 信号が無ければ質問ゼロ" '.open | tojson' '[]'
run "$BIN" --instruction "$INSTR" --kind 実装 --allow-unattended --human-facts '{"mechanical":false}'
assert_j "unattended: 一部回答済みでも信号が無ければ fallback" '.gate' "fallback"
run "$BIN" --instruction "$INSTR" --kind 実装 --allow-unattended \
  --human-facts '{"mechanical":false,"high_stakes":false,"regression":1}'
assert_j "unattended: 3 軸回答済みでも fallback" '.gate' "fallback"
assert_j "unattended: 回答による確定には印を立てない" '.unattended' "false"
run env ASTRA_WEEKLY_COUNT_CAP=0 "$BIN" --instruction "$INSTR" --kind 実装 --allow-unattended --human-facts '{"tier":"astra"}'
assert_j "unattended: 信号なしの明示 Astra 指定でも承認を省略しない" '.gate' "fallback"
run "$BIN" --instruction "$INSTR" --kind 実装 --allow-unattended --signals "$(sig '.behavior_defined = 0.4 | .decisions = [{id:"ui_choice",kind:"spec",question:"表示は?",options:[{label:"A",tradeoff:"速い"},{label:"B",tradeoff:"詳しい"}],recommended:"A"}]')"
assert_j "unattended: decision の ask は残る" '.gate' "ask_human"
assert_j "unattended: ask で印を立てない" '.unattended' "false"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.difficulty.confidence = 0.5')"
assert_j "unattended: 指定しなくても difficulty のみなら confirmed" '.gate' "confirmed"

# ── 回帰シナリオ: 実走スモークで出た 3 ラウンドの収束 ──
SC='{"judge":"claude-agent:sonnet",
 "difficulty":{"score":2.8,"confidence":0.6},
 "regression":{"score":1.3,"confidence":0.55},
 "ambiguity":{"score":1.4,"confidence":0.55},
 "mechanical":0.05,"high_stakes":0.75,"splittable":0.65,
 "tier":{"choice":"sol","confidence":0.55},
 "scope_defined":0.95,"behavior_defined":0.82,"done_defined":0.9,"product_decision":0.2}'
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(printf '%s' "$SC" | jq -c .)"
assert_exit "回帰: round1 は判定できる" 0
assert_j "回帰: round1 は ambiguity の gather のみ" '[.open[].reason] | join(",")' "ambiguity"
assert_j "回帰: round1 の high_stakes と difficulty は自動採用" '.auto_decided | tojson' '["high_stakes","difficulty"]'
assert_j "回帰: round1 は regression を聞かない(score=1.3)" '[.open[] | select(.reason=="regression")] | length' "0"
assert_j "回帰: round1 は推奨 sol と一致" '.tier_disagreement' "null"
assert_j "回帰: round1 の推奨" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"
RID_SC="$(jget '.route_id')"

run "$BIN" --route-id "$RID_SC" --human-facts '{"high_stakes":true,"ambiguity":1,"difficulty":3}'
assert_j "回帰: round2 の推奨は astra/max" '.recommend.model + "/" + .recommend.effort' "gpt-6-astra/max"
assert_j "回帰: round2 の open は空" '.open | tojson' '[]'
assert_j "回帰: round2 は予算内 Astra で confirmed" '.gate' "confirmed"
assert_j "回帰: round2 の splittable は自動採用" '.auto_decided | tojson' '["splittable"]'
assert_j "回帰: round2 の不一致を記録" '.tier_disagreement.formula' "astra"

run "$BIN" --route-id "$RID_SC" --human-facts '{"astra_approved":false,"splittable":true}'
assert_j "回帰: round3 は confirmed" '.gate' "confirmed"
assert_j "回帰: round3 の推奨は sol/high" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"
assert_j "回帰: round3 の open は空" '.open | length' "0"
assert_j "回帰: round3 も承認前の不一致を保持" '.tier_disagreement.formula' "astra"

# ── 台帳の検証・差し替えと決定性 ──────────────────────
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)" --human-facts '{"scope_defined":true}'
DETERMINISTIC="$(jget 'del(.ts, .route_id) | tojson')"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)" --human-facts '{"scope_defined":true}'
assert_j "決定性: 同じ signals / facts は ts・route_id 以外同一" 'del(.ts, .route_id) | tojson' "$DETERMINISTIC"

runE env DELEGATE_MODELS_FILE=/nonexistent "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)"
assert_exit "台帳: 不存在は exit 2" 2
assert_contains "台帳: 不存在の理由" "モデル台帳が存在しない: /nonexistent"
BAD_LEDGER="$TMP/bad-models.json"
for INVALID_JSON in '{' '' 'null' '[]' '{} {}'; do
  printf '%s\n' "$INVALID_JSON" > "$BAD_LEDGER"
  runE env DELEGATE_MODELS_FILE="$BAD_LEDGER" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)"
  assert_exit "台帳: JSON オブジェクトでない入力を拒否($INVALID_JSON)" 2
  assert_contains "台帳: JSON 不正の理由" "JSON オブジェクトとして解析できない"
done
for TIER in luna terra sol astra; do
  jq --arg tier "$TIER" 'del(.tiers[$tier])' "$MODELS_FILE" > "$BAD_LEDGER"
  runE env DELEGATE_MODELS_FILE="$BAD_LEDGER" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)"
  assert_exit "台帳: $TIER 欠落を拒否" 2
  assert_contains "台帳: 欠落 tier の理由" "モデル台帳が不正: tiers.$TIER: 必須項目が無い"
done
jq '.tiers.terra.model = "missing-model"' "$MODELS_FILE" > "$BAD_LEDGER"
runE env DELEGATE_MODELS_FILE="$BAD_LEDGER" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)"
assert_exit "台帳: models に無い tier.model を拒否" 2
assert_contains "台帳: model 参照不正の理由" "モデル台帳が不正: tiers.terra.model: models に無い: missing-model"

# 配列の型・空配列・要素の型をロード時に検査し、文字列の部分一致を許さない。
for FIELD_PATH in '["tiers","terra","efforts_allowed"]' '["models","gpt-5.6-terra","efforts_supported"]'; do
  FIELD="$(printf '%s' "$FIELD_PATH" | jq -r 'join(".")')"
  for INVALID_VALUE in '"lowmediumhigh"' '[]' '["medium",1]' 'null' '{}'; do
    jq --argjson path "$FIELD_PATH" --argjson value "$INVALID_VALUE" 'setpath($path; $value)' "$MODELS_FILE" > "$BAD_LEDGER"
    runE env DELEGATE_MODELS_FILE="$BAD_LEDGER" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)"
    assert_exit "台帳: $FIELD の不正な配列を拒否($INVALID_VALUE)" 2
    assert_contains "台帳: 配列の違反項目と理由" "モデル台帳が不正: $FIELD: 1 件以上の文字列配列が必要"
  done
done
for FIELD_PATH in '["ledger_version"]' '["tiers","sol","default_effort"]' '["models","gpt-5.5","status"]'; do
  FIELD="$(printf '%s' "$FIELD_PATH" | jq -r 'join(".")')"
  for INVALID_VALUE in 'null' '1' '[]'; do
    jq --argjson path "$FIELD_PATH" --argjson value "$INVALID_VALUE" 'setpath($path; $value)' "$MODELS_FILE" > "$BAD_LEDGER"
    runE env DELEGATE_MODELS_FILE="$BAD_LEDGER" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)"
    assert_exit "台帳: $FIELD の文字列以外を拒否($INVALID_VALUE)" 2
    assert_contains "台帳: 文字列の違反項目と理由" "モデル台帳が不正: $FIELD: 文字列が必要"
  done
done
for DEFAULT_EFFORT in low med; do
  jq --arg effort "$DEFAULT_EFFORT" '.tiers.terra.default_effort = $effort' "$MODELS_FILE" > "$BAD_LEDGER"
  runE env DELEGATE_MODELS_FILE="$BAD_LEDGER" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)"
  assert_exit "台帳: allowed に無い default_effort を拒否($DEFAULT_EFFORT)" 2
  assert_contains "台帳: default_effort の包含関係の理由" "モデル台帳が不正: tiers.terra.default_effort: efforts_allowed に含まれていない"
done
jq '.models["gpt-5.5"] = false' "$MODELS_FILE" > "$BAD_LEDGER"
runE env DELEGATE_MODELS_FILE="$BAD_LEDGER" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)"
assert_exit "台帳: ティアから参照されない model も検証する" 2
assert_contains "台帳: model 自体の型も項目名つきで拒否" "モデル台帳が不正: models.gpt-5.5: オブジェクトが必要"
jq '.tiers.extra = {model:"gpt-5.6-terra",efforts_allowed:"medium",default_effort:"medium"}' "$MODELS_FILE" > "$BAD_LEDGER"
runE env DELEGATE_MODELS_FILE="$BAD_LEDGER" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)"
assert_exit "台帳: 必須 4 ティア以外も検証する" 2
assert_contains "台帳: 追加ティアの違反項目" "モデル台帳が不正: tiers.extra.efforts_allowed: 1 件以上の文字列配列が必要"
jq '.ledger_version = false | .models["gpt-5.6-terra"].efforts_supported = "lowmediumhigh"' "$MODELS_FILE" > "$BAD_LEDGER"
runE env DELEGATE_MODELS_FILE="$BAD_LEDGER" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)"
assert_exit "台帳: 複数違反も exit 2" 2
[ "$OUT" = "delegate-route: ERROR: モデル台帳が不正: ledger_version: 文字列が必要" ] && ok || ng "台帳: 最初の違反だけを 1 行で表示する"

CUSTOM_LEDGER="$TMP/custom models.json"
jq '.tiers.terra.model = "gpt-5.5" | .ledger_version = "test-ledger"' "$MODELS_FILE" > "$CUSTOM_LEDGER"
run env DELEGATE_MODELS_FILE="$CUSTOM_LEDGER" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)"
assert_exit "台帳: 空白を含むパスで差し替え" 0
assert_j "台帳: 推奨モデルを台帳から解決" '.recommend.model' "gpt-5.5"
assert_j "台帳: 差し替えた ledger_version" '.ledger_version' "test-ledger"
run env DELEGATE_MODELS_FILE="$CUSTOM_LEDGER" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.difficulty.score = 2.6')"
assert_j "台帳: alternatives のモデルも台帳から解決" '.alternatives | tojson' '[{"model":"gpt-5.5","effort":"high"}]'

jq '.tiers.terra.efforts_allowed = ["medium"]' "$MODELS_FILE" > "$CUSTOM_LEDGER"
run env DELEGATE_MODELS_FILE="$CUSTOM_LEDGER" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)"
assert_j "effort: allowed に無い high を medium に丸める" '.recommend.effort' "medium"
assert_j "effort: 丸めを記録" '.rules_applied | index("effort_clamped") != null' "true"
run env DELEGATE_MODELS_FILE="$CUSTOM_LEDGER" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)" --human-facts '{"tier":"terra"}'
assert_j "effort: 人間の tier 指定も丸める" '.recommend.effort' "medium"
run "$BIN" --instruction "$INSTR_MANY" --kind 実装 --signals "$(sig '.mechanical = 0.9')" --human-facts '{"tier":"terra"}'
assert_j "effort: 人間の Terra 指定は機械作業でも difficulty を反映" '.recommend.effort' "high"
jq '.tiers.astra.efforts_allowed = ["high"]' "$MODELS_FILE" > "$CUSTOM_LEDGER"
run env DELEGATE_MODELS_FILE="$CUSTOM_LEDGER" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$ASTRA_SIG"
assert_j "effort: Astra の max も既定値へ丸める" '.recommend.effort' "high"
assert_j "effort: Astra の丸めを記録" '.rules_applied | index("effort_clamped") != null' "true"
jq '.tiers.terra.default_effort = "low" | .tiers.terra.efforts_allowed = ["low"]' "$MODELS_FILE" > "$CUSTOM_LEDGER"
run env DELEGATE_MODELS_FILE="$CUSTOM_LEDGER" "$BIN" --instruction "$INSTR" --kind 実装
assert_j "effort: 信号なしは台帳の default_effort" '.recommend.effort' "low"
assert_j "alternatives: 定義外の組は空配列" '.alternatives | tojson' '[]'

# ── unavailable は最終推奨に対し、すべての open / gate より優先 ──
UNAVAILABLE_LEDGER="$TMP/unavailable-models.json"
jq '.models["gpt-5.6-terra"].status = "unavailable"' "$MODELS_FILE" > "$UNAVAILABLE_LEDGER"
run env DELEGATE_MODELS_FILE="$UNAVAILABLE_LEDGER" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)"
assert_exit "unavailable: 判定自体は exit 0" 0
assert_j "unavailable: open が無くても confirmed にしない" '.gate' "unavailable"
assert_j "unavailable: 推奨はそのまま" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-terra/high"
assert_j "unavailable: open は空" '.open | tojson' '[]'
assert_j "unavailable: 理由と案内" '.unavailable_reason' "推奨ティア terra のモデル gpt-5.6-terra は台帳で status=unavailable(verified_at 2026-09-22)。models.json を更新するか、--human-facts '{\"tier\":\"…\"}' で別のティアを指定する"
assert_j "unavailable: alternatives は算出する" '.alternatives | tojson' '[{"model":"gpt-5.6-sol","effort":"high"}]'
for EXPR in '.scope_defined = 0.5' '.behavior_defined = 0.5'; do
  run env DELEGATE_MODELS_FILE="$UNAVAILABLE_LEDGER" "$BIN" --instruction "$INSTR" --kind 実装 --allow-unattended --signals "$(sig "$EXPR")"
  assert_j "unavailable: 内容未確定でも最優先($EXPR)" '.gate' "unavailable"
  assert_j "unavailable: 内容の open も出さない" '.open | tojson' '[]'
  assert_j "unavailable: unattended で確定させない" '.unattended' "false"
done
run env DELEGATE_MODELS_FILE="$UNAVAILABLE_LEDGER" "$BIN" --instruction "$INSTR" --kind 実装 --allow-unattended --signals "$(sig '.high_stakes = 0.5')"
assert_j "unavailable: モデル軸のみでも unattended 不可" '.gate' "unavailable"
assert_j "unavailable: モデル軸のみでも unattended=false" '.unattended' "false"
run env DELEGATE_MODELS_FILE="$UNAVAILABLE_LEDGER" "$BIN" --instruction "$INSTR" --kind 実装
assert_j "unavailable: fallback より優先" '.gate' "unavailable"
run env DELEGATE_MODELS_FILE="$UNAVAILABLE_LEDGER" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)" --human-facts '{"tier":"terra"}'
assert_j "unavailable: 人間の tier 指定を黙って変更しない" '.gate' "unavailable"
assert_j "unavailable: 人間の Terra 指定を保持" '.recommend.model' "gpt-5.6-terra"
run env DELEGATE_MODELS_FILE="$UNAVAILABLE_LEDGER" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)" --human-facts '{"tier":"sol"}'
assert_j "unavailable: 人間が available の別 tier を指定できる" '.gate' "confirmed"
assert_j "unavailable: 別 tier なら理由は null" '.unavailable_reason' "null"

jq '.models["gpt-6-astra"].status = "retired"' "$MODELS_FILE" > "$UNAVAILABLE_LEDGER"
run env DELEGATE_MODELS_FILE="$UNAVAILABLE_LEDGER" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$ASTRA_SIG" --human-facts '{"astra_approved":true}'
assert_j "unavailable: 承認しても unavailable" '.gate' "unavailable"
assert_contains "unavailable: available 以外の status も拒否" 'status=retired'
run env DELEGATE_MODELS_FILE="$UNAVAILABLE_LEDGER" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$ASTRA_SIG" --human-facts '{"astra_approved":false}'
assert_j "unavailable: 承認拒否後の Sol を検査" '.gate' "confirmed"
run env DELEGATE_MODELS_FILE="$UNAVAILABLE_LEDGER" "$BIN" --instruction "$INSTR" --kind 調査 --signals "$ASTRA_SIG"
assert_j "unavailable: kind の Astra 禁止後の Sol を検査" '.gate' "confirmed"
run env DELEGATE_MODELS_FILE="$UNAVAILABLE_LEDGER" ASTRA_WEEKLY_COUNT_CAP=0 "$BIN" --instruction "$INSTR" --kind 実装 --signals "$ASTRA_SIG"
assert_j "unavailable: 予算超過後の Sol を検査" '.gate' "confirmed"
assert_j "unavailable: 予算超過後の推奨は Sol" '.recommend.model' "gpt-5.6-sol"

# ── gather の質問・選択肢・3 ラウンド目での収束 ──
for AX in scope_defined done_defined; do
  run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig ".$AX = 0.5")"
  RID_GATHER="$(jget '.route_id')"
  assert_j "gather $AX: 初回は gather_context" '.gate' "gather_context"
  assert_j "gather $AX: resolution" '.open[0].resolution' "gather"
  assert_j "gather $AX: 選択肢は再判定だけ" '.open[0].options | tojson' '["指示書に追記して再判定する"]'
  assert_j "gather $AX: 初回は must_decide=false" '.open[0].must_decide' "false"
  case "$AX" in
    scope_defined) EXPECT_QUESTION='変更対象(ファイル・モジュール)と触らない範囲が指示書で特定されていません。リポジトリと `git status` から対象・除外範囲を補って指示書に書き、判定し直してください。' ;;
    done_defined) EXPECT_QUESTION='完了条件と検証コマンド(ベースライン込み)が指示書にありません。ベースラインを計測して指示書に書き、判定し直してください。' ;;
  esac
  assert_j "gather $AX: 司令塔向けの質問文" '.open[0].question' "$EXPECT_QUESTION"
  run "$BIN" --route-id "$RID_GATHER"
  assert_j "gather $AX: 2 回目も gather_context" '.gate' "gather_context"
  run "$BIN" --route-id "$RID_GATHER"
  assert_j "gather $AX: 3 回目は must_decide=true" '.open[0].must_decide' "true"
  assert_j "gather $AX: 3 回目も resolution=gather" '.open[0].resolution' "gather"
  assert_j "gather $AX: 3 回目も gather_context" '.gate' "gather_context"
  assert_j "gather $AX: 選択肢は再判定だけ" '.open[0].options | tojson' '["指示書に追記して再判定する"]'
  assert_gather_fact_closes "$AX" "true" "$RID_GATHER"
done
for AX in behavior_defined product_decision ambiguity; do
  case "$AX" in
    behavior_defined) EXPR='.behavior_defined = 0.5'; EXPECTED_FACT=true ;;
    product_decision) EXPR='.product_decision = 0.5'; EXPECTED_FACT=false ;;
    ambiguity) EXPR='.ambiguity.score = 2'; EXPECTED_FACT=0 ;;
  esac
  run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig "$EXPR")"
  RID_GATHER="$(jget '.route_id')"
  assert_j "gather $AX: decisions 空なら gather_context" '.gate' "gather_context"
  run "$BIN" --route-id "$RID_GATHER"
  run "$BIN" --route-id "$RID_GATHER"
  assert_j "gather $AX: 3 ラウンド目は must_decide" '.open[0].must_decide' "true"
  assert_j "gather $AX: 3 ラウンド目も gather" '.open[0].resolution' "gather"
  assert_gather_fact_closes "$AX" "$EXPECTED_FACT" "$RID_GATHER"
done
runE "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.scope_defined = 0.5')"
assert_contains "gather: stderr に resolution を含める" '[content/scope_defined/gather]'

# 旧 route-decisions 行の model / astra_approval 理由を streak で安全に読む。
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.scope_defined = 0.5')"
LEGACY_BASE="$OUT"
LEGACY_DIR="$TMP/legacy"; mkdir -p "$LEGACY_DIR"
printf '%s\n' "$LEGACY_BASE" | jq -c '.route_id = "rt_legacy_mix" | .round = 1 | .open = [{reason:"high_stakes"},{reason:"astra_approval"},{reason:"scope_defined"}] | del(.astra_approval_source)' > "$LEGACY_DIR/route-decisions.jsonl"
printf '%s\n' "$LEGACY_BASE" | jq -c '.route_id = "rt_legacy_mix" | .round = 2 | .open = [{reason:"high_stakes"},{reason:"astra_approval"},{reason:"scope_defined"}] | del(.astra_approval_source)' >> "$LEGACY_DIR/route-decisions.jsonl"
run env DELEGATE_LOG_DIR="$LEGACY_DIR" "$BIN" --show rt_legacy_mix
assert_exit "旧ログ: --show が旧形式行を返す" 0
assert_j "旧ログ: --show は最新の旧ラウンド" '.round' "2"
run env DELEGATE_LOG_DIR="$LEGACY_DIR" "$BIN" --route-id rt_legacy_mix
assert_exit "旧ログ: 再判定が動く" 0
assert_j "旧ログ: scope の streak が維持される" '.open[0].must_decide' "true"
assert_j "旧ログ: model と承認理由は open に戻らない" '[.open[].reason] | tojson' '["scope_defined"]'
assert_j "旧ログ: gather_context のまま" '.gate' "gather_context"

# ── 昇格元: 全一致行の cause / model と合計失敗回数を検証 ──
ESC_DIR="$TMP/escalation"; mkdir -p "$ESC_DIR"
printf '%s\n' \
  '壊れた委任ログ行' 'null' '[]' \
  '{"run_id":"run_resumed","cause":"model","model":"gpt-5.6-terra","resumes":1}' \
  '{"run_id":"run_once","cause":"model","model":"gpt-5.6-terra","resumes":0}' \
  '{"run_id":"run_a","cause":"model","model":"gpt-5.6-terra","resumes":0}' \
  '{"run_id":"run_b","cause":"model","model":"gpt-5.6-sol","resumes":0}' \
  '{"run_id":"run_astra","cause":"model","model":"gpt-6-astra","resumes":1}' \
  '{"run_id":"run_twice","cause":"model","model":"gpt-5.6-terra"}' \
  '{"run_id":"run_twice","cause":"model","model":"gpt-5.6-sol","resumes":null}' \
  > "$ESC_DIR/delegation-log.jsonl"
run env DELEGATE_LOG_DIR="$ESC_DIR" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.tier.choice = "astra"')" --escalate-from run_resumed
assert_exit "昇格: Terra + resumes:1 は通る" 0
assert_j "昇格: 検証済みを記録" '.rules_applied | index("escalation_verified") != null' "true"
assert_j "昇格: Astra 候補化" '.astra_candidate' "true"
assert_j "昇格: astra/high を推奨" '.recommend.model + "/" + .recommend.effort' "gpt-6-astra/high"
RID_ESC="$(jget '.route_id')"
run env DELEGATE_LOG_DIR="$ESC_DIR" "$BIN" --route-id "$RID_ESC" --human-facts '{"astra_approved":true}'
assert_exit "昇格: 再判定でも有効なログなら通る" 0
assert_j "昇格: 再判定で escalate_from を引き継ぐ" '.escalate_from' "run_resumed"
assert_j "昇格: 再判定も検証済みを記録" '.rules_applied | index("escalation_verified") != null' "true"
printf '%s\n' '{"run_id":"run_resumed","cause":"instruction","model":"gpt-5.6-terra","resumes":0}' >> "$ESC_DIR/delegation-log.jsonl"
runE env DELEGATE_LOG_DIR="$ESC_DIR" "$BIN" --route-id "$RID_ESC"
assert_exit "昇格: 再判定で全一致行を検証し拒否" 2
assert_contains "昇格: 再判定も原因分類へ戻す" "原因分類へ戻る"

runE env DELEGATE_LOG_DIR="$ESC_DIR" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)" --escalate-from run_once
assert_exit "昇格: resumes:0 の 1 行だけでは拒否" 2
assert_contains "昇格: 失敗 2 回が必要" "2 回失敗"
assert_contains "昇格: 現在の回数" "現在 1 回"
run env DELEGATE_LOG_DIR="$ESC_DIR" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.tier.choice = "astra"')" --escalate-from run_a,run_b
assert_exit "昇格: 2 つの run_id を合計" 0
assert_j "昇格: カンマ区切りをそのまま記録" '.escalate_from' "run_a,run_b"
assert_j "昇格: 2 run でも Astra 候補化" '.astra_candidate' "true"
RID_ESC_MULTI="$(jget '.route_id')"
run env DELEGATE_LOG_DIR="$ESC_DIR" "$BIN" --route-id "$RID_ESC_MULTI"
assert_exit "昇格: 複数 run_id の再判定" 0
assert_j "昇格: 複数 run_id を引き継ぐ" '.escalate_from' "run_a,run_b"
for IDS in "run_a, run_b" " run_a, , run_b, " $'\trun_a,\nrun_b\t'; do
  run env DELEGATE_LOG_DIR="$ESC_DIR" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.tier.choice = "astra"')" --escalate-from "$IDS"
  assert_exit "昇格: run_id の前後の空白と空要素を除去する($IDS)" 0
  assert_j "昇格: 空白除去後の 2 run で Astra 候補化" '.astra_candidate' "true"
  RID_ESC_SPACED="$(jget '.route_id')"
  run env DELEGATE_LOG_DIR="$ESC_DIR" "$BIN" --route-id "$RID_ESC_SPACED"
  assert_exit "昇格: 空白入り run_id の再判定も通る" 0
done
for IDS in " , " "" "   " ",,," $'\t,\n'; do
  runE env DELEGATE_LOG_DIR="$ESC_DIR" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)" --escalate-from "$IDS"
  assert_exit "昇格: 全要素が空なら exit 2" 2
  assert_contains "昇格: 空の run_id の理由" "escalate-from に run_id が無い"
done
run env DELEGATE_LOG_DIR="$ESC_DIR" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)" --escalate-from run_twice
assert_exit "昇格: 同じ run_id の全行を合計(null・未指定 resumes は 0)" 0
runE env DELEGATE_LOG_DIR="$ESC_DIR" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)" --escalate-from run_once,run_once
assert_exit "昇格: 引数の run_id 重複で回数を水増ししない" 2
runE env DELEGATE_LOG_DIR="$ESC_DIR" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)" --escalate-from "run_once, run_once"
assert_exit "昇格: 空白除去後の重複でも回数を水増ししない" 2
assert_contains "昇格: 空白除去後も失敗回数は 1 回" "現在 1 回"

for CAUSE in instruction spec_change environment tooling product_decision unknown none other; do
  jq -cn --arg cause "$CAUSE" '{run_id:"run_bad",cause:$cause,model:"gpt-5.6-terra",resumes:1}' > "$ESC_DIR/delegation-log.jsonl"
  runE env DELEGATE_LOG_DIR="$ESC_DIR" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)" --escalate-from run_bad
  assert_exit "昇格: cause=$CAUSE は拒否" 2
  assert_contains "昇格: cause=$CAUSE を明記" "cause=$CAUSE"
  assert_contains "昇格: cause=$CAUSE は原因分類へ戻す" "原因分類へ戻る"
done
runE env DELEGATE_LOG_DIR="$ESC_DIR" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)" --escalate-from run_missing
assert_exit "昇格: 不明な run_id は拒否" 2
assert_contains "昇格: 不明な run_id を明記" "escalate-from の run_id が委任ログに無い: run_missing"
printf '%s\n' \
  '{"run_id":"run_astra","cause":"model","model":"gpt-5.6-terra","resumes":1}' \
  '{"run_id":"run_astra","cause":"model","model":"gpt-6-astra","resumes":1}' \
  > "$ESC_DIR/delegation-log.jsonl"
runE env DELEGATE_LOG_DIR="$ESC_DIR" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)" --escalate-from run_astra
assert_exit "昇格: 一致行に Astra が含まれれば拒否" 2
assert_contains "昇格: Terra / Sol 限定の理由" "Terra / Sol の委任に限る: run_astra は model=gpt-6-astra"
jq '.tiers.terra.model = "gpt-5.5"' "$MODELS_FILE" > "$CUSTOM_LEDGER"
printf '%s\n' '{"run_id":"run_custom","cause":"model","model":"gpt-5.5","resumes":1}' > "$ESC_DIR/delegation-log.jsonl"
run env DELEGATE_MODELS_FILE="$CUSTOM_LEDGER" DELEGATE_LOG_DIR="$ESC_DIR" "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)" --escalate-from run_custom
assert_exit "昇格: Terra / Sol の model は台帳から解決" 0

# ── --show と記録行 ──────────────────────────────────
ROBUST_DIR="$TMP/route-jsonl-robust"; mkdir -p "$ROBUST_DIR"
ROBUST_RID="rt_jsonl_robust"
ROBUST_SHA="$(shasum -a 256 "$INSTR" | awk '{print $1}')"
ROBUST_SIG="$(sig)"
ROBUST_ROW1="$(jq -cn --arg rid "$ROBUST_RID" --arg instruction "$INSTR" --arg sha "$ROBUST_SHA" \
  --argjson signals "$ROBUST_SIG" \
  '{route_id:$rid,round:1,kind:"実装",instruction:$instruction,instruction_sha256:$sha,
    series_key:null,escalate_from:null,signals:$signals,human_facts:{},open:[]}')"
ROBUST_ROW2="$(jq -cn --arg rid "$ROBUST_RID" --arg instruction "$INSTR" --arg sha "$ROBUST_SHA" \
  --argjson signals "$ROBUST_SIG" \
  '{route_id:$rid,round:2,kind:"実装",instruction:$instruction,instruction_sha256:$sha,
    series_key:null,escalate_from:null,signals:$signals,human_facts:{},open:[]}')"
printf '%s\n' '壊れた先頭行' "$ROBUST_ROW1" '壊れた最新ラウンド手前の行' "$ROBUST_ROW2" \
  > "$ROBUST_DIR/route-decisions.jsonl"
run env DELEGATE_LOG_DIR="$ROBUST_DIR" "$BIN" --show "$ROBUST_RID"
assert_exit "JSONL 堅牢性: --show は壊れた行を飛ばす" 0
assert_j "JSONL 堅牢性: --show は最新ラウンドを返す" '.round' "2"
run env DELEGATE_LOG_DIR="$ROBUST_DIR" "$BIN" --route-id "$ROBUST_RID" --human-facts '{"mechanical":false}'
assert_exit "JSONL 堅牢性: 再判定は壊れた行を飛ばす" 0
assert_j "JSONL 堅牢性: 再判定は最新ラウンドから進む" '.round' "3"
run env DELEGATE_LOG_DIR="$ROBUST_DIR" "$BIN" --show "$ROBUST_RID"
assert_j "JSONL 堅牢性: 追記後の最新ラウンドを取得" '.round' "3"

run "$BIN" --show "$RID_MD"
assert_exit "--show: 成功" 0
assert_j "--show: 最新ラウンドを返す" '.round' "3"
assert_j "--show: route_id が一致" '.route_id' "$RID_MD"
runE "$BIN" --show rt_nosuch
assert_exit "--show: 未知 route_id は exit 2" 2

runE "$BIN" --unknown-flag
assert_exit "不明な引数は exit 2" 2

BADLINES="$(grep -cv '^$' "$DELEGATE_LOG_DIR/route-decisions.jsonl" >/dev/null; jq -e -s 'length > 0' "$DELEGATE_LOG_DIR/route-decisions.jsonl" >/dev/null 2>&1 && echo ok || echo ng)"
OUT="$BADLINES"; [ "$BADLINES" = "ok" ] && ok || ng "記録: route-decisions.jsonl の全行が JSON として妥当"
OUT="$(jq -s -r '[.[] | select((.route_id|type)!="string" or (.round|type)!="number" or (.gate|type)!="string" or (.open|type)!="array" or (.budget|type)!="object")] | length' "$DELEGATE_LOG_DIR/route-decisions.jsonl")"
[ "$OUT" = "0" ] && ok || ng "記録: 全行が出力スキーマを満たす"
OUT="$(jq -s -r '[.[] | select((.auto_decided|type)!="array")] | length' "$DELEGATE_LOG_DIR/route-decisions.jsonl")"
[ "$OUT" = "0" ] && ok || ng "記録: 全行に auto_decided 配列がある"
OUT="$(jq -s -r '[.[] | select(.route_id == $rid and (.auto_decided | index("difficulty") != null))] | length' --arg rid "$RID_SC" "$DELEGATE_LOG_DIR/route-decisions.jsonl")"
[ "$OUT" = "1" ] && ok || ng "記録: route-decisions.jsonl に difficulty の自動採用を記録する"
OUT="$(jq -s -r '[.[] | select(.ts == null)] | length' "$DELEGATE_LOG_DIR/route-decisions.jsonl")"
[ "$OUT" = "0" ] && ok || ng "記録: 全行に ts がある"
OUT="$(jq -sr '[.[] | select(.policy_version != "0.28.0" or (.ledger_version | type) != "string"
  or (.alternatives | type) != "array" or (has("unavailable_reason") | not)
  or (has("tier_disagreement") | not)
  or any(.open[]; .resolution != "gather" and .resolution != "ask"))] | length' "$DELEGATE_LOG_DIR/route-decisions.jsonl")"
[ "$OUT" = "0" ] && ok || ng "記録: 新しい出力フィールドと resolution を全行に記録する"
OUT="$(grep -E '"reason"[[:space:]]*:[[:space:]]*"tier"|fallback_confirm' "$TMP/route-output.txt")"
[ -z "$OUT" ] && ok || ng "全出力: 廃止したティア質問が含まれない"

echo
echo "PASS: $PASS / FAIL: $FAIL"
rm -rf "$TMP"
[ "$FAIL" -eq 0 ]
