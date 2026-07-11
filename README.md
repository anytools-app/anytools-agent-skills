# anytools-agent-skills

Agent Skills that turn Claude Code into an **orchestrator** which safely delegates implementation, research, and independent review to external AI CLIs — OpenAI Codex, xAI Grok, and Google Antigravity (Gemini).

**Note: the skill body is written in Japanese.** This README is an English summary; see [README.ja.md](README.ja.md) for full documentation.

## What it does (30 seconds)

The `delegate` skill is a **delegation protocol**, not a prompt pack. Claude Code keeps design, work instructions, artifact review, and commits, while routing:

- everyday implementation → **Codex**
- web/X and breaking-news research → **Grok**
- large-context reading, docs research, independent review → **Antigravity (Gemini)**
- cheap pre-design code reading → **Claude subagents**

Every delegation goes through an auditable loop: baseline measurement → written instruction → sandboxed execution via `bin/delegate-run` → file-manifest cross-check → full diff review → one-line JSONL log entry.

## Install

```bash
claude plugin marketplace add anytools-app/anytools-agent-skills
claude plugin install anytools-agent-skills
```

Or clone and symlink (if you want to manage the skill via git directly):

```bash
git clone https://github.com/anytools-app/anytools-agent-skills.git
cd anytools-agent-skills
cp skills/delegate/.env.example skills/delegate/.env
ln -s "$PWD/skills/delegate" ~/.claude/skills/delegate
```

## Pin the orchestrator model (recommended)

The skill assumes the model you talk to — the main Claude Code session — is the single, pinned orchestrator (see 「窓口(司令塔モデル)の固定」 in `SKILL.md`). You never re-pick the orchestrator per task: implementation tokens flow to the workers, and per-task model selection happens on the worker side (Codex Luna/Terra/Sol etc.), so the orchestrator should simply be the strongest model you have — its diff-review quality is the ceiling for everything the workers produce.

Add one line to `~/.claude/settings.json`:

```json
{
  "model": "best"
}
```

- `"best"` is an official alias resolving to Fable 5 where you have access, otherwise the latest Opus — the "which model?" decision disappears and the pin survives model generations
- The skill never changes the main session's model or effort while running (no frontmatter overrides); only worker-side models and efforts vary per task
- Optionally pair with `"effortLevel": "high"` for maximum orchestrator judgment, at higher token cost

## Configuration

Log destination is configurable via `skills/delegate/.env` (precedence: process env > `.env` > default `~/.claude/logs/delegate`):

```bash
DELEGATE_LOG_DIR=/path/to/your/logs
```

Logs contain task descriptions of what you delegated, so they are intentionally kept out of the repository (`.gitignore`d).

## Requirements

- **Claude Code only** (this skill encodes an asymmetric orchestrator/worker relationship, so a Codex-side plugin would be meaningless — the directory layout still follows the open Agent Skills format)
- Tested on macOS; `delegate-run` is plain bash
- Install only the worker CLIs you actually use: Codex CLI, Grok CLI (`XAI_API_KEY`), Antigravity CLI (`agy`)
- `jq`, `git`, `uuidgen`

## Network access & destructive operations

- The skill itself (markdown + `delegate-run`) makes no network calls
- **Running a delegation sends the code each worker CLI reads to that vendor's API** — the protocol includes explicit rules to keep `.env` files, secrets, and customer data out of delegated context (see [SECURITY.md](SECURITY.md))
- `delegate-run` never commits, pushes, or deletes; write delegations are confined to each CLI's sandbox and dangerous bypass flags are rejected

## License

[MIT](LICENSE)
