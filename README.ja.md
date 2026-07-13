# anytools-agent-skills

Claude Code 用の Agent Skills 集です。各スキルの詳細は**スキルごとの README** を参照してください(スキル本文はすべて日本語)。

**English summary: see [README.md](README.md).**

## スキル一覧

| スキル | 概要 |
|---|---|
| [delegate](skills/delegate/README.ja.md) | Claude Code を司令塔にして、外部 AI CLI(OpenAI Codex / xAI Grok / Google Antigravity)へ実装・調査・独立レビューを安全に委任する規約。安全ランナー `delegate-run`(sandbox 必須化・実行記録・limit cooldown)同梱 |
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

## セキュリティ

スキルの性質上の注意(外部 AI へのコード送信、外部サービスへの書き込みなど)は [SECURITY.md](SECURITY.md) と各スキルの README「ネットワークアクセスと破壊的操作」に記載しています。

## バージョン

[CHANGELOG.md](CHANGELOG.md) と [GitHub Releases](https://github.com/anytools-app/anytools-agent-skills/releases) を参照(SemVer)。

## ライセンス

[MIT](LICENSE)
