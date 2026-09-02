# App Storeスクリーンショット撮影

最終更新: 2026-08-24

この手順は、共有OFFのlocal-only Release境界Aについて、個人写真、位置情報、Apple Account、
メールアドレス、端末名、通知、招待情報を含まない日本語iPhoneスクリーンショット候補を作る。
App Store Connectへのアップロードや提出は行わない。

## 作る5枚

| 順 | ファイル | 実際に示す機能 |
| --- | --- | --- |
| 1 | `01-local-cat-widget.jpg` | Widget Galleryで実際のWidget Extensionが描いたローカル猫写真Widgetのサンプル |
| 2 | `02-local-photo-window.jpg` | このiPhoneで見つけた猫写真の一覧と「自動アルバム」の入口 |
| 3 | `03-organized-memories.jpg` | 撮影年や端末内の解析結果から作る自動アルバム |
| 4 | `04-liked-photos.jpg` | 利用者が「思い出に残す」で選んだ写真と書き出しの入口 |
| 5 | `05-on-device-photo-privacy.jpg` | 端末内解析と開発者サーバーへの自動送信なしを説明する許可前の画面 |

境界Aに存在しない招待、送受信、受信Widget、通報、block、共有解除は撮らない。通知、push、
background delivery、複数人利用があるようなcaptionも付けない。

## プライバシーと権利の境界

- workflowは既存Simulatorを撮影前後にeraseし、写真やアカウントをimportしない。
- 猫はアプリ画面用fixtureとWidget Extension内の撮影専用fixtureがCore Graphicsで描く、
  決定的なベクター風イラストである。
  参照写真、生成AI画像、CC0画像、人物、文字、ロゴ、EXIF、GPSを入力しない。
- アプリ画面のfixture rootとidentifier解決は`#if DEBUG`内だけにある。Widgetサンプルはさらに
  `#if DEBUG && APP_STORE_SCREENSHOT_WIDGET_FIXTURE`で囲み、専用conditionをこの手動workflowだけが
  Widget ExtensionのDebug targetへ注入する。通常DebugとReleaseではコードも画像もコンパイルされず、
  通常の写真表示は引き続きPhotoKit／App Group cacheだけを読む。ただしこの撮影run自体はDebug UI testであり、
  最終Release archiveのbinary検査を行ったという証拠にはしない。
- 画面本体は`OnboardingView`、`MainTabView`、`HomeView`、`AlbumView`、`LikedPhotosView`という
  製品UIをそのまま使う。Widget候補も実際の`NekoWidgetView`、timeline provider、image loaderを通し、
  App Group、写真、network、timeline reloadに依存しない撮影専用sample entryをWidget Galleryで描画する。
  存在しない機能やマーケティング用の上書きUIは足さない。
- xcodebuildにはdisabled tupleを全て明示し、API URL、共有policy URL、moderation keyを空にする。
  Share Extensionも`FALSEPREDICATE`のdisabled plistを使う。
- XCTestのPNGはmacOS `sips`でJPEGへ変換する。exporterはJPEG APP1 metadata（EXIF/XMP）を拒否し、
  accepted pixel sizeとSHA-256をmanifestへ記録した後、raw attachmentsを成果物から除く。

## App Storeのサイズ

Appleの6.9-inch iPhone portrait accepted sizeのいずれか1種類で5枚を統一する。

- `1260 x 2736`
- `1290 x 2796`
- `1320 x 2868`

