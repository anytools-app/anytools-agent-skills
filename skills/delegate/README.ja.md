# delegate — 外部AI委任とモデルルーティング

Claude Code を**司令塔**にして、外部 AI CLI(OpenAI Codex / xAI Grok / Google Antigravity)へ実装・調査・独立レビューを安全に委任するためのスキルです。

**English summary: see [README.md](README.md). The skill body is written in Japanese.**

## 30秒サマリ

`delegate` は「マルチエージェントの委任規約」です。Claude Code が設計・実装指示書・成果物レビュー・コミットを握ったまま、

- 通常実装 → **Codex**
- Web/X・速報系の調査 → **Grok**
- 大規模読解・ドキュメント調査・独立レビュー → **Antigravity(Gemini)**
- 設計前の安価なコードリーディング → **Claude サブエージェント**

にタスクを振り分けます。プロンプト集ではなく、**ベースライン計測 → 指示書 → sandbox付き実行 → マニフェスト照合 → diff レビュー → 委任ログ記録**という監査可能なループを規約化したものです。

## Before / After

| | Before(素の Claude Code) | After(delegate 導入後) |
|---|---|---|
| 委任コマンド | 毎回アドホック。sandbox 指定漏れ・stdin ハング・resume でフラグ消失 | `bin/delegate-run` が canonical command を生成(既知事故はテストケース化済み) |
| 成果物の受け入れ | 委任先の「完了しました」を信用しがち | マニフェスト照合・全 diff レビュー・ベースライン比較が必須工程 |
| 設計判断 | 外部AIに丸投げされがち | 詳細設計は「ドラフト」まで。最終設計・製品判断・コミットは Claude Code |
| limit・クォータ切れ | 毎回「使ってみる→失敗→代替」 | cooldown を記録し、実行前に拒否して代替へ直行 |
| 振り返り | 記録なし | 全委任を JSONL に記録し、10件ごとにルーティングを見直し |

## セットアップ

インストール(リポジトリ共通)は[ルートの README](../../README.ja.md) を参照。このスキル固有の設定:

```bash
cp .env.example .env   # このディレクトリ内。ログ保存先を変えたい場合に編集
```

### 司令塔モデルの固定(推奨)

このスキルは「ユーザーが話しかける相手 = メインセッションの Claude Code(司令塔)」を1つに固定する前提で設計されています(`SKILL.md`「窓口(司令塔モデル)の固定」)。タスクごとに司令塔のモデルを選び直す必要はありません — 実装トークンは委任先へ流れ、モデルの使い分けは委任先側(Codex の Luna/Terra/Sol 等)で行うため、司令塔は常に使える中で最上位のモデルに固定するのが合理的です。司令塔の diff レビュー品質が、委任成果物すべての品質上限になります。

`~/.claude/settings.json` に1行追加します:

```json
{
  "model": "best"
}
```

- `"best"` は「Fable 5 にアクセスがあれば Fable 5、なければ最新の Opus」に解決される公式エイリアスです。「どのモデルにするか」という選択自体がなくなり、モデル世代が変わっても自動で追従します
- スキル側は動作中にメインセッションのモデル・effort を**変更しません**(frontmatter による上書きもしない設計)。タスクに応じて変わるのは委任先のモデル・effort だけです
- 司令塔の判断の質を最大化したい場合は `"effortLevel": "high"` の併用も検討してください(トークン消費は増えます)

### ログ保存先(.env)

ログの保存先は `.env` で変更できます(環境変数 > `.env` > デフォルトの優先順位):

```bash
# skills/delegate/.env
DELEGATE_LOG_DIR=/path/to/your/logs   # 省略時: ~/.claude/logs/delegate
```

- `delegation-log.jsonl` — 委任の評価ログ(採否・ルーティング判定)
- `runs.jsonl` / `runs/*.log` — `delegate-run` の実行記録と生ログ
- `cooldowns.json` — limit 中の CLI の記録(セッション・プロジェクト横断で共有)

ログには委任したタスク内容が含まれるため、**リポジトリにはコミットしない**設計です(`.gitignore` 済み)。

## 実行例

```text
User:
この認証バグの修正、codexに実装させて

Claude Code(delegate スキル):
1. 委任可否ゲート → 委任対象と判定、リスク=高(認証)
2. ベースライン計測(typecheck / テスト / git status)
3. 実装指示書を scratchpad に作成(変更するユーザー可視挙動・スコープ外を明記)
4. bin/delegate-run --cli codex --mode write --model gpt-5.6-terra --effort medium \
     --cd /path/to/repo --prompt-file instruction.md
5. マニフェスト照合 + git diff 全読み + ベースライン比較
6. 高リスクのため Antigravity にブラインド独立レビューを依頼
7. 合格した変更だけ Claude Code がコミットし、委任ログに1行記録
```

「grokに聞いて」「agyでレビューして」「セカンドオピニオンが欲しい」などでも起動します。

## 構成

```text
skills/delegate/
├── SKILL.md          # 中核規約(委任可否ゲート・リスク判定・レビュー義務・cooldown・委任ログ)
├── adapters/         # CLI別の canonical command・モデル表・実測済みの罠
│   ├── codex.md
│   ├── grok.md
│   └── antigravity.md
├── templates.md      # 実装指示書・詳細設計ドラフト依頼・独立レビュー依頼
├── lessons.md        # 事故例・実測記録・ログ見直しの昇格条件
├── bin/
│   ├── delegate-run           # 安全なコマンドランナー(sandbox必須化・ログ隔離・実行記録・limit cooldown)
│   └── delegate-run-tests.sh  # 既知事故を変換した dry-run テスト
└── .env.example
```

## 対応環境・前提

- **Claude Code 専用**(CLI / デスクトップ)。スキル本文は日本語
- macOS で実測・運用(`delegate-run` は bash スクリプト)
- 委任先 CLI は使うものだけ導入すればよい:
  - [Codex CLI](https://developers.openai.com/codex)(`codex`)
  - [Grok CLI](https://docs.x.ai/)(`~/.grok/bin/grok`、`XAI_API_KEY` 必要)
  - [Antigravity CLI](https://antigravity.google/)(`agy`)
- `jq`、`git`、`uuidgen`(macOS 標準)

### なぜ Codex 用プラグインを同梱しないのか

このスキルは「Claude Code が司令塔、Codex は委任先」という**非対称な役割**を規約化したものなので、Codex 側にインストールする意味がありません。ディレクトリ構成は Agent Skills のオープン標準(`SKILL.md` + `scripts`/`references`)に準拠しています。

## ネットワークアクセスと破壊的操作

- スキル自体(ドキュメント+`delegate-run`)は外部ネットワークにアクセスしません
- ただし**委任を実行すると、各 CLI が読んだコード・指示書は各社の API に送信されます**。`SKILL.md`「秘密情報・外部送信ルール」で `.env`・秘密鍵・顧客データを読ませない規律を定めています([SECURITY.md](../../SECURITY.md))
- `delegate-run` はコミット・プッシュ・ファイル削除を行いません。書き込み委任は各 CLI の sandbox(workspace-write 等)に限定し、bypass 系フラグの生成を拒否します
