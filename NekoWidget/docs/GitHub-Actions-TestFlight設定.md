# GitHub Actions / TestFlight設定

## 役割分担

3つのworkflowをリポジトリルートの`.github/workflows`に置いている。

- `ios-build.yml`：push、pull request、手動実行で、AppとWidgetをiOS Simulator向けに無署名ビルドする。これはSwiftのコンパイル検査であり、実機用entitlementや配布署名の正しさまでは保証しない。
- `ios-scale.yml`：手動実行で、1,000〜3,000枚のSimulatorスケールテストとプロセスメモリ計測を行う。通常は繰り返し実行しない。
- `testflight.yml`：`workflow_dispatch`からだけ起動し、Release archive、署名とApp Group entitlementの検査、IPA exportを行う。既定の`review-preview`と、明示的に選んだときだけ使える`pairing-only`を分離する。`upload_to_testflight`がtrueのときだけApp Store Connectで検証し、TestFlightへuploadする。GitHub Environment `testflight`を使う。

2026年4月28日以降のアップロード要件に合わせ、3つとも`macos-15` runner上のXcode 26.3を明示している。runnerからこのXcodeが削除された場合は、GitHub runner imageの一覧とAppleの提出要件を確認して`DEVELOPER_DIR`を更新する。

## APIキーとコード署名は別物

このworkflowでApp Store Connect APIキーを使うのは、完成したIPAをApp Store Connectへ認証付きで検証・アップロードする段階である。APIキーの`.p8`だけをApple Distributionのコード署名秘密鍵として使うことはできない。

再現可能なheadless CIにするため、署名には次も明示的にインストールする。

1. Apple Distribution証明書と対応する秘密鍵を含むP12
2. アプリBundle ID用のApp Store Connect配布プロファイル
3. Widget Bundle ID用のApp Store Connect配布プロファイル

2つのプロファイルは、同じTeam、正しいBundle ID、同じApp Group entitlementを持つ必要がある。workflowはarchive前にこれらを検査する。

Xcode 26向けには、プロファイルを現在の保存先である`~/Library/Developer/Xcode/UserData/Provisioning Profiles`へ一時配置し、job終了時に削除する。

Xcode Organizerの対話的配布ではクラウド管理証明書を利用できる場合があるが、このworkflowはそれを前提にしない。Apple Developer Programの権限やクラウド署名設定だけに依存してP12とプロファイルを省略する変更は、実際のTeamで別途検証してから行う。

WindowsとOpenSSLで秘密鍵、CSR、P12を作る具体的な手順、ID決定表、承認後のPortal操作は[Apple Developer署名・TestFlight準備](Apple-Developer署名準備.md)を正本とする。

## Apple側の準備

1. Apple Developer Programへ登録し、契約を有効にする。
2. アプリ、Widget、Share Extensionの明示的App IDを登録する。
3. App Groupを登録し、3つのApp IDで有効にする。
4. Apple Distribution証明書を作り、Windowsで保持する対応秘密鍵と証明書をP12へまとめる。
5. アプリ、Widget、Share Extensionそれぞれに`App Store Connect`配布プロファイルを作る。3つすべてで手順3のApp Groupが有効であり、手順4の証明書が含まれることを確認する。
6. App Store Connectにアプリレコードを作る。アップロードするBundle IDと一致させる。
7. App Store Connectの「ユーザとアクセス」>「統合」で、アップロード権限を持つteam API keyを作る。Key ID、Issuer ID、1度だけダウンロードできる`.p8`を安全に保管する。
8. `Config.xcconfig`のアプリ、Widget、Share Extension、App Groupの4つのIDがPortalの登録値と完全一致していることを確認する。

API keyにはbuild upload可能なroleが必要である。本プロジェクトでは最小権限としてTeam Keyの`Developer` roleを使う。Team Keyは特定アプリだけに限定できない。契約が未承認、アプリレコードが未作成、Bundle IDが不一致、または同じbuild numberがすでに存在する場合、署名が成功してもアップロードは失敗する。

