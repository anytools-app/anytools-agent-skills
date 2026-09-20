#!/bin/bash
# delegate-route のテスト — 判定は決定的なので LLM も外部 API も呼ばない。
# 実ログを汚さないよう DELEGATE_LOG_DIR は必ず一時ディレクトリを指す。
set -u
BIN="$(cd "$(dirname "$0")" && pwd)/delegate-route"
PASS=0; FAIL=0

TMP="$(mktemp -d)"
export DELEGATE_LOG_DIR="$TMP/logs"
export DELEGATE_ROUTE_TODAY="2026-09-19"   # today-6 = 2026-09-13 / today-7 = 2026-09-12
mkdir -p "$DELEGATE_LOG_DIR"

INSTR="$TMP/instr.md"
printf '%s\n' '実装指示書。対象は `src/a.ts` と `src/b.ts`。' > "$INSTR"
INSTR_MANY="$TMP/instr-many.md"
printf '%s\n' '対象は `src/a.ts` `src/b.ts` `src/c.ts` `src/d.ts` `src/e.ts` `src/f.ts`。' > "$INSTR_MANY"
INSTR_RISK="$TMP/instr-risk.md"
printf '%s\n' '認証まわりの変更。`src/auth.ts` を触る。' > "$INSTR_RISK"
INSTR_SPACE="$TMP/instruction with spaces.md"
printf '%s\n' '空白を含むパスの指示書。`src/a.ts` を触る。' > "$INSTR_SPACE"

run()  { OUT="$("$@" 2>/dev/null)"; CODE=$?; }
runE() { OUT="$("$@" 2>&1)"; CODE=$?; }
ok()   { PASS=$((PASS+1)); }
ng()   { FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "  ---- output ----"; echo "$OUT" | sed 's/^/  /'; }
assert_exit()     { [ "$CODE" -eq "$2" ] && ok || ng "$1(exit $CODE ≠ $2)"; }
assert_contains() { case "$OUT" in *"$2"*) ok ;; *) ng "$1(期待文字列なし: $2)" ;; esac; }
assert_not_contains() { case "$OUT" in *"$2"*) ng "$1(禁止文字列あり: $2)" ;; *) ok ;; esac; }
jget() { printf '%s' "$OUT" | jq -r "$1" 2>/dev/null; }
assert_j() { V="$(jget "$2")"; [ "$V" = "$3" ] && ok || ng "$1($2 = $V / 期待 $3)"; }

BASE='{"judge":"claude-agent:sonnet",
 "difficulty":{"score":2.1,"confidence":0.92},
 "regression":{"score":1.0,"confidence":0.95},
 "ambiguity":{"score":0.4,"confidence":0.9},
 "mechanical":0.05,"high_stakes":0.1,"splittable":0.85,
 "tier":{"choice":"terra","confidence":0.9},
 "scope_defined":0.95,"behavior_defined":0.9,"done_defined":0.9,"product_decision":0.05}'
sig() { printf '%s' "$BASE" | jq -c "${1:-.}"; }

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

runE "$BIN" --instruction "$TMP/no-such.md" --kind 実装 --signals "$(sig)"
assert_exit "指示書が無ければ exit 2" 2

# ── 推奨ティアの各分岐 ──────────────────────────────────
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)"
assert_exit "基本形: 判定できたら exit 0" 0
assert_j "基本形: terra/high" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-terra/high"
assert_j "基本形: gate confirmed" '.gate' "confirmed"
assert_j "基本形: features.scope_files" '.features.scope_files' "2"
EXPECTED_SHA="$(shasum -a 256 "$INSTR" | awk '{print $1}')"
assert_j "基本形: instruction_sha256 を記録" '.instruction_sha256' "$EXPECTED_SHA"

