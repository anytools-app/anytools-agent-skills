# Codex native subagent adapter

Codex を司令塔にする場合、repo 内調査・実装のために `codex exec` を入れ子で起動しない。Codex の native subagent を使う。

## 既定 routing

| タスク | agent | model / effort の目安 | sandbox |
|---|---|---|---|
| 軽いコード探索 | `explorer` | Terra 相当 / medium | read-only |
| 深い原因調査 | `explorer` または root-cause 系 custom agent | 高能力モデル / high | read-only |
| 通常実装 | `worker` / `implementer` | 標準モデル / medium | 親 turn を継承 |
| 横断実装・高リスク | `worker` / `implementer` | 高能力モデル / high 以上 | 親 turn を継承 |
| 補助レビュー | `reviewer` | 高能力モデル / high | read-only |

利用可能な model / effort は現在の Codex クライアントとアカウントで変わる。スキル内で古い model ID を固定せず、利用可能な agent 設定を優先する。

## 調査 prompt の必須要素

```text
目的: <何を判断するための調査か>
対象: <repo / module / route>
書き込み: 禁止
返すもの: 結論、根拠の file:line、実行経路、未確認事項
禁止: 修正、コミット、無関係な広い調査、生ログの貼り付け
```

## 実装 prompt の必須要素

```text
ownership: <担当ファイルまたはモジュール>
目的と仕様: <一意に確定した実装内容>
不変条件: <変えてはいけない挙動>
ベースライン: <既存 test / lint 結果>
完了条件: <検証コマンドと期待結果>
禁止: コミット、プッシュ、スコープ外修正、他者差分の巻き戻し
共同作業: 他の作業者がいる。既存差分を戻さず、現在のツリーへ適応すること
最終報告: 変更ファイル一覧、検証結果、残る blocker
```

## 並列化

- read-only の探索・テスト観点・ログ分析は、重複しない問いに分けて並列化できる
- 書き込み agent は同一 working tree で1つだけ
- 複数 write agent が必要なら、メイン Codex が agent ごとの worktree を作り ownership を分離する
- agent の最終報告と `git status` / `git diff` を必ず照合する

## 委任event

メイン Codex はタスク開始時に`delegate-log --new-task-id`、委任ごとに`--new-delegation-id`を実行する。native subagentのspawn直後に`dispatched`、follow-up送信後に`followup`、追加follow-upが不要になり委任を閉じる時に`completed|failed`を記録し、subagent自身の記録には依存しない。途中の完了通知後に再依頼する可能性がある間はterminal eventを記録しない。`agent_task_name`はcanonical agent task名、`ownership`はpromptに明示したscopeを使う。最後に同じ`task_id`の`task_summary`を記録し、`delegate-log --audit-all`を通す。

logger は追記と同じ lock 内で lifecycle を検証する。重複dispatch、dispatchなしfollow-up、terminal後follow-up、terminal重複、未閉鎖delegationが残るsummaryは追記されない。過去ログの誤ったeventを扱う場合も削除やrewriteはせず、メインCodexが `delegation_correction` を append して effective lifecycle だけを補正する。

## 独立性

Codex reviewer は実装者と別 thread / role でも同一モデル系の可能性がある。標準・高・最重要変更の主レビューは `adapters/claude.md` に従い Claude を使う。
