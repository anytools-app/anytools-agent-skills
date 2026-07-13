# 事故例・実測記録・ログ見直し(lessons)

**通常の委任では読まない。** CLI が失敗した時に該当 CLI のセクションを、委任ログの見直し時に「ログの見直しと昇格条件」を読む。新しい事故・実測はバージョンと日付を付けてここへ追記する(中核規約 `SKILL.md` には足さない。規約に昇格させるのは繰り返し起きたものだけ)。**このスキルは公開リポジトリで管理されている — 追記に個別案件の名称・ドメイン・顧客を特定できる情報を書かず、一般化した表現にする**(案件固有の詳細はローカルの委任ログ側にだけ書く)。

## プロセス(設計・指示書・レビューの事故)

- **製品判断の取り違え**: 「リトライを別エンジンで救済」は技術的には正しかったが、生成物(ユーザー可視アウトプット)の見た目が変わる製品判断であり、当日中に撤回になった → ユーザー可視アウトプットが変わる判断は委任前にユーザー確認(`SKILL.md`「製品判断と技術判断」)
- **現行可視挙動の棚卸し漏れ**: 「レビュー不合格の候補も画面には表示されていた」という現行挙動を確認せずに「不合格=エラー」の意味論を導入し、ユーザーには「生成できなくなった」退行として現れ、復旧に3コミット要した → 既存フロー変更では現行可視挙動を先に列挙(`SKILL.md`「基本フロー」2)
- **指示書の対象列挙漏れ**: memory 側のフィルタ撤去だけ指示し、postgres 側の同じフィルタを指示書から漏らした。委任先が趣旨を汲んで拾ったが、指示書で保証すべきだった → 複数系統がある機能は「全系統を揃える。系統は全域 grep で洗い出す」を明記(`templates.md`)
- **ベースライン欠落**: 既存の失敗テストに合わせて生成コストに関わる定数を変更された → 完了条件は「全部パス」ではなく「委任前より失敗を増やさない」
- **証拠不足の障害修正**: コールドスタート仮説でリトライを実装したが、真因はデプロイ先DBのスキーマ欠落で修正がもう1周必要になった(リトライ自体は無害だったので傷は浅かった)→ 仮説向けの修正は空振りしても害のない最小限に絞る
- **「前はできていた」の思い込み**: 体感の原因が自分たちの変更による退行だった実例あり → `git show <コミット>:<ファイル>` で症状発生前の実コードを確認し、現行との差分を証拠にする
- **委任中の外部書き込み**: 委任中に `.grok/settings.json` が変わり `npm run check` が失敗 → 委任先には変更ファイル単位の check で代替させ、lint/git 除外の設定追加(数行)は司令塔が直接処置
- **原典未確認の提案を鵜呑みにしかけた**: レビュー済み提案に含まれていた `--ask-for-approval` フラグが手元の codex exec には存在せず、鵜呑みにしていたら全委任コマンドが壊れていた → バージョン依存の仕様は実バージョンと照合(`SKILL.md`「Web調査結果の原典確認」)
- **検証コストゼロ設計の成功例**: 生成ジョブのポーリングUIの検証で、DBの `generation_status` を手で `generating`→`ready` に書き換え、生成APIを一度も叩かずに「生成中表示→ポーリング→完成表示」の全遷移をPlaywrightで確認した。モック・テストレコード作成用のdebugエンドポイント・DB直接更新スクリプトが道具になる

## Codex

### 2026-07 / codex 0.142.5〜0.144.0

