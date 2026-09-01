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
| `BILLING_NONCE_REDIS_URL` | 共有nonce予約専用のTLS Redis URL（`rediss://`）。secret managerからだけ注入 |
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

internal requestの同一nonceは、全instanceで共有するRedisのatomic `SET NX`でApple検証前に予約します。時刻の±300秒許容全域を覆うため保持は601秒です。Redisが不通、応答不明、または同一nonceが予約済みなら署名付き503でfail closedし、Apple検証を呼びません。切断時は短い再接続を3回だけ行い、その間と失敗後のhealthは503です。単一processのmemory cacheへfallbackしません。

現在のserverと実行entrypointは`127.0.0.1`だけへbindし、同一hostのprivate gateway経由だけを前提にします。header受信5秒、body受信10秒、Apple応答期限25秒、idle socket 30秒、同時Apple処理4件の上限をcodeで固定し、超過時は署名付き503にします。Apple libraryの未完了通信を安全に中断できないため、25秒超過時は503を返した直後にinstanceを異常終了し、隔離hostのsupervisorが再起動します。通常requestは64 KiB、二重JWSを持つ復旧requestだけ128 KiBです。containerで`0.0.0.0`が必要な構成はこのentrypointを流用せず、Worker以外を拒否するprivate ingressと独立したreviewを必須にします。

Apple公式実装と仕様：[App Store Server Library for Node](https://github.com/apple/app-store-server-library-node)、[App Store Server API](https://developer.apple.com/documentation/appstoreserverapi)。
