#!/usr/bin/env bash
set -u

PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); }
ng() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in *"$needle"*) ok ;; *) ng "$label (missing: $needle)" ;; esac
}
assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in *"$needle"*) ng "$label (unexpected: $needle)" ;; *) ok ;; esac
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
LOG_DIR="$TMP/logs"
REPO="$TMP/repo"
FAKE="$TMP/claude"
ARGS_FILE="$TMP/args"
STDIN_FILE="$TMP/stdin"
mkdir -p "$HOME_DIR" "$REPO"
git -C "$REPO" init -q
printf '%s\n' 'base' > "$REPO/file.txt"
printf '%s\n' '# review packet' > "$TMP/review.md"

cat > "$FAKE" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  if [ "${FAKE_HELP_MODE:-complete}" = missing ]; then
    printf '%s\n' '--safe-mode --model'
  else
    printf '%s\n' '--safe-mode --no-chrome --permission-mode --tools --disallowedTools --model --effort --output-format --session-id --resume'
  fi
  exit 0
fi
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  if [ "${FAKE_AUTH:-true}" = true ]; then
    printf '%s\n' '{"loggedIn":true,"authMethod":"fake"}'
  else
    printf '%s\n' '{"loggedIn":false,"authMethod":"none"}'
  fi
  exit 0
fi
printf '%s\n' "$*" > "$FAKE_ARGS_FILE"
cat > "$FAKE_STDIN_FILE"
if [ "${FAKE_MODE:-ok}" = limit ]; then
  echo 'quota exhausted' >&2
  exit 1
fi
if [ "${FAKE_MODE:-ok}" = invalid ]; then
  printf '%s\n' 'not-json'
  exit 0
fi
if [ "${FAKE_MODE:-ok}" = mutate ]; then
  printf '%s\n' 'unexpected' > reviewer-created.txt
fi
if [ "${FAKE_MODE:-ok}" = mutate_fail ]; then
  printf '%s\n' 'unexpected' > reviewer-created.txt
  printf '%s\n' '{"session_id":"fake-session","result":"failed after mutation"}'
  exit 7
fi
if [ "${FAKE_MODE:-ok}" = result_mention ]; then
  printf '%s\n' '{"session_id":"fake-session","result":"review text mentions rate limit"}'
  exit 1
fi
if [ "${FAKE_MODE:-ok}" = raw_limit ]; then
  printf '%s\n' 'rate limit exceeded'
  exit 1
fi
sid="fake-session"
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id|--resume) sid="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '{"session_id":"%s","result":"重大な指摘なし","usage":{"input_tokens":100,"cache_read_input_tokens":20,"output_tokens":30},"total_cost_usd":0.0123}\n' "$sid"
FAKE_CLAUDE
chmod +x "$FAKE"

RUNNER="$(cd "$(dirname "$0")" && pwd)/delegate-review"
LOGGER="$(cd "$(dirname "$0")" && pwd)/delegate-log"

SAFE_ENV_SKILL="$TMP/safe-env-skill"
mkdir -p "$SAFE_ENV_SKILL/bin"
cp "$LOGGER" "$SAFE_ENV_SKILL/bin/delegate-log"
printf 'DELEGATE_CODEX_LOG_DIR="%s"\nCLAUDE_BIN=\n' "$TMP/safe-env-log" > "$SAFE_ENV_SKILL/.env"
OUT="$(env HOME="$HOME_DIR" "$SAFE_ENV_SKILL/bin/delegate-log" --repo sample --task safe-env --kind 相談 --agent self --model unknown --risk 低 --outcome 採用 --validation not_run --routing 適正 --cause none 2>&1)"
assert_contains "static .env parser accepts allowlisted keys" "$OUT" "$TMP/safe-env-log/delegation-log.jsonl"

MALICIOUS_ENV_MARKER="$TMP/malicious-env-executed"
for ENV_SCRIPT in delegate-log delegate-review; do
  MALICIOUS_ENV_SKILL="$TMP/malicious-env-$ENV_SCRIPT"
  mkdir -p "$MALICIOUS_ENV_SKILL/bin"
  cp "$LOGGER" "$MALICIOUS_ENV_SKILL/bin/delegate-log"
  cp "$RUNNER" "$MALICIOUS_ENV_SKILL/bin/delegate-review"
  printf 'DELEGATE_CODEX_LOG_DIR=$(touch %s)\n' "$MALICIOUS_ENV_MARKER" > "$MALICIOUS_ENV_SKILL/.env"
  set +e
  if [ "$ENV_SCRIPT" = delegate-log ]; then
    OUT="$(env HOME="$HOME_DIR" "$MALICIOUS_ENV_SKILL/bin/$ENV_SCRIPT" --new-task-id 2>&1)"
  else
    OUT="$(env HOME="$HOME_DIR" "$MALICIOUS_ENV_SKILL/bin/$ENV_SCRIPT" --cooldowns 2>&1)"
  fi
  RC=$?
  set -e
  [ "$RC" -eq 2 ] && ok || ng "$ENV_SCRIPT がskill .envのshell構文を拒否しない"
  assert_contains "$ENV_SCRIPT static .env shell rejection" "$OUT" "shell構文は使えない"
  [ ! -e "$MALICIOUS_ENV_MARKER" ] && ok || ng "$ENV_SCRIPT がskill .envのcommand substitutionを実行した"
done

SYMLINK_ENV_SKILL="$TMP/symlink-env-skill"
mkdir -p "$SYMLINK_ENV_SKILL/bin"
cp "$LOGGER" "$SYMLINK_ENV_SKILL/bin/delegate-log"
printf '%s\n' 'DELEGATE_CODEX_LOG_DIR=' > "$TMP/outside.env"
ln -s "$TMP/outside.env" "$SYMLINK_ENV_SKILL/.env"
set +e
OUT="$(env HOME="$HOME_DIR" "$SYMLINK_ENV_SKILL/bin/delegate-log" --new-task-id 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "symlinked skill .envを拒否しない"
assert_contains "symlinked skill .env rejection" "$OUT" "skill .env に symlink は使えない"

COMMON_ENV=(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$LOG_DIR" CLAUDE_BIN="$FAKE" FAKE_ARGS_FILE="$ARGS_FILE" FAKE_STDIN_FILE="$STDIN_FILE")

OUT="$("$RUNNER" --help 2>&1)"
assert_contains "help exit code 3" "$OUT" "3: worktree changed"
assert_contains "help exit code 2 includes run-log failure" "$OUT" "run-log write failure"

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/help-log" CLAUDE_BIN="$FAKE" FAKE_HELP_MODE=missing FAKE_ARGS_FILE="$ARGS_FILE" FAKE_STDIN_FILE="$STDIN_FILE" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$TMP/review.md" --dry-run 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "必須 Claude flag 欠落を exit 2 にしない"
assert_contains "missing flag message" "$OUT" "必須 flag"

OUT="$("${COMMON_ENV[@]}" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$TMP/review.md" --dry-run 2>&1)"
assert_contains "dry-run safe-mode" "$OUT" "--safe-mode"
assert_contains "dry-run plan" "$OUT" "--permission-mode plan"
assert_contains "dry-run tools" "$OUT" "Read\,Glob\,Grep"
assert_contains "dry-run MCP deny" "$OUT" "mcp__\*"
assert_not_contains "dry-run Bash disabled" "$OUT" "Read\,Glob\,Grep\,Bash"
assert_contains "dry-run stdin packet" "$OUT" "$TMP/review.md"
[ ! -e "$LOG_DIR/runs.jsonl" ] && ok || ng "dry-run が runs.jsonl を作成した"

OUT="$("${COMMON_ENV[@]}" "$RUNNER" --model fable --effort high --cd "$REPO" --prompt-file "$TMP/review.md" --dry-run 2>&1)"
assert_contains "critical fable model" "$OUT" "--model fable"

OUT="$("${COMMON_ENV[@]}" "$RUNNER" --model opus --effort high --cd "$REPO" --prompt-file "$TMP/review.md" --dry-run 2>&1)"
assert_contains "high-risk opus model passthrough" "$OUT" "--model opus"
assert_contains "high-risk opus effort passthrough" "$OUT" "--effort high"

OUT="$("${COMMON_ENV[@]}" "$RUNNER" --model future-claude-model --effort high --cd "$REPO" --prompt-file "$TMP/review.md" --dry-run 2>&1)"
assert_contains "arbitrary model passthrough remains allowed" "$OUT" "--model future-claude-model"

OUT="$(env HOME="$HOME_DIR" XDG_STATE_HOME= CLAUDE_BIN="$FAKE" FAKE_ARGS_FILE="$ARGS_FILE" FAKE_STDIN_FILE="$STDIN_FILE" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$TMP/review.md" --dry-run 2>&1)"
if [ "$(uname -s)" = Darwin ]; then
  assert_contains "macOS default log dir" "$OUT" "$HOME_DIR/Library/Logs/delegate-codex"
else
  assert_contains "Linux default log dir" "$OUT" "$HOME_DIR/.local/state/delegate-codex"
fi

OUT="$(env HOME="$HOME_DIR" XDG_STATE_HOME="$TMP/xdg-state" CLAUDE_BIN="$FAKE" FAKE_ARGS_FILE="$ARGS_FILE" FAKE_STDIN_FILE="$STDIN_FILE" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$TMP/review.md" --dry-run 2>&1)"
assert_contains "XDG default log dir" "$OUT" "$TMP/xdg-state/delegate-codex"

REVIEW_MKDIR_BLOCKER="$TMP/review-mkdir-blocker"
printf '%s\n' blocker > "$REVIEW_MKDIR_BLOCKER"
set +e
OUT="$(env LC_ALL=C HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$REVIEW_MKDIR_BLOCKER/logs" CLAUDE_BIN="$FAKE" FAKE_ARGS_FILE="$ARGS_FILE" FAKE_STDIN_FILE="$STDIN_FILE" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$TMP/review.md" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "delegate-review mkdir 失敗を exit 2 にしない"
assert_contains "delegate-review mkdir OS error" "$OUT" "Not a directory"
assert_contains "delegate-review mkdir escalation guidance" "$OUT" "同一コマンドを sandbox escalation"

OUT="$(cd "$TMP" && env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/relative-cli-log" CLAUDE_BIN=./claude FAKE_ARGS_FILE="$ARGS_FILE" FAKE_STDIN_FILE="$STDIN_FILE" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$TMP/review.md" 2>&1)"
assert_contains "relative claude bin normalized" "$OUT" "exit_code: 0"

set +e
OUT="$("${COMMON_ENV[@]}" "$RUNNER" --model sonnet --effort high --cd relative/repo --prompt-file "$TMP/review.md" --dry-run 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "相対 --cd を exit 2 で拒否しない"
assert_contains "relative cd message" "$OUT" "絶対パス"

OUT="$("${COMMON_ENV[@]}" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$TMP/review.md" 2>&1)"
assert_contains "run summary" "$OUT" "exit_code: 0"
assert_contains "tokens summary" "$OUT" "total=150"
assert_contains "fake args safe-mode" "$(cat "$ARGS_FILE")" "--safe-mode"
[ "$(cat "$STDIN_FILE")" = '# review packet' ] && ok || ng "review packet が stdin で渡っていない"
[ "$(jq -r '.orchestrator' "$LOG_DIR/runs.jsonl")" = codex ] && ok || ng "orchestrator が codex でない"
[ "$(jq -r '.cli' "$LOG_DIR/runs.jsonl")" = claude ] && ok || ng "cli が claude でない"
[ "$(jq -r '.safe_mode' "$LOG_DIR/runs.jsonl")" = true ] && ok || ng "safe_mode が記録されていない"
[ "$(jq -r '.tokens_total' "$LOG_DIR/runs.jsonl")" = 150 ] && ok || ng "tokens_total が不正"
[ "$(jq -r '.result_valid' "$LOG_DIR/runs.jsonl")" = true ] && ok || ng "result_valid=true が記録されていない"
[ "$(jq -r '.runner_exit_code' "$LOG_DIR/runs.jsonl")" = 0 ] && ok || ng "runner_exit_code=0 が記録されていない"

APPEND_FAIL_LOG="$TMP/append-fail-log"
mkdir -p "$APPEND_FAIL_LOG/runs.jsonl"
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$APPEND_FAIL_LOG" CLAUDE_BIN="$FAKE" FAKE_ARGS_FILE="$ARGS_FILE" FAKE_STDIN_FILE="$STDIN_FILE" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$TMP/review.md" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "runs.jsonl 追記失敗を exit 2 にしない"
assert_contains "runs.jsonl append failure message" "$OUT" "delegate-review: ERROR: runs.jsonl への追記に失敗: $APPEND_FAIL_LOG/runs.jsonl"
assert_contains "runs.jsonl append escalation guidance" "$OUT" "同一コマンドを sandbox escalation"

RUNS_SYMLINK_LOG="$TMP/runs-symlink-log"
mkdir -p "$RUNS_SYMLINK_LOG"
printf '%s\n' outside > "$TMP/outside-runs.jsonl"
ln -s "$TMP/outside-runs.jsonl" "$RUNS_SYMLINK_LOG/runs.jsonl"
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$RUNS_SYMLINK_LOG" CLAUDE_BIN="$FAKE" FAKE_ARGS_FILE="$ARGS_FILE" FAKE_STDIN_FILE="$STDIN_FILE" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$TMP/review.md" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "runs.jsonl symlink を exit 2 で拒否しない"
assert_contains "runs.jsonl symlink message" "$OUT" "runs.jsonl に symlink は使えない: $RUNS_SYMLINK_LOG/runs.jsonl"
[ "$(cat "$TMP/outside-runs.jsonl")" = outside ] && ok || ng "runs.jsonl symlink 先を変更した"

OUT="$("${COMMON_ENV[@]}" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$TMP/review.md" --resume resume-123 2>&1)"
assert_contains "resume summary" "$OUT" "session_id: resume-123"
assert_contains "resume args" "$(cat "$ARGS_FILE")" "--resume resume-123"

