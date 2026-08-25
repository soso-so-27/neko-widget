# ADR-022：通常APNs通知と永続Outbox

日付: 2026-08-25  
状態: 実装・外部release gate待ち  
関連: [ADR-015](ADR-015-共有の配送設計.md)、[ADR-020](ADR-020-思い出とハートの操作分離.md)

## 決定

新しい一枚のcommitと、受信写真へのハートの受付を、通常APNs通知の契機にする。iOS 18.1.1以上を対象に、一般的な`alert`と`content-available`を同じ通知へ入れる。Host appが背景実行を得た場合だけ、既存の署名付き同期、検証済みcache再構築、`WidgetCenter.reloadTimelines`を行う。WidgetKit専用pushは本releaseへ含めない。

APNsやiOSは配送・背景実行・Widget再読込を保証しない。製品表示は「サーバー受付済み」「相手端末へ到着」を区別し、APNsのHTTP 200を相手端末への到着として扱わない。iOS 18のWidget更新はbest effortであり、強制終了中は次のapp起動まで更新されない場合がある。

## Privacy境界

- payloadは「新しい一枚が届きました」「届けた写真にハートが届きました」という一般文だけにする。
- 写真、まど名、相手名、撮影日時、moment/reaction ID、URL、暗号鍵を入れない。
- APNs tokenはWorkerのSecret keyringでAES-GCM暗号化し、D1には暗号文、nonce、key versionと重複確認用SHA-256だけを置く。平文tokenをlog、API response、iPhoneの永続領域へ残さない。
- Serverは署名済みrequestから現在のparticipant、device、bundle topicを決定し、client指定のIDやtopicを受け付けない。
- subscriptionは最大35日のleaseとし、起動時に更新する。通知OFF、失効device、機種変更、unlink、block、APNsの無効token応答、期限到来で削除へ収束させる。

## 配送整合性

`notification_events`と`notification_deliveries`をD1の永続Outboxにする。moment commitまたは新規reactionと、宛先別delivery作成を同じD1 batchへ入れる。HTTP応答後の`ctx.waitUntil`で即時配送を試み、1分cronで未完了分を回収する。D1 leaseの比較更新により同時drainを制御する。

- 200: APNs受付済み
- 410、`Unregistered`、`BadDeviceToken`、`DeviceTokenNotForTopic`: 同じtoken fingerprintの場合だけsubscriptionを削除
- network、429、5xx: jitter付き指数backoff
- provider key、topic、payload等の構成エラー: tokenを削除せず運用エラーとして保留

クラッシュ境界はat-least-onceである。同じeventに安定したcollapse IDを使い、重複表示を抑える。event／deliveryの作成が失敗した場合は写真commit／reaction自体も失敗させ、通知だけを暗黙に欠落させない。

## iOS境界

- `aps-environment`はHost appだけに付与する。Debugはdevelopment、Release/TestFlightはproductionとする。
- WidgetとShare ExtensionへAPNs entitlementを付けない。
- 通知許可済みかつ、ペアリング・写真共有同意が有効な選択中のまどだけへtokenを署名付き登録する。同じ物理tokenを別のまどからPUTした場合は以前のbindingと未完了deliveryを置き換え、非activeまどの通知でactiveまどを誤同期しない。
- 通知拒否時は署名付きDELETEを試み、失敗時もpairingを破壊しない。Server側のcascadeとlease expiryを最終収束経路にする。
- remote callbackでは既存refreshを使い、APNs alertと同じ内容のlocal notificationを重複生成しない。

## 外部release gate

ソース実装だけでは通知を有効にしない。次がすべて必要である。

1. Apple DeveloperのHost App IDでPush Notificationsを有効化する。
2. production `aps-environment`を含むApp Store配布profileを再発行し、CI secretを差し替える。Widget／Share profileは変更しない。
3. APNs Auth Keyを作成し、provider credentialをCloudflare Secretへ登録する。
4. token暗号化keyringをCloudflare Secretへ登録する。値をrepositoryへ置かない。
5. D1 migration適用後にWorkerをdeployする。
6. developmentとproductionで実APNsのHTTP 200、invalid token、retryを確認する。TestFlightはproduction APNsを使う。
7. 署名済みarchiveでHost appだけが`aps-environment=production`を持つことをCIで確認する。

Cloudflare Workerの外向き通信が実APNsの要件を満たすことは実送信smokeで確定する。満たさない場合は、Outboxを維持したままAPNs transportだけを対応providerへ分離する。
