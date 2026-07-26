# anytools-agent-skills

Claude Code / Codex 用の Agent Skills 集です。各スキルの詳細は**スキルごとの README** を参照してください(スキル本文はすべて日本語)。

**English summary: see [README.md](README.md).**

## スキル一覧

| スキル | 概要 |
|---|---|
| [delegate](skills/delegate/README.ja.md) | Claude Code を司令塔にして、外部 AI CLI(OpenAI Codex / xAI Grok / Google Antigravity)へ実装・調査・独立レビューを安全に委任する規約。安全ランナー `delegate-run`(sandbox 必須化・実行記録・limit cooldown)同梱 |
| [delegate-codex](codex-skills/delegate-codex/README.ja.md) | Codex を司令塔にして native subagent へ調査・実装を委任し、Claude Code CLI を主レビュー役にする規約。read-only レビュー runner、実行記録、cooldown を同梱 |
| [wordpress-to-200stack](skills/wordpress-to-200stack/README.md) | WordPress サイトを microCMS + Next.js 静的エクスポートへ移行して 200stack に公開する手順。決定的 CLI `wpkit` と品質ゲート同梱 |

## インストール

### A. Claude Code プラグインとして(全スキル一括・推奨)

```bash
claude plugin marketplace add anytools-app/anytools-agent-skills
claude plugin install anytools-agent-skills
```

### B. git clone + symlink(使いたいスキルだけ / git で直接管理したい場合)

```bash
git clone https://github.com/anytools-app/anytools-agent-skills.git
cd anytools-agent-skills
ln -s "$PWD/skills/delegate" ~/.claude/skills/delegate                                  # 使いたいスキルごとに
ln -s "$PWD/skills/wordpress-to-200stack" ~/.claude/skills/wordpress-to-200stack
```

`~/.claude/skills/` 配下は次回セッションから自動で読み込まれ、リポジトリを `git pull` すればスキルも更新されます。スキル固有のセットアップ(delegate の `.env`・司令塔モデル設定など)は各スキルの README を参照してください。

### C. Codex plugin として(delegate-codex)

```bash
codex plugin marketplace add anytools-app/anytools-agent-skills
codex plugin add anytools-agent-skills-codex@anytools-agent-skills
```

symlink で入れる場合は [delegate-codex README](codex-skills/delegate-codex/README.ja.md) を参照してください。レビューroutingは標準=`sonnet / high`、高=`opus / high`、最重要=`fable / high`です。`AGENTS.md` からの既定利用のため暗黙起動は有効ですが、スキル起動自体は外部送信の承認ではありません。ユーザーが指定・開いたユーザー管理 repo の最小限の対象コード・diff・マスク済みテスト結果・非秘密タスク要約を使う Anthropic Claude Fable `fable / high` read-only 最重要レビューだけは限定的な恒常承認の対象です。Sonnet / Opus と条件外の送信は引き続きタスク単位の明示承認が必要です。Opus standing は現在未対応で、ユーザーが限定条件を明示承認し規約へ追加するまでは Opus をタスク単位の `explicit` とします。また、利用した全タスクで最終応答前の `delegate-log` 成功が完了条件です。subagent利用時はschema v2の委任eventをメインCodexが記録し、append lock 内で不正lifecycleを拒否し、既存lockは自動削除せずfail-closedし、過去の不正lifecycleだけをappend-only `delegation_correction` で補正します。正常な未閉鎖delegationを隠すcorrectionは拒否し、`required_model` / `actual_model` / `review_status` を使い、read-onlyの`--audit-all`成功も完了条件です。managed sandbox が既定の永続ログ先を拒否した場合は同一コマンドを実行環境側で escalation し、repo・一時パスへ黙って切り替えません。

## セキュリティ

スキルの性質上の注意(外部 AI へのコード送信、外部サービスへの書き込みなど)は [SECURITY.md](SECURITY.md) と各スキルの README「ネットワークアクセスと破壊的操作」に記載しています。

## バージョン

[CHANGELOG.md](CHANGELOG.md) と [GitHub Releases](https://github.com/anytools-app/anytools-agent-skills/releases) を参照(SemVer)。

## ライセンス

[MIT](LICENSE)
