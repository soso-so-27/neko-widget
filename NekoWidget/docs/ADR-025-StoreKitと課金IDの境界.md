# ADR-025：StoreKitと課金IDの境界

作成：2026-08-31  
状態：クライアントとServer記録基盤を採用。全runtime OFF。販売・sponsorship・課金UIは未実装

関連：[ADR-024](ADR-024-無料体験とPlusと物販.md)、[ADR-018](ADR-018-名前付きの非公開なまど.md)、[共有設計](共有設計.md)

## 背景

ねこのまど Plusは、購入者が複数の非公開なまどを支援し、招待相手は無料で参加できる構想である。一方、現在のまどの参加者ID、端末ID、暗号鍵のKeychainアカウントは、まどごと・端末ごとの安全境界であり、購入者を表すIDではない。これらを課金へ流用すると、機種変更、複数まど、共有解除、再インストール時に権利と暗号境界が混ざる。

StoreKitの購入権復元も、写真原本、届いた写真、まど、E2E暗号鍵の復元を意味しない。利用者へ同じ「復元」として見せない設計が必要である。

## 決定1：課金IDを共有IDから分離する

- 課金には独立した仮名UUID `BillingAccountID` を用いる。
- 購入時はこのUUIDをStoreKit 2の `appAccountToken` として渡す。
- `PairingCredential`、participant ID、window owner、端末ID、Apple Accountのメールアドレスを課金IDにしない。
- BillingAccountIDの初回発行は、共有IDと分離したServer bootstrapが所有する。現在のアプリはまだ接続・永続化しない。復旧は未実装である。
- ServerはAppleの取引系譜とBillingAccountIDを検証し、購入者とPlus対象まどの`sponsorship`を別レコードで結ぶ。

## 決定2：StoreKitの確認だけでServer権限を確定しない

端末はStoreKit 2で次を行う。

- 月額・年額の商品を `Product.products(for:)` で取得する
- 起動時に `Transaction.currentEntitlements` を走査する
- 起動中は `Transaction.updates` を1本だけ監視する
- verified、想定商品ID、自動更新購読、本人購入、未取消、未失効だけを候補にする
- 購入にはBillingAccountIDを必須とする
- 復元の `AppStore.sync()` は、将来の明示的な「購入を復元」操作からだけ呼ぶ
- アプリが前面へ戻るたびにcurrent entitlementを再照合する

verified transactionはServerの冪等な記録が成功した後にだけ `finish()` する。通信失敗時はfinishせず、StoreKitから再配信できる状態を保つ。transaction ID単位の重複記録をServerが安全に受理できることを販売開始条件とする。

端末の状態は単純な有料booleanへ保存しない。少なくとも無効、確認中、非加入、StoreKit確認済み、確認不能を区別する。確認不能になっても既存の写真、まど、思い出、作品を削除または不可視化しない。

## 決定3：現在は明示的に無効にする

クライアント基盤はApp targetにだけ置き、WidgetとShare ExtensionへStoreKitを含めない。

ソース管理上の初期値は次のとおりとする。

```text
PLUS_STOREFRONT_ENABLED = NO
PLUS_MONTHLY_PRODUCT_ID =
PLUS_ANNUAL_PRODUCT_ID =
```

Server側も、Wranglerの上限スイッチとD1の下限スイッチを独立して持つ。

```text
BILLING_ACCOUNT_BOOTSTRAP_RUNTIME_ENABLED = NO
BILLING_TRANSACTION_INGESTION_RUNTIME_ENABLED = NO
billing_runtime_gate.account_bootstrap_enabled = 0
billing_runtime_gate.transaction_ingestion_enabled = 0
```

どちらか片方でもOFF、設定不足、検証サービス不通の場合はfail closedとする。この基盤を追加しただけでは購入、価格表示、権利付与、既存まどの制限を開始しない。

フラグが有効でない、商品IDが空・不正・重複している、またはServer recorderがない場合はfail closedとする。通常画面には価格、購入、復元、Plusバッジ、機能制限を出さない。現行の3まど上限、無料機能、既存データの扱いも変更しない。

## 決定4：Appleのファミリー共有を当面使わない

