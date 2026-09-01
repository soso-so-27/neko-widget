# Active Worker Rate Limit Attestation

この手順は、stagingまたはproductionの固定Workerについて、現在100% activeな1 versionにあるRate Limiting bindingをCloudflare REST APIから読み取り、review済みmanifestとexact照合するread-only gateです。deploy、version切替、D1更新、namespace作成、secret変更は行いません。

## 証拠の境界

- `GET /accounts/{account}/workers/scripts/{script}/deployments`の`result.deployments[0]`だけをactive deploymentとして扱います。
- active deploymentは`strategy=percentage`、version 1件、`percentage=100`、manifestの`expectedVersionId`との一致を必須にします。
- version detailの`resources.bindings`から`type=ratelimit`だけをmemory内でsanitizeし、binding名、namespace ID、limit、period、`mitigation_timeout`の有無と値、binding集合、namespace重複をexact照合します。
- `BILLING_RATE_LIMITER`と`BILLING_APPLE_NOTIFICATION_RATE_LIMITER`は両方を必須とし、namespace共有を拒否します。
- version detail取得後にdeploymentsを再取得し、deployment ID、strategy、version ID、percentageのdriftを拒否します。
- `/health`の`READY`はbinding objectの存在だけなので証拠には使いません。
- これは**Worker-scoped**な証拠です。同じactive Worker内のnamespace重複は拒否しますが、account内の別Workerが同じnamespaceを使っていないことまでは証明しません。account-wide inventoryはこのtoolの対象外です。

Cloudflare公式schemaは[Deployments API](https://developers.cloudflare.com/api/resources/workers/subresources/scripts/subresources/deployments/)と[Versions API](https://developers.cloudflare.com/api/resources/workers/subresources/scripts/subresources/versions/)を正本にします。

## Review manifest

service rootに`active-worker-ratelimit-attestation-manifest.json`を作成します。この名前は`.gitignore`に固定され、追跡対象へ追加しません。stagingとproductionでmanifestを共有せず、固定account、script、active version、全Rate Limit bindingをそれぞれreviewします。

```json
{
  "schemaVersion": 1,
  "accountId": "32文字のaccount ID",
  "scriptName": "review済みWorker名",
  "expectedVersionId": "review済みactive version UUID",
  "rateLimits": [
    {
      "name": "CREATE_RATE_LIMITER",
      "namespaceId": "review済みnamespace ID",
      "limit": 5,
      "period": 60,
      "mitigationTimeout": null
    },
    {
      "name": "INVITE_RATE_LIMITER",
      "namespaceId": "review済みnamespace ID",
      "limit": 10,
      "period": 60,
      "mitigationTimeout": null
    },
    {
      "name": "MEMBER_RATE_LIMITER",
      "namespaceId": "review済みnamespace ID",
      "limit": 120,
      "period": 60,
      "mitigationTimeout": null
    },
    {
      "name": "BILLING_RATE_LIMITER",
      "namespaceId": "review済みnamespace ID",
      "limit": 30,
      "period": 60,
      "mitigationTimeout": null
    },
    {
      "name": "BILLING_APPLE_NOTIFICATION_RATE_LIMITER",
      "namespaceId": "review済みproductionまたはstaging専用namespace ID",
      "limit": 120,
      "period": 60,
      "mitigationTimeout": null
    }
  ]
}
```

上のApple通知`120`はJSONの型を示す例であり、推奨値ではありません。実環境では必ず実測してreviewした整数へ置き換えます。

`mitigation_timeout`がAPI responseに存在しない場合は`null`、存在する場合は数値をmanifestへ明示します。未指定と`0`を同一視しません。productionではstagingのApple通知`30/min`をコピーせず、Apple TEST通知と合成burst、Verifier max-inflightからreviewした値を使います。

## 実行

API tokenはaccountを限定したWorkers Scripts Readだけを与え、process environment以外へ渡しません。コマンド引数、manifest、ログへ書きません。値はshell historyへ直接書かず、対話入力します。

```powershell
$env:CLOUDFLARE_API_TOKEN = Read-Host "Workers Scripts Read token"
npm --silent run active-worker:ratelimit-attestation
Remove-Item Env:CLOUDFLARE_API_TOKEN
```

stdoutは`true`または`false`の1行だけです。raw API JSON、account ID、script名、deployment/version ID、namespace ID、tokenは出力しません。`false`またはexit code 1はfail closedとして扱い、GateをONにしません。

次をすべて失敗として扱います。

- tokenの欠落、空白、改行、未知のCLI引数
- timeout、redirect、HTTP non-2xx、`success!=true`、空でない`errors`
- oversized response、invalid UTF-8／JSON、未知のRate Limit binding shape
- split deployment、100%未満、expected version不一致、取得中のdeployment drift
- Rate Limit bindingの欠落／追加、name、namespace、limit、period、mitigation timeoutの不一致、namespace重複

ローカルcontract testはnetworkへ接続しません。

```powershell
npm run check:active-worker-ratelimit-attestation
```

このattestationが`true`でも、Tunnel／Access、Verifier、Redis、Apple Sandbox／production商品の確認や通知再取得手順を代替しません。
