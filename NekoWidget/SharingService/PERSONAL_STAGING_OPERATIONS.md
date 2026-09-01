# 本人2台／Build 71外部1人限定・写真／まど名共有staging運用

この手順は、本人所有2台の内部TestFlightで「今の一枚」と暗号化まど名同期を継続する運用と、Build 71候補を既知で信頼できる外部tester 1人だけへ配布する限定例外を扱います。外部例外はreportをclient／serverともOFF、public link OFF、TestFlight feedbackと48時間以内の初回確認を必須とします。2人目以降、別build、App Store審査提出、一般公開または不特定の第三者招待を許可するものではありません。

## 正常な公開境界

- `MOMENT_RUNTIME_ENABLED=YES`: 現行の一枚共有だけを利用可能にする
- `WINDOW_NAME_RUNTIME_ENABLED=YES`: 暗号化済みのまど名同期を利用可能にする
- `APNS_RUNTIME_ENABLED=YES|NO`: 通知だけを独立制御する。通知OFFでも写真同期を正本として維持する
- `REPORT_INGESTION_RUNTIME_ENABLED=YES|NO`: 新規通報受付だけを独立制御する。OFFでもblockとcleanupを維持する
- `LEGACY_SHARING_RUNTIME_ENABLED=NO`: 旧日次共有は常に無効

`0011`適用後は上記varを上限とし、D1のsingleton runtime gateも同時にONでなければ
media（写真・ハート・暗号化まど名）、APNs、新規通報受付はfail closedになります。gateは
generation付きCASだけで更新し、初期値はすべてOFFです。`personal-staging-runtime-gate-manifest.json`
はGit管理外に置き、固定account／Worker／D1／origin、期待generationと次のreview済み状態だけを記録します。

- `build70-media-apns-on`: media ON、APNs ON、通報OFF。状態名はBuild 70で導入した履歴を示すだけで、Build 71候補の信頼できる外部1人限定betaも同じD1境界を使う
- `broad-off`: media／APNs／通報OFF

controllerが読む上限configはGit管理外の`wrangler.general-staging-on.jsonc`に固定し、すべての
上限varが`YES`かつ固定Worker／D1と一致しない限り、planも実操作も拒否します。
現在のcontrollerは通報ON状態を受け付けません。安全なremote export／判断／早期削除と実担当者による
訓練が完成するまで、D1 gateの通報値は0に固定し、上限configが誤ってYESでもfail closedにします。

```powershell
npm run staging:runtime:gate
# 固定D1のread-only rowと同一originのhealthを照合する。
npm run staging:runtime:status
# 実操作は別途承認時だけ。任意SQL、任意origin、任意状態は受け付けない。
npm run staging:runtime:emergency-off:confirm
npm run staging:runtime:recover:confirm
```

実操作は固定ignored configからD1へ`UPDATE ... WHERE generation=<expected> RETURNING ...`を
1回だけ実行し、変更1件と同一origin `/health` のgeneration／実効状態headerを照合します。
`status`は固定SELECT以外を書き込まず、D1 rowとhealthが一致し、manifestの期待generationが
現在値と一致するときだけ成功します。timeout後に更新済みか不明な場合は確認コマンドを再実行せず、
まず`status`で現在generationを照合します。gate導入前のWorkerへrollbackするとD1 gateを読まないため、
上限varがOFFでない限り安全なrollbackではありません。
- `/health`: `200`とexactなhealth JSON
- 未認証の`/v2/moments/changes`: `401 invalid_authentication`
- 未認証の`/v2/window-name`: `401 invalid_authentication`
- `/v1/sharing/sources`: `503 legacy_sharing_runtime_disabled`

写真、暗号文、鍵、利用者識別子を監視へ送りません。公開endpointのstatusとerror codeだけを1日1回確認します。取り違えを防ぐため、監視先は本人用stagingの既知HTTPS originへworkflow内で固定し、GitHub variableから差し替えません。Workerを移す場合はorigin変更もreview対象にします。

schedule失敗を見落とさないよう、repository ownerはGitHub Actionsの失敗通知を有効にし、週1回は`Personal sharing staging monitor`の直近runが緑であることを確認します。監視を置くだけで無人対応になるわけではありません。

### Build 34でまど名同期を再開

2026-08-23にBuild 33のまど名署名形式の不一致を確認したため、写真配送を維持したまま`WINDOW_NAME_RUNTIME_ENABLED=NO`へ一時的に切り替えました。修正済みBuild 34を本人所有2台へ導入し、同じまど名が受信側へ反映されることを確認した後、`WINDOW_NAME_RUNTIME_ENABLED=YES`へ戻しています。現在のschedule監視は、通常momentとまど名endpointに加えてreport 3経路も検査する`limited-external-beta`境界を正本とし、旧共有は`503 legacy_sharing_runtime_disabled`を期待します。確認時はD1の`moment_window_names`が1件であることだけを集計し、暗号文や名前の内容は読み取りませんでした。

