# Plus課金staging安全操作

この手順は、本人用stagingでPlus課金の上下2層Gateを段階的に確認するためのものです。
一般公開、TestFlightへの診断画面追加、実購入、production変更を許可する手順ではありません。

Apple通知履歴は通常の課金操作に含めません。read-only statusと緊急OFFは
[`BILLING_NOTIFICATION_HISTORY_STAGING_DRILL.md`](BILLING_NOTIFICATION_HISTORY_STAGING_DRILL.md)
の専用手順を使います。専用手順にもON操作はありません。

## 安全境界

- 追跡対象の`wrangler.staging.template.jsonc`は、課金8 upper Gateを常に`NO`で保持する。
- 生成される次の3ファイルはGit管理外で、IDやsecretをcommitしない。
  - `wrangler.billing-control-staging-off.jsonc`
  - `wrangler.billing-control-staging-on.jsonc`
  - `billing-staging-runtime-gate-manifest.json`
- OFF／ON configは、既存の写真、反応、まど名、APNs、通報受付のupper Gateを変更しない。
- ON configとの差分は通常の課金7 upper Gateの`NO`／`YES`だけであり、Apple通知履歴復旧の8番目は両方で`NO`のままにする。
- config生成、検査、`--plan`はdeploy、D1更新、購入、復旧を行わない。
- D1 controllerは固定Worker、固定D1、固定origin、期待generation、期待stateが一致した場合だけ1回のCASを行う。
- `/health`は課金8 Gateの実効値、billing generation、Apple通知専用limiterの`READY`／`MISSING`だけを返し、account、database、device、token、JWS、secret、namespace IDを返さない。`READY`が証明するのはactive Workerにbinding objectがあることだけで、namespace ID・limit・periodの実値ではない。release判定には、固定したactive deployment/versionのCloudflare control-plane snapshotを取得し、review済みconfigとexact照合する別の証拠を必須とする。
- Apple通知の公開endpointは、本文解析や隔離Verifier呼出しより先に専用の`BILLING_APPLE_NOTIFICATION_RATE_LIMITER`を通す。keyは送信元IPではなく固定route classとし、同一Cloudflare location内のApple通知をまとめる近似pre-filterとして使う。counterはper-locationかつeventually consistentであり、複数locationの合算を制限するglobal boundaryではない。Verifierのmax-inflightとfail-closedをhard boundaryとする。本人用stagingの30/minはVerifier保護用の暫定上限であり、正確な通知quotaやproduction容量とは扱わない。productionは固有namespaceと別のreview済み値を必須とし、Apple TEST通知と合成burstの実測から閾値を決める。Sandbox通知は失敗時に自動再送されないため、staging値をproductionへ流用しない。
- Workerから隔離Verifierへの入口はCloudflare TunnelとAccessの`Service Auth` policyで非公開化し、service tokenの2 headerとアプリ層HMACの両方を必須にする。どちらか一方だけで配備しない。

## 固定state

ON方向は次の順で1 Gateずつ開く。通常のOFF方向は逆順で1 Gateずつ閉じる。

1. `all-off`
2. `bootstrap-only`
3. `transaction-on`
4. `notification-on`
5. `reconciliation-on`
6. `entitlement-on`
7. `sponsorship-on`
8. `recovery-on`

任意のreview済みON stateから`all-off`へ戻す場合だけ、緊急停止として1回のCASを許可する。
ON方向の飛び越し、同じstateの再実行、未知の組み合わせは拒否する。

## 外部変更をしないローカル確認

最初に全migrationと合成データ訓練を通す。

```powershell
npm run billing-sponsorship:local-drill
npm run check:billing-control-staging-config
npm run check:billing-staging-runtime-gate
```

staging専用の既知IDを現在のprocessへ読み込み、ignored configを生成する。値はPowerShell historyへ直接書かず、`Read-Host`を使う。

