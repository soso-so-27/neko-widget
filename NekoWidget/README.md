# ねこのまど v1

端末の写真ライブラリをオンデバイスで調べ、猫が主役の写真を選別するiOS 17.1以上向けSwiftUIアプリです。選別結果は「うちの子」アルバムと、Small / Medium / LargeのWidgetKitウィジェットへ渡します。「これ好き」の記録はApp Group内へ永続化します。

## 現在の引き継ぎ状態

ソースはWindows上で作成しています。GitHub ActionsではXcodeコンパイル、Simulator上の起動・PhotoKit・Vision・App Groupスモークテスト、1,000枚のスケール／メモリテストまで成功しています。iPhoneではBuild 7までの技術検証に加え、Build 8のMedium / Large表示不具合まで確認し、8,861枚の確定スキャンとdetected無作為100枚のレビューを完了しました。レビューは`reviewNo 74`だけを製品候補から除外し、99 / 100を採用しました。scannerはBuild 10でも変更しないため、このPrecision標本は再利用します。Build 7の1週間計測はLike表示不具合で中断し、その再計測案も「結果が製品判断を変えない」として2026-08-17に撤回しました。新しいbaselineから再開する予定はなく、特定端末へ別buildを入れない制約もありません。Build 8では高解像度20件TimelineによりMedium / Largeがplaceholder相当になる不具合を確認し、Build 9でTimelineを最大2件へ制限、Build 10で写真ブラウザの標準ページングを修復しました。3サイズ、like／unlike即時反映、写真ブラウザの操作感は通常の機能ゲートとして実機確認します。Build 10の写真ブラウザが固まる場合は、待たずに遅延pagingを含む開発branchのbuildを同じ端末へ入れて確認します。実施順は[実機技術検証チェックリスト](docs/実機技術検証チェックリスト.md)、Like修復は[ADR-007](docs/ADR-007-Build8計測修復と最終UX.md)、Timeline修復は[ADR-008](docs/ADR-008-高解像度WidgetのTimeline負荷制限.md)、アルバム／共有は[ADR-009](docs/ADR-009-ローカルアルバムと招待制共有.md)、898件の遅延pagingは[ADR-010](docs/ADR-010-大規模写真ブラウザの遅延ページング.md)、うちの子の選別と将来の個体推定は[ADR-011](docs/ADR-011-うちの子の選別と将来の個体推定.md)、多頭プロフィールと安全な移行は[ADR-012](docs/ADR-012-多頭identity基盤と安全な移行.md)、関節点を使わないbbox姿勢アルバムは[ADR-013](docs/ADR-013-bbox姿勢アルバム.md)で管理します。

アプリ名「ねこのまど」に合わせ、窓の開口が二度見ると猫耳に見えるC5 Softを正式App Iconとして採用しています。紙色`#F2E8D5`と墨色`#2A2521`の2色フラットで、1024×1024px・不透明RGBのAsset Catalogを含みます。編集用の形状正本は[`docs/design/AppIcon-P1-master.svg`](docs/design/AppIcon-P1-master.svg)です。一般公開前には商標と実機上の視認性を最終確認してください。

写真シャッフルには、指定時点のアルバム内容がスナップショットとして取り込まれます。アルバムへ後から追加した写真は自動反映されないことを実機スパイクで確認済みです。判断の記録は[ADR-001](docs/ADR-001-写真シャッフルのアルバム追従.md)にあります。アルバム生成は維持し、ウィジェットを主要な継続表示先とします。

