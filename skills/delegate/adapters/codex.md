# Codex adapter(codex CLI / OpenAI)

役割: **通常実装のデフォルト委任先**。コード密着の read-only 相談・詳細設計ドラフトのレビューにも使う。**Web 調査には使わない**(委任時は web_search を切って運用する。Web が要るタスクは Grok / Antigravity へ)。

## モデル表(GPT-5.6 主系統 + GPT-6 Astra は「ここ一番」限定 / 2026-09-19 改定)

通常実装は GPT-5.6 ファミリ(Terra / Luna)、難所は Sol を主系統とし、GPT-6 Astra は週予算つきの「ここ一番」に限る(下記「Astra の使用条件と週予算」)。各モデルの位置づけの根拠: 公式モデルページ https://learn.chatgpt.com/docs/models (旧 https://developers.openai.com/codex/models から 308 リダイレクト)は Astra を「Our most capable model for complex work across code, apps, and research」と位置づけ、複数ステップ・複数ツールにまたがる持続的な推論と判断を要する end-to-end のワークフロー向けとしている。Sol は「ambiguous, difficult, or high-value」、Terra は日常作業の自然な起点、Luna は成功条件が明確な高頻度作業という位置づけを維持している。

手元の `~/.codex/models_cache.json` (`fetched_at`: 2026-09-04 / client 0.153.0)で Astra・Sol・Terra・Luna が `visibility:"list"` に含まれることを確認済み。codex 0.153.2 で `codex exec --sandbox read-only -m gpt-6-astra -c 'model_reasoning_effort="low"'` の疎通を実測済み(exit 0、リポジトリのファイルも実読)。Astra の supported effort は `low` / `medium` / `high` / `xhigh` / `max` / `ultra`、default は `medium`。

| タスク | 例 | フラグ |
|---|---|---|
| 機械的な作業 | リネーム、定型コード追加、雛形作成、仕様が完全に固定されたテスト追加 | `-m gpt-5.6-luna -c 'model_reasoning_effort="medium"'` |
| 標準的な実装 | 通常の機能追加・障害修正 | `-m gpt-5.6-terra -c 'model_reasoning_effort="medium"'` |
| 横断的な標準実装 | 複数レイヤー、状態遷移、DB移行、並行処理を伴う変更 | `-m gpt-5.6-terra -c 'model_reasoning_effort="high"'` |
| 難所 | 複雑なリファクタ、原因不明の障害、高い退行リスク | `-m gpt-5.6-sol -c 'model_reasoning_effort="high"'` |
| 最難関(ここ一番) | レビュー可能な単位へ分割できない難所。または Terra / Sol が `cause:"model"` で 2 回失敗した後の昇格 | `-m gpt-6-astra -c 'model_reasoning_effort="high"'`(人間承認+週予算) |
| 重要・高リスク(ここ一番) | 委任インフラ・ログ健全性・リリース・不可逆操作・認証/課金/セキュリティ。難易度でなく**重要度**で選ぶ軸 | `-m gpt-6-astra -c 'model_reasoning_effort="max"'`(人間承認+週予算。予算超過時は `gpt-5.6-sol / high`) |

