# 2台メディアstaging・TestFlight準備

この手順は、既にペアリング済みの2台で「今の一枚」を確認するためのクライアント側release gateです。Cloudflare resourceの作成、migration、deployは[Cloudflare隔離staging手順](../SharingService/STAGING.md)の責務とし、ここでは繰り返しません。

Build 30で本人所有2台への最初の内部TestFlight受入、Build 31でfail-closedな受信再試行、履歴、ホーム、Widgetの受入、Build 34で名前付きのまどと1枚共有の本人2台受入まで完了しました。Build 35は共有UXと期限付きの「思い出に残す」を追加する内部候補です。2026-08-24現在は本人2台だけの個人例外として`MOMENT_RUNTIME_ENABLED=YES`、`WINDOW_NAME_RUNTIME_ENABLED=YES`、`LEGACY_SHARING_RUNTIME_ENABLED=NO`を維持し、[日次監視と緊急OFF](../SharingService/PERSONAL_STAGING_OPERATIONS.md)を適用します。一般向けTestFlight配布、App Store審査提出、公開はまだ行いません。

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

## Build 30 初回受入記録

2026-08-23、commit `5172b09015bf1ad9a5d498f0be313fc0b47080ef`からBuild 30を作成し、本人用の内部TestFlightグループだけへ配布した。

- mainのbuild、iOS 18.5／26.2 sharing runtime self-test、Simulator smokeが成功
- signing-only archiveを先に検証し、同一commitをBuild 30としてAppleへupload
- App Store Connectで処理完了、Build 30、内部グループ割当を確認
- 本人所有の2台をBuild 30へ更新し、既存の2人ペアリングを維持
- 両端末で「センシティブな内容の警告」が有効な状態から開始
- 本人が選んだ新しいテスト画像1枚だけを、Share Extensionからhost appへ渡した
- host appで安全確認後に送信し、送信側は「直近の配信受付」を表示
- 受信側は同じ1枚を表示し、Serverでもmoment `committed`、delivery `acknowledged`を確認
- テスト窓では通常momentだけを一時的に有効化し、旧日次共有runtimeは常に無効のまま維持
- 終了直後に通常momentを無効化し、`/health`の`200`、通常momentと旧共有の`503`を確認
- Environmentに設定した公開privacy、support、community standardsの3 URLは、外部からのHTTPS到達性が`200`で、placeholderを含まない

この合格は通常の`reserve → upload → commit → receive → ACK`だけを対象とする。Build 30時点では次を未確認として残した。

- 受信側の分析設定が無効な間は未表示・未ACKとし、有効化後に同じ配送を再試行する実機経路
- アプリ内のprivacy、support、community standardsの各Linkが端末で開くこと
- 受信写真の通報、block、共有解除
- offline、Share Extension終了、再起動、通信retry、鍵喪失
- app削除・再install後に旧資格を使えないこと

## Build 31 本人2台受入記録

2026-08-23、commit `fa5b74312b6e9b90425dde201c21573ea92c49d9`からBuild 31を作成し、本人用の内部TestFlightグループだけへ配布した。両方の本人所有iPhoneをBuild 31へ更新し、既存ペアリングを解除せず継続した。

- 受信側の「センシティブな内容の警告」が無効な間は写真を表示せず、ACKとcursor更新を行わないfail-closed経路を確認
- 設定を有効にした後、同じ配送を再試行して表示・ACKまで進むことを確認
- 送信側が緑の配信受付になり、相手端末へ新しい一枚が届くことを複数回確認
- ホームの受信カードとホーム画面Widgetへ同じ受信写真が表示されることを確認
- 共有履歴で表示可能3枚と安全確認で非表示2枚を分離して扱えることを確認
- Widgetの共有写真源では肉球操作を出さず、タップで共有履歴を開くことを確認
- 写真アクセスを許可していない旧iPhoneでは個人写真源を空のまま保ち、共有写真源だけで届いた写真を表示できることを確認
- 通常momentだけを継続ONとし、旧日次共有runtimeはOFFのまま維持

