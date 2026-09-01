# Cloudflare隔離staging手順

この手順は「今の一枚」のCloudflare実環境検証を、productionと共有しないWorker、D1、R2、rate-limit namespaceで始めるためのものです。この段階では通常moment、reaction、暗号化まど名、APNs、新規通報受付、旧日次共有runtimeを有効にしません。追跡対象の`wrangler.staging.template.jsonc`と通常preflightはこれらのflagがすべてexact `NO`であることを要求します。section 7の用途別preflightだけが、同じOFF設定から派生したignored ON候補をdry-run用に検証します。

この手順が作成する外部resourceはstaging専用です。

> 2026-08-27現在、本人所有2台ではBuild 70の写真・ハート・まど名・APNsを確認し、旧共有を`LEGACY_SHARING_RUNTIME_ENABLED=NO`で運用します。一般公開や第三者の招待を認める変更ではありません。日次監視、D1 generation CASによる共有data-plane OFF／復旧、独立OFF Worker候補のlocal検証は[本人2台用・写真／まど名共有staging運用](PERSONAL_STAGING_OPERATIONS.md)を正本とします。active Worker code／binding自体を疑うincident向けのversion実切替はrepositoryから提供しません。以下の通常手順のOFF既定と、ON候補を直接deployしない原則は変更しません。
>
> Build 36は`disabled`かつApp Store Connectへ送信しない署名dry runであり、このstagingのWorker、D1、R2、rate-limit namespace、secret、runtime flagを一切変更していません。

| 種類 | 名前 |
|---|---|
| Worker | `neko-window-sharing-staging` |
| D1 | `neko-window-sharing-staging` |
| 通常写真R2 | `neko-window-sharing-staging-media-private` |
| 通報R2 | `neko-window-sharing-staging-moderation-private` |

今回のstaging resourceはすべて同じCloudflare accountに置き、作成時のlocation hintは`apac`に揃えます。

`wrangler.example.jsonc`と`wrangler.jsonc`は、この手順では編集・deployしません。D1 ID、Cloudflare account ID、rate-limit namespace ID、API tokenをcommitしません。生成される`wrangler.staging.jsonc`は`.gitignore`対象です。

## 1. 認証と対象accountの固定

PowerShellで`NekoWidget/SharingService`へ移動し、locked dependencyを入れます。

```powershell
npm ci --ignore-scripts
$wranglerVersion = (npx --no-install wrangler --version | Out-String)
if ($wranglerVersion -notmatch "4\.125\.0") { throw "reviewed Wrangler version is required" }
npx --no-install wrangler login
npx --no-install wrangler whoami
```

`whoami`に表示された対象accountを読み上げて確認します。複数accountがある場合は、対象account IDを現在のPowerShell processだけへ設定します。値を`.env`、メモ、shell scriptへ保存しません。

```powershell
$env:CLOUDFLARE_ACCOUNT_ID = Read-Host "stagingを作るCloudflare account ID"
```

以後のresource作成、migration、deployを同じPowerShell processで行います。

## 2. staging専用resourceの作成

最初に対象accountの既存resourceを読みます。

```powershell
npx --no-install wrangler d1 list --json
npx --no-install wrangler r2 bucket list
```

上表と同名のresourceがすでに3つ存在する場合、作成コマンドを再実行しません。所有accountと実IDを確認できない同名resourceがあれば停止します。存在しない場合だけ次のコマンドを一つずつ実行します。名前が上表と完全一致すること、production名を含まないことを確認します。`--update-config=false`と自動resource作成無効によりtracked configや別resourceを暗黙に変更させません。

```powershell
npx --no-install wrangler d1 create neko-window-sharing-staging --location apac --update-config=false --experimental-provision=false --experimental-auto-create=false
npx --no-install wrangler r2 bucket create neko-window-sharing-staging-media-private --location apac --update-config=false --experimental-provision=false --experimental-auto-create=false
npx --no-install wrangler r2 bucket create neko-window-sharing-staging-moderation-private --location apac --update-config=false --experimental-provision=false --experimental-auto-create=false
```

R2 bucketは既定で非公開です。Cloudflare dashboardと次のCLIの両方で、Public Development URLが無効、Custom Domainsが空であることを確認します。`r2.dev`を有効にしません。

