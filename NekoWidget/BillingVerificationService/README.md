# BillingVerificationService

ねこのまど Plus向けに、StoreKit 2の`Transaction.jwsRepresentation`、App Store Server Notifications V2、Subscription Status API内のJWSをAppleの公式Node libraryで検証する、隔離したNode.js 22 serviceです。Cloudflare Worker互換を仮定せず、証明書chain・オンライン失効確認を実Node runtimeで行います。

現時点ではsourceとtestだけです。deployされておらず、runtimeも既定OFFです。App Store Connectの商品、購入UI、Plus権限、sponsorshipは有効になりません。

## 境界

- 入力はWorkerからの署名済みinternal requestだけです。
- HMAC transcriptにはprotocol version、時刻、nonce、request body SHA-256を含めます。
- responseもrequest nonce、HTTP status、response body SHA-256へHMAC署名します。
- Apple JWSは検証中だけmemoryへ置き、log・D1・responseへ残しません。
- 出力はallowlistとidentityを検証した正規化済みtransaction fieldsだけです。
- 通知は再照合を起動する事実として扱い、通知内statusから権利を直接変更しません。現在状態の正本はSubscription Status APIの署名済みtransaction／renewalです。
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
| `BILLING_NOTIFICATION_VERIFIER_RUNTIME_ENABLED` | 通知検証endpointを正確に`YES`で有効化。既定`NO` |
| `BILLING_SUBSCRIPTION_STATUS_RUNTIME_ENABLED` | Subscription Status照合endpointを正確に`YES`で有効化。既定`NO` |
| `BILLING_ACCOUNT_RECOVERY_VERIFIER_RUNTIME_ENABLED` | 端末移行用のAppTransaction/Transaction二重検証endpointを正確に`YES`で有効化。既定`NO` |
| `APP_STORE_SERVER_API_PRIVATE_KEY` | Status照合ON時だけ必須の専用`.p8`秘密鍵 |
| `APP_STORE_SERVER_API_KEY_ID` | Status照合ON時だけ必須の10文字Key ID |
| `APP_STORE_SERVER_API_ISSUER_ID` | Status照合ON時だけ必須のIssuer ID |
| `PORT` | 1〜65535。省略時8080 |

秘密値、Apple root、実商品IDをrepositoryへcommitしません。root certificateはAppleのPKI公式配布元から取得し、DER bytesとrotation手順をdeploy前に別途reviewします。JWS transaction／通知検証だけならApp Store Connect APIの`.p8` keyは使いません。Status照合の`.p8`は専用switchがOFFなら存在自体を拒否し、用途を分離します。

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
4. Notifications V2／Subscription Statusの隔離staging URL、Notification History復旧、再送・順序逆転を運用検証する
5. Sandboxの購入・更新・失効・返金fixtureを検証する
6. 両runtime gateを段階的に開く手順と緊急OFFを訓練する

internal requestの同一nonce再送は検証結果やD1を直接変更しませんが、Apple証明書確認の負荷を増幅し得ます。runtimeをONにする前に、隔離ingressでのrate limitと、全instanceで共有する5分TTL nonce storeを実装・負荷試験します。単一processのmemory cacheだけで完了扱いにはしません。

現在のserverは`127.0.0.1`へbindし、同一hostのprivate gateway経由だけを前提にします。containerで`0.0.0.0`が必要な構成へ変更する場合も、Worker以外を拒否するprivate ingress、64 KiB以下のrequest、header受信5秒・body受信10秒・upstream応答29秒未満のtimeout、負荷試験から決めた同時実行上限と超過時の拒否を必須にします。これらが構成ファイルと自動確認で証明できるまで公開しません。

Apple公式実装と仕様：[App Store Server Library for Node](https://github.com/apple/app-store-server-library-node)、[App Store Server API](https://developer.apple.com/documentation/appstoreserverapi)。