WidgetはAppleの壁紙と美しさで競わず、写真をタップして「これ好き」へ進む導線を担います。Build 5の常設ぼかしは実機で没入感不足と判定し、現行は検出済み猫union＋8%余白を守るfamily別full-bleedです。Small / Largeの収容不能時だけ既存ぼかしへfallbackし、Mediumはbbox上側を焦点にします。Build 8では実ピクセル相当の`500×500 / 1050×500 / 1050×1100`へ上げ、約20pxでも猫と分かる独自`CatPawMark`へ置き換えました。Build 9ではこの画質を保ち、20件のmanifestから時刻基準で最大2件だけをTimelineへ渡します。Build 10は写真ブラウザの標準ページングだけを修復し、Widgetの構図や選別を変えません。Subject Lifting、新しい背景ぼかし、Mediumの2枚化、saliency、顔・構図理解、新しい選別軸は実装しません。招待制共有は[ADR-009](docs/ADR-009-ローカルアルバムと招待制共有.md)に従ってローカルアルバムの後に別段階で実装します。履歴は[ADR-003](docs/ADR-003-Widget表示品質のBuild5範囲.md)、表示判断は[ADR-005](docs/ADR-005-Widget猫優先full-bleed.md)と[ADR-007](docs/ADR-007-Build8計測修復と最終UX.md)、resource修復は[ADR-008](docs/ADR-008-高解像度WidgetのTimeline負荷制限.md)にあります。

Build 5とBuild 6は技術検証専用です。Build 6では3サイズの右下へ輪郭／塗りつぶしの肉球ボタンを追加し、アプリを開かずに好き／解除をApp Groupへ記録します。Widget専用App IntentはSiriやショートカットへ公開しません。Build 7でfull-bleedとランダム100枚を確認し、同buildで始めた1週間計測はアプリ側の表示通知不具合により中断しました。再計測案は2026-08-17に撤回済みです。Build 8では共有Likeストアの即時反映を修復しましたが、Medium / Largeの表示ゲートが失敗しました。Build 9で最大2件Timelineを導入し、Build 10で写真ブラウザの標準ページングを修復しました。Build 10上の3サイズ表示、押下／解除のアプリ即時反映、写真ブラウザの初期表示とスワイプは、計測開始条件ではなく通常の機能確認として実施します。肉球と過去の計測境界は[ADR-004](docs/ADR-004-Widget肉球ボタンとBuild6計測.md)、Like修復は[ADR-007](docs/ADR-007-Build8計測修復と最終UX.md)、Timeline修復は[ADR-008](docs/ADR-008-高解像度WidgetのTimeline負荷制限.md)にあります。

1,000枚スケールテストでは全件確定まで123.595秒、約8.1枚／秒でした。実ライブラリでは数十分かかる可能性を認識したうえで、速報値と確定値の分離を維持し、実機実測まで速度最適化を保留します。判断の記録は[ADR-002](docs/ADR-002-全件スキャン速度と最適化保留.md)にあります。

実機8,861枚のうちScreenshot 736枚と`unavailableLocally` 2,586枚を除く解析済みは5,539枚で、猫898枚は解析済み集合の16.2%です。Deferredにも同率で猫がいる単純仮定では未発見約419枚、潜在約1,317枚、観測率約68.2%になります。現行の`unavailableLocally`は1024px high-quality requestをローカルだけで満たせなかった意味であり、低解像度ローカル派生も存在しないとはまだ断定しません。Build 10にはdownload処理やscanner request変更を入れていません。512px fast-formatの非破壊probeは、1週間の待機条件なしで、準備できたInternal技術検証buildから実行できます。採用時だけ後続production buildへ反映する方針を[ADR-006](docs/ADR-006-iCloudローカル派生画像の検証.md)へ記録しています。

## 登録済み識別子

`Config.xcconfig`にはApple Developer Portalへ登録済みの次の値があります。

| 用途 | 変数 | 登録済みの値 |
| --- | --- | --- |
| アプリ | `APP_BUNDLE_IDENTIFIER` | `jp.nekowidget.app` |
| Widget Extension | `WIDGET_BUNDLE_IDENTIFIER` | `jp.nekowidget.app.widget` |
| 共有コンテナ | `APP_GROUP_IDENTIFIER` | `group.jp.nekowidget.app` |

識別子を変更する場合は、Developer Portal、配布プロファイル、`Config.xcconfig`を同時に更新してください。命名と登録の記録は[TestFlight準備手順](docs/Apple-Developer署名準備.md)を参照してください。

