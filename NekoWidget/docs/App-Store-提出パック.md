# App Store 提出パック（草案）

最終更新: 2026-08-24

この文書は、`ねこのまど - 猫の写真ウィジェット`をApp Store Connectへ提出する前に、
実装、公開文書、審査情報、運用を同じrelease境界で照合するための作業用正本である。
現時点の本人所有2台による内部TestFlight確認は、一般向けTestFlight、App Store審査提出、
一般公開の完了を意味しない。

Apple要件の外部リンクはApple公式資料だけを使用する。法律、輸出、連絡先、販売地域に関する
最終判断はApp所有者が行い、このrepositoryへ個人連絡先や秘密をcommitしない。

## 0. 表記と提出境界

### 0.1 表記

- **事実**: repository、archive、実装または完了済み検証から記入できる。
- **本人入力**: App所有者の意思、権利、連絡先、販売または運用判断が必要である。
- **Connect確認**: App Store Connectの現行質問、計算結果または保存状態を画面上で確認する。
- **提出停止**: 条件が完了するまで、その機能を含むbuildを外部配布または審査提出しない。

### 0.2 今回の提出境界を一つ選ぶ

| 選択 | buildの能力 | 必要な申告 | 状態 |
| --- | --- | --- | --- |
| A. ローカル写真・Widgetのみ | 写真共有runtime、共有Extensionの送信、まど名同期を完全にOFF | 最終archiveのPrivacy Manifestと実通信を根拠に、共有データを収集しない回答へ揃える。共有を説明・撮影しない | **本人入力** |
| B. 名前付きの非公開なまどを含む | 招待、2者確認、一枚送受信、履歴、共有Widget、通報、block、共有解除をON | 共有データ4種類、UGC安全策、2端末審査、暗号化輸出、production運用を全て揃える | **本人入力 / 現在は提出停止** |

選択: `【本人入力: A / B】`

- 提出Version: `【Connect確認】`
- 提出Build: `【Connect確認】`
- Git commit: `【Connect確認】`
- archive checksumまたはApp Store Connect build ID: `【Connect確認】`

共有ONのBは、次が完了するまで**提出停止**とする。

- production moderation鍵の承認済み生成、複数人backup、rotation、破棄
- 強い運用者認証、二人承認、監査可能な通報export
- 通報判断、利用者への応答、異議申立て、早期削除
- 通常写真runtimeとは独立したreport-ingestion緊急OFF
- hostile imageを隔離してdecode／再encodeする境界
- production D1／R2、負荷試験、cleanup、監視、alert
- 休日を含む48時間以内の初回確認を、実際の担当者で満たす訓練
- 共有解除、block、再インストール、鍵喪失、旧資格拒否を含む2端末failure test
- 公開Privacy Policy、Support、Community Standardsの公開と、実際に応答できる連絡先

運用gateの正本は[Media-Staging-TestFlight手順](Media-Staging-TestFlight手順.md)と
[moderation runbook](../SharingService/MODERATION_RUNBOOK.md)で管理する。

## 1. App Review Notes

Appleは、審査に必要な設定、登録情報、特別な手順をApp Review Informationへ記載するよう求める。
Notesは4,000 bytesまでである。

