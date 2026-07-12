# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.3.0] - 2026-07-12

### Added

- Grok adapter にモデル表を追加: 軽い相談は CLI 既定、Web/X 調査・深い相談・独立レビュー・Antigravity limit 時の大規模読解代替は `--model grok-4.5`(公式フラッグシップ、500k context、configurable reasoning。docs.x.ai と CLI 実測で確認)
- Grok の役割に「Antigravity が limit・障害時の大規模読解・独立レビュー代替」を明記

### Changed

- `delegate-run`: grok の `--model` 拒否を撤廃し任意透過に変更(指定時のみ `--model` を付与)。テストを 55→57 件に更新

## [0.2.0] - 2026-07-11

### Added

- SKILL.md「窓口(司令塔モデル)の固定」: 窓口=最終司令塔の2階層原則、メインセッションの model / effort をスキル・委任フローが変更しない不変条件(frontmatter への `model` / `effort` 記載禁止を含む)、委任先設定のみ可変とする分界、モデル切替に頼らないエスカレーション順。窓口モデルは settings.json の `"model": "best"` 固定を推奨

### Changed

- Grok adapter: 2026-07-11 実測を反映(モデルラインナップの grok-4.20/4.3/4.5 系への世代交代、`--output-format json` の応答構造変更)

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
