# delegate — delegation protocol for external AI CLIs

Turns Claude Code into an **orchestrator** which safely delegates implementation, research, and independent review to external AI CLIs — OpenAI Codex, xAI Grok, and Google Antigravity (Gemini).

**Note: the skill body is written in Japanese.** This README is an English summary; see [README.ja.md](README.ja.md) for full documentation.

## What it does (30 seconds)

`delegate` is a **delegation protocol**, not a prompt pack. Claude Code keeps design, work instructions, artifact review, and commits, while routing:

- everyday implementation → **Codex**
- web/X and breaking-news research → **Grok**
- large-context reading, docs research, independent review → **Antigravity (Gemini)**
- cheap pre-design code reading → **Claude subagents**

Every delegation goes through an auditable loop: baseline measurement → written instruction → sandboxed execution via `bin/delegate-run` → file-manifest cross-check → full diff review → one-line JSONL log entry. Rate-limited CLIs are recorded as cooldowns and rejected before execution instead of being retried every time.

## Setup

Install the repository first (see the [root README](../../README.md)), then:

```bash
cp .env.example .env    # in this directory, if you want a custom log location
```

### Pin the orchestrator model (recommended)

The skill assumes the model you talk to — the main Claude Code session — is the single, pinned orchestrator. You never re-pick the orchestrator per task: implementation tokens flow to the workers, and per-task model selection happens on the worker side (Codex Luna/Terra/Sol etc.), so the orchestrator should simply be the strongest model you have — its diff-review quality is the ceiling for everything the workers produce.

Add one line to `~/.claude/settings.json`:

```json
{
  "model": "best"
}
```

- `"best"` is an official alias resolving to Fable 5 where you have access, otherwise the latest Opus
- The skill never changes the main session's model or effort while running (no frontmatter overrides)
- Optionally pair with `"effortLevel": "high"` for maximum orchestrator judgment, at higher token cost

### Log location

Configurable via `.env` (precedence: process env > `.env` > default `~/.claude/logs/delegate`):

```bash
DELEGATE_LOG_DIR=/path/to/your/logs
```

Logs (`delegation-log.jsonl`, `runs.jsonl`, `cooldowns.json`) contain descriptions of what you delegated, so they are intentionally kept out of the repository.

## Requirements

- **Claude Code only** (this skill encodes an asymmetric orchestrator/worker relationship, so a Codex-side plugin would be meaningless)
- Tested on macOS; `delegate-run` is plain bash
- Install only the worker CLIs you actually use: Codex CLI, Grok CLI (`XAI_API_KEY`), Antigravity CLI (`agy`)
- `jq`, `git`, `uuidgen`

## Network access & destructive operations

- The skill itself (markdown + `delegate-run`) makes no network calls
- **Running a delegation sends the code each worker CLI reads to that vendor's API** — the protocol includes explicit rules to keep `.env` files, secrets, and customer data out of delegated context (see [SECURITY.md](../../SECURITY.md))
- `delegate-run` never commits, pushes, or deletes; write delegations are confined to each CLI's sandbox and dangerous bypass flags are rejected
