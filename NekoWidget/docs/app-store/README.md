# App Storeメタデータ（完全ローカル版・日本語）

最終更新: 2026-08-24

このディレクトリは、写真共有を完全に無効にした`disabled` releaseだけに使う。
貼り付け内容の機械可読な正本は[local-only-ja.json](local-only-ja.json)である。
共有を有効にしたbuild、外部TestFlight用説明、将来機能の宣伝には流用しない。

現在の状態は、本文検証が`COPY_VALID`、提出可否は`RED`である。公開Privacy／Supportページに
実際の問い合わせ経路がなく、所有者入力と最終`disabled`署名archiveの証拠も未完了のため、
App Storeへ提出しない。

Appleの現行上限は、App名30文字、Subtitle 30文字、Promotional Text 170文字、
Description 4,000文字、Keywords 100 bytes、Review Notes 4,000 bytesである。
Keywordsだけは文字数ではなくUTF-8 bytesで確認する。AppleのPlatform version informationに従い、
Support URLは実際の連絡先情報へ到達できるページでなければならない。GitHub Issuesへの誘導だけ、
「窓口未掲載」の表示、または連絡不能なplaceholderはこの要件を満たさない。

## 貼り付け用本文

### App名候補

<!-- metadata:app_name:start -->
```text
ねこのまど
```
<!-- metadata:app_name:end -->

App Store Connectの既存record名と一致することを所有者が確認するまで提出不可。

### Subtitle

<!-- metadata:subtitle:start -->
```text
猫写真を見つけて毎日ウィジェットに
```
<!-- metadata:subtitle:end -->

### Promotional Text

<!-- metadata:promotional_text:start -->
```text
猫の写真を端末内で見つけ、ホーム画面のウィジェットへ。気に入った一枚は肉球で残し、選んだ1〜30枚をPDFにまとめられます。
```
<!-- metadata:promotional_text:end -->

### Description

<!-- metadata:description:start -->
```text
カメラロールに埋もれた猫の写真を、毎日の「まど」へ。

「ねこのまど」は、iPhoneの写真から猫が主役の写真を端末内で見つけ、ホーム画面のウィジェットに表示するアプリです。アプリを開かない時間にも、思い出の一枚と再会できます。

できること
・許可した写真の中から猫写真を端末内で判定
・ホーム画面のウィジェットに一枚を表示
・「思い出」で年ごと、成長、どアップ、人といっしょ、おでかけなどを振り返る（写真の内容や撮影情報に応じて表示）
・気に入った写真へ肉球を付け、「これ好き」にまとめる
・「これ好き」から1〜30枚を選び、PDFに書き出す
・猫ごとのプロフィールを作り、自分で指定した写真や写真アプリのアルバムをつなぐ
・誤って猫候補になった写真を除外し、あとから戻す

プライバシー
猫判定、一覧、ウィジェット用画像の準備はこのiPhone内で行います。このバージョンには、ほかの利用者への写真送信、招待、受信、公開フィード、アカウント、広告、トラッキングはありません。写真や判定結果を開発者のサーバーへ自動送信しません。

写真へのアクセスは、許可した範囲だけを使用します。元の写真を削除・移動しません。設定から写真アプリの「うちの子」アルバムを更新した場合は、元写真を複製せず、アルバムへの追加・解除だけを行います。iCloud写真の同期はAppleと利用者の設定に従います。

PDFなどを書き出すときだけiOSの共有シートが開き、共有先は利用者が選びます。
```
<!-- metadata:description:end -->

### Keywords

<!-- metadata:keywords:start -->
```text
猫写真,ウィジェット,思い出,アルバム,カメラロール,成長記録,写真PDF
```
<!-- metadata:keywords:end -->

App名や他社・他App名は入れない。

### Support URL

<!-- metadata:support_url:start -->
```text
https://soso-so-27.github.io/neko-widget/app/support/
```
<!-- metadata:support_url:end -->

### Privacy Policy URL

<!-- metadata:privacy_policy_url:start -->
```text
https://soso-so-27.github.io/neko-widget/app/privacy/
```
<!-- metadata:privacy_policy_url:end -->

### Marketing URL

空欄。公開中の`/app/`は提出準備状況を明示するpolicy landingであり、製品marketing pageとしては使わない。

### App Review Notes

<!-- metadata:review_notes:start -->
```text
この提出ビルドは「ねこのまど」の完全ローカル版です。サインインやデモアカウントは不要です。

主な確認手順
1. 起動し、写真アクセスを「すべての写真」または「選択した写真」で許可します。
2. アプリを前面にしたまま、許可した写真から猫写真の判定が進むことを確認します。猫が主役の写真がない場合は空状態を表示します。
3. 「まど」で一枚を開き、肉球を押すと「これ好き」に追加されます。
4. 「思い出」で、利用可能な写真に応じたアルバムを開けます。
5. 「これ好き」で1〜30枚を選ぶと、端末内でPDFを作成し、iOSの共有シートを開けます。
6. ホーム画面の空白を長押しし、「編集」から「ウィジェットを追加」を選び、「ねこのまど」を追加します。WidgetKitの更新時刻はiOSが決めるため、操作直後に画像が切り替わらない場合があります。

プライバシーと機能境界
・猫判定、一覧、ウィジェット用画像、PDF作成は端末内で行います。
・許可した写真だけを読み、元写真を削除・移動しません。
・このビルドでは、ほかの利用者とのネットワーク写真共有、招待、送信、受信、共有履歴を無効にしています。
・開発者サーバーへの自動通信、サインイン、アカウント、広告、トラッキングはありません。
・利用者がPDF等の書き出しを選んだ場合だけiOSの共有シートを開きます。
・写真アプリの「うちの子」アルバム更新は利用者が設定から実行する操作です。元写真を複製せず、アルバム所属だけを変更します。iCloud写真の同期はAppleと利用者の設定に従います。

写真アクセスを許可しない場合、設定、プライバシーポリシー、サポートは確認できますが、猫写真とウィジェットの実画像は表示されません。
```
<!-- metadata:review_notes:end -->

