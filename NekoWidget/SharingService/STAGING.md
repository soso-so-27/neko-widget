# Cloudflare隔離staging手順

この手順は「今の一枚」のCloudflare実環境検証を、productionと共有しないWorker、D1、R2、rate-limit namespaceで始めるためのものです。この段階では通常moment、reaction、暗号化まど名、APNs、新規通報受付、旧日次共有runtimeを有効にしません。追跡対象の`wrangler.staging.template.jsonc`と通常preflightはこれらのflagがすべてexact `NO`であることを要求します。section 7の用途別preflightだけが、同じOFF設定から派生したignored ON候補をdry-run用に検証します。

この手順が作成する外部resourceはstaging専用です。

> 2026-08-24現在、本人所有2台では内部TestFlight Build 34までを確認し、通常momentと暗号化まど名を継続利用する個人例外として`MOMENT_RUNTIME_ENABLED=YES`、`WINDOW_NAME_RUNTIME_ENABLED=YES`、旧共有を`LEGACY_SHARING_RUNTIME_ENABLED=NO`で運用します。Build 35はAppleへのvalidate／upload受付までで、Apple側の処理完了、内部group割当、実機受入は未確認です。一般公開や第三者の招待を認める変更ではありません。日次の公開境界監視とOFF候補のlocal検証は[本人2台用・写真／まど名共有staging運用](PERSONAL_STAGING_OPERATIONS.md)を正本とします。repository内の外部実停止経路は廃止済みで、未整備の実停止は継続利用と一般配布のblockerです。以下の通常手順のOFF既定と、ON候補を直接deployしない原則は変更しません。
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

Rate Limiting bindingの`namespace_id`は、Cloudflare account内で一意な正の整数を文字列として指定します。3 binding間でも、他のWorkerとも共有しない3値を決めます。namespace resourceを別途作成する操作はありません。

## 3. untracked configの生成

D1作成結果のUUIDと、確認済みのrate-limit namespace IDを現在のprocessへ読み込みます。`Read-Host`を使うことで値をPowerShell historyへ残しません。

```powershell
$env:NEKO_STAGING_D1_DATABASE_ID = Read-Host "staging D1 database ID"
$env:NEKO_STAGING_CREATE_RATE_LIMIT_NAMESPACE_ID = Read-Host "未使用のcreate rate namespace ID"
$env:NEKO_STAGING_INVITE_RATE_LIMIT_NAMESPACE_ID = Read-Host "未使用のinvite rate namespace ID"
$env:NEKO_STAGING_MEMBER_RATE_LIMIT_NAMESPACE_ID = Read-Host "未使用のmember rate namespace ID"
npm run staging:config:render
npm run staging:config:check
git check-ignore -v wrangler.staging.jsonc
```

Rendererは既存の`wrangler.staging.jsonc`を上書きしません。resourceを取り違えた場合はdeployせず、値を確認してから生成ファイルだけを削除し、再生成します。preflightは次を確認します。

- Worker、D1、通常R2、通報R2がstaging固有名である
- `workers_dev=true`かつpreview URLとcustom routeが無効である
- `ENVIRONMENT=staging`、`MOMENT_RUNTIME_ENABLED=NO`、`WINDOW_NAME_RUNTIME_ENABLED=NO`、`LEGACY_SHARING_RUNTIME_ENABLED=NO`である
- Workers Paid専用のcustom `limits`が存在しない
- rate limit 3本が固有namespaceで、5/min・10/min・120/minである
- cleanup／通知配送を含むCron 3本がある
- account固有のIDや未置換placeholderをtracked templateへ持ち込まない

## 4. migrationの事前確認と適用