Build 31で完了したのは本人2台の内部受入であり、一般公開のproduction gateではない。アプリ内の公開policy Link、実際の通報・block・共有解除、offline／Extension終了／再起動、鍵喪失、再install後の旧資格拒否、負荷、監視、鍵運用、App Store Connect回答は別gateとして残る。本人2台の継続利用は[個人例外runbook](../SharingService/PERSONAL_STAGING_OPERATIONS.md)に従い、異常時は新しい写真配送を緊急OFFにする。一般向けTestFlightまたはApp Storeで写真runtimeを有効化しない。

## Build 34 名前付きまどの本人2台受入記録

2026-08-24、Build 34を本人用の内部TestFlightグループだけへ配布し、両方の本人所有iPhoneを既存ペアリングのまま更新した。

- 作成者側でまど名を変更して「相手と共有」を行い、招待相手側にも同じ名前が反映されることを確認
- まど名同期後も一枚の送受信、受信履歴、共有Widgetが継続することを確認
- 公開runtimeで通常momentと暗号化まど名同期が有効、旧日次共有が無効であることを確認
- staging monitorが成功し、公開runtimeの3つの状態が設定どおりであることを確認

この確認は名前同期を含む本人2台の内部受入であり、複数まど、3人以上、一般向けTestFlight、App Store審査提出、一般公開の完了を意味しない。

## Build 35 候補の受入・配布メモ

Build 35候補は2026-08-24時点で番号未確定・TestFlight未配布である。写真配送やまど名同期のprotocolを広げず、次の利用者向け修正を一つの候補へまとめる。

- 最初に「新しいまどを作る」と「招待されたまどに参加」を分け、各段階で役割と次の操作を1つずつ案内する
- 手動確認後に状態が変わらなくても、確認完了、現在待っている相手側の操作、確認時刻を表示する
- 機種変更・再インストールでは鍵を引き継がず、旧端末または相手端末から解除して再招待することを案内する
- 共有解除をserverで確認してから、このiPhoneの共有鍵、受信履歴、まど内の「思い出に残す」の印を削除したことを表示する
- 安全に表示できた受信写真だけへ「思い出に残す」を付けられる。これは共有履歴内の端末ローカルな印であり、写真本体を複製せず、写真アプリやiCloud、個人の「これ好き」へ追加しない
- 印を付けた写真は最新の一枚を妨げない範囲で端末内履歴の整理時に優先するが、最大90日・500枚・256MBの上限は延長しない。期限、共有解除、block、再インストールで写真と印を削除する

候補SHAを作る前に、schema 5から6への既定値移行、表示可能な受信写真だけへ印を付けられること、期限・容量・tombstone・unlink・blockで孤立した印が残らないこと、Photos／iCloudへ書き込まないこと、ペアリング各段階の主操作と手動確認結果を対象テストで確認する。候補SHAでは通常のiOS buildとsharing runtime self-testを1回通し、その後にだけ本人用内部TestFlightへ配布する。2台では既存ペアリングを維持した更新、印のON/OFF、手動確認結果、解除を伴わない機種変更案内、一枚の送受信とWidgetの非退行を確認する。一般向けTestFlightやApp Storeへは自動的に広げない。

### Build 35後も残るもの

1. production moderation鍵の複数人バックアップ・rotation・破棄、強い運用者認証、通報判断・異議申立て・早期削除、独立したreport-ingestion緊急OFFを含む一般公開の安全運用
2. hostile imageの隔離decode／再encode、production D1/R2、負荷試験、監視、App Store ConnectのPrivacy回答・審査メモ・審査用導線
3. アプリを閉じたままの即時受信通知。現行は起動時・foreground復帰時・前面中の同期であり、APNsは未実装
4. ADR-018段階4のspace単位分離と複数まど
5. ADR-018段階5の3人以上と、1人が複数端末を使う場合の鍵更新・招待・解除・delivery
6. 受信写真を共有履歴から独立して個人の「これ好き」／PDF／本へ恒久保存する機能と、その同意・容量・削除設計
