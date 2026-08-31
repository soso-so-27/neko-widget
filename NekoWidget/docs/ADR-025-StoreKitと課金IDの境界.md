# ADR-025：StoreKitと課金IDの境界

作成：2026-08-31  
状態：クライアントの安全な土台を採用。販売・Server entitlement・課金UIは未実装

関連：[ADR-024](ADR-024-無料体験とPlusと物販.md)、[ADR-018](ADR-018-名前付きの非公開なまど.md)、[共有設計](共有設計.md)

## 背景

ねこのまど Plusは、購入者が複数の非公開なまどを支援し、招待相手は無料で参加できる構想である。一方、現在のまどの参加者ID、端末ID、暗号鍵のKeychainアカウントは、まどごと・端末ごとの安全境界であり、購入者を表すIDではない。これらを課金へ流用すると、機種変更、複数まど、共有解除、再インストール時に権利と暗号境界が混ざる。

StoreKitの購入権復元も、写真原本、届いた写真、まど、E2E暗号鍵の復元を意味しない。利用者へ同じ「復元」として見せない設計が必要である。

## 決定1：課金IDを共有IDから分離する

- 課金には独立した仮名UUID `BillingAccountID` を用いる。
- 購入時はこのUUIDをStoreKit 2の `appAccountToken` として渡す。
- `PairingCredential`、participant ID、window owner、端末ID、Apple Accountのメールアドレスを課金IDにしない。
- BillingAccountIDの発行・復旧は、将来の課金bootstrapとServerが所有する。現在のアプリは生成・永続化しない。
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

フラグが有効でない、商品IDが空・不正・重複している、またはServer recorderがない場合はfail closedとする。通常画面には価格、購入、復元、Plusバッジ、機能制限を出さない。現行の3まど上限、無料機能、既存データの扱いも変更しない。

## 決定4：Appleのファミリー共有を当面使わない

StoreKitのFamily Sharing購入は、ねこのまど内の「招待相手は無料」と異なる概念である。初期版では本人購入 (`ownershipType == purchased`) だけを採用し、family-shared transactionを権利にしない。招待相手への利用権はServerのsponsorshipで表す。App Store Connectの商品でもFamily Sharingを有効にせず、販売前検査で確認する。

`appAccountToken`のない取引は購入者へ安全に結びつけられないため、現在の基盤は権利を付与せずfinishもしない。初期販売はアプリ内のBillingAccountID付き購入だけに限定し、オファーコード等の外部購入導線は有効にしない。将来それらを使う場合は、Serverでの明示的なclaim・再関連付けを先に実装する。

## 復元という言葉の境界

| 操作 | 復元するもの | 復元しないもの |
|---|---|---|
| 購入を復元 | App StoreのPlus購入権 | 写真、まど、暗号鍵 |
| 機種変更・引き継ぎ | 実装・検証済みと明示した作品や整理状態 | 明示していない写真原本やE2E鍵 |
| まどへ再接続 | 相手との新しい端末接続 | 過去端末の秘密鍵 |

販売画面では対象を省略して単に「復元」と書かない。

## 販売前に残る必須作業

1. App Store Connectで月額・年額を同じsubscription group・同じlevel、Family Sharing無効で作成する
2. BillingAccountIDを安全に発行・復旧するServer bootstrapを実装する
3. transaction JWSのServer検証と冪等記録を実装する
4. 購入者からまどへのsponsorship、解約、返金、請求猶予、失効、オフラインの状態遷移を実装する
5. 既存β利用者のまどを失わない移行を実装する
6. Xcode StoreKit、Sandbox、TestFlightの順で購入・保留・取消・復元・更新・失効・返金を検証する
7. 価値が実装済みになった後にだけ、購入・復元・購読管理UIを接続する

## 参考

- [Apple: Transaction](https://developer.apple.com/documentation/storekit/transaction)
- [Apple: currentEntitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements)
- [Apple: AppStore.sync](https://developer.apple.com/documentation/storekit/appstore/sync())
- [Apple: 自動更新サブスクリプションの設定](https://developer.apple.com/help/app-store-connect/manage-subscriptions/offer-auto-renewable-subscriptions/)