INVALID_LOG="$TMP/invalid-log"
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$INVALID_LOG" CLAUDE_BIN="$FAKE" FAKE_MODE=invalid FAKE_ARGS_FILE="$ARGS_FILE" FAKE_STDIN_FILE="$STDIN_FILE" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$TMP/review.md" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 4 ] && ok || ng "不正な Claude JSON を exit 4 にしない"
[ "$(jq -r '.result_valid' "$INVALID_LOG/runs.jsonl")" = false ] && ok || ng "result_valid=false が記録されない"
[ "$(jq -r '.runner_exit_code' "$INVALID_LOG/runs.jsonl")" = 4 ] && ok || ng "runner_exit_code=4 が記録されない"

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/auth-log" CLAUDE_BIN="$FAKE" FAKE_AUTH=false FAKE_ARGS_FILE="$ARGS_FILE" FAKE_STDIN_FILE="$STDIN_FILE" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$TMP/review.md" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "未認証が exit 2 で停止しない"
assert_contains "未認証メッセージ" "$OUT" "claude auth login"

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$REPO/review-logs" CLAUDE_BIN="$FAKE" FAKE_ARGS_FILE="$ARGS_FILE" FAKE_STDIN_FILE="$STDIN_FILE" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$TMP/review.md" --dry-run 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "repo 内ログ先を拒否しない"
assert_contains "repo 内ログ先メッセージ" "$OUT" "対象 repo 外"

printf '%s\n' '# repo packet' > "$REPO/review.md"
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/packet-log" CLAUDE_BIN="$FAKE" FAKE_ARGS_FILE="$ARGS_FILE" FAKE_STDIN_FILE="$STDIN_FILE" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$REPO/review.md" --dry-run 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "repo 内 review packet を拒否しない"
assert_contains "repo 内 packet メッセージ" "$OUT" "review packet は対象 repo 外"
rm "$REPO/review.md"

ln -s "$TMP/review.md" "$TMP/review-link.md"
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/symlink-log" CLAUDE_BIN="$FAKE" FAKE_ARGS_FILE="$ARGS_FILE" FAKE_STDIN_FILE="$STDIN_FILE" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$TMP/review-link.md" --dry-run 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "review packet symlink を拒否しない"
assert_contains "packet symlink message" "$OUT" "symlink は使えない"

set +e
OUT="$("${COMMON_ENV[@]}" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$TMP/review.md" --log "$REPO/review.log" --dry-run 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "repo 内 --log を拒否しない"
assert_contains "repo log override message" "$OUT" "対象 repo 外"

set +e
OUT="$("${COMMON_ENV[@]}" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$TMP/review.md" --out-result "$REPO/review.json" --dry-run 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "repo 内 --out-result を拒否しない"
assert_contains "repo result override message" "$OUT" "対象 repo 外"

OTHER_REPO="$TMP/other-repo"
mkdir -p "$OTHER_REPO"
git -C "$OTHER_REPO" init -q
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$OTHER_REPO/review-logs" CLAUDE_BIN="$FAKE" FAKE_ARGS_FILE="$ARGS_FILE" FAKE_STDIN_FILE="$STDIN_FILE" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$TMP/review.md" --dry-run 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "別 git worktree 内ログ先を拒否しない"
assert_contains "other worktree log message" "$OUT" "すべての git worktree 外"

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$REPO/clear-cooldown-log" CLAUDE_BIN="$FAKE" "$RUNNER" --clear-cooldown 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "--clear-cooldown が worktree 内ログ先を拒否しない"
assert_contains "clear cooldown worktree guard" "$OUT" "すべての git worktree 外"
[ ! -d "$REPO/clear-cooldown-log" ] && ok || ng "--clear-cooldown が拒否前に worktree 内ディレクトリを作成した"

MUTATE_LOG="$TMP/mutate-log"
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$MUTATE_LOG" CLAUDE_BIN="$FAKE" FAKE_MODE=mutate FAKE_ARGS_FILE="$ARGS_FILE" FAKE_STDIN_FILE="$STDIN_FILE" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$TMP/review.md" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 3 ] && ok || ng "reviewer の worktree 変更を exit 3 にしない"
[ "$(jq -r '.tree_changed' "$MUTATE_LOG/runs.jsonl")" = true ] && ok || ng "tree_changed=true が記録されない"
rm "$REPO/reviewer-created.txt"

MUTATE_FAIL_LOG="$TMP/mutate-fail-log"
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$MUTATE_FAIL_LOG" CLAUDE_BIN="$FAKE" FAKE_MODE=mutate_fail FAKE_ARGS_FILE="$ARGS_FILE" FAKE_STDIN_FILE="$STDIN_FILE" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$TMP/review.md" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 7 ] && ok || ng "tree change と Claude 非0時に Claude exit code を保持しない"
[ "$(jq -r '.tree_changed' "$MUTATE_FAIL_LOG/runs.jsonl")" = true ] && ok || ng "mutate_fail の tree_changed=true が記録されない"
rm "$REPO/reviewer-created.txt"

MENTION_LOG="$TMP/mention-log"
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$MENTION_LOG" CLAUDE_BIN="$FAKE" FAKE_MODE=result_mention FAKE_ARGS_FILE="$ARGS_FILE" FAKE_STDIN_FILE="$STDIN_FILE" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$TMP/review.md" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 1 ] && ok || ng "review 本文の limit 言及時に CLI exit code を保持しない"
[ ! -e "$MENTION_LOG/cooldowns.json" ] && ok || ng "review 本文の limit 言及を cooldown と誤検知した"

RAW_LIMIT_LOG="$TMP/raw-limit-log"
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$RAW_LIMIT_LOG" CLAUDE_BIN="$FAKE" FAKE_MODE=raw_limit FAKE_ARGS_FILE="$ARGS_FILE" FAKE_STDIN_FILE="$STDIN_FILE" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$TMP/review.md" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 1 ] && ok || ng "非JSON limit の CLI exit code を保持しない"
[ "$(jq -r '.claude.reason' "$RAW_LIMIT_LOG/cooldowns.json")" != null ] && ok || ng "非JSON stdout limit を cooldown に記録しない"

LIMIT_LOG="$TMP/limit-log"
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$LIMIT_LOG" CLAUDE_BIN="$FAKE" FAKE_MODE=limit FAKE_ARGS_FILE="$ARGS_FILE" FAKE_STDIN_FILE="$STDIN_FILE" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$TMP/review.md" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 1 ] && ok || ng "limit fake の exit code が保持されない"
[ "$(jq -r '.claude.reason' "$LIMIT_LOG/cooldowns.json")" != null ] && ok || ng "limit cooldown が記録されない"

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$LIMIT_LOG" CLAUDE_BIN="$FAKE" FAKE_ARGS_FILE="$ARGS_FILE" FAKE_STDIN_FILE="$STDIN_FILE" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$TMP/review.md" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "cooldown gate が実行を拒否しない"
assert_contains "cooldown message" "$OUT" "cooldown 中"
assert_contains "cooldown standard alternative needs explicit approval" "$OUT" "標準: 代替外部 AI にもタスク単位の明示承認が必要"
assert_contains "cooldown high blocks silent Sonnet fallback" "$OUT" "高: Opus 不可時に Sonnet へ黙って切り替えず"
assert_contains "cooldown critical keeps Fable blocker" "$OUT" "最重要: Fable 未実施を blocker として残す"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$LIMIT_LOG" CLAUDE_BIN="$FAKE" "$RUNNER" --cooldowns 2>&1)"
assert_contains "cooldown list" "$OUT" "[有効]"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$LIMIT_LOG" CLAUDE_BIN="$FAKE" "$RUNNER" --clear-cooldown 2>&1)"
assert_contains "cooldown clear" "$OUT" "claude を解除"
[ "$(jq -r '.claude // empty' "$LIMIT_LOG/cooldowns.json")" = "" ] && ok || ng "cooldown が解除されない"

COOLDOWN_SYMLINK_LOG="$TMP/cooldown-symlink-log"
mkdir -p "$COOLDOWN_SYMLINK_LOG"
printf '%s\n' '{"claude":{}}' > "$TMP/outside-cooldowns.json"
ln -s "$TMP/outside-cooldowns.json" "$COOLDOWN_SYMLINK_LOG/cooldowns.json"
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$COOLDOWN_SYMLINK_LOG" CLAUDE_BIN="$FAKE" "$RUNNER" --cooldowns 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "cooldowns.json symlink を exit 2 で拒否しない"
assert_contains "cooldowns.json symlink message" "$OUT" "cooldown JSON に symlink は使えない: $COOLDOWN_SYMLINK_LOG/cooldowns.json"

printf '%s\n' '{"claude":{"until":"2000-01-01T00:00:00Z","reason":"expired test"}}' > "$LIMIT_LOG/cooldowns.json"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$LIMIT_LOG" CLAUDE_BIN="$FAKE" "$RUNNER" --cooldowns 2>&1)"
assert_contains "expired cooldown list" "$OUT" "[期限切れ]"

printf '%s\n' '{broken' > "$LIMIT_LOG/cooldowns.json"
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$LIMIT_LOG" CLAUDE_BIN="$FAKE" FAKE_ARGS_FILE="$ARGS_FILE" FAKE_STDIN_FILE="$STDIN_FILE" "$RUNNER" --model sonnet --effort high --cd "$REPO" --prompt-file "$TMP/review.md" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "壊れた cooldown JSON を拒否しない"
assert_contains "broken cooldown message" "$OUT" "cooldown JSON が壊れている"

EVAL_LOG="$TMP/eval-log"
for EXTERNAL_AGENT in claude grok agy; do
  INVALID_EXTERNAL_LOG="$TMP/invalid-$EXTERNAL_AGENT-review-log"
  set +e
  OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$INVALID_EXTERNAL_LOG" "$LOGGER" --repo sample --task review --kind レビュー --agent "$EXTERNAL_AGENT" --model test-model --risk 標準 --outcome 採用 --validation pass --routing 適正 --cause none --run-id "run-$EXTERNAL_AGENT-none" --review-findings 0 --note ok 2>&1)"
  RC=$?
  set -e
  [ "$RC" -eq 2 ] && ok || ng "$EXTERNAL_AGENT 外部レビューの approval_basis=none を exit 2 で拒否しない"
  assert_contains "$EXTERNAL_AGENT external review requires approval basis" "$OUT" "--kind に関係なく --approval-basis explicit|standing が必須"
  [ ! -e "$INVALID_EXTERNAL_LOG/delegation-log.jsonl" ] && ok || ng "拒否した $EXTERNAL_AGENT none review をログへ記録した"
done

for CLAUDE_KIND in 調査 相談; do
  INVALID_CLAUDE_KIND_LOG="$TMP/invalid-claude-$CLAUDE_KIND-log"
  set +e
  OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$INVALID_CLAUDE_KIND_LOG" "$LOGGER" --repo sample --task mis-kind --kind "$CLAUDE_KIND" --agent claude --model sonnet --risk 標準 --outcome 採用 --validation pass --routing 適正 --cause none --note ok 2>&1)"
  RC=$?
  set -e
  [ "$RC" -eq 2 ] && ok || ng "Claude kind=$CLAUDE_KIND の approval_basis=none を exit 2 で拒否しない"
  assert_contains "Claude $CLAUDE_KIND cannot bypass approval basis" "$OUT" "--kind に関係なく --approval-basis explicit|standing が必須"
  [ ! -e "$INVALID_CLAUDE_KIND_LOG/delegation-log.jsonl" ] && ok || ng "拒否した Claude none $CLAUDE_KIND をログへ記録した"
done

OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$EVAL_LOG" "$LOGGER" --repo sample --task explicit-review --kind レビュー --agent claude --model sonnet --effort high --risk 標準 --outcome 採用 --validation pass --routing 適正 --cause none --approval-basis explicit --run-id run-sonnet-1 --review-findings 0 --note explicit-ok 2>&1)"
assert_contains "explicit approval log summary" "$OUT" "recorded:"
[ "$(tail -n 1 "$EVAL_LOG/delegation-log.jsonl" | jq -r '.orchestrator')" = codex ] && ok || ng "evaluation orchestrator が不正"
[ "$(tail -n 1 "$EVAL_LOG/delegation-log.jsonl" | jq -r '.review_findings')" = 0 ] && ok || ng "review_findings=0 が保持されない"
[ "$(tail -n 1 "$EVAL_LOG/delegation-log.jsonl" | jq -r '.approval_basis')" = explicit ] && ok || ng "explicit approval_basis が記録されない"
[ "$(tail -n 1 "$EVAL_LOG/delegation-log.jsonl" | jq -r '.effort')" = high ] && ok || ng "explicit effort=high が記録されない"

MISSING_EXPLICIT_RUN_LOG="$TMP/missing-explicit-run-log"
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$MISSING_EXPLICIT_RUN_LOG" "$LOGGER" --repo sample --task explicit-without-run --kind レビュー --agent claude --model opus --effort high --risk 高 --outcome 採用 --validation pass --routing 適正 --cause none --approval-basis explicit --note missing-run 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "成功した explicit Claude review の run_id 欠落を拒否しない"
assert_contains "successful explicit Claude requires run_id" "$OUT" "空でない --run-id が必須"
[ ! -e "$MISSING_EXPLICIT_RUN_LOG/delegation-log.jsonl" ] && ok || ng "run_id 欠落の成功Claude reviewを記録した"

CLAUDE_PRE_RUN_FAILURE_LOG="$TMP/claude-pre-run-failure-log"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$CLAUDE_PRE_RUN_FAILURE_LOG" "$LOGGER" --repo sample --task explicit-pre-run-failure --kind レビュー --agent claude --model opus --effort high --risk 高 --outcome 失敗 --validation not_run --routing 適正 --cause tooling --approval-basis explicit --note pre-run-failure 2>&1)"
assert_contains "pre-run Claude failure may omit run_id" "$OUT" "recorded:"

for EXTERNAL_AGENT in grok agy; do
  OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$EVAL_LOG" "$LOGGER" --repo sample --task "explicit-$EXTERNAL_AGENT-review" --kind レビュー --agent "$EXTERNAL_AGENT" --model test-model --effort high --risk 標準 --outcome 採用 --validation pass --routing 適正 --cause none --approval-basis explicit --run-id "run-$EXTERNAL_AGENT-explicit" --review-findings 0 --note explicit-ok 2>&1)"
  assert_contains "explicit $EXTERNAL_AGENT approval log summary" "$OUT" "recorded:"
  [ "$(tail -n 1 "$EVAL_LOG/delegation-log.jsonl" | jq -r '.agent')" = "$EXTERNAL_AGENT" ] && ok || ng "explicit $EXTERNAL_AGENT agent が記録されない"
  [ "$(tail -n 1 "$EVAL_LOG/delegation-log.jsonl" | jq -r '.approval_basis')" = explicit ] && ok || ng "explicit $EXTERNAL_AGENT approval_basis が記録されない"
done

OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$EVAL_LOG" "$LOGGER" --repo sample --task explicit-opus-review --kind レビュー --agent claude --model opus --effort high --risk 高 --outcome 採用 --validation pass --routing 適正 --cause none --approval-basis explicit --run-id run-opus-1 --note 'tier=高; task-specific approval' 2>&1)"
assert_contains "explicit opus approval log summary" "$OUT" "recorded:"
[ "$(tail -n 1 "$EVAL_LOG/delegation-log.jsonl" | jq -r '.model')" = opus ] && ok || ng "explicit opus model が記録されない"
[ "$(tail -n 1 "$EVAL_LOG/delegation-log.jsonl" | jq -r '.approval_basis')" = explicit ] && ok || ng "explicit opus approval_basis が記録されない"
[ "$(tail -n 1 "$EVAL_LOG/delegation-log.jsonl" | jq -r '.effort')" = high ] && ok || ng "explicit opus effort=high が記録されない"

OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$EVAL_LOG" "$LOGGER" --repo sample --task standing-review --kind レビュー --agent claude --model fable --effort high --risk 高 --outcome 採用 --validation pass --routing 適正 --cause none --approval-basis standing --run-id run-standing-1 --note 'tier=最重要; standing approval 使用; 送信対象カテゴリ=マスク済みテスト結果,対象diff' 2>&1)"
assert_contains "standing approval log summary" "$OUT" "recorded:"
[ "$(tail -n 1 "$EVAL_LOG/delegation-log.jsonl" | jq -r '.approval_basis')" = standing ] && ok || ng "standing approval_basis が記録されない"
[ "$(tail -n 1 "$EVAL_LOG/delegation-log.jsonl" | jq -r '.effort')" = high ] && ok || ng "standing effort=high が記録されない"
[ "$(tail -n 1 "$EVAL_LOG/delegation-log.jsonl" | jq -r '.run_id')" = run-standing-1 ] && ok || ng "standing run_id が記録されない"
[ "$(tail -n 1 "$EVAL_LOG/delegation-log.jsonl" | jq -r '.note')" = 'tier=最重要; standing approval 使用; 送信対象カテゴリ=マスク済みテスト結果,対象diff' ] && ok || ng "standing note に tier=最重要 が記録されない"

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/standing-missing-tier-log" "$LOGGER" --repo sample --task standing-missing-tier --kind レビュー --agent claude --model fable --effort high --risk 高 --outcome 失敗 --validation fail --routing 委任先ミス --cause instruction --approval-basis standing --run-id run-missing-tier --note 'standing approval 使用; 送信対象カテゴリ=対象diff' 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "standing approval の tier=最重要 欠落を exit 2 で拒否しない"
assert_contains "standing approval tier guard" "$OUT" "'tier=最重要' が必須"

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/note-lf-log" "$LOGGER" --repo sample --task note-lf --kind 相談 --agent self --model unknown --risk 低 --outcome 失敗 --validation fail --routing 適正 --cause instruction --approval-basis none --note $'通常の日本語; 維持\n二行目' 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "approval_basis=none の note LF を exit 2 で拒否しない"
assert_contains "note LF guard" "$OUT" "制御文字(CR/LF/TAB)は使えない"

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/note-cr-log" "$LOGGER" --repo sample --task note-cr --kind レビュー --agent claude --model opus --effort high --risk 高 --outcome 失敗 --validation fail --routing 適正 --cause instruction --approval-basis explicit --note $'explicit-ok\rsecond' 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "approval_basis=explicit の note CR を exit 2 で拒否しない"
assert_contains "note CR guard" "$OUT" "制御文字(CR/LF/TAB)は使えない"

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/note-tab-log" "$LOGGER" --repo sample --task note-tab --kind 相談 --agent self --model unknown --risk 低 --outcome 失敗 --validation fail --routing 適正 --cause instruction --note $'tab\tvalue' 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "note TAB を exit 2 で拒否しない"
assert_contains "note TAB guard" "$OUT" "制御文字(CR/LF/TAB)は使えない"

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/standing-newline-category-log" "$LOGGER" --repo sample --task standing-newline-category --kind レビュー --agent claude --model fable --effort high --risk 高 --outcome 失敗 --validation fail --routing 委任先ミス --cause instruction --approval-basis standing --run-id run-newline-category --note $'tier=最重要; standing approval 使用; 送信対象カテゴリ=対象diff\n本番ログ' 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "standing category 後の改行+未知カテゴリを exit 2 で拒否しない"
assert_contains "standing category newline guard" "$OUT" "制御文字(CR/LF/TAB)は使えない"

OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$EVAL_LOG" "$LOGGER" --repo sample --task explicit-fable-max --kind レビュー --agent claude --model fable --effort max --risk 高 --outcome 採用 --validation pass --routing 過剰 --cause none --approval-basis explicit --run-id run-fable-max --note explicit-max-ok 2>&1)"
assert_contains "explicit fable max log summary" "$OUT" "recorded:"
[ "$(tail -n 1 "$EVAL_LOG/delegation-log.jsonl" | jq -r '.approval_basis')" = explicit ] && ok || ng "fable max の explicit approval_basis が記録されない"
[ "$(tail -n 1 "$EVAL_LOG/delegation-log.jsonl" | jq -r '.effort')" = max ] && ok || ng "fable max の effort=max が記録されない"

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/standing-model-log" "$LOGGER" --repo sample --task invalid-model --kind レビュー --agent claude --model sonnet --effort high --risk 高 --outcome 失敗 --validation fail --routing 委任先ミス --cause instruction --approval-basis standing --run-id run-invalid-model --note 'tier=最重要; standing approval 使用; 送信対象カテゴリ=対象diff' 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "standing approval の不正 model を exit 2 で拒否しない"
assert_contains "standing approval model guard" "$OUT" "--model fable が必須"

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/standing-agent-log" "$LOGGER" --repo sample --task invalid-agent --kind レビュー --agent codex-native --model fable --effort high --risk 高 --outcome 失敗 --validation fail --routing 委任先ミス --cause instruction --approval-basis standing --run-id run-invalid-agent --note 'tier=最重要; standing approval 使用; 送信対象カテゴリ=対象diff' 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "standing approval の不正 agent を exit 2 で拒否しない"
assert_contains "standing approval agent guard" "$OUT" "--agent claude が必須"

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/standing-risk-log" "$LOGGER" --repo sample --task invalid-risk --kind レビュー --agent claude --model fable --effort high --risk 標準 --outcome 失敗 --validation fail --routing 委任先ミス --cause instruction --approval-basis standing --run-id run-invalid-risk --note 'tier=最重要; standing approval 使用; 送信対象カテゴリ=対象diff' 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "standing approval の不正 risk を exit 2 で拒否しない"
assert_contains "standing approval risk guard" "$OUT" "--risk 高 が必須"

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/standing-max-log" "$LOGGER" --repo sample --task invalid-max --kind レビュー --agent claude --model fable --effort max --risk 高 --outcome 失敗 --validation fail --routing 委任先ミス --cause instruction --approval-basis standing --run-id run-invalid-max --note 'tier=最重要; standing approval 使用; 送信対象カテゴリ=対象diff' 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "standing approval の effort=max を exit 2 で拒否しない"
assert_contains "standing approval max guard" "$OUT" "--effort high が必須"

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/standing-unknown-effort-log" "$LOGGER" --repo sample --task invalid-unknown-effort --kind レビュー --agent claude --model fable --risk 高 --outcome 失敗 --validation fail --routing 委任先ミス --cause instruction --approval-basis standing --run-id run-invalid-effort --note 'tier=最重要; standing approval 使用; 送信対象カテゴリ=対象diff' 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "standing approval の既定 effort=unknown を exit 2 で拒否しない"
assert_contains "standing approval unknown effort guard" "$OUT" "--effort high が必須"

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/invalid-effort-log" "$LOGGER" --repo sample --task invalid-effort-enum --kind 相談 --agent self --model unknown --effort ultra --risk 低 --outcome 失敗 --validation fail --routing 適正 --cause instruction --approval-basis none --note invalid-effort 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "規約外 effort を exit 2 で拒否しない"
assert_contains "effort enum guard" "$OUT" "--effort は unknown|low|medium|high|xhigh|max"

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/standing-note-log" "$LOGGER" --repo sample --task invalid-note --kind レビュー --agent claude --model fable --effort high --risk 高 --outcome 失敗 --validation fail --routing 委任先ミス --cause instruction --approval-basis standing --run-id run-invalid-note --note 'tier=最重要; standing approval 使用' 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "standing approval の note カテゴリ欠落を exit 2 で拒否しない"
assert_contains "standing approval note guard" "$OUT" "送信対象カテゴリ="

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/standing-empty-note-log" "$LOGGER" --repo sample --task empty-note --kind レビュー --agent claude --model fable --effort high --risk 高 --outcome 失敗 --validation fail --routing 委任先ミス --cause instruction --approval-basis standing --run-id run-empty-note --note 'tier=最重要; standing approval 使用; 送信対象カテゴリ=   ' 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "standing approval の空カテゴリを exit 2 で拒否しない"
assert_contains "standing approval empty categories guard" "$OUT" "送信対象カテゴリは空にできない"

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/standing-kind-log" "$LOGGER" --repo sample --task invalid-kind --kind 実装 --agent claude --model fable --effort high --risk 高 --outcome 失敗 --validation fail --routing 委任先ミス --cause instruction --approval-basis standing --run-id run-invalid-kind --note 'tier=最重要; standing approval 使用; 送信対象カテゴリ=対象diff' 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "standing approval の kind!=レビュー を exit 2 で拒否しない"
assert_contains "standing approval kind guard" "$OUT" "--kind レビュー が必須"

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/standing-run-id-log" "$LOGGER" --repo sample --task missing-run-id --kind レビュー --agent claude --model fable --effort high --risk 高 --outcome 失敗 --validation fail --routing 委任先ミス --cause instruction --approval-basis standing --note 'tier=最重要; standing approval 使用; 送信対象カテゴリ=対象diff' 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "standing approval の空 run-id を exit 2 で拒否しない"
assert_contains "standing approval run-id guard" "$OUT" "空でない --run-id が必須"

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/standing-whitespace-run-id-log" "$LOGGER" --repo sample --task whitespace-run-id --kind レビュー --agent claude --model fable --effort high --risk 高 --outcome 失敗 --validation fail --routing 委任先ミス --cause instruction --approval-basis standing --run-id '   ' --note 'tier=最重要; standing approval 使用; 送信対象カテゴリ=対象diff' 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "standing approval の空白 run-id を exit 2 で拒否しない"
assert_contains "standing approval whitespace run-id guard" "$OUT" "空でない --run-id が必須"

for BASIS in none explicit; do
  set +e
  OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/non-standing-marker-$BASIS" "$LOGGER" --repo sample --task invalid-marker --kind レビュー --agent claude --model fable --effort high --risk 高 --outcome 失敗 --validation fail --routing 委任先ミス --cause instruction --approval-basis "$BASIS" --run-id run-invalid-marker --note 'tier=最重要; standing approval 使用; 送信対象カテゴリ=対象diff' 2>&1)"
  RC=$?
  set -e
  [ "$RC" -eq 2 ] && ok || ng "approval_basis=$BASIS の standing marker を exit 2 で拒否しない"
  assert_contains "non-standing approval marker guard ($BASIS)" "$OUT" "--approval-basis standing のときだけ"
done

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/standing-unknown-category-log" "$LOGGER" --repo sample --task unknown-category --kind レビュー --agent claude --model fable --effort high --risk 高 --outcome 失敗 --validation fail --routing 委任先ミス --cause instruction --approval-basis standing --run-id run-unknown-category --note 'tier=最重要; standing approval 使用; 送信対象カテゴリ=対象diff,本番ログ' 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "standing approval の未知カテゴリを exit 2 で拒否しない"
assert_contains "standing approval unknown category guard" "$OUT" "送信対象カテゴリが規約外: 本番ログ"

for INVALID_CATEGORIES in ',対象diff' '対象diff,' '対象diff,,最小タスク要約' '対象diff,   ,最小タスク要約'; do
  set +e
  OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/standing-empty-element-log" "$LOGGER" --repo sample --task empty-category-element --kind レビュー --agent claude --model fable --effort high --risk 高 --outcome 失敗 --validation fail --routing 委任先ミス --cause instruction --approval-basis standing --run-id run-empty-element --note "tier=最重要; standing approval 使用; 送信対象カテゴリ=$INVALID_CATEGORIES" 2>&1)"
  RC=$?
  set -e
  [ "$RC" -eq 2 ] && ok || ng "standing approval の空カテゴリ要素 ($INVALID_CATEGORIES) を exit 2 で拒否しない"
  assert_contains "standing approval empty category element guard ($INVALID_CATEGORIES)" "$OUT" "送信対象カテゴリに空要素は使えない"
done

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/standing-duplicate-category-log" "$LOGGER" --repo sample --task duplicate-category --kind レビュー --agent claude --model fable --effort high --risk 高 --outcome 失敗 --validation fail --routing 委任先ミス --cause instruction --approval-basis standing --run-id run-duplicate-category --note 'tier=最重要; standing approval 使用; 送信対象カテゴリ=対象diff,最小タスク要約,対象diff' 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "standing approval の重複カテゴリを exit 2 で拒否しない"
assert_contains "standing approval duplicate category guard" "$OUT" "送信対象カテゴリは重複できない: 対象diff"

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/standing-multiple-marker-log" "$LOGGER" --repo sample --task multiple-marker --kind レビュー --agent claude --model fable --effort high --risk 高 --outcome 失敗 --validation fail --routing 委任先ミス --cause instruction --approval-basis standing --run-id run-multiple-marker --note 'tier=最重要; standing approval 使用; 送信対象カテゴリ=対象diff; 送信対象カテゴリ=最小タスク要約' 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "standing approval の複数カテゴリ marker を exit 2 で拒否しない"
assert_contains "standing approval multiple category marker guard" "$OUT" "'送信対象カテゴリ=' は1回だけ"

set +e
OUT="$(cd "$TMP" && env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR=relative-eval-log "$LOGGER" --repo sample --task relative --kind 相談 --agent self --model unknown --risk 低 --outcome 失敗 --validation not_run --routing 適正 --cause tooling --note relative 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "delegate-log が相対 LOG_DIR を exit 2 で拒否しない"
assert_contains "delegate-log relative log dir" "$OUT" "DELEGATE_CODEX_LOG_DIR は絶対パス"
[ ! -e "$TMP/relative-eval-log" ] && ok || ng "delegate-log が相対 LOG_DIR を作成した"