手元で現在の境界を確認する場合は次を実行します。

```powershell
$env:NEKO_STAGING_API_ORIGIN = "https://neko-window-sharing-staging.nakanishisoya.workers.dev"
# media/APNsがON・reportがOFFで、通報3経路がauth-firstの401、旧共有が503であることを確認する。
npm run staging:runtime:limited-external-beta:check
```

この公開checkerはruntime境界と未認証応答だけを確認します。限定外部betaではアプリ内通報を提供せず、
TestFlightの非公開feedback、アプリのブロック／共有解除、必要時の`broad-off`を安全経路にします。
feedbackには写真、招待code、12語、鍵を添付させません。この縮退運用は外部1人を超える配布や
App Store一般公開には使いません。

この確認はWorkerのroutingとruntime switch、未認証時のauthentication境界を検査します。D1への実読み書き、R2、Cron、受信端末の同期、Appleのbackground実行までは証明しません。Cloudflare dashboardでは週1回を目安に、D1/R2使用量、3本のCron、error/exception、R2のPublic Development URL無効とCustom Domains空を確認します。請求上限や予算通知はCloudflare側の別設定です。

## 共有data-planeの緊急OFFと復旧

`broad-off`は、写真、ハート、暗号化まど名、APNs、新規通報受付をgeneration CASで停止します。
これはWorker全停止ではありません。既存利用者が相手をblock・共有解除でき、期限切れデータのcleanupを
継続できるようにし、pairing／機種変更経路も停止対象に含めません。

訓練または実停止の前に、新規deployを凍結し、通知outboxが空であることを件数だけ確認します。OFF中に
残った通知eventは最大24時間有効で、復旧後に配信され得ます。実incidentでは復旧前に、未送信通知を
再開するか破棄するかをincident記録で決めます。写真、暗号文、token、利用者IDは記録しません。

1. ignored manifestを現在generationと`broad-off`へ更新し、`gate`、`status`の順にlocal計画と現在値を確認する。
2. `staging:runtime:emergency-off:confirm`を1回だけ実行する。
3. `/health`と`check-staging-runtime.mjs --expected off`で新generationとOFF境界を確認する。
4. 復旧時は原因と未送信通知の扱いを確定してから、manifestをOFF後のgenerationと
   `build70-media-apns-on`へ更新する。
5. `status`、`staging:runtime:recover:confirm`、`staging:runtime:limited-external-beta:check`の順に確認する。本人2台だけへ戻す場合も、report 3経路を省略しない同じ厳しい確認を使う。

通常の写真requestはrequest開始時のgateを使うため、OFF直前にすでに処理へ入った1 requestまでを
取り消す仕組みではありません。APNs drainはprovider送信直前にも同じgenerationを再確認します。
実停止後に同じconfirmationを再実行するとCASが0件となり、安全に失敗します。

## workers.dev公開入口の全停止と復旧

D1の`broad-off`でも残る招待・pairing・機種変更を含め、固定staging originへの公開到達を止める場合は、
script単位のworkers.dev制御を使います。Worker、D1、R2、active versionは削除・deploy・rollbackせず、
`neko-window-sharing-staging.nakanishisoya.workers.dev`とpreview URLだけをOFFにします。

この操作にCloudflareの原子的なexpected-current条件はありません。したがって操作中はdeployを凍結し、専用controllerが
次をすべて満たさない限り変更を拒否します。

- API tokenのaccountが固定account subdomainを所有し、固定Workerがexactに1件ある
- account内の全zoneを完全に列挙し、各zoneの公式Workers Routes APIで固定Workerのcustom routeが0件である
- 固定Workerにcustom domainがない
- active deploymentが1 version・100%で、active version取得の前後でdeployment/versionが変わっていない
- active versionのD1 bindingが`type=d1 / name=DB`のexact 1件で、`id`と`database_id`が
  同じUUIDであり、account-scoped D1 detailのUUID／名前が`neko-window-sharing-staging`と一致する
- 上記live D1 UUIDがschema 2のbaseline manifestへ固定され、以後のstatus／OFF／復旧で
  deployment/versionと一緒に変わっていない
- preview URLがOFFで、停止前は同一originの`/health`が正常
- OFF後はCloudflare状態が`enabled=false / previews_enabled=false`で、同一originが3回連続でアプリを返さない

