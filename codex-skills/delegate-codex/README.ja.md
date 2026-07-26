# delegate-codex

Codex を司令塔にし、repo 内の調査・実装は Codex native subagent、独立レビューは Claude Code CLI を第一選択にする Agent Skill です。

## 役割

- メイン Codex: 要求解釈、設計、採否、検証、コミット
- Codex subagent: repo 内調査と実装
- Claude Code CLI: 標準・高・最重要変更の read-only 独立レビュー
- Grok / Antigravity: Web 調査や Claude 不可時の補助レビュー

Claude はレビュー専任です。標準は `sonnet / high`、高は `opus / high`、最重要は `fable / high` を既定にします。

## インストール

### Codex plugin として

```bash
codex plugin marketplace add anytools-app/anytools-agent-skills
codex plugin add anytools-agent-skills-codex@anytools-agent-skills
```

ローカル checkout を試す場合:

```bash
codex plugin marketplace add "$PWD"
codex plugin add anytools-agent-skills-codex@anytools-agent-skills
```

### symlink でスキルだけ入れる

```bash
mkdir -p "$HOME/.agents/skills"
ln -s "$PWD/codex-skills/delegate-codex" "$HOME/.agents/skills/delegate-codex"
```

インストール後に Codex を再起動します。`agents/openai.yaml` は暗黙起動を許可しており、global または repo の `AGENTS.md` から既定スキルとして選択できます。ただし、スキル起動自体は外部送信の承認ではありません。下記の限定的な Fable 恒常承認だけを例外とし、それ以外は送信先、対象範囲、制約を示したタスク単位の明示承認が必要です。

## Fable の限定的な恒常承認

次の全条件を満たす Anthropic Claude Fable `fable / high` の read-only 最重要レビューだけは、ユーザーの恒常承認により都度承認なしで実行できます。最重要は、認証・認可境界、課金・金銭、顧客・本番データ、秘密・署名・供給網、本番移行のいずれかで、破壊的・不可逆・広範囲・rollback 困難・複数システムへの波及を伴う変更に限定します。同じ領域でも局所的で可逆なら高として `opus / high` を使います。

- ユーザーが現在の作業対象として指定または開いているユーザー管理 repo である
- 送信対象は、対象ソースコードと必要な関連コード、対象 diff、秘密を検査・マスク済みのテスト結果、秘密を含まない最小タスク要約の必要分だけである。repo 全体を無差別に送信・探索させない
- `.env`、秘密鍵、認証・アクセストークン、DB 接続文字列、顧客・個人データ、本番ログ、認証済みブラウザ状態、委任の生ログは常に除外する。テスト出力も送信前に検査・マスクする
- runner の safe mode、plan permission mode、`Read,Glob,Grep`、MCP 拒否を維持する。ファイル変更・コミット・push・追加 network action は禁止する

実行前に全条件への適合と、送信するファイル・カテゴリを内部確認します。恒常承認を使った場合は、最終報告と `delegate-log --approval-basis standing --effort high` の note に `tier=最重要; standing approval 使用; 送信対象カテゴリ=<実際のカテゴリ>` を記録します。条件外、範囲不明、より広いデータ、Fable 以外（Sonnet / Opus を含む）、`fable / max`、外部 AI による実装・書き込み・追加 network action は従来どおりタスク単位の明示承認が必要です。Sonnet / Opus `high` は `--approval-basis explicit --effort high`、Fable `max` は `--approval-basis explicit --effort max` として記録します。Opus の恒常承認は、ユーザーのタスク単位明示承認があるまで未対応であり、常に `explicit` のままです。必須の Fable review から Opus / Sonnet へ黙って切り替えません。高で必須の Opus が使えない場合も Sonnet へ黙って切り替えず、明示承認なしに別の外部 AI を使いません。