LOGGER_MKDIR_BLOCKER="$TMP/logger-mkdir-blocker"
printf '%s\n' blocker > "$LOGGER_MKDIR_BLOCKER"
set +e
OUT="$(env LC_ALL=C HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$LOGGER_MKDIR_BLOCKER/logs" "$LOGGER" --repo sample --task mkdir --kind 相談 --agent self --model unknown --risk 低 --outcome 失敗 --validation fail --routing 適正 --cause tooling --note mkdir 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "delegate-log mkdir 失敗を exit 2 にしない"
assert_contains "delegate-log mkdir OS error" "$OUT" "Not a directory"
assert_contains "delegate-log mkdir escalation guidance" "$OUT" "同一コマンドを sandbox escalation"

OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$EVAL_LOG" "$LOGGER" --repo sample --task investigate --kind 調査 --agent codex-native --model gpt-test --risk 低 --outcome 採用 --validation pass --routing 適正 --cause none --note '通常の日本語; semicolon維持' 2>&1)"
assert_contains "codex-native log summary" "$OUT" "recorded:"
[ "$(tail -n 1 "$EVAL_LOG/delegation-log.jsonl" | jq -r '.agent')" = codex-native ] && ok || ng "codex-native が記録されない"
[ "$(tail -n 1 "$EVAL_LOG/delegation-log.jsonl" | jq -r '.approval_basis')" = none ] && ok || ng "codex-native の省略 approval_basis が none でない"
[ "$(tail -n 1 "$EVAL_LOG/delegation-log.jsonl" | jq -r '.effort')" = unknown ] && ok || ng "codex-native の省略 effort が unknown でない"
[ "$(tail -n 1 "$EVAL_LOG/delegation-log.jsonl" | jq -r '.note')" = '通常の日本語; semicolon維持' ] && ok || ng "日本語/semicolon note が保持されない"

OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$EVAL_LOG" "$LOGGER" --repo sample --task direct --kind 相談 --agent self --model unknown --risk 低 --outcome 採用 --validation not_run --routing 適正 --cause none --note self-ok 2>&1)"
assert_contains "self log summary" "$OUT" "recorded:"
[ "$(tail -n 1 "$EVAL_LOG/delegation-log.jsonl" | jq -r '.agent')" = self ] && ok || ng "self が記録されない"
[ "$(tail -n 1 "$EVAL_LOG/delegation-log.jsonl" | jq -r '.approval_basis')" = none ] && ok || ng "self の省略 approval_basis が none でない"
[ "$(tail -n 1 "$EVAL_LOG/delegation-log.jsonl" | jq -r '.effort')" = unknown ] && ok || ng "self の省略 effort が unknown でない"

EVAL_SYMLINK_LOG="$TMP/eval-symlink-log"
mkdir -p "$EVAL_SYMLINK_LOG"
printf '%s\n' outside > "$TMP/outside-delegation-log.jsonl"
ln -s "$TMP/outside-delegation-log.jsonl" "$EVAL_SYMLINK_LOG/delegation-log.jsonl"
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$EVAL_SYMLINK_LOG" "$LOGGER" --repo sample --task symlink --kind 相談 --agent self --model unknown --risk 低 --outcome 失敗 --validation fail --routing 適正 --cause tooling --note symlink 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "delegate-log symlink を exit 2 で拒否しない"
assert_contains "delegate-log symlink message" "$OUT" "委任評価ログに symlink は使えない: $EVAL_SYMLINK_LOG/delegation-log.jsonl"
[ "$(cat "$TMP/outside-delegation-log.jsonl")" = outside ] && ok || ng "delegate-log symlink 先を変更した"

EVAL_APPEND_FAIL_LOG="$TMP/eval-append-fail-log"
mkdir -p "$EVAL_APPEND_FAIL_LOG/delegation-log.jsonl"
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$EVAL_APPEND_FAIL_LOG" "$LOGGER" --repo sample --task direct --kind 相談 --agent self --model unknown --risk 低 --outcome 失敗 --validation fail --routing 適正 --cause tooling --note append-fail 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "delegate-log 追記失敗を exit 2 にしない"
assert_contains "delegate-log append failure path" "$OUT" "delegate-log: ERROR: ログ追記に失敗: $EVAL_APPEND_FAIL_LOG/delegation-log.jsonl"
assert_contains "delegate-log append escalation guidance" "$OUT" "同一コマンドを sandbox escalation"

set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$REPO/eval-log" "$LOGGER" --repo sample --task review --kind レビュー --agent claude --model fable --effort high --risk 高 --outcome 採用 --validation pass --routing 適正 --cause none --approval-basis explicit --run-id run-worktree-blocked --note blocked 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "delegate-log が repo 内ログ先を拒否しない"
assert_contains "delegate-log repo guard" "$OUT" "git worktree 外"
[ ! -d "$REPO/eval-log" ] && ok || ng "拒否前に repo 内ログディレクトリを作成した"
[ ! -e "$REPO/eval-log/delegation-log.jsonl" ] && ok || ng "repo 内に delegation-log.jsonl を作成した"

ID_ONLY_LOG="$TMP/id-only-log"
TASK_ID="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$ID_ONLY_LOG" "$LOGGER" --new-task-id)"
DELEGATION_ID="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$ID_ONLY_LOG" "$LOGGER" --new-delegation-id)"
case "$TASK_ID" in task_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]_[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ok ;; *) ng "task ID 形式が不正: $TASK_ID" ;; esac
case "$DELEGATION_ID" in del_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]_[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ok ;; *) ng "delegation ID 形式が不正: $DELEGATION_ID" ;; esac
[ ! -e "$ID_ONLY_LOG" ] && ok || ng "ID生成がログディレクトリへ触れた"

SUMMARY_V2_LOG="$TMP/summary-v2-log"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$SUMMARY_V2_LOG" "$LOGGER" --repo sample --task summary-v2 --task-id "$TASK_ID" --kind 実装 --agent codex-native --model gpt-test --risk 低 --outcome 採用 --validation pass --routing 適正 --cause none --note compatible 2>&1)"
assert_contains "summary v2 recorded" "$OUT" "recorded:"
SUMMARY_V2="$(tail -n 1 "$SUMMARY_V2_LOG/delegation-log.jsonl")"
[ "$(printf '%s' "$SUMMARY_V2" | jq -r '.schema_version')" = 2 ] && ok || ng "summary schema_version=2 がない"
[ "$(printf '%s' "$SUMMARY_V2" | jq -r '.record_type')" = task_summary ] && ok || ng "summary record_type が不正"
[ "$(printf '%s' "$SUMMARY_V2" | jq -r '.task_id')" = "$TASK_ID" ] && ok || ng "summary task_id が保持されない"
[ "$(printf '%s' "$SUMMARY_V2" | jq -r '.kind,.agent,.routing_verdict' | tr '\n' ' ')" = '実装 codex-native 適正 ' ] && ok || ng "summary の既存 field が保持されない"
[ "$(printf '%s' "$SUMMARY_V2" | jq -r '.required_model,.actual_model,.review_status' | tr '\n' ' ')" = 'none none skipped_low_risk ' ] && ok || ng "summary routing model fields の低risk派生が不正"
case "$(printf '%s' "$SUMMARY_V2" | jq -r '.timestamp')" in ????-??-??T??:??:??Z) ok ;; *) ng "summary timestamp が UTC ISO でない" ;; esac

ROUTING_LOG="$TMP/routing-log"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$ROUTING_LOG" "$LOGGER" --repo sample --task standard-claude --kind レビュー --agent claude --model sonnet --effort high --risk 標準 --outcome 採用 --validation pass --routing 適正 --cause none --approval-basis explicit --run-id run-routing-sonnet --required-model sonnet --actual-model sonnet --review-status completed 2>&1)"
assert_contains "explicit routing fields accepted" "$OUT" "recorded:"
[ "$(tail -n 1 "$ROUTING_LOG/delegation-log.jsonl" | jq -r '.required_model,.actual_model,.review_status' | tr '\n' ' ')" = 'sonnet sonnet completed ' ] && ok || ng "explicit routing fields が記録されない"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$ROUTING_LOG" "$LOGGER" --repo sample --task high-opus-absent --kind 実装 --agent codex-native --model unknown --risk 高 --outcome 採用 --validation pass --routing 過小 --cause none 2>&1)"
assert_contains "high opus absent may be adopted" "$OUT" "recorded:"
[ "$(tail -n 1 "$ROUTING_LOG/delegation-log.jsonl" | jq -r '.required_model,.actual_model,.review_status,.routing_verdict' | tr '\n' ' ')" = 'opus none blocked_approval 過小 ' ] && ok || ng "high opus absent routing derivation が不正"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$ROUTING_LOG" "$LOGGER" --repo sample --task low-extra-claude --kind レビュー --agent claude --model sonnet --effort high --risk 低 --outcome 採用 --validation pass --routing 過剰 --cause none --approval-basis explicit --run-id run-routing-extra 2>&1)"
assert_contains "required none actual external is over" "$OUT" "recorded:"
[ "$(tail -n 1 "$ROUTING_LOG/delegation-log.jsonl" | jq -r '.required_model,.actual_model,.review_status,.routing_verdict' | tr '\n' ' ')" = 'none sonnet completed 過剰 ' ] && ok || ng "required none actual external routing が不正"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$ROUTING_LOG" "$LOGGER" --repo sample --task critical-absent --kind 実装 --agent codex-native --model unknown --risk 高 --outcome 未完了 --validation not_run --routing 過小 --cause tooling --note 'tier=最重要' 2>&1)"
assert_contains "critical fable absent incomplete recorded" "$OUT" "recorded:"
[ "$(tail -n 1 "$ROUTING_LOG/delegation-log.jsonl" | jq -r '.required_model,.actual_model,.review_status,.routing_verdict' | tr '\n' ' ')" = 'fable none blocked_approval 過小 ' ] && ok || ng "critical fable absent routing derivation が不正"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$ROUTING_LOG" "$LOGGER" --repo sample --task critical-lower-opus --kind レビュー --agent claude --model opus --effort high --risk 高 --outcome 未完了 --validation not_run --routing 過小 --cause tooling --approval-basis explicit --note 'tier=最重要' 2>&1)"
assert_contains "critical lower opus incomplete recorded" "$OUT" "recorded:"
[ "$(tail -n 1 "$ROUTING_LOG/delegation-log.jsonl" | jq -r '.required_model,.actual_model,.review_status,.routing_verdict' | tr '\n' ' ')" = 'fable opus completed 過小 ' ] && ok || ng "critical lower opus routing derivation が不正"
for ROUTING_REJECT in required actual status routing critical_outcome critical_lower_outcome; do
  set +e
  case "$ROUTING_REJECT" in
    required) OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/routing-reject-required" "$LOGGER" --repo sample --task reject --kind レビュー --agent claude --model sonnet --effort high --risk 標準 --outcome 採用 --validation pass --routing 適正 --cause none --approval-basis explicit --run-id run-reject-required --required-model opus 2>&1)" ;;
    actual) OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/routing-reject-actual" "$LOGGER" --repo sample --task reject --kind レビュー --agent claude --model sonnet --effort high --risk 標準 --outcome 採用 --validation pass --routing 適正 --cause none --approval-basis explicit --run-id run-reject-actual --actual-model opus 2>&1)" ;;
    status) OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/routing-reject-status" "$LOGGER" --repo sample --task reject --kind レビュー --agent claude --model sonnet --effort high --risk 標準 --outcome 採用 --validation pass --routing 適正 --cause none --approval-basis explicit --run-id run-reject-status --review-status blocked_approval 2>&1)" ;;
    routing) OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/routing-reject-routing" "$LOGGER" --repo sample --task reject --kind 実装 --agent codex-native --model unknown --risk 標準 --outcome 採用 --validation pass --routing 適正 --cause none 2>&1)" ;;
    critical_outcome) OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/routing-reject-critical" "$LOGGER" --repo sample --task reject --kind 実装 --agent codex-native --model unknown --risk 高 --outcome 採用 --validation pass --routing 過小 --cause none --note 'tier=最重要' 2>&1)" ;;
    critical_lower_outcome) OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$TMP/routing-reject-critical-lower" "$LOGGER" --repo sample --task reject --kind レビュー --agent claude --model opus --effort high --risk 高 --outcome 採用 --validation pass --routing 過小 --cause none --approval-basis explicit --run-id run-critical-lower --note 'tier=最重要' 2>&1)" ;;
  esac
  RC=$?
  set -e
  [ "$RC" -eq 2 ] && ok || ng "routing contradiction $ROUTING_REJECT を拒否しない"
  case "$ROUTING_REJECT" in
    required) assert_contains "required contradiction message" "$OUT" "--required-model が派生routingと矛盾" ;;
    actual) assert_contains "actual contradiction message" "$OUT" "--actual-model が --agent/--model と矛盾" ;;
    status) assert_contains "status contradiction message" "$OUT" "--review-status が派生routingと矛盾" ;;
    routing) assert_contains "routing contradiction message" "$OUT" "--routing が review model routing と矛盾" ;;
    critical_outcome) assert_contains "critical absent outcome message" "$OUT" "最重要 fable review 欠落または下位review時" ;;
    critical_lower_outcome) assert_contains "critical lower outcome message" "$OUT" "最重要 fable review 欠落または下位review時" ;;
  esac
done
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$ROUTING_LOG" "$LOGGER" --audit-routing 2>&1)"
assert_contains "routing audit clean" "$OUT" "issues=0"