D1 migrationはbinding名ではなくstaging database名を明記します。最初に`d1 list --json`の同名database IDと生成configのIDがexact一致することを確認します。新規で空のstaging D1では、未適用一覧がrepositoryの`0001_pairing.sql`から`0015_moderation_operator_routes.sql`までの15件と昇順でexact一致しなければ停止します。既存D1では、適用済みledgerが同じ15件の連続したprefix、未適用一覧が残りのsuffixであることを照合し、欠番、順序違い、未知fileがあれば停止します。`0012`は既存のcommitted reportを未着手caseとして安全にbackfillし、以後のcommitから48時間の初回確認期限とappend-only review eventを作る。`0015`は予約をreview開始と扱わず、DB時刻で作った証拠intentを2分以内にledgerへ確定した同じtransaction内でだけ`review_started`を追加する。1人または1caseに有効な未確定intentは1件だけで、期限後は新しい操作で安全に再開できる。結果確定とcontent削除はcanonical evidenceとdomain outboxが未完成のため拒否する。過去のcleanupやlegacy ledgerからreview済みとは推測しません。`0015`もHTTP route、WebAuthn verifier、R2削除、runtime ONを追加しません。生成済みconfigの実在D1 UUIDを使い、Wranglerにresourceを自動生成させません。

```powershell
npx --no-install wrangler d1 migrations list neko-window-sharing-staging --remote --config wrangler.staging.jsonc --experimental-provision=false --experimental-auto-create=false
npx --no-install wrangler d1 migrations apply neko-window-sharing-staging --remote --config wrangler.staging.jsonc --experimental-provision=false --experimental-auto-create=false
npx --no-install wrangler d1 migrations list neko-window-sharing-staging --remote --config wrangler.staging.jsonc --experimental-provision=false --experimental-auto-create=false
```

Apply前の確認promptでdatabase名またはmigration一覧が違う場合は承認しません。trigger migrationはLF改行と括弧付き`CASE`をCIで固定し、Wrangler/D1のremote parser回帰を防ぎます。失敗時はD1が空のままかを確認し、場当たり的なSQLやmigration ledgerの手動挿入で進めません。

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
- 3本のRate Limit binding
- `MOMENT_RUNTIME_ENABLED`、`WINDOW_NAME_RUNTIME_ENABLED`、`LEGACY_SHARING_RUNTIME_ENABLED`がすべて`NO`

現在のrepositoryには、対象Cloudflare account／Worker／active versionを原子的に照合してから切り替える外部deploy経路がありません。この手順ではdry-runより先へ進みません。通常の`wrangler deploy`やDashboardの手動var編集で代用すると、別account・別Worker・別versionを操作しても成功に見えるため禁止します。実配備は、review済みversionの事前作成、対象の固定、条件付きactive-version切替、直後の同一origin検証、rollback訓練が実装された後の別手順とします。

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

section 3と同じ4つの環境変数を設定したPowerShell processで、OFFとONを別々に生成します。既存fileを上書きしないため、再生成が必要なら対象がこのdirectory内のignored configであることを確認してから手動で削除します。

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

workers.devは公開originです。この段階でも招待・ペアリングAPIはインターネットから到達し、rate limitで保護されます。通常moment／暗号化まど名／旧共有のflag OFFだけでは、ペアリングと安全APIまで停止しません。現在のvalidatorは誤配備防止のため`workers_dev=true`のstaging候補だけを受け付け、`workers_dev=false`へ通常deployする全停止手順を実装済みとは扱いません。対象account／Workerとactive versionを原子的に束縛したreview済み全停止・再開手順と訓練が完成するまでは一般配布のrelease blockerです。緊急時にlocal dry-runや別originの応答を停止証拠にせず、別途承認されたCloudflare incident responseへescalateします。

## 公式資料

- [Wrangler configuration](https://developers.cloudflare.com/workers/wrangler/configuration/)
- [D1 migrations](https://developers.cloudflare.com/d1/reference/migrations/)
- [R2 bucket creation](https://developers.cloudflare.com/r2/buckets/create-buckets/)
- [R2 public access](https://developers.cloudflare.com/r2/buckets/public-buckets/)
- [Workers Rate Limiting binding](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/)
- [Workers limits](https://developers.cloudflare.com/workers/platform/limits/)
- [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/)
- [R2 pricing](https://developers.cloudflare.com/r2/pricing/)