StoreKitのFamily Sharing購入は、ねこのまど内の「招待相手は無料」と異なる概念である。初期版では本人購入 (`ownershipType == purchased`) だけを採用し、family-shared transactionを権利にしない。招待相手への利用権はServerのsponsorshipで表す。App Store Connectの商品でもFamily Sharingを有効にせず、販売前検査で確認する。

`appAccountToken`のない取引は購入者へ安全に結びつけられないため、現在の基盤は権利を付与せずfinishもしない。初期販売はアプリ内のBillingAccountID付き購入だけに限定し、オファーコード等の外部購入導線は有効にしない。将来それらを使う場合は、Serverでの明示的なclaim・再関連付けを先に実装する。

## 決定5：Apple JWS検証をCloudflare Workerから分離する

- Cloudflare Worker/D1は、BillingAccountID、端末の課金用Ed25519公開鍵、取引系譜、正規化済みイベントだけを保持する。
- 生の`Transaction.jwsRepresentation`、端末署名、network address、共有HMAC secretはD1へ保存しない。
- Appleの公式Node libraryを使う実JWS検証は、Node.js 22の独立した`BillingVerificationService`で行う。Cloudflare Worker互換を仮定しない。
- Workerと検証サービス間は、固定origin、時刻、nonce、body hashを含むHMAC署名requestと、request nonce・status・body hashを含むHMAC署名responseで相互境界を固定する。
- 検証サービスはApple root chain、オンライン失効確認、bundle ID、environment、App Apple ID、subscription group、商品allowlist、`appAccountToken`、transaction type、所有種別、日付を検証する。
- 初期商品ではFamily Sharingを無効にする。`FAMILY_SHARED`は`appAccountToken`でBillingAccountIDへ安全に結べないため検証サービスで拒否し、Worker側でも防御的にPlus候補にしない。本人購入の返金済み・upgrade済みイベントは監査用に記録するが、Plus候補にしない。
- D1は同じ正規化イベントを冪等に受け入れ、取引系譜を別BillingAccountIDへ付け替えない。現段階のresponseは`candidate`であり、まどの権利を直接付与しない。

## 復元という言葉の境界

| 操作 | 復元するもの | 復元しないもの |
|---|---|---|
| 購入を復元 | App StoreのPlus購入権 | 写真、まど、暗号鍵 |
| 機種変更・引き継ぎ | 実装・検証済みと明示した作品や整理状態 | 明示していない写真原本やE2E鍵 |
| まどへ再接続 | 相手との新しい端末接続 | 過去端末の秘密鍵 |

販売画面では対象を省略して単に「復元」と書かない。

## 販売前に残る必須作業

1. App Store Connectで月額・年額を同じsubscription group・同じlevel、Family Sharing無効で作成する
2. Clientを課金bootstrapへ接続し、BillingAccountIDと課金用秘密鍵をKeychainへ保存する
3. BillingAccountIDの安全な復旧と端末鍵rotationを実装する
4. App Store Server Notifications V2、Subscription Status API、再照合jobを接続する
5. 購入者からまどへのsponsorship、解約、返金、請求猶予、失効、オフラインの状態遷移を実装する
6. 既存β利用者のまどを失わない移行を実装する
7. 検証サービスを隔離環境へdeployし、Apple root、secret、監視、rotation、共有nonce store、ingress rate limit、緊急OFFを運用検証する
8. Xcode StoreKit、Sandbox、TestFlightの順で購入・保留・取消・復元・更新・失効・返金を検証する
9. 価値が実装済みになった後にだけ、購入・復元・購読管理UIを接続する

## 参考

- [Apple: Transaction](https://developer.apple.com/documentation/storekit/transaction)
- [Apple: currentEntitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements)
- [Apple: AppStore.sync](https://developer.apple.com/documentation/storekit/appstore/sync())
- [Apple: 自動更新サブスクリプションの設定](https://developer.apple.com/help/app-store-connect/manage-subscriptions/offer-auto-renewable-subscriptions/)
- [Apple: App Store Server Library for Node](https://github.com/apple/app-store-server-library-node)
- [Apple: App Store Server Notifications](https://developer.apple.com/documentation/appstoreservernotifications)
