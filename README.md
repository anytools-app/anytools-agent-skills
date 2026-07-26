# anytools-agent-skills

A collection of Agent Skills for Claude Code and Codex. See **each skill's README** for details — **the skill bodies are written in Japanese**; this root README and per-skill English summaries serve as the index.

日本語のインデックスは [README.ja.md](README.ja.md) を参照してください。

## Skills

| Skill | Summary |
|---|---|
| [delegate](skills/delegate/README.md) | Delegation protocol that turns Claude Code into an orchestrator routing implementation, research, and independent review to external AI CLIs (OpenAI Codex / xAI Grok / Google Antigravity). Ships `delegate-run`, a safe command runner with mandatory sandboxing, run logging, and limit cooldowns |
| [delegate-codex](codex-skills/delegate-codex/README.md) | Codex-native delegation protocol: native subagents investigate and implement, while Claude Code CLI is the primary independent reviewer. Ships a read-only review runner, run logging, and cooldowns |
| [wordpress-to-200stack](skills/wordpress-to-200stack/README.md) | Gated workflow migrating WordPress sites to microCMS + Next.js static export deployed on 200stack, with the deterministic `wpkit` CLI included (Japanese only) |

## Install

```bash
claude plugin marketplace add anytools-app/anytools-agent-skills
claude plugin install anytools-agent-skills
```

Or clone and symlink just the skills you want:

```bash
git clone https://github.com/anytools-app/anytools-agent-skills.git
cd anytools-agent-skills
ln -s "$PWD/skills/delegate" ~/.claude/skills/delegate
ln -s "$PWD/skills/wordpress-to-200stack" ~/.claude/skills/wordpress-to-200stack
```

Anything under `~/.claude/skills/` auto-loads next session and updates via `git pull`. Skill-specific setup (delegate's `.env`, orchestrator-model pinning, etc.) is documented in each skill's README.

Install `delegate-codex` as a Codex plugin:

```bash
codex plugin marketplace add anytools-app/anytools-agent-skills
codex plugin add anytools-agent-skills-codex@anytools-agent-skills
```

See the [delegate-codex README](codex-skills/delegate-codex/README.md) for symlink setup and Claude authentication. Review routing is standard=`sonnet / high`, high=`opus / high`, critical=`fable / high`. Implicit invocation is enabled for `AGENTS.md`-based defaults, but invocation itself does not approve external transfer. A limited standing approval applies only to Anthropic Claude Fable `fable / high` read-only critical review of user-designated/open user-managed repositories, using minimal target code/diffs, masked test results, and a non-secret task summary under strict exclusions. Sonnet, Opus, and every transfer outside those conditions require task-specific explicit approval. Opus standing approval is currently unsupported; Opus remains task-specific `explicit` until the user explicitly authorizes a limited standing scope and the policy is updated. Every use also requires a successful final `delegate-log` entry; subagent work records schema-v2 lifecycle events, rejects invalid lifecycle transitions under the append lock, fails closed instead of auto-deleting existing locks, supports append-only `delegation_correction` for historical bad lifecycle rows while refusing corrections that would hide healthy open delegations, records `required_model` / `actual_model` / `review_status`, and must pass the read-only `--audit-all`. Managed-sandbox denial of the default persistent log path requires rerunning the same logger command with execution-level escalation, never a silent repository or temporary-path fallback.

## Security

Skill-inherent caveats (code sent to external AI vendors, writes to external services) are documented in [SECURITY.md](SECURITY.md) and each skill's README.

## Versioning & License

[CHANGELOG.md](CHANGELOG.md) and [GitHub Releases](https://github.com/anytools-app/anytools-agent-skills/releases) (SemVer). [MIT](LICENSE).