## Mac / Xcodeでの設定

1. Macへリポジトリを取得し、`NekoWidget.xcodeproj`を開きます。2026年4月28日以降にTestFlightへアップロードするarchiveはXcode 26以上で作成します。アプリtarget `NekoWidget`とWidget Extension target `NekoWidgetWidgetExtension`が表示されることを確認します。
2. Debug / ReleaseのBase Configurationに`Config.xcconfig`を設定します。両targetのDeployment Targetが`17.1`であることを確認します。
3. アプリtargetのProduct Bundle Identifierを`$(APP_BUNDLE_IDENTIFIER)`、Widget targetを`$(WIDGET_BUNDLE_IDENTIFIER)`にします。
4. アプリtargetではInfo.plist Fileを`NekoWidget/Info.plist`、Code Signing Entitlementsを`NekoWidget/NekoWidget.entitlements`にします。Widget targetにも同様に、そのtarget用のInfo.plistとentitlementsを割り当てます。手書きのplistを使うtargetではGenerate Info.plist Fileを`No`にします。
5. Signing & Capabilitiesで、アプリとWidgetの両targetへ同じApple Development Teamを設定します。両方へApp Groups capabilityを追加し、`$(APP_GROUP_IDENTIFIER)`の展開後と同じGroupを有効にします。Apple Developer側に存在しない場合は、この時点で登録します。
6. ビルド設定を展開表示し、`APP_BUNDLE_IDENTIFIER`、`WIDGET_BUNDLE_IDENTIFIER`、`APP_GROUP_IDENTIFIER`が期待する実値になっていることを両targetで確認します。アプリのInfoとentitlementsが同じApp Groupを参照していない状態では共有データを読めません。
7. `nekowidget` URL schemeがアプリtargetのInfoに入っていることを確認します。Build 6の非公開Widget App IntentはAppとWidgetの両targetへ含めますが、Siri / ショートカット連携は追加しません。
8. 実機を接続し、Developer Modeと端末上の開発者信頼を必要に応じて有効にして、アプリschemeを選びRunします。

## GitHub Actions

push / pull requestでは`iOS build check`を実行します。最初のジョブはmacOS runner上でAppとWidgetを無署名コンパイルします。成功後のSimulatorジョブはiOS 18.6 Simulator上でXCUITestを使い、アプリの写真許可ボタンから実際のシステムダイアログを開いてフルアクセスを許可します。その時点の写真IDをbaselineとして保存してから、[専用に生成したCC0の猫画像3枚](ci/fixtures/cats/README.md)を写真ライブラリへ投入し、本試験としてアプリを通常起動します。`simctl addmedia`の画像resource準備が遅れる場合は、時間上限付きでアプリを再起動して再スキャンします。baselineとの差分3件についてPhotoKit取得とVision分類を確認し、App GroupへのJSONLログ／snapshot／Widget cache書き込みも検証します。権限テスト結果、起動画面、SharedLog、統合ログ、検証レポート、App Group成果物は7日間artifactに保存します。GitHub Hosted SimulatorのiOS 18.6／26.2では、`simctl privacy grant photos`が成功しTCCへ許可行を保存してもPhotoKitの`.readWrite`判定が未決定のままになる挙動を確認したため、実際のダイアログを操作する方式を採用しています。最新OSの権限フローは別途実機で確認します。この自動テストはフルアクセス許可フローだけが対象で、拒否／制限付きアクセス、ホーム画面へ配置したWidgetプロセスからの読み出しも実機確認の対象です。

TestFlight配布は手動起動専用の`Archive and upload to TestFlight`を使います。最初は`upload_to_testflight = false`で署名archiveとIPA exportだけを検証し、成功後にtrueへ切り替えてApp Store Connectでの検証とアップロードを行います。実uploadでは`retain_signed_artifacts = true`とし、一致するIPA、xcarchive、dSYMを暗号化artifactで回収します。

### Simulatorスケールテスト