## GitHub EnvironmentとSecrets

GitHubリポジトリのSettings > Environmentsで`testflight`を作る。Deployment branch/tagは`main`だけに必ず制限し、別reviewerがいる場合はRequired reviewersも設定する。一人運用で別reviewerがいない間は`Prevent self-review`を有効にしない。以下はRepository SecretsではなくEnvironment Secretsとして置くと、承認前にはjobから参照できない。

| Secret | 内容 |
| --- | --- |
| `APPLE_TEAM_ID` | Apple Developer Team ID（10文字） |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect team API Key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect API Issuer ID |
| `APP_STORE_CONNECT_PRIVATE_KEY_BASE64` | `AuthKey_XXXXXXXXXX.p8`のファイル全体をBase64化した値 |
| `APPLE_DISTRIBUTION_CERTIFICATE_BASE64` | 秘密鍵を含む配布用P12のファイル全体をBase64化した値 |
| `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD` | P12を書き出したときのパスワード |
| `KEYCHAIN_PASSWORD` | CIの一時Keychain専用に作った十分長いランダム値 |
| `APP_PROVISIONING_PROFILE_BASE64` | アプリ用`.mobileprovision`のファイル全体をBase64化した値 |
| `WIDGET_PROVISIONING_PROFILE_BASE64` | Widget用`.mobileprovision`のファイル全体をBase64化した値 |
| `SHARE_EXTENSION_PROVISIONING_PROFILE_BASE64` | Share Extension用`.mobileprovision`のファイル全体をBase64化した値 |
| `SIGNED_ARTIFACT_ENCRYPTION_PASSWORD` | 署名済みartifactを保存する場合だけ使う20文字以上の独立パスワード |

Environment Variablesには次を置く。

| Variable | 内容 |
| --- | --- |
| `SHARING_STAGING_API_ORIGIN` | `pairing-only`だけに注入するstaging Workerの公開HTTPS origin。末尾path、query、placeholder、localhost、IP直書きは不可 |
| `SHARING_EXPORT_REVIEWED` | pairing暗号を含むbuildの輸出コンプライアンス確認後だけ`YES` |

`SHARING_STAGING_API_ORIGIN`は`Config.xcconfig`やソースへ書かない。`testflight` Environmentを`main`だけに制限し、workflowが`pairing-only`を選んだ場合だけarchiveへ注入する。未設定または公開originとして不正なら署名処理前に失敗し、processed Info.plistでも再検査する。

macOSで改行なしのBase64文字列をクリップボードへ入れる例：

```sh
base64 -i AuthKey_XXXXXXXXXX.p8 | tr -d '\n' | pbcopy
base64 -i Distribution.p12 | tr -d '\n' | pbcopy
base64 -i NekoWidget_AppStore.mobileprovision | tr -d '\n' | pbcopy
base64 -i NekoWidgetWidget_AppStore.mobileprovision | tr -d '\n' | pbcopy
```