```powershell
npx --no-install wrangler r2 bucket dev-url get neko-window-sharing-staging-media-private
npx --no-install wrangler r2 bucket domain list neko-window-sharing-staging-media-private
npx --no-install wrangler r2 bucket dev-url get neko-window-sharing-staging-moderation-private
npx --no-install wrangler r2 bucket domain list neko-window-sharing-staging-moderation-private
```

このstaging configはWorkers Freeでもdeployできるよう、`limits`を設定せずaccount planの既定値を使います。R2は月額基本料0でも無料枠超過分は従量課金です。写真runtimeをOFFに保ち、意図しないobject作成をsmokeで確認します。

Rate Limiting bindingの`namespace_id`は、Cloudflare account内で一意な正の整数を文字列として指定します。4 binding間でも、他のWorkerとも共有しない4値を決めます。namespace resourceを別途作成する操作はありません。

## 3. untracked configの生成

D1作成結果のUUIDと、確認済みのrate-limit namespace IDを現在のprocessへ読み込みます。`Read-Host`を使うことで値をPowerShell historyへ残しません。

```powershell
$env:NEKO_STAGING_D1_DATABASE_ID = Read-Host "staging D1 database ID"
$env:NEKO_STAGING_CREATE_RATE_LIMIT_NAMESPACE_ID = Read-Host "未使用のcreate rate namespace ID"
$env:NEKO_STAGING_INVITE_RATE_LIMIT_NAMESPACE_ID = Read-Host "未使用のinvite rate namespace ID"
$env:NEKO_STAGING_MEMBER_RATE_LIMIT_NAMESPACE_ID = Read-Host "未使用のmember rate namespace ID"
$env:NEKO_STAGING_BILLING_RATE_LIMIT_NAMESPACE_ID = Read-Host "未使用のbilling rate namespace ID"
$env:NEKO_STAGING_BILLING_APPLE_NOTIFICATION_RATE_LIMIT_NAMESPACE_ID = Read-Host "未使用のApple notification rate namespace ID"
npm run staging:config:render
npm run staging:config:check
git check-ignore -v wrangler.staging.jsonc
```

Rendererは既存の`wrangler.staging.jsonc`を上書きしません。resourceを取り違えた場合はdeployせず、値を確認してから生成ファイルだけを削除し、再生成します。preflightは次を確認します。

- Worker、D1、通常R2、通報R2がstaging固有名である
- `workers_dev=true`かつpreview URLとcustom routeが無効である
- `ENVIRONMENT=staging`であり、写真・反応・まど名・通知・旧共有・通報受付と8つの課金runtimeがすべて`NO`である
- Workers Paid専用のcustom `limits`が存在しない
- rate limit 5本が固有namespaceで、作成5/min・招待10/min・member 120/min・課金30/min・Apple通知30/minである。Apple通知値は本人用stagingだけの暫定値で、productionへ流用しない
- cleanup／通知配送を含むCron 3本がある
- account固有のIDや未置換placeholderをtracked templateへ持ち込まない

## 4. migrationの事前確認と適用

D1 migrationはbinding名ではなくstaging database名を明記します。最初に`d1 list --json`の同名database IDと生成configのIDがexact一致することを確認します。新規で空のstaging D1では、未適用一覧がrepositoryの`0001_pairing.sql`から`0025_billing_apple_notification_history_recovery.sql`までの25件と昇順でexact一致しなければ停止します。既存D1では、適用済みledgerが同じ25件の連続したprefix、未適用一覧が残りのsuffixであることを照合し、欠番、順序違い、未知fileがあれば停止します。

`0012`〜`0018`は通報・管理操作のappend-only監査と権限境界を追加し、既存記録を推測で補完しません。`0019`〜`0024`は共有identityと分離した課金account、Apple authority、実効権限、課金鍵復旧、最大3まどの購入者支援、まど所有者による支援解除を追加します。`0025`はApple通知履歴の欠落回復を、独立した下限gate、固定期間、lease、cursor、冪等cause台帳とともに追加します。課金migrationはすべて下限gateを`0`で作り、HTTP上限もtracked configでは`NO`のままです。migration適用だけで購入、Plus権限、支援、復旧を開始しません。SQLiteの合成訓練は署名、Apple JWS、実際のStoreKit購入を検証したとは主張しません。生成済みconfigの実在D1 UUIDを使い、Wranglerにresourceを自動生成させません。

