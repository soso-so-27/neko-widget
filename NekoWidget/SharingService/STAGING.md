# Cloudflare隔離staging手順

この手順は「今の一枚」のCloudflare実環境検証を、productionと共有しないWorker、D1、R2、rate-limit namespaceで始めるためのものです。この段階では通常moment runtimeと旧日次共有runtimeを有効にしません。`wrangler.staging.template.jsonc`とpreflightは`MOMENT_RUNTIME_ENABLED = NO`、`LEGACY_SHARING_RUNTIME_ENABLED = NO`以外を拒否します。

この手順が作成する外部resourceはstaging専用です。

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
- `ENVIRONMENT=staging`、`MOMENT_RUNTIME_ENABLED=NO`、`LEGACY_SHARING_RUNTIME_ENABLED=NO`である
- Workers Paid専用のcustom `limits`が存在しない
- rate limit 3本が固有namespaceで、5/min・10/min・120/minである
- cleanup Cron 2本がある
- account固有のIDや未置換placeholderをtracked templateへ持ち込まない

## 4. migrationの事前確認と適用

D1 migrationはbinding名ではなくstaging database名を明記します。最初に`d1 list --json`の同名database IDと生成configのIDがexact一致することを確認します。未適用一覧は`0001_pairing.sql`、`0002_daily_sharing.sql`、`0003_append_only_moments.sql`だけでなければ停止します。生成済みconfigの実在D1 UUIDを使い、Wranglerにresourceを自動生成させません。

```powershell
npx --no-install wrangler d1 migrations list neko-window-sharing-staging --remote --config wrangler.staging.jsonc --experimental-provision=false --experimental-auto-create=false
npx --no-install wrangler d1 migrations apply neko-window-sharing-staging --remote --config wrangler.staging.jsonc --experimental-provision=false --experimental-auto-create=false
npx --no-install wrangler d1 migrations list neko-window-sharing-staging --remote --config wrangler.staging.jsonc --experimental-provision=false --experimental-auto-create=false
```

Apply前の確認promptでdatabase名またはmigration一覧が違う場合は承認しません。trigger migrationはLF改行と括弧付き`CASE`をCIで固定し、Wrangler/D1のremote parser回帰を防ぎます。失敗時はD1が空のままかを確認し、場当たり的なSQLやmigration ledgerの手動挿入で進めません。

## 5. bundleとdeployの二段階確認

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
- `MOMENT_RUNTIME_ENABLED`と`LEGACY_SHARING_RUNTIME_ENABLED`がどちらも`NO`

実deploy直前にもう一度preflightを通し、その直後にだけdeployします。`--keep-vars=false`でdashboard上の古いplaintext varsを正本にせず、tracked policyを反映します。Worker secretを削除する操作ではありません。

```powershell
npm run staging:config:check
$stagingCommit = (git rev-parse --short=12 HEAD).Trim()
npx --no-install wrangler deploy --strict --config wrangler.staging.jsonc --autoconfig=false --keep-vars=false --message "pairing-only staging; moment+legacy OFF; $stagingCommit" --experimental-provision=false --experimental-auto-create=false
```

deployが返した`https://neko-window-sharing-staging.<account-subdomain>.workers.dev`をstaging API originとして控えます。独自domainやPagesはこの段階では不要です。

## 6. runtime OFFのsmoke確認

URLは現在のprocessだけへ置き、末尾へpath、query、fragmentを加えません。

```powershell
$env:NEKO_STAGING_API_ORIGIN = Read-Host "staging Worker HTTPS origin"
curl.exe -i "$env:NEKO_STAGING_API_ORIGIN/health"
curl.exe -i "$env:NEKO_STAGING_API_ORIGIN/v2/moments/changes"
curl.exe -i "$env:NEKO_STAGING_API_ORIGIN/v1/sharing/sources"
```

期待値は次のとおりです。

- `/health`: `200`、`{"status":"ok","protocolVersion":1}`
- `/v2/moments/changes`: `503`、error code `moment_runtime_disabled`
- `/v1/sharing/sources`: `503`、error code `legacy_sharing_runtime_disabled`

Cloudflare dashboardで2本のCronが登録済みであり、両R2 bucketが引き続き非公開であることも確認します。`/health`はD1/R2/Cronの健全性を証明しないため、これだけでruntimeをONにしません。

## 停止条件

この手順では`MOMENT_RUNTIME_ENABLED`と`LEGACY_SHARING_RUNTIME_ENABLED`を`YES`へ変更しません。通常momentを有効にするには、moderation鍵と復号手段、公開support/community standards/privacy、対応runbook、staging client release gate、二端末試験票を別の変更で揃えます。旧日次共有runtimeはstagingでも有効化しません。

生成config、migration対象、Worker名、bucket公開状態の一つでも不明な場合はdeployしません。D1/R2/Workerを削除する操作はこの手順に含めません。

workers.devは公開originです。この段階でも招待・ペアリングAPIはインターネットから到達し、rate limitで保護されます。緊急全停止時はreview済みconfigで`workers_dev=false`、`preview_urls=false`、custom routeなしへ変更して再deployします。通常moment/旧共有のフラグOFFだけでは、ペアリングと安全APIまで停止しません。次のdeployで再び公開しないよう、この停止変更を先にcommitします。

## 公式資料

- [Wrangler configuration](https://developers.cloudflare.com/workers/wrangler/configuration/)
- [D1 migrations](https://developers.cloudflare.com/d1/reference/migrations/)
- [R2 bucket creation](https://developers.cloudflare.com/r2/buckets/create-buckets/)
- [R2 public access](https://developers.cloudflare.com/r2/buckets/public-buckets/)
- [Workers Rate Limiting binding](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/)
- [Workers limits](https://developers.cloudflare.com/workers/platform/limits/)
- [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/)
- [R2 pricing](https://developers.cloudflare.com/r2/pricing/)