run "$BIN" --instruction "$INSTR_SPACE" --kind 実装 --signals "$(sig)"
assert_exit "指示書パスに空白: 判定成功" 0
assert_j "指示書パスに空白: 絶対パスを保持" '.instruction' "$INSTR_SPACE"
assert_j "指示書パスに空白: sha を記録" '.instruction_sha256' "$(shasum -a 256 "$INSTR_SPACE" | awk '{print $1}')"

run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.difficulty.score = 1.0')"
assert_j "difficulty<1.5: terra/medium" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-terra/medium"

run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.mechanical = 0.9')"
assert_j "mechanical>=0.8: luna/medium" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-luna/medium"

run "$BIN" --instruction "$INSTR_MANY" --kind 実装 --signals "$(sig '.mechanical = 0.9')"
assert_j "mechanical + 6ファイル: terra/medium" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-terra/medium"
assert_j "mechanical + 6ファイル: scope_files" '.features.scope_files' "6"

run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.difficulty.score = 2.6 | .tier.choice = "sol"')"
assert_j "difficulty>=2.5: sol/high" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"

run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.regression.score = 2 | .tier.choice = "sol"')"
assert_j "regression>=2: sol/high" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"

run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.difficulty.score = 3.5 | .splittable = 0.9 | .tier.choice = "terra"')"
assert_j "difficulty>=3.2 かつ分割可: terra/high" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-terra/high"
assert_j "difficulty>=3.2 かつ分割可: 分割を勧告" '.advice' "split"
assert_j "difficulty>=3.2 かつ分割可: Astra 候補でない" '.astra_candidate' "false"

run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.difficulty.score = 3.5 | .splittable = 0.1 | .tier.choice = "astra"')"
assert_j "difficulty>=3.2 かつ分割不可: astra/high" '.recommend.model + "/" + .recommend.effort' "gpt-6-astra/high"
assert_j "difficulty>=3.2 かつ分割不可: Astra 候補" '.astra_candidate' "true"

run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.high_stakes = 0.9 | .tier.choice = "astra"')"
assert_j "high_stakes>=0.8: astra/max" '.recommend.model + "/" + .recommend.effort' "gpt-6-astra/max"

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
done
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.high_stakes = 0.9 | .tier.choice = "astra"')"
assert_j "kind=実装: Astra 候補は残る" '.astra_candidate' "true"

# ── Astra 承認: 予算内でも必ず聞く / true・false の扱い ──
ASTRA_SIG="$(sig '.high_stakes = 0.9 | .tier.choice = "astra"')"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$ASTRA_SIG"
assert_j "astra: 確定域でも ask_human" '.gate' "ask_human"
assert_j "astra: astra_approval を出す" '[.open[] | select(.reason=="astra_approval")] | length' "1"
assert_j "astra: 質問は model 軸" '[.open[] | select(.reason=="astra_approval")][0].axis' "model"
assert_contains "astra: 質問文に週の消費" "今週 0/8 件・0M/80M"
assert_j "astra: 予算内の選択肢" '[.open[] | select(.reason=="astra_approval")][0].options | join("|")' "Astra を使う|Sol で代替|分割して Terra"
assert_j "astra: astra_approval は open の最後" '.open[-1].reason' "astra_approval"
RID_ASTRA="$(jget '.route_id')"

run "$BIN" --route-id "$RID_ASTRA" --human-facts '{"astra_approved":true}'
assert_j "astra_approved=true: astra のまま" '.recommend.model + "/" + .recommend.effort' "gpt-6-astra/max"
assert_j "astra_approved=true: confirmed" '.gate' "confirmed"
assert_j "astra_approved=true: 出力に反映" '.astra_approved' "true"
assert_j "astra_approved=true: round が進む" '.round' "2"