EVENT_LOG="$TMP/event-log"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$EVENT_LOG" "$LOGGER" --event dispatched --repo sample --task event-flow --task-id "$TASK_ID" --delegation-id "$DELEGATION_ID" --subagent-role worker_v2 --agent-task-name /root/worker_v2 --ownership 'bin/delegate-log, tests' --attempt 1 --agent codex-native 2>&1)"
assert_contains "dispatched event recorded" "$OUT" "recorded:"
DISPATCHED="$(tail -n 1 "$EVENT_LOG/delegation-log.jsonl")"
[ "$(printf '%s' "$DISPATCHED" | jq -r '.record_type,.event,.outcome,.validation,.model,.effort,.approval_basis' | tr '\n' ' ')" = 'delegation_event dispatched 未完了 not_run unknown unknown none ' ] && ok || ng "dispatched event の既定値が不正"
[ "$(printf '%s' "$DISPATCHED" | jq -r '.ownership')" = 'bin/delegate-log, tests' ] && ok || ng "dispatched ownership が保持されない"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$EVENT_LOG" "$LOGGER" --record-type delegation_event --event followup --repo sample --task event-flow --task-id "$TASK_ID" --delegation-id "$DELEGATION_ID" --parent-delegation-id del_parent --subagent-role worker_v2 --agent-task-name /root/worker_v2 --attempt 2 --agent codex-native --note retry 2>&1)"
assert_contains "followup event recorded" "$OUT" "recorded:"
[ "$(tail -n 1 "$EVENT_LOG/delegation-log.jsonl" | jq -r '.parent_delegation_id,.attempt' | tr '\n' ' ')" = 'del_parent 2 ' ] && ok || ng "followup field が保持されない"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$EVENT_LOG" "$LOGGER" --event completed --repo sample --task event-flow --task-id "$TASK_ID" --delegation-id "$DELEGATION_ID" --subagent-role worker_v2 --agent-task-name /root/worker_v2 --attempt 2 --agent codex-native --outcome 採用 --validation pass 2>&1)"
assert_contains "completed event recorded" "$OUT" "recorded:"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$EVENT_LOG" "$LOGGER" --repo sample --task event-flow --task-id "$TASK_ID" --kind 実装 --agent codex-native --model unknown --risk 低 --outcome 採用 --validation pass --routing 適正 --cause none 2>&1)"
assert_contains "event task summary recorded" "$OUT" "recorded:"
BEFORE_EVENT_AUDIT_CKSUM="$(cksum "$EVENT_LOG/delegation-log.jsonl")"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$EVENT_LOG" "$LOGGER" --audit-delegations 2>&1)"
assert_contains "healthy delegation audit" "$OUT" "issues=0"
[ "$BEFORE_EVENT_AUDIT_CKSUM" = "$(cksum "$EVENT_LOG/delegation-log.jsonl")" ] && ok || ng "delegation audit がログを変更した"

FAILED_ID="$(env HOME="$HOME_DIR" "$LOGGER" --new-delegation-id)"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$EVENT_LOG" "$LOGGER" --event dispatched --repo sample --task failed-flow --task-id "$TASK_ID" --delegation-id "$FAILED_ID" --subagent-role explorer --agent-task-name /root/explorer --ownership read-only --attempt 1 --agent codex-native 2>&1)"
assert_contains "failed flow dispatched" "$OUT" "recorded:"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$EVENT_LOG" "$LOGGER" --event failed --repo sample --task failed-flow --task-id "$TASK_ID" --delegation-id "$FAILED_ID" --subagent-role explorer --agent-task-name /root/explorer --attempt 1 --agent codex-native --outcome 失敗 --validation fail --cause tooling 2>&1)"
assert_contains "failed event recorded" "$OUT" "recorded:"

LIFECYCLE_LOG="$TMP/lifecycle-log"
LIFE_TASK="task_lifecycle"
LIFE_ID="del_lifecycle"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$LIFECYCLE_LOG" "$LOGGER" --event dispatched --repo sample --task lifecycle --task-id "$LIFE_TASK" --delegation-id "$LIFE_ID" --subagent-role worker --agent-task-name /root/life --ownership files --attempt 1 --agent codex-native 2>&1)"
assert_contains "lifecycle dispatch recorded" "$OUT" "recorded:"
LIFE_LINES="$(wc -l < "$LIFECYCLE_LOG/delegation-log.jsonl" | tr -d ' ')"
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$LIFECYCLE_LOG" "$LOGGER" --event dispatched --repo sample --task lifecycle --task-id "$LIFE_TASK" --delegation-id "$LIFE_ID" --subagent-role worker --agent-task-name /root/life --ownership files --attempt 1 --agent codex-native 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "duplicate dispatch をrecord-timeで拒否しない"
assert_contains "duplicate dispatch issue" "$OUT" "duplicate_dispatch"
[ "$LIFE_LINES" = "$(wc -l < "$LIFECYCLE_LOG/delegation-log.jsonl" | tr -d ' ')" ] && ok || ng "duplicate dispatch拒否で行数が変化した"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$LIFECYCLE_LOG" "$LOGGER" --event completed --repo sample --task lifecycle --task-id "$LIFE_TASK" --delegation-id "$LIFE_ID" --subagent-role worker --agent-task-name /root/life --attempt 1 --agent codex-native --outcome 採用 --validation pass 2>&1)"
assert_contains "lifecycle terminal recorded" "$OUT" "recorded:"
LIFE_LINES="$(wc -l < "$LIFECYCLE_LOG/delegation-log.jsonl" | tr -d ' ')"
for LIFECYCLE_REJECT in followup_after_terminal terminal_after_terminal; do
  set +e
  if [ "$LIFECYCLE_REJECT" = followup_after_terminal ]; then
    OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$LIFECYCLE_LOG" "$LOGGER" --event followup --repo sample --task lifecycle --task-id "$LIFE_TASK" --delegation-id "$LIFE_ID" --subagent-role worker --agent-task-name /root/life --attempt 2 --agent codex-native 2>&1)"
  else
    OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$LIFECYCLE_LOG" "$LOGGER" --event failed --repo sample --task lifecycle --task-id "$LIFE_TASK" --delegation-id "$LIFE_ID" --subagent-role worker --agent-task-name /root/life --attempt 2 --agent codex-native --outcome 失敗 --validation fail --cause tooling 2>&1)"
  fi
  RC=$?
  set -e
  [ "$RC" -eq 2 ] && ok || ng "$LIFECYCLE_REJECT をrecord-timeで拒否しない"
  assert_contains "$LIFECYCLE_REJECT issue" "$OUT" "$LIFECYCLE_REJECT"
  [ "$LIFE_LINES" = "$(wc -l < "$LIFECYCLE_LOG/delegation-log.jsonl" | tr -d ' ')" ] && ok || ng "$LIFECYCLE_REJECT 拒否で行数が変化した"
done
for LIFECYCLE_REJECT in followup_without_dispatch terminal_without_dispatch failed_without_dispatch; do
  REJECT_LOG="$TMP/$LIFECYCLE_REJECT"
  set +e
  case "$LIFECYCLE_REJECT" in
    followup_without_dispatch) OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$REJECT_LOG" "$LOGGER" --event followup --repo sample --task lifecycle --task-id task_x --delegation-id del_x --subagent-role worker --agent-task-name /root/x --attempt 2 --agent codex-native 2>&1)" ;;
    terminal_without_dispatch) OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$REJECT_LOG" "$LOGGER" --event completed --repo sample --task lifecycle --task-id task_x --delegation-id del_x --subagent-role worker --agent-task-name /root/x --attempt 1 --agent codex-native --outcome 採用 --validation pass 2>&1)" ;;
    failed_without_dispatch) OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$REJECT_LOG" "$LOGGER" --event failed --repo sample --task lifecycle --task-id task_x --delegation-id del_x --subagent-role worker --agent-task-name /root/x --attempt 1 --agent codex-native --outcome 失敗 --validation fail --cause tooling 2>&1)" ;;
  esac
  RC=$?
  set -e
  [ "$RC" -eq 2 ] && ok || ng "$LIFECYCLE_REJECT をrecord-timeで拒否しない"
  case "$LIFECYCLE_REJECT" in failed_without_dispatch) assert_contains "$LIFECYCLE_REJECT issue" "$OUT" "terminal_without_dispatch" ;; *) assert_contains "$LIFECYCLE_REJECT issue" "$OUT" "$LIFECYCLE_REJECT" ;; esac
  [ ! -e "$REJECT_LOG/delegation-log.jsonl" ] && ok || ng "$LIFECYCLE_REJECT 拒否でログが作成された"
done
INDEPENDENT_ID="del_lifecycle_other"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$LIFECYCLE_LOG" "$LOGGER" --event dispatched --repo sample --task lifecycle2 --task-id task_lifecycle2 --delegation-id "$INDEPENDENT_ID" --subagent-role worker --agent-task-name /root/life2 --ownership files --attempt 1 --agent codex-native 2>&1)"
assert_contains "independent delegation dispatch recorded" "$OUT" "recorded:"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$LIFECYCLE_LOG" "$LOGGER" --event completed --repo sample --task lifecycle2 --task-id task_lifecycle2 --delegation-id "$INDEPENDENT_ID" --subagent-role worker --agent-task-name /root/life2 --attempt 1 --agent codex-native --outcome 採用 --validation pass 2>&1)"
assert_contains "independent delegation terminal recorded" "$OUT" "recorded:"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$LIFECYCLE_LOG" "$LOGGER" --repo sample --task lifecycle2 --task-id task_lifecycle2 --kind 実装 --agent codex-native --model unknown --risk 低 --outcome 採用 --validation pass --routing 適正 --cause none 2>&1)"
assert_contains "independent delegation summary recorded" "$OUT" "recorded:"

CONCURRENCY_LOG="$TMP/concurrency-log"
CONCURRENCY_OUT1="$TMP/concurrency-1.out"
CONCURRENCY_OUT2="$TMP/concurrency-2.out"
set +e
env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$CONCURRENCY_LOG" "$LOGGER" --event dispatched --repo sample --task concurrent --task-id task_concurrent --delegation-id del_concurrent --subagent-role worker --agent-task-name /root/c1 --ownership files --attempt 1 --agent codex-native >"$CONCURRENCY_OUT1" 2>&1 &
PID1=$!
env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$CONCURRENCY_LOG" "$LOGGER" --event dispatched --repo sample --task concurrent --task-id task_concurrent --delegation-id del_concurrent --subagent-role worker --agent-task-name /root/c2 --ownership files --attempt 1 --agent codex-native >"$CONCURRENCY_OUT2" 2>&1 &
PID2=$!
wait "$PID1"; RC1=$?
wait "$PID2"; RC2=$?
set -e
if { [ "$RC1" -eq 0 ] && [ "$RC2" -eq 2 ]; } || { [ "$RC1" -eq 2 ] && [ "$RC2" -eq 0 ]; }; then ok; else ng "同一ID並行dispatchの成功/拒否数が不正: $RC1/$RC2"; fi
[ "$(wc -l < "$CONCURRENCY_LOG/delegation-log.jsonl" | tr -d ' ')" = 1 ] && ok || ng "同一ID並行dispatchで行数が1にならない"

LOCK_LIVE_LOG="$TMP/lock-live-log"
mkdir -p "$LOCK_LIVE_LOG/delegation-log.jsonl.lock"
printf '%s\n%s\n' "$$" "$(date +%s)" > "$LOCK_LIVE_LOG/delegation-log.jsonl.lock/owner"
LOCK_LIVE_OUT="$TMP/lock-live.out"
env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$LOCK_LIVE_LOG" "$LOGGER" --event dispatched --repo sample --task lock-live --task-id task_lock_live --delegation-id del_lock_live --subagent-role worker --agent-task-name /root/lock-live --ownership files --attempt 1 --agent codex-native >"$LOCK_LIVE_OUT" 2>&1 &
LOCK_LIVE_PID=$!
sleep 0.2
[ -d "$LOCK_LIVE_LOG/delegation-log.jsonl.lock" ] && ok || ng "live owner lock をstaleとして削除した"
[ ! -e "$LOCK_LIVE_LOG/delegation-log.jsonl" ] && ok || ng "live owner lock 中にログを書き込んだ"
rm -f "$LOCK_LIVE_LOG/delegation-log.jsonl.lock/owner"
rmdir "$LOCK_LIVE_LOG/delegation-log.jsonl.lock"
wait "$LOCK_LIVE_PID"
assert_contains "live lock waiter eventually records" "$(cat "$LOCK_LIVE_OUT")" "recorded:"

LOCK_MISSING_OWNER="$TMP/lock-missing-owner"
mkdir -p "$LOCK_MISSING_OWNER/delegation-log.jsonl.lock"
touch -t 200001010000 "$LOCK_MISSING_OWNER/delegation-log.jsonl.lock"
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$LOCK_MISSING_OWNER" "$LOGGER" --event dispatched --repo sample --task lock-missing --task-id task_lock_missing --delegation-id del_lock_missing --subagent-role worker --agent-task-name /root/lock-missing --ownership files --attempt 1 --agent codex-native 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "ownerなし既存lockをfail-closedしない"
assert_contains "missing owner lock fail closed" "$OUT" "既存lockは自動削除しない"
[ -d "$LOCK_MISSING_OWNER/delegation-log.jsonl.lock" ] && ok || ng "ownerなし既存lockを削除した"
[ ! -e "$LOCK_MISSING_OWNER/delegation-log.jsonl" ] && ok || ng "ownerなし既存lock中にログを書き込んだ"

LOCK_DEAD_OWNER="$TMP/lock-dead-owner"
mkdir -p "$LOCK_DEAD_OWNER/delegation-log.jsonl.lock"
printf '%s\n%s\n' "999999" "946684800" > "$LOCK_DEAD_OWNER/delegation-log.jsonl.lock/owner"
touch -t 200001010000 "$LOCK_DEAD_OWNER/delegation-log.jsonl.lock/owner" "$LOCK_DEAD_OWNER/delegation-log.jsonl.lock"
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$LOCK_DEAD_OWNER" "$LOGGER" --event dispatched --repo sample --task lock-dead --task-id task_lock_dead --delegation-id del_lock_dead --subagent-role worker --agent-task-name /root/lock-dead --ownership files --attempt 1 --agent codex-native 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "dead owner既存lockをfail-closedしない"
assert_contains "dead owner lock fail closed" "$OUT" "既存lockは自動削除しない"
[ -d "$LOCK_DEAD_OWNER/delegation-log.jsonl.lock" ] && ok || ng "dead owner既存lockを削除した"
[ -e "$LOCK_DEAD_OWNER/delegation-log.jsonl.lock/owner" ] && ok || ng "dead owner lock ownerを削除した"
[ ! -e "$LOCK_DEAD_OWNER/delegation-log.jsonl" ] && ok || ng "dead owner既存lock中にログを書き込んだ"

