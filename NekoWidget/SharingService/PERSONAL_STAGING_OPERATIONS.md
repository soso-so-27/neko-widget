# 本人2台用・写真／まど名共有staging運用

この手順は、本人所有の2台だけへ配布した内部TestFlightで「今の一枚」と暗号化まど名同期を継続利用する例外運用です。一般向けTestFlight、App Store公開、第三者の招待を許可するものではありません。

## 正常な公開境界

- `MOMENT_RUNTIME_ENABLED=YES`: 現行の一枚共有だけを利用可能にする
- `WINDOW_NAME_RUNTIME_ENABLED=YES`: 暗号化済みのまど名同期を利用可能にする
- `APNS_RUNTIME_ENABLED=YES|NO`: 通知だけを独立制御する。通知OFFでも写真同期を正本として維持する
- `REPORT_INGESTION_RUNTIME_ENABLED=YES|NO`: 新規通報受付だけを独立制御する。OFFでもblockとcleanupを維持する
- `LEGACY_SHARING_RUNTIME_ENABLED=NO`: 旧日次共有は常に無効

`0011`適用後は上記varを上限とし、D1のsingleton runtime gateも同時にONでなければ
media（写真・ハート・暗号化まど名）、APNs、新規通報受付はfail closedになります。gateは
generation付きCASだけで更新し、初期値はすべてOFFです。`personal-staging-runtime-gate-manifest.json`
はGit管理外に置き、固定account／Worker／D1／origin、期待generation、`build70-media-apns-on`
（media ON、APNs ON、通報OFF）または`broad-off`だけを記録します。

```powershell
npm run staging:runtime:gate
# 実操作は別途承認時だけ。通常の引数、任意SQL、任意originは受け付けません。
node .\scripts\personal-staging-runtime-gate.mjs --confirm-build70-media-apns-on
node .\scripts\personal-staging-runtime-gate.mjs --confirm-broad-off
```

実操作は固定ignored configからD1へ`UPDATE ... WHERE generation=<expected> RETURNING ...`を
1回だけ実行し、変更1件と同一origin `/health` のgeneration／実効状態headerを照合します。
この開発作業ではremote更新・照会を実行しません。gate導入前のWorkerへrollbackするとD1 gateを
読まないため、上限varがOFFでない限り安全なrollbackではありません。
- `/health`: `200`とexactなhealth JSON
- 未認証の`/v2/moments/changes`: `401 invalid_authentication`
- 未認証の`/v2/window-name`: `401 invalid_authentication`
- `/v1/sharing/sources`: `503 legacy_sharing_runtime_disabled`

写真、暗号文、鍵、利用者識別子を監視へ送りません。公開endpointのstatusとerror codeだけを1日1回確認します。取り違えを防ぐため、監視先は本人用stagingの既知HTTPS originへworkflow内で固定し、GitHub variableから差し替えません。Workerを移す場合はorigin変更もreview対象にします。

schedule失敗を見落とさないよう、repository ownerはGitHub Actionsの失敗通知を有効にし、週1回は`Personal sharing staging monitor`の直近runが緑であることを確認します。監視を置くだけで無人対応になるわけではありません。

### Build 34でまど名同期を再開

2026-08-23にBuild 33のまど名署名形式の不一致を確認したため、写真配送を維持したまま`WINDOW_NAME_RUNTIME_ENABLED=NO`へ一時的に切り替えました。修正済みBuild 34を本人所有2台へ導入し、同じまど名が受信側へ反映されることを確認した後、`WINDOW_NAME_RUNTIME_ENABLED=YES`へ戻しています。schedule監視も通常の`on`境界を正本とし、未認証の通常momentとまど名endpointはともに`401 invalid_authentication`、旧共有だけは`503 legacy_sharing_runtime_disabled`を期待します。確認時はD1の`moment_window_names`が1件であることだけを集計し、暗号文や名前の内容は読み取りませんでした。

手元で現在の境界を確認する場合は次を実行します。

```powershell
$env:NEKO_STAGING_API_ORIGIN = "https://neko-window-sharing-staging.nakanishisoya.workers.dev"
node scripts/check-staging-runtime.mjs --expected on
```

この確認はWorkerのroutingとruntime switch、未認証時のauthentication境界を検査します。D1への実読み書き、R2、Cron、受信端末の同期、Appleのbackground実行までは証明しません。Cloudflare dashboardでは週1回を目安に、D1/R2使用量、3本のCron、error/exception、R2のPublic Development URL無効とCustom Domains空を確認します。請求上限や予算通知はCloudflare側の別設定です。

