# APNs通知のstaging／production運用

この文書は、写真とハートの汎用APNs通知を有効にするときのserver側停止条件です。通知は同期の正本ではありません。APNsが`200`を返しても端末表示・background実行・Widget更新は保証されず、アプリの署名済みcursor同期を正本にします。

## 保持する情報

- APNs device tokenは`APNS_TOKEN_KEYRING_JSON`のcurrent AES-256-GCM鍵でapplication-level暗号化してD1へ保存する。
- D1には暗号文、12-byte nonce、鍵version、重複／失効CAS用SHA-256 digestだけを置く。平文tokenをresponseやlogへ出さない。
- Subscriptionは現在の認証済み`moment_devices.id`へserver側で結び、最終更新から35日で削除する。アプリは起動ごとにPUTして更新する。
- Notification eventは24時間で削除する。最初のtoken登録で古いeventをbackfillしない。Moment ACK、revoke、expiry、block、device/participant/space失効では関連eventまたはsubscriptionを即時削除する。
- APNsの表示本文は一般文だけとし、`aps.alert`と`content-available=1`を使う。sound、badge、写真、まど名、人物名、撮影日時、reaction/device ID、URL、鍵を含めない。
- 旧`v2` subscriptionの`neko`は`{"v":1,"kind":"new_moment|heart"}`のexact 2-key envelopeを維持する。新しい加算型`v3` subscriptionには、旧clientがfail closedで拒否する`{"v":2,"kind":"new_moment|heart"}`と、別top-levelの`nekoTarget`にある`{"v":1,"spaceId":"<opaque>","momentId":"<opaque>"}`を送る。新clientだけが通知タップを正しいまど・写真へ結ぶ。
- `nekoTarget`の二つのIDは表示文、accessibility、診断log、analyticsへ出さず、端末内の認証済みまどと同期済み写真にexact一致した場合だけrouteへ使う。余分なkey、未知version、形式不正、一意に解決できないまどはfail closedとし、別のまどへfallbackしない。`nekoTarget`自体がない旧payloadだけは、従来どおり選択中のまどの`kind`に対応する区分を開く。
- 旧`PUT /v2/push-subscriptions/current`は選択中のまどだけを通知対象にし、同じtoken digestの別まど／device bindingと未完了deliveryを置き換える。新`PUT /v3/push-subscriptions/current`は認証済みのまどを加算登録し、最初の`v3`登録時に同じtoken digestの旧route bindingだけを削除した後、targeted routeの複数まどを共存させる。`v2`へ戻すと同じtokenの加算bindingを削除して選択中1まどへ安全に戻る。

## Signed API

旧client向け`PUT /v2/push-subscriptions/current`のexact JSON（同じ物理tokenのbindingを1件へ置換）:

```json
{"protocolVersion":2,"token":"<canonical base64url; decoded 16..256 bytes>","environment":"development|production"}
```

成功response:

```json
{"protocolVersion":2,"subscription":{"state":"active"}}
```

旧client向け`DELETE /v2/push-subscriptions/current`のexact JSON:

```json
{"protocolVersion":2}
```

新client向け`PUT /v3/push-subscriptions/current`のexact JSON（認証済みまどを加算）:

```json
{"protocolVersion":3,"token":"<canonical base64url; decoded 16..256 bytes>","environment":"development|production"}
```

成功response:

```json
{"protocolVersion":3,"subscription":{"state":"active"}}
```

新client向け`DELETE /v3/push-subscriptions/current`のexact JSON（署名したdevice bindingだけを解除）:

```json
{"protocolVersion":3}
```

DELETEの成功responseは、呼び出したrouteと同じprotocol versionを返す:

```json
{"protocolVersion":2,"subscription":{"state":"deleted"}}
```

または:

```json
{"protocolVersion":3,"subscription":{"state":"deleted"}}
```

全routeで通常member requestと同じEd25519署名、timestamp、nonceを必須にします。PUTは`APNS_RUNTIME_ENABLED=YES`でだけ成功し、OFF中も署名検証後にnonceを消費して`503 apns_runtime_disabled`へします。DELETEは緊急OFF中にも成功し、利用者がserver tokenを消せる状態を維持します。Client指定のdevice ID、participant ID、bundle ID、topic、route schemaは受け取らず、`v2`をlegacy route、`v3`をtargeted routeへserver側で固定します。

## Cloudflare Secrets

次の二つはWrangler plaintext vars、repository、CI artifactへ入れず、対象WorkerのSecretとして登録します。

`APNS_PROVIDER_CREDENTIAL_JSON`:

