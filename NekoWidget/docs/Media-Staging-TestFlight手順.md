# 2台メディアstaging・TestFlight準備

この手順は、既にペアリング済みの2台で「今の一枚」を確認するためのクライアント側release gateです。Cloudflare resourceの作成、migration、deployは[Cloudflare隔離staging手順](../SharingService/STAGING.md)の責務とし、ここでは繰り返しません。

Build 30で本人所有2台への最初の内部TestFlight受入、Build 31でfail-closedな受信再試行、「届いた写真」、ホーム、Widgetの受入、Build 34で名前付きのまどと1枚共有の本人2台受入まで完了しました。Build 35は共有UXと期限付きbookmark（当時の表示名「思い出に残す」、現「しおり」）を追加し、Appleへのvalidate／upload受付まで完了していますが、Apple側の処理完了・build一覧表示、内部group割当、実機受入は未確認です。2026-08-24現在は本人2台だけの個人例外として`MOMENT_RUNTIME_ENABLED=YES`、`WINDOW_NAME_RUNTIME_ENABLED=YES`、`LEGACY_SHARING_RUNTIME_ENABLED=NO`を維持し、[日次監視と緊急OFF](../SharingService/PERSONAL_STAGING_OPERATIONS.md)を適用します。一般向けTestFlight配布、App Store審査提出、公開はまだ行いません。

## release modeの固定値

`media-staging`は次の組み合わせだけを許可します。

| 項目 | 値 |
|---|---|
| feature | `YES` |
| media | `YES` |
| Share Extension handoff | `YES` |
| Share Extension direct-send | `NO` |
| review-preview | `NO` |

Share Extensionは保護された1枚をhost appへ受け渡すだけで、ネットワーク送信しません。host appは現在のinstallationと明示同意を確認した後にだけ送信候補を作ります。workflowの既定値は共有を完全にOFFにする`disabled`です。`review-preview`は静的な画面確認だけ、`pairing-only`は写真OFF、`media-staging`は明示した本人2台の内部試験だけに使います。

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

App Store ConnectのApp PrivacyはTestFlight uploadと別の手動gateです。内部TestFlight向けにbinaryのuploadが成功しても、App Privacyの回答保存・Publishや外部配布、審査提出は完了しません。外部groupへの追加またはApp Store審査提出の前に、公開policyの内容と上記4種類を実装へ一致させ、App Store Connect側を更新します。

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
- 「届いた写真」で表示可能3枚と安全確認で非表示2枚を分離して扱えることを確認
- Widgetの共有写真源では肉球操作を出さず、タップで「届いた写真」を開くことを確認
- 写真アクセスを許可していない旧iPhoneでは個人写真源を空のまま保ち、共有写真源だけで届いた写真を表示できることを確認
- 通常momentだけを継続ONとし、旧日次共有runtimeはOFFのまま維持

Build 31で完了したのは本人2台の内部受入であり、一般公開のproduction gateではない。アプリ内の公開policy Link、実際の通報・block・共有解除、offline／Extension終了／再起動、鍵喪失、再install後の旧資格拒否、負荷、監視、鍵運用、App Store Connect回答は別gateとして残る。本人2台の継続利用は[個人例外runbook](../SharingService/PERSONAL_STAGING_OPERATIONS.md)に従い、異常時は新しい写真配送を緊急OFFにする。一般向けTestFlightまたはApp Storeで写真runtimeを有効化しない。

## Build 34 名前付きまどの本人2台受入記録

2026-08-24、Build 34を本人用の内部TestFlightグループだけへ配布し、両方の本人所有iPhoneを既存ペアリングのまま更新した。

- 作成者側でまど名を変更して「相手と共有」を行い、招待相手側にも同じ名前が反映されることを確認
- まど名同期後も一枚の送受信、「届いた写真」、共有Widgetが継続することを確認
- 公開runtimeで通常momentと暗号化まど名同期が有効、旧日次共有が無効であることを確認
- staging monitorが成功し、公開runtimeの3つの状態が設定どおりであることを確認

この確認は名前同期を含む本人2台の内部受入であり、複数まど、3人以上、一般向けTestFlight、App Store審査提出、一般公開の完了を意味しない。

## Build 35 upload記録（Apple処理・実機確認待ち）

2026-08-24、source `2e6f565e4272d1df40a1bad2a1411d0aafa67c78`からBuild 35を作成した。

