# delegate-codex

An Agent Skill that keeps Codex as the orchestrator, delegates repository investigation and implementation to native Codex subagents, and uses Claude Code CLI as the primary independent reviewer.

- Standard-risk review: Claude `sonnet / high`
- High-risk review: Claude `opus / high`
- Critical review: Claude `fable / high`
- Claude runs read-only with `--safe-mode`, `--permission-mode plan`, restricted tools, isolated logs, and before/after worktree checks

## Install

As a Codex plugin:

```bash
codex plugin marketplace add anytools-app/anytools-agent-skills
codex plugin add anytools-agent-skills-codex@anytools-agent-skills
```

Or symlink only this skill:

```bash
mkdir -p "$HOME/.agents/skills"
ln -s "$PWD/codex-skills/delegate-codex" "$HOME/.agents/skills/delegate-codex"
```

Restart Codex after installation. `agents/openai.yaml` allows implicit invocation so global or repository `AGENTS.md` rules can select the skill by default. Skill invocation itself never authorizes an external transfer. The only standing-approval exception is the narrowly scoped Fable review described below; all other external AI transfers require task-specific explicit approval stating the destination, scope, and constraints.

## Limited standing approval for Fable

The user has granted standing approval only for Anthropic Claude Fable `fable / high` read-only critical reviews. Critical means a change to an authentication or authorization boundary, billing or money, customer or production data, secrets/signing/supply chain, or a production migration that is also destructive, irreversible, broad, hard to roll back, or crosses multiple systems. A local and reversible change in any of those domains remains high-risk and routes to `opus / high`. All of these conditions must also hold:

- The repository is a user-managed repository that the user designated or opened for the current task.
- Transfer is limited to target source files and necessary related code, the target diff, secret-checked and masked test results, and a minimal non-secret task summary. The repository must not be sent or explored indiscriminately.
- `.env` files, private keys, authentication or access tokens, database connection strings, customer or personal data, production logs, authenticated browser state, and raw delegation logs are always excluded. Test output is inspected and masked before transfer.
- Claude remains read-only through runner-enforced safe mode, plan permission mode, `Read,Glob,Grep`, and denied MCP tools. File edits, commits, pushes, and additional network actions are forbidden.

Before execution, Codex internally checks every condition and the exact files and categories being sent. When it uses standing approval, the final report and `delegate-log --approval-basis standing --effort high` note record `tier=最重要; standing approval 使用; 送信対象カテゴリ=<実際のカテゴリ>`. Unclear or broader scope, a non-Fable external AI (including Sonnet and Opus), `fable / max`, external implementation or writes, and additional network actions still require task-specific explicit approval. Log Sonnet/Opus `high` with `--approval-basis explicit --effort high` and Fable `max` with `--approval-basis explicit --effort max`. Opus standing approval is currently unsupported; Opus remains task-specific `explicit` until the user explicitly authorizes a limited standing scope and the policy is updated. A required Fable review never silently falls back to Opus, Sonnet, or another external AI. If required Opus is unavailable, never silently fall back to Sonnet or use another external AI without explicit approval.

Every task using this skill must successfully run `bin/delegate-log` before the final response, including low-risk, investigation, consultation, direct/self, native-subagent-only, and no-Claude-review tasks. The backward-compatible defaults `--approval-basis none` and `--effort unknown` remain only for self/native/no-external-transfer routes. Claude, Grok, and Antigravity (`agent=claude|grok|agy`) require `explicit` or `standing` regardless of `kind` and cannot use `none`; the existing standing guards permit only an eligible critical `fable / high` review. Claude reviews record the actual effort. Use `explicit` for task-approved Sonnet/Opus/Fable transfers and `standing` only for eligible critical `fable / high` reviews. The logger keeps the existing `risk=高` enum for both high and critical routes; Fable standing records the actual tier as `tier=最重要` in the note and validates that marker. A standing entry requires `kind=レビュー`, a non-empty review `run-id`, and the exact sent-category vocabulary (`対象ソースコード`, `対象diff`, `マスク済みテスト結果`, `最小タスク要約`). Category order is unrestricted, but empty, unknown, and duplicate entries fail closed. The standing marker is rejected for every non-standing approval basis. Every note must be one line: CR, LF, and TAB fail closed, while normal Japanese text, spaces, and semicolons remain allowed. The logger writes `approval_basis` and `effort` to JSONL and fail-closes invalid entries. The final report includes the path printed by `recorded:`. A logging failure keeps the task incomplete and must be reported with its literal error.

