# Grok adapter(grok CLI / xAI)

役割: **最新の Web / X 情報が要る調査・相談**(grok は `web_search` / `web_fetch` をデフォルトで使える)、X・コミュニティ・速報色の強い**第三意見**、OpenAI クォータを温存したい read-only 相談。実装委任も可能だが、実装のデフォルトは Codex(技術ドキュメント文脈の第三意見・独立レビューは Antigravity)。

## 呼び出しの前提

- **フルパス `~/.grok/bin/grok` で呼ぶ**(PATH 追加は `.zshrc` のみで、非対話シェルには入らない)
- 認証は環境変数 `XAI_API_KEY`(`~/.zshenv` で設定済み)で、`grok login` は不要。API 従量課金
- モデルは既定(grok-build)でよい。一覧は `~/.grok/bin/grok models`。軽重は `--effort low|medium|high|xhigh` で付ける

## 相談(read-only)

```bash
~/.grok/bin/grok \
  --sandbox read-only \
  --yolo \
  --no-auto-update \
  --cwd <プロジェクトルートの絶対パス> \
  --effort <low|medium|high|xhigh> \
  --output-format json \
  -p "$(cat <scratchpadの質問ファイル>)" \
  > <scratchpadのログファイル> 2>&1 < /dev/null
```

## 実装委任(workspace write)

Codex と同一の規律(ベースライン・指示書・マニフェスト照合・diff 全読み・検証)を適用する。比較実装は `SKILL.md`「並列委任時の worktree 分離」に従い、`--cwd` を対象 worktree に向ける:

```bash
~/.grok/bin/grok \
  --sandbox workspace \
  --yolo \
  --no-auto-update \
  --cwd <対象worktreeの絶対パス> \
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
- `--output-format json` を付け、session id はログファイルの JSON の `sessionId` から取る(先に `type` が `error` でないか確認)。**実行のたびに控える**
- 継続は `-r <SESSION_ID>`。**sandbox はセッションに保存され resume で自動復元される**(codex と違い付け直し不要。異なる指定はエラーになる)
- 生ログの隔離・`< /dev/null` の作法は codex と同じ(`codex.md`「実行の作法」)

## Web/X 調査の規約

- 調査結果は `SKILL.md`「Web調査結果の原典確認」に従い、原典確認まで仮説扱い。原典 URL の無い要約は採用しない
- 調査を指示書・設計に反映する時は「確認済み事実」と「仮説」を分けて書かせる

## セットアップ・課金エラー(失敗した時だけ確認)

- `~/.grok/bin/grok models` の1行目に「You are using XAI_API_KEY」が出なければ、`~/.zshenv` の `XAI_API_KEY` 設定を確認
- 403「Your newly created team doesn't have any credits」は xAI 側のクレジット未購入。作業を止めて console.x.ai での購入をユーザーに案内する

過去の事故・実測記録: `../lessons.md`「Grok」
