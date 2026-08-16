# Mac / iPhone実機検証手順

## 目的

Windowsで生成した猫ウィジェットv1をMacでビルド・署名し、iOS 17.1以上のiPhoneでPhotoKit、段階スキャン、アルバム、WidgetKit、Deep Link、App Group共有、診断ログおよびメモリ制約を検証する。

写真シャッフルがアルバムへの後日追加を自動追従しないことは確認済みであり、不具合ではない。詳細は[ADR-001](ADR-001-写真シャッフルのアルバム追従.md)を参照する。

## 0. 検証記録

実施前に記入する。

| 項目 | 記録 |
| --- | --- |
| 検証日 | |
| 担当者 | |
| Mac / macOS | |
| Xcode | |
| iPhone | |
| iOS | |
| Apple Development Team | |
| アプリBundle ID | |
| Widget Bundle ID | |
| App Group | |
| 対象コミット | |

各テストの結果は`OK`、`NG`、`未実施`のいずれかとし、NGには再現手順、Xcode consoleの時刻とログ、スクリーンショットを添付する。

## 1. 事前条件

- iOS 17.1以上のiPhoneと、対応するXcodeをインストールしたMacがある。
- 実機には猫写真を含むテスト可能な写真ライブラリがある。段階スキャン確認では静止画を501枚以上用意する。
- App Groups capabilityを利用できるApple Development Teamで署名できる。
- `Config.xcconfig`の3識別子を、そのTeamで一意な実値へ置き換えている。Widget Bundle IDはアプリBundle IDに`.widget`などの接尾辞を付け、App Groupは`group.`で始める。
- WindowsでのCSR／P12作成、Portal登録、2つの配布profile、GitHub Secretsは[Apple Developer署名・TestFlight準備](Apple-Developer署名準備.md)に従って完了している。
- テスト対象の写真はバックアップ済みである。アプリが写真原本を変更・複製しないことも確認対象とする。

## 2. Xcode設定とビルド

1. Xcodeでプロジェクトを開く。アプリtargetとWidget targetのDeployment TargetがともにiOS 17.1であることを確認する。
2. Debug / ReleaseのBase Configurationが`Config.xcconfig`を参照することを確認する。
3. アプリtargetのBundle IDが`$(APP_BUNDLE_IDENTIFIER)`、Widget targetが`$(WIDGET_BUNDLE_IDENTIFIER)`から展開されることを確認する。
4. Signing & Capabilitiesで両targetに同じTeamを設定する。
5. 両targetにApp Groups capabilityを追加し、`$(APP_GROUP_IDENTIFIER)`と同じGroupをチェックする。
6. アプリtargetのInfo.plist Fileが`NekoWidget/Info.plist`、Code Signing Entitlementsが`NekoWidget/NekoWidget.entitlements`であることを確認する。Widget targetにもそのtarget用のplistとentitlementsを設定する。
7. アプリInfoの写真読み書き説明、写真追加説明、`nekowidget` URL scheme、App Group識別子がBuild Settingsの変数を展開できることを確認する。
8. 実機を接続してアプリschemeを選び、Product > Clean Build Folder、続けてProduct > Buildを実行する。
9. Signing、entitlements、plistの警告がないことを確認し、Product > Runで実機へインストールする。
10. Build Logで`Assets.xcassets`と`AppIcon`が処理され、ホーム画面でプレースホルダーアイコンが表示されることを確認する。

期待結果：アプリが実機で起動し、Widget Extensionを含んだ状態で署名される。App Group entitlementの不一致や未登録によるインストール失敗がない。

## 3. Full Access

1. アプリを削除して再インストールし、初回の写真許可でFull Accessを選ぶ。
2. 許可文が用途を説明していることを確認する。
3. 初回スキャンを開始し、クラッシュ、UIフリーズ、大量のiCloudダウンロードがないことを確認する。
4. 「うちの子」アルバムを作成し、選別済みの元写真への参照が入ることを確認する。
5. 任意の写真で「これ好き」を切り替え、アプリの終了・再起動後も状態が残ることを確認する。

結果：`未実施`

メモ：

## 4. Limited Access