課金8 Gateの固定OFF、通常7 GateのON config、段階的generation CAS、同一originのhealth証明、緊急一括OFFは[Plus課金staging安全操作](BILLING_STAGING_OPERATIONS.md)を正本とします。Apple通知履歴復旧は通常ON configでもOFFを維持し、別のreview済み訓練を必要とします。Verifierのloopback／Redis fail-closed実装はありますが、private ingress、TLS Redis instance、secret、Apple Sandbox商品、DEBUG実機経路が揃うまでは、設定生成とlocal検査だけに留めます。

課金migrationをremoteへ適用する前に、次の完全ローカル訓練を通します。system temp配下に一時SQLiteを作り、全migration、上下gateの既定OFF、世代CAS、購入者による支援・解除、実効権限OFF中の所有者解除、全課金下限gateをOFFへ戻す終了状態を合成データだけで確認します。ネットワーク、Wrangler、Cloudflare、Apple、秘密情報は使用しません。

```powershell
npm run billing-sponsorship:local-drill
```

```powershell
npx --no-install wrangler d1 migrations list neko-window-sharing-staging --remote --config wrangler.staging.jsonc --experimental-provision=false --experimental-auto-create=false
npx --no-install wrangler d1 migrations apply neko-window-sharing-staging --remote --config wrangler.staging.jsonc --experimental-provision=false --experimental-auto-create=false
npx --no-install wrangler d1 migrations list neko-window-sharing-staging --remote --config wrangler.staging.jsonc --experimental-provision=false --experimental-auto-create=false
```

Apply前の確認promptでdatabase名またはmigration一覧が違う場合は承認しません。trigger migrationはLF改行と括弧付き`CASE`をCIで固定し、Wrangler/D1のremote parser回帰を防ぎます。失敗時はD1が空のままかを確認し、場当たり的なSQLやmigration ledgerの手動挿入で進めません。

### 管理Workerの公開routeなし・runtime OFF shell

`wrangler.moderation-operator.disabled.jsonc`は、将来の通報確認機能を通常の写真共有Workerから
分離するための**ローカルbundle候補**であり、配備設定ではありません。`workers_dev=false`、
`preview_urls=false`、custom routeなし、runtimeはexact `NO`で固定し、D1、R2、Cron、Queue、
service、rate limit、secretのbindingを一つも持ちません。管理APIのoperationもまだ0件です。
account側で別途Service Bindingやrouteを設定していないことまでは、このtracked configだけでは証明しません。
仮に外部から呼ばれても、runtime gateが一定の503を返し、operationへ到達させない設計です。

```powershell
npm run moderation-operator:config:check
$operatorBundle = Join-Path $env:TEMP ("neko-moderation-operator-disabled-" + [guid]::NewGuid())
npx --no-install wrangler deploy --dry-run --config wrangler.moderation-operator.disabled.jsonc --outdir $operatorBundle --autoconfig=false --experimental-provision=false --experimental-auto-create=false
```

このconfigへの通常の`wrangler deploy`、route追加、Dashboardでの変数変更、resource binding追加を
行いません。Access JWT verifier、厳格WebAuthn verifier、append-only access audit schema、承認provenance、
version付きcase参照、sanitized control-plane snapshotのpure validatorは存在しても、routeへ接続されて
いません。pure validatorはlive Cloudflare設定を取得せず、成功しても`releaseReady: false`です。live Access／
account snapshotの独立照合、専用rate-limit binding、同じD1 transactionでのexact quota、成功時のdomain side
effectを結ぶ統合試験が完成し、明示承認されるまではruntimeをONに
しません。将来D1を追加する場合はcase lifecycleと原子的制約を共有する同じD1だけを使い、通常写真の
`MEDIA` bindingは管理Workerへ渡しません。

## 5. bundleのローカル確認

外部uploadを行わないdry-runを先に通します。

```powershell
npm run staging:config:check
$stagingBundle = Join-Path $env:TEMP ("neko-sharing-staging-" + [guid]::NewGuid())
npx --no-install wrangler deploy --dry-run --config wrangler.staging.jsonc --outdir $stagingBundle --autoconfig=false --experimental-provision=false --experimental-auto-create=false
```

出力に次が表示されることを確認します。

- Worker名が`neko-window-sharing-staging`
- D1が`neko-window-sharing-staging`
- `MEDIA`と`MODERATION_MEDIA`が異なるstaging bucket
- 5本のRate Limit binding
- 写真・反応・まど名・通知・旧共有・通報受付と8つの課金runtimeがすべて`NO`

