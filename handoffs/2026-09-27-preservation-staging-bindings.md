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

変更はstaging Service Bindingと未適用のIAMポリシー候補、記録だけ。
直接確認済みはdry-run、非公開Service Bindingの実呼出し（両方503）、
AWS account/KMS状態、IAM Access Analyzerと許可/拒否シミュレーション。
残る不確実性は実際のKMS署名通信と課金照会、資格情報の運用、提供開始条件。
本線前に開発フロー検査・対象選択・必要CIを行う。直近の同系統Node CIは約1分、
開発フロー検査は約2分だったが、この新しいポリシーファイルがfull CIを選ぶ
可能性は未判定。fullなら1時間以上を想定して方法と時間を再評価する。
初候補08:40 JSTからの累計時間で評価し、最後のCI時間だけを所要時間としない。
dry-runは実配備や接続成功を意味しない。

未解決：固定候補CI、鍵Workerの正しいAWSアカウントへの
接続、課金Workerの署名付き照会、実写真の暗号化保存と復元、費用測定。
今回の設定だけでは保管サービスを開始できない。変更後の本体Workerを遠隔配備する前に、
結線先の現行version/flagを再確認し、実権限・通信を検証する。

AWS CLIの一時ログインを個人のブラウザで更新し、STS account
`164892691568` とKMSの東京リージョン対称鍵がEnabledであることを読取確認。
現行鍵policyはアカウントrootへの管理許可だけで、専用実行主体はまだ存在しない。
AWS予算は月3 USD、実費1.5/3 USDと予測3 USDの通知（請求停止ではない）。
専用staging IAM方針の候補は
`scripts/aws-kms-staging-worker-policy.json`。同一鍵のEncrypt/Decryptと
唯一の暗号化コンテキストキーに絞る。IAMユーザーやアクセスキーは
作成していない。候補差分の独立レビューは完了したが、実権限は未検証。
AWS Access Analyzerのidentity policy検証はfindings 0。
IAM Simulatorは正しい鍵＋唯一のcontext keyでEncrypt/Decryptを許可、
context欠落・余分なkey・別の鍵・鍵削除はimplicitDenyを確認。
これは静的IAM判定であり、実行鍵の作成・KMS Workerの実通信・鍵の安全運用の証拠ではない。
