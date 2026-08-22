# 2台メディアstaging・TestFlight準備

この手順は、既にペアリング済みの2台で「今の一枚」を確認するためのクライアント側release gateです。Cloudflare resourceの作成、migration、deployは[Cloudflare隔離staging手順](../SharingService/STAGING.md)の責務とし、ここでは繰り返しません。

現在は準備段階です。Workerの`MOMENT_RUNTIME_ENABLED`と`LEGACY_SHARING_RUNTIME_ENABLED`はどちらも`NO`のままであり、この変更でdeploy、TestFlight upload、App Store Connectのprivacy申告更新は行いません。

## release modeの固定値

`media-staging`は次の組み合わせだけを許可します。

| 項目 | 値 |
|---|---|
| feature | `YES` |
| media | `YES` |
| Share Extension handoff | `YES` |
| Share Extension direct-send | `NO` |
| review-preview | `NO` |

Share Extensionは保護された1枚をhost appへ受け渡すだけで、ネットワーク送信しません。host appは現在のinstallationと明示同意を確認した後にだけ送信候補を作ります。`review-preview`の既定値と`pairing-only`の写真OFF境界は変更しません。

## GitHub `testflight` Environmentのprotected variables

値はrepository、xcconfig、workflowの直書きにせず、次のEnvironment variablesだけから注入します。Environmentはreviewerと`main`のdeployment branch ruleで保護します。

| Variable | 要件 |
|---|---|
| `SHARING_STAGING_API_ORIGIN` | 公開DNSで解決できるHTTPS origin。credential、path、query、fragmentなし |
| `SHARING_STAGING_MODERATION_KEY_ID` | `moderation-v1`とexact一致 |
| `SHARING_STAGING_MODERATION_PUBLIC_KEY` | 32 byteのcanonical base64url public key |
| `SHARING_STAGING_PRIVACY_URL` | 公開HTTPSのprivacy policy URL |
| `SHARING_STAGING_SUPPORT_URL` | 公開HTTPSのsupport URL |
| `SHARING_STAGING_COMMUNITY_STANDARDS_URL` | 公開HTTPSのcommunity standards URL |

空欄、placeholder、localhost、IP直書き、HTTP、非canonical keyは署名処理前に失敗します。archive後はprocessed App/Share Extension `Info.plist`のmode、5つのflag、API origin、moderation設定、3つの公開URLをEnvironmentの入力とexact比較します。

## privacyと同意gate

`media-staging`のApp privacy manifestは次の4種類だけを、linked、App Functionality、trackingなしで申告します。Share Extensionの収集申告は空のままです。

- User ID
- Photos or Videos
- Device ID
- Product Interaction

privacy policyは写真共有への同意toggleより前と、受信画面の「安全とプライバシー」から開けます。privacy、support、community standardsのいずれかが欠けると、media runtimeは利用可能になりません。

App Store ConnectのApp PrivacyはTestFlight uploadと別の手動gateです。公開policyの内容と上記4種類が実装に一致することを確認し、App Store Connect側を更新するまでuploadしません。

## signing-onlyの実行

外部gateが全て完了しても、最初はActionsの`Archive and upload to TestFlight`を次で実行します。

- `release_mode = media-staging`
- `upload_to_testflight = false`
- `retain_signed_artifacts = true`
- build numberは未使用の正の整数

これは署名archiveとIPA exportまでで、App Store Connectへ送信しません。次の全てが揃わなければ`upload_to_testflight = true`を選びません。

- staging Workerが別手順でreview、deployされ、通常moment runtimeをONにする承認がある
- moderation private keyの保管、復号、通報処理runbookが運用可能である
- privacy、support、community standardsが公開URLで確認できる
- App Store Connectのprivacy申告と暗号化輸出回答がarchiveと一致する
- signing-only runのarchive/privacy/entitlement検査が成功し、対象commit SHAが固定されている

## 2台確認の停止条件

uploadの承認後は、専用の内部tester groupにだけ配布します。個人情報を含まない識別しやすいテスト画像1枚を使い、共有シート→host appの内容確認→送信→相手の受信を順に確認します。次のいずれかで即時停止します。

- Share Extensionがhost appを経由せず送信する
- 同意前に写真または縮小画像の保存、送信、server object作成が発生する
- 選択した1枚以外、原本、位置情報が届く
- 送信済み表示と相手の受信状態を受領確認と誤認する
- privacy、support、community standardsのLinkが開けない
- 通報、block、共有解除のいずれかが失敗する

今回の準備変更ではこの2台試験、TestFlight upload、Cloudflare deployは実施しません。
