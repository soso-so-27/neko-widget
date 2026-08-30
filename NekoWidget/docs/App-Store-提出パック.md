# App Store 提出パック（草案）

最終更新: 2026-08-27

この文書は、`ねこのまど`をApp Store Connectへ提出する前に、
実装、公開文書、審査情報、運用を同じrelease境界で照合するための作業用正本である。
現時点の本人所有2台による内部TestFlight確認は、一般向けTestFlight、App Store審査提出、
一般公開の完了を意味しない。

Apple要件の外部リンクはApple公式資料だけを使用する。法律、輸出、連絡先、販売地域に関する
最終判断はApp所有者が行い、このrepositoryへ個人連絡先や秘密をcommitしない。

共有を完全に無効化した選択Aの日本語貼り付け用正本と、fail-closedの提出可否検証は
[app-store/README.md](app-store/README.md)で管理する。そこにある文面を共有ONの選択Bへ流用しない。

技術証跡はPR22〜PR28、main CI、正本スクリーンショット、Build 36の送信なし署名dry runまで完了した。
提出可否は引き続き`RED`であり、非公開のprivacy問い合わせ窓口、所有者入力、App Store Connect回答、
最終`disabled` upload証拠、build選択、審査提出は完了していない。

## 0. 表記と提出境界

### 0.1 表記

- **事実**: repository、archive、実装または完了済み検証から記入できる。
- **本人入力**: App所有者の意思、権利、連絡先、販売または運用判断が必要である。
- **Connect確認**: App Store Connectの現行質問、計算結果または保存状態を画面上で確認する。
- **提出停止**: 条件が完了するまで、その機能を含むbuildを外部配布または審査提出しない。

### 0.2 今回の提出境界を一つ選ぶ

| 選択 | buildの能力 | 必要な申告 | 状態 |
| --- | --- | --- | --- |
| A. ローカル写真・Widgetのみ | 写真共有runtime、共有Extensionの送信、まど名同期を完全にOFF | 最終archiveのPrivacy Manifestと実通信を根拠に、共有データを収集しない回答へ揃える。共有を説明・撮影しない | **PR22〜PR28、main CI、スクリーンショット、Build 36 dry runは完了。非公開のprivacy連絡先、本人入力、最終upload証拠は待ち** |
| B. 名前付きの非公開なまどを含む | 招待、2者確認、一枚送受信、届いた写真、思い出、共有Widget、block、共有解除をON。暗号化通報受付はOFF | 共有データ4種類、UGC安全策、2端末審査、暗号化輸出、限定beta運用を揃える | **外部1人のTestFlightだけ条件付き。一般公開は提出停止** |

選択: `【本人入力: A / B】`

- 提出Version: `【Connect確認】`
- 提出Build: `【Connect確認】`
- Git commit: `【Connect確認】`
- archive checksumまたはApp Store Connect build ID: `【Connect確認】`

### 0.3 現在のrelease証跡

- Build 35は共有を含む内部`media-staging`で、source `2e6f565e4272d1df40a1bad2a1411d0aafa67c78`を使用した。main CI `32652404425`、署名dry run `32652415564`、validate／upload run `32653493665`は成功した。暗号化された署名artifactはdownloadし、復号せず暗号化されたままprivate保管済みである。
- Build 35についてApple側の処理完了・build一覧表示、輸出コンプライアンス状態、内部group割当は未確認である。外部group追加、TestFlight App Review、App Store審査提出は行っていない。
- 選択Aの`disabled` modeはPR22でmain `cd5c13e6839dee4c3c33f8c65254a324328fbb32`へ統合済みである。完全ローカル版のpolicyとread-only監視はPR23でmain `9924edea7da1113d315138a841862a56f7c76e57`へ統合し、Pages deploy run `32656307265`とread-only monitor run `32656352690`が成功した。
- PR24〜PR28はmain `df7c7acf7747e9673f8269dd67763845ab9960e2`へ統合済みで、main CI run `32679594269`と共有OFFの正本スクリーンショットrun `32679649547`が成功した。5枚はすべて`1320 x 2868`、APP1 metadataなし、manifest SHA-256一致である。
- 同じmain SHAからBuild 36を`release_mode = disabled`、`upload_to_testflight = false`、`retain_signed_artifacts = true`で実行し、run `32680522092`が成功した。archive、privacy/export gate、署名／App Group entitlement、IPA export、暗号化artifact保存は成功し、App Store Connect API key導入とvalidate／uploadはskipされた。App Store Connectへのbuild選択、外部配布、審査提出は行っていない。
- Build 35の共有staging実績を選択Aのarchive検証、App Privacy回答、公開policy、審査提出の完了として流用しない。