- 迷ったら `gpt-5.6-terra / medium`。このスキルでは Claude Code が設計を確定してから実装を渡すため、標準実装で Astra をデフォルトにしない
- Luna は「何を変更するか」「正解が何か」が明確な作業に限る。仕様解釈・設計判断・複数案の比較が必要なら Terra へ上げる
- Terra は通常実装の主力。複数ファイルという理由だけで Astra に上げず、曖昧さ・影響範囲・退行リスクで判断する
- Sol は難所の主系統。Astra の予算超過・不承認時の代替、設計のセカンドオピニオンなど深い read-only 相談の主力でもある
- セッション継続(文脈の再利用)を理由に、小変更を sol/max の resume で続けない。小変更は現状と変更点を指示書に書き、新規セッションを luna / terra で開く(`../lessons.md`「Codex」)
- Astra を使いたくなる状態が続くのは、モデル不足ではなくタスク分割または指示書の不足を疑う(move-only・歴史化・置換バッチなど挙動不変の作業は、大きくても Terra / Luna)
- **「重要・高リスク」ティア(gpt-6-astra / max)は難易度でなく重要度の軸**(ユーザー方針 2026-07-20)。司令塔が「自分でやった方が早い」と感じる重要対応こそここへ委任し、最深の推論を割いて司令塔はレビューに専念する(`../SKILL.md`「委任可否ゲート」)。`max` は TUI `/model` で対象モデルに表示され利用可能なことを確認してから使う(下記「max / ultra」)。モデルは利用できるが effort 指定が失敗する場合は `xhigh` → `high`(難所ティア)へ落とす。予算超過で Astra を使えない重要対応は `gpt-5.6-sol / high` + 独立レビューで担保する
- **Astra canary 終了(2026-09-05〜09-19、182 件)**: 品質は良好(実装 163 件で採用率 98%・`cause:"model"` 5.5%。同期間の Terra high 21%・medium 10%)だが、週次クォータの消費が同トークンあたり Terra の約 3〜4 倍・Sol の約 4〜5 倍(`~/.codex/sessions` の rate_limits からの推定)で、2 週間に週次枠を 4 回使い切った。以後は下記の使用条件と週予算で運用する。`note` の `canary` 記録は不要。Astra が使えない・不適な場合は同じ effort の `gpt-5.6-sol` へ明示的にフォールバックする(自動では行わない)
- 世代間の effort に正確な対応関係を仮定しない。GPT-5.5 と GPT-5.6 は公式に「no exact mapping」と明記されており、GPT-5.6 と GPT-6 の effort にも同値性を仮定しない。旧設定の `high` / `xhigh` をそのまま移植せず、公式方針どおり必要な結果が出る最小の effort から試して委任ログで評価する。フォールバックの「同じ effort」は指定値の維持であり、推論深度やコストの同値性を意味しない
- **GPT-5.6 canary 完了(2026-07-10〜07-13)**: **GPT-5.6 全ティア昇格確定**。119件見直し(2026-07-13)時点で Terra は実装64件中62採用(非採用は capacity 失敗1と設計起因の一部採用1のみ)、Sol 3/3、Luna 3/3(仕様固定の機械的 UI 変更を3件とも一発で仕様どおり実装 — Luna の想定用途どおり)。以後の GPT-5.6 ティアは canary の note 記録なしの通常運用とし、モデル表の見直しは `../lessons.md`「ログの見直しと昇格条件」の更新条件(同じ組で3件以上の偏り)に従う

### Astra の使用条件と週予算(2026-09-19、ユーザー方針)

- **使ってよいのは 3 つだけ**: (1) 分割不能な最難関、(2) 重要・高リスク、(3) Terra / Sol が `cause:"model"` で 2 回失敗した後の昇格。調査・相談・レビューには使わない(Sol / high が上限)
- **effort は `high` か `max` のみ**。`low` / `medium` の Astra は使わない(その用途は Terra で足りる。canary 期間に `astra/medium` 37 件で 6.9 億トークンを消費した)
- **週予算: 直近 7 日で 8,000 万トークンまたは 8 件**(どちらか早い方。`.env` の `ASTRA_WEEKLY_TOKEN_CAP` / `ASTRA_WEEKLY_COUNT_CAP`)。残量は `delegate-route --budget`
- **毎回、人間の承認を取る**。`delegate-route` が Astra を推奨しても、承認の質問(今週の消費と代替案つき)を経るまで確定しない。`delegate-run` は `-m gpt-6-astra` を、人間承認済みの `--route-id` なしでは実行前に拒否する。検査するのは (1) route が `gate:"confirmed"`・推奨 Astra・`astra_approved:true` (2) `--prompt-file` の SHA-256 が承認時の指示書と一致 (3) `--effort` が `high` / `max` で route の推奨と一致 (4) その承認が未使用(同じ指示書内容での成功した新規実行 1 回で消費。失敗した実行は数えない。承認した委任と同じセッションの `--resume` は通る。指示書を直して同じ route で再承認すれば、新しい内容での新規実行は通る。同じ内容をもう一度新規実行するなら route を取り直す)。強行は `--force-astra` のみ(cooldown 用の `--force` では通らない)。強行した実実行は `runs.jsonl` に `astra_forced:true` が残るので(dry-run は記録されない)、委任ログの `note` に理由を書く
- 予算超過時の既定は `gpt-5.6-sol / high`。「超過を承知で使う」は人間だけが選べる
- 手順は `../SKILL.md`「ティア判定と確定ループ」

