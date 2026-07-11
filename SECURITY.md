# Security Policy

## このスキルが扱うリスク / What this skill touches

`delegate` スキルの委任を実行すると、委任先 CLI(Codex / Grok / Antigravity)が読んだコード・ログ・指示書は各ベンダーの API に送信されます。スキル本体はこのリスクを前提に、次を規約として定めています(`skills/delegate/SKILL.md`「秘密情報・外部送信ルール」):

- `.env`・秘密鍵・認証トークン・DB接続文字列・顧客データ・本番ログは委任先に読ませない/指示書に貼らない
- 委任ログ(`DELEGATE_LOG_DIR` 配下)には委任タスクの内容が残るため、リポジトリにコミットしない(`.gitignore` 済み)
- `delegate-run` は各 CLI の sandbox 指定を必須化し、`--dangerously-bypass-approvals-and-sandbox` / `--dangerously-skip-permissions` 等の生成・手動注入を拒否する

Running a delegation sends whatever the worker CLI reads to that vendor's API. The protocol requires keeping secrets and customer data out of delegated context, keeps delegation logs out of git, and hard-rejects sandbox-bypass flags in `delegate-run`.

## サポートされるバージョン / Supported versions

最新のリリースのみをサポートします。Only the latest release is supported.

## 脆弱性の報告 / Reporting a vulnerability

`delegate-run` の sandbox 強制の欠陥、秘密情報が委任先へ漏れる経路、その他のセキュリティ問題を見つけた場合は、公開 Issue ではなく GitHub の **Security Advisories**(Report a vulnerability)から報告してください。

Please report vulnerabilities via GitHub Security Advisories (not public issues).
