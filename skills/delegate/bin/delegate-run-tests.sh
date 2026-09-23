#!/bin/bash
# delegate-run のテスト — lessons.md の既知事故をテストケースに変換したもの。
# すべて --dry-run(または引数エラー)で完結し、実際の CLI 呼び出しは行わない。
set -u
BIN="$(cd "$(dirname "$0")" && pwd)/delegate-run"
PASS=0; FAIL=0

# 隔離環境(環境変数は skill の .env より優先されるので、実 .env があってもテストは隔離される)
TMP="$(mktemp -d)"
export DELEGATE_LOG_DIR="$TMP/logs"
export DELEGATE_MODELS_FILE="$(cd "$(dirname "$0")" && pwd)/testdata/models.fixture.json"
MODELS_FILE="$DELEGATE_MODELS_FILE"
GITDIR="$TMP/repo"; mkdir -p "$GITDIR"; git -C "$GITDIR" init -q
NONGIT="$TMP/plain"; mkdir -p "$NONGIT"
PROMPT="$TMP/prompt.md"; echo "テスト指示" > "$PROMPT"
PROMPT_SHA="$(shasum -a 256 "$PROMPT" | awk '{print $1}')"
PROMPT_OTHER="$TMP/prompt-other.md"; echo "別のテスト指示" > "$PROMPT_OTHER"
PROMPT_REVISED="$TMP/prompt-revised.md"; echo "改稿後のテスト指示" > "$PROMPT_REVISED"
PROMPT_REVISED_SHA="$(shasum -a 256 "$PROMPT_REVISED" | awk '{print $1}')"

run() { OUT="$("$@" 2>&1)"; CODE=$?; }
ok()   { PASS=$((PASS+1)); }
ng()   { FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "  ---- output ----"; echo "$OUT" | sed 's/^/  /'; }
assert_contains()     { case "$OUT" in *"$2"*) ok ;; *) ng "$1(期待文字列なし: $2)" ;; esac; }
assert_not_contains() { case "$OUT" in *"$2"*) ng "$1(禁止文字列あり: $2)" ;; *) ok ;; esac; }
assert_exit()         { [ "$CODE" -eq "$2" ] && ok || ng "$1(exit $CODE ≠ $2)"; }

# ── Codex: write の必須フラグ(workspace-write / approval never / web_search disabled / stdin 遮断) ──
run "$BIN" --dry-run --cli codex --mode write --model gpt-5.6-terra --effort medium --cd "$GITDIR" --prompt-file "$PROMPT"
assert_exit "codex write dry-run 成功" 0
assert_contains "codex write: sandbox"      "--sandbox workspace-write"
assert_contains "codex write: approval"     'approval_policy=\"never\"'
assert_contains "codex write: web_search"   'web_search=\"disabled\"'
assert_contains "codex write: model"        "-m gpt-5.6-terra"
assert_contains "codex write: effort"       'model_reasoning_effort=\"medium\"'
assert_contains "codex write: --cd"         "--cd $GITDIR"
assert_contains "codex write: stdin 遮断"   "< /dev/null"
assert_not_contains "codex: bypass 禁止"    "--dangerously-bypass-approvals-and-sandbox"
assert_not_contains "codex: full-auto 禁止" "--full-auto"
assert_not_contains "codex: skip-git-repo-check 禁止" "--skip-git-repo-check"

# ── Codex: readonly は read-only sandbox ──
run "$BIN" --dry-run --cli codex --mode readonly --model gpt-5.6-luna --effort medium --cd "$GITDIR" --prompt-file "$PROMPT"
assert_contains "codex readonly: sandbox" "--sandbox read-only"

# ── Codex: 非 git ディレクトリは「Not inside a trusted directory」の予防で即エラー ──
run "$BIN" --dry-run --cli codex --mode write --model gpt-5.6-terra --effort medium --cd "$NONGIT" --prompt-file "$PROMPT"
assert_exit "codex 非gitディレクトリ拒否" 2
assert_contains "codex 非git: 理由表示" "git リポジトリ内でない"

# ── Codex: resume は全フラグ付け直し・--last 不使用 ──
run "$BIN" --dry-run --cli codex --mode write --model gpt-5.6-terra --effort medium --cd "$GITDIR" --prompt-file "$PROMPT" --resume 0123abcd-0000-7000-8000-000000000000
assert_exit "codex resume dry-run 成功" 0
assert_contains "codex resume: サブコマンド" "exec resume 0123abcd"
assert_contains "codex resume: sandbox_mode 再指定" 'sandbox_mode=\"workspace-write\"'
assert_contains "codex resume: approval 再指定"     'approval_policy=\"never\"'
assert_contains "codex resume: web_search 再指定"   'web_search=\"disabled\"'
assert_contains "codex resume: model 再指定"        "-m gpt-5.6-terra"
assert_contains "codex resume: effort 再指定"       'model_reasoning_effort=\"medium\"'
assert_not_contains "codex resume: --last 不使用"   "--last"

# ── Codex: effort 未指定はエラー(config デフォルト依存の禁止) ──
run "$BIN" --dry-run --cli codex --mode write --model gpt-5.6-terra --cd "$GITDIR" --prompt-file "$PROMPT"
assert_exit "codex effort 必須" 2

# ── Codex: 台帳の supported を検査(route の allowed と独立)──
run "$BIN" --dry-run --cli codex --mode write --model gpt-6-astra --effort none --cd "$GITDIR" --prompt-file "$PROMPT"
assert_exit "台帳 effort: Astra none は exit 2" 2
assert_contains "台帳 effort: Astra route 検査より先に拒否" "effort none は gpt-6-astra が対応していない"
assert_contains "台帳 effort: supported を表示" '["low","medium","high","xhigh","max","ultra"]'
assert_not_contains "台帳 effort: route の案内まで進まない" "--route-id が必要"
run "$BIN" --dry-run --force-astra --cli codex --mode write --model gpt-6-astra --effort none --cd "$GITDIR" --prompt-file "$PROMPT"
assert_exit "台帳 effort: force-astra でも未対応 effort は拒否" 2
run "$BIN" --dry-run --cli codex --mode readonly --model gpt-5.6-luna --effort ultra --cd "$GITDIR" --prompt-file "$PROMPT"
assert_exit "台帳 effort: Luna ultra は拒否" 2
assert_contains "台帳 effort: Luna の理由" "effort ultra は gpt-5.6-luna が対応していない"
run "$BIN" --dry-run --cli codex --mode write --model gpt-5.6-terra --effort xhigh --cd "$GITDIR" --prompt-file "$PROMPT"
assert_exit "台帳 effort: Terra xhigh は supported なので通る" 0
assert_contains "台帳 effort: xhigh を透過" 'model_reasoning_effort=\"xhigh\"'
run "$BIN" --dry-run --cli codex --mode readonly --model gpt-5.3-codex-spark --effort medium --cd "$GITDIR" --prompt-file "$PROMPT"
assert_exit "台帳 effort: 台帳に無いモデルは従来どおり通る" 0
run env DELEGATE_MODELS_FILE=/nonexistent "$BIN" --dry-run --cli codex --mode write --model gpt-5.6-terra --effort medium --cd "$GITDIR" --prompt-file "$PROMPT"
assert_exit "台帳: 不存在は拒否" 2
assert_contains "台帳: 不存在の理由" "モデル台帳が存在しない: /nonexistent"
run env DELEGATE_MODELS_FILE=/nonexistent "$BIN" --dry-run --cli codex --mode write --model gpt-5.6-terra --cd "$GITDIR" --prompt-file "$PROMPT"
assert_exit "台帳: 必須引数の検査が先" 2
assert_contains "台帳: effort 必須を先に表示" "codex は --effort 必須"
BAD_LEDGER="$TMP/bad-models.json"
for INVALID_JSON in '{' '' 'null' '[]' '{} {}'; do
  printf '%s\n' "$INVALID_JSON" > "$BAD_LEDGER"
  run env DELEGATE_MODELS_FILE="$BAD_LEDGER" "$BIN" --dry-run --cli codex --mode write --model gpt-5.6-terra --effort medium --cd "$GITDIR" --prompt-file "$PROMPT"
  assert_exit "台帳: JSON オブジェクトでない入力を拒否($INVALID_JSON)" 2
  assert_contains "台帳: JSON 不正の理由" "JSON オブジェクトとして解析できない"