run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$ASTRA_SIG"
RID_ASTRA2="$(jget '.route_id')"
run "$BIN" --route-id "$RID_ASTRA2" --human-facts '{"astra_approved":false}'
assert_j "astra_approved=false: sol/high に落とす" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"
assert_j "astra_approved=false: confirmed" '.gate' "confirmed"
assert_j "astra_approved=false: 再質問しない" '[.open[] | select(.reason=="astra_approval")] | length' "0"

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
assert_j "予算超過: ask_human" '.gate' "ask_human"
assert_j "予算超過: 選択肢の先頭は Sol 代替" '[.open[] | select(.reason=="astra_approval")][0].options[0]' "Sol で代替(推奨)"
assert_j "予算超過: 選択肢の末尾は超過承知" '[.open[] | select(.reason=="astra_approval")][0].options[-1]' "超過を承知で Astra を使う"
assert_contains "予算超過: 質問文に消費量" "今週 8/8 件・80M/80M"
assert_j "予算超過: rules_applied" '.rules_applied | join(",")' "astra_budget_over"
RID_OVER="$(jget '.route_id')"
run env DELEGATE_LOG_DIR="$OVERDIR" "$BIN" --route-id "$RID_OVER" --human-facts '{"astra_approved":true}'
assert_j "予算超過 + astra_approved=true: astra のまま" '.recommend.model + "/" + .recommend.effort' "gpt-6-astra/max"
assert_j "予算超過 + astra_approved=true: confirmed" '.gate' "confirmed"

# ── 内容の確定条件 ────────────────────────────────────
for PAIR in "scope_defined|.scope_defined = 0.5" "behavior_defined|.behavior_defined = 0.5" \
            "done_defined|.done_defined = 0.5" "product_decision|.product_decision = 0.5" \
            "ambiguity|.ambiguity.score = 2"; do
  AX="${PAIR%%|*}"; EXPR="${PAIR#*|}"
  run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig "$EXPR")"
  assert_j "内容軸 $AX: 未達で ask_human" '.gate' "ask_human"
  assert_j "内容軸 $AX: content 軸の質問が出る" "[.open[] | select(.reason==\"$AX\" and .axis==\"content\")] | length" "1"
done
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.scope_defined = 0.5 | .high_stakes = 0.5')"
assert_j "open の並び: content 軸が先頭" '.open[0].axis' "content"
assert_j "open の並び: model 軸が後" '.open[1].reason' "high_stakes"

# ── モデルの確定条件 ──────────────────────────────────
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.high_stakes = 0.5')"
assert_j "モデル軸: high_stakes 中間値は未確定" '[.open[] | select(.reason=="high_stakes" and .axis=="model")] | length' "1"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.mechanical = 0.5')"
assert_j "モデル軸: mechanical 中間値は未確定" '[.open[] | select(.reason=="mechanical")] | length' "1"
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
assert_j "モデル軸: regression 低確信 + 2 近傍は未確定" '[.open[] | select(.reason=="regression")] | length' "1"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.regression.confidence = 0.5')"
assert_j "モデル軸: regression 低確信でも 2 から遠ければ聞かない(score=1.0)" '[.open[] | select(.reason=="regression")] | length' "0"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.regression.score = 1.5 | .regression.confidence = 0.5')"
assert_j "モデル軸: regression の境界(1.5)は未確定" '[.open[] | select(.reason=="regression")] | length' "1"

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
assert_j "モデル軸: score 決定時は difficulty を自動採用する" '.auto_decided | tojson' '["difficulty"]'
assert_j "モデル軸: score 決定時は regression を従来どおり聞く" '[.open[] | select(.reason=="regression")] | length' "1"

# tier は「2 段以上離れている」か「1 段ずれ + 低確信」のときだけ聞く
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.tier.confidence = 0.5')"
assert_j "モデル軸: tier が推奨と同じなら低確信でも聞かない" '[.open[] | select(.reason=="tier")] | length' "0"
assert_j "モデル軸: tier d=0 低確信は confirmed" '.gate' "confirmed"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.tier.choice = "sol"')"
assert_j "モデル軸: tier 1段違い + 高確信は許容" '.gate' "confirmed"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.tier.choice = "sol" | .tier.confidence = 0.5')"
assert_j "モデル軸: tier 1段違い + 低確信は未確定" '[.open[] | select(.reason=="tier")] | length' "1"
assert_contains "モデル軸: 1段ずれの質問文" "1 段ずれ、判定者の確信も低いです"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.tier.choice = "astra"')"
assert_j "モデル軸: tier 2段違いは高確信でも未確定" '[.open[] | select(.reason=="tier")] | length' "1"
assert_contains "モデル軸: 2段以上の質問文" "2 段以上離れています"
assert_contains "モデル軸: tier 質問に両者を出す" "決定式の推奨(terra)"