token値はmanifest、receipt、標準出力へ保存しません。統合訓練用の一時`CLOUDFLARE_API_TOKEN`はaccount側の
`Workers Scripts Read`、`Workers Scripts Write`、`D1 Edit`に加え、zone側の`Zone Read`と`Workers Routes Read`を付与し、
zone resourceは固定staging account配下の**All zones**に限定します。一部zoneだけを含むtokenではroute不在を証明できないため
訓練に使いません。Cloudflare Dashboardのtoken summaryでこのscopeを目視確認してから、非秘密の実行確認値
`CLOUDFLARE_ALL_ZONES_SCOPE_ATTESTED=cloudflare-all-zones-v1`を設定します。controllerがAPIで確認できるのは
credential-visible zoneまでなので、この目視確認を省略しません。`CLOUDFLARE_ACCOUNT_ID`は固定staging accountの値を、
訓練時間だけprocess環境へ渡します。
最初にread-only baselineをcaptureします。これはactive deployment取得、active version detail、
account-scoped D1 detail、active deployment再取得の順でdriftを拒否します。生成する
`personal-staging-workers-dev-control-manifest.json`はschema 2でD1 UUIDも保持します。旧schema 1 manifestは
再利用せず、進行中の`personal-staging-workers-dev-recovery.json`がないことを確認してからbaselineを
取り直します。D1 CAS用の`wrangler.general-staging-on.jsonc`、
`personal-staging-runtime-gate-manifest.json`、workers.dev manifest、停止前に排他的作成されるrecovery receiptが
すべてGitでignoredのままであることを確認します。

```powershell
npm run staging:ingress:plan
npm run staging:ingress:capture-baseline
npm run staging:ingress:status
```

Cloudflareへ変更を送る前に、schema 2 workers.dev manifestの`databaseId`、
`personal-staging-runtime-gate-manifest.json`の`databaseId`、
`wrangler.general-staging-on.jsonc`の`d1_databases[0].database_id`が同じであることを確認します。
1つでも不一致ならD1 CASもworkers.dev変更も実行しません。

短時間訓練は、別terminalやDashboardからdeployしない状態で、先にD1 `broad-off`を完了してから
公開入口を止めます。復旧は逆順にして、公開入口を同一versionで戻した後もD1をOFFのまま保ち、
最後にmedia/APNsだけを再開します。各confirmは1回だけ実行します。

```powershell
# D1 manifestを現在generation/broad-offへ合わせ、gate→status後に実行する。
npm run staging:runtime:emergency-off:confirm
npm run staging:ingress:emergency-off:confirm
npm run staging:ingress:recover:confirm
npm run staging:ingress:status
# D1 manifestをOFF後generation/build70-media-apns-onへ合わせ、status後に実行する。
npm run staging:runtime:recover:confirm
npm run staging:runtime:limited-external-beta:check
```

OFF前にrecovery receiptを排他的に作るため、途中でprocessが終了しても復旧対象のdeployment/versionを失いません。
復旧は同じreceiptとlive stateが一致する場合だけ`enabled=true / previews_enabled=false`へ戻します。復旧POSTの応答だけが
失われた場合はlive stateを再照合して完了できます。復旧後にdeployment drift、preview URLの有効化、health異常を検出した
場合は再OFFを試み、receiptを残して失敗します。Cloudflare consoleの手動toggleや通常deployを代替手順にしません。

この手順が証明するのは、固定accountの全zoneを列挙してcustom route/domainがないと確認し、
active versionのexact `DB` bindingと同じaccountの固定名D1 detailを照合した固定workers.dev originの
公開停止・同一version／同一D1 binding復旧です。
Cloudflare account全体、別Worker、production、D1/R2の削除、外部provider停止を意味しません。

## 独立OFF Worker候補のlocal検証（Workerは停止しない）

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
npm run staging:runtime:emergency-off-candidate:dry-run
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

現在のrepositoryで実行できる緊急停止は、上記D1 generation CASによる共有data-plane OFFと、
固定workers.dev公開入口のOFFです。この節のversion candidateは、active Worker code／binding自体を疑うincidentで使う独立した第二層ですが、
Cloudflare version切替にはexpected-currentの原子的preconditionがないため、repositoryからの実切替は
まだ提供しません。local dry-runを独立Worker停止の証拠にせず、D1を先にOFFにしたうえで、別途承認された
Cloudflare incident responseへescalateします。

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

選択的configの実deployと独立OFF Workerの実切替は提供しません。共有全体を止めるときは上記D1 CASを使い、
local bundle確認を停止とみなしません。一般配布前には、対象環境でD1 OFF／復旧訓練を完了し、code／binding
incidentに備えたreview済みversion ID、deploy凍結、切替後検証を同じincident手順へ束縛します。