- `--ask-for-approval` はトップレベル `codex --help` には存在するが、`codex exec` では unexpected argument(0.142.5)。0.144.0 でも `codex exec --help` に載らないことを確認済み → CLI フラグに依存せず config キー `-c 'approval_policy="never"'` で渡す
- resume が sandbox・モデル・reasoning effort を引き継がず、ローカル config のデフォルトへ戻ることを実測(0.142.5)→ resume 時も全フラグを付け直す。今後のバージョンでも継承を期待しない
- stdin 未遮断で「Reading additional input from stdin...」のまま無期限にハング → 末尾 `< /dev/null` 必須
- `--cd` がリポジトリ外(scratchpad 等)を指すと「Not inside a trusted directory」で即失敗(0.144.0 実測)。`--skip-git-repo-check` での回避はしない
- web_search の公開 docs 上の値は `disabled|cached|live`。0.142.5 のローカル検証では `indexed` も受理されたが普遍仕様として扱わない
- code-mode host spawn 失敗(2026-07-10): 「failed to spawn code-mode host /opt/homebrew/bin/codex-code-mode-host」で回答は返るがリポジトリ未読になる。ChatGPT.app 同梱バイナリへの symlink で復旧(手順は `adapters/codex.md`「セットアップ」)。`-c 'features.unified_exec=false'` では回避できない
- API 向けモデル名(`gpt-5.2-codex` / `gpt-5.5-codex` 等)は ChatGPT アカウントでは 400 エラー(実測)
- フォアグラウンドで Bash timeout 上限(10分)を超えるとプロセスごと殺され、成果物が中途半端な状態で残る → 大きい委任は run_in_background
- workspace-write sandbox は**ネットワーク listen も制限**され、dev server・listen を伴うテストは委任先で実行できない(2026-07-12 実測2件。1件は初回納品にバグ残留として顕在化)→ 該当プロジェクトでは指示書に「テスト実施は司令塔で行うので、動く状態にしておくこと」を明記する(`templates.md` 記入時の注意 3)
- **「model at capacity」はサーバ側の一時飽和で、アカウントの limit ではない** → cooldown を記録せず、フォールバック表の旧モデル(Terra なら `gpt-5.4`)へ明示的に切り替えて続行する(2026-07-13 実測: capacity で即失敗 → gpt-5.4 で一発成功。委任ログの model には実際に使ったモデルを記録)

## Grok

- 403「Your newly created team doesn't have any credits」= xAI 側のクレジット未購入。作業を止めて console.x.ai での購入をユーザーに案内する(2026-07-11 クレジット購入後に read-only スモークで疎通確認済み: exit 0・2秒・sessionId 取得。同日実測でモデルラインナップが grok-4.20/4.3/4.5 系へ変わり、`--output-format json` の応答構造も `{text, stopReason, sessionId, requestId}` に変化 — `type` フィールド無し。delegate-run の sessionId 抽出はそのまま動作)
- `grok models` の1行目に「You are using XAI_API_KEY」が出なければ `~/.zshenv` の `XAI_API_KEY` を確認(PATH は非対話シェルに入らないためフルパス呼び出しも必須)
- macOS(Seatbelt)ではネットワーク遮断が効かず、sandbox は書き込み保護のみ
- 2026-07-12: `grok-4.5` が公式フラッグシップであることを docs.x.ai で確認(「grok-4.20 and newer」の表現どおり 4.20 → 4.5 の順。数字の見た目と新旧が逆)。**CLI 既定は前世代の `grok-4.20-0309-non-reasoning` のまま**なので判断の質が要るタスクは `--model grok-4.5` を明示する。`--model grok-4.5` + `--effort high` の併用を read-only smoke で実測(応答 JSON に `thought` フィールド=reasoning 有効)。同日 delegate-run の grok `--model` 拒否を撤廃し任意透過へ変更。Antigravity が limit の間の大規模読解・独立レビューは grok-4.5(500k context)で代替する
- `grok-4.20-0309-non-reasoning` のコードレビュー2件(2026-07-12、agy limit 中の代替)で、反証可能な blocker を提出(SELECT を変更と誤認/fail-loud 設計を誤指摘/機構説明の誤り。cause:model、1件破棄・1件一部採用)。着眼(配線・カバレッジ・secrets 残留)は有用 → grok に独立レビューを振る時は `--model grok-4.5` を使い、**blocker は実コードで反証してから採否を決める**
- `grok-4.5` の再計測完了(2026-07-12 の76件見直し): agy cooldown 中の代替として独立レビュー4件+相談1件が**全採用・反証 blocker ゼロ**(SQL 忠実性の差分検出、re-enqueue 消失退行の検出など採用率の高い中位指摘)。agy 代替の独立レビュー先として実証済み — 4.20 時代の精度問題は 4.5 では再現していない

## Antigravity

- `--mode plan` でもワークスペースのファイル書き換えとコマンド実行がそのまま通った(実測)→ read-only は「保証」ではなく「意図」。プロンプト側の禁止文+実行後の `git status --short` / `git diff --stat` 確認を必須化
- `--add-dir` 欠落時、対象ディレクトリは渡らず `~/.gemini/antigravity-cli/scratch` を勝手にワークスペースにしてサイレント続行(実測。エラーにならない)
- `--print` の直後にフラグを置くとフラグ名自体がプロンプトとして送信され、最初の位置引数より後ろのフラグは全部無視される(実測)。「--mode フラグの解説」のような回答が返ってきたら誤爆のサイン
- `-c` / `--continue` は「マシン全体で最新の会話」を掴む誤爆(codex の `--last` と同種)→ `--conversation <UUID>` を明示
- `~/.gemini/antigravity-cli/cache/last_conversations.json` はディレクトリ単位で最新IDに上書きされる → 実行のたびに UUID を控える
- 「Individual quota reached」= 個人クォータ到達。リセットまで**約108時間(4.5日)**表示の実測あり(2026-07-12、9秒で失敗・書き込みなし)→ `delegate-run --set-cooldown agy 108h` で記録し、大規模読解・独立レビューは grok-4.5 へ代替(`SKILL.md`「委任先の limit と cooldown」)