done
jq 'del(.tiers.terra)' "$MODELS_FILE" > "$BAD_LEDGER"
run env DELEGATE_MODELS_FILE="$BAD_LEDGER" "$BIN" --dry-run --cli codex --mode write --model gpt-5.6-terra --effort medium --cd "$GITDIR" --prompt-file "$PROMPT"
assert_exit "台帳: tier 欠落も route と同じく拒否" 2
jq '.tiers.terra.model = "missing-model"' "$MODELS_FILE" > "$BAD_LEDGER"
run env DELEGATE_MODELS_FILE="$BAD_LEDGER" "$BIN" --dry-run --cli codex --mode write --model gpt-5.6-terra --effort medium --cd "$GITDIR" --prompt-file "$PROMPT"
assert_exit "台帳: models に無い tier.model を拒否" 2

# high が部分一致する文字列でも、台帳の配列型検査で先に拒否する。
for FIELD_PATH in '["tiers","terra","efforts_allowed"]' '["models","gpt-5.6-terra","efforts_supported"]'; do
  FIELD="$(printf '%s' "$FIELD_PATH" | jq -r 'join(".")')"
  for INVALID_VALUE in '"lowmediumhigh"' '[]' '["medium",1]' 'null' '{}'; do
    jq --argjson path "$FIELD_PATH" --argjson value "$INVALID_VALUE" 'setpath($path; $value)' "$MODELS_FILE" > "$BAD_LEDGER"
    run env DELEGATE_MODELS_FILE="$BAD_LEDGER" "$BIN" --dry-run --cli codex --mode write --model gpt-5.6-terra --effort high --cd "$GITDIR" --prompt-file "$PROMPT"
    assert_exit "台帳: $FIELD の不正な配列を拒否($INVALID_VALUE)" 2
    assert_contains "台帳: 配列の違反項目と理由" "モデル台帳が不正: $FIELD: 1 件以上の文字列配列が必要"
  done
done
for FIELD_PATH in '["ledger_version"]' '["tiers","sol","default_effort"]' '["models","gpt-5.5","status"]'; do
  FIELD="$(printf '%s' "$FIELD_PATH" | jq -r 'join(".")')"
  for INVALID_VALUE in 'null' '1' '[]'; do
    jq --argjson path "$FIELD_PATH" --argjson value "$INVALID_VALUE" 'setpath($path; $value)' "$MODELS_FILE" > "$BAD_LEDGER"
    run env DELEGATE_MODELS_FILE="$BAD_LEDGER" "$BIN" --dry-run --cli codex --mode write --model gpt-5.6-terra --effort high --cd "$GITDIR" --prompt-file "$PROMPT"
    assert_exit "台帳: $FIELD の文字列以外を拒否($INVALID_VALUE)" 2
    assert_contains "台帳: 文字列の違反項目と理由" "モデル台帳が不正: $FIELD: 文字列が必要"
  done
done
for DEFAULT_EFFORT in low med; do
  jq --arg effort "$DEFAULT_EFFORT" '.tiers.terra.default_effort = $effort' "$MODELS_FILE" > "$BAD_LEDGER"
  run env DELEGATE_MODELS_FILE="$BAD_LEDGER" "$BIN" --dry-run --cli codex --mode write --model gpt-5.6-terra --effort high --cd "$GITDIR" --prompt-file "$PROMPT"
  assert_exit "台帳: allowed に無い default_effort を拒否($DEFAULT_EFFORT)" 2
  assert_contains "台帳: default_effort の包含関係の理由" "モデル台帳が不正: tiers.terra.default_effort: efforts_allowed に含まれていない"
done
jq '.models["gpt-5.5"] = false' "$MODELS_FILE" > "$BAD_LEDGER"
run env DELEGATE_MODELS_FILE="$BAD_LEDGER" "$BIN" --dry-run --cli codex --mode write --model gpt-5.6-terra --effort high --cd "$GITDIR" --prompt-file "$PROMPT"
assert_exit "台帳: 実行対象以外の model も検証する" 2
assert_contains "台帳: model 自体の型も項目名つきで拒否" "モデル台帳が不正: models.gpt-5.5: オブジェクトが必要"
jq '.tiers.extra = {model:"gpt-5.6-terra",efforts_allowed:"medium",default_effort:"medium"}' "$MODELS_FILE" > "$BAD_LEDGER"
run env DELEGATE_MODELS_FILE="$BAD_LEDGER" "$BIN" --dry-run --cli codex --mode write --model gpt-5.6-terra --effort high --cd "$GITDIR" --prompt-file "$PROMPT"
assert_exit "台帳: 必須 4 ティア以外も検証する" 2
assert_contains "台帳: 追加ティアの違反項目" "モデル台帳が不正: tiers.extra.efforts_allowed: 1 件以上の文字列配列が必要"
jq '.ledger_version = false | .models["gpt-5.6-terra"].efforts_supported = "lowmediumhigh"' "$MODELS_FILE" > "$BAD_LEDGER"
run env DELEGATE_MODELS_FILE="$BAD_LEDGER" "$BIN" --dry-run --cli codex --mode write --model gpt-5.6-terra --effort high --cd "$GITDIR" --prompt-file "$PROMPT"
assert_exit "台帳: 複数違反も exit 2" 2
[ "$OUT" = "delegate-run: ERROR: モデル台帳が不正: ledger_version: 文字列が必要" ] && ok || ng "台帳: 最初の違反だけを 1 行で表示する"

CUSTOM_LEDGER="$TMP/custom models.json"
jq '.models["gpt-5.6-terra"].efforts_supported = ["medium"]' "$MODELS_FILE" > "$CUSTOM_LEDGER"
run env DELEGATE_MODELS_FILE="$CUSTOM_LEDGER" "$BIN" --dry-run --cli codex --mode write --model gpt-5.6-terra --effort high --cd "$GITDIR" --prompt-file "$PROMPT"
assert_exit "台帳: 環境変数の差し替えた supported を使う" 2
assert_contains "台帳: 差し替えた supported の値" 'efforts_supported: ["medium"]'
run env DELEGATE_MODELS_FILE="$CUSTOM_LEDGER" "$BIN" --dry-run --cli codex --mode write --model gpt-5.6-terra --effort medium --cd "$GITDIR" --prompt-file "$PROMPT"
assert_exit "台帳: 差し替えた supported の許容値は通る" 0

# ── Grok: sandbox と yolo は必ずセット・フルパス・json 出力 ──
run "$BIN" --dry-run --cli grok --mode readonly --effort medium --cd "$NONGIT" --prompt-file "$PROMPT"
assert_exit "grok readonly dry-run 成功" 0
assert_contains "grok: フルパス"        "/.grok/bin/grok"
assert_contains "grok: sandbox"         "--sandbox read-only"
assert_contains "grok: yolo(sandboxとセット)" "--yolo"
assert_contains "grok: no-auto-update"  "--no-auto-update"
assert_contains "grok: cwd"             "--cwd $NONGIT"
assert_contains "grok: json 出力"       "--output-format json"
assert_contains "grok: -p 形式"         '-p "$(cat'
assert_contains "grok: stdin 遮断"      "< /dev/null"

# ── Grok: write は workspace sandbox + max-turns(暴走抑制)デフォルト ──
run "$BIN" --dry-run --cli grok --mode write --cd "$NONGIT" --prompt-file "$PROMPT"
assert_contains "grok write: sandbox"    "--sandbox workspace"
assert_contains "grok write: max-turns"  "--max-turns 40"

# ── Grok: resume は sandbox を付け直さない(セッションに保存・異なる指定はエラーになるため) ──
run "$BIN" --dry-run --cli grok --mode write --cd "$NONGIT" --prompt-file "$PROMPT" --resume sess-123
assert_contains "grok resume: -r"        "-r sess-123"
assert_not_contains "grok resume: sandbox 非指定" "--sandbox"