```json
{
  "keyId":"APPLEKEY1A",
  "teamId":"APPLETEAM1",
  "bundleId":"<app bundle identifier>",
  "environment":"production",
  "privateKey":"-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----"
}
```

`APNS_TOKEN_KEYRING_JSON`:

```json
{"current":"2026-01","keys":{"2026-01":"<base64url 32 random bytes>"}}
```

鍵rotationは新しい鍵を`current`へし、旧鍵を`keys`に残したままdeployします。35日のsubscription TTLを越えて全端末が更新または失効したことを件数だけ確認してから旧鍵を外します。旧鍵を先に外すと未更新tokenを復号できず、配送は`configuration_error:TokenDecryptFailed`としてexpiryまで保留されます。

## Staging gate

1. Apple Developerでアプリ本体App IDのPush Notificationsを有効にし、配布profileを再生成する。
2. `0011_apns_route_schema.sql`までD1 migrationを順番に適用する。`0008`は1人の複数iPhone、`0009`は同じAPNs tokenを持つ複数binding、`0010`は1台だけを解除しても同じ参加者の名前・ハート・再送防止情報を消さないために必要である。`0011`は旧active-only routeと新targeted routeをserverで区別し、rollbackした旧clientが非選択まどの通知を誤解釈しないために必要である。
3. 上記二つのSecretを、development／productionを混同せず対象Workerへ登録する。TestFlightは`production`と`https://api.push.apple.com`を使う。
4. `npm run notification-staging:config:render`でignored ON候補を作り、`npm run notification-staging:config:check`を通す。これはdeployしない。
5. migrationとignored configの準備後、Workerを更新する前に`npm run notification-staging:status`を実行する。このread-only確認は`route_schema_version`を直接参照するため、未適用なら失敗する。ただしactive Workerとconfigの一致は証明しない。
6. 一般配布前には、同じreview済みcode／bindingからON・OFF versionを事前固定し、active version条件付き切替を実装・検証した後にだけ、署名PUT、moment/heart各1件、APNs HTTP `200`、署名DELETE、`APNS_RUNTIME_ENABLED=NO`へのrollbackを実機で確認する。現時点のcandidateを通常deployで切り替えない。
6. Cloudflare outbound `fetch`とAPNsの実接続はmock testでは証明できない。sandbox／productionの実`200`が取れなければ公開せず、APNs provider部分をHTTP/2対応serviceへ分離する。

## 古いWorkerへ戻す場合

加算型subscriptionが1件でも存在する状態で、`route_schema_version`を知らない古いWorkerへそのまま戻してAPNsを動かしてはいけません。古いWorkerはtargeted rowも旧routeとして送るため、旧clientが非選択中のまどを選択中のまどとして扱うおそれがあります。

1. 先に`APNS_RUNTIME_ENABLED=NO`を配備し、cronと即時drainを停止する。
2. 古いWorkerへ戻している間は原則としてAPNsをOFFのままにする。
3. どうしても古いWorkerでAPNsを再開する場合は、別途明示承認を得て`notification_deliveries`、`notification_events`、`apns_subscriptions`を全削除し、加算bindingが0件になったことを件数だけ確認してからONにする。写真やハートの正本は削除せず、通知だけを捨てて各clientの次回v2登録からactive-only状態を作り直す。
4. 新Workerへ戻すときもAPNsはOFFのまま、schema確認、Worker更新、v3再登録の順に進め、staging smokeが通った後だけONにする。

`0011`のtriggerは、古いWorkerが更新した個々のsubscriptionをroute 1へ正規化する。ただし、古いWorkerに触れられていない既存の加算bindingまで安全に選別することはできないため、上記のOFF境界を省略しない。

毎分cronは最大50 deliveryをleaseし、network／`429`／`5xx`をjitter付きbackoffで再試行します。`410 Unregistered`、`BadDeviceToken`、`DeviceTokenNotForTopic`は物理的に同じtoken digestを持つ全まどのsubscriptionをCAS相当で削除します。Provider key、topic、payload等の構成4xxではdevice tokenを削除せず、D1の`last_reason=configuration_error:*`へ残して1時間後に再試行します。request body、credential、tokenはconsoleへ出しません。

## 件数だけの運用確認

ON候補を作成・検証済みで、そのconfigが参照する隔離済みstaging D1を確認するときだけ、次を実行できます。

```powershell
npm run notification-staging:status
```