## Claude サブエージェント(独立レビュー・調査)

- **general-purpose を独立レビュアーとして使う運用が有効(2026-07-12、agy cooldown 中の4件で確立)**: agy が個人クォータ枯渇(108h)の間、high リスク変更(D1互換アダプタ・alarm駆動エンジン・better-auth スキーマ・認証境界・ログイン悪用対策)の独立レビューを Agent ツールの general-purpose(読み取り専用指示)に振り、4件すべて routing 適正・採用。実コード/実 .d.mts を根拠に file:line 付きで指摘し、**全員が見落とした欠陥を単独発見した実績が複数**(alarm 駆動化での 60s バックオフ消失、better-auth の runtime .mjs と .d.mts の食い違い、XFF 詐称でのレート制限回避、Turnstile 公開値ゲートの黙殺無効化)。同期間の grok-4.20 レビュー2件が cause:model(反証可能な blocker)だったのと対照的 → **agy cooldown 中の独立レビューは grok より Claude サブエージェント(general-purpose、読み取り専用+攻撃者視点の指示)を優先する**。依頼書は scratchpad に組み立て(指示書原文+diff+観点)、`git status`/snapshot で書き込みなしを確認する運用は agy と同じ。デフォルトのレビュアー表(SKILL.md)は agy のままで変えない(委任先ミスではないため)— これは cooldown 時の代替の優先順位付け
- 大規模コードリーディングは Explore、判断を伴う調査は general-purpose/sonnet。返答をパス・行番号・結論に絞らせ、ファイル全文をメイン会話に持ち込まない規律は SKILL.md どおり。3〜4件の調査すべて採用(境界棚卸し・API 実物確認が指示書を一発化した)

## テスト実行の場所(sandbox listen 制限)

- **codex/grok の workspace-write sandbox は 127.0.0.1 の listen を禁止するため、@cloudflare/vitest-pool-workers・next dev・Wrangler ローカル D1 を使うテストは委任先で実行不能(EPERM)。SaaS 化案件の全実装パッケージで再現(委任ログ environment cause 多数)** → このプロジェクトの実装指示書には必ず「テスト実施は司令塔で行う。委任先は typecheck と『動く状態』までで可、テスト実行結果は完了条件にしない」を明記する(`templates.md` の注意3)。委任先の「テスト未実行」報告は失敗ではなく既知の環境制約。司令塔が `npm test` を実行して緑を確認してからコミットする

## ログの見直しと昇格条件

追記は `SKILL.md`「委任ログ」の `jq -cn` コマンドで行う。このセクションは見直しの時(10の倍数、または「委任ログを見直して」)だけ読む。

### 集計コマンド

cli × model × kind 単位で件数と全判定軸の分布を出す(`SKILL_DIR` はこのスキルのディレクトリ。ログ先の解決は `SKILL.md`「委任ログ」と同じ):

```bash
set -a; [ -f "$SKILL_DIR/.env" ] && . "$SKILL_DIR/.env"; set +a
jq -s '
  sort_by(.cli, .model, .kind) |
  group_by([.cli, .model, .kind]) |
  map({
    cli: .[0].cli, model: .[0].model, kind: .[0].kind, n: length,
    delegation_verdicts: (group_by(.delegation_verdict) | map({verdict: .[0].delegation_verdict, n: length})),
    routing_verdicts: (group_by(.routing_verdict) | map({verdict: .[0].routing_verdict, n: length})),
    outcomes: (group_by(.outcome) | map({outcome: .[0].outcome, n: length})),
    validations: (group_by(.validation) | map({validation: .[0].validation, n: length})),
    causes: (group_by(.cause) | map({cause: .[0].cause, n: length}))
  })
' "${DELEGATE_LOG_DIR:-$HOME/.claude/logs/delegate}/delegation-log.jsonl"
```

トークン効率(コスト)の集計 — `tokens` が記録されている行のみが対象:

```bash
jq -s '[.[] | select(.tokens != null)] | group_by([.cli, .model, .kind]) |
  map({cli: .[0].cli, model: .[0].model, kind: .[0].kind, n: length,
       tokens_median: (map(.tokens) | sort | .[length/2|floor]),
       tokens_max: (map(.tokens) | max)})
' "${DELEGATE_LOG_DIR:-$HOME/.claude/logs/delegate}/delegation-log.jsonl"
```