# ── Grok: --model は任意(指定時は透過、未指定は CLI 既定。深い相談・独立レビューは grok-4.5) ──
run "$BIN" --dry-run --cli grok --mode readonly --model grok-4.5 --cd "$NONGIT" --prompt-file "$PROMPT"
assert_exit "grok --model 透過 dry-run 成功" 0
assert_contains "grok --model: 指定時は透過" "--model grok-4.5"
run "$BIN" --dry-run --cli grok --mode readonly --cd "$NONGIT" --prompt-file "$PROMPT"
assert_not_contains "grok --model: 未指定なら付けない" "--model"

# ── agy: フラグは --print より前・--add-dir=cwd・skip-permissions を生成しない ──
run "$BIN" --dry-run --cli agy --mode readonly --model "Gemini 3.1 Pro (High)" --cd "$NONGIT" --prompt-file "$PROMPT"
assert_exit "agy readonly dry-run 成功" 0
assert_contains "agy: mode plan"        "--mode plan"
assert_contains "agy: sandbox"          "--sandbox"
assert_contains "agy: add-dir=cwd"      "--add-dir $NONGIT"
assert_contains "agy: print-timeout 既定" "--print-timeout 10m"
assert_contains "agy: --print が最後"   '--print "$(cat'
assert_not_contains "agy: skip-permissions 禁止" "--dangerously-skip-permissions"

# ── agy: write は accept-edits、resume は --conversation 明示(-c/--continue 誤爆の禁止) ──
run "$BIN" --dry-run --cli agy --mode write --model "Gemini 3.1 Pro (High)" --cd "$NONGIT" --prompt-file "$PROMPT" --resume 11111111-2222-3333-4444-555555555555
assert_contains "agy write: accept-edits"   "--mode accept-edits"
assert_contains "agy resume: conversation"  "--conversation 11111111-2222-3333-4444-555555555555"
assert_not_contains "agy resume: --continue 不使用" " --continue"

# ── agy: effort 指定は拒否 ──
run "$BIN" --dry-run --cli agy --mode readonly --model "Gemini 3.5 Flash (Low)" --effort high --cd "$NONGIT" --prompt-file "$PROMPT"
assert_exit "agy --effort 拒否" 2

# ── 共通: -o は全 CLI で受理し、ネイティブフラグとしては codex だけに渡す ──
run "$BIN" --dry-run --cli grok --mode readonly --cd "$NONGIT" --prompt-file "$PROMPT" -o "$TMP/r.md"
assert_exit "grok -o dry-run 成功" 0
assert_not_contains "grok -o: codex 専用として拒否しない" "codex 専用"
assert_not_contains "grok -o: ネイティブフラグは渡さない" " -o "

run "$BIN" --dry-run --cli agy --mode readonly --model "Gemini 3.1 Pro (High)" --cd "$NONGIT" --prompt-file "$PROMPT" -o "$TMP/r.md"
assert_exit "agy -o dry-run 成功" 0
assert_not_contains "agy -o: codex 専用として拒否しない" "codex 専用"
assert_not_contains "agy -o: ネイティブフラグは渡さない" " -o "

run "$BIN" --dry-run --cli codex --mode write --model gpt-5.6-terra --effort medium --cd "$GITDIR" --prompt-file "$PROMPT" -o "$TMP/r.md"
assert_exit "codex -o dry-run 成功" 0
assert_contains "codex -o: ネイティブフラグを渡す" " -o "
assert_contains "codex -o: 保存先を渡す" "$TMP/r.md"

# ── Codex: --timeout は引き続き agy 専用として拒否 ──
run "$BIN" --dry-run --cli codex --mode write --model gpt-5.6-terra --effort medium --cd "$GITDIR" --prompt-file "$PROMPT" --timeout 10
assert_exit "codex --timeout 拒否" 2
assert_contains "codex --timeout: 理由表示" "--timeout は agy 専用"

# ── 共通: prompt file 必須・存在チェック / dry-run は JSONL に書かない ──
run "$BIN" --dry-run --cli codex --mode write --model m --effort e --cd "$GITDIR" --prompt-file "$TMP/nai.md"
assert_exit "prompt file 不存在エラー" 2
[ -f "$DELEGATE_LOG_DIR/runs.jsonl" ] && { OUT="runs.jsonl が存在"; ng "dry-run は JSONL に書かない"; } || ok

# ── 共通: 未知の引数(禁止フラグの手動注入含む)は拒否 ──
run "$BIN" --dry-run --cli codex --mode write --model m --effort e --cd "$GITDIR" --prompt-file "$PROMPT" --dangerously-bypass-approvals-and-sandbox
assert_exit "未知引数の拒否" 2

# ── cooldown: 記録 → ゲート拒否 → --force 強行 → 他CLI非影響 → 解除 → 期限切れ無視 ──
run "$BIN" --set-cooldown grok 30m "test limit"
assert_exit "cooldown 記録成功" 0
run "$BIN" --cooldowns
assert_contains "cooldown 一覧に記録が出る" "grok"
run "$BIN" --dry-run --cli grok --mode readonly --cd "$NONGIT" --prompt-file "$PROMPT"
assert_exit "cooldown 中は実行前に拒否" 2
assert_contains "cooldown 拒否: 案内表示" "cooldown 中"
run "$BIN" --dry-run --force --cli grok --mode readonly --cd "$NONGIT" --prompt-file "$PROMPT"
assert_exit "cooldown は --force で強行できる" 0
run "$BIN" --dry-run --cli codex --mode write --model m --effort e --cd "$GITDIR" --prompt-file "$PROMPT"
assert_exit "cooldown は他 CLI に影響しない" 0
run "$BIN" --clear-cooldown grok
assert_exit "cooldown 解除成功" 0
run "$BIN" --dry-run --cli grok --mode readonly --cd "$NONGIT" --prompt-file "$PROMPT"
assert_exit "解除後は実行できる" 0
"$BIN" --set-cooldown grok 30m "expire test" >/dev/null 2>&1
jq '.grok.until = "2000-01-01T00:00:00Z"' "$DELEGATE_LOG_DIR/cooldowns.json" > "$DELEGATE_LOG_DIR/cooldowns.json.tmp" \
  && mv "$DELEGATE_LOG_DIR/cooldowns.json.tmp" "$DELEGATE_LOG_DIR/cooldowns.json"
run "$BIN" --dry-run --cli grok --mode readonly --cd "$NONGIT" --prompt-file "$PROMPT"
assert_exit "期限切れ cooldown は無視される" 0
run "$BIN" --set-cooldown grok bad-duration
assert_exit "不正な期間形式は拒否" 2
run "$BIN" --set-cooldown vscode 30m
assert_exit "未知 CLI の cooldown は拒否" 2

# ── トークン抽出: codex / grok のセッション記録から(fake HOME で検証)──
FAKEHOME="$TMP/home"
mkdir -p "$FAKEHOME/.codex/sessions/2026/07/13" "$FAKEHOME/.grok/sessions/%2Ftmp%2Fx/sess-tok-1"
printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20,"total_tokens":120}}}}' \
  > "$FAKEHOME/.codex/sessions/2026/07/13/rollout-2026-07-13T00-00-00-tok-abc.jsonl"
run env HOME="$FAKEHOME" "$BIN" --extract-tokens codex tok-abc
assert_exit "tokens: codex 抽出成功" 0
assert_contains "tokens: codex の in/cached/out/total" "100 40 20 120"
echo '{"contextTokensUsed":2893,"contextWindowTokens":256000}' > "$FAKEHOME/.grok/sessions/%2Ftmp%2Fx/sess-tok-1/signals.json"
run env HOME="$FAKEHOME" "$BIN" --extract-tokens grok sess-tok-1
assert_contains "tokens: grok の total" "- - - 2893"
run env HOME="$FAKEHOME" "$BIN" --extract-tokens codex no-such-session
assert_exit "tokens: セッション不在でもエラーにしない" 0

# ── ログ先の解決: 環境変数 > skill 直下の .env > デフォルト ──
run "$BIN" --dry-run --cli codex --mode write --model m --effort e --cd "$GITDIR" --prompt-file "$PROMPT"
assert_contains "log dir: 環境変数が反映" "$TMP/logs/runs/"