`iOS Simulator scale test`はGitHub Actionsの手動実行専用です。Actionsタブでこのworkflowを選び、`Run workflow`から写真数1,000（既定）、2,000、3,000のいずれかを選びます。CI中に既存のCC0猫画像3枚から、ファイル名と実画素が異なるJPEGを一時生成します。合計枚数には8000×6000px（48MP）の画像3枚を含みます。生成JPEGはrunnerの一時領域だけに置き、Gitやartifactには保存しません。代わりに各画像のSHA-256、寸法、容量、役割、CC0系譜をmanifestへ記録します。

権限付与とbaseline保存後、全画像を`simctl addmedia`で投入し、測定中はアプリを同一PIDで一度だけ起動します。最終snapshotの`completed / final`、投入枚数と解析結果、起動から完了までとスキャン自体の所要時間、プロセスの現在physical footprint／生涯ピーク／RSSを検証します。48MP画像の開始・サムネイル解決・完了ログと100ms間隔のメモリCSVを時刻で突き合わせ、大画像区間の増分も判定します。既定の退行検出閾値は生涯ピーク512MiB、48MP区間の生涯ピーク増分128MiBです。途中終了、PID再利用、閾値超過、クラッシュや`JetsamEvent` / `EXC_RESOURCE`の候補があれば失敗し、詳細を`scale-report.json`とartifactへ残します。

