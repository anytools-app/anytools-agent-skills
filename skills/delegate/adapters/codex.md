# Codex adapter(codex CLI / OpenAI)

役割: **通常実装のデフォルト委任先**。コード密着の read-only 相談・詳細設計ドラフトのレビューにも使う。**Web 調査には使わない**(委任時は web_search を切って運用する。Web が要るタスクは Grok / Antigravity へ)。

## モデル表(GPT-5.6 ファミリ / 2026-07-10 改定)

通常の実装ルーティングは GPT-5.6 ファミリ(Sol / Terra / Luna)を主系統とする。根拠: 公式モデルページ https://developers.openai.com/codex/models の世代交代 — Terra は「everyday work」で従来 GPT-5.5 に振っていた作業の移行先、Sol は「ambiguous, difficult, or high-value tasks」、Luna は「specific, high-volume tasks」。手元の codex 0.144.0 + ChatGPT アカウントで3モデルとも `codex exec` 動作確認済み。

| タスク | 例 | フラグ |
|---|---|---|
| 機械的な作業 | リネーム、定型コード追加、雛形作成、仕様が完全に固定されたテスト追加 | `-m gpt-5.6-luna -c 'model_reasoning_effort="medium"'` |
| 標準的な実装 | 通常の機能追加・障害修正 | `-m gpt-5.6-terra -c 'model_reasoning_effort="medium"'` |
| 横断的な標準実装 | 複数レイヤー、状態遷移、DB移行、並行処理を伴う変更 | `-m gpt-5.6-terra -c 'model_reasoning_effort="high"'` |
| 難所 | 複雑なリファクタ、原因不明の障害、高い退行リスク | `-m gpt-5.6-sol -c 'model_reasoning_effort="high"'` |

- 迷ったら `gpt-5.6-terra / medium`。このスキルでは Claude Code が設計を確定してから実装を渡すため、標準実装で Sol をデフォルトにしない
- Luna は「何を変更するか」「正解が何か」が明確な作業に限る。仕様解釈・設計判断・複数案の比較が必要なら Terra へ上げる
- Terra は通常実装の主力。複数ファイルという理由だけで Sol に上げず、曖昧さ・影響範囲・退行リスクで判断する
- Sol は、設計後もなお難しい作業に限定する。Sol を頻繁に使う状態は、モデル不足ではなくタスク分割または指示書の不足を疑う
- GPT-5.5 の effort と GPT-5.6 の effort に正確な対応関係はない(公式に「no exact mapping」と明記)。旧設定の `high` / `xhigh` をそのまま移植せず、低い effort から試して委任ログで評価する
- **canary 記録(2026-07-10 開始)**: **Terra・Sol は昇格確定**(2026-07-12 の52件見直し: Terra 実装22件すべて採用・pass・routing適正・scope違反0。Sol は canary 3/3 到達、相談・レビュー計4件で採用中心)。**Luna のみ 1/3 継続** — Luna を使う時だけ note に「GPT-5.6 canary luna n/3」を記録する。昇格・差し戻しの判定は `../lessons.md`「ログの見直しと昇格条件」の更新条件に従う。Luna が弱ければ Terra へ、Terra が過剰なら Luna へ寄せる
- `-m` が「not supported when using Codex with a ChatGPT account」で失敗したら、ユーザーに TUI の `/model` で現行一覧を確認してもらい、この表を更新する

### GPT-5.6 Sol の max / ultra(例外扱い)

- `gpt-5.6-sol / max` は、レビュー可能な単位へ分割できず、深さが速度・クォータより重要な最難関に限る(単一エージェントに深い推論時間を与える)。通常のモデル表には入れない
- `ultra` は Codex 内部でサブエージェントを使うモード(公式: 「uses subagents to accelerate complex work」)。**通常の書き込み委任には使わない** — どの内部エージェントが何を判断したかが不透明になり、Claude Code 側のマニフェスト照合・原因分析・委任ログ評価が弱くなる(このスキル側に既にルーティング・worktree分離のオーケストレーションがあり二重化する)
- 使うとしても read-only の複数観点レビュー・大規模調査に限定する
- `max` / `ultra` は TUI の `/model` で対象モデルに表示され、実際に利用可能であることを確認してから使う

