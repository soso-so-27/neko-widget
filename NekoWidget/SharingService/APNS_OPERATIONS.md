# APNs通知のstaging／production運用

この文書は、写真とハートの汎用APNs通知を有効にするときのserver側停止条件です。通知は同期の正本ではありません。APNsが`200`を返しても端末表示・background実行・Widget更新は保証されず、アプリの署名済みcursor同期を正本にします。

## 保持する情報

- APNs device tokenは`APNS_TOKEN_KEYRING_JSON`のcurrent AES-256-GCM鍵でapplication-level暗号化してD1へ保存する。
- D1には暗号文、12-byte nonce、鍵version、重複／失効CAS用SHA-256 digestだけを置く。平文tokenをresponseやlogへ出さない。
- Subscriptionは現在の認証済み`moment_devices.id`へserver側で結び、最終更新から35日で削除する。アプリは起動ごとにPUTして更新する。
- Notification eventは24時間で削除する。最初のtoken登録で古いeventをbackfillしない。Moment ACK、revoke、expiry、block、device/participant/space失効では関連eventまたはsubscriptionを即時削除する。
- APNs payloadは`aps.alert`と`content-available=1`だけで、sound、badge、写真、まど名、人物名、時刻、moment/reaction/device/space ID、URL、鍵を含めない。
- 1台のiPhoneでは選択中のまどだけを通知対象にする。同じtoken digestの署名PUTは、それ以前の別まど／device bindingと未完了deliveryを置き換える。非activeまどを明示scopeで同期できる版までは、複数まどへ同じ物理tokenを同時登録しない。

## Signed API

`PUT /v2/push-subscriptions/current`のexact JSON:

```json
{"protocolVersion":2,"token":"<canonical base64url; decoded 16..256 bytes>","environment":"development|production"}
```

成功response:

```json
{"protocolVersion":2,"subscription":{"state":"active"}}
```

`DELETE /v2/push-subscriptions/current`のexact JSON:

```json
{"protocolVersion":2}
```

成功response:

```json
{"protocolVersion":2,"subscription":{"state":"deleted"}}
```

どちらも通常member requestと同じEd25519署名、timestamp、nonceを必須にします。PUTは`APNS_RUNTIME_ENABLED=YES`でだけ成功し、OFF中も署名検証後にnonceを消費して`503 apns_runtime_disabled`へします。DELETEは緊急OFF中にも成功し、利用者がserver tokenを消せる状態を維持します。Client指定のdevice ID、participant ID、bundle ID、topicは受け取りません。

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
2. `0010_multi_device_shared_data.sql`までD1 migrationを順番に適用する。`0008`は1人の複数iPhone、`0009`は同じAPNs tokenを持つ旧bindingを安全に識別・置換する場合、`0010`は1台だけを解除しても同じ参加者の名前・ハート・再送防止情報を消さないために必要である。
3. 上記二つのSecretを、development／productionを混同せず対象Workerへ登録する。TestFlightは`production`と`https://api.push.apple.com`を使う。
4. `npm run notification-staging:config:render`でignored ON候補を作り、`npm run notification-staging:config:check`を通す。これはdeployしない。
5. 明示承認後にだけ同じcandidateをdeployし、署名PUT、moment/heart各1件、APNs HTTP `200`、署名DELETE、`APNS_RUNTIME_ENABLED=NO`へのrollbackを実機で確認する。
6. Cloudflare outbound `fetch`とAPNsの実接続はmock testでは証明できない。sandbox／productionの実`200`が取れなければ公開せず、APNs provider部分をHTTP/2対応serviceへ分離する。

毎分cronは最大50 deliveryをleaseし、network／`429`／`5xx`をjitter付きbackoffで再試行します。`410 Unregistered`、`BadDeviceToken`、`DeviceTokenNotForTopic`は物理的に同じtoken digestを持つ全まどのsubscriptionをCAS相当で削除します。Provider key、topic、payload等の構成4xxではdevice tokenを削除せず、D1の`last_reason=configuration_error:*`へ残して1時間後に再試行します。request body、credential、tokenはconsoleへ出しません。

## 件数だけの運用確認

ON候補を作成・検証済みで、対象Workerへ既に配備されているときだけ、次を実行できます。

```powershell
npm run notification-staging:status
```

このコマンドは、固定されたignored file `wrangler.notification-staging-on.jsonc`だけを読み、隔離済みstaging D1へ`SELECT`だけを実行します。任意のdatabase名・config path・SQL・shell引数は受け付けず、deploy、migration、secret変更、D1書き込みを行いません。表示するのは次の集計だけです。

- 有効subscription：`environment`ごとの件数
- 未期限切れevent：`new_moment`／`heart`ごとの件数
- delivery：`state`、粗いHTTP status（`200`／`other`）、匿名化したreason区分ごとの件数

ID、device ID、APNs token/digest/ciphertext、写真、まど名、暗号文、raw provider reasonは読み取りも表示もしません。`accepted/200`はAPNs受付の証拠ですが、端末の表示・background実行・Widget更新の証拠ではありません。

eventとdeliveryは、受信側がアプリを開いて署名済み同期／ACKを行うと直ちに消えることがあります。APNsの確認時は、**受信側アプリを開く前**にこの集計を取り、写真送信後およそ30秒と70秒の二度で確認します。即時`waitUntil`配送または毎分cronのどちらでも、対象の写真は`new_moment`、ハートは`heart`として`accepted/200`を期待します。

## 最終APNs smoke（手動確認は一度だけ）

一般公開前の実機確認は、別々の細かなテストに分けず一回にまとめます。

1. 2台を同じrelease buildにし、通知を許可して、受信側の対象まどを一度前面で開く。上記集計で`production` subscriptionが2件であることだけを確認する。
2. 受信側を閉じ、送信側から**新しい**写真を一枚届ける。受信側を開く前に集計で`new_moment`の`accepted/200`を確認し、その後に通知、アプリ内の写真、Widget更新を確認する。
3. 受信側からその写真へ**新しい**ハートを一回送る。送信側を閉じたまま集計で`heart`の`accepted/200`を確認し、その後に送信側の通知とアプリ内表示を確認する。

すでに同期済みの写真、すでに送ったハート、通知がOFFの端末ではeventが出ないかdeliveryが先に消えるため、このsmokeの証拠には使いません。失敗時はIDやpayloadを採取せず、上記の匿名集計、Cloudflareのcron実行時刻・error件数、iPhoneの診断コードだけを確認します。
