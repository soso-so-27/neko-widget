# BillingVerificationService

ねこのまど Plus向けに、StoreKit 2の`Transaction.jwsRepresentation`をAppleの公式Node libraryで検証する、隔離したNode.js 22 serviceです。Cloudflare Worker互換を仮定せず、証明書chain・オンライン失効確認を実Node runtimeで行います。

現時点ではsourceとtestだけです。deployされておらず、runtimeも既定OFFです。App Store Connectの商品、購入UI、Plus権限、sponsorshipは有効になりません。

## 境界

- 入力はWorkerからの署名済みinternal requestだけです。
- HMAC transcriptにはprotocol version、時刻、nonce、request body SHA-256を含めます。
- responseもrequest nonce、HTTP status、response body SHA-256へHMAC署名します。
- Apple JWSは検証中だけmemoryへ置き、log・D1・responseへ残しません。
- 出力はallowlistとidentityを検証した正規化済みtransaction fieldsだけです。
- Family Sharingは初期商品で無効にします。`FAMILY_SHARED`取引には課金IDを安全に結ぶ`appAccountToken`がないため、このendpointでは明示拒否します。
- 本人購入の返金・upgrade事実は返します。Worker ledgerは記録しますが、Plus候補にしません。Worker側も防御的に`FAMILY_SHARED`を候補にしません。

## 必須環境変数

| 変数 | 内容 |
|---|---|
| `BILLING_VERIFIER_RUNTIME_ENABLED` | 正確に`YES`のときだけ起動 |
| `BILLING_VERIFIER_SHARED_SECRET` | Workerと共有する32-byte canonical base64url secret |
| `APPLE_ROOT_CERTIFICATES_BASE64_JSON` | Apple公式root DERをbase64化したJSON配列 |
| `BILLING_STORE_ENVIRONMENT` | `Sandbox`または`Production` |
| `BILLING_BUNDLE_ID` | App bundle ID |
| `BILLING_APP_APPLE_ID` | Productionで必須、Sandboxでは指定しない |
| `BILLING_SUBSCRIPTION_GROUP_ID` | 自動更新購読group ID |
| `BILLING_MONTHLY_PRODUCT_ID` | 月額商品ID |
| `BILLING_ANNUAL_PRODUCT_ID` | 年額商品ID |
| `PORT` | 1〜65535。省略時8080 |

秘密値、Apple root、実商品IDをrepositoryへcommitしません。root certificateはAppleのPKI公式配布元から取得し、DER bytesとrotation手順をdeploy前に別途reviewします。JWS transaction検証だけならApp Store Connect APIの`.p8` keyは使いません。Notifications／status照合を追加する段階で、用途を分離したcredentialを設計します。

## Local verification

```sh
npm ci --ignore-scripts
npm run check
```

`npm run check`はstrict typecheck、Apple payload正規化、fail-closed設定、Workerとの共通HMAC vector、internal HTTP認証、署名response、retryable error、production buildを確認します。実Apple JWSのSandbox確認は、商品と隔離stagingを作った後の販売前gateです。

## Production前に必要なもの

1. public internetへ直接公開しない隔離host、TLS、egress制御、secret manager、監視を決める
2. Apple公式rootの取得・検査・rotation runbookを作る
3. WorkerとserviceのHMAC secret rotationを実装・訓練する
4. App Store Server Notifications V2とSubscription Status再照合を実装する
5. Sandboxの購入・更新・失効・返金fixtureを検証する
6. 両runtime gateを段階的に開く手順と緊急OFFを訓練する

internal requestの同一nonce再送は検証結果やD1を直接変更しませんが、Apple証明書確認の負荷を増幅し得ます。runtimeをONにする前に、隔離ingressでのrate limitと、全instanceで共有する5分TTL nonce storeを実装・負荷試験します。単一processのmemory cacheだけで完了扱いにはしません。

`0.0.0.0`へのbindはcontainer内部用です。runtimeをONにする構成審査では、Worker以外を拒否するprivate ingress、64 KiB以下のrequest、header受信5秒・body受信10秒・upstream応答29秒未満のtimeout、負荷試験から決めた同時実行上限と超過時の拒否を必須にします。これらが構成ファイルと自動確認で証明できるまで公開しません。

Apple公式実装と仕様：[App Store Server Library for Node](https://github.com/apple/app-store-server-library-node)、[App Store Server API](https://developer.apple.com/documentation/appstoreserverapi)。
