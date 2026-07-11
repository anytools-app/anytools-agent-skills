# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-07-11

### Added

- `delegate` skill: 外部AI CLI(Codex / Grok / Antigravity)への委任とモデルルーティングの中核規約
  - `SKILL.md` — 委任可否ゲート、リスク判定、製品判断/技術判断の切り分け、ベースライン規約、成果物レビュー義務、retry budget、worktree 分離、秘密情報ルール、委任ログ
  - `adapters/{codex,grok,antigravity}.md` — CLI 別 canonical command・モデル表・実測済みの罠
  - `templates.md` — 実装指示書 / 詳細設計ドラフト依頼書 / 独立レビュー依頼書
  - `lessons.md` — 事故例・実測記録・ログ見直しと自動化の昇格条件
  - `bin/delegate-run` — sandbox 必須化・ログ隔離・実行記録(runs.jsonl)を自動化する安全ランナー
  - `bin/delegate-run-tests.sh` — 既知事故を変換した dry-run テスト
- ログ保存先の `.env` 設定(`DELEGATE_LOG_DIR`、優先順位: 環境変数 > `.env` > `~/.claude/logs/delegate`)
- Claude Code plugin / marketplace マニフェスト(`.claude-plugin/`)