1. アプリを削除して再インストールするか、設定アプリの「プライバシーとセキュリティ」>「写真」>「猫が主役」でLimited Accessへ変更する。
2. 猫あり、猫なしを含む少数の写真だけを許可する。
3. 許可済みの範囲だけでスキャンと表示が動き、未許可assetの参照、空結果、削除済みassetでクラッシュしないことを確認する。
4. 「もっと写真を選ぶ」からlimited library pickerを開き、写真を追加する。
5. 再スキャンで対象範囲と結果が更新されることを確認する。
6. 設定アプリで許可済み写真を減らし、アプリへ戻って安全に状態が更新されることを確認する。

結果：`未実施`

メモ：

## 5. 段階スキャンと表示区分

1. 501枚以上の静止画へアクセスできる状態で、保存済みスキャン状態をリセットして起動する。
2. 新しい順に最大500枚を処理する第1段階が先に動くことをログと画面で確認する。
3. 起動後おおむね10秒以内に、猫の途中枚数、処理数、進捗と「速報」の表示が見えることを確認する。
4. 速報中は、全ライブラリの総数や最古日を確定値として表示しないことを確認する。
5. 全件処理の終了を待ち、状態が「確定」へ変わり、総数と最古日が表示されることを確認する。
6. アプリを終了・再起動し、確定状態と保存データが読み戻されることを確認する。
7. 写真ライブラリを変更してアプリを起動またはフォアグラウンドへ戻し、同期が始まることを確認する。バックグラウンド実行はOS裁量のbest effortであり、アプリを閉じたままの即時同期はNG判定にしない。

Simulatorの1,000枚スケールテストでは、アプリ起動から全件確定まで123.595秒、SharedLog上は119.630秒で、約8.1〜8.4枚／秒だった。これはCPU-only Visionと合成画像による参考値であり、実機の合否基準には使わない。実ライブラリで全件確定に数十分かかる可能性は既知であり、速報が操作継続に十分なら速度だけを理由にNGとしない。詳細は[ADR-002](ADR-002-全件スキャン速度と最適化保留.md)を参照する。

結果：`未実施`

速報までの秒数：

500枚完了までの秒数：

全件確定までの時間：

対象写真総数／ローカル／iCloud：

平均枚数／秒：

端末温度・バッテリー・UI応答性：

## 6. アルバムと写真シャッフルの再設定

1. アプリで「うちの子」アルバムを作成・更新する。
2. 写真アプリで、アルバムに選別済みの元写真が入り、原本そのものが変更されていないことを確認する。
3. 設定アプリの「壁紙」>「新しい壁紙を追加」>「写真シャッフル」でアルバムを選び、「うちの子」を指定する。
4. ロックと解除を繰り返し、設定時点の写真が候補になることを確認する。
5. アプリへ戻り、「うちの子」アルバムへ新しい写真が入るよう更新する。
6. 既存の写真シャッフルでは追加分が自動追従しないことを確認する。
7. 写真シャッフルでアルバムを選び直すか壁紙を作り直し、更新後の集合が候補になることを確認する。
8. アプリ内に「アルバム更新後は写真シャッフルの再設定が必要」と誤解なく表示されることを確認する。

結果：`未実施`

メモ：

## 7. Widget 3サイズと共有データ

1. アプリでスキャンとキャッシュ生成を完了させる。
2. ホーム画面を長押しし、Small、Medium、Largeのウィジェットを1つずつ追加する。
3. 3サイズすべてで専用画像が表示されることを確認する。通常は端まで鮮明なfull-bleed、Small / Largeは猫union＋余白を保持し、収容不能時だけ猫全体＋同写真ぼかし、Mediumは収容不能時もbbox上寄りfull-bleedとする。黒帯、空白、回転、反転、伸長がないことも確認する。
4. 写真なし、manifestなし、壊れたキャッシュまたは参照先削除の各状態で、プレースホルダーまたは空表示へ安全にフォールバックすることを確認する。
5. アプリで選別結果を更新し、Widgetが更新後のApp Group内manifestと画像を読めることを確認する。

結果：`未実施`

Small：
Medium：
Large：

## 8. 20分タイムライン

1. Xcodeのconsoleまたはデバッガで、1回のtimeline生成が未来の15〜20件を返すことを確認する。
2. entryの日付が既定20分間隔で並び、最後のentry後に`.atEnd`で次回timelineを要求することを確認する。
3. iPhoneを通常利用しながら数時間観察し、同一timeline内で表示写真がbest effortに切り替わることを確認する。
4. アプリのデータ更新後にtimeline reloadが要求されることを確認する。

WidgetKitの更新時刻はOS裁量である。20分ちょうどに切り替わらないこと自体はNGにしない。entry数不足、全entryが同一日時、次回要求なし、または長時間一度も候補が変わらない場合はログを採取する。