FAKESKILL="$TMP/fakeskill"; mkdir -p "$FAKESKILL/bin"
cp "$BIN" "$FAKESKILL/bin/delegate-run"
cp "$MODELS_FILE" "$FAKESKILL/models.json"
echo "DELEGATE_LOG_DIR=$TMP/envfile-logs" > "$FAKESKILL/.env"
run env -u DELEGATE_LOG_DIR "$FAKESKILL/bin/delegate-run" --dry-run --cli codex --mode write --model m --effort e --cd "$GITDIR" --prompt-file "$PROMPT"
assert_contains "log dir: .env フォールバック" "$TMP/envfile-logs/runs/"

run "$FAKESKILL/bin/delegate-run" --dry-run --cli codex --mode write --model m --effort e --cd "$GITDIR" --prompt-file "$PROMPT"
assert_contains "log dir: 環境変数 > .env" "$TMP/logs/runs/"

ln -s "$FAKESKILL/bin/delegate-run" "$TMP/delegate-run-link"
run env -u DELEGATE_LOG_DIR "$TMP/delegate-run-link" --dry-run --cli codex --mode write --model m --effort e --cd "$GITDIR" --prompt-file "$PROMPT"
assert_contains "log dir: symlink 越しの .env 解決" "$TMP/envfile-logs/runs/"

# ── コスト換算: 単価は .env の COST_PER_MTOK_*(grok のみ既定あり)──
# 実 .env の単価に影響されないよう FAKESKILL(単価未設定の .env)側のバイナリで検証する
run "$FAKESKILL/bin/delegate-run" --estimate-cost grok 1000000
assert_contains "cost: grok 既定は API input 単価" "2.0000"
run env -u COST_PER_MTOK_CODEX "$FAKESKILL/bin/delegate-run" --estimate-cost codex 5000000
assert_exit "cost: 単価未設定は換算しない(エラーにもしない)" 0
assert_not_contains "cost: 単価未設定で数値を出さない" "."
run env COST_PER_MTOK_CODEX=0.5 "$FAKESKILL/bin/delegate-run" --estimate-cost codex 1000000
assert_contains "cost: 按分単価の設定が効く" "0.5000"
run env COST_PER_MTOK_CLAUDE_AGENT=0.13 "$FAKESKILL/bin/delegate-run" --estimate-cost claude-agent 2000000
assert_contains "cost: claude-agent の換算" "0.2600"
run "$FAKESKILL/bin/delegate-run" --estimate-cost grok not-a-number
assert_exit "cost: 非数値でもエラーにしない" 0

# ── 委任ログ lint: 不存在 / 正常 enum / 実発生した逸脱パターン ──
run "$BIN" --lint-log
assert_exit "lint: ファイル不存在でも成功" 0
assert_contains "lint: ファイル不存在を案内" "存在しないか空"

mkdir -p "$DELEGATE_LOG_DIR"
printf '%s\n' \
  '{"outcome":"採用","cause":"none","validation":"pass","kind":"実装","routing_verdict":"適正","delegation_verdict":"必要"}' \
  '{"outcome":"一部採用","cause":"instruction","validation":"no_new_failures","kind":"調査","routing_verdict":"過小","delegation_verdict":"必要"}' \
  > "$DELEGATE_LOG_DIR/delegation-log.jsonl"
run "$BIN" --lint-log
assert_exit "lint: 正常 enum は成功" 0
assert_contains "lint: 調査を含む正常行は OK" "OK: 2行すべて規約準拠"

printf '%s\n' \
  '{"outcome":"採用","cause":"","validation":"pass","kind":"実装","routing_verdict":"適正","delegation_verdict":"必要"}' \
  '{"outcome":"採用(司令塔修正込み)","cause":"none","validation":"pass","kind":"実装","routing_verdict":"適正","delegation_verdict":"必要"}' \
  '{"outcome":"採用","cause":"reach-analysis","validation":"pass","kind":"実装","routing_verdict":"適正","delegation_verdict":"必要"}' \
  '{"outcome":"採用","cause":"none","validation":"pass","kind":"実装","delegation_verdict":"必要"}' \
  'JSON 解析不能行' \
  > "$DELEGATE_LOG_DIR/delegation-log.jsonl"
run "$BIN" --lint-log
assert_exit "lint: 逸脱があれば exit 1" 1
assert_contains "lint: 空 cause の行番号とフィールド" "line 1: cause="
assert_contains "lint: 注記混入 outcome の行番号とフィールド" "line 2: outcome="
assert_contains "lint: enum 外 cause の行番号とフィールド" "line 3: cause="
assert_contains "lint: 欠落 routing_verdict の行番号とフィールド" "line 4: routing_verdict=(missing)"
assert_contains "lint: 解析不能行の行番号" "line 5: JSON として解析できない"

# ── 司令塔モデル解決(transcript の実モデル。/model 切替に追随)──
CHOME="$TMP/chome"; mkdir -p "$CHOME/.claude/projects/testproj"
printf '%s\n' '{"type":"user"}' '{"type":"assistant","message":{"model":"claude-fable-5"}}' '{"type":"assistant","message":{"model":"claude-opus-4-8"}}' > "$CHOME/.claude/projects/testproj/sess-xyz.jsonl"
run env HOME="$CHOME" CLAUDE_CODE_SESSION_ID=sess-xyz "$BIN" --current-commander
assert_exit "current-commander: 成功" 0
assert_contains "current-commander: 直近 assistant の実モデルを返す" "claude-opus-4-8"
assert_not_contains "current-commander: 古いモデルは返さない" "claude-fable-5"

run env HOME="$CHOME" CLAUDE_CODE_SESSION_ID=no-such-session "$BIN" --current-commander
assert_contains "current-commander: transcript 無しは unknown" "unknown"

run env -u CLAUDE_CODE_SESSION_ID HOME="$CHOME" "$BIN" --current-commander
assert_contains "current-commander: session-id 無しは unknown" "unknown"

# サブエージェント(isSidechain)は無視して main-loop の実モデルを返す
printf '%s\n' '{"type":"assistant","message":{"model":"claude-fable-5"}}' '{"type":"assistant","message":{"model":"claude-opus-4-8"}}' '{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-4-5-20251001"}}' > "$CHOME/.claude/projects/testproj/sess-side.jsonl"
run env HOME="$CHOME" CLAUDE_CODE_SESSION_ID=sess-side "$BIN" --current-commander
assert_contains "current-commander: sidechain を無視し main-loop を返す" "claude-opus-4-8"
assert_not_contains "current-commander: sidechain の haiku は返さない" "haiku"

# ── commander 監査: runs.jsonl 記録の実モデルと委任ログを突き合わせ ──
AHOME="$TMP/ahome"; ALOG="$TMP/alogs"; mkdir -p "$ALOG"
printf '%s\n' \
  '{"run_id":"run_A","ts":"2026-07-19T09:00:00Z","commander":"claude-opus-4-8","prompt_file":"/x"}' \
  '{"run_id":"run_B","ts":"2026-07-10T09:00:00Z","commander":"claude-fable-5","prompt_file":"/x"}' \
  > "$ALOG/runs.jsonl"
printf '%s\n' \
  '{"date":"2026-07-19","run_id":"run_A","commander":"claude-fable-5","kind":"実装"}' \
  '{"date":"2026-07-10","run_id":"run_B","commander":"claude-fable-5","kind":"実装"}' \
  '{"date":"2026-07-19","run_id":"run_Z","commander":"claude-fable-5","kind":"実装"}' \
  > "$ALOG/delegation-log.jsonl"
run env DELEGATE_LOG_DIR="$ALOG" HOME="$AHOME" "$BIN" --audit-commander
assert_exit "audit-commander: 不一致ありは exit 1" 1
assert_contains "audit-commander: opus 誤記録を検出" "run_A"
assert_not_contains "audit-commander: 導入日前(run_B)は対象外" "run_B"
assert_not_contains "audit-commander: runs 未記録(run_Z)は対象外" "run_Z"

run env DELEGATE_LOG_DIR="$ALOG" HOME="$AHOME" "$BIN" --audit-commander --fix
assert_contains "audit-commander --fix: 訂正件数を報告" "1 件を訂正"
CORRECTED="$(jq -r 'select(.run_id=="run_A") | .commander' "$ALOG/delegation-log.jsonl")"
[ "$CORRECTED" = "claude-opus-4-8" ] && ok || ng "audit-commander --fix: run_A が opus に訂正される(実際: $CORRECTED)"
UNTOUCHED="$(jq -r 'select(.run_id=="run_B") | .commander' "$ALOG/delegation-log.jsonl")"
[ "$UNTOUCHED" = "claude-fable-5" ] && ok || ng "audit-commander --fix: 導入日前 run_B は不変(実際: $UNTOUCHED)"