### GPT-6 Astra の max / ultra(例外扱い)

- `gpt-6-astra / max` は最大深度の推論として次の2用途で使う(いずれも単一エージェントに深い推論時間を与える): (1) レビュー可能な単位へ分割できず、深さが速度・クォータより重要な**最難関**(難易度の軸)、(2) モデル表の**重要・高リスク**ティア(重要度の軸。ユーザー方針 2026-07-20)。いずれも上記「Astra の使用条件と週予算」の範囲内で使う。通常の標準実装(terra)には使わない
- `ultra` は Codex 内部でサブエージェントを使うモード(公式: 「uses subagents to accelerate complex work」)。**通常の書き込み委任には使わない** — どの内部エージェントが何を判断したかが不透明になり、Claude Code 側のマニフェスト照合・原因分析・委任ログ評価が弱くなる(このスキル側に既にルーティング・worktree分離のオーケストレーションがあり二重化する)
- 使うとしても read-only の複数観点レビュー・大規模調査に限定する
- `max` / `ultra` は TUI の `/model` で対象モデルに表示され、実際に利用可能であることを確認してから使う

### 旧モデル・プレビュー系(フォールバック)

主系統が使えない・canary で不適と判明した場合の明示的なフォールバック:

| 主系統 | フォールバック |
|---|---|
| `gpt-6-astra` | `gpt-5.6-sol`(同じ effort) |
| `gpt-5.6-sol` | `gpt-5.5`(公式上は前世代 frontier) |
| `gpt-5.6-terra` | `gpt-5.5` |
| `gpt-5.6-luna` | `gpt-5.4-mini`(deprecate 予告あり)または `gpt-5.3-codex-spark` |

- `gpt-5.4-mini` は `models_cache.json` の `upgrade` フィールドで Luna への移行が予告されており、いずれ使えなくなる前提で扱う
- `gpt-5.3-codex-spark` は ChatGPT Pro 向けのテキスト専用 research preview。速度最優先の小さな作業に限り、画像・スクリーンショットを含む作業や長い文脈が要る作業には使わない
- フォールバックは自動で行わない。指定モデルが失敗した場合は、`models_cache.json` と TUI `/model` の現行一覧を確認し、使用モデルを明示的に変更する
- 委任ログの `model` には、要求したモデルではなく実際に使用したモデル名を記録する
- `gpt-5.2-codex` / `gpt-5.5-codex` など API 向けモデル名は ChatGPT アカウントでは 400 エラー(実測)

### 現行一覧の確認手順

`models_cache.json` は codex が取得するキャッシュ。`fetched_at` が古い場合は codex を一度起動して更新してから、次のコマンドで公開一覧のモデル名・priority・説明を確認する:

```bash
jq -r '.models[] | select(.visibility == "list") | "\(.slug)\t\(.priority)\t\(.description)"' ~/.codex/models_cache.json
```

- `visibility` が `list` 以外(`hide`)のモデルは委任に使わない(`gpt-reserve` / `codex-auto-review` を含む)
- `-m` が「not supported when using Codex with a ChatGPT account」で失敗したら、上記キャッシュに加えてユーザーに TUI の `/model` で現行一覧を確認してもらう
- モデル表と実態がずれていたら、この確認結果をもとに表を更新する

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
- 詳細設計ドラフト関連の目安: 設計済み方針の実装可能性確認は `gpt-5.6-terra / high`、複雑な設計の落とし穴・移行・並行処理のレビューは `gpt-5.6-sol / high`、分割不能な最難関の技術設計レビューも `gpt-5.6-sol / high` を上限とする(Astra は相談・レビューに使わない)。大規模読解を含む第一ドラフトは Antigravity に置き、Codex は「実装担当視点で詳細設計をレビューする」役割に限る(最終設計は確定させない)
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