New records use schema v2. Existing CLI calls remain task summaries with all previous fields plus `schema_version`, `record_type`, UTC `timestamp`, and an optional `task_id`; existing JSONL is not rewritten. For subagent work, the main Codex generates a task ID (`--new-task-id`) and delegation ID (`--new-delegation-id`), records `dispatched` immediately after spawn, `followup` immediately after each follow-up, and `completed|failed` only when it closes the delegation with no further follow-up pending, then writes the final summary with the same task ID. A provisional completion notification is not terminal while another request may follow. Canonical agent task names and instruction ownership scopes make individual delegations traceable without relying on subagent-side logging. Direct/self work does not need events.

`delegate-log` validates lifecycle state under the same atomic lock used for append. Duplicate dispatches, follow-up without dispatch, events after terminal, terminal without dispatch, terminal after terminal, and a task summary while effective delegations are still open are rejected before append, leaving the line count unchanged. The lock is tied to `delegation-log.jsonl` and lives outside git worktrees with the log. Existing locks are never auto-deleted, regardless of owner-file presence or PID liveness; after a bounded wait, the logger fails closed and asks the operator to manually verify that no `delegate-log` process is active before touching the lock.

Historical bad lifecycle rows are corrected append-only with `record_type:"delegation_correction"` via `--correction voided|supersedes`, `--target-delegation-id`, optional `--replacement-delegation-id`, and `--reason historical_bad_lifecycle|operator_error|duplicate_record|unknown`. Corrections never delete physical rows; they retire the target delegation only for lifecycle audit and preappend effective state. Unknown targets, self-targets, duplicate corrections, invalid replacement IDs, new events on retired IDs, and corrections against healthy open delegations fail closed. A healthy open delegation is exactly one dispatch and zero terminal events; it must be closed with a normal terminal event, not hidden by correction. Audits report physical events, effective events, corrections, and issues.

Task summaries also carry `required_model`, `actual_model`, and `review_status`. Old CLI calls derive these fields: investigation/consultation is `none/none/not_required`; low-risk implementation/review without Claude is `none/none/skipped_low_risk`; standard requires `sonnet`, high requires `opus`, and `tier=最重要` or Fable standing requires `fable`. Actual model is populated only for Claude `sonnet|opus|fable`. Missing required review becomes `blocked_approval` and `routing_verdict=過小`; lower/higher actual models become `過小`/`過剰`; required none plus actual Claude is `過剰`. Explicit fields or routing that contradict derivation are rejected. Missing or lower-than-Fable critical review requires outcome `未完了|失敗`; missing high Opus may still be adopted if it records `過小` and `blocked_approval`.

`delegate-log --audit-delegations` checks effective dispatch/terminal uniqueness, event order, attempts, matching task summaries, and requires each task's latest summary to follow all of its effective events. `--audit-run-ids` checks every Claude `run_id`, including legacy summaries, against `runs.jsonl`; it compares model/effort only when the delegation log has concrete values and treats missing/`unknown` legacy values as unassertable rather than mismatches. `--audit-routing` validates the new routing fields while summaries missing all three fields remain legacy-compatible. Successful/adopted explicit or standing Claude summaries and completed events require a non-empty run ID; only pre-run failure/incomplete records may omit it. Standing=`fable / high` remains strict. `--audit-all` runs all audits and is required before completing a subagent task. Audits are read-only: issues return 1, while malformed/unreadable/symlinked/worktree-local logs return 2.

If a managed sandbox permission profile rejects the default persistent log path, rerun the same `delegate-log` command through the execution environment's sandbox escalation mechanism; escalation is not a `delegate-log` CLI flag. If approval is denied, leave the task incomplete. Never silently redirect logs into a repository, git worktree, or temporary path. A different `DELEGATE_CODEX_LOG_DIR` is allowed only when the user explicitly configures a persistent, absolute, Codex-writable path outside every git worktree.

Run Claude CLI reviews serially against the default persistent log location. Do not split per-reviewer log directories or merge logs afterward; serialization prevents `runs.jsonl` and `cooldowns.json` races. The runner rejects symlinks for those metadata files, and `delegate-log` rejects a symlinked `delegation-log.jsonl`. Log-directory creation failures retain the literal OS error and absolute target path.

Authenticate Claude Code yourself:

```bash
claude auth status
claude auth login
```

The skill-local `.env` is never sourced as shell. Its non-comment lines are statically limited to `DELEGATE_CODEX_LOG_DIR=<value>` and `CLAUDE_BIN=<value>`. Symlinks, unknown keys, CR/TAB, and shell syntax such as command substitution fail closed. Explicit process environment variables take precedence over `.env`.

See [README.ja.md](README.ja.md) for setup, runner usage, tests, and security details. The skill body is written in Japanese.