共有ONのBは、次が完了するまでApp Store一般公開、public link、外部testerの人数追加を**提出停止**とする。
唯一の例外は、第8節のBuild 71候補について、暗号化通報受付をserver／clientの両方でOFFに固定し、
public link OFF、信頼できる外部tester 1人、TestFlightの非公開feedback、block／共有解除、
48時間以内の初回確認、共有data-plane緊急OFFを全て確認した限定外部TestFlightである。
この例外を2人目以降、別build、App Store Reviewまたは一般公開の承認として流用しない。

- production moderation鍵の承認済み生成、複数人backup、rotation、破棄
- 強い運用者認証、二人承認、監査可能な通報export
- 通報判断、利用者への応答、異議申立て、早期削除
- 通常写真runtimeとは独立したreport-ingestion緊急OFF（ソースとdry-runは実装済み。対象productionでの停止訓練は未完了）
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
> 「思い出」に残した一枚で「写真を書き出す」を選ぶと、位置情報、撮影日時、元のファイル名等を
> 除いた最大2,048pxのJPEGを端末内で準備し、iOSの共有シートへ画像データとして渡します。
> アプリ自身が管理する書き出し用の一時ファイルは作らず、開発者のサーバーへ自動送信しません。
> iOSまたは選んだ共有先がコピーを作成・保持する場合があり、その共有先のポリシーが適用されます。
>
> 共有機能では、1台のiPhoneで最大20個の名前付きで招待制の「非公開なまど」を作成・参加・切り替えでき、
> 各まどは2人だけで使います。各参加者は、承認した最大4台のiPhoneで同じまどを利用できます。
> 公開フィード、検索、フォロー、匿名チャット、連絡先同期はありません。送信されるのは、
> アプリ内の写真選択または写真アプリの共有シートで利用者が明示的に選んだ1枚だけです。最大2,048pxへ縮小し、位置情報等のmetadataを
> 除去してエンドツーエンド暗号化します。
>
> 投稿前にiOSのSensitive Content Analysisをfail-closedで実行します。受信写真では送信者をblockし、
> 共有解除できます。通常の写真を運営者が復号する鍵はありません。この限定外部TestFlightでは
> 暗号化通報受付をserver側で停止しており、アプリにも通報操作を表示しません。安全上の問題は、
> 写真、招待code、12語、鍵を添付せずTestFlightの非公開feedbackから連絡してください。
>
> サインイン用アカウントはありません。共有を確認する場合は、下記の2端末手順で新しいまどを
> 作成してください。写真・ハートはAPNsで一般的な新着通知を送りますが、通知時刻と閉じた状態のWidget更新は
> AppleとiOSのbest effortです。通知を開くと対象のまど・写真を端末内で照合します。
>
> 審査対象: Version 【Connect確認】 / Build 【Connect確認】
> 審査環境: 【本人入力: 審査期間中に維持する環境の説明。秘密や一時codeはrepositoryへ記載しない】
> 問い合わせ: 【本人入力: App Review Informationの担当者欄と一致させる】

### 1.2 ローカル限定buildの場合

選択Aでは共有に関する段落と2端末手順を削除し、次の事実だけを説明する。

- 写真判定とWidget派生画像は端末内で処理する。
- 思い出一枚のJPEG書き出しは明示操作後だけ端末内で作成し、位置情報等の元情報を除いてiOS共有シートへ渡す。開発者のサーバーへ自動送信せず、共有先のポリシーが適用される。
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
- 共有runtime、まど名同期、block／共有解除、TestFlight feedbackの確認体制が審査期間中に利用可能な限定beta環境
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
6. Aのまど画面で「写真を選んで届ける」を押し、CC0猫写真1枚を選ぶ。写真アプリの共有シートから「ねこのまど」を選び、一時保存してhost appへ戻る経路も利用できる。
7. host appで送り先、縮小後preview、安全確認を確認して送信する。
8. Bに通知が届いた場合は通知を開き、対象のまど・写真が表示されることを確認する。
9. 自動更新後も変化がなく、エラー画面に「もう一度確認する」が表示された場合だけ、その操作を1回行う。
10. Bの「届いた写真」へ同じ写真が1枚だけ表示されることを確認する。
11. Bの共有Widgetを配置し、同じ受信写真が表示候補になることを確認する。
12. Bで「取り込んで残す」を選び、写真アクセスを許可したあと通常の思い出へ加わることを確認する。続けて「思い出」から同じ一枚を開き、「写真を書き出す」でiOS共有シートが開くことを確認する。「思い出から外す」を選んでも、写真アプリの写真自体は残ることを確認する。