# ── resumes / rework_of 監査: runs の resume 連鎖と手戻りヒューリスティック ──
RWMISSING="$TMP/rework-missing"; mkdir -p "$RWMISSING"
run env DELEGATE_LOG_DIR="$RWMISSING" "$BIN" --audit-rework
assert_exit "audit-rework: log 不在でも成功" 0
assert_contains "audit-rework: log 不在を案内" "delegation-log.jsonl が存在しないか空"
printf '%s\n' '{"date":"2026-07-20","task":"通常実装","kind":"実装","outcome":"採用","resumes":0,"rework_of":null}' \
  > "$RWMISSING/delegation-log.jsonl"
run env DELEGATE_LOG_DIR="$RWMISSING" "$BIN" --audit-rework
assert_exit "audit-rework: runs 不在でも成功" 0
assert_contains "audit-rework: runs 不在を案内" "runs.jsonl が存在しないか空"
run env DELEGATE_LOG_DIR="$RWMISSING" "$BIN" --audit-rework --fix
assert_exit "audit-rework: --fix は拒否" 2
assert_contains "audit-rework: 引数なし専用の使い方案内" "使い方: --audit-rework"

# 1. 親 resumes=0 だが runs に未計上の resume 実行がある
RW1="$TMP/rework-1"; mkdir -p "$RW1"
printf '%s\n' \
  '{"run_id":"run_parent_1","session_id":"session_parent_1","resume_of":null}' \
  '{"run_id":"run_resume_1","session_id":"session_resume_1","resume_of":"session_parent_1"}' \
  > "$RW1/runs.jsonl"
printf '%s\n' \
  '{"date":"2026-07-20","task":"通常実装","kind":"実装","outcome":"採用","resumes":0,"rework_of":null,"run_id":"run_parent_1","note":""}' \
  > "$RW1/delegation-log.jsonl"
run env DELEGATE_LOG_DIR="$RW1" "$BIN" --audit-rework
assert_exit "audit-rework resumes: 未計上 resume は exit 1" 1
assert_contains "audit-rework resumes: 行番号・件数・resume run_id を報告" \
  "resumes不整合: line 1: run_parent_1 resumes=0 だが未計上のresume実行1件(run_resume_1)"
assert_contains "audit-rework resumes: NG 集計" "NG: 検査1=1件 / 警告=0件 / 情報=0件"

# 2. 親 resumes=1 なら同じ resume 連鎖と整合する
RW2="$TMP/rework-2"; mkdir -p "$RW2"
printf '%s\n' \
  '{"run_id":"run_parent_2","session_id":"session_parent_2","resume_of":null}' \
  '{"run_id":"run_resume_2","session_id":"session_resume_2","resume_of":"session_parent_2"}' \
  > "$RW2/runs.jsonl"
printf '%s\n' \
  '{"date":"2026-07-20","task":"通常実装","kind":"実装","outcome":"採用","resumes":1,"rework_of":null,"run_id":"run_parent_2","note":""}' \
  > "$RW2/delegation-log.jsonl"
run env DELEGATE_LOG_DIR="$RW2" "$BIN" --audit-rework
assert_exit "audit-rework resumes: resumes=1 は成功" 0
assert_contains "audit-rework resumes: 整合時は OK" "OK: resumes/rework の機械検査に指摘なし"
assert_not_contains "audit-rework resumes: 整合時は不整合を出さない" "resumes不整合"

# 3. resume 実行が独立した log エントリを持つ場合は親 resumes に要求しない
RW3="$TMP/rework-3"; mkdir -p "$RW3"
printf '%s\n' \
  '{"run_id":"run_parent_3","session_id":"session_parent_3","resume_of":null}' \
  '{"run_id":"run_resume_3","session_id":"session_parent_3","resume_of":"session_parent_3"}' \
  > "$RW3/runs.jsonl"
printf '%s\n' \
  '{"date":"2026-07-20","task":"親実装","kind":"実装","outcome":"採用","resumes":0,"rework_of":null,"run_id":"run_parent_3","note":""}' \
  '{"date":"2026-07-20","task":"resumeの独立記録","kind":"実装","outcome":"採用","resumes":0,"rework_of":null,"run_id":"run_resume_3","note":""}' \
  > "$RW3/delegation-log.jsonl"
run env DELEGATE_LOG_DIR="$RW3" "$BIN" --audit-rework
assert_exit "audit-rework resumes: 独立 log 記録は成功" 0
assert_contains "audit-rework resumes: 独立 log 記録時は OK" "OK: resumes/rework の機械検査に指摘なし"
assert_not_contains "audit-rework resumes: 独立 log 記録を未計上扱いしない" "resumes不整合"

# 4. 丸数字を含む実装 task で rework_of=null は警告(b)
RW4="$TMP/rework-4"; mkdir -p "$RW4"
printf '%s\n' '{"run_id":"run_unrelated_4","session_id":"session_unrelated_4","resume_of":null}' > "$RW4/runs.jsonl"
printf '%s\n' \
  '{"date":"2026-07-20","task":"プレビュー表示の④を修正","kind":"実装","outcome":"採用","resumes":0,"rework_of":null,"run_id":"","note":""}' \
  > "$RW4/delegation-log.jsonl"
run env DELEGATE_LOG_DIR="$RW4" "$BIN" --audit-rework
assert_exit "audit-rework warning(b): 丸数字は exit 1" 1
assert_contains "audit-rework warning(b): 行番号付きで警告" "rework警告(b): line 1"
assert_contains "audit-rework warning(b): task を報告" "task「プレビュー表示の④を修正」 rework_of=null"
assert_contains "audit-rework warning(b): NG 集計" "NG: 検査1=0件 / 警告=1件 / 情報=0件"

# 5. 差し戻し語があっても rework_of 非null なら検出しない
RW5="$TMP/rework-5"; mkdir -p "$RW5"
printf '%s\n' '{"run_id":"run_unrelated_5","session_id":"session_unrelated_5","resume_of":null}' > "$RW5/runs.jsonl"
printf '%s\n' \
  '{"date":"2026-07-20","task":"差し戻し対応","kind":"実装","outcome":"採用","resumes":0,"rework_of":"run_original","run_id":"","note":""}' \
  > "$RW5/delegation-log.jsonl"
run env DELEGATE_LOG_DIR="$RW5" "$BIN" --audit-rework
assert_exit "audit-rework warning(a): rework_of 非null は成功" 0
assert_contains "audit-rework warning(a): rework_of 非null は OK" "OK: resumes/rework の機械検査に指摘なし"
assert_not_contains "audit-rework warning(a): rework_of 非null は警告しない" "rework警告(a)"

# 6. 翌日の同名採用は失敗再試行の情報(c)のみで exit 0
RW6="$TMP/rework-6"; mkdir -p "$RW6"
printf '%s\n' '{"run_id":"run_unrelated_6","session_id":"session_unrelated_6","resume_of":null}' > "$RW6/runs.jsonl"
printf '%s\n' \
  '{"date":"2026-07-20","task":"プレビューのホバーURL表示(初回)","kind":"実装","outcome":"失敗","resumes":0,"rework_of":null,"run_id":"","note":"環境失敗"}' \
  '{"date":"2026-07-21","task":"プレビューのホバーURL表示(再実行)","kind":"実装","outcome":"採用","resumes":0,"rework_of":null,"run_id":"","note":"再実行"}' \
  > "$RW6/delegation-log.jsonl"
run env DELEGATE_LOG_DIR="$RW6" "$BIN" --audit-rework
assert_exit "audit-rework info(c): 情報のみは exit 0" 0
assert_contains "audit-rework info(c): 採用行を報告" "rework情報(c): line 2"
assert_contains "audit-rework info(c): 元の失敗行を報告" "line 1 の失敗の再試行(rework_of不要なら問題なし)"
assert_contains "audit-rework info(c): 情報のみは OK" "OK: resumes/rework の機械検査に指摘なし"