Appleは1〜10枚の`.jpeg`、`.jpg`、`.png`を受け付け、alpha／透明を認めない。仕様は変わり得るため、
実際の提出時に[AppleのScreenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
を再確認する。本アプリは`TARGETED_DEVICE_FAMILY = 1`なので、このworkflowはiPhoneだけを作る。

## GitHub Actionsで撮る

workflowは手動起動だけで、AppleやApp Store Connectへ接続しない。

```bash
gh workflow run app-store-screenshots.yml --ref <candidate-branch-or-sha>
gh run list --workflow app-store-screenshots.yml --limit 1
gh run download <run-id> --name app-store-screenshots-<run-id>-1
```

`.github/workflows/app-store-screenshots.yml`はXcode 26.3／iOS 26.2の6.9-inch iPhoneを選び、
日本語、ライト表示、09:41、満充電へ固定し、製品画面とWidget Gallery previewの2つのUI testを
直列で実行する。成果物の保持期間は14日。

失敗時はlog、選択Simulator、終了codeに加え、`.xcresult`から抽出した失敗画面やUI階層などの
named attachmentを7日だけ保存する。空previewと画面自体は正常なのにSpringBoardがWidget内部の
accessibilityを公開しない場合を区別できるようにし、巨大なraw `.xcresult`は保存しない。
成功画像の成果物とは分離する。

成果物:

- 上記5枚のJPEG
- `app-store-screenshot-manifest.json`: pixel size、SHA-256、metadata検査、fixture由来
- `capture-device.txt`
- `xcode-version.txt`
- `widget-fixture-build-conditions.txt`: 撮影Debugだけに専用conditionが入り、通常Debug／Releaseには
  入らないことを`xcodebuild -showBuildSettings`で確認した記録

### 2026-08-24のmain正本記録

PR28を統合したmain `df7c7acf7747e9673f8269dd67763845ab9960e2`について、main CI
[run 32679594269](https://github.com/soso-so-27/neko-widget/actions/runs/32679594269)と撮影
[run 32679649547](https://github.com/soso-so-27/neko-widget/actions/runs/32679649547)が成功した。撮影artifactは
`app-store-screenshots-32679649547-1`（artifact ID `9503891782`、GitHub artifact digest
`sha256:0b8d89d36a90b33ac36f5f121357d7699554602f2e9f041bf9a1cf716c12c228`、2026-09-07失効予定）である。

5枚はすべて`1320 x 2868`のJPEGで、manifest SHA-256と一致し、SOI／SOS／EOI構造が有効、APP1 segmentは
0件だった。manifestは個人写真0件、外部画像0件、account／位置情報なし、`local-only-disabled`境界、
`userReviewRequiredBeforeUpload = true`を記録している。5枚の技術的な目視確認でも、描画不良、共有UI、
個人情報、文字切れは見つからなかった。これはApp ownerによるContent Rights、caption、順序、最終Build一致の
承認を代替しない。

## アップロード前の人による確認

workflow成功は撮影候補の技術検査であり、Content RightsやApp Store提出の承認ではない。App ownerが
5枚を実際に開き、次を確認してからApp Store Connectへ手動で登録する。

- 最終提出Buildと文言、タブ、機能境界が一致する。
- 猫イラストを商品画面の写真代替として使うことを承認する。
- 個人名、写真、位置、通知、アカウント、メール、端末名、招待code、12語、鍵が見えない。
- 5枚が同じpixel sizeで、manifestのSHA-256と一致する。
- captionを付ける場合もlocal-onlyを超える共有・push・自動送信を示さない。
- App Store Connectのpreviewで順序、crop、文字切れを確認する。

## macOSでのみ残る検証（候補を再生成するときも必須）

Windows／Linuxで行えるのはworkflow、project参照、fixture境界、exporterの静的契約テストまでである。
次はXcodeを備えたmacOSで確認する。上記main正本runで1〜3と技術的な5を完了し、Build 36の
`disabled`署名dry runで4のRelease境界も確認した。source、UI、Xcode、撮影deviceを変えた場合は再実行する。

1. UI testのSwiftコンパイルと6.9-inch Simulatorでの実描画
2. XCTest attachmentのexportと`sips`によるJPEG変換
3. 実画像のaccepted size／APP1 metadata／SHA-256検査
4. 最終Release archiveでDEBUG fixture routeが含まれないことのRelease CI確認
5. 5枚の目視確認

App Store Connectへの登録、Content Rights確認、caption・順番の最終承認、Submit for Reviewは完了しておらず、自動化しない。