期待結果:

- Bは写真ライブラリへのアクセスを許可しなくても、共有写真を受信・表示できる。「思い出に残す」を選んだ時点でだけ写真アクセスを求める。
- Share Extensionは選んだ1枚をhost appへ一時handoffし、Extensionから直接送信しない。
- 操作していない「届いた写真」は、最長90日、最大500枚、256MiBまでの一時的な受信履歴である。
- 届いた写真の「取り込んで残す」は位置情報を除いた写真を写真アプリへコピーし、通常の思い出、PDF、将来の商品対象にする。相手へ通知せず、ハートとは独立する。
- 「写真を書き出す」は現在思い出に残っている一枚だけを、位置情報、撮影日時、元のファイル名等を除いた最大2,048pxのJPEGとしてiOS共有シートへ渡す。元写真と思い出状態を変更せず、アプリ自身が管理する書き出し用の一時ファイルも作らない。iOSまたは共有先がコピーを保持し得る。
- 「思い出から外す」、共有解除、block、再インストールでは写真アプリの写真を削除しない。
- APNs通知と閉じた状態のWidget更新はiOS／Appleの制御を受けるため、通知が遅れた場合に手動更新で収束することも合格条件に含める。

### 2.3 安全機能

通常経路の合格後、別のCC0 fixtureで次を行う。

1. 受信写真の安全menuに通報操作が表示されず、「この相手をブロック」から確認画面の「ブロックしてまどを解除」まで進めることを確認する。
2. 安全とプライバシーの説明からsupportを開け、写真・招待code・12語・鍵をTestFlight feedbackへ添付しない注意が表示されることを確認する。
3. 受信側で送信者をblockし、新しい送受信が停止することを確認する。
4. 最後に共有解除を確認する。

blockと共有解除はpairing、鍵、一時的な「届いた写真」を破棄するため、通常経路と同じpairingでは必ず最後に実施する。写真アプリへ明示的に取り込んだ写真は破棄しない。
再インストール後はThisDeviceOnlyの鍵を復元せず、再招待が必要である。

### 2.4 審査用記録

| 項目 | 記録 |
| --- | --- |
| 端末A / iOS | `【Connect確認】` |
| 端末B / iOS | `【Connect確認】` |
| Version / Build / commit | `【Connect確認】` |
| Release mode / environment | `【artifact metadata確認】` |
| Moderation key ID（境界Bのみ） | tracked rollout policyの`clientKeyId`（現policyは`moderation-v1`）。`【artifact metadata確認】` |
| Moderation public key SHA-256（境界Bのみ） | raw 32-byte public keyに対するlowercase 64文字hex。`【artifact metadata確認】` |
| Moderation trust manifest revision（境界Bのみ） | `【artifact metadata確認】` |
| 通常送受信の時刻 | `【Connect確認】` |
| Widget表示 | `【OK / NG】` |
| TestFlight feedbackの初回確認体制 | `【OK / NG / 提出停止】` |
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
| Photos or Videos | 利用者がアプリ内または共有シートで明示したcanonical JPEG。限定betaでは通報用copyを収集しない | Yes | No | App Functionality | 通常暗号文はACK後7日、未受領はcommit後30日 |
| User ID | まど、参加者を区別するrandom ID。氏名、email、Apple Accountではない | Yes | No | App Functionality | 共有の整合性、失効、cleanupに必要な期間 |
| Device ID | 承認済みinstallation／端末資格を区別するrandom ID。広告IDではない | Yes | No | App Functionality | 共有中と失効・cleanupに必要な期間 |
| Product Interaction | reserve、commit、配送、受領、ACK、更新、quota、block等。限定betaでは通報理由を収集しない | Yes | No | App Functionality | 整合性、不正利用防止、cleanup、必要最小限の監査期間 |