# 差し戻し語が task または note にあり rework_of=null なら警告(a)
RW7="$TMP/rework-7"; mkdir -p "$RW7"
printf '%s\n' '{"run_id":"run_unrelated_7","session_id":"session_unrelated_7","resume_of":null}' > "$RW7/runs.jsonl"
printf '%s\n' \
  '{"date":"2026-07-20","task":"通常実装の修正","kind":"実装","outcome":"採用","resumes":0,"rework_of":null,"run_id":"","note":"人間からの差し戻しを反映"}' \
  > "$RW7/delegation-log.jsonl"
run env DELEGATE_LOG_DIR="$RW7" "$BIN" --audit-rework
assert_exit "audit-rework warning(a): 差し戻し語は exit 1" 1
assert_contains "audit-rework warning(a): note の差し戻し語を検出" "rework警告(a): line 1"

# 「指摘」+数字も指摘リスト痕跡の警告(b)
RW8="$TMP/rework-8"; mkdir -p "$RW8"
printf '%s\n' '{"run_id":"run_unrelated_8","session_id":"session_unrelated_8","resume_of":null}' > "$RW8/runs.jsonl"
printf '%s\n' \
  '{"date":"2026-07-20","task":"レビュー指摘5点を反映","kind":"実装","outcome":"採用","resumes":0,"rework_of":null,"run_id":"","note":""}' \
  > "$RW8/delegation-log.jsonl"
run env DELEGATE_LOG_DIR="$RW8" "$BIN" --audit-rework
assert_exit "audit-rework warning(b): 指摘+数字は exit 1" 1
assert_contains "audit-rework warning(b): 指摘+数字を検出" "rework警告(b): line 1"

# ── Astra ゲート: delegate-route の承認済み判定がなければ実行前に拒否 ──
mkdir -p "$DELEGATE_LOG_DIR"
ROUTE_JSONL="$DELEGATE_LOG_DIR/route-decisions.jsonl"
printf '%s\n' \
  '壊れた route 行' \
  "{\"route_id\":\"rt_open\",\"round\":1,\"gate\":\"ask_human\",\"recommend\":{\"model\":\"gpt-6-astra\",\"effort\":\"high\"},\"astra_approved\":false,\"instruction_sha256\":\"$PROMPT_SHA\",\"open\":[]}" \
  "{\"route_id\":\"rt_ok\",\"round\":1,\"gate\":\"confirmed\",\"recommend\":{\"model\":\"gpt-6-astra\",\"effort\":\"high\"},\"astra_approved\":true,\"instruction_sha256\":\"$PROMPT_SHA\",\"open\":[]}" \
  "{\"route_id\":\"rt_max\",\"round\":1,\"gate\":\"confirmed\",\"recommend\":{\"model\":\"gpt-6-astra\",\"effort\":\"max\"},\"astra_approved\":true,\"instruction_sha256\":\"$PROMPT_SHA\",\"open\":[]}" \
  '{"route_id":"rt_no_sha","round":1,"gate":"confirmed","recommend":{"model":"gpt-6-astra","effort":"high"},"astra_approved":true,"open":[]}' \
  "{\"route_id\":\"rt_consume\",\"round\":1,\"gate\":\"confirmed\",\"recommend\":{\"model\":\"gpt-6-astra\",\"effort\":\"high\"},\"astra_approved\":true,\"instruction_sha256\":\"$PROMPT_SHA\",\"open\":[]}" \
  "{\"route_id\":\"rt_legacy\",\"round\":1,\"gate\":\"confirmed\",\"recommend\":{\"model\":\"gpt-6-astra\",\"effort\":\"high\"},\"astra_approved\":true,\"instruction_sha256\":\"$PROMPT_SHA\",\"open\":[]}" \
  "{\"route_id\":\"rt_fail_retry\",\"round\":1,\"gate\":\"confirmed\",\"recommend\":{\"model\":\"gpt-6-astra\",\"effort\":\"high\"},\"astra_approved\":true,\"instruction_sha256\":\"$PROMPT_SHA\",\"open\":[]}" \
  "{\"route_id\":\"rt_latest\",\"round\":1,\"gate\":\"ask_human\",\"recommend\":{\"model\":\"gpt-6-astra\",\"effort\":\"high\"},\"astra_approved\":false,\"instruction_sha256\":\"$PROMPT_SHA\",\"open\":[]}" \
  '壊れた最新ラウンド手前の行' \
  "{\"route_id\":\"rt_latest\",\"round\":2,\"gate\":\"confirmed\",\"recommend\":{\"model\":\"gpt-6-astra\",\"effort\":\"high\"},\"astra_approved\":true,\"instruction_sha256\":\"$PROMPT_SHA\",\"open\":[]}" \
  "{\"route_id\":\"rt_demoted\",\"round\":1,\"gate\":\"confirmed\",\"recommend\":{\"model\":\"gpt-5.6-sol\",\"effort\":\"high\"},\"astra_approved\":false,\"instruction_sha256\":\"$PROMPT_SHA\",\"open\":[]}" \
  > "$ROUTE_JSONL"

run "$BIN" --dry-run --cli codex --mode write --model gpt-6-astra --effort high --cd "$GITDIR" --prompt-file "$PROMPT"
assert_exit "astra: --route-id なしは拒否" 2
assert_contains "astra: route の案内表示" "delegate-route"

run "$BIN" --dry-run --cli codex --mode write --model gpt-6-astra --effort high --cd "$GITDIR" --prompt-file "$PROMPT" --route-id rt_nosuch
assert_exit "astra: 未知の route_id は拒否" 2
assert_contains "astra: 未知 route の理由表示" "route_id が無い"

run "$BIN" --dry-run --cli codex --mode write --model gpt-6-astra --effort high --cd "$GITDIR" --prompt-file "$PROMPT" --route-id rt_open
assert_exit "astra: 未承認 route は拒否" 2
assert_contains "astra: 未承認の理由表示" "承認済みでない"

run "$BIN" --dry-run --cli codex --mode write --model gpt-6-astra --effort high --cd "$GITDIR" --prompt-file "$PROMPT" --route-id rt_demoted
assert_exit "astra: 推奨が sol に落ちた route は拒否" 2

run "$BIN" --dry-run --cli codex --mode write --model gpt-6-astra --effort high --cd "$GITDIR" --prompt-file "$PROMPT" --route-id rt_ok
assert_exit "astra: 承認済み route なら通過" 0
run "$BIN" --dry-run --cli codex --mode write --model gpt-6-astra --effort high --cd "$GITDIR" --prompt-file "$PROMPT" --route-id rt_latest
assert_exit "astra JSONL: 壊れた行を飛ばして最新 route を取得" 0

run "$BIN" --dry-run --cli codex --mode write --model gpt-6-astra --effort high --cd "$GITDIR" --prompt-file "$PROMPT" --route-id rt_no_sha
assert_exit "astra: route 側 sha 欠落は拒否" 2
assert_contains "astra: route 側 sha 欠落の理由表示" "instruction_sha256 が無い"

run "$BIN" --dry-run --cli codex --mode write --model gpt-6-astra --effort high --cd "$GITDIR" --prompt-file "$PROMPT_OTHER" --route-id rt_ok
assert_exit "astra: prompt sha 不一致は拒否" 2
assert_contains "astra: prompt sha 不一致の理由表示" "instruction_sha256 が一致しない"

run "$BIN" --dry-run --cli codex --mode write --model gpt-6-astra --cd "$GITDIR" --prompt-file "$PROMPT" --route-id rt_ok
assert_exit "astra effort: 未指定は拒否" 2
assert_contains "astra effort: 未指定の理由表示" "effort"
for BAD_EFFORT in medium low; do
  run "$BIN" --dry-run --cli codex --mode write --model gpt-6-astra --effort "$BAD_EFFORT" --cd "$GITDIR" --prompt-file "$PROMPT" --route-id rt_ok
  assert_exit "astra effort: $BAD_EFFORT は拒否" 2
  assert_contains "astra effort: $BAD_EFFORT の許容値を表示" "high または max"
