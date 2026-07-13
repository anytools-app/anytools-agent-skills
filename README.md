# anytools-agent-skills

A collection of Agent Skills for Claude Code. See **each skill's README** for details — **the skill bodies are written in Japanese**; this root README and per-skill English summaries serve as the index.

日本語のインデックスは [README.ja.md](README.ja.md) を参照してください。

## Skills

| Skill | Summary |
|---|---|
| [delegate](skills/delegate/README.md) | Delegation protocol that turns Claude Code into an orchestrator routing implementation, research, and independent review to external AI CLIs (OpenAI Codex / xAI Grok / Google Antigravity). Ships `delegate-run`, a safe command runner with mandatory sandboxing, run logging, and limit cooldowns |
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

## Security

Skill-inherent caveats (code sent to external AI vendors, writes to external services) are documented in [SECURITY.md](SECURITY.md) and each skill's README.

## Versioning & License

[CHANGELOG.md](CHANGELOG.md) and [GitHub Releases](https://github.com/anytools-app/anytools-agent-skills/releases) (SemVer). [MIT](LICENSE).