Windowsでは秘密値をconsoleやtext fileへ出さず、[Apple Developer署名・TestFlight準備](Apple-Developer署名準備.md#74-powershellでbase64を直接clipboardへ送る)のClipboard関数を使う。貼り付け後はClipboardを空にし、WindowsのClipboard履歴とデバイス間同期を無効にする。

秘密情報をリポジトリ、artifact、issue、ログへ貼らない。workflowは一時Keychain、P12、プロファイル、API private keyを`always()` cleanupで削除し、外部ActionはGitHub公式の`actions/*`だけをfull commit SHAで固定している。GitHub-hosted runner自体もjob終了時に破棄される。

## 実行

1. まず`iOS build check`を手動実行し、無署名コンパイルを通す。
2. Actions > `Archive and upload to TestFlight` > Run workflowを選ぶ。
   実行対象branchは`main`に限定しており、それ以外でdispatchしたjobはskipする。
3. 通常は`release_mode = review-preview`のままにする。これはBuild 27までの静的レビュー境界で、共有runtimeと収集申告はOFFのままである。
4. 初回は`upload_to_testflight = false`、`retain_signed_artifacts = false`にし、P12 import、3 profile、manual archive、署名検査、IPA exportだけを通す。API Key関連の3 Secretsはまだ不要で、Appleへは送信しない。
5. `build_number`は正の整数を指定する。空欄では当該workflowの`github.run_number`を使うが、手動Xcodeなど別経路で同じ番号を使った場合は、既存より大きい番号を明示する。
6. `testflight` Environmentの承認を行う。
7. signing-onlyが成功したらApp Store ConnectのアプリレコードとAPI Keyを確認し、`upload_to_testflight = true`、`retain_signed_artifacts = true`で実行する。
8. archive、IPA export、validate、uploadの順に成功したことをログで確認する。
9. App Store Connect側の処理完了を待つ。workflow成功はアップロード受付までであり、Apple側の処理や輸出コンプライアンス回答、TestFlightグループへの配布までは自動化しない。

### Build 28の2台ペアリング確認

Build 28だけは`release_mode = pairing-only`、`build_number = 28`を明示する。このmodeは専用`Config.PairingOnly.xcconfig`を選び、featureだけを`YES`、media、Share Extension handoff、direct-send、review-previewをすべて`NO`へ固定する。Appのprivacy manifestはlinked User ID／trackingなし／App Functionalityだけへ一時overlayし、Share Extensionの収集dataは空のままにする。archive検査のsummaryが`pairing-only/photos disabled`でなければ配布しない。

TestFlight自体は1つのbuildを端末台数で強制制限できないため、Build 28は2台を使う内部testerだけへ割り当て、他のtester groupへ追加しない。2台で「まどを作る → 招待コードを渡す → 12語を照合 → 承認 → ペアリング済み → 設定から解除」を確認する。このBuildでは写真を保存・送信しないため、共有シートからのhandoff、写真の送受信、R2 object作成は合格条件に含めず、発生した場合は失敗とする。

Xcode result bundleとexport診断は14日間artifactへ保存する。`retain_signed_artifacts = true`の場合、IPAと、dSYMを内包するxcarchiveを1つのAES-256-CBC/PBKDF2暗号化artifactとして14日間保存する。復号パスワードはGitHubから後で表示できないため、必ず別のパスワードマネージャーに保存する。配布buildと一致するxcarchive／dSYMは14日以内に復号し、privateな保管場所へ退避する。無署名ビルドのresult bundleは7日間保存する。

現行の`altool`経路はIPAだけをAppleへ送るため、dSYMの明示uploadによるApple側自動symbolicationは保証しない。暗号化xcarchiveの保管を必須とし、必要時は復号してローカルsymbolicationに使う。

## 公式資料

- [Apple：Upcoming Requirements](https://developer.apple.com/news/upcoming-requirements/)
- [Apple：Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- [Apple：View builds and metadata](https://developer.apple.com/help/app-store-connect/manage-builds/view-builds-and-metadata/)
- [Apple：TN3147（altoolのApp Store Connect API key認証）](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)
- [Apple：Transporter User Guide](https://help.apple.com/itc/transporteruserguide/en.lproj/static.html)
- [Apple：Cloud-managed certificates](https://developer.apple.com/help/account/certificates/cloud-managed-certificates/)
- [Apple：Xcode 16 Release Notes（現在のprovisioning profile保存先）](https://developer.apple.com/documentation/xcode-release-notes/xcode-16-release-notes)
- [Apple：Create an App Store Connect provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile)
- [Apple：App Store Connect API](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api)
- [GitHub：Installing an Apple certificate on macOS runners](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [GitHub：Secure use reference](https://docs.github.com/en/actions/reference/security/secure-use)
- [GitHub：Deploying with GitHub Actions](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/control-deployments)
- [GitHub runner-images：macOS 15 installed software](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md)