for INVALID_EVENT_CASE in \
  "dispatched missing-ownership" \
  "dispatched bad-attempt" \
  "followup bad-attempt" \
  "completed missing-terminal-fields" \
  "failed cause-none" \
  "self self-agent" \
  "badrole bad-role"; do
  EVENT_NAME="${INVALID_EVENT_CASE%% *}"
  EVENT_CASE="${INVALID_EVENT_CASE#* }"
  INVALID_EVENT_LOG="$TMP/invalid-event-$EVENT_CASE"
  EVENT_ARGS=(--event dispatched --repo sample --task invalid --task-id "$TASK_ID" --delegation-id "$DELEGATION_ID" --subagent-role worker --agent-task-name /root/invalid --ownership bin/x --attempt 1 --agent codex-native)
  case "$EVENT_CASE" in
    missing-ownership) EVENT_ARGS=(--event dispatched --repo sample --task invalid --task-id "$TASK_ID" --delegation-id "$DELEGATION_ID" --subagent-role worker --agent-task-name /root/invalid --attempt 1 --agent codex-native) ;;
    bad-attempt)
      if [ "$EVENT_NAME" = followup ]; then INVALID_ATTEMPT=1; else INVALID_ATTEMPT=2; fi
      EVENT_ARGS=(--event "$EVENT_NAME" --repo sample --task invalid --task-id "$TASK_ID" --delegation-id "$DELEGATION_ID" --subagent-role worker --agent-task-name /root/invalid --ownership bin/x --attempt "$INVALID_ATTEMPT" --agent codex-native)
      ;;
    missing-terminal-fields) EVENT_ARGS=(--event completed --repo sample --task invalid --task-id "$TASK_ID" --delegation-id "$DELEGATION_ID" --subagent-role worker --agent-task-name /root/invalid --attempt 1 --agent codex-native) ;;
    cause-none) EVENT_ARGS=(--event failed --repo sample --task invalid --task-id "$TASK_ID" --delegation-id "$DELEGATION_ID" --subagent-role worker --agent-task-name /root/invalid --attempt 1 --agent codex-native --outcome 失敗 --validation fail --cause none) ;;
    self-agent) EVENT_ARGS=(--event dispatched --repo sample --task invalid --task-id "$TASK_ID" --delegation-id "$DELEGATION_ID" --subagent-role worker --agent-task-name /root/invalid --ownership bin/x --attempt 1 --agent self) ;;
    bad-role) EVENT_ARGS=(--event dispatched --repo sample --task invalid --task-id "$TASK_ID" --delegation-id "$DELEGATION_ID" --subagent-role 'worker role' --agent-task-name /root/invalid --ownership bin/x --attempt 1 --agent codex-native) ;;
  esac
  set +e
  OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$INVALID_EVENT_LOG" "$LOGGER" "${EVENT_ARGS[@]}" 2>&1)"
  RC=$?
  set -e
  [ "$RC" -eq 2 ] && ok || ng "invalid event branch を拒否しない: $EVENT_CASE"
  [ ! -e "$INVALID_EVENT_LOG/delegation-log.jsonl" ] && ok || ng "invalid event を記録した: $EVENT_CASE"
done

EVENT_EXTERNAL_LOG="$TMP/event-external-log"
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$EVENT_EXTERNAL_LOG" "$LOGGER" --event dispatched --repo sample --task external --task-id "$TASK_ID" --delegation-id "$DELEGATION_ID" --subagent-role reviewer --agent-task-name /root/reviewer --ownership diff --attempt 1 --agent claude --model opus --kind レビュー --risk 高 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "external event approval_basis=none を拒否しない"
assert_contains "external event approval guard" "$OUT" "--approval-basis explicit|standing が必須"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$EVENT_EXTERNAL_LOG" "$LOGGER" --event dispatched --repo sample --task external --task-id "$TASK_ID" --delegation-id "$DELEGATION_ID" --subagent-role reviewer --agent-task-name /root/reviewer --ownership diff --attempt 1 --agent claude --model opus --effort high --kind レビュー --risk 高 --approval-basis explicit 2>&1)"
assert_contains "explicit external event recorded" "$OUT" "recorded:"

write_audit_fixture() {
  local dir="$1"
  shift
  mkdir -p "$dir"
  printf '%s\n' "$@" > "$dir/delegation-log.jsonl"
}

AUDIT_CRITICAL_LOWER_ROUTING="$TMP/audit-critical-lower-routing"
write_audit_fixture "$AUDIT_CRITICAL_LOWER_ROUTING" \
  '{"schema_version":2,"record_type":"task_summary","repo":"sample","task":"critical-lower","task_id":"task-critical-lower","kind":"レビュー","agent":"claude","model":"opus","effort":"high","risk":"高","outcome":"採用","validation":"pass","routing_verdict":"過小","cause":"none","approval_basis":"explicit","run_id":"run-critical-lower","note":"tier=最重要","required_model":"fable","actual_model":"opus","review_status":"completed"}'
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$AUDIT_CRITICAL_LOWER_ROUTING" "$LOGGER" --audit-routing 2>&1)"
RC=$?
set -e
[ "$RC" -eq 1 ] && ok || ng "critical lower review adopted summary をaudit-routingが拒否しない"
assert_contains "critical lower review audit issue" "$OUT" "critical_review_absent_outcome"

CORRECTION_LOG="$TMP/correction-log"
env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$CORRECTION_LOG" "$LOGGER" --event dispatched --repo sample --task old --task-id task_corr --delegation-id del_old --subagent-role worker --agent-task-name /root/old --ownership files --attempt 1 --agent codex-native >/dev/null
tail -n 1 "$CORRECTION_LOG/delegation-log.jsonl" >> "$CORRECTION_LOG/delegation-log.jsonl"
env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$CORRECTION_LOG" "$LOGGER" --event dispatched --repo sample --task replacement --task-id task_corr --delegation-id del_new --subagent-role worker --agent-task-name /root/new --ownership files --attempt 1 --agent codex-native >/dev/null
env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$CORRECTION_LOG" "$LOGGER" --event completed --repo sample --task replacement --task-id task_corr --delegation-id del_new --subagent-role worker --agent-task-name /root/new --attempt 1 --agent codex-native --outcome 採用 --validation pass >/dev/null
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$CORRECTION_LOG" "$LOGGER" --correction supersedes --repo sample --task correction --task-id task_corr --target-delegation-id del_old --replacement-delegation-id del_new --reason historical_bad_lifecycle --note supersede-old 2>&1)"
assert_contains "supersedes correction recorded" "$OUT" "recorded:"
[ "$(tail -n 1 "$CORRECTION_LOG/delegation-log.jsonl" | jq -r '.record_type,.correction,.target_delegation_id,.replacement_delegation_id,.reason' | tr '\n' ' ')" = 'delegation_correction supersedes del_old del_new historical_bad_lifecycle ' ] && ok || ng "supersedes correction fields が不正"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$CORRECTION_LOG" "$LOGGER" --repo sample --task correction --task-id task_corr --kind 実装 --agent codex-native --model unknown --risk 低 --outcome 採用 --validation pass --routing 適正 --cause none 2>&1)"
assert_contains "summary after superseded unclosed delegation recorded" "$OUT" "recorded:"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$CORRECTION_LOG" "$LOGGER" --audit-delegations 2>&1)"
assert_contains "correction audit physical count" "$OUT" "physical_events=4"
assert_contains "correction audit effective count" "$OUT" "effective_events=2"
assert_contains "correction audit correction count" "$OUT" "corrections=1"
assert_contains "correction audit clean" "$OUT" "issues=0"
CORRECTION_LINES="$(wc -l < "$CORRECTION_LOG/delegation-log.jsonl" | tr -d ' ')"
env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$CORRECTION_LOG" "$LOGGER" --event dispatched --repo sample --task invalid-replacement --task-id task_corr --delegation-id del_unclosed_replacement --subagent-role worker --agent-task-name /root/unclosed --ownership files --attempt 1 --agent codex-native >/dev/null
CORRECTION_LINES="$(wc -l < "$CORRECTION_LOG/delegation-log.jsonl" | tr -d ' ')"
for CORRECTION_REJECT in unknown duplicate retired self invalid_replacement; do
  set +e
  case "$CORRECTION_REJECT" in
    unknown) OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$CORRECTION_LOG" "$LOGGER" --correction voided --repo sample --task correction --target-delegation-id del_missing --reason unknown 2>&1)" ;;
    duplicate) OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$CORRECTION_LOG" "$LOGGER" --correction voided --repo sample --task correction --target-delegation-id del_old --reason duplicate_record 2>&1)" ;;
    retired) OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$CORRECTION_LOG" "$LOGGER" --event followup --repo sample --task old --task-id task_corr --delegation-id del_old --subagent-role worker --agent-task-name /root/old --attempt 2 --agent codex-native 2>&1)" ;;
    self) OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$CORRECTION_LOG" "$LOGGER" --correction supersedes --repo sample --task correction --target-delegation-id del_new --replacement-delegation-id del_new --reason operator_error 2>&1)" ;;
    invalid_replacement) OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$CORRECTION_LOG" "$LOGGER" --correction supersedes --repo sample --task correction --target-delegation-id del_new --replacement-delegation-id del_unclosed_replacement --reason operator_error 2>&1)" ;;
  esac
  RC=$?
  set -e
  [ "$RC" -eq 2 ] && ok || ng "correction $CORRECTION_REJECT を拒否しない"
  case "$CORRECTION_REJECT" in
    unknown) assert_contains "unknown correction target issue" "$OUT" "unknown_correction_target" ;;
    duplicate) assert_contains "duplicate correction target issue" "$OUT" "duplicate_correction_target" ;;
    retired) assert_contains "retired delegation event issue" "$OUT" "retired_delegation" ;;
    self) assert_contains "self correction target issue" "$OUT" "同一にできない" ;;
    invalid_replacement) assert_contains "invalid replacement delegation issue" "$OUT" "invalid_replacement_delegation" ;;
  esac
  [ "$CORRECTION_LINES" = "$(wc -l < "$CORRECTION_LOG/delegation-log.jsonl" | tr -d ' ')" ] && ok || ng "correction $CORRECTION_REJECT 拒否で行数が変化した"
done

VOID_LOG="$TMP/correction-void-log"
env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$VOID_LOG" "$LOGGER" --event dispatched --repo sample --task void --task-id task_void --delegation-id del_void --subagent-role worker --agent-task-name /root/void --ownership files --attempt 1 --agent codex-native >/dev/null
tail -n 1 "$VOID_LOG/delegation-log.jsonl" >> "$VOID_LOG/delegation-log.jsonl"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$VOID_LOG" "$LOGGER" --correction voided --repo sample --task void --task-id task_void --target-delegation-id del_void --reason operator_error 2>&1)"
assert_contains "voided correction recorded" "$OUT" "recorded:"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$VOID_LOG" "$LOGGER" --audit-delegations 2>&1)"
assert_contains "voided correction effective count" "$OUT" "effective_events=0"
assert_contains "voided correction audit clean" "$OUT" "issues=0"

HEALTHY_OPEN_CORRECTION_LOG="$TMP/correction-healthy-open-log"
env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$HEALTHY_OPEN_CORRECTION_LOG" "$LOGGER" --event dispatched --repo sample --task healthy-open --task-id task_healthy_open --delegation-id del_healthy_open --subagent-role worker --agent-task-name /root/healthy --ownership files --attempt 1 --agent codex-native >/dev/null
HEALTHY_LINES="$(wc -l < "$HEALTHY_OPEN_CORRECTION_LOG/delegation-log.jsonl" | tr -d ' ')"
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$HEALTHY_OPEN_CORRECTION_LOG" "$LOGGER" --correction voided --repo sample --task healthy-open --task-id task_healthy_open --target-delegation-id del_healthy_open --reason operator_error 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "healthy open delegation correction をrecord-timeで拒否しない"
assert_contains "healthy open correction issue" "$OUT" "healthy_open_correction_target"
[ "$HEALTHY_LINES" = "$(wc -l < "$HEALTHY_OPEN_CORRECTION_LOG/delegation-log.jsonl" | tr -d ' ')" ] && ok || ng "healthy open correction 拒否で行数が変化した"

AUDIT_HEALTHY_OPEN_CORRECTION="$TMP/audit-healthy-open-correction"
write_audit_fixture "$AUDIT_HEALTHY_OPEN_CORRECTION" \
  '{"schema_version":2,"record_type":"delegation_event","repo":"sample","task":"healthy","task_id":"task-healthy","delegation_id":"del-healthy","event":"dispatched","subagent_role":"worker","agent_task_name":"/root/healthy","ownership":"files","attempt":1,"agent":"codex-native","model":"unknown","effort":"unknown","outcome":"未完了","validation":"not_run","routing_verdict":"適正","cause":"none","approval_basis":"none"}' \
  '{"schema_version":2,"record_type":"delegation_correction","repo":"sample","task":"healthy","target_delegation_id":"del-healthy","correction":"voided","reason":"operator_error"}'
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$AUDIT_HEALTHY_OPEN_CORRECTION" "$LOGGER" --audit-delegations 2>&1)"
RC=$?
set -e
[ "$RC" -eq 1 ] && ok || ng "healthy open correction audit が exit 1 でない"
assert_contains "healthy open correction audit issue" "$OUT" "healthy_open_correction_target"

AUDIT_INVALID_CORRECTION="$TMP/audit-invalid-correction"
write_audit_fixture "$AUDIT_INVALID_CORRECTION" \
  '{"schema_version":2,"record_type":"delegation_correction","target_delegation_id":"del_missing","correction":"voided","reason":"bad_reason"}'
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$AUDIT_INVALID_CORRECTION" "$LOGGER" --audit-delegations 2>&1)"
RC=$?
set -e
[ "$RC" -eq 1 ] && ok || ng "invalid correction audit が exit 1 でない"
assert_contains "invalid correction audit issue" "$OUT" "invalid_correction"

AUDIT_UNCLOSED="$TMP/audit-unclosed"
write_audit_fixture "$AUDIT_UNCLOSED" '{"record_type":"delegation_event","task_id":"task-a","delegation_id":"del-a","event":"dispatched","attempt":1}'
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$AUDIT_UNCLOSED" "$LOGGER" --audit-delegations 2>&1)"
RC=$?
set -e
[ "$RC" -eq 1 ] && ok || ng "未閉鎖 delegation audit が exit 1 でない"
assert_contains "unclosed delegation issue" "$OUT" "unclosed"

AUDIT_TERMINAL_ONLY="$TMP/audit-terminal-only"
write_audit_fixture "$AUDIT_TERMINAL_ONLY" '{"record_type":"delegation_event","task_id":"task-a","delegation_id":"del-a","event":"completed","attempt":1}'
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$AUDIT_TERMINAL_ONLY" "$LOGGER" --audit-delegations 2>&1)"
RC=$?
set -e
[ "$RC" -eq 1 ] && ok || ng "terminal without dispatch が exit 1 でない"
assert_contains "terminal without dispatch issue" "$OUT" "terminal_without_dispatch"