### ルーティング表・モデル表の更新条件

- 更新してよいのは、**同じ cli/model/kind の組で3件以上あり、かつ `過剰` または `過小` が明確に偏った場合だけ**(全体10件で表を動かすのは早すぎる)
- `過小` を理由にモデルを上げる判断は、その `過小` が `cause:"model"` で偏っている場合のみ。`routing_verdicts` に `過小` が偏って見えても、`causes` が `instruction`/`spec_change` 寄りなら指示書・設計の問題であり、モデル表は動かさない
- **委任先の役割分担(provider デフォルト)を見直すのは、`routing_verdict:"委任先ミス"` が3件以上、かつ理由が同じ能力不足である場合だけ**(例: Codex に投げたが毎回 Web 調査不足 / Antigravity に投げたが毎回 write guard 不足 / Grok が大規模 repo 読解で不安定)。現在の provider デフォルトで問題が出ていないなら capability matrix 化は不要
- 更新時は根拠にしたログ件数を表に注記する
- **トークン効率の見直し**: 同種のタスク(kind × リスク帯)でモデル・effort 別の `tokens` 分布を比較し、品質(outcome / validation / resumes)が同等で tokens が明確に低いティアがあるなら、そちらへ寄せる。resume が嵩む委任は tokens も嵩む — 指示書の分割・スコープ明確化はコスト面からも評価する。判断材料が3件未満の組では動かさない(モデル表と同じ規律)

### 自動化の昇格条件(件数ではなく、失敗の種類の偏りで判断する)

30件はあくまで見直し時点であり、自動化のトリガーではない。次の偏りが実際に出た場合だけ、対応する自動化を検討する。

**delegate-run(実行ラッパー)— 2026-07-11 作成済み**

`bin/delegate-run`(テスト: `bin/delegate-run-tests.sh`、実行記録: ログディレクトリの `runs.jsonl`)。ログ30件見直しで条件成立(実委任多数・参照漏れなし・resume の cwd 誤りという「ラッパーが防ぐ類のミス」が実発生)を確認して作成。既知事故をテスト51件に変換済み(dry-run 検証)+ agy Flash Low での実行スモーク確認済み。仕様変更時は adapter を先に直し、テストを追従させる。当初の設計方針(参考のため保持): policy engine にはせず、安全なコマンドランナーに限定する。

- 担当する: provider 別 canonical command の生成 / 必須 sandbox 設定 / prompt file の読み込み / ログ隔離 / `< /dev/null` / timeout 設定 / session・conversation ID の取得 / exit code の記録 / 実行前後の `git status` / 実行情報 JSONL の自動追記(`run_id` を発行し、評価ログ側にも `run_id` を足して関連付ける)
- 担当しない: 委任すべきかの判断 / provider・モデルの自動選択 / 製品判断 / diff レビュー / validation の合否判定 / 自動コミット / 自動 resume / 自動 handoff
- 作る時は、このファイルの各 CLI セクションの既知事故をテストケースへ変換する(例: Codex write に workspace-write / approval never / web_search disabled / stdin 遮断が必ず付く、resume で全フラグ付け直し・`--last` 不使用、Grok は sandbox+yolo セット、agy は `--add-dir`=cwd・`--print` 最後・`--dangerously-skip-permissions` を生成しない)。`--dry-run` で shell-escaped command を実行前に確認できるようにする

**指示書 preflight を検討する条件**(いずれかが3件以上)

- `cause:"instruction"` で、同じ必須項目の欠落が繰り返された
- ベースライン未記載が繰り返された
- ユーザー可視挙動の棚卸し漏れが繰り返された
- スコープ外の明記不足が繰り返された

→ 最初は JSON Schema ではなく、`templates.md` の見出し存在チェックから始める(存在検査はできるが中身の正しさまでは保証できない。その限界を明記して使う)

**capability routing(provider マトリクス化)を検討する条件**

- 比較可能な30件程度の中で `routing_verdict:"委任先ミス"` が3件以上偏り、かつ理由が同じ能力不足である場合だけ(上記「更新条件」と同じ基準)

**状態機械・オーケストレーション基盤を検討する条件**(いずれかが起きた場合のみ)

- 複数ユーザーが同じ skill を使う / 同時委任が常態化する / タスクが日数をまたぐ / resume・handoff の追跡漏れが頻発する / 人手を介さず連続実行したい / 監査可能な承認履歴が必要

単一ユーザーが1日数件使う段階では不要。