`/health`のApple通知limiter `READY`はbinding objectの存在だけを示し、active namespace ID・limit・periodは示しません。release判定では、固定したactive deployment/versionのCloudflare control-planeからsanitized binding snapshotを取得し、review済みconfigとexact照合します。ローカルconfig検査と`READY`だけを実配備の証拠にはしません。

現在のrepositoryは、account／Worker／固定origin／期待active version／事前承認済みOFF versionをexact manifestへ束縛し、呼び出し側のactive snapshotが不一致なら副作用のない切替planすら返さないpure契約まで実装しています。既定はdry-runで、実provider、Cloudflare query、version切替、origin確認はありません。Cloudflareの公開version切替APIにexpected-currentの原子的preconditionがないため、GET後のPOSTを条件付き切替やcompare-and-swapとは表現しません。この手順ではdry-runより先へ進まず、通常の`wrangler deploy`やDashboardの手動var編集でも代用しません。安全な切替方式、直後の同一origin exact OFF確認、rollback訓練が実装・承認された後にだけ別手順で実配備します。

## 6. 将来の実配備後に必要なruntime OFF smoke

URLは現在のprocessだけへ置き、末尾へpath、query、fragmentを加えません。

```powershell
$env:NEKO_STAGING_API_ORIGIN = Read-Host "staging Worker HTTPS origin"
curl.exe -i "$env:NEKO_STAGING_API_ORIGIN/health"
curl.exe -i "$env:NEKO_STAGING_API_ORIGIN/v2/moments/changes"
curl.exe -i "$env:NEKO_STAGING_API_ORIGIN/v2/window-name"
curl.exe -i "$env:NEKO_STAGING_API_ORIGIN/v1/sharing/sources"
```

期待値は次のとおりです。

- `/health`: `200`、`{"status":"ok","protocolVersion":1}`
- `/v2/moments/changes`: `503`、error code `moment_runtime_disabled`
- `/v2/window-name`: `503`、error code `window_name_runtime_disabled`
- `/v1/sharing/sources`: `503`、error code `legacy_sharing_runtime_disabled`

Cloudflare dashboardで3本のCronが登録済みであり、両R2 bucketが引き続き非公開であることも確認します。`/health`はD1/R2/Cronの健全性を証明しないため、これだけでruntimeをONにしません。

## 7. 写真・まど名runtimeの短時間テスト設定を準備する（deployしない）

この節は、通常写真、ハート、暗号化まど名を2台だけで検証するためのON候補と、rollback候補を同じresource設定から生成します。生成だけではCloudflareへ何も送信しません。tracked templateは全runtimeのexact `NO`を正本とし、media候補は`MOMENT_RUNTIME_ENABLED`、`REACTION_RUNTIME_ENABLED`、`WINDOW_NAME_RUNTIME_ENABLED`だけを`YES`にしてignored fileへ派生させます。APNs、新規通報受付、旧日次共有は`NO`のままです。

先に次の外部条件をすべて満たしている必要があります。

- 公開済みのprivacy、community standards、supportのHTTPS URLをApp内から確認できる
- media-staging用Privacy manifestとApp Store ConnectのApp Privacy回答が一致する
- 通報専用公開鍵をreleaseへ設定し、秘密鍵はGitHub、Cloudflare、repo外の安全な保管先にある
- [`MODERATION_STAGING_DRILL_RUNBOOK.md`](MODERATION_STAGING_DRILL_RUNBOOK.md)のoffline合成通報を
  operator toolで生成・検証・復号・human view・descriptor-bound削除し、exact audit遷移を確認済み
- 同じcommitのmedia-staging TestFlight Buildを本人所有の2台だけへ配布している
- 通常R2と通報R2が非公開で、対応担当者、48時間以内の初回確認、kill switch手順が決まっている

section 3と同じ5つの環境変数を設定したPowerShell processで、OFFとONを別々に生成します。既存fileを上書きしないため、再生成が必要なら対象がこのdirectory内のignored configであることを確認してから手動で削除します。

```powershell
npm run staging:config:render
npm run media-staging:config:render
npm run staging:config:check
npm run media-staging:config:check
git check-ignore -v wrangler.staging.jsonc
git check-ignore -v wrangler.media-staging-on.jsonc
```

