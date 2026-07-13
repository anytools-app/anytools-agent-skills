# Antigravity adapter(agy CLI / Google)

役割: **大きなコードベースの構造把握・横断的な依存調査**(広い文脈を渡す読解)、**Google Search を併用した公式ドキュメント調査**(ヘッドレスでも web 検索を使うことを実測済み。特に Google Cloud / Firebase / Android / Gemini API 周辺)、**独立レビューの持ち回り担当の一角**(仕様逸脱・副作用・テスト不足を別モデル視点で洗う — 担当の選び方は `SKILL.md`「独立レビュー」)、技術文脈の**第三意見**(X/速報文脈なら Grok)、OpenAI / xAI クォータを温存したい read-only 相談、隔離 worktree での比較実装。実装のデフォルトにはしない。

## モデル表(2026-07 実測)

`--model` には `agy models` の表示名をそのまま渡す(実測一覧: Gemini 3.5 Flash Low/Medium/High・Gemini 3.1 Pro Low/High・Claude Sonnet/Opus 4.6・GPT-OSS 120B):

| タスク | モデル |
|---|---|
| 軽い相談・要約・機械的読解 | `"Gemini 3.5 Flash (Low)"` / `"(Medium)"` |
| 深い読解・独立レビュー・第三意見 | `"Gemini 3.1 Pro (High)"` |

- 独立レビュー・第三意見には Gemini 系を選ぶ(Claude Sonnet/Opus 4.6 も選べるが司令塔と同系で視点が重複し、独立性が下がる)
- モデル名は変わりやすい。`--model` が失敗した時や久しぶりに使う時は `agy models` の実出力を確認し、この表を更新する

## 相談(read-only「意図」— 保証ではない)

```bash
cd <プロジェクトルートの絶対パス> && \
~/.local/bin/agy \
  --mode plan \
  --sandbox \
  --add-dir "$PWD" \
  --model "<モデル>" \
  --print-timeout 10m \
  --print "$(cat <scratchpadの質問ファイル>)" \
  > <scratchpadのログファイル> 2>&1 < /dev/null
```

- 質問ファイルの末尾に必ず含める(plan モードは保証にならないため、プロンプト側の禁止が一次防御): 「ファイルの作成・変更・削除とコマンド実行は禁止です。読み取りと回答のみ行ってください。確認や質問は不要で、具体的な結論・提案まで自主的に出力してください。」
- **相談でも実行後に `git status --short` / `git diff --stat` を必ず確認する**(`--mode plan` が書き込みをブロックしないことを実測済み)

## 書き込み委任

単独委任は Codex と同じ規律(ベースライン計測・指示書・マニフェスト照合・diff 全読み・検証・コミット禁止)を省略しない。比較実装は `SKILL.md`「並列委任時の worktree 分離」に従う:

```bash
cd <対象worktreeの絶対パス> && \
~/.local/bin/agy \
  --mode accept-edits \
  --sandbox \
  --add-dir "$PWD" \
  --model "<モデル>" \
  --print-timeout 10m \
  --print "$(cat <scratchpadの実装指示書>)" \
  > <scratchpadのログファイル> 2>&1 < /dev/null
```

## フラグの罠(重要)

- **フラグはすべて `--print` より前に置き、`--print "<プロンプト>"` を必ず最後にする**。agy は Go 製 CLI で、(1) `--print` の直後にフラグを置くとそのフラグ名自体がプロンプトとして送信され、(2) 最初の位置引数から後ろのフラグは全部無視される(実測済みの罠)。「--mode フラグの解説」のような回答が返ってきたら誤爆のサイン
- **`--add-dir "$PWD"` を毎回付け、cd 先と同じパスにする**。付け忘れると対象ディレクトリは渡らず、`~/.gemini/antigravity-cli/scratch` を勝手にワークスペースにしてそこで作業される(エラーにならずサイレントに続行する。実測済みの罠)。`--cd`/`--cwd` 相当のフラグは無いため、worktree に向ける時は `cd <対象worktree> && --add-dir "$PWD"` で切り替える
- **`--mode plan` は read-only 保証ではない**(実測: plan モードでもワークスペースのファイル書き換えとコマンド実行がそのまま通った)。読み取り専用はプロンプト内の禁止指示で伝え、実行後の diff 確認を必須にする
- `--mode` は毎回明示する(省略時のヘッドレス挙動は未検証で、承認待ちタイムアウトの恐れ)
- `--dangerously-skip-permissions` は禁止(codex の bypass と同格)

## read-only 相談を worktree に隔離する条件

次のいずれかに該当する場合は、相談でも使い捨て worktree で実行する:

1. メインツリーが dirty
2. 他の書き込み委任と並走中
3. 未信頼のリポジトリ/プロンプト/外部ログを読ませる
4. 過去に read-only 意図で書き換えが起きた対象

## 権限待ち・timeout で止まった時

**`--dangerously-skip-permissions` を足して再実行しない。** 分岐は:

1. ログで何の許可待ちで止まったか確認する
2. その作業を Codex に戻せるなら Codex へ
3. Antigravity が必要なら隔離 worktree で対話 TUI を使い、ユーザーに diff/権限を確認してもらう

ヘッドレス自動承認の例外は「使い捨て worktree・秘密情報なし・ユーザーの明示承認」が全部揃った場合のみ。

## resume(継続)

- 継続は `--conversation <UUID>`(会話コンテキストの保持を実測済み)
- UUID は実行後に `jq -r --arg d "$PWD" '.[$d]' ~/.gemini/antigravity-cli/cache/last_conversations.json` で取り、**実行のたびに控える**(ディレクトリ単位で最新IDに上書きされる)
- `-c` / `--continue`(最新会話)は codex の `--last` と同じ誤爆があるため使わない
- resume 時も mode・model・sandbox・add-dir を毎回付け直す(引き継ぎは未検証)

## 実行の作法

- ヘッドレスは `--print` の応答待ちがデフォルト5分で打ち切られる。大きいタスクは `--print-timeout 10m` 等に上げ、Bash の run_in_background で実行する
- 軽いタスクで数秒〜30秒程度(実測)。生ログの隔離・`< /dev/null` の作法は codex と同じ(`codex.md`「実行の作法」)

## セットアップ・認証(失敗した時だけ確認)

- `~/.local/bin/agy models` でモデル一覧が出なければ未認証か障害。ユーザー自身のターミナルで対話モード(`agy`)を起動して再ログインしてもらう(ブラウザ認証のため代行不可)

過去の事故・実測記録: `../lessons.md`「Antigravity」