このコマンドは、固定されたignored file `wrangler.notification-staging-on.jsonc`だけを読み、隔離済みstaging D1へ`SELECT`だけを実行します。任意のdatabase名・config path・SQL・shell引数は受け付けず、deploy、migration、secret変更、D1書き込みを行いません。`0011`の列がなければ失敗し、存在するときだけ`route_schema: ready`を表示します。ほかに表示するのは次の集計だけです。

- 有効subscription：`environment`ごとの件数
- 未期限切れevent：`new_moment`／`heart`ごとの件数
- delivery：`state`、粗いHTTP status（`200`／`other`）、識別子を含まないreason区分ごとの件数

ID、device ID、APNs token/digest/ciphertext、写真、まど名、暗号文、raw provider reasonは読み取りも表示もしません。`accepted/200`はAPNs受付の証拠ですが、端末の表示・background実行・Widget更新の証拠ではありません。

このコマンドは現在activeなWorkerのcode、binding、runtime flag、Cron、または同じD1へ配備されていることを
証明しません。一般配布前には、active deploymentとreview済みmanifestの一致を別のfail-closedな手順で
証明する必要があり、未整備の間はrelease blockerです。

eventとdeliveryは、受信側がアプリを開いて署名済み同期／ACKを行うと直ちに消えることがあります。APNsの確認時は、**受信側アプリを開く前**にこの集計を取り、写真送信後およそ30秒と70秒の二度で確認します。即時`waitUntil`配送または毎分cronのどちらでも、対象の写真は`new_moment`、ハートは`heart`として`accepted/200`を期待します。

## APNsだけのOFF候補を検証する（実停止ではない）

通知provider、token暗号鍵、誤routing、想定外の通知件数に異常があるときは、写真共有・通報・block・
cleanupを止めず、`APNS_RUNTIME_ENABLED`だけを`NO`へ戻す候補を使う。先に
[`STAGING.md`の一般配布候補config手順](STAGING.md#一般配布候補の独立停止config生成検証のみ)で4つの
ignored configを生成し、`npm run selective-staging-off:config:check`を通す。必要なD1／rate-limit IDは
その手順どおり現在のprocess環境だけから与え、file、chat、logへ書かない。

現時点で自動化するのは、外部変更を行わないcandidate検証とlocal bundleのdry-runまでである。

```powershell
npm run staging:runtime:apns-off
```

`--confirm-apns-only-off`は意図的に失敗し、deployしない。Wranglerの通常deployでは、現在のactive
versionと原子的に比較しながら変数1つだけを変更できず、Worker code、binding、Cronを同時に置き換える
可能性があるためである。事前に同じreview済みcode／bindingからON・OFF versionを作り、そのversion IDを
保護されたmanifestへ固定し、active versionへの条件付き切替を検証できるまでは、一般配布環境の
APNs-only実停止を自動実行しない。

広いOFFを含むrepository内の外部deploy経路も廃止済みである。本人2台のpersonal stagingでもdry-runを
停止とみなさず、利用を中断して承認済みincident responseへescalateする。一般配布ではこの未整備自体を
release blockerとする。

## 最終APNs smoke（手動確認は一度だけ）

一般公開前の実機確認は、別々の細かなテストに分けず一回にまとめます。

1. 2台を同じrelease buildにし、通知を許可して、各端末で通知対象にする全まどの登録を前面で完了する。上記集計では`production` subscriptionが「各物理端末×その端末の有効なまど資格」の件数になっていることだけを確認する。同じparticipantの同じ物理tokenは配送時に1件へまとめられる。
2. 受信側を閉じ、送信側から**新しい**写真を一枚届ける。受信側を開く前に集計で`new_moment`の`accepted/200`を確認する。通知後に別のまどを選択してから通知をタップし、対象のまどへ切り替わって対象写真の詳細が開くこと、Widgetが対象まどの検証済みcacheへ更新されることを確認する。
3. 受信側からその写真へ**新しい**ハートを一回送る。送信側を閉じたまま集計で`heart`の`accepted/200`を確認する。通知後に別のまどを選択してから通知をタップし、対象のまどへ切り替わって「自分が届けた写真」の対象行が示されることを確認する。

すでに同期済みの写真、すでに送ったハート、通知がOFFの端末ではeventが出ないかdeliveryが先に消えるため、このsmokeの証拠には使いません。失敗時はIDやpayloadを採取せず、上記の識別子を含まない集計、Cloudflareのcron実行時刻・error件数、iPhoneの診断コードだけを確認します。件数は小さい母数でも抑制しないため、operator専用とし、個人の状態を推測できる可能性を前提に外部共有しません。