done
run "$BIN" --dry-run --cli codex --mode write --model gpt-6-astra --effort max --cd "$GITDIR" --prompt-file "$PROMPT" --route-id rt_ok
assert_exit "astra effort: route 推奨との不一致は拒否" 2
assert_contains "astra effort: route 推奨との不一致理由" "推奨と一致しない"
run "$BIN" --dry-run --cli codex --mode write --model gpt-6-astra --effort max --cd "$GITDIR" --prompt-file "$PROMPT" --route-id rt_max
assert_exit "astra effort: route 推奨 max なら通過" 0

run "$BIN" --dry-run --force --cli codex --mode write --model gpt-6-astra --effort high --cd "$GITDIR" --prompt-file "$PROMPT"
assert_exit "astra: --force(cooldown 用)ではゲートを迂回できない" 2
assert_contains "astra: --force でも承認を求める" "delegate-route"

run "$BIN" --dry-run --force-astra --cli codex --mode write --model gpt-6-astra --effort high --cd "$GITDIR" --prompt-file "$PROMPT"
assert_exit "astra: --force-astra で強行できる" 0
assert_contains "astra: 強行時は警告を出す" "--force-astra で強行"
assert_contains "astra: 強行時は note への記録を促す" "note に理由"

run "$BIN" --dry-run --force-astra --cli codex --mode write --model gpt-6-astra --effort medium --cd "$GITDIR" --prompt-file "$PROMPT_OTHER" --route-id rt_no_sha
assert_exit "astra: --force-astra は sha・effort・route 不備を迂回" 0
assert_contains "astra: --force-astra + medium は警告つきで通過" "--force-astra で強行"
assert_contains "astra: --force-astra + medium でも effort を明示" 'model_reasoning_effort=\"medium\"'
run "$BIN" --dry-run --force-astra --cli codex --mode write --model gpt-6-astra --cd "$GITDIR" --prompt-file "$PROMPT_OTHER"
assert_exit "astra: --force-astra でも effort 未指定は拒否" 2
assert_contains "astra: effort 未指定は既存の必須条件を維持" "codex は --effort 必須"

run "$BIN" --dry-run --force --cli codex --mode write --model gpt-6-astra --effort medium --cd "$GITDIR" --prompt-file "$PROMPT" --route-id rt_ok
assert_exit "astra: --force では effort 制限を迂回できない" 2
assert_contains "astra: --force の effort 拒否理由" "high または max"

# cooldown 中でも、承認済み route + --force なら通る(ゲートは route、cooldown は --force)
"$BIN" --set-cooldown codex 30m "astra gate test" >/dev/null 2>&1
run "$BIN" --dry-run --cli codex --mode write --model gpt-6-astra --effort high --cd "$GITDIR" --prompt-file "$PROMPT" --route-id rt_ok
assert_exit "astra: cooldown 中は承認済み route でも止まる" 2
assert_contains "astra: 止まる理由は cooldown" "cooldown 中"
run "$BIN" --dry-run --force --cli codex --mode write --model gpt-6-astra --effort high --cd "$GITDIR" --prompt-file "$PROMPT" --route-id rt_ok
assert_exit "astra: cooldown + 承認済み route + --force で通過" 0
"$BIN" --clear-cooldown codex >/dev/null 2>&1

# Astra 以外のモデルでは --force-astra は無害
run "$BIN" --dry-run --force-astra --cli codex --mode write --model gpt-5.6-terra --effort medium --cd "$GITDIR" --prompt-file "$PROMPT"
assert_exit "astra: 他モデルで --force-astra は無害" 0
assert_not_contains "astra: 他モデルでは強行警告を出さない" "--force-astra で強行"

run "$BIN" --dry-run --cli codex --mode write --model gpt-5.6-terra --effort medium --cd "$GITDIR" --prompt-file "$PROMPT"
assert_exit "astra ゲート: Astra 以外は route 不要" 0

# resume でもゲートは効く
run "$BIN" --dry-run --cli codex --mode write --model gpt-6-astra --effort high --cd "$GITDIR" --prompt-file "$PROMPT" --resume 0123abcd-0000-7000-8000-000000000000
assert_exit "astra: resume でもゲートは効く" 2

# Astra 承認は成功した新規実行 1 回で消費し、同じ session の resume だけ許可する
FAKE_ASTRA_BIN="$TMP/fake-astra-bin"; mkdir -p "$FAKE_ASTRA_BIN"
printf '#!/bin/bash\necho "session id: abc12345-0000-7000-8000-000000000000"\n' > "$FAKE_ASTRA_BIN/codex"
chmod +x "$FAKE_ASTRA_BIN/codex"
RUNHOME_ASTRA="$TMP/runhome-astra"; mkdir -p "$RUNHOME_ASTRA"
run env HOME="$RUNHOME_ASTRA" PATH="$FAKE_ASTRA_BIN:$PATH" "$BIN" --cli codex --mode write --model gpt-6-astra --effort high \
  --cd "$GITDIR" --prompt-file "$PROMPT" --route-id rt_consume
assert_exit "astra 消費: 1 回目の新規実行は成功" 0
LOGGED_INSTRUCTION_SHA="$(jq -r 'select(.route_id=="rt_consume") | .instruction_sha256' "$DELEGATE_LOG_DIR/runs.jsonl")"
[ "$LOGGED_INSTRUCTION_SHA" = "$PROMPT_SHA" ] && ok \
  || { OUT="$LOGGED_INSTRUCTION_SHA"; ng "run: runs.jsonl に instruction_sha256 を記録"; }
{
  printf '%s\n' '壊れた runs 行'
  cat "$DELEGATE_LOG_DIR/runs.jsonl"
} > "$DELEGATE_LOG_DIR/runs.jsonl.tmp"
mv "$DELEGATE_LOG_DIR/runs.jsonl.tmp" "$DELEGATE_LOG_DIR/runs.jsonl"
run env HOME="$RUNHOME_ASTRA" PATH="$FAKE_ASTRA_BIN:$PATH" "$BIN" --cli codex --mode write --model gpt-6-astra --effort high \
  --cd "$GITDIR" --prompt-file "$PROMPT" --route-id rt_consume
assert_exit "astra 消費: 壊れた行の後でも同一 route_id の 2 回目新規実行を拒否" 2
assert_contains "astra 消費: 使用済み理由を表示" "この指示書内容での Astra 承認は使用済み"
assert_contains "astra 消費: 同一内容の再実行手順" "--instruction からやり直して新しい route_id"
assert_contains "astra 消費: 修正継続の手順" "修正の継続は --resume"
assert_contains "astra 消費: 改稿後の再承認手順" "instruction_changed:true"

run env HOME="$RUNHOME_ASTRA" PATH="$FAKE_ASTRA_BIN:$PATH" "$BIN" --dry-run --cli codex --mode write --model gpt-6-astra --effort high \
  --cd "$GITDIR" --prompt-file "$PROMPT" --route-id rt_consume --resume abc12345-0000-7000-8000-000000000000
assert_exit "astra resume: 壊れた行の後でも一致する session_id は通過" 0
run env HOME="$RUNHOME_ASTRA" PATH="$FAKE_ASTRA_BIN:$PATH" "$BIN" --dry-run --cli codex --mode write --model gpt-6-astra --effort high \
  --cd "$GITDIR" --prompt-file "$PROMPT" --route-id rt_consume --resume fff12345-0000-7000-8000-000000000000
assert_exit "astra resume: 不一致 session_id は拒否" 2
assert_contains "astra resume: 不一致理由を表示" "session_id と一致しない"

# 同じ route_id でも、改稿後の新しい sha で再承認された最新ラウンドなら新規実行できる
printf '%s\n' \
  "{\"route_id\":\"rt_consume\",\"round\":2,\"gate\":\"confirmed\",\"recommend\":{\"model\":\"gpt-6-astra\",\"effort\":\"high\"},\"astra_approved\":true,\"instruction_sha256\":\"$PROMPT_REVISED_SHA\",\"open\":[]}" \
  >> "$ROUTE_JSONL"
run env HOME="$RUNHOME_ASTRA" PATH="$FAKE_ASTRA_BIN:$PATH" "$BIN" --cli codex --mode write --model gpt-6-astra --effort high \
  --cd "$GITDIR" --prompt-file "$PROMPT_REVISED" --route-id rt_consume