## 広いOFF候補のlocal検証（Workerは停止しない）

review済みのignored OFF configが、通常moment、reaction、暗号化まど名、APNs、新規通報受付、旧共有を
すべて`NO`にしたbundleを作れることだけをlocalで確認する。これは現在activeなWorkerを変更せず、緊急停止を
実行するコマンドではない。

先に`SharingService/emergency-off-control-manifest.json`を作り、Gitに追跡させない。値はDashboardや承認記録で
別々に確認した実値を記入し、API token、鍵、email、利用者・端末・通報IDは入れない。

```json
{
  "schemaVersion": 1,
  "accountId": "<32文字のlowercase hex>",
  "workerName": "<対象Worker名>",
  "origin": "https://<同じWorkerの固定origin>",
  "expectedActiveVersionId": "<現在であるべきreview済みON version UUID>",
  "preapprovedOffVersionId": "<事前作成・review済みOFF version UUID>"
}
```

manifestは余分なfield、同じversion ID、非canonicalなaccount／Worker／origin／versionを拒否する。local検証の
成功は、versionが実在すること、現在activeであること、originがそのWorkerへ向くことを照会・証明しない。

package commandは`-DryRun`を内部で固定し、manifest契約のlocal検証後にOFF bundleだけを作る。

```powershell
npm run staging:runtime:emergency-off
```

直接実行する場合も許可するのは次だけである。

```powershell
& .\scripts\personal-staging-emergency-off-windows.ps1 `
    -ControlManifestPath .\emergency-off-control-manifest.json `
    -DryRun
```

`-ConfirmPersonalStagingEmergencyOff`は、config解決、Git remote-state確認、Wrangler起動、公開endpoint確認の
前に必ず失敗する。旧実装はdeploy先account／Workerと検証先originを原子的に束縛できず、別Workerを変更した
後で既にOFFのoriginを確認して成功と誤認できたため、外部deploy／query経路を廃止した。

pureな計画生成は、呼び出し側が渡したaccount／Worker／active version snapshotがmanifestと完全一致しない
限りplanを返さない。一致時のplanも`preapprovedOffVersionId`と同じoriginのexact OFF確認要件を示すだけで、
query、mutation、HTTP確認を実行しない。repositoryには実providerがなく、Cloudflareのversion切替APIに
expected-currentの原子的なpreconditionがないため、GET後の切替を安全なcompare-and-swapとは扱わない。

現在のrepositoryには、広いruntime OFFまたはWorker全停止を安全に外部実行するコマンドはない。想定外の配送、
誤routing、暗号化／moderationの疑い、急なerror・費用増加では、local dry-run成功を停止証拠にせず、本人2台の
利用を中断して、別途承認されたCloudflare incident responseへescalateする。manifestとpure planは誤対象を
拒否する準備であり実停止ではない。原子的な条件または同等にreviewされた安全な切替方式、実provider、対象
productionでの訓練が完成するまで、この欠落は継続利用と一般配布のblockerである。

原因、影響範囲、非公開R2、D1、moderation、2台の資格情報を確認するまで再開しない。

## 通知／新規通報だけのOFF候補（実停止ではない）

まず[`STAGING.md`の一般配布候補config手順](STAGING.md#一般配布候補の独立停止config生成検証のみ)で
ignored候補を生成・exact比較する。現時点の個別コマンドはlocal dry-run専用で、外部deployを行わない。

写真共有を継続できる一方で通知providerだけに異常がある場合の候補:

```powershell
npm run staging:runtime:apns-off
```

通報鍵、moderation受付または担当体制だけに異常がある場合の候補:

```powershell
npm run staging:runtime:report-ingestion-off
```

通常の写真・ハート・まど名・APNsだけを止め、通報受付とblock／cleanupを残す場合はmedia-onlyを使う。

```powershell
npm run staging:runtime:media-off
```

3つのconfirmation引数は、local bundle確認後に必ず失敗してdeployしない。通常deployにはactive versionの
原子的な条件がなく、別deployとの競合やcode／binding／Cronの同時変更を「1機能だけOFF」と誤認できるため
である。review済みON/OFF version IDと条件付き切替が完成するまでは選択的実停止を利用可能と扱わない。

広いOFFを含む実停止経路も提供しない。本人2台のpersonal stagingでもlocal dry-runを停止とみなさず、
利用中断と承認済みincident responseへescalateする。一般配布では実停止の未整備をrelease blockerとする。
将来の仕組みでは全状態を事前生成し、deploy先account／Worker、review済みversion ID、active-version条件、
検証originを同じ保護manifestへ束縛する。
