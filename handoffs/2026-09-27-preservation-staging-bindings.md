# 保管stagingの非公開サービス結線候補

main `0db04ea` からの別worktree。2026-09-27 08:40 JSTに最初の候補を作成。
本体Workerのstaging設定に、既に非公開・既定OFFで配備済みの鍵Workerと
課金確認WorkerのService Binding名を追加する。公開route、受付、課金、消去、
実写真は有効化しない。鍵・課金用secretは設定しない。

直接証拠：Wrangler 4.125の `deploy --dry-run --env staging` が終了0。
結線先3つと `PRESERVATION_ENABLED=NO`、`CLEANUP_ENABLED=NO` を表示した。
最初のdry-runはKMS/課金の名前付きentrypoint指定が欠けていたため修正。
両Workerのdefault entrypointは404固定であり、名前付き指定が必須。
修正後のdry-runも終了0で、`#PreservationKeyWrapper` と
`#BillingAuthority` が各bindingに表示された。
ignoredの一時probeを `wrangler dev --remote` で非公開プレビューし、
両名前付きentrypointへの実Service Binding呼出しを確認した。
KMS/課金とも期待通り503（既定OFF）、default entrypointの404ではない。
プレビューを終了した。鍵操作・課金照会成功・実写真保存は未検証。

独立した差分レビューでは、既定OFF・認証情報なしの条件下で具体的なP1/P2を
見つけなかった。実際の鍵操作や受付有効化を承認するレビューではない。

## 固定候補の検証計画

変更はstaging Service Binding、専用IAMポリシー、非公開KMS Workerの
既定OFF設定、記録だけ。
直接確認済みはdry-run、非公開Service Bindingの実呼出し（両方503）、
AWS account/KMS状態、IAM Access Analyzerと許可/拒否シミュレーション。
残る不確実性は実際のKMS署名通信と課金照会、資格情報の運用、提供開始条件。
本線前に開発フロー検査・対象選択・必要CIを行う。開発フロー検査の局所検査は
85.1秒で成功したが、新しいポリシーとstaging設定は厳密な保管scopeの
対象外で、full-v1（実測64.43〜97.92分）を選び、30分目標で停止した。
設定だけを先にpushして後続の接続実装でfullを重ねず、機能候補を統合して
直接境界検証後に固定候補の必須CIを1回実行する。CI成功と本線反映は未了。
初候補08:40 JSTからの累計時間で評価し、最後のCI時間だけを所要時間としない。
dry-runは実配備や接続成功を意味しない。

未解決：固定候補CI、配備済み鍵Workerのsecretを使う実通信、
課金Workerの署名付き照会、実写真の暗号化保存と復元、費用測定。
今回の設定だけでは保管サービスを開始できない。

AWS CLIの一時ログインを個人のブラウザで更新し、STS account
`164892691568` とKMSの東京リージョン対称鍵がEnabledであることを読取確認。
現行鍵policyはアカウントrootへの管理許可だけ。
AWS予算は月3 USD、実費1.5/3 USDと予測3 USDの通知（請求停止ではない）。
専用staging IAM方針の候補は
`scripts/aws-kms-staging-worker-policy.json`。同一鍵のEncrypt/Decryptと
唯一の暗号化コンテキストキーに絞る。9/27、専用IAMユーザー
`neko-preservation-staging-kms-worker`と限定policyを作成・関連付けた。
アクセスキーを1本発行してCloudflareの非公開KMS Workerのsecretに登録した後、
AWS側でInactiveにした。secret値はファイルや記録に残していない。
両Workerの共有呼出しsecretを別々のWorker secretとして同値登録した。
非公開KMS Workerを東京リージョン・対象ARN・既定OFFで再配備し、
本体Workerも3つの名前付きService Binding・受付OFF・cleanup OFFで再配備した。
9/27、起動時に必須だが設定が欠けていた`REQUEST_LIMITER`をstagingへ追加。
CloudflareのRate Limiting binding（120回/60秒/拠点/同一IPキー）をdry-runで確認し、
本体Workerを引き続き受付OFF・routeなしで再配備した。これはIP単位の濫用緩和で、
アカウント全体の請求上限や本人単位の厳密な受付上限ではない。
いずれも公開routeなし。実Worker間の署名付きKMS通信は未検証。
候補差分の独立レビューは完了。
AWS Access Analyzerのidentity policy検証はfindings 0。
IAM Simulatorは正しい鍵＋唯一のcontext keyでEncrypt/Decryptを許可、
context欠落・余分なkey・別の鍵・鍵削除はimplicitDenyを確認。
新規発行直後の一時鍵による初回Encryptは`UnrecognizedClientException`で失敗。
その鍵は削除。次に12秒待ってSTSで専用主体を確認し、さらに別の一時鍵で
合成32バイトのKMS Encrypt/Decrypt往復に成功した。試験用鍵は両方削除し、
残る1本はInactive。初回失敗はIAM反映遅延が疑われるが断定しない。
既存`vitest.live-staging-kms.config.ts`のWorker実行環境で、一時鍵を使う
合成32バイト鍵の実KMS wrap/unwrap 1件が成功した。試験鍵を削除し、
残る鍵はInactiveと再照合した。これは製品コードの実AWS通信の証拠だが、
配備済み非公開Workerのsecret・Service Binding連携や障害復旧の証拠ではない。

## 非公開の課金照合先

9/27、Cloudflare上の`neko-window-sharing-staging` D1 IDを照合し、
課金WorkerをこのDB・audience`neko-preservation-staging`・両機能OFF・routeなしで再配備。
本体Workerも同じaudienceと受付OFFで再配備した。既存共有Workerは変更していない。
ただしD1の`sqlite_master`と移行履歴を読んだ結果、共有staging DBには
`billing_account_keys`/`billing_runtime_gate`等の課金表がまだない。
0019〜0025課金migrationは未適用で、0026以降の他機能移行だけが適用済み。
さらに遠隔履歴の`0028_family_record_moments.sql`はこのmain checkoutの
`0028_window_support_requests.sql`と同じ番号で別内容。並行中の共有機能作業が
stagingを先行している状態なので、migration番号を上書き・手動補完しない。
共有アプリへの影響と移行順序を本線担当と整合するまで課金照合はONにしない。

## S3の現物設定

9/27の読取照合でstaging復旧bucketはversioning Enabled、Public Access Blockの
4項目すべてtrue、既定SSE-S3(AES256)、lifecycle未設定。
版を残す復旧には適合するが、非現行版を含む容量・費用が自動で止まる設定ではない。
復旧期間を壊す一律のlifecycleは追加していない。