端末内の猫判定、一覧、Widget派生画像は、端末外へ送らない限りserver収集として扱わない。
操作していない「届いた写真」は端末内で最長90日、最大500枚、256MiBのうち最初に達した上限まで保持する。「取り込んで残す」を選んだ写真は、位置情報を除いて写真アプリへ保存されるため、この一時履歴の削除後も利用者の写真ライブラリに残る。利用者が単写真JPEGをiOS共有シートから外部へ渡す操作は開発者による収集ではないが、選んだ共有先による処理にはそのサービスのポリシーが適用される。

### 3.2 最終回答前の確認事項

- `【Connect確認】` Cloudflareがtransport、security、abuse対策で処理するIPその他network情報を、
  Appleのどのdata typeとして申告するかを実構成と契約に基づき判断した。
- `【Connect確認】` production archiveにanalytics、crash、広告、loginその他の第三者SDKが入っていない。
- `【Connect確認】` TestFlight feedbackや外部supportで得る情報をCustomer Supportとして追加申告する
  必要があるか、実際のproduction経路に基づき判断した。
- `【Connect確認】` 限定betaでは通報理由、通報用写真copy、自由記述をアプリから収集しないことを最終buildで確認した。
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

GitHub Pagesの[共有ベータ版](https://soso-so-27.github.io/neko-widget/)は公開済みで、現在のstable pathsは`/privacy/`、`/support/`、`/community/`である。これらは共有機能、通報受付OFF、TestFlight feedback、block、共有解除を説明する**限定外部beta専用**policyであり、選択Aの完全ローカル版へ流用しない。

選択Aの完全ローカル版専用ページはPR23で公開済みである。main commit `9924edea7da1113d315138a841862a56f7c76e57`のPages deploy run `32656307265`とread-only monitor run `32656352690`で、次のexact URLのHTTPS `200`、内容、相互linkを確認した。ただしApp Store Connectへの入力は未確認で、各ページも非公開のprivacy問い合わせ窓口が未掲載であることを明示している。この状態で一般公開の提出準備完了と扱わない。

| 用途 | 完全ローカル版のexact URL候補 | 現在の状態 |
| --- | --- | --- |
| Marketing URL | 空欄 | local-only metadataの正本どおり。`/app/`は提出準備状況を示すpolicy landingであり、Marketing URLへ流用しない |
| Privacy Policy URL | `https://soso-so-27.github.io/neko-widget/app/privacy/` | 公開・HTTPS `200`確認済み／非公開のprivacy連絡先未掲載／Connect入力未確認 |
| Support URL | `https://soso-so-27.github.io/neko-widget/app/support/` | 公開・HTTPS `200`確認済み／非公開のprivacy連絡先未掲載／Connect入力未確認 |

PR23の配備と自動監視は完了したが、Connect入力と提出条件は別の手動gateである。提出前にさらに次を満たす。

- 選択AはHTTPSのPrivacy PolicyとSupport、選択BはさらにCommunity Standardsを公開し、exact URLとdeployed commitを記録する。
- 選択Bだけは、「家族のまど」を製品語の「名前付きの非公開なまど」へ揃える。
- 選択Bだけは、一時的な受信履歴の保存期間、通報受付OFFと代替連絡経路、再インストール、明示的な「取り込んで残す」によるPhotos保存とiCloud同期の可能性を最終buildと一致させる。
- AppleのPlatform version informationに従い、Support URLへ利用者とAppleが実際に連絡できる
  email、電話、または応答可能なHTTPS form等の連絡先情報を掲載する。GitHub Issuesへの誘導だけ、
  placeholder、または「窓口未掲載」の表示では完了にしない。
- 選択Bで48時間以内の初回確認を公開する場合、休日を含む実運用で履行できる。
- 選択を問わず、個人写真や個人情報を公開問い合わせへ添付しない注意を維持する。選択Bではさらに、招待code、12語、暗号鍵を添付しない。

選択Bについて、Apple Guideline 1.2はUGCを扱うAppへ投稿前filter、通報と適時対応、abusive userのblock、
公開連絡先を求める。限定1人の外部TestFlightでは縮退運用を明示するが、アプリ内通報を安全に再開するまで
外部人数追加、public link、App Store一般公開へ進めない。

- [Apple: App Review Guidelines 1.2](https://developer.apple.com/app-store/review/guidelines/)
- [Apple: Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)

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
| filtering / report / block | Sensitive Content Analysisはfail-closed。限定betaではreport OFF、TestFlight feedback、block、共有解除 | `外部1人のみ。一般公開は提出停止` |
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

### 5.1 選択Aの5枚

| 順 | ファイル | 実際に示す機能 | 注意 |
| --- | --- | --- | --- |
| 1 | `01-local-cat-widget.jpg` | Widget Galleryで実際のWidget Extensionが描くローカル猫写真Widget | 個人のホーム画面や通知を写さない |
| 2 | `02-local-photo-window.jpg` | 端末内で選ばれた「思い出の一枚」と肉球 | 共有写真や内部diagnostic語を写さない |
| 3 | `03-organized-memories.jpg` | 撮影年や端末内解析から作る「思い出」 | serverへ写真libraryを送ると誤認させない |
| 4 | `04-liked-photos.jpg` | 利用者が肉球で残した「これ好き」 | 写真送信や「届いた写真」として表現しない |
| 5 | `05-on-device-photo-privacy.jpg` | 端末内解析と開発者serverへの自動送信なし | 許可前の説明と最終buildを一致させる |

選択Bで限定外部betaへ提出する場合に限り、名前付きの非公開なまど、一枚送信、受信Widget、block・
共有解除を別候補として検討する。選択Aへ共有画面を混ぜず、選択Bでも最終buildにない画面や将来機能を掲載しない。

### 5.2 撮影・権利チェック

共有OFFの境界A用候補は[App Storeスクリーンショット撮影](App-Store-スクリーンショット撮影.md)の
手動workflowで、消去済みSimulatorとコード生成fixtureから再現できる。workflowはApp Store Connectへ
アップロードせず、成功後もownerの目視・Content Rights・最終Build一致の承認を必要とする。

main `df7c7acf7747e9673f8269dd67763845ab9960e2`のrun `32679649547`で、上記5枚の生成、accepted size、
SHA-256、APP1 metadata除去、fixture境界、技術的な目視確認まで完了した。artifactは
`app-store-screenshots-32679649547-1`（ID `9503891782`）で、owner承認とApp Store Connect登録は未完了である。

- `【本人入力】` 最終caption、順序、localizationを承認した。
- `【本人入力】` 使用する猫イラストと画面素材の権利を確認した。
- workflowがCore Graphicsで描く決定的な猫イラスト、または権利を確認済みの公開可能素材だけを使う。
- 人物、住所、位置情報、通知、Apple Account、email、端末名を写さない。
- TestFlight表示、内部Build表示、debug menu、staging hostを写さない。
- 招待code、QR、12語、暗号鍵を写さない。
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
| 通報envelope | 限定betaでは生成・送信しない | remote moderation運用完成までOFF |
| local key protection | ThisDeviceOnly Keychain、同期なし | room key、device credential |

App targetとShare Extensionの`ITSAppUsesNonExemptEncryption`は現在`false`である。この値は
「暗号を使っていない」という記録ではなく、最終的なexemption判断と一致する場合だけ維持する。

### 6.2 releaseごとの記録

| 項目 | 値 |
| --- | --- |
| Version / Build / commit | `【Connect確認】` |
| Release mode / environment | `【artifact metadata確認】` |
| Moderation key ID（境界Bのみ） | tracked rollout policyの`clientKeyId`（現policyは`moderation-v1`）。`【artifact metadata確認】` |
| Moderation public key SHA-256（境界Bのみ） | raw 32-byte public keyに対するlowercase 64文字hex。`【artifact metadata確認】` |
| Moderation trust manifest revision（境界Bのみ） | `【artifact metadata確認】` |
| 配布する国・地域 | `【本人入力】` |
| App Store Connect質問と回答 | `【Connect確認】` |
| exemptionの根拠 | `【本人入力 / 法務確認】` |
| Appleが書類不要と判定 | `【Connect確認: Yes / No】` |
| 必要書類／CCATS等 | `【本人入力 / Connect確認】` |
| Apple approval code | `【Connect確認。秘密でない運用記録へ保存】` |
| Info.plist最終値 | `【Connect確認】` |
| 確認者／確認日 | `【本人入力】` |

回答画面、承認文書、根拠は公開repositoryではなく、アクセス制御したrelease記録へ保存する。実在しない
`moderation-v2` public key／fingerprintを推測で記録しない。境界Bのv2 clientはServer／offline Toolのv1＋v2
dual対応とreview済みv2 trust entryを先に完了した後だけ提出できる。v2 clientを一度でも配布した後はclientを
v1へ戻してもServer／Toolをv1-onlyへ戻さず、v1 retirementは全v1 lifecycleがretention／削除まで完了した
別承認にする。詳細は[moderation runbook](../SharingService/MODERATION_RUNBOOK.md#moderation-v2-rotationの順序)を
正本とする。

## 7. App Store Connect入力チェックリスト

### 7.1 App recordの固定値

| 項目 | 値 |
| --- | --- |
| App name | `ねこのまど` |
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
- [ ] `【本人入力】` Content Rights。利用者が端末内で表示する写真とスクリーンショット用猫イラストの権利境界を含む
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
- [ ] `【本人入力 / 非公開問い合わせ窓口の掲載後】` Support URL: 選択Aは`https://soso-so-27.github.io/neko-widget/app/support/`、選択B／Build 71限定betaは`https://soso-so-27.github.io/neko-widget/support/`
- [ ] `【本人入力 / 非公開問い合わせ窓口の掲載後】` Privacy Policy URL: 選択Aは`https://soso-so-27.github.io/neko-widget/app/privacy/`、選択B／Build 71限定betaは`https://soso-so-27.github.io/neko-widget/privacy/`
- [ ] `【Connect確認】` Marketing URLは空欄
- [ ] `【本人入力】` Copyright
- [ ] `【Connect確認】` 選択A用5枚のスクリーンショットと順序
- [ ] `【Connect確認】` 正しいVersionとBuildを関連付けた

Support URLは、利用者とAppleが実際に連絡できる情報へ到達できなければならない。選択Bではさらに
Guideline 1.2の公開連絡先として機能させる。公開GitHub Issueだけを個人情報・安全通報の窓口にしない。

### 7.4 App Privacy・暗号化・安全

- [ ] `【Connect確認】` 最終binaryと一致するApp Privacy data types
- [ ] `【Connect確認】` Product Page Preview
- [ ] `【Connect確認】` App Privacy responsesをPublish
- [ ] `【Connect確認】` Privacy Policy URLがHTTPSで開く
- [ ] `【Connect確認】` export compliance質問
- [ ] `【Connect確認】` 必要な暗号化文書をbuildへattach
- [ ] `【境界Bのみ・artifact確認 / AはN/A】` Version／Build、tracked rollout policyが選ぶkey ID（現policyは`moderation-v1`）、archive public key、算出SHA-256、trust manifest revisionが同じ`moderation-release-metadata.json`と一致
- [ ] `【境界Bのv2のみ・提出停止 / AはN/A】` Server／offline Toolのdual対応、review済みv2 fingerprint、rollback／retirement手順がclientより先に完了
- [ ] `【境界Bのみ・提出停止 / AはN/A】` Guideline 1.2のfilter、report、timely response、block、公開連絡先
- [ ] `【境界Bのみ・提出停止 / AはN/A】` production moderationと独立緊急OFF

独立したAPNs OFF／report-ingestion OFFのreview済みコマンドとdry-run検証は実装済みである。ただし、
この項目は対象productionでの資格情報、担当者、停止・復旧訓練が完了するまでチェックしない。

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
- [ ] `【境界Bのみ・Connect確認 / AはN/A】` 2端末手順が最終buildと一致
- [ ] `【境界B・外部1人のみ / AはN/A】` 審査期間中に同じ環境、TestFlight feedback確認、block／共有解除を維持できる
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
- [ ] `【Connect確認】` 旧buildを含まないBuild 71専用external groupを新設し、正しいbuildを一つだけ追加
- [ ] `【Connect確認】` TestFlight App Reviewの承認
- [ ] `【Connect確認】` Build 71候補の最終binaryで通報操作が非表示、serverの暗号化通報受付がOFF、公開policyのrevision監視が合格
- [ ] `【本人入力 / Connect確認】` public link OFF、外部testerは信頼できる1人だけ、Feedback EmailとReview Contactは実際に48時間以内の初回確認が可能
- [ ] `【提出停止】` 上記の1人限定例外を満たさない共有ON build、外部testerの追加、public link、App Store一般公開

内部TestFlightで本人所有2台が動作した事実を、外部TestFlightまたはApp Store公開の承認として扱わない。
第8節の1人限定例外が成立しても、2人目以降またはApp Store一般公開の承認として扱わない。

### Build 71候補 限定外部ベータ準備記録（2026-08-27）

- App Store Connectには外部group `友人テスト`が存在するが、現在はtester 0人で、承認済みの旧Build 7だけが入っている。Build 71限定境界を壊すため、既存の`友人テスト`groupを使わない。
- Build 70は内部group `自分用`で本人所有2台の受入を完了した。通報操作を非表示にして縮退運用へ一致させる変更はBuild 71候補で、Connect上の処理・内部確認後に旧buildを含まないBuild 71専用external groupへだけ追加する。
- D1 generation CASによる共有data-planeの実OFFと復旧を訓練し、OFF中の公開境界と復旧後の状態を確認した。
- staging通報鍵を用いた合成通報の復号・削除drillは完了し、review JPEG、receipt、ciphertextが残っていないことを検証した。
- 安全なremote export／判断／早期削除は未完成のため、暗号化通報受付はD1 gateでOFFのまま固定する。日次monitorはhealthのmedia/APNs ON・report OFF、通報endpointのauth-first 401、legacy OFFを検証し、認証済み通報の503拒否はintegration testで固定する。
- 1人限定betaの安全経路は、TestFlightの非公開feedback、アプリのブロック／共有解除、48時間以内の初回確認、必要時の共有data-plane緊急OFFとする。外部人数追加、public link、一般公開には使わない。
- 公開privacy、community standards、supportは、この縮退した1人限定外部TestFlightベータ向け原稿へ更新した。公開反映とrevision監視の合格後にだけ外部groupを変更する。
- feedback email、review contact、信頼できる外部tester 1人のApple Accountメールは、本人が送信先と値を確認するまでApp Store Connectへ入力しない。

**Beta App Description（日本語案）**

> 「ねこのまど」は、信頼できる相手と名前付きの非公開な「まど」を作り、iPhoneから選んだ写真を1枚ずつ暗号化して届ける1人限定ベータです。公開フィード、検索、フォローはありません。受け取った写真は、ハートを返したり、明示的に写真アプリへ保存して「思い出」に残せます。写真は送信前に最大2,048pxへ縮小し、位置情報を除去します。ブロックと共有解除に対応しています。暗号化通報受付はこのbetaでは無効で、安全上の連絡にはTestFlightのベータ版フィードバックを使用します。

**What to Test（日本語案）**

> Build 71候補では、(1) 招待でまどを作成・参加、(2) 写真を1枚届けて受け取る、(3) ハートを返す、(4) 受信写真を「思い出に残す」へ保存してJPEGを書き出す、(5) 通知をタップして対象のまど・写真を開く、(6) 受信写真の安全メニューで「この相手をブロック」を選び、確認画面の「ブロックしてまどを解除」を実行、を確認してください。公開情報や機密写真は使わず、テスト用画像で確認してください。不具合や安全上の問題は、写真や招待秘密を添付せずTestFlightのベータ版フィードバックから送信してください。アプリ内の暗号化通報はこのbetaでは無効です。

**Beta App Review Notes（日本語案）**

> アカウントへのサインインは不要です。共有機能は信頼できる2人の招待制で、1台目が非公開なまどを作成し、2台目が一回限りの招待コードで参加します。両端末で同じ12語の確認フレーズを照合して承認した後、利用者が選んだ写真1枚だけを送信できます。写真共有の確認には2台のiPhoneが必要です。両端末でiPhoneの「設定」>「プライバシーとセキュリティ」>「センシティブな内容の警告」をONにしてください。通常写真はエンドツーエンド暗号化され、送信前に位置情報を除去します。この1人限定betaでは暗号化通報のreserve／upload／commitをserver側で停止し、clientにも通報操作を表示しません。問題のある相手は受信写真の安全メニューからブロックしてまどを解除でき、安全上の連絡はTestFlightの非公開feedbackで受け付けます。公開フィード、検索、フォロー、匿名の出会いはありません。

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
| Moderation、監視、緊急OFF | Safety / Operations | `【外部1人のみ条件付き／公開policy・monitor待ち】` |
| Review Notesと連絡先 | App owner | `【未確認】` |
| Submit for Reviewの明示承認 | App owner | `【未確認】` |

全Gateが選択した提出境界と一致するまで、この文書を「公開準備完了」の証拠として使用しない。
