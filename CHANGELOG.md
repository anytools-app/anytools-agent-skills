# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.10.0] - 2026-07-14

### Added

- **委任ログに `rework_of`(人間差し戻しの追跡)を追加**: 司令塔が採用した成果物に後から人間が NG を出して発生した委任にだけ、元委任の run_id か task 要約を記録する(それ以外は null)。`cause` が委任先起因の手戻りを測るのに対し、`rework_of` は司令塔レビューの見逃し率(rework_of 付き件数 ÷ 採用件数)を測る別軸。lessons に集計コマンドと「率が上がり続けたら司令塔レビュー強化を検討」の基準を追加(138件見直しで、人間差し戻し起点の委任が task 命名の痕跡でしか判別できないことが判明したため)

## [0.9.0] - 2026-07-14

### Added

- **委任ログの `cause` に `none`(手戻りなし)を追加**: 修正指示なし、または独立レビュー反映など正常工程の resume のみで完了した委任は `none` を記録する。`unknown` は「手戻りがあったが原因未特定」専用に戻し、空文字は不可と明記(131件見直しで、手戻りなし委任の `unknown` 流用と空文字9件が実発生し、cause 集計のシグナルが濁っていたため)

## [0.8.0] - 2026-07-13

### Changed

- **コスト換算をサブスク按分方式に変更**: サブスク・定額プランも固定費として費用に反映する。単価(USD per 1M tokens)は `.env` の `COST_PER_MTOK_{GROK,CODEX,AGY,CLAUDE_AGENT}` で設定し、サブスク勢は「月額 USD ÷ 月間総トークン(百万)」の按分単価を書く(契約・使用量に依存する社内情報のためリポジトリには置かない。grok のみ API 公開単価 2.00 を既定に持つ)
- 単価未設定の CLI は cost_usd を出さず、サマリで設定方法を案内
- `--estimate-cost` が claude-agent に対応(Agent ツールの usage 表示を委任ログの cost_usd へ換算する用)
- lessons: 按分単価の分母(月間総トークン)はログ見直しの節目で実測し直して `.env` を更新する運用を明記(codex の実測手順付き)
- テスト 75→78 件

## [0.7.0] - 2026-07-13

### Added

- **実費(USD)への換算**: トークン数より直感的な「価格」でコストを扱えるように
  - `delegate-run` が tokens から `cost_usd` を自動計算してサマリ表示+`runs.jsonl` に記録。単体換算は `--estimate-cost <cli> <tokens>`
  - 実費が発生するのは Grok の従量課金のみ($2.00/1M input 単価による近似。セッション記録に in/out 内訳がないため input 支配的な委任の性質を利用)。codex(ChatGPT サブスク)・agy(個人クォータ)・claude-agent(サブスク)は実費 0
  - 委任ログに `cost_usd` フィールドを追加。lessons の集計・見直し観点を「実費は cost_usd・クォータ消耗は tokens」の二軸に更新
  - 単価は `cost_usd()`(bin)と grok adapter に記録し、改定時に両方更新する運用
  - テスト 72→75 件

## [0.6.0] - 2026-07-13

### Added

- **トークン使用量の計測**: 委任のコスト効率をデータで見直せるようにする仕組み
  - `delegate-run` が実行後に codex(セッション JSONL の `token_count`)/ grok(`signals.json` の `contextTokensUsed`)からトークン使用量を自動抽出し、サマリ表示+`runs.jsonl` に記録(`tokens_total` / `tokens_detail`)。単体取得は `--extract-tokens <cli> <SESSION_ID>`。agy は保存形式が SQLite のため未対応
  - 委任ログ(delegation-log.jsonl)に `tokens` フィールドを追加(総トークン数。claude-agent は Agent ツールの usage 表示から転記)
  - lessons「ログの見直し」にトークン効率の集計コマンドと見直し観点を追加: 同種タスクで品質が同等なら tokens の低いティアへ寄せる。3件未満の組では動かさない
  - テスト 68→72 件

## [0.5.0] - 2026-07-13

### Changed

- **独立レビューを3系統の持ち回りに変更**: Antigravity(Gemini)/ Claude サブエージェント / Grok(grok-4.5)を均等に使う(コスト構造とクォータ消耗の分散、レビュー視点の多様化)。選ぶ前に委任ログで直近のレビュー担当を確認し、最も使っていない系統を選ぶ。高リスク変更のレビューは司令塔と同系の Claude サブエージェントを避け、異系統を優先
- Codex adapter: GPT-5.6 canary 完了(119件見直しで Terra 62/64・Sol 3/3・Luna 3/3 の全ティア昇格確定)
- lessons(Codex): 「model at capacity」はサーバ側の一時飽和でアカウント limit と区別する(cooldown せずフォールバック表の旧モデルで続行)
- README をスキルごとに分割: ルートの README / README.ja はスキル一覧のインデックスになり、詳細は `skills/delegate/README(.ja).md` と `skills/wordpress-to-200stack/README.md` へ移動
- plugin / marketplace マニフェストの description を複数スキルパック前提に更新

### Added

- **wordpress-to-200stack スキル**: WordPress サイトを microCMS + Next.js 静的エクスポートに変換して 200stack にデプロイする移行手順。決定的 CLI「wpkit」(analyze / parse / media / archive / schema gen / import / verify)を `kit/` に同梱(TypeScript、テスト26件)。WXR 分析 → mapping config → 冪等入稿 → デザイン忠実再現(委任規律込み)→ 新旧照合 → 200stack 公開までを4つの品質ゲートで規定。実案件の移行(公開599件・画像7,511点)をパイロットに実データ検証済み

### Changed(76件時点の委任ログ見直し 2026-07-12)

- lessons(Grok): grok-4.5 の再計測完了 — agy cooldown 中の代替レビュー4件+相談1件が全採用・反証 blocker ゼロ。agy 代替の独立レビュー先として実証済み
- SKILL.md(委任ログ): 独立レビュー指摘の反映 resume は cause に数えない(根因が指示書の誤り・欠落の場合のみ `instruction`)ことを明確化

### Changed(52件時点の委任ログ見直し 2026-07-12)

- Codex adapter: GPT-5.6 canary を更新 — Terra(実装22件全採用・全pass)に加え Sol も 3/3 で昇格確定。canary 記録の継続は Luna のみ
- Codex adapter / templates: 相談・設計ドラフト依頼の締め文に「リポジトリの読み取り・検索は積極的に行う」を明記(禁止文言だけ                書くと read-only 過解釈で repo 未読のまま回答される実測への対策)
- lessons(Codex): workspace-write sandbox の listen 制限で dev server・テストが委任先で実行不能(実測2件)→ 指示書で司令塔実行を明記
- lessons(Grok): grok-4.20-non-reasoning のコードレビューで反証可能な blocker 提出(2件、cause:model)→ レビューは grok-4.5 を使い、blocker は実コードで反証してから採否
- lessons(Antigravity): 「Individual quota reached」のリセットは約108時間の実測 → cooldown 108h 推奨

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