AUDIT_DUPLICATE="$TMP/audit-duplicate"
write_audit_fixture "$AUDIT_DUPLICATE" \
  '{"record_type":"delegation_event","task_id":"task-a","delegation_id":"del-a","event":"dispatched","attempt":1}' \
  '{"record_type":"delegation_event","task_id":"task-a","delegation_id":"del-a","event":"completed","attempt":1}' \
  '{"record_type":"delegation_event","task_id":"task-a","delegation_id":"del-a","event":"failed","attempt":1}'
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$AUDIT_DUPLICATE" "$LOGGER" --audit-delegations 2>&1)"
RC=$?
set -e
[ "$RC" -eq 1 ] && ok || ng "重複terminal audit が exit 1 でない"
assert_contains "duplicate terminal issue" "$OUT" "duplicate_terminal"
assert_contains "event after terminal issue" "$OUT" "event_after_terminal"

AUDIT_NO_SUMMARY="$TMP/audit-no-summary"
write_audit_fixture "$AUDIT_NO_SUMMARY" \
  '{"record_type":"delegation_event","task_id":"task-a","delegation_id":"del-a","event":"dispatched","attempt":1}' \
  '{"record_type":"delegation_event","task_id":"task-a","delegation_id":"del-a","event":"completed","attempt":1}'
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$AUDIT_NO_SUMMARY" "$LOGGER" --audit-delegations 2>&1)"
RC=$?
set -e
[ "$RC" -eq 1 ] && ok || ng "summary欠落 audit が exit 1 でない"
assert_contains "summary missing issue" "$OUT" "summary_missing"

AUDIT_EARLY_SUMMARY="$TMP/audit-early-summary"
EARLY_TASK_ID="$(env HOME="$HOME_DIR" "$LOGGER" --new-task-id)"
EARLY_DELEGATION_ID="$(env HOME="$HOME_DIR" "$LOGGER" --new-delegation-id)"
env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$AUDIT_EARLY_SUMMARY" "$LOGGER" --event dispatched --repo sample --task early-summary --task-id "$EARLY_TASK_ID" --delegation-id "$EARLY_DELEGATION_ID" --subagent-role worker --agent-task-name /root/early --ownership bin/x --attempt 1 --agent codex-native >/dev/null
EARLY_SUMMARY_LINES="$(wc -l < "$AUDIT_EARLY_SUMMARY/delegation-log.jsonl" | tr -d ' ')"
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$AUDIT_EARLY_SUMMARY" "$LOGGER" --repo sample --task early-summary --task-id "$EARLY_TASK_ID" --kind 実装 --agent codex-native --model unknown --risk 低 --outcome 採用 --validation pass --routing 適正 --cause none 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "未閉鎖delegation中のtask summaryをrecord-timeで拒否しない"
assert_contains "record-time summary unclosed issue" "$OUT" "summary_with_unclosed_delegation"
[ "$EARLY_SUMMARY_LINES" = "$(wc -l < "$AUDIT_EARLY_SUMMARY/delegation-log.jsonl" | tr -d ' ')" ] && ok || ng "拒否した早すぎるsummaryで行数が変化した"
env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$AUDIT_EARLY_SUMMARY" "$LOGGER" --event completed --repo sample --task early-summary --task-id "$EARLY_TASK_ID" --delegation-id "$EARLY_DELEGATION_ID" --subagent-role worker --agent-task-name /root/early --attempt 1 --agent codex-native --outcome 採用 --validation pass >/dev/null
env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$AUDIT_EARLY_SUMMARY" "$LOGGER" --repo sample --task early-summary --task-id "$EARLY_TASK_ID" --kind 実装 --agent codex-native --model unknown --risk 低 --outcome 採用 --validation pass --routing 適正 --cause none >/dev/null
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$AUDIT_EARLY_SUMMARY" "$LOGGER" --audit-delegations 2>&1)"
assert_contains "closed-after-rejected-summary audit succeeds" "$OUT" "issues=0"

AUDIT_EARLY_SUMMARY_RAW="$TMP/audit-early-summary-raw"
write_audit_fixture "$AUDIT_EARLY_SUMMARY_RAW" \
  '{"schema_version":2,"record_type":"delegation_event","repo":"sample","task":"early","task_id":"task-a","delegation_id":"del-a","event":"dispatched","subagent_role":"worker","agent_task_name":"/root/w","agent":"codex-native","attempt":1,"ownership":"x","outcome":"未完了","validation":"not_run"}' \
  '{"schema_version":2,"record_type":"task_summary","repo":"sample","task":"early","task_id":"task-a","kind":"実装","agent":"codex-native","model":"unknown","risk":"低","outcome":"採用","validation":"pass","routing_verdict":"適正","cause":"none"}' \
  '{"schema_version":2,"record_type":"delegation_event","repo":"sample","task":"early","task_id":"task-a","delegation_id":"del-a","event":"completed","subagent_role":"worker","agent_task_name":"/root/w","agent":"codex-native","attempt":1,"outcome":"採用","validation":"pass"}'
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$AUDIT_EARLY_SUMMARY_RAW" "$LOGGER" --audit-delegations 2>&1)"
RC=$?
set -e
[ "$RC" -eq 1 ] && ok || ng "terminal前のtask summaryをauditが拒否しない"
assert_contains "summary before close issue" "$OUT" "summary_before_close"

AUDIT_BROKEN="$TMP/audit-broken"
write_audit_fixture "$AUDIT_BROKEN" '{broken'
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$AUDIT_BROKEN" "$LOGGER" --audit-delegations 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "壊れたJSONL audit が exit 2 でない"
assert_contains "broken JSONL audit message" "$OUT" "解析不能な JSONL"

AUDIT_SYMLINK="$TMP/audit-symlink"
mkdir -p "$AUDIT_SYMLINK"
printf '%s\n' '{}' > "$TMP/audit-outside.jsonl"
ln -s "$TMP/audit-outside.jsonl" "$AUDIT_SYMLINK/delegation-log.jsonl"
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$AUDIT_SYMLINK" "$LOGGER" --audit-delegations 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] && ok || ng "symlink audit が exit 2 でない"
assert_contains "symlink audit message" "$OUT" "symlink は使えない"

RUN_AUDIT_OK="$TMP/run-audit-ok"
mkdir -p "$RUN_AUDIT_OK"
printf '%s\n' \
  '{"agent":"claude","model":"opus","effort":"high","run_id":"run-ok","approval_basis":"explicit"}' \
  '{"agent":"claude","model":"fable","effort":"high","run_id":"run-standing","approval_basis":"standing"}' > "$RUN_AUDIT_OK/delegation-log.jsonl"
printf '%s\n' \
  '{"run_id":"run-ok","model":"opus","effort":"high"}' \
  '{"run_id":"run-standing","model":"fable","effort":"high"}' > "$RUN_AUDIT_OK/runs.jsonl"
BEFORE_DELEGATION_CKSUM="$(cksum "$RUN_AUDIT_OK/delegation-log.jsonl")"
BEFORE_RUNS_CKSUM="$(cksum "$RUN_AUDIT_OK/runs.jsonl")"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$RUN_AUDIT_OK" "$LOGGER" --audit-run-ids 2>&1)"
assert_contains "run-id audit success" "$OUT" "issues=0"
[ "$BEFORE_DELEGATION_CKSUM" = "$(cksum "$RUN_AUDIT_OK/delegation-log.jsonl")" ] && [ "$BEFORE_RUNS_CKSUM" = "$(cksum "$RUN_AUDIT_OK/runs.jsonl")" ] && ok || ng "run-id audit がログを変更した"

RUN_AUDIT_LEGACY="$TMP/run-audit-legacy"
mkdir -p "$RUN_AUDIT_LEGACY"
printf '%s\n' \
  '{"agent":"claude","run_id":"run-legacy-missing"}' \
  '{"agent":"claude","model":"unknown","effort":"unknown","run_id":"run-legacy-unknown"}' > "$RUN_AUDIT_LEGACY/delegation-log.jsonl"
printf '%s\n' \
  '{"run_id":"run-legacy-missing","model":"sonnet","effort":"high"}' \
  '{"run_id":"run-legacy-unknown","model":"opus","effort":"high"}' > "$RUN_AUDIT_LEGACY/runs.jsonl"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$RUN_AUDIT_LEGACY" "$LOGGER" --audit-run-ids 2>&1)"
assert_contains "legacy missing model/effort is not a mismatch" "$OUT" "issues=0"

RUN_AUDIT_MISSING_REQUIRED="$TMP/run-audit-missing-required"
mkdir -p "$RUN_AUDIT_MISSING_REQUIRED"
printf '%s\n' '{"schema_version":2,"record_type":"task_summary","task_id":"task-missing-run","agent":"claude","approval_basis":"explicit","outcome":"採用","validation":"pass","run_id":null}' > "$RUN_AUDIT_MISSING_REQUIRED/delegation-log.jsonl"
set +e
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$RUN_AUDIT_MISSING_REQUIRED" "$LOGGER" --audit-run-ids 2>&1)"
RC=$?
set -e
[ "$RC" -eq 1 ] && ok || ng "成功Claude summaryのrun_id欠落auditがexit 1でない"
assert_contains "missing successful Claude run_id issue" "$OUT" "missing_claude_run_id"
[ ! -e "$RUN_AUDIT_MISSING_REQUIRED/runs.jsonl" ] && ok || ng "run_id欠落だけのauditがruns.jsonlを作成した"

for RUN_ISSUE in missing model effort standing; do
  RUN_ISSUE_DIR="$TMP/run-audit-$RUN_ISSUE"
  mkdir -p "$RUN_ISSUE_DIR"
  case "$RUN_ISSUE" in
    missing)
      printf '%s\n' '{"agent":"claude","model":"opus","effort":"high","run_id":"run-x","approval_basis":"explicit"}' > "$RUN_ISSUE_DIR/delegation-log.jsonl"
      printf '%s\n' '{"run_id":"run-other","model":"opus","effort":"high"}' > "$RUN_ISSUE_DIR/runs.jsonl"
      EXPECTED_ISSUE=missing_run_id ;;
    model)
      printf '%s\n' '{"agent":"claude","model":"opus","effort":"high","run_id":"run-x","approval_basis":"explicit"}' > "$RUN_ISSUE_DIR/delegation-log.jsonl"
      printf '%s\n' '{"run_id":"run-x","model":"sonnet","effort":"high"}' > "$RUN_ISSUE_DIR/runs.jsonl"
      EXPECTED_ISSUE=model_mismatch ;;
    effort)
      printf '%s\n' '{"agent":"claude","model":"opus","effort":"high","run_id":"run-x","approval_basis":"explicit"}' > "$RUN_ISSUE_DIR/delegation-log.jsonl"
      printf '%s\n' '{"run_id":"run-x","model":"opus","effort":"max"}' > "$RUN_ISSUE_DIR/runs.jsonl"
      EXPECTED_ISSUE=effort_mismatch ;;
    standing)
      printf '%s\n' '{"agent":"claude","model":"opus","effort":"high","run_id":"run-x","approval_basis":"standing"}' > "$RUN_ISSUE_DIR/delegation-log.jsonl"
      printf '%s\n' '{"run_id":"run-x","model":"opus","effort":"high"}' > "$RUN_ISSUE_DIR/runs.jsonl"
      EXPECTED_ISSUE=standing_mismatch ;;
  esac
  set +e
  OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$RUN_ISSUE_DIR" "$LOGGER" --audit-run-ids 2>&1)"
  RC=$?
  set -e
  [ "$RC" -eq 1 ] && ok || ng "$RUN_ISSUE run-id audit が exit 1 でない"
  assert_contains "$RUN_ISSUE run-id audit issue" "$OUT" "$EXPECTED_ISSUE"
done

AUDIT_EMPTY="$TMP/audit-empty"
OUT="$(env HOME="$HOME_DIR" DELEGATE_CODEX_LOG_DIR="$AUDIT_EMPTY" "$LOGGER" --audit-all 2>&1)"
assert_contains "empty delegation audit" "$OUT" "delegation audit: physical_events=0"
assert_contains "empty run-id audit" "$OUT" "run-id audit: references=0"
[ ! -e "$AUDIT_EMPTY" ] && ok || ng "audit-all が存在しないログ先を作成した"

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "$SKILL_DIR/../.." && pwd)"
SKILL_POLICY="$(cat "$SKILL_DIR/SKILL.md")"
LOGGER_POLICY="$(cat "$SKILL_DIR/bin/delegate-log")"
RUNNER_POLICY="$(cat "$SKILL_DIR/bin/delegate-review")"
CLAUDE_POLICY="$(cat "$SKILL_DIR/adapters/claude.md")"
TEMPLATE_POLICY="$(cat "$SKILL_DIR/templates.md")"
OPENAI_POLICY="$(cat "$SKILL_DIR/agents/openai.yaml")"
README_EN_POLICY="$(cat "$SKILL_DIR/README.md")"
README_JA_POLICY="$(cat "$SKILL_DIR/README.ja.md")"
SECURITY_POLICY="$(cat "$ROOT_DIR/SECURITY.md")"
CHANGELOG_POLICY="$(cat "$ROOT_DIR/CHANGELOG.md")"