```powershell
$env:NEKO_STAGING_D1_DATABASE_ID = Read-Host "staging D1 database ID"
$env:NEKO_STAGING_CREATE_RATE_LIMIT_NAMESPACE_ID = Read-Host "create rate-limit namespace ID"
$env:NEKO_STAGING_INVITE_RATE_LIMIT_NAMESPACE_ID = Read-Host "invite rate-limit namespace ID"
$env:NEKO_STAGING_MEMBER_RATE_LIMIT_NAMESPACE_ID = Read-Host "member rate-limit namespace ID"
$env:NEKO_STAGING_BILLING_RATE_LIMIT_NAMESPACE_ID = Read-Host "billing rate-limit namespace ID"
$env:NEKO_STAGING_BILLING_APPLE_NOTIFICATION_RATE_LIMIT_NAMESPACE_ID = Read-Host "Apple notification rate-limit namespace ID"
npm run billing-control-staging:config:render
npm run billing-control-staging:config:check
```

Rendererは既存ファイルを上書きしない。値を直す場合はdeployせず、対象の生成configだけを確認してから削除し、再生成する。

manifestは次のキーだけを持つ。実値は表示、共有、commitしない。

```json
{
  "schemaVersion": 1,
  "accountId": "32文字のstaging account ID",
  "databaseId": "staging D1 UUID",
  "workerName": "neko-window-sharing-staging",
  "origin": "https://neko-window-sharing-staging.nakanishisoya.workers.dev",
  "expectedGeneration": 0,
  "expectedState": "all-off",
  "desiredState": "bootstrap-only"
}
```

次の2コマンドは、固定configとmanifestを検証する。`plan`はネットワークへ接続しない。`status`は固定SELECTと同一originの`/health`照合だけを行い、D1を書き換えない。

```powershell
npm run billing-staging:runtime-gate:plan
npm run billing-staging:runtime-gate:status
```

## 実stagingを開く前の必須条件

次をすべて満たすまで、ON configのdeployやGate確認コマンドを実行しない。

1. Cloudflare認証先、Worker、D1、R2、rate-limit namespaceが本人用stagingと一致する。
2. remote D1を保護された保存先へexportし、migration ledgerが`0001`〜`0025`の連続prefixである。
3. 未適用の課金migrationだけを順番どおり適用し、課金8 lower Gateがすべて0である。
4. review済みWorkerを先にOFF configで配備し、既存の写真・APNs・通報境界が変わらない。
5. 隔離Billing Verifier、Cloudflare Tunnel、Accessの`Service Auth` policy、TLS Redis instance、secret rotation、Apple Sandbox商品、bundle／group／product IDを用意する。Verifierのloopback待受、timeout、同時処理上限、Redis atomic nonce adapterと、WorkerがAccess service token headerを付ける処理は実装済みだが、外部instance、Access application／token、secretは未作成である。Verifier hostのfirewallはTunnel以外のingressを拒否する。
6. ON config配備後もlower Gateが`all-off`であり、`/health`の課金8実効値がすべてOFFである。
7. Mac、development署名、DEBUG起動引数`--billing-internal-diagnostics`を使える。診断画面はTestFlightには含めない。

Worker側の`BILLING_VERIFIER_ACCESS_CLIENT_ID`、`BILLING_VERIFIER_ACCESS_CLIENT_SECRET`、`BILLING_VERIFIER_SHARED_SECRET`はWranglerのsecretとして投入し、追跡対象または生成済みconfigの`vars`へ書かない。staging／productionではAccess credentialsの片方だけ、欠落、空白、改行をすべて設定不備として503でfail closedにする。`ENVIRONMENT=local`、`http://127.0.0.1`、両Access値未設定の3条件が同時に成立する場合だけ、loopback開発のためAccessを省略できる。

現在のrepositoryにはVerifierのprivate ingress配備、Redis／secret投入、Sandbox商品の作成経路がまだない。したがって、Gate導線とVerifier側のfail-closed境界が完成していても、実課金の完全な7操作訓練を開始できる状態とは扱わない。

## 確認と緊急停止

通常の段階確認では、manifestの`expectedGeneration`、`expectedState`、`desiredState`をreviewしてから、desired stateをコマンドでもう一度明示する。

```powershell
node scripts/billing-staging-runtime-gate.mjs --confirm-bootstrap-only
```

成功後は新generationとstateをmanifestへ反映し、`status`でD1と同一originを照合してから次へ進む。

異常時は、新規購入や診断を止め、現在stateから`all-off`へのmanifestをreviewして次を1回だけ実行する。

```powershell
node scripts/billing-staging-runtime-gate.mjs --confirm-billing-all-off
```

同一originの8実効値がすべてOFFになったことを確認し、その後にOFF upper configへ戻す。schemaや監査データは場当たり的に削除しない。