- main CI [run 32652404425](https://github.com/soso-so-27/neko-widget/actions/runs/32652404425)が成功
- 同じsourceの署名dry run [run 32652415564](https://github.com/soso-so-27/neko-widget/actions/runs/32652415564)でarchive、署名検査、IPA exportが成功
- 内部TestFlight upload [run 32653493665](https://github.com/soso-so-27/neko-widget/actions/runs/32653493665)でApp Store Connectのvalidateとuploadが成功
- 暗号化されたIPA、xcarchive、dSYM artifactをdownloadし、復号せず暗号化されたままprivate保管済み

workflow成功が示すのはAppleへのupload受付までである。Apple側の処理完了、Build 35の一覧表示、輸出コンプライアンス状態、内部groupへの割当、本人2台へのinstallと受入はまだ確認していない。外部TestFlight groupへの追加、TestFlight App Review、App Store審査提出は行っていない。

Build 35には写真配送やまど名同期のprotocolを広げず、次の利用者向け修正をまとめた。

- 最初に「新しいまどを作る」と「招待されたまどに参加」を分け、各段階で役割と次の操作を1つずつ案内する
- 手動確認後に状態が変わらなくても、確認完了、現在待っている相手側の操作、確認時刻を表示する
- 機種変更・再インストールでは鍵を引き継がず、旧端末または相手端末から解除して再招待することを案内する
- 共有解除をserverで確認してから、このiPhoneの共有鍵、「届いた写真」、「しおり」を削除したことを表示する
- 安全に表示できた「届いた写真」だけへ無料の「しおり」を付けられる。これは端末内の通常整理時に保持上限内なら優先して残す目印で、写真を新しく保存する機能や長期保管ではない。写真本体を複製せず、写真アプリやiCloud、個人の「これ好き」へ追加しない
- 「しおり」を付けた写真は最新の一枚を妨げない範囲で端末内の整理時に優先するが、最長90日・最大500枚・256MiBの上限は延長しない。期限、共有解除、block、再インストールで写真と「しおり」を削除する

source固定前に、schema 5から6への既定値移行、表示可能な受信写真だけへ印を付けられること、期限・容量・tombstone・unlink・blockで孤立した印が残らないこと、Photos／iCloudへ書き込まないこと、ペアリング各段階の主操作と手動確認結果を対象テストで確認した。Apple側の処理完了後に内部groupへ割り当てる場合は、2台で既存ペアリングを維持した更新、印のON/OFF、手動確認結果、解除を伴わない機種変更案内、一枚の送受信とWidgetの非退行を改めて確認する。一般向けTestFlightやApp Storeへは自動的に広げない。

## PR22〜PR28の統合とBuild 36の送信なし記録

PR22で`release_mode = disabled`をmainの`cd5c13e6839dee4c3c33f8c65254a324328fbb32`へ統合した。このmodeは共有runtime、まど名同期、Share Extension handoff、review previewをすべてOFFにし、App Storeへ出す完全ローカル版の候補境界である。

PR23で完全ローカル版の公開policyとread-only監視をmainの`9924edea7da1113d315138a841862a56f7c76e57`へ統合した。Pages deploy run `32656307265`とread-only monitor run `32656352690`は成功したが、非公開のprivacy問い合わせ窓口は未掲載のため、一般公開の提出準備完了とは扱わない。

PR24〜PR28はmain `df7c7acf7747e9673f8269dd67763845ab9960e2`へ統合済みで、main CI run `32679594269`と共有OFFの正本スクリーンショットrun `32679649547`が成功した。同じmain SHAのBuild 36は`release_mode = disabled`、`upload_to_testflight = false`、`retain_signed_artifacts = true`の署名dry run `32680522092`として成功した。Build 36のarchive/privacy/entitlement/IPA exportと暗号化artifact保存は確認したが、App Store Connect API key導入とvalidate／uploadはskipされ、build選択、外部配布、審査提出は行っていない。Build 36はこのpersonal stagingのWorker、D1、R2、secret、runtime flagを変更していない。Build 35の`media-staging`実績とBuild 36の`disabled` dry runは別境界として維持する。

## 次のrelease candidateでも残るもの（2026-08-25更新）

1. production moderation鍵の複数人バックアップ・rotation・破棄、強い運用者認証、通報判断・異議申立て・早期削除、独立したreport-ingestion緊急OFFを含む一般公開の安全運用
2. hostile imageの隔離decode／再encode、production D1/R2、負荷試験、監視、App Store ConnectのPrivacy回答・審査メモ・審査用導線
3. 通常APNs通知は実装済みだが、Apple DeveloperでPush Notificationsを有効化したApp ID、新しいproduction APNs entitlement入り配布profile、APNs Auth Key、Worker暗号鍵、D1 migration／deploy、production APNs実機smokeが未完了。これらを満たすまではTestFlightへ配布しない。iOS 18を含むWidget更新はbest effortであり、WidgetKit専用pushは後続releaseとする
4. 複数まどの通常操作は実装済み。通常APNsはこのiPhoneで選択中のまどだけへ登録し、まど切替時に同じtokenの旧bindingを置き換える。非activeまども通知起点で明示スコープ同期し、そのまどを選んだWidgetまで更新する処理は後続releaseとする
5. 本人の追加端末は相手の確認付きで最大4台まで実装済み。残るのは3人以上の参加、端末一覧、端末単位の明示失効
6. 期限付きの「届いた写真」自体をserverで長期保管する課金は未実装。将来再検討する場合も、個人の「思い出に追加」と分け、同意・容量・削除・鍵喪失・StoreKitを先に設計する
7. 「届いた写真」の恒久的な思い出取込は実装済み。残るのは、取り込んだ写真を使う物理的な本・プリントの注文と削除・課金設計