### 旧モデル・プレビュー系(フォールバック)

GPT-5.6 系が使えない・canary で不適と判明した場合の明示的なフォールバック:

| GPT-5.6 | フォールバック |
|---|---|
| `gpt-5.6-luna` | `gpt-5.4-mini` または `gpt-5.3-codex-spark` |
| `gpt-5.6-terra` | `gpt-5.4` |
| `gpt-5.6-sol` | `gpt-5.5`(公式上は前世代 frontier) |

- `gpt-5.3-codex-spark` は ChatGPT Pro 向けのテキスト専用 research preview。速度最優先の小さな作業に限り、画像・スクリーンショットを含む作業や長い文脈が要る作業には使わない
- フォールバックは自動で行わない。指定モデルが失敗した場合は、実際の `/model` 一覧を確認し、使用モデルを明示的に変更する
- 委任ログの `model` には、要求したモデルではなく実際に使用したモデル名を記録する
- `gpt-5.2-codex` / `gpt-5.5-codex` など API 向けモデル名は ChatGPT アカウントでは 400 エラー(実測)

## canonical command(書き込み委任)

```bash
codex exec \
  --sandbox workspace-write \
  -c 'approval_policy="never"' \
  -c 'web_search="disabled"' \
  -m <モデル> \
  -c 'model_reasoning_effort="<effort>"' \
  --cd <プロジェクトルートの絶対パス> \
  "$(cat <scratchpadの実装指示書>)" \
  > <scratchpadのログファイル> 2>&1 < /dev/null
```

- `--sandbox workspace-write` を**毎回明示する**(config デフォルトに依存しない)。書き込みは作業ディレクトリと /tmp に限定される。`danger-full-access` と `--dangerously-bypass-approvals-and-sandbox` は禁止
- `-c 'approval_policy="never"'` を**毎回明示する**。非対話実行では「境界外の操作は承認待ちにせず失敗させ、失敗内容を司令塔が判断する」が正しい形。**CLI フラグ `--ask-for-approval` は `codex exec` では使えない**ため、必ず config キーで渡す(実測の経緯は `../lessons.md`「Codex」)
- `-c 'web_search="disabled"'` を**毎回明示する**。codex 本体の web search ツールは sandbox とは別レイヤーで、デフォルトは cached(OpenAI 管理のインデックス検索)。公開 docs 上の値は `disabled|cached|live`。委任運用で使うのは `disabled` のみ。実装委任に調査を混ぜず、Web調査が要るタスクは Grok / Antigravity に分岐する
- `-m` と `model_reasoning_effort` は**毎回明示する**。config のデフォルトモデル・effort は Codex の更新やローカル設定で変わるため、特定の固定値を前提にしない。明示しない実行は委任ログの比較可能性も失わせる
- `--cd` は **git リポジトリ内(信頼済みディレクトリ)を指す**。リポジトリ外(scratchpad 等)を指すと「Not inside a trusted directory」で即失敗する(0.144.0 実測)。`--skip-git-repo-check` での回避はしない。worktree に向ける場合は `--cd <worktreeの絶対パス>`
- `--full-auto` は使わない(deprecated で `--sandbox workspace-write` の別名にすぎない)
- workspace-write でも**シェルコマンドのネットワークはデフォルト遮断**。依存パッケージの追加が必要なら、`npm install` 等は Claude Code 側で先に済ませてから委任する

## read-only 相談

書き込みが不要な相談(バグの原因調査・設計のセカンドオピニオン・別アプローチ探索)も、実装委任と同じ規律で実行する(相談時だけ雑にすると後で汚染源になる):

```bash
codex exec \
  --sandbox read-only \
  -c 'approval_policy="never"' \
  -c 'web_search="disabled"' \
  -m <モデル> \
  -c 'model_reasoning_effort="<effort>"' \
  --cd <プロジェクトルートの絶対パス> \
  "$(cat <scratchpadの質問ファイル>)" \
  > <scratchpadのログファイル> 2>&1 < /dev/null
```