このスキルを使った全タスクは、最終応答前の `bin/delegate-log` 成功が完了条件です。低リスク、調査、相談、直接処理、native subagent のみ、Claude review なしも対象です。`--approval-basis none` と `--effort unknown` の省略時後方互換は self / native / 外部送信なしの経路だけに維持します。Claude / Grok / Antigravity (`agent=claude|grok|agy`) は `kind` に関係なく `explicit|standing` を必須として `none` を拒否し、`standing` は条件適合する最重要 `fable / high` だけが通ります。Claude review は実effortを記録し、タスク単位承認済みの Sonnet / Opus / Fable は `explicit`、条件適合する最重要 `fable / high` 恒常承認だけは `standing` とします。logger の既存 `risk=高` enum は高と最重要の両方に使い、Fable standingの実tierは `tier=最重要` として note に残して機械検証します。standing の記録には `kind=レビュー`、空でない review `run-id`、許可語彙だけの `送信対象カテゴリ=` が必要です。カテゴリの順序は自由ですが、空要素・未知値・重複は fail-closed で拒否します。standing 以外の note に `standing approval 使用` を書くことも拒否します。すべてのnoteは単一行とし、CR / LF / TABを拒否します。通常の日本語、空白、semicolonは使用できます。logger は `approval_basis` と `effort` を JSONL に記録し、不正なentryを拒否します。最終報告には `recorded:` が示すパスを含めます。ログ失敗時は完了扱いにせず、literal error と未記録であることを報告します。

新規記録はschema v2です。既存CLI呼び出しは従来fieldをすべて保った`task_summary`として動き、`schema_version`、`record_type`、UTC `timestamp`、optionalな`task_id`だけが追加されます。過去JSONLはrewriteしません。subagentを使う場合、メインCodexが`--new-task-id`でタスクID、`--new-delegation-id`で委任IDを生成し、spawn直後の`dispatched`、follow-up直後の`followup`、追加follow-upが不要になり委任を閉じる時の`completed|failed`を自分で記録します。途中の完了通知後に再依頼する可能性がある間はterminal eventを記録しません。subagent自身のログには依存せず、canonical agent task名と指示書ownership scopeを使い、最後に同じtask IDのsummaryを記録します。直接処理・selfにはeventは不要です。

`delegate-log` は追記と同じ atomic lock の内側で lifecycle を検証します。重複 dispatch、dispatch なし follow-up、terminal 後 follow-up、dispatch なし terminal、重複 terminal、effective delegation が未閉鎖の task summary は追記前に拒否され、行数は変わりません。lock は `delegation-log.jsonl` に対応する worktree 外パスへ `mkdir` で取得します。既存 lock は owner ファイルの有無や PID 生死を問わず自動削除せず、bounded wait 後に fail-closed します。実行中の `delegate-log` がないことを人間が確認してから lock を手動確認してください。

過去の不正 lifecycle 行は物理削除・rewrite せず、append-only の `record_type:"delegation_correction"` で補正します。CLI は `--correction voided|supersedes`、`--target-delegation-id`、任意の `--replacement-delegation-id`、`--reason historical_bad_lifecycle|operator_error|duplicate_record|unknown` です。correction は lifecycle audit と preappend の effective state だけに効き、物理行は残ります。unknown target、self-target、重複 correction、不正 replacement、補正済み ID への新event、正常な未閉鎖 delegation への correction は拒否します。正常な未閉鎖 delegation は dispatch が1つ、terminal が0の状態であり、correction で隠さず通常の terminal event で閉じます。監査出力は physical events、effective events、corrections、issues を分けます。

task summary には `required_model`、`actual_model`、`review_status` も記録します。旧CLIでは、調査・相談は `none/none/not_required`、低riskの実装・レビューでClaude実績なしなら `none/none/skipped_low_risk`、標準は required `sonnet`、高は required `opus`、`tier=最重要` または Fable standing は required `fable` を派生します。actual は `agent=claude` かつ `model=sonnet|opus|fable` の場合だけ入ります。required 欠落は `blocked_approval` と `routing_verdict=過小`、actual が required より低い/高い場合は `過小`/`過剰`、一致は `適正`、required none で actual Claude があれば `過剰` です。明示fieldや `--routing` が派生と矛盾する場合は拒否します。最重要 Fable 欠落または Sonnet/Opus の下位reviewは `outcome=未完了|失敗` のみ許可します。高 Opus 欠落は `過小` / `blocked_approval` なら採用記録を許容します。

`delegate-log --audit-delegations`はeffectiveなdispatch/terminalの一意性、event順序、attempt、対応summaryを検査し、各taskの最新summaryが全effective eventより後にあることを要求します。`--audit-run-ids`はlegacy summaryを含むClaudeの全`run_id`を`runs.jsonl`へ照合し、委任ログに具体値があるmodel/effortだけを比較します。legacyの欠落・`unknown`は不一致と断定しません。`--audit-routing` は新しい routing field を検査し、3 field がすべて欠けたsummaryは legacy 互換として通します。`explicit|standing`で成功・採否を記録するClaude summaryと`completed` eventは空でない`run-id`が必須で、実行前の失敗だけは省略できます。standingは常に`fable / high`へ厳格に拘束します。`--audit-all`はすべてを実行し、subagent利用タスクの完了条件です。監査はread-onlyで、issueはexit 1、解析不能・読取不能・symlink・worktree内ログはexit 2です。

