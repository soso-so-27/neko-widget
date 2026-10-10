# 運営画面の接続設定と起動

SharingServiceで `npm ci --ignore-scripts` 後、管理する接続設定JSONをrepo外へ置く。`operator.connection.example.json` は不足項目を明示した雛形で、そのままでは起動しない。秘密・JWT・authority秘密鍵をrepoに保存しない。実際の本人ID・role・公開鍵は運営側の確認済み設定を使い、起動側が新しい権限や鍵を自動作成しない。

```powershell
node scripts/moderation-operator-local-start.mjs --config C:/dev/neko-operator-local/connection.json --plan
node scripts/moderation-operator-local-start.mjs --config C:/dev/neko-operator-local/connection.json --init-local-db
node scripts/moderation-operator-local-start.mjs --config C:/dev/neko-operator-local/connection.json --check
node scripts/moderation-operator-local-start.mjs --config C:/dev/neko-operator-local/connection.json --serve
```

`--plan` は設定準備だけを読み、鍵・DBに触れず起動もしない。`--init-local-db` は空のrepo外runtimeDirectoryに既存migrationを適用する。既存データがある場所は拒否する。ローカルDBだけで、remote binding・cron・公開route・role/identity/authorityの自動登録はない。途中失敗のディレクトリは自動削除・再試行せず、証拠と一緒に保持する。`--check` は生成したWrangler設定の完全一致、3つの必要schema、Node handlerの構築を確認する。DBの配備完了、既存roleの新規承認や本人認証成功を意味しない。

`--serve` は `127.0.0.1:4317` だけで受けるHTTP backendである。ブラウザ入口は設定されたHTTPS originの `/operator/enrollment`。Access front doorが実Access JWTを渡し、upstream Hostを `127.0.0.1:4317` に設定する必要がある。外部IPで待受けず、forwarded headerからoriginを選ばず、保存JWTを全利用者へ注入しない。HTTPS front door・tunnel・DNS・証明書の信頼やAccess policyを自動作成しない。HTTP localhostを本人WebAuthnの実動作確認に読み替えない。

healthは個人情報のない接続状態だけ。全operator routeは既存のRS256検証を通す。POSTのOrigin完全一致、重複認証header拒否、32KiB本文・同時4件・通信20秒の制限を追加する。終了はSIGINT/SIGTERMで受付を止め、通信を取消し、既に受理したhandlerの終了を待ってDBを破棄する。既に受理した原子的なDB処理のrollbackを約束しない。signalを無視する依存が永久停止した場合、安全な終了も待機する。

本人閲覧の隔離adapterはこの起動方法には未接続で、owner policyも自動作成しない。実通報写真を閲覧可能にしたり、実際の返答を送信したりする結果ではない。設定したroleの一覧は既存DBの状態と照合される入力であり、承認・grantそのものではない。

次の実接続候補は本人1名に限定したHTTPS Access入口と既存本人設定の照合。新しいlive権限が必要なら具体的なbefore/afterを示して最後に確認する。その後、本人の認証器登録を一往復し、合成caseの一覧→写真確認→判断→返答下書きへ進む。実Access/実認証器・offline承認・実写真の開示は今回のローカル通信検証とは別の未確認事項。
