# Grok adapter(grok CLI / xAI)

役割: **最新の Web / X 情報が要る調査・相談**(grok は `web_search` / `web_fetch` をデフォルトで使える)、X・コミュニティ・速報色の強い**第三意見**、**独立レビューの持ち回り担当の一角**(`--model grok-4.5`。API 従量課金の実費がかかるため独占させない — `SKILL.md`「独立レビュー」)、OpenAI クォータを温存したい read-only 相談、**Antigravity が limit・障害時の大規模読解の代替**(`grok-4.5` は 500k context)。実装委任も可能だが、実装のデフォルトは Codex。

## 呼び出しの前提

- **フルパス `~/.grok/bin/grok` で呼ぶ**(PATH 追加は `.zshrc` のみで、非対話シェルには入らない)
- 認証は環境変数 `XAI_API_KEY`(`~/.zshenv` で設定済み)で、`grok login` は不要。API 従量課金
- 軽重は `--effort low|medium|high|xhigh` で付ける(`grok-4.5` は reasoning configurable で `--effort` 併用を実測済み。non-reasoning 既定モデルでの effort の効きは未検証)

## モデル表(2026-07-12 改定)

| タスク | モデル |
|---|---|
| 軽い相談・要約・定型調査 | 指定なし(CLI 既定。2026-07 実測: `grok-4.20-0309-non-reasoning`) |
| Web/X 調査、深い相談、独立レビュー、Antigravity 代替の大規模読解 | `--model grok-4.5` |

- `grok-4.5` は公式フラッグシップ(公式 docs 2026-07-12 確認: 「flagship model for code and everything else」「the most intelligent and fastest model we've built」。500k context、$2/$6 per 1M tokens、knowledge cutoff 2026-02-01、configurable reasoning)。**CLI 既定(grok-4.20 系)は前世代のまま**なので、判断の質が要るタスクでは既定に任せず `--model grok-4.5` を明示する(「grok-4.20 and newer」という公式表現のとおり 4.20 → 4.5 の順で、数字の見た目と新旧が逆なことに注意)
- 一覧は `~/.grok/bin/grok models` で確認し、変わっていたらこの表を更新する
- **実費の目安**: `grok-4.5` は $2.00/1M input・$6.00/1M output(2026-07 docs.x.ai)。grok は3系統で唯一の従量課金なので、delegate-run がセッション total(内訳は取れない)に input 単価を掛けた**近似実費をサマリに出す**。単価改定時は `bin/delegate-run` の `cost_usd()` とこの行を更新する
- resume(`-r`)でモデルがセッションに保存・復元されるかは未検証。resume で継続する場合も元と同じ `--model` を付けて挙動を確認する

## 相談(read-only)

```bash
~/.grok/bin/grok \
  --sandbox read-only \
  --yolo \
  --no-auto-update \
  --cwd <プロジェクトルートの絶対パス> \
  --model grok-4.5 \
  --effort <low|medium|high|xhigh> \
  --output-format json \
  -p "$(cat <scratchpadの質問ファイル>)" \
  > <scratchpadのログファイル> 2>&1 < /dev/null
# --model は軽い相談なら省略可(CLI 既定モデルになる。上のモデル表)
```

## 実装委任(workspace write)

Codex と同一の規律(ベースライン・指示書・マニフェスト照合・diff 全読み・検証)を適用する。比較実装は `SKILL.md`「並列委任時の worktree 分離」に従い、`--cwd` を対象 worktree に向ける:

```bash
~/.grok/bin/grok \
  --sandbox workspace \
  --yolo \
  --no-auto-update \
  --cwd <対象worktreeの絶対パス> \
  --model grok-4.5 \
  --effort <low|medium|high|xhigh> \
  --max-turns <N> \
  --output-format json \
  -p "$(cat <scratchpadの実装指示書>)" \
  > <scratchpadのログファイル> 2>&1 < /dev/null
```

## フラグ・セッションの規約

- **`--sandbox` を毎回明示する**(デフォルトは off)。OSレベル(macOS: Seatbelt)で書き込みが制限される。ただし macOS ではネットワーク遮断は効かないため、read-only は「書き込み保護のみ」と考える。`--sandbox workspace` の書き込みは CWD・/tmp・`~/.grok` に限定される
- `--yolo`(全ツール自動承認)はヘッドレスでは実質必須(承認プロンプトを出せない)。**必ず `--sandbox` とセットで使う**
- `--max-turns <N>` で暴走を抑制できる(書き込み委任では必ず付ける)
- `--output-format json` を付け、session id はログファイルの JSON の `sessionId` から取る。**実行のたびに控える**。正常応答の構造は `{text, stopReason, sessionId, requestId}`(2026-07-11 実測。`type` フィールドは無くなった — `sessionId` が取れない・`stopReason` が `EndTurn` でない場合はログ全文を確認)
- 継続は `-r <SESSION_ID>`。**sandbox はセッションに保存され resume で自動復元される**(codex と違い付け直し不要。異なる指定はエラーになる)
- 生ログの隔離・`< /dev/null` の作法は codex と同じ(`codex.md`「実行の作法」)

## Web/X 調査の規約

- 調査結果は `SKILL.md`「Web調査結果の原典確認」に従い、原典確認まで仮説扱い。原典 URL の無い要約は採用しない
- 調査を指示書・設計に反映する時は「確認済み事実」と「仮説」を分けて書かせる

## セットアップ・課金エラー(失敗した時だけ確認)

- `~/.grok/bin/grok models` の1行目に「You are using XAI_API_KEY」が出なければ、`~/.zshenv` の `XAI_API_KEY` 設定を確認
- 403「Your newly created team doesn't have any credits」は xAI 側のクレジット未購入。作業を止めて console.x.ai での購入をユーザーに案内する

過去の事故・実測記録: `../lessons.md`「Grok」
