# 猫ウィジェット v1

端末の写真ライブラリをオンデバイスで調べ、猫が主役の写真を選別するiOS 17.1以上向けSwiftUIアプリです。選別結果は「うちの子」アルバムと、Small / Medium / LargeのWidgetKitウィジェットへ渡します。「これ好き」の記録はApp Group内へ永続化します。

## 現在の引き継ぎ状態

ソースはWindows上で作成しています。GitHub ActionsではXcodeコンパイルとSimulator上の起動・PhotoKit・Vision・App Groupスモークテストを実行しますが、配布署名、iPhoneへのインストール、Widgetの実配置およびメモリ使用量は未検証です。MacとiOS 17.1以上のiPhoneで、[実機検証手順](docs/Mac実機検証手順.md)を最後まで実施してください。

TestFlightで最初の配布確認を行えるよう、1024×1024pxのプレースホルダーApp IconとAsset Catalogを含めています。正式公開前には、商標・視認性・各外観での見え方を確認した最終アイコンへ差し替えてください。

写真シャッフルには、指定時点のアルバム内容がスナップショットとして取り込まれます。アルバムへ後から追加した写真は自動反映されないことを実機スパイクで確認済みです。判断の記録は[ADR-001](docs/ADR-001-写真シャッフルのアルバム追従.md)にあります。アルバム生成は維持し、ウィジェットを主要な継続表示先とします。

## 仮の識別子

`Config.xcconfig`には次の仮値があります。

| 用途 | 変数 | 仮値 |
| --- | --- | --- |
| アプリ | `APP_BUNDLE_IDENTIFIER` | `com.example.nekowidget` |
| Widget Extension | `WIDGET_BUNDLE_IDENTIFIER` | `com.example.nekowidget.widget` |
| 共有コンテナ | `APP_GROUP_IDENTIFIER` | `group.com.example.nekowidget` |

Macで署名する前に、3つとも利用するApple Development Teamで一意な値へ変更します。WidgetのBundle IDはアプリのBundle IDに`.widget`などの接尾辞を付けた値にし、App Groupは先頭の`group.`を維持してください。

## Mac / Xcodeでの設定

1. Macへリポジトリを取得し、`NekoWidget.xcodeproj`を開きます。2026年4月28日以降にTestFlightへアップロードするarchiveはXcode 26以上で作成します。アプリtarget `NekoWidget`とWidget Extension target `NekoWidgetWidgetExtension`が表示されることを確認します。
2. Debug / ReleaseのBase Configurationに`Config.xcconfig`を設定します。両targetのDeployment Targetが`17.1`であることを確認します。
3. アプリtargetのProduct Bundle Identifierを`$(APP_BUNDLE_IDENTIFIER)`、Widget targetを`$(WIDGET_BUNDLE_IDENTIFIER)`にします。
4. アプリtargetではInfo.plist Fileを`NekoWidget/Info.plist`、Code Signing Entitlementsを`NekoWidget/NekoWidget.entitlements`にします。Widget targetにも同様に、そのtarget用のInfo.plistとentitlementsを割り当てます。手書きのplistを使うtargetではGenerate Info.plist Fileを`No`にします。
5. Signing & Capabilitiesで、アプリとWidgetの両targetへ同じApple Development Teamを設定します。両方へApp Groups capabilityを追加し、`$(APP_GROUP_IDENTIFIER)`の展開後と同じGroupを有効にします。Apple Developer側に存在しない場合は、この時点で登録します。
6. ビルド設定を展開表示し、`APP_BUNDLE_IDENTIFIER`、`WIDGET_BUNDLE_IDENTIFIER`、`APP_GROUP_IDENTIFIER`が期待する実値になっていることを両targetで確認します。アプリのInfoとentitlementsが同じApp Groupを参照していない状態では共有データを読めません。
7. `nekowidget` URL schemeがアプリtargetのInfoに入っていることを確認します。v1でApp Intent / ショートカット連携は追加しません。
8. 実機を接続し、Developer Modeと端末上の開発者信頼を必要に応じて有効にして、アプリschemeを選びRunします。

## GitHub Actions

push / pull requestでは`iOS build check`を実行します。最初のジョブはmacOS runner上でAppとWidgetを無署名コンパイルし、成功後のSimulatorジョブは[専用に生成したCC0の猫画像3枚](ci/fixtures/cats/README.md)を写真ライブラリへ投入します。ジョブはiOS 18.6 Simulatorを明示的に使い、DEBUG限定の起動引数で通常のPhotoKit権限要求を開始した後、`simctl privacy`で許可し、Simulatorを再起動してから本試験としてアプリを起動します。PhotoKit取得、Vision猫検出、App GroupへのJSONLログ／snapshot／Widget cache書き込みを検証し、起動画面、SharedLog、統合ログ、検証レポート、App Group成果物を7日間artifactに保存します。GitHub Hosted SimulatorのiOS 18.6／26.2では要求前の`simctl privacy`だけではPhotoKitの読み書き権限が未決定のままになる挙動を確認したため、この順序を採用しています。最新OSの権限フローは別途実機で確認します。この自動テストは許可済みフローだけが対象で、拒否／制限付きアクセス、ホーム画面へ配置したWidgetプロセスからの読み出しも実機確認の対象です。

TestFlight配布は手動起動専用の`Archive and upload to TestFlight`を使い、archive、IPA export、App Store Connectでの検証とアップロードを行います。

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

- 「うちの子」アルバムを作成・更新し、元の`PHAsset`が入ることを確認します。壁紙用の猫中心クロップは作らず、クロップはアプリとウィジェットの表示だけに適用します。
- iPhoneの壁紙設定で写真シャッフルに「うちの子」アルバムを指定します。
- その後アプリからアルバム内容を更新しても、既存の写真シャッフルには追加分が自動反映されないことを確認します。
- 新しい内容を壁紙へ反映するには、写真シャッフル側で「うちの子」アルバムを選び直すか、写真シャッフル壁紙を作り直します。アプリ内にもこの再設定案内が表示されることを確認します。

### Widget 3サイズ、タイムライン、Deep Link

- ホーム画面へSmall / Medium / Largeを1つずつ追加し、各サイズで猫が主役になるクロップ、プレースホルダー、空データ時の表示を確認します。
- manifestに15〜20件の未来エントリがあり、既定20分間隔の日時になっていることを確認します。数時間置いて表示の切り替わりを確認しますが、WidgetKitの実行時刻はOS裁量であり、正確な20分更新は受け入れ条件にしません。
- アプリが前面、背面、終了中の各状態でウィジェットをタップし、`nekowidget://photo?id=...`から該当写真の詳細と「これ好き」が開くことを確認します。
- データ更新後に新しいtimelineが要求され、共有manifestとキャッシュをWidgetが読めることを確認します。

### Widgetのメモリ

- 大きな原写真を含むライブラリで確認します。ウィジェットへ渡すJPEGが400×400px、目安50KB以下であり、Widget側でPhotoKit / Vision / クロップを実行していないことを確認します。
- XcodeのDebug NavigatorでWidget ExtensionプロセスへAttachし、複数回の更新中もメモリがおおむね30MBの制約内に収まり、急増やクラッシュがないことを観察します。必要ならInstrumentsのAllocationsも併用します。
- TimelineEntryへJPEG Dataや画像オブジェクトを保持せず、表示中の1枚だけを読み込むこと、キャッシュとmanifestの更新途中の状態が見えないことを確認します。

検証日時、端末、iOS / Xcodeバージョン、権限モード、結果とログは[Mac実機検証手順](docs/Mac実機検証手順.md)の記録欄へ残してください。