- 質問ファイルの締めは相談用に差し替える: 「確認や質問は不要です。リポジトリの読み取り・検索は積極的に行ってください(禁止はファイルの作成・変更のみ)。具体的な提案・修正案・コード例まで自主的に出力してください。」(禁止文言だけ書くと read-only を過解釈して repo 未読のまま回答される — 2026-07-12 実測)
- ティアの目安: 軽い相談(仕様確認・小さな疑問)は `gpt-5.6-luna / medium` でクォータを節約。標準的な相談は `gpt-5.6-terra / medium`、設計のセカンドオピニオンなど深い相談は `gpt-5.6-sol / high`(effort は低めから試す)
- 詳細設計ドラフト関連の目安: 設計済み方針の実装可能性確認は `gpt-5.6-terra / high`、複雑な設計の落とし穴・移行・並行処理のレビューは `gpt-5.6-sol / high`、分割不能な最難関の技術設計レビューのみ `gpt-5.6-sol / max`。大規模読解を含む第一ドラフトは Antigravity に置き、Codex は「実装担当視点で詳細設計をレビューする」役割に限る(最終設計は確定させない)
- **Web 調査が目的の相談は codex に投げない**(web_search を切って使うため)

## resume(継続・修正指示)

```bash
codex exec resume <SESSION_ID> \
  -c 'sandbox_mode="workspace-write"' \
  -c 'approval_policy="never"' \
  -c 'web_search="disabled"' \
  -m <元と同じモデル> \
  -c 'model_reasoning_effort="<元と同じeffort>"' \
  "$(cat <scratchpadの修正指示>)" \
  > <scratchpadのログファイル> 2>&1 < /dev/null
```

- `SESSION_ID` は exec 実行時のヘッダー `session id: <uuid>` 行から取得する。**修正指示に備えて、exec 実行のたびに必ず控えておく**(`grep -m1 "session id" <ログファイル>`)
- **`-c 'sandbox_mode=...'`・`approval_policy`・`web_search`・モデル系フラグを必ず付け直す**。resume は元セッションの sandbox・モデル・reasoning effort を引き継がない場合があり(実測記録は `../lessons.md`「Codex」)、config のデフォルト値も更新・環境差で変わるため、今後のバージョンでも継承を期待しない
- `codex exec resume --last` は「マシン全体で最新のセッション」を拾い、無関係なセッションを掴む恐れがあるため使わない。SESSION_ID を明示する

## 実行の作法

- 応答には数分かかる。小さな委任はフォアグラウンド(timeout 600000ms=上限10分)でよいが、**大きな委任(複数ファイル・テスト込み)は Bash の run_in_background で実行し、完了通知が来てからレビューに入る**。フォアグラウンドで上限を超えるとプロセスごと殺され、成果物が中途半端な状態で残る
- **生ログをメイン会話に流し込まない**: stdout は数百KBになるため `> <scratchpadのログファイル> 2>&1` へ逃がし、session id は `grep -m1` で取る。最終レポートは `-o <scratchpadのファイル>` に書き出させ、そのファイルを読む(stderr の MCP 接続エラー等のノイズも一緒に隔離できる)
- **末尾に `< /dev/null` を必ず付ける**。非対話シェルから実行すると codex が stdin を読もうとして無期限にハングする(実測)。長い指示書はスクラッチパッドのファイルに保存し `"$(cat <ファイル>)"` で渡す
- 秘密情報: `shell_environment_policy` 設定で env 継承を絞れるが防波堤にすぎない。`SKILL.md`「秘密情報・外部送信ルール」が一次防御

## セットアップ・認証(失敗した時だけ確認)

- `codex --version` — 未導入/リンク切れなら `brew reinstall --cask codex` を提示
- `codex login status` — 未認証なら、ユーザー自身のターミナルで `codex login` を実行してもらう(ブラウザ認証のため代行不可)
- 「failed to spawn code-mode host /opt/homebrew/bin/codex-code-mode-host」でファイルを読めない場合(回答は返るがリポジトリ未読になる): バイナリは ChatGPT.app に同梱されている。`ln -s "/Applications/ChatGPT.app/Contents/Resources/codex-code-mode-host" /opt/homebrew/bin/codex-code-mode-host` で復旧(2026-07-10 実測。`-c 'features.unified_exec=false'` では回避できない)。**委任先の回答冒頭に「実読できなかった」等の自己申告がないか毎回確認する**

過去の事故・バージョン付き実測記録: `../lessons.md`「Codex」