# tier の確定扱い: astra_approved に答えた / 推奨の根拠 high_stakes と regression に答えた
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.tier.choice = "astra"')"
RID_TS="$(jget '.route_id')"
run "$BIN" --route-id "$RID_TS" --human-facts '{"astra_approved":false}'
assert_j "tier: astra_approved(false)に答えたら聞かない" '[.open[] | select(.reason=="tier")] | length' "0"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.tier.choice = "astra"')"
RID_TS2="$(jget '.route_id')"
run "$BIN" --route-id "$RID_TS2" --human-facts '{"astra_approved":true}'
assert_j "tier: astra_approved(true)に答えたら聞かない" '[.open[] | select(.reason=="tier")] | length' "0"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.tier.choice = "astra"')"
RID_TS3="$(jget '.route_id')"
run "$BIN" --route-id "$RID_TS3" --human-facts '{"high_stakes":false,"regression":1}'
assert_j "tier: 根拠 high_stakes/regression に答えたら聞かない" '[.open[] | select(.reason=="tier")] | length' "0"
assert_j "tier: 根拠 high_stakes/regression に答えたら確定" '.gate' "confirmed"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.tier.choice = "astra"')"
RID_TS4="$(jget '.route_id')"
run "$BIN" --route-id "$RID_TS4" --human-facts '{"high_stakes":false,"difficulty":2.1}'
assert_j "tier: regression が無ければ依然として聞く" '[.open[] | select(.reason=="tier")] | length' "1"

# splittable は difficulty < 3.2 のとき確定条件から除外する
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.splittable = 0.5')"
assert_j "splittable: difficulty<3.2 なら除外" '[.open[] | select(.reason=="splittable")] | length' "0"
assert_j "splittable: 除外時は confirmed" '.gate' "confirmed"
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.difficulty.score = 3.5 | .splittable = 0.5 | .tier.choice = "terra"')"
assert_j "splittable: difficulty>=3.2 なら確定条件" '[.open[] | select(.reason=="splittable")] | length' "1"

# ── human_facts: 優先・再質問しない・未知キー拒否 ──
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig '.high_stakes = 0.5')"
RID_HF="$(jget '.route_id')"
assert_j "human_facts 前: high_stakes を聞く" '[.open[] | select(.reason=="high_stakes")] | length' "1"
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
run "$BIN" --instruction "$INSTR" --kind 実装 --signals "$(sig)"
RID_TIER2="$(jget '.route_id')"
run "$BIN" --route-id "$RID_TIER2" --human-facts '{"tier":"astra"}'
assert_j "tier 指定 astra: high_stakes<0.8 なら high" '.recommend.effort' "high"
assert_j "tier 指定 astra: 承認は別途必要" '[.open[] | select(.reason=="astra_approval")] | length' "1"
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
runE "$BIN" --route-id "$RID_DC" --human-facts '{"delegated_to_commander":["astra_approval"]}'
assert_exit "delegated_to_commander: astra_approval は拒否" 2
assert_contains "delegated_to_commander: astra_approval を名指し" "astra_approval"
runE "$BIN" --route-id "$RID_DC" --human-facts '{"delegated_to_commander":["fallback_confirm"]}'
assert_exit "delegated_to_commander: fallback_confirm は拒否" 2

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
assert_j "指示書改稿: Astra 承認を取り直す" '[.open[] | select(.reason=="astra_approval")] | length' "1"
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