assert_exit "astra 消費: 改稿・同一 route_id・新しい sha の再承認後は新規実行できる" 0
REVISED_LOGGED_SHA="$(jq -Rr 'fromjson? | select(type=="object" and .route_id=="rt_consume") | .instruction_sha256' \
  "$DELEGATE_LOG_DIR/runs.jsonl" | tail -1)"
[ "$REVISED_LOGGED_SHA" = "$PROMPT_REVISED_SHA" ] && ok \
  || { OUT="$REVISED_LOGGED_SHA"; ng "run: 改稿後の instruction_sha256 を記録"; }

# instruction_sha256 の無い旧成功 run は安全側で同じ内容の消費済みとみなす
printf '%s\n' \
  '{"run_id":"run_legacy_success","route_id":"rt_legacy","exit_code":0,"resume_of":null,"session_id":"legacy-session"}' \
  >> "$DELEGATE_LOG_DIR/runs.jsonl"
run env HOME="$RUNHOME_ASTRA" PATH="$FAKE_ASTRA_BIN:$PATH" "$BIN" --dry-run --cli codex --mode write --model gpt-6-astra --effort high \
  --cd "$GITDIR" --prompt-file "$PROMPT" --route-id rt_legacy
assert_exit "astra 消費: instruction_sha256 の無い旧成功 run は使用済み" 2
assert_contains "astra 消費: 旧成功 run も使用済み理由を表示" "この指示書内容での Astra 承認は使用済み"

# 以降の非ゲート系テストは jq で runs.jsonl を直接読むため、堅牢性 fixture の壊れた行を除く
sed '/^壊れた runs 行$/d' "$DELEGATE_LOG_DIR/runs.jsonl" > "$DELEGATE_LOG_DIR/runs.jsonl.tmp"
mv "$DELEGATE_LOG_DIR/runs.jsonl.tmp" "$DELEGATE_LOG_DIR/runs.jsonl"

printf '#!/bin/bash\nexit 1\n' > "$FAKE_ASTRA_BIN/codex"; chmod +x "$FAKE_ASTRA_BIN/codex"
run env HOME="$RUNHOME_ASTRA" PATH="$FAKE_ASTRA_BIN:$PATH" "$BIN" --cli codex --mode write --model gpt-6-astra --effort high \
  --cd "$GITDIR" --prompt-file "$PROMPT" --route-id rt_fail_retry
assert_exit "astra 消費: 失敗 run は exit 1" 1
printf '#!/bin/bash\necho "session id: def12345-0000-7000-8000-000000000000"\n' > "$FAKE_ASTRA_BIN/codex"; chmod +x "$FAKE_ASTRA_BIN/codex"
run env HOME="$RUNHOME_ASTRA" PATH="$FAKE_ASTRA_BIN:$PATH" "$BIN" --cli codex --mode write --model gpt-6-astra --effort high \
  --cd "$GITDIR" --prompt-file "$PROMPT" --route-id rt_fail_retry
assert_exit "astra 消費: exit_code!=0 の run 後は新規実行できる" 0

run env HOME="$RUNHOME_ASTRA" PATH="$FAKE_ASTRA_BIN:$PATH" "$BIN" --dry-run --force-astra --cli codex --mode write --model gpt-6-astra --effort low \
  --cd "$GITDIR" --prompt-file "$PROMPT_OTHER" --route-id rt_consume
assert_exit "astra: --force-astra は承認消費・sha・effort をまとめて迂回" 0

# ── run 実行: runs.jsonl の route_id と指示書の退避(fake CLI で実行を伴う検証)──
FAKEAGY="$TMP/fake-agy"; printf '#!/bin/bash\necho fake-agy-ok\n' > "$FAKEAGY"; chmod +x "$FAKEAGY"
RUNHOME="$TMP/runhome"; mkdir -p "$RUNHOME"
run env HOME="$RUNHOME" AGY_BIN="$FAKEAGY" "$BIN" --cli agy --mode readonly --model "Gemini 3.1 Pro (High)" \
  --cd "$NONGIT" --prompt-file "$PROMPT" --route-id rt_ok
assert_exit "run: fake agy の実行に成功" 0
RID="$(printf '%s' "$OUT" | sed -n 's/^run_id: //p' | head -1)"
[ -n "$RID" ] && ok || ng "run: run_id を出力する"
LOGGED_ROUTE="$(jq -r --arg r "$RID" 'select(.run_id==$r) | .route_id' "$DELEGATE_LOG_DIR/runs.jsonl" 2>/dev/null)"
[ "$LOGGED_ROUTE" = "rt_ok" ] && ok || ng "run: runs.jsonl に route_id を記録(実際: $LOGGED_ROUTE)"
LOGGED_AGY_SHA="$(jq -r --arg r "$RID" 'select(.run_id==$r) | .instruction_sha256' "$DELEGATE_LOG_DIR/runs.jsonl" 2>/dev/null)"
[ "$LOGGED_AGY_SHA" = "$PROMPT_SHA" ] && ok \
  || { OUT="$LOGGED_AGY_SHA"; ng "run: Astra 以外も instruction_sha256 を記録"; }
if [ -f "$DELEGATE_LOG_DIR/instructions/$RID.md" ] \
   && cmp -s "$PROMPT" "$DELEGATE_LOG_DIR/instructions/$RID.md"; then ok
else OUT="$(ls -R "$DELEGATE_LOG_DIR" 2>&1)"; ng "run: 指示書を instructions/<run_id>.md へ退避"; fi

# route-id 未指定なら runs.jsonl の route_id は null
run env HOME="$RUNHOME" AGY_BIN="$FAKEAGY" "$BIN" --cli agy --mode readonly --model "Gemini 3.1 Pro (High)" \
  --cd "$NONGIT" --prompt-file "$PROMPT"
RID2="$(printf '%s' "$OUT" | sed -n 's/^run_id: //p' | head -1)"
LOGGED_ROUTE2="$(jq -r --arg r "$RID2" 'select(.run_id==$r) | .route_id' "$DELEGATE_LOG_DIR/runs.jsonl" 2>/dev/null)"
[ "$LOGGED_ROUTE2" = "null" ] && ok || ng "run: route-id 未指定なら null(実際: $LOGGED_ROUTE2)"
LOGGED_FORCED="$(jq -r --arg r "$RID2" 'select(.run_id==$r) | .astra_forced' "$DELEGATE_LOG_DIR/runs.jsonl" 2>/dev/null)"
[ "$LOGGED_FORCED" = "false" ] && ok || ng "run: 強行していなければ astra_forced=false(実際: $LOGGED_FORCED)"

# --force-astra で強行した実行は runs.jsonl に astra_forced:true を残す(実 codex は呼ばない)
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
printf '#!/bin/bash\necho fake-codex-ok\n' > "$FAKEBIN/codex"; chmod +x "$FAKEBIN/codex"
run env HOME="$RUNHOME" PATH="$FAKEBIN:$PATH" "$BIN" --cli codex --mode write --model gpt-6-astra --effort high \
  --cd "$GITDIR" --prompt-file "$PROMPT" --force-astra
RID3="$(printf '%s' "$OUT" | sed -n 's/^run_id: //p' | head -1)"
LOGGED_FORCED3="$(jq -r --arg r "$RID3" 'select(.run_id==$r) | .astra_forced' "$DELEGATE_LOG_DIR/runs.jsonl" 2>/dev/null)"
[ "$LOGGED_FORCED3" = "true" ] && ok || ng "run: 強行実行は astra_forced=true(実際: $LOGGED_FORCED3)"

# dry-run は退避しない
BEFORE_N="$(ls "$DELEGATE_LOG_DIR/instructions" 2>/dev/null | grep -c . | tr -d ' ')"
run "$BIN" --dry-run --cli codex --mode write --model gpt-5.6-terra --effort medium --cd "$GITDIR" --prompt-file "$PROMPT"
AFTER_N="$(ls "$DELEGATE_LOG_DIR/instructions" 2>/dev/null | grep -c . | tr -d ' ')"
[ "$BEFORE_N" = "$AFTER_N" ] && ok || ng "run: dry-run では指示書を退避しない($BEFORE_N → $AFTER_N)"

echo
echo "PASS: $PASS / FAIL: $FAIL"
rm -rf "$TMP"
[ "$FAIL" -eq 0 ]