`media-staging:config:check`は、両configが同じWorker、D1、非公開R2、rate limit、Cronを使い、通報受付、APNs、旧共有を`NO`に保ったまま、差がmedia用3 flagの`NO`／`YES`だけであることを確認します。IDやresource名が一つでも違えば停止します。

明示的に許可されたテスト窓の前でも、ON候補はdry-runまでに留めます。

```powershell
$mediaBundle = Join-Path $env:TEMP ("neko-sharing-media-staging-" + [guid]::NewGuid())
npx --no-install wrangler deploy --dry-run --config wrangler.media-staging-on.jsonc --outdir $mediaBundle --autoconfig=false --experimental-provision=false --experimental-auto-create=false
```

ON候補とOFF候補の実deployは、このrepositoryの現状では行いません。対象account／Worker／active versionを固定した条件付き切替が実装された後に、別の明示承認を得て一つの短時間テスト窓として実施します。テスト完了・失敗・中断のいずれでも同じ対象へreview済みOFF versionを原子的に戻し、同一originでruntime停止を確認できることが採用条件です。通常のdeployやDashboardの手動var編集は代替になりません。

### 一般配布候補の独立停止config（生成・検証のみ）

一般配布の安全試験では、写真・APNs・新規通報受付をすべてONにした候補を起点として、APNsだけOFF、
新規通報受付だけOFF、mediaとAPNsをOFFにして通報窓口だけ維持、の3遷移をexact比較する。

```powershell
npm run notification-staging:config:render
npm run report-ingestion-staging:config:render
npm run general-staging:config:render
npm run general-staging:apns-off-config:render
npm run selective-staging-off:config:check
```

各rendererは既存fileを上書きせず、出力はすべてgit ignoredである。checkは同じWorker／binding／Cron／
rate limitであることと、各遷移でreview済みruntime flag以外が一切変わらないことを要求する。ここでは
deploy、migration、secret変更を行わない。OFF候補と実停止未実装の境界は
[`PERSONAL_STAGING_OPERATIONS.md`](PERSONAL_STAGING_OPERATIONS.md)、APNsは
[`APNS_OPERATIONS.md`](APNS_OPERATIONS.md)、通報は[`MODERATION_RUNBOOK.md`](MODERATION_RUNBOOK.md)を正本とする。

## 停止条件

この手順単体ではruntimeを実deployせず、section 7のignored候補もdry-runまでに留めます。短時間ONは、列挙した外部gateを満たした後に別の明示承認でだけ行います。`LEGACY_SHARING_RUNTIME_ENABLED`はstagingでも常に`NO`です。

生成config、migration対象、Worker名、bucket公開状態の一つでも不明な場合はdeployしません。D1/R2/Workerを削除する操作はこの手順に含めません。

workers.devは公開originです。この段階でも招待・ペアリングAPIはインターネットから到達し、rate limitで保護されます。通常moment／暗号化まど名／旧共有のflag OFFだけでは、ペアリングと安全APIまで停止しません。現在のvalidatorは誤配備防止のため`workers_dev=true`のstaging候補だけを受け付け、`workers_dev=false`への通常deployを全停止手順として使いません。固定account／Worker／active deployment／versionと、account全zoneのWorkers Routesおよびcustom domain不在を前後照合し、script単位のworkers.dev公開入口だけをOFF/ONするcontrollerは`PERSONAL_STAGING_OPERATIONS.md`に定義しています。Cloudflare APIに原子的なexpected-current条件はないためdeploy凍結と二重照合が必須で、対象stagingで停止・到達不能・同一version復旧の実訓練が完了するまでは一般配布のrelease blockerです。local dry-runや別originの応答を停止証拠にしません。

## 公式資料

- [Wrangler configuration](https://developers.cloudflare.com/workers/wrangler/configuration/)
- [D1 migrations](https://developers.cloudflare.com/d1/reference/migrations/)
- [R2 bucket creation](https://developers.cloudflare.com/r2/buckets/create-buckets/)
- [R2 public access](https://developers.cloudflare.com/r2/buckets/public-buckets/)
- [Workers Rate Limiting binding](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/)
- [Workers limits](https://developers.cloudflare.com/workers/platform/limits/)
- [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/)
- [R2 pricing](https://developers.cloudflare.com/r2/pricing/)