assert_contains "three-tier routing standard" "$SKILL_POLICY" 'Claude `sonnet / high`'
assert_contains "three-tier routing high" "$SKILL_POLICY" 'Claude `opus / high`'
assert_contains "three-tier routing critical" "$SKILL_POLICY" 'Claude `fable / high`'
assert_contains "critical criteria domains" "$SKILL_POLICY" '認証・認可境界、課金・金銭、顧客・本番データ、秘密・署名・供給網、本番移行'
assert_contains "critical criteria impact" "$SKILL_POLICY" '破壊的、不可逆、広範囲、rollback 困難、複数システムへ波及'
assert_contains "local reversible sensitive change uses Opus" "$SKILL_POLICY" 'これらの領域でも局所的で可逆なら「高」とし、`opus / high` を使う'
assert_contains "standing approval is Fable-critical-only" "$SKILL_POLICY" 'Anthropic Claude Fable `fable / high` の read-only 最重要レビューに限定'
assert_contains "standing approval limits repository" "$SKILL_POLICY" 'ユーザーが現在の作業対象として指定または開いているユーザー管理 repo'
assert_contains "standing approval minimizes categories" "$SKILL_POLICY" '対象ソースコード、対象 diff、秘密を検査してマスク済みのテスト結果、秘密を含まない最小タスク要約'
assert_contains "standing approval review inputs are explicitly limited" "$SKILL_POLICY" '明示した対象ファイルと必要な関連コード、対象 diff、秘密を検査・マスク済みのテスト結果、秘密を含まない最小タスク要約のうち、そのレビューに必要なものだけ'
assert_contains "task-specific approval respects approved scope" "$SKILL_POLICY" '送信先・承認済み対象範囲・制約に沿った'
assert_not_contains "review policy has no blanket full-diff transfer" "$SKILL_POLICY" '渡すのは確定指示書、変更ファイル一覧、全 diff、ベースライン、変更後検証だけ'
assert_contains "standing approval forbids indiscriminate repo transfer" "$SKILL_POLICY" 'repo 全体を無差別に送信・探索させない'
assert_contains "standing approval excludes authenticated browser state" "$SKILL_POLICY" '認証済みブラウザ状態'
assert_contains "standing approval excludes raw delegation logs" "$SKILL_POLICY" '委任の生ログ'
assert_contains "standing approval inspects test output" "$SKILL_POLICY" 'テスト出力も送信前に秘密を検査し、必要箇所をマスクする'
assert_contains "standing approval keeps runner read-only" "$SKILL_POLICY" '`--safe-mode`、`--permission-mode plan`、`Read,Glob,Grep`、MCP 拒否による read-only'
assert_contains "standing approval forbids writes and network" "$SKILL_POLICY" 'ファイル変更・コミット・push・追加 network action を許可しない'
assert_contains "standing approval is logged" "$SKILL_POLICY" '`tier=最重要`、`standing approval 使用`、実際に送信した対象カテゴリ'
assert_contains "Fable standing records actual critical tier" "$SKILL_POLICY" '`tier=最重要; standing approval 使用; 送信対象カテゴリ=<実際のカテゴリ>` を必ず含める'
assert_contains "skill limits default none compatibility" "$SKILL_POLICY" '後方互換は、self / native / 外部送信なしの経路だけに維持する'
assert_contains "skill rejects external AI none regardless of kind" "$SKILL_POLICY" '`agent=claude|grok|agy` は `kind` に関係なく `--approval-basis explicit|standing` を必須'
assert_contains "skill rejects note controls" "$SKILL_POLICY" 'すべての approval basis で `--note` の CR / LF / TAB を拒否'
assert_contains "standing approval log requires review run" "$SKILL_POLICY" '`kind=レビュー`、`agent=claude`、`model=fable`、`effort=high`、`risk=高`、空でない `run-id`'
assert_contains "standing approval categories are exact and unique" "$SKILL_POLICY" 'カテゴリ順は自由だが、空要素・未知値・重複は拒否する'
assert_contains "standing marker is reserved" "$SKILL_POLICY" '`standing` 以外の note に `standing approval 使用` を記録することも拒否する'
assert_contains "Sonnet and Opus remain task-approved" "$SKILL_POLICY" 'Fable 以外（Sonnet / Opus を含む）'
assert_contains "Opus explicit approval log contract" "$SKILL_POLICY" '| Opus `opus / high` | `--approval-basis explicit --effort high` |'
assert_contains "Opus has no silent Sonnet fallback" "$SKILL_POLICY" '高で Opus が利用できない場合も Sonnet へ黙って切り替えず'
assert_contains "Fable has no silent fallback" "$SKILL_POLICY" 'Opus / Sonnet や別の外部 AI へ黙って切り替えない'

assert_contains "logger mechanically requires critical tier" "$LOGGER_POLICY" "'tier=最重要' が必須"
assert_contains "logger rejects note controls" "$LOGGER_POLICY" '制御文字(CR/LF/TAB)は使えない'
assert_contains "logger rejects external AI none regardless of kind" "$LOGGER_POLICY" '外部 AI (claude|grok|agy) は --kind に関係なく --approval-basis explicit|standing が必須'
assert_contains "runner cooldown standard requires explicit alternative approval" "$RUNNER_POLICY" '標準: 代替外部 AI にもタスク単位の明示承認が必要'
assert_contains "runner cooldown high blocks silent fallback" "$RUNNER_POLICY" '高: Opus 不可時に Sonnet へ黙って切り替えず'
assert_contains "runner cooldown critical remains blocker" "$RUNNER_POLICY" '最重要: Fable 未実施を blocker として残す'

assert_contains "Claude adapter has standing preflight" "$CLAUDE_POLICY" '## 外部送信の承認ゲート'
assert_contains "Claude adapter requires exact sent categories" "$CLAUDE_POLICY" '送信対象カテゴリ=<実際のカテゴリ>'
assert_contains "Claude adapter requires explicit approval for fable max" "$CLAUDE_POLICY" '`fable / max` を使うことはできるが、恒常承認の対象外'
assert_contains "Claude adapter routes high to Opus" "$CLAUDE_POLICY" '| 高 | `opus` | `high` |'
assert_contains "Claude adapter keeps Opus explicit" "$CLAUDE_POLICY" 'Opus は常に standing 対象外'
assert_contains "Claude adapter records critical tier" "$CLAUDE_POLICY" '`tier=最重要; standing approval 使用; 送信対象カテゴリ=<実際のカテゴリ>`'
assert_contains "Claude adapter canonical models include Opus" "$CLAUDE_POLICY" '--model <sonnet|opus|fable>'
assert_contains "Claude adapter model examples are not allowlist" "$CLAUDE_POLICY" 'allowlist ではない'
assert_contains "Claude adapter blocks Opus to Sonnet fallback" "$CLAUDE_POLICY" 'Claude Opus が使えなくても Sonnet へ黙って切り替えない'
assert_contains "Claude adapter has no silent fallback" "$CLAUDE_POLICY" 'Opus / Sonnet へ黙って切り替えない'
assert_contains "packet template has pre-send checklist" "$TEMPLATE_POLICY" '送信前チェック:'
assert_contains "packet template restricts target files" "$TEMPLATE_POLICY" '## 許可された参照範囲'
assert_contains "packet template marks masked validation" "$TEMPLATE_POLICY" '## マスク済み変更後検証'
assert_contains "packet template excludes Sonnet and Opus from standing" "$TEMPLATE_POLICY" 'Sonnet、Opus、`fable / max` には standing approval を使わず、必ずタスク単位の明示承認を得る'
assert_contains "packet template records critical tier" "$TEMPLATE_POLICY" '`tier=最重要; standing approval 使用; 送信対象カテゴリ=<実際のカテゴリ>`'
assert_contains "packet template rejects external AI none regardless of kind" "$TEMPLATE_POLICY" 'Claude / Grok / Antigravity (`agent=claude|grok|agy`) は `kind` に関係なく `approval_basis=none`'
assert_contains "OpenAI prompt carries standing approval" "$OPENAI_POLICY" 'standing-approval exception is Anthropic Claude Fable fable/high read-only'
assert_contains "OpenAI prompt carries standard routing" "$OPENAI_POLICY" 'Route standard review to Claude sonnet/high,'
assert_contains "OpenAI prompt carries high and critical routing" "$OPENAI_POLICY" 'high review to opus/high, and only critical review to fable/high.'
assert_contains "OpenAI prompt keeps Sonnet explicit" "$OPENAI_POLICY" 'any non-Fable external AI including Sonnet'
assert_contains "OpenAI prompt keeps Opus explicit" "$OPENAI_POLICY" 'and Opus, or external implementation/write/additional-network work requires'
assert_contains "OpenAI prompt has no Fable silent fallback" "$OPENAI_POLICY" 'Never silently fall back from required Fable to'
assert_contains "OpenAI prompt has no Opus silent fallback" "$OPENAI_POLICY" 'If required Opus is unavailable, never'
assert_contains "OpenAI prompt requires structured approval basis" "$OPENAI_POLICY" 'Pass --approval-basis standing --effort high'
assert_contains "OpenAI prompt limits standing to critical Fable" "$OPENAI_POLICY" 'only for eligible critical fable/high reviews and include the required note'
assert_contains "OpenAI prompt records critical tier" "$OPENAI_POLICY" 'tier=最重要'
assert_contains "OpenAI prompt rejects external AI none regardless of kind" "$OPENAI_POLICY" 'Claude, Grok, and Antigravity'
assert_contains "OpenAI prompt binds external approval regardless of kind" "$OPENAI_POLICY" 'must use explicit or standing regardless of kind'
assert_contains "OpenAI prompt rejects note controls" "$OPENAI_POLICY" 'reject CR, LF, and TAB'
assert_contains "English README documents limited standing approval" "$README_EN_POLICY" '## Limited standing approval for Fable'
assert_contains "English README documents Opus tier" "$README_EN_POLICY" 'High-risk review: Claude `opus / high`'
assert_contains "English README keeps Sonnet and Opus task-approved" "$README_EN_POLICY" 'a non-Fable external AI (including Sonnet and Opus)'
assert_contains "English README records critical tier" "$README_EN_POLICY" '`tier=最重要; standing approval 使用; 送信対象カテゴリ=<実際のカテゴリ>`'
assert_contains "English README limits none compatibility" "$README_EN_POLICY" 'remain only for self/native/no-external-transfer routes'
assert_contains "English README rejects external AI none regardless of kind" "$README_EN_POLICY" 'Claude, Grok, and Antigravity (`agent=claude|grok|agy`) require `explicit` or `standing` regardless of `kind`'
assert_contains "English README rejects note controls" "$README_EN_POLICY" 'CR, LF, and TAB fail closed'
assert_contains "Japanese README documents limited standing approval" "$README_JA_POLICY" '## Fable の限定的な恒常承認'
assert_contains "Japanese README documents Opus tier" "$README_JA_POLICY" '高は `opus / high`'
assert_contains "Japanese README keeps Sonnet and Opus task-approved" "$README_JA_POLICY" 'Fable 以外（Sonnet / Opus を含む）、`fable / max`'
assert_contains "Japanese README documents standing log guards" "$README_JA_POLICY" 'カテゴリの順序は自由ですが、空要素・未知値・重複は fail-closed で拒否します'
assert_contains "Japanese README records critical tier" "$README_JA_POLICY" '`tier=最重要; standing approval 使用; 送信対象カテゴリ=<実際のカテゴリ>`'
assert_contains "Japanese README rejects external AI none regardless of kind" "$README_JA_POLICY" 'Claude / Grok / Antigravity (`agent=claude|grok|agy`) は `kind` に関係なく `explicit|standing` を必須'
assert_contains "Japanese README rejects note controls" "$README_JA_POLICY" 'CR / LF / TABを拒否'
assert_contains "skill documents task id generation" "$SKILL_POLICY" '`--new-task-id`'
assert_contains "skill documents dispatched event" "$SKILL_POLICY" '`dispatched`'
assert_contains "skill requires audit all" "$SKILL_POLICY" '`--audit-all`'
assert_contains "logger supports delegation event" "$LOGGER_POLICY" 'record_type:"delegation_event"'
assert_contains "logger supports delegation audit" "$LOGGER_POLICY" '--audit-delegations'
assert_contains "logger rejects summary before close" "$LOGGER_POLICY" 'summary_before_close'
assert_contains "logger audits missing successful Claude run id" "$LOGGER_POLICY" 'missing_claude_run_id'
assert_not_contains "logger never sources skill env" "$LOGGER_POLICY" '. "$SKILL_DIR/.env"'
assert_not_contains "runner never sources skill env" "$RUNNER_POLICY" '. "$SKILL_DIR/.env"'
assert_contains "logger statically allowlists env keys" "$LOGGER_POLICY" 'DELEGATE_CODEX_LOG_DIR|CLAUDE_BIN'
assert_contains "skill documents static env parsing" "$SKILL_POLICY" 'skill-local `.env` はshellとして`source`しない'
assert_contains "skill requires summary after every event" "$SKILL_POLICY" '各`task_id`の最新summaryは、そのtaskの全eventより後'
assert_contains "skill requires successful Claude run id" "$SKILL_POLICY" '成功・採否を記録するClaude summaryと`completed` eventは空でない`run-id`を必須'
assert_contains "template includes delegation event commands" "$TEMPLATE_POLICY" '--event dispatched'
assert_contains "OpenAI prompt requires task id" "$OPENAI_POLICY" 'task_id'
assert_contains "OpenAI prompt requires successful Claude run id" "$OPENAI_POLICY" 'events require the delegate-review run_id'
assert_contains "OpenAI prompt rejects shell-sourced env" "$OPENAI_POLICY" 'Never source the skill-local .env as shell'
assert_contains "English README documents delegation audit" "$README_EN_POLICY" '`--audit-all`'
assert_contains "Japanese README documents delegation audit" "$README_JA_POLICY" '`--audit-all`'
assert_contains "root security documents standing approval" "$SECURITY_POLICY" '恒常承認は、ユーザーが作業対象として指定または開いているユーザー管理 repo'
assert_contains "root security documents Opus explicit approval" "$SECURITY_POLICY" 'Opus/high は常に `--approval-basis explicit --effort high`'
assert_contains "root security documents standing log binding" "$SECURITY_POLICY" 'standing を `kind=レビュー` と空でない `run-id` と `tier=最重要` へ結び付け'
assert_contains "root security records critical tier" "$SECURITY_POLICY" '`tier=最重要; standing approval 使用; 送信対象カテゴリ=<実際のカテゴリ>`'
assert_contains "root security rejects external AI none regardless of kind" "$SECURITY_POLICY" 'Claude / Grok / Antigravity (`agent=claude|grok|agy`) は `kind` に関係なく `approval_basis=none` を拒否'
assert_contains "root security rejects note controls" "$SECURITY_POLICY" '全noteのCR / LF / TABを拒否'
assert_contains "root security documents static env parser" "$SECURITY_POLICY" 'skill-local `.env`はshellとしてsourceせず'
assert_contains "changelog records standing approval" "$CHANGELOG_POLICY" '`standing approval 使用`・送信カテゴリ記録'
assert_contains "changelog records three-tier routing" "$CHANGELOG_POLICY" '標準は Claude Sonnet / high、高は Claude Opus / high、最重要は Claude Fable / high'
assert_contains "changelog rejects external AI none regardless of kind" "$CHANGELOG_POLICY" 'Claude / Grok / Antigravity (`agent=claude|grok|agy`) は `kind` に関係なく外部送信の`none`を拒否'
assert_contains "changelog records delegation events" "$CHANGELOG_POLICY" '`delegation_event`'

echo "PASS: $PASS / FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