managed sandbox の permission profile が既定の永続ログ先への書き込みを拒否した場合は、同一の `delegate-log` コマンドを実行環境の sandbox escalation で再実行します。logger は OS エラー原文と対象絶対パスを表示します。escalation は `delegate-log` の CLI 引数ではありません。承認拒否時は未完了です。repo / git worktree 内や一時パスへ黙って切り替えません。別の `DELEGATE_CODEX_LOG_DIR` を使えるのは、ユーザーが永続的・絶対パス・Codex 書き込み可能・全 git worktree 外のログ先を明示設定した場合だけです。

## Claude の準備

Claude Code CLI をインストールし、ユーザー自身でログインします。

```bash
claude auth status
claude auth login
```

必要ならローカル設定を作ります。

```bash
cp codex-skills/delegate-codex/.env.example codex-skills/delegate-codex/.env
```

`DELEGATE_CODEX_LOG_DIR` をユーザーが明示設定する場合は、永続的で、Codex の permission profile から書き込める絶対パスかつ全 git worktree 外のローカル専用ディレクトリにしてください。既定値は macOS が `~/Library/Logs/delegate-codex`、Linux が `${XDG_STATE_HOME:-~/.local/state}/delegate-codex` です。

skill-local `.env` はshellとして`source`されません。通常行は`DELEGATE_CODEX_LOG_DIR=<value>`または`CLAUDE_BIN=<value>`だけを許可する静的設定です。symlink、未知キー、CR/TAB、command substitutionを含むshell構文は拒否されます。実行環境で明示した同名環境変数が`.env`より優先します。

## Claude review runner

```bash
codex-skills/delegate-codex/bin/delegate-review \
  --model <sonnet|opus|fable> \
  --effort high \
  --cd /absolute/path/to/repo \
  --prompt-file /absolute/path/to/review-packet.md
```

実行内容だけ確認する場合は `--dry-run` を追加します。runner は Claude を `--safe-mode`、`--permission-mode plan`、限定 tools で起動し、review packet を stdin で渡します。実行前後の `git status` が変わった場合や、stdout が期待する JSON result でない場合は失敗扱いにします。review packet・結果・ログは対象 repo に限らず、すべての git worktree 内への配置を拒否します。

終了コード:

- `0`: レビュー成功
- `2`: 設定・認証・cooldown gate・`runs.jsonl` 追記の失敗
- `3`: レビュー中に worktree が変化
- `4`: Claude の result JSON が不正
- その他の非0値: Claude CLI の終了コードを保持

Claude CLI review は既定の永続ログ先を共有して直列実行します。`runs.jsonl` と `cooldowns.json` の競合・cooldown 判定 race を避けるため並列実行せず、reviewer ごとのログ先分割や完了後の統合も行いません。runner は `runs.jsonl` / `cooldowns.json` の symlink を拒否し、`delegate-log` は symlink の `delegation-log.jsonl` を拒否します。

`cooldowns.json` が壊れた場合は fail-closed で停止します。内容を確認して退避してからファイルを取り除き、review を再実行してください。`--clear-cooldown` は壊れた JSON を自動修復しません。

2026-07-22 に Claude Code CLI `2.1.207`、`fable / high`、実 packet で end-to-end smoke を実行し、runner / Claude とも exit `0`、result JSON valid、worktree 変更なしを確認しています。runner は起動時にも必須 CLI flag の存在を検査します。

## テスト

```bash
bash codex-skills/delegate-codex/bin/delegate-review-tests.sh
```

## セキュリティ

Claude review は Anthropic への外部送信を伴います。`.env`、秘密鍵、認証・アクセストークン、DB 接続文字列、顧客・個人データ、本番ログ、認証済みブラウザ状態、委任の生ログを review packet や diff に含めないでください。テスト出力も秘密を検査・マスクします。review packet、結果、委任ログはコミットしません。

詳細は [SKILL.md](SKILL.md)、[Claude adapter](adapters/claude.md)、リポジトリの [SECURITY.md](../../SECURITY.md) を参照してください。