結果：`未実施`

観察開始 / 終了：

確認した切り替わり回数：

## 9. Deep Link

1. アプリを前面にした状態でWidgetをタップし、対象写真の詳細と「これ好き」が開くことを確認する。
2. アプリを背面にして同じ確認を行う。
3. アプリを終了して同じ確認を行う。
4. IDにURLエンコードが必要な文字が含まれても、`nekowidget://photo?id=<encoded localIdentifier>`が正しく復元されることを確認する。
5. IDなし、不明ID、アクセス権を失ったIDでクラッシュせず、安全な画面へ戻ることを確認する。

結果：`未実施`

メモ：

## 10. Widgetのメモリ

1. 高解像度の原写真を含む状態で、本体アプリにWidgetキャッシュを作らせる。
2. App Groupコンテナを確認し、派生JPEGがSmall 400×400px、Medium 800×374px、Large 400×420pxで各50KiB以下であること、manifestが3サイズの画像ファイル名を参照していることを確認する。
3. Widgetを表示し、XcodeのDebug > Attach to Process by PID or NameからWidget ExtensionプロセスへAttachする。
4. Debug NavigatorのMemoryを記録し、Small / Medium / Largeの追加、timeline更新、アプリ側のデータ更新を繰り返す。
5. メモリがおおむね30MBの制約内に収まり、継続増加、Jetsam、クラッシュがないことを確認する。判断が難しい場合はInstrumentsのAllocationsで再試験する。
6. Widget側でPhotoKit、Vision、クロップ処理が実行されず、TimelineEntryがJPEG Dataや画像オブジェクトを保持せず、現在の1枚だけを読み込むことをログまたはコードと合わせて確認する。
7. 「これ好き」の連続操作や再スキャンを繰り返し、旧timelineの表示が途中で空にならないこと、`widget-cache`が最大480ファイルを超えて増え続けないことを確認する。

結果：`未実施`

| 操作 | メモリ | 備考 |
| --- | ---: | --- |
| 初回表示 | | |
| Small / Medium / Large表示 | | |
| timeline更新後 | | |
| アプリ側データ更新後 | | |

## 11. App／Widget共通の診断ログ

1. 設定タブから「診断ログを見る」を開き、アプリの起動、権限、スキャン進捗、Vision集計が表示されることを確認する。
2. Widgetを追加または再表示した後に「更新」を押し、`widget/timeline`、`widget/manifest`、`widget/image`の行がアプリ側の行と時刻順に統合されることを確認する。
3. 画像ログに圧縮バイト数、出力ピクセル数、推定デコードバイト数があり、写真そのもの、PhotoKitの識別子全文、絶対ファイルパスが含まれないことを確認する。
4. 「コピー」で表示内容をペーストでき、「共有」で`.txt`をAirDrop、ファイル、メール等へ渡せることを確認する。
5. 「消去」後に既存行が消え、次のアプリ／Widgetイベントから新しいログが安全に作られることを確認する。
6. Widgetが落ちた場合は直前のファイルログに加え、TestFlightのクラッシュレポートまたはXcode Organizerのクラッシュ／Jetsam情報も保存する。ファイルログだけでOSのクラッシュスタックを代替できるとは判定しない。

結果：`未実施`

ログ共有ファイル名：

メモ：

## 12. 最終判定

- [ ] iOS 17.1以上でビルド・署名・実機インストールできた
- [ ] Full Accessで主要機能が動いた
- [ ] Limited Accessでクラッシュせず「もっと写真を選ぶ」が使えた
- [ ] 速報と確定が明確に分離された
- [ ] 「うちの子」アルバムを作成・更新できた
- [ ] 写真シャッフルの再設定案内が正しかった
- [ ] WidgetのSmall / Medium / Largeが表示された
- [ ] 15〜20件、既定20分間隔のtimelineを確認した
- [ ] Widgetから正しい写真へDeep Linkできた
- [ ] Small 400×400px、Medium 800×374px、Large 400×420pxで各50KiB以下のキャッシュを確認した
- [ ] Widgetのメモリ急増とクラッシュがなかった
- [ ] App Group共有と「これ好き」の永続化を確認した
- [ ] AppとWidgetの診断ログを統合表示、コピー、共有、消去できた
- [ ] プレースホルダーApp Iconがarchiveへ含まれた

総合結果：`未実施`

残課題：