# ── fallback: signals が無いときは静的ルール ──
run "$BIN" --instruction "$INSTR" --kind 実装
assert_exit "fallback: signals 無しでも exit 0" 0
assert_j "fallback: gate" '.gate' "fallback"
assert_j "fallback: 高リスク語なしは terra/medium" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-terra/medium"
assert_j "fallback: 確認質問を 1 問出す" '[.open[] | select(.reason=="fallback_confirm" and .axis=="model")] | length' "1"
assert_j "fallback: signals は null" '.signals' "null"
assert_j "fallback: difficulty を自動採用しない" '.auto_decided | tojson' '[]'
RID_FB="$(jget '.route_id')"
run "$BIN" --route-id "$RID_FB" --human-facts '{"tier":"terra"}'
assert_j "fallback: tier 指定で確定" '.gate' "confirmed"
assert_j "fallback: tier 指定が推奨になる" '.recommend.model' "gpt-5.6-terra"

run "$BIN" --instruction "$INSTR_RISK" --kind 実装
assert_j "fallback: 高リスク語ありは sol/high" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"
assert_j "fallback: risk_terms を出す" '.features.risk_terms | join(",")' "認証,auth"

# ── allow-unattended ─────────────────────────────────
run "$BIN" --instruction "$INSTR" --kind 実装 --allow-unattended --signals "$(sig '.difficulty.confidence = 0.5')"
assert_j "unattended: difficulty のみなら confirmed" '.gate' "confirmed"
assert_j "unattended: 質問が無いため印を立てない" '.unattended' "false"
run "$BIN" --instruction "$INSTR" --kind 実装 --allow-unattended --signals "$(sig '.scope_defined = 0.5')"
assert_j "unattended: 内容軸が残るなら不可" '.gate' "ask_human"
assert_j "unattended: 不可なら印も立たない" '.unattended' "false"
run "$BIN" --instruction "$INSTR" --kind 実装 --allow-unattended --signals "$ASTRA_SIG"
assert_j "unattended: 推奨が Astra なら不可" '.gate' "ask_human"
run "$BIN" --instruction "$INSTR" --kind 実装 --allow-unattended
assert_j "unattended: fallback_confirm が残るときは fallback のまま" '.gate' "fallback"
assert_j "unattended: fallback は印も立たない" '.unattended' "false"
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
assert_j "回帰: round1 の open は ambiguity/high_stakes のみ" '[.open[].reason] | join(",")' "ambiguity,high_stakes"
assert_j "回帰: round1 の difficulty は自動採用" '.auto_decided | tojson' '["difficulty"]'
assert_j "回帰: round1 は regression を聞かない(score=1.3)" '[.open[] | select(.reason=="regression")] | length' "0"
assert_j "回帰: round1 は tier を聞かない(推奨 sol と d=0)" '[.open[] | select(.reason=="tier")] | length' "0"
assert_j "回帰: round1 の推奨" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"
RID_SC="$(jget '.route_id')"

run "$BIN" --route-id "$RID_SC" --human-facts '{"high_stakes":true,"ambiguity":1,"difficulty":3}'
assert_j "回帰: round2 の推奨は astra/max" '.recommend.model + "/" + .recommend.effort' "gpt-6-astra/max"
assert_j "回帰: round2 の open は tier と astra_approval" '[.open[].reason] | join(",")' "tier,astra_approval"
assert_j "回帰: round2 は ask_human" '.gate' "ask_human"

run "$BIN" --route-id "$RID_SC" --human-facts '{"astra_approved":false}'
assert_j "回帰: round3 は confirmed" '.gate' "confirmed"
assert_j "回帰: round3 の推奨は sol/high" '.recommend.model + "/" + .recommend.effort' "gpt-5.6-sol/high"
assert_j "回帰: round3 の open は空" '.open | length' "0"

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

echo
echo "PASS: $PASS / FAIL: $FAIL"
rm -rf "$TMP"
[ "$FAIL" -eq 0 ]