SimulatorではiPhoneのメモリ警告やOOM終了が再現されないため、この合格は実機jetsamに対する安全証明ではありません。ここで防ぐのは、スキャンの未完了、明白なプロセス終了、物理メモリの退行、48MP画像の全解像度デコード相当のスパイクです。Appleも、SimulatorではmacOSがメモリ警告やOOM終了を発行せず、緑表示でも実機の安全範囲とは限らないと説明しています。実機では[Xcodeのメモリ計測](https://developer.apple.com/documentation/xcode/gathering-information-about-memory-use)とjetsamレポートで最終確認します。

2026-08-16に1,000枚を1回実行し、全件完走、lifetime physical footprint 76.147MiB、48MP区間の生涯ピーク増分0.344MiB、途中終了とクラッシュ痕跡なしでPASSしました。2,000枚／3,000枚は実行していません。

App Store Connect APIキーはアップロード認証用です。コード署名には別途、Apple Distribution証明書の秘密鍵を含むP12と、アプリ／Widgetそれぞれの配布プロファイルが必要です。必要なGitHub Environment、Secrets、作成手順は[GitHub Actions / TestFlight設定](docs/GitHub-Actions-TestFlight設定.md)を参照してください。

## 診断ログ

アプリとWidget Extensionは、App Group内の同じ`diagnostic-logs`ディレクトリへプロセス／起動セッション別のJSONLログを書きます。設定タブの「診断ログを見る」では、両方のログを時刻順に統合して閲覧、更新、コピー、共有、消去できます。スキャン進捗、Visionの集計、画像の圧縮・デコードサイズ、manifest／timeline、PhotoKit・ファイル処理のエラーを記録します。

写真そのもの、PhotoKitの`localIdentifier`全文、ファイルの絶対パスは記録しません。識別が必要な箇所では短い非可逆ハッシュだけを使います。ファイルログはWidgetが終了する直前までの手掛かりを残すもので、JetsamやOSが生成するクラッシュスタックそのものは取得できません。TestFlightのクラッシュレポートやXcode Organizerと併用してください。

## 実機確認の要点

### 写真アクセス：full / limited

- Full Accessでは写真の読み書きを許可し、スキャン、アルバム作成・更新、「これ好き」の永続化を確認します。
- Limited Accessでは数枚だけを選び、許可済みの写真だけで動作し、クラッシュしないことを確認します。「もっと写真を選ぶ」から選択範囲を増やし、再スキャン結果が更新されることも確認します。
- 権限ケースを切り替えるときは、設定アプリの「プライバシーとセキュリティ」>「写真」から変更します。初回許可画面をやり直す必要があればアプリを削除して再インストールします。

### 段階スキャン

- 写真が500枚を超えるライブラリで起動し、最新から最大500枚の第1段階が開始されることを確認します。
- 起動後おおむね10秒以内に、処理数と猫の枚数が「速報」と明示されることを確認します。速報中は全体の総数や最古日を確定値として表示してはいけません。
- 全件処理後に表示が「確定」へ変わり、総数と最古日が出ることを確認します。アプリを再起動しても状態が破損しないことを確認します。
- 同期は起動時とフォアグラウンド復帰時を確実な経路とします。バックグラウンド実行はOS裁量のbest effortであり、閉じたまま即時同期することは受け入れ条件にしません。

### アルバムと写真シャッフル

- 「うちの子」アルバムを作成・更新し、元の`PHAsset`が入ることを確認します。壁紙用の猫中心クロップは作りません。Widgetは猫union＋余白を基準にfamily別full-bleedを事前合成し、Small / Largeの収容不能時だけぼかしへfallbackします。
- iPhoneの壁紙設定で写真シャッフルに「うちの子」アルバムを指定します。
- その後アプリからアルバム内容を更新しても、既存の写真シャッフルには追加分が自動反映されないことを確認します。
- 新しい内容を壁紙へ反映するには、写真シャッフル側で「うちの子」アルバムを選び直すか、写真シャッフル壁紙を作り直します。アプリ内にもこの再設定案内が表示されることを確認します。

### Widget 3サイズ、タイムライン、Deep Link

- ホーム画面へSmall / Medium / Largeを1つずつ追加し、各サイズ専用のfull-bleed、Small / Largeの例外的ぼかしfallback、Mediumのbbox上寄り、プレースホルダー、空データ時の表示を確認します。
- manifestに最大20件の候補があり、providerが時刻基準の現在＋次の最大2件だけを返すことを確認します。既定20分後に2件目へ切り替わり、その次の境界で新しいTimelineを要求します。WidgetKitの実行時刻はOS裁量であり、正確な20分更新は受け入れ条件にしません。
- アプリが前面、背面、終了中の各状態でウィジェットをタップし、`nekowidget://photo?id=...&shownAt=...`から該当写真の詳細が開くことを確認します。大きな写真、左右スワイプ、肉球、撮影日、「この日の写真をすべて見る」、約20分ごとの切り替えと最後に変わった時刻が表示され、「次へ」ボタンがないことも確認します。
- 3サイズの右下に肉球があり、輪郭→塗りつぶし→輪郭と切り替わること、処理中表示、アプリを開かないこと、肉球以外の領域では従来のDeep Linkが働くことを確認します。
- データ更新後に新しいtimelineが要求され、共有manifestとキャッシュをWidgetが読めることを確認します。

### Widgetのメモリ

- 大きな原写真を含むライブラリで確認します。本体は2048×2048のlocal-only high-quality入力から、Small 500×500px／100KiB以下、Medium 1050×500px／200KiB以下、Large 1050×1100px／220KiB以下を作ります。Widget側でPhotoKit / Vision / クロップ／ぼかしを実行していないことを確認します。
- XcodeのDebug NavigatorでWidget ExtensionプロセスへAttachし、複数回の更新中もメモリがおおむね30MBの制約内に収まり、急増やクラッシュがないことを観察します。必要ならInstrumentsのAllocationsも併用します。
- TimelineEntryへJPEG Dataや画像オブジェクトを保持せず、1回のTimelineを最大2件へ制限します。1枚の推定デコード量が5MiB以下、2件合計がfamilyごとに10MiB以下であることを確認します。cacheは最大8 generation／400ファイルで、全件を220KiBと置いた保守上限は約85.9MiBです。キャッシュとmanifestの更新途中の状態が見えないことも確認します。

検証日時、端末、iOS / Xcodeバージョン、権限モード、結果とログは[実機技術検証チェックリスト](docs/実機技術検証チェックリスト.md)へ記録してください。Macで直接デバッグする場合の手順は[Mac実機検証手順](docs/Mac実機検証手順.md)を参照してください。