- [Apple: App Review](https://developer.apple.com/app-store/review/)
- [Apple: Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)

### 1.1 貼り付け用草案

次の本文は**共有ONのB専用**である。`【...】`を全て解消し、最終buildと一致することを確認してから
App Store Connectへ貼り付ける。

> 「ねこのまど」はiPhone専用の猫写真整理・Widgetアプリです。写真ライブラリの猫判定、一覧、
> Widget用画像の作成は端末内で行います。
>
> 共有機能では、利用者が名前を付けた招待制の「非公開なまど」1つに、2人・各1台で参加します。
> 公開フィード、検索、フォロー、匿名チャット、連絡先同期はありません。送信されるのは、
> 共有シートで利用者が明示的に選んだ1枚だけです。最大2,048pxへ縮小し、位置情報等のmetadataを
> 除去してエンドツーエンド暗号化します。
>
> 投稿前にiOSのSensitive Content Analysisをfail-closedで実行します。受信写真には通報、
> 送信者のblock、共有解除があります。通常の写真を運営者が復号する鍵はありません。
> 通報した1枚だけが通常写真とは別のmoderation経路へ暗号化コピーされます。
>
> サインイン用アカウントはありません。共有を確認する場合は、下記の2端末手順で新しいまどを
> 作成してください。同期はアプリが前面になったときに行い、pushによる即時通知は保証しません。
>
> 審査対象: Version 【Connect確認】 / Build 【Connect確認】
> 審査環境: 【本人入力: 審査期間中に維持する環境の説明。秘密や一時codeはrepositoryへ記載しない】
> 問い合わせ: 【本人入力: App Review Informationの担当者欄と一致させる】

### 1.2 ローカル限定buildの場合

選択Aでは共有に関する段落と2端末手順を削除し、次の事実だけを説明する。

- 写真判定とWidget派生画像は端末内で処理する。
- 写真アクセスは利用者が許可した範囲だけで使用する。
- サインイン用アカウントはない。
- 共有runtime、共有送信、通報serverはそのbuildでは利用できない。

### 1.3 App Review Informationの空欄

| 項目 | 値 |
| --- | --- |
| Contact first / last name | `【本人入力。repositoryへcommitしない】` |
| Contact email | `【本人入力。repositoryへcommitしない】` |
| Contact phone | `【本人入力。国番号を含める。repositoryへcommitしない】` |
| Sign-in required | `No（現行buildにサインイン用accountはない）` |
| Demo username / password | `該当なし。将来loginを追加した場合は期限切れしない審査用accountが必要` |
| Review Notes byte count | `【Connect確認: 4,000 bytes以下】` |

## 2. 2端末審査手順

この節は共有ONのB専用である。審査用環境では、一般利用者と同じ経路を使い、審査専用の安全機能
bypassを設けない。

### 2.1 事前条件

- 同じ審査対象buildを入れた2台のiPhone
- 共有runtime、まど名同期、通報経路が審査期間中に利用可能なproduction相当環境
- 権利を確認した、位置情報や人物を含まないCC0猫写真1枚以上
- 両端末の日時が自動設定され、通信できること
- 両端末で「設定」>「プライバシーとセキュリティ」>「センシティブな内容の警告」をON

環境の有効期限、監視担当、緊急OFF担当: `【本人入力 / 提出停止】`

### 2.2 通常経路

1. 端末Aでアプリを開き、「まどをつくる」を選ぶ。
2. 個人名を含まない審査用のまど名を入力する。
3. Aが表示した招待codeを端末Bの「招待で入る」へ入力する。codeをスクリーンショット、
   Review Notesまたは公開supportへ恒久掲載しない。
4. 両端末へ出る12語の確認フレーズを比較する。
5. 12語が完全一致した場合だけ、両方で「同じフレーズ」と確認し、相手を承認する。
6. Aの写真アプリでCC0猫写真1枚を開き、共有シートから「ねこのまど」を選ぶ。
7. Share Extensionの説明を確認して続け、host appへ戻る。
8. host appで送り先、縮小後preview、安全確認を確認して送信する。
9. Bでアプリを前面にする。自動更新後も変化がなければ、画面の更新操作を1回行う。
10. Bの受信履歴へ同じ写真が1枚だけ表示されることを確認する。
11. Bの共有Widgetを配置し、同じ受信写真が表示候補になることを確認する。
12. Bで「思い出に残す」をON／OFFできることを確認する。

期待結果:

- Bは写真ライブラリへのアクセスを許可しなくても、共有写真を受信・表示できる。
- Share Extensionは選んだ1枚をhost appへ一時handoffし、Extensionから直接送信しない。
- 「思い出に残す」はまど内の期限付きbookmarkで、写真アプリやiCloudへ保存しない。
- bookmarkは端末内共有履歴の最大90日、500枚、256MiBを延長しない。
- background pushは使用しないため、「送信直後に通知が来る」ことを合格条件にしない。

### 2.3 安全機能

通常経路の合格後、別のCC0 fixtureで次を行う。

1. 受信写真のmenuから通報理由を一つ選び、通報する。
2. 通報した1枚だけが通報queueへ入り、通常写真の復号鍵をserverへ渡さないことを運用側で確認する。
3. 受信側で送信者をblockし、新しい送受信が停止することを確認する。
4. 最後に共有解除を確認する。

blockと共有解除はpairing、鍵、履歴を破棄するため、通常経路と同じpairingでは必ず最後に実施する。
再インストール後はThisDeviceOnlyの鍵を復元せず、再招待が必要である。

### 2.4 審査用記録

| 項目 | 記録 |
| --- | --- |
| 端末A / iOS | `【Connect確認】` |
| 端末B / iOS | `【Connect確認】` |
| Version / Build / commit | `【Connect確認】` |
| 通常送受信の時刻 | `【Connect確認】` |
| Widget表示 | `【OK / NG】` |
| 通報queueと初回確認 | `【OK / NG / 提出停止】` |
| block / 共有解除 | `【OK / NG】` |
| 再インストール後の旧資格拒否 | `【OK / NG】` |

## 3. App Privacy対応表

App Store Connectのprivacy回答はPrivacy Manifestの存在だけでは完了しない。最終archive、実際のserver、
第三者service、公開Privacy Policyを同じrelease境界で照合し、App Store Connect上で回答をPublishする。

- [Apple: Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
- [Apple: App privacy details](https://developer.apple.com/app-store/app-privacy-details/)

### 3.1 共有ONの申告候補

現行media-stagingのPrivacy Manifestは次の4種類を、linked、trackingなし、App Functionalityとして
宣言している。

| Apple data type | 実装上の内容 | Linked | Tracking | Purpose | 保持境界 |
| --- | --- | --- | --- | --- | --- |
| Photos or Videos | 利用者が共有シートで明示したcanonical JPEG。通報時は同じ1枚の別暗号化copy | Yes | No | App Functionality | 通常暗号文はACK後7日、未受領はcommit後30日。通報暗号文はcommit後7日で削除対象 |
| User ID | まど、参加者を区別するrandom ID。氏名、email、Apple Accountではない | Yes | No | App Functionality | 共有の整合性、失効、cleanupに必要な期間 |
| Device ID | 承認済みinstallation／端末資格を区別するrandom ID。広告IDではない | Yes | No | App Functionality | 共有中と失効・cleanupに必要な期間 |
| Product Interaction | reserve、commit、配送、受領、ACK、更新、quota、通報理由、block等 | Yes | No | App Functionality | 整合性、不正利用防止、cleanup、必要最小限の監査期間 |

端末内の猫判定、一覧、Widget派生画像は、端末外へ送らない限りserver収集として扱わない。
受信履歴は端末内で最大90日、500枚、256MiBのうち最初に達した上限まで保持する。

### 3.2 最終回答前の確認事項

- `【Connect確認】` Cloudflareがtransport、security、abuse対策で処理するIPその他network情報を、
  Appleのどのdata typeとして申告するかを実構成と契約に基づき判断した。
- `【Connect確認】` production archiveにanalytics、crash、広告、loginその他の第三者SDKが入っていない。
- `【Connect確認】` TestFlight feedbackや外部supportで得る情報をCustomer Supportとして追加申告する
  必要があるか、実際のproduction経路に基づき判断した。
- `【Connect確認】` 通報理由は定型選択だけで、自由記述を収集しないことを最終buildで確認した。
- `【Connect確認】` TrackingはNoで、広告、data broker、第三者広告測定へ共有しない。
- `【Connect確認】` App Privacyの全data typeを保存後、Product Page Previewを確認し、Publishした。
- `【本人入力】` Privacy Policy URLを入力した。
- `【本人入力】` User Privacy Choices URLを提供するか決めた。

### 3.3 共有OFFの申告

選択Aでは、最終archiveのrelease mode、Privacy Manifest、Share Extension、実通信を検査し、
共有の4種類を収集しない状態であることを確認する。共有ON用のpolicy、Review Notes、スクリーンショットを
流用しない。`No, we do not collect data from this app`を選べるかは、最終archiveと第三者serviceを確認して
App Store Connect上で判断する。

### 3.4 公開policy gate

repositoryの`../../docs/`は公開候補sourceであり、公開済みであることを意味しない。提出前に次を満たす。

- HTTPSでPrivacy Policy、Support、Community Standardsを公開し、exact URLとdeployed commitを記録する。
- 「家族のまど」を製品語の「名前付きの非公開なまど」へ揃える。
- 保存期間、通報の例外、再インストール、bookmark、Photos／iCloud非保存を最終buildと一致させる。
- Support URLへ、利用者とAppleが実際に連絡できる情報を掲載する。
- 48時間以内の初回確認を公開する場合、休日を含む実運用で履行できる。
- 個人写真、招待code、12語、暗号鍵を公開問い合わせへ添付しない注意を維持する。

Apple Guideline 1.2は、UGCを扱うAppへ投稿前filter、通報と適時対応、abusive userのblock、
公開連絡先を求める。

- [Apple: App Review Guidelines 1.2](https://developer.apple.com/app-store/review/guidelines/)

## 4. Age Rating判断材料

年齢ratingはApp Store Connectの現行質問へ回答し、Appleが算出したglobal／region別結果を正本とする。
この文書だけで最終ratingを決めない。

- [Apple: Set an app age rating](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating/)
- [Apple: Age ratings values and definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions)
- [Apple: App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)

### 4.1 共有ONの回答材料

| 質問領域 | 実装上の事実 | 最終回答 |
| --- | --- | --- |
| User-Generated Content | 利用者が選んだ写真を扱う。ただし1つの招待制まど、2人、各1台だけで、不特定多数への配信はない | `【Connect確認: 現行質問の「broad distribution」の定義に従う】` |
| Messaging and Chat | text、voice、video chatはないが、利用者間で1対1の写真を直接届ける | `【Connect確認: direct messagingの定義に従い保守的に回答】` |
| Social Media | feed、search、follow、repost、公開reaction、拡散、発見導線はない | `No候補 / Connect確認` |
| Unrestricted Web Access | 任意Web browsingを提供しない | `No候補 / Connect確認` |
| Parental Controls | 独自のparental controlはない | `No候補 / Connect確認` |
| Age Assurance | 年齢確認、Declared Age Range連携はない | `No候補 / Connect確認` |
| filtering / report / block | Sensitive Content Analysisのfail-closed確認、1枚通報、block、共有解除がある | `Yes相当の実装証跡をReview Notesへ記載` |
| Provided mature content | App自身は成人向け素材、暴力、賭博、薬物、医療情報を提供しない | `【本人入力: 利用者写真に起こり得る頻度を含め、質問文どおり回答】` |
| Advertising / IAP / contests | 現行v1に広告、IAP、contestはない | `No候補 / 最終build確認` |

Appleの現行定義では、UGCは利用者作成contentの広範囲配信、Messaging and Chatは利用者同士の
direct／group messagingを含む。招待制であることだけを理由に質問を省略しない。

### 4.2 Made for Kids

`Made for Kids`は一般的な「子どもも使える」という意味で選ばない。Kids categoryを意図し、
その継続要件を全updateで守る意思がある場合だけ選ぶ。App Review承認後は選択を容易に変更できない。

決定: `【本人入力: Made for Kids Yes / No】`

### 4.3 記録

| 項目 | 値 |
| --- | --- |
| questionnaire回答日 | `【Connect確認】` |
| 回答者 | `【本人入力】` |
| global rating | `【Connect確認】` |
| region-specific rating | `【Connect確認】` |
| upward override | `【本人入力: なし / 内容】` |
| age suitability URL | `【本人入力: 任意】` |

共有OFFの選択Aでは、Messaging、UGC、安全機能に関する回答をそのbuildの実能力へ戻して再回答する。

## 5. App Storeスクリーンショット

Appleは1〜10枚の`.jpeg`、`.jpg`または`.png`を受け付け、alpha／透明を認めない。iPhone 6.9-inchの
portrait accepted sizeには`1260 x 2736`、`1290 x 2796`、`1320 x 2868`がある。

- [Apple: Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
- [Apple: Upload app previews and screenshots](https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots)

### 5.1 推奨shot list

| 順 | 伝える内容 | 画面候補 | 注意 |
| --- | --- | --- | --- |
| 1 | 猫の写真を毎日のWidgetへ | App homeと代表Widget | 個人のホーム画面通知を写さない |
| 2 | 写真はiPhoneの中で見つける | onboarding／写真処理説明 | serverへ全libraryを送ると誤認させない |
| 3 | 好きな一枚を残して振り返る | 写真詳細、肉球、履歴 | 内部diagnostic語を写さない |
| 4 | 名前付きの非公開なまど | まどhome、一般的なまど名 | 招待code、12語、個人名を写さない |
| 5 | 選んだ一枚だけを届ける | host appの送信確認 | 送信前確認と2,048px／metadata除去を正確に表現 |
| 6 | 届いた一枚をWidgetにも | 受信履歴と共有Widget | push通知があるように表現しない |
| 7 | 通報・block・共有解除 | 安全設定menu | 違反写真そのものを載せない |

選択Aでは4〜7を削除する。選択Bでも、最終buildにない画面や将来機能を掲載しない。

### 5.2 撮影・権利チェック

共有OFFの境界A用候補は[App Storeスクリーンショット撮影](App-Store-スクリーンショット撮影.md)の
手動workflowで、消去済みSimulatorとコード生成fixtureから再現できる。workflowはApp Store Connectへ
アップロードせず、成功後もownerの目視・Content Rights・最終Build一致の承認を必要とする。

- `【本人入力】` 最終caption、順序、localizationを承認した。
- `【本人入力】` 使用する猫写真の権利とlicense証跡を確認した。
- CIのCC0 fixtureまたは同等の公開可能fixtureだけを使う。
- 人物、住所、位置情報、通知、Apple Account、email、端末名を写さない。
- TestFlight表示、内部Build表示、debug menu、staging hostを写さない。
- 招待code、QR、12語、暗号鍵、通報case IDを写さない。
- 6.9-inch portrait masterを同じaccepted sizeで統一する。
- 文字、写真、buttonが最終binaryと一致し、過度な合成や存在しない機能を使わない。
- exported fileにalphaがなく、pixel size、色、順序をupload後のpreviewで確認する。

## 6. 暗号化・輸出記録

Appleは、標準暗号またはApple OSの暗号機能を使うAppにもexport complianceの判定を求める。
現在のInfo.plist値だけから免除や書類不要を断定しない。

- [Apple: Overview of export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)

### 6.1 実装inventory

| 用途 | 実装上の方式 | 対象 |
| --- | --- | --- |
| Transport | HTTPS／TLS | App、Share Extensionとsharing service |
| 招待proof／member request | Ed25519 signature、SHA-256 transcript | pairing、server authentication |
| room key envelope | X25519、HKDF-SHA256、ChaCha20-Poly1305 | 2端末pairing |
| 通常写真／manifest | HKDF-SHA256、ChaChaPoly、AAD | E2E写真配送 |
| 通報envelope | ephemeral X25519、HKDF-SHA256、ChaCha20-Poly1305 | report-only moderation copy |
| local key protection | ThisDeviceOnly Keychain、同期なし | room key、device credential |

App targetとShare Extensionの`ITSAppUsesNonExemptEncryption`は現在`false`である。この値は
「暗号を使っていない」という記録ではなく、最終的なexemption判断と一致する場合だけ維持する。

### 6.2 releaseごとの記録

| 項目 | 値 |
| --- | --- |
| Version / Build / commit | `【Connect確認】` |
| 配布する国・地域 | `【本人入力】` |
| App Store Connect質問と回答 | `【Connect確認】` |
| exemptionの根拠 | `【本人入力 / 法務確認】` |
| Appleが書類不要と判定 | `【Connect確認: Yes / No】` |
| 必要書類／CCATS等 | `【本人入力 / Connect確認】` |
| Apple approval code | `【Connect確認。秘密でない運用記録へ保存】` |
| Info.plist最終値 | `【Connect確認】` |
| 確認者／確認日 | `【本人入力】` |

回答画面、承認文書、根拠は公開repositoryではなく、アクセス制御したrelease記録へ保存する。

## 7. App Store Connect入力チェックリスト

### 7.1 App recordの固定値

| 項目 | 値 |
| --- | --- |
| App name | `ねこのまど - 猫の写真ウィジェット` |
| Bundle ID | `jp.nekowidget.app` |
| SKU | `jp.nekowidget.app.2026` |
| Platform | iOS / iPhone only |
| Version candidate | `1.0`。提出時にConnectとarchiveを再確認 |

App名、Bundle ID、SKUは署名準備の記録を正本とする。App Store Connect上の値が異なる場合は、
この文書を推測で直さず差異を解消する。

### 7.2 App Information

- [ ] `【本人入力】` Primary language
- [ ] `【本人入力】` Primary category
- [ ] `【本人入力】` Secondary categoryまたはなし
- [ ] `【本人入力】` Content Rights。利用者写真とmarketing fixtureの権利を含む
- [ ] `【本人入力】` Made for Kids
- [ ] `【Connect確認】` Age Rating questionnaireと地域別結果
- [ ] `【本人入力】` License Agreement。標準EULAまたはcustom EULA
- [ ] `【本人入力】` DSA trader statusその他の地域別事業者情報

AppleのApp Information reference:

- [Apple: App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)
- [Apple: Required, localizable, and editable properties](https://developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties/)

### 7.3 Version Information

- [ ] `【本人入力】` Subtitle（最大30文字）
- [ ] `【本人入力】` Description（最大4,000文字、plain text）
- [ ] `【本人入力】` Keywords（最大100 bytes、App名／会社名の重複や競合名を避ける）
- [ ] `【本人入力】` Promotional Textまたは空欄
- [ ] `【本人入力】` Support URL
- [ ] `【本人入力】` Privacy Policy URL
- [ ] `【本人入力】` Marketing URLまたは空欄
- [ ] `【本人入力】` Copyright
- [ ] `【Connect確認】` 1〜10枚のスクリーンショット
- [ ] `【Connect確認】` 正しいVersionとBuildを関連付けた

Support URLは、適用法が求める実際の連絡先情報へ到達でき、Guideline 1.2の公開連絡先として
機能しなければならない。公開GitHub Issueだけを個人情報・安全通報の窓口にしない。

### 7.4 App Privacy・暗号化・安全

- [ ] `【Connect確認】` 最終binaryと一致するApp Privacy data types
- [ ] `【Connect確認】` Product Page Preview
- [ ] `【Connect確認】` App Privacy responsesをPublish
- [ ] `【Connect確認】` Privacy Policy URLがHTTPSで開く
- [ ] `【Connect確認】` export compliance質問
- [ ] `【Connect確認】` 必要な暗号化文書をbuildへattach
- [ ] `【提出停止】` Guideline 1.2のfilter、report、timely response、block、公開連絡先
- [ ] `【提出停止】` production moderationと独立緊急OFF

### 7.5 Pricing and Availability

- [ ] `【本人入力】` 無料／有料、価格tier
- [ ] `【本人入力】` Tax category
- [ ] `【本人入力】` 配布国・地域
- [ ] `【本人入力】` Pre-orderの有無
- [ ] `【本人入力】` release方法: 手動、承認後自動、phased release

### 7.6 App Review Information

- [ ] `【本人入力】` Contact name、email、国番号付きphoneをConnectへ直接入力
- [ ] `【Connect確認】` Sign-in required = No
- [ ] `【Connect確認】` Review Notesが4,000 bytes以下
- [ ] `【Connect確認】` 2端末手順が最終buildと一致
- [ ] `【提出停止】` 審査期間中に同じ環境と通報対応を維持できる
- [ ] `【Connect確認】` 秘密、個人写真、期限切れcodeをNotesへ残していない

### 7.7 提出操作

Appleの現行flowでは、required metadataとbuildを揃えて`Add for Review`しただけでは送信されない。
Draft Submissionを確認し、別の`Submit for Review`を実行する。

- [Apple: Submit an app](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app)

- [ ] required fieldに未入力がない
- [ ] 選択したbuild、metadata、privacy、age、encryption、公開policyが同じrelease境界
- [ ] ownerが最終previewと販売地域を承認
- [ ] `Add for Review`
- [ ] Draft Submissionの項目を再確認
- [ ] `Submit for Review`
- [ ] Waiting for Reviewになったことを確認

このchecklistは提出を自動承認しない。最後の`Submit for Review`はApp所有者の明示判断で行う。

## 8. 外部TestFlightとの境界

外部TestFlightはApp Store一般公開ではないが、内部testerの追加だけとも異なる。外部groupへ最初のbuildを
追加するとTestFlight App Reviewが必要で、beta description、What to Test、feedback email、review contactを
準備する。最初のbuildはfull reviewで、後続buildもreviewが省略されると保証しない。

- [Apple: TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview)
- [Apple: Invite external testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers)

- [ ] `【本人入力】` 外部testerの対象と人数
- [ ] `【本人入力】` Beta App Description
- [ ] `【本人入力】` What to Test
- [ ] `【本人入力】` Feedback Email
- [ ] `【本人入力】` Review Contact
- [ ] `【Connect確認】` external groupへ正しいbuildを一つ追加
- [ ] `【Connect確認】` TestFlight App Reviewの承認
- [ ] `【提出停止】` production運用gateを満たさない共有ON buildを外部testerへ配布しない

内部TestFlightで本人所有2台が動作した事実を、外部TestFlightまたはApp Store公開の承認として扱わない。

## 9. 最終sign-off

| Gate | Owner | 結果 |
| --- | --- | --- |
| 提出境界A／Bを確定 | App owner | `【未確認】` |
| Final archiveとcommitを固定 | Release | `【未確認】` |
| 2端末機能・failure test | QA | `【未確認】` |
| App Privacyと公開policy | App owner / Privacy | `【未確認】` |
| Age Rating | App owner | `【未確認】` |
| Export Compliance | App owner / Legal | `【未確認】` |
| ScreenshotとContent Rights | App owner | `【未確認】` |
| Moderation、監視、緊急OFF | Safety / Operations | `【提出停止】` |
| Review Notesと連絡先 | App owner | `【未確認】` |
| Submit for Reviewの明示承認 | App owner | `【未確認】` |

全Gateが選択した提出境界と一致するまで、この文書を「公開準備完了」の証拠として使用しない。
