# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.4.0] - 2026-07-12

### Added

- **limit cooldown 機構**: limit・クォータ切れの CLI を「使ってみる→失敗→代替」と毎回試さないための仕組み
  - `delegate-run --set-cooldown <cli> <期間>` / `--clear-cooldown` / `--cooldowns` で記録・解除・一覧(状態はログディレクトリの `cooldowns.json`。セッション・プロジェクト横断で共有)
  - cooldown 中の CLI への委任は実行前に拒否し、代替先を案内(`--force` で強行可)
  - limit パターンを含む失敗(exit≠0)は自動で 1h 記録。exit 0 での検知は警告に留めて判断を司令塔へ残す
  - SKILL.md「委任先の limit と cooldown」: 代替ルーティング表(agy→grok-4.5 / grok→agy / codex→分割 or Grok workspace)と、代替委任を委任ログへ記録する規約
  - テスト 57→68 件

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