Sign-in requiredは`No`。初回Version 1.0なので`What’s New`は空欄とし、更新版へ流用しない。

## 所有者だけが入力する提出gate

個人連絡先、年齢rating、暗号化・輸出判断、販売地域などはrepositoryへ書かない。
[local-only-owner-input.example.json](local-only-owner-input.example.json)をrepository外またはgitignoredの
`local-only-owner-input.json`へcopyし、値を埋める。`null`、未入力、`false`はすべて提出停止になる。
所有者が値を`true`にしても、checked-inのPrivacy／Supportページに「窓口は現在未掲載」または
「提出準備は完了していません」が残る間はvalidatorが自動で`RED`を維持する。通常実行が確認する
site rootはrepositoryの`docs/app`へ固定しており、CLI引数で別のdummy pageへ差し替えることはできない。

公開準備を完了するときは、Privacy／Support両ページへ次を実装する。個人emailをrepositoryへ
書く必要がない運用なら、実際に応答できる専用の公開HTTPS formを用意する。

- `<meta name="neko-app-store-contact-ready" content="true">`をheadへ置く。
- 実際に受信・応答できる`mailto:` link、または公開HTTPS formだけに
  `data-neko-private-contact="true"`を付ける。
- HTTPS formのlinkまたはformには`data-neko-contact-kind="form"`も付ける。
- markerだけ、dummy address、予約domain、転送先未設定のformでは完了扱いにしない。

特に次は文面が完成していても代行判断できない。

- App Store Connect上のApp名、Bundle ID、SKU、Primary Language、Category
- 猫写真、アイコン、スクリーンショットのContent Rights
- 標準／custom EULA、DSA status、販売地域ごとの追加要件
- Made for KidsとAge Ratingの現行質問・算出結果
- 最終archiveと一致するApp Privacy回答とPublish状態
- Privacy Policy／Support URLの保存と、公開support・非公開privacy連絡経路
- App Review contact（氏名、email、国番号付き電話番号。Connectへ直接入力）
- Export Complianceの回答、免除判断、必要書類
- Copyright、価格、tax category、配布地域、release方法
- Version、Build、40桁commit、`disabled` archiveの一致
- 最終release workflowの結論が`Success`であること
- 最終previewと`Submit for Review`の所有者承認

## 最終archive evidence gate

所有者入力だけでは`GREEN`にならない。`.github/workflows/testflight.yml`をmainの提出候補SHAで、
`release_mode=disabled`、`upload_to_testflight=true`、`retain_signed_artifacts=true`として完走させる。
workflowはTestFlight upload成功後に次の2つのActions artifactを生成する。

- `nekowidget-signed-artifacts-<run>-<attempt>`: 暗号化した署名済みarchive／IPA
- `nekowidget-local-only-release-evidence-<run>-<attempt>`: workflow生成manifestと処理済みApp Info.plist

両方を同じrunからdownloadし、暗号化artifact、`local-only-release-evidence.json`、
`NekoWidget-processed-app-info.plist`を一緒に検証する。validatorは実fileのSHA-256／size、処理済み
Info.plistのVersion／Build／Bundle ID／`disabled` flags、workflow run ID／URL、TestFlight upload成功、
source commitのgit実在と現在のrepository HEADへの完全一致を確認する。さらに公開GitHub Actions APIで
runの最終状態が`completed/success`、workflow／main／SHA／attemptが完全一致し、同じrunに暗号化archiveと
release evidenceの両artifactが存在して期限切れでないことを照合する。ネットワーク障害などでこの最終記録を
確認できない場合もfail-closedで`RED`になる。`aaaa...`、
`owner-recorded-result`、nullその他のplaceholderは証拠にならない。署名archiveだけを作るdry run
（`upload_to_testflight=false`）も提出準備は`RED`のままである。

[local-only-release-evidence.example.json](local-only-release-evidence.example.json)はschemaの例であり、
証拠そのものではない。workflow生成manifestを手書きで再現しない。Actions run全体の結論が
`Success`になったことを確認してから、所有者入力の
`release_workflow_conclusion_success_confirmed`を`true`にする。

## 検証

本文だけを検証する（成功する）:

```powershell
python NekoWidget/ci/validate-app-store-local-only-readiness.py --copy-only
```

提出可否を検証する（所有者入力、公開連絡経路、最終archive evidenceのいずれかがなければ
意図どおり`RED`、終了code 2）:

```powershell
python NekoWidget/ci/validate-app-store-local-only-readiness.py
```

workflowからdownloadした3fileと所有者入力を含める場合:

```powershell
python NekoWidget/ci/validate-app-store-local-only-readiness.py `
  --owner-input NekoWidget/docs/app-store/local-only-owner-input.json `
  --release-evidence NekoWidget/docs/app-store/local-only-release-evidence.json `
  --signed-artifact NekoWidget/docs/app-store/NekoWidget-signed-artifacts.tar.gz.enc `
  --processed-app-info NekoWidget/docs/app-store/NekoWidget-processed-app-info.plist `
  --json
```

この4fileは`.gitignore`対象であり、commitしない。site rootを指定するoptionは意図的に提供しない。

`GREEN`は提出操作を実行する許可ではない。最後の`Submit for Review`は所有者がApp Store Connectの
previewを確認して明示的に実行する。

## Apple公式資料

- [App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)
- [Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)
- [Required, localizable, and editable properties](https://developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties/)
- [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
