# 本人2台用・写真／まど名共有staging運用

この手順は、本人所有の2台だけへ配布した内部TestFlightで「今の一枚」と暗号化まど名同期を継続利用する例外運用です。一般向けTestFlight、App Store公開、第三者の招待を許可するものではありません。

## 正常な公開境界

- `MOMENT_RUNTIME_ENABLED=YES`: 現行の一枚共有だけを利用可能にする
- `WINDOW_NAME_RUNTIME_ENABLED=YES`: 暗号化済みのまど名同期を利用可能にする
- `LEGACY_SHARING_RUNTIME_ENABLED=NO`: 旧日次共有は常に無効
- `/health`: `200`とexactなhealth JSON
- 未認証の`/v2/moments/changes`: `401 invalid_authentication`
- 未認証の`/v2/window-name`: `401 invalid_authentication`
- `/v1/sharing/sources`: `503 legacy_sharing_runtime_disabled`

写真、暗号文、鍵、利用者識別子を監視へ送りません。公開endpointのstatusとerror codeだけを1日1回確認します。取り違えを防ぐため、監視先は本人用stagingの既知HTTPS originへworkflow内で固定し、GitHub variableから差し替えません。Workerを移す場合はorigin変更もreview対象にします。

schedule失敗を見落とさないよう、repository ownerはGitHub Actionsの失敗通知を有効にし、週1回は`Personal sharing staging monitor`の直近runが緑であることを確認します。監視を置くだけで無人対応になるわけではありません。

手元で現在の境界を確認する場合は次を実行します。

```powershell
$env:NEKO_STAGING_API_ORIGIN = "https://neko-window-sharing-staging.nakanishisoya.workers.dev"
npm run staging:runtime:check -- --expected on
```

この確認はWorkerのroutingとruntime switch、未認証時のauthentication境界を検査します。D1への実読み書き、R2、Cron、受信端末の同期、Appleのbackground実行までは証明しません。Cloudflare dashboardでは週1回を目安に、D1/R2使用量、2本のCron、error/exception、R2のPublic Development URL無効とCustom Domains空を確認します。請求上限や予算通知はCloudflare側の別設定です。

## 写真配送・まど名同期の緊急OFF（Worker全停止ではない）

想定外の写真配送、誤った相手、暗号化やmoderationの疑い、急なerror増加、費用急増があれば、新しい写真の送受信を止めます。Cloudflare dashboardで変数だけを手編集せず、review済みのignored OFF configと固定版Wranglerを使います。

まず外部変更をしないdry-runを行います。

```powershell
& .\scripts\personal-staging-emergency-off-windows.ps1 -DryRun
```

実際に止めるときだけ、同じreview済みSharingService worktreeで明示確認を付けます。実行元はcleanなdetached HEADで、そのcommitが`origin/main`へ含まれることも自動確認します。cleanなだけの未merge branchはdeployしません。

```powershell
& .\scripts\personal-staging-emergency-off-windows.ps1 `
  -ConfirmPersonalStagingEmergencyOff
```

この操作は通常moment、暗号化まど名、旧共有を`NO`にしたbundleを再検査してdeployし、公開endpointがOFF境界へ変わるまで確認します。停止後もhealth、ペアリング、通報、block、cleanupは残り、新しいmomentのreserve、upload、commit、receive、ACKとまど名のGET/PUTが止まります。既に端末へ安全に保存済みの履歴を遠隔削除する操作ではありません。

Workerの公開origin自体とペアリング・安全APIまで止める重大事故では、このコマンドを全停止とみなさず、[Worker全体を止める別手順](STAGING.md#停止条件)で`workers_dev=false`をreview・commitしてdeployします。

ONへ戻すコマンドはこの緊急手順に含めません。原因、影響範囲、非公開R2、D1、moderation、2台の資格情報を確認し、別のreview済み変更として再開します。
