#!/bin/bash
# delegate-run のテスト — lessons.md の既知事故をテストケースに変換したもの。
# すべて --dry-run(または引数エラー)で完結し、実際の CLI 呼び出しは行わない。
set -u
BIN="$(cd "$(dirname "$0")" && pwd)/delegate-run"
PASS=0; FAIL=0

# 隔離環境(環境変数は skill の .env より優先されるので、実 .env があってもテストは隔離される)
TMP="$(mktemp -d)"
export DELEGATE_LOG_DIR="$TMP/logs"
GITDIR="$TMP/repo"; mkdir -p "$GITDIR"; git -C "$GITDIR" init -q
NONGIT="$TMP/plain"; mkdir -p "$NONGIT"
PROMPT="$TMP/prompt.md"; echo "テスト指示" > "$PROMPT"

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

echo
echo "PASS: $PASS / FAIL: $FAIL"
rm -rf "$TMP"
[ "$FAIL" -eq 0 ]
