# Apple Developer署名・TestFlight準備

## 目的

Apple Developer Program（Individual）の承認を待つ間に決められる事項を確定し、承認後はWindowsとDeveloper Portalだけで署名素材を作り、GitHub ActionsのmacOS runnerでarchive、署名、IPA export、TestFlight uploadを行う。

Appleが通常のApple Distribution証明書向けに公開しているCSR作成手順はMacのキーチェーンアクセスを使う方法である。本書のWindows／OpenSSL手順は、同じPKCS#10 CSR、X.509証明書、PKCS#12 identityを作る互換手順であり、Appleが公開しているWindows専用手順ではない。最終的なmacOS Keychainへのimport、codesign、archiveはGitHub Actionsで検証する。

## いま可能なこと

| 作業 | 承認前 | 承認後 |
| --- | --- | --- |
| 永続ID候補の決定 | 可能 | Portalで空きを確認して登録 |
| RSA秘密鍵とCSRの生成 | 可能 | 同じ素材を使用 |
| GitHub `testflight` Environmentの作成 | 可能 | Secretsを投入 |
| Apple Distribution証明書の発行 | 不可 | 可能 |
| App ID／App Group／profileの登録 | 不可 | 可能 |
| App Store Connect API access／key | 不可 | 申請・承認後に可能 |
| 署名archive／IPA export | 不可 | GitHub ActionsのmacOS runnerで可能 |
| TestFlight upload | 不可 | GitHub Actionsから可能 |

承認前に秘密鍵を作る場合も、リポジトリやOneDriveには置かない。`C:\secure\neko-widget-signing`など、同期対象外かつBitLocker等で保護された場所を使い、暗号化された外部媒体またはパスワードマネージャーの添付機能へバックアップする。

## 1. 実IDの方針

### 1.1 命名規則

3つとも英小文字、数字、ピリオドを中心にした長期利用可能な値にする。GitHub owner名から自動決定せず、自分が今後も使うstable namespaceを決める。

```text
APP_BUNDLE_IDENTIFIER    = com.<stable-namespace>.nekowidget
WIDGET_BUNDLE_IDENTIFIER = com.<stable-namespace>.nekowidget.widget
APP_GROUP_IDENTIFIER     = group.com.<stable-namespace>.nekowidget
```

- AppとWidgetは別々のExplicit App IDとして登録する。wildcardは使わない。
- Widget IDはApp IDを接頭辞に持つ値にする。
- App Groupは別のIdentifierであり、必ず`group.`から始める。
- Team IDはこれらの値へ書かない。署名時の`application-identifier`にはApple側がTeam ID prefixを付ける。
- App Store Connectへ最初のbuildを送った後は、アプリレコードのBundle IDを変更できない。登録前にスペルを確定する。

### 1.2 決定表

Portal登録時に次を埋める。

| 項目 | 確定値 |
| --- | --- |
| Stable namespace | `jp.nekowidget` |
| App Bundle ID | `jp.nekowidget.app` |
| Widget Bundle ID | `jp.nekowidget.app.widget` |
| App Group ID | `group.jp.nekowidget.app` |
| Apple Team ID | `FF96XYPPH2` |
| App Store Connect App Name | `ねこのまど - 猫の写真ウィジェット` |
| App Store Connect SKU | `jp.nekowidget.app.2026` |

2026-08-16にPortal登録とApp Groups割当を完了し、`Config.xcconfig`を次のリテラル値へ更新した。CIがファイルを直接読むため、`$(APP_BUNDLE_IDENTIFIER)`のような派生式にはしない。

```xcconfig
APP_BUNDLE_IDENTIFIER = jp.nekowidget.app
WIDGET_BUNDLE_IDENTIFIER = jp.nekowidget.app.widget
APP_GROUP_IDENTIFIER = group.jp.nekowidget.app
```

`APP_PROVISIONING_PROFILE_SPECIFIER`と`WIDGET_PROVISIONING_PROFILE_SPECIFIER`は空のままにする。CIがprofileからNameを読み、実行時に注入する。

## 2. Windowsで秘密鍵とCSRを作る

### 2.1 OpenSSLの確認

Git for Windowsに含まれるOpenSSLをGit Bashから使える。PowerShellから直接使う場合の例：

```powershell
$OpenSSL = "C:\Program Files\Git\usr\bin\openssl.exe"
& $OpenSSL version
```

別のOpenSSL 3.xを使う場合は、信頼できる配布元から取得し、次の`$OpenSSL`だけ置き換える。

### 2.2 保管場所

```powershell
$SigningDir = "C:\secure\neko-widget-signing"
New-Item -ItemType Directory -Path $SigningDir -Force
Set-Location $SigningDir
```

このディレクトリはGit、OneDrive、Dropbox等の同期対象外にする。画面共有、Issue、Actionsログへ内容を貼らない。

### 2.3 暗号化RSA秘密鍵

```powershell
& $OpenSSL genpkey `
  -algorithm RSA `
  -aes-256-cbc `
  -pkeyopt rsa_keygen_bits:2048 `
  -out AppleDistribution.private.pem
```

OpenSSLが秘密鍵のパスフレーズを対話入力で求める。十分長い固有値を使い、パスワードマネージャーへ保存する。コマンド行の`-pass`へ直接書かない。

### 2.4 PKCS#10 CSR

`APPLE_ID_EMAIL`と`ASCII_NAME`を置き換える。Common Nameは識別しやすいASCII名にする。

```powershell
& $OpenSSL req `
  -new `
  -sha256 `
  -key AppleDistribution.private.pem `
  -out AppleDistribution.certSigningRequest `
  -subj "/emailAddress=APPLE_ID_EMAIL/CN=ASCII_NAME NekoWidget Distribution/C=JP"
```

CSRを検査する。

```powershell
& $OpenSSL req `
  -in AppleDistribution.certSigningRequest `
  -noout `
  -verify `
  -subject `
  -text
```

この時点で必要なのは次の2ファイルである。

- `AppleDistribution.private.pem`：最重要の秘密。Portalへ送らない。
- `AppleDistribution.certSigningRequest`：承認後にPortalへuploadする。

CSRを作り直した場合は、証明書を発行したCSRと対になる秘密鍵を混同しない。

## 3. 承認後のDeveloper Portal作業

### 3.1 最初に確認すること

1. Apple Developer AccountのMembershipがactiveであることを確認する。
2. 最新契約をAccount Holderとして承諾する。
3. Membership detailsの10文字Team IDを記録する。
4. App Store Connectの`Users and Access > Integrations`でAPI accessをすぐ申請する。Program承認とは別に審査待ちになる場合がある。

### 3.2 App Group

1. Certificates, Identifiers & Profilesを開く。
2. Identifiersの`+`から`App Groups`を選ぶ。
3. 決定済み`APP_GROUP_IDENTIFIER`を登録する。

### 3.3 AppとWidgetのExplicit App ID

次を別々に登録する。

| Description例 | Bundle ID | Capability |
| --- | --- | --- |
| `NekoWidget App` | `APP_BUNDLE_IDENTIFIER` | App Groups |
| `NekoWidget Widget Extension` | `WIDGET_BUNDLE_IDENTIFIER` | App Groups |

各App IDでApp Groupsを`Configure`し、同じ`APP_GROUP_IDENTIFIER`を割り当てる。App Groupsを後から変更すると既存profileが無効になるため、profile作成より先に済ませる。

### 3.4 `Config.xcconfig`

Portalに表示された3つの正確な値をコピーし、前述の3行だけを書き換える。大文字小文字、ピリオド、`group.` prefixを目視とdiffで再確認する。

## 4. Apple Distribution証明書とP12

### 4.1 証明書発行

1. Certificatesの`+`を開く。
2. Softwareで`Apple Distribution`を選ぶ。
3. `AppleDistribution.certSigningRequest`をuploadする。
4. 発行された`.cer`を`AppleDistribution.cer`として安全なディレクトリへ保存する。

### 4.2 DERからPEMへ変換

```powershell
& $OpenSSL x509 `
  -inform DER `
  -in AppleDistribution.cer `
  -out AppleDistribution.cert.pem

& $OpenSSL x509 `
  -in AppleDistribution.cert.pem `
  -noout `
  -subject `
  -issuer `
  -serial `
  -dates `
  -fingerprint `
  -sha256
```

有効期限、subject、issuerを確認する。

### 4.3 証明書と秘密鍵の一致

```powershell
& $OpenSSL pkey `
  -in AppleDistribution.private.pem `
  -pubout `
  -out private.public.pem

& $OpenSSL x509 `
  -in AppleDistribution.cert.pem `
  -pubkey `
  -noout `
  -out certificate.public.pem

& $OpenSSL pkey `
  -pubin `
  -in private.public.pem `
  -outform DER `
  -out private.public.der

& $OpenSSL pkey `
  -pubin `
  -in certificate.public.pem `
  -outform DER `
  -out certificate.public.der

Get-FileHash private.public.der -Algorithm SHA256
Get-FileHash certificate.public.der -Algorithm SHA256
```

2つのSHA-256が完全一致しなければ、その組でP12を作らない。

### 4.4 P12作成

```powershell
& $OpenSSL pkcs12 `
  -export `
  -inkey AppleDistribution.private.pem `
  -in AppleDistribution.cert.pem `
  -name "NekoWidget Apple Distribution" `
  -out AppleDistribution.p12
```

秘密鍵パスフレーズの後、P12専用のexport passwordを対話入力する。このexport passwordがGitHub Secret `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD`になる。

```powershell
& $OpenSSL pkcs12 `
  -in AppleDistribution.p12 `
  -info `
  -noout
```

まずOpenSSL 3の通常形式を使う。GitHubの署名だけ実行するworkflowでmacOS Keychain importに失敗した場合だけ、`pkcs12 -export`へ`-legacy`を加えた互換形式を検討する。

## 5. 配布profileを2つ作る

Profilesの`+`からDistributionの`App Store Connect`を選び、次を1つずつ作る。

| profile名の例 | App ID | 証明書 |
| --- | --- | --- |
| `NekoWidget AppStore App 2026` | App本体 | 前節のApple Distribution |
| `NekoWidget AppStore Widget 2026` | Widget Extension | 同じApple Distribution |

それぞれ`.mobileprovision`としてdownloadする。App Store Connect profileには1つのApp IDと1つのdistribution certificateが入るため、Widgetを含むこのアプリでは2ファイル必要である。

Windowsで内容をXMLへ展開する例：

```powershell
& $OpenSSL cms `
  -verify `
  -inform DER `
  -in NekoWidget_AppStore.mobileprovision `
  -noverify `
  -out NekoWidget_AppStore.plist

& $OpenSSL cms `
  -verify `
  -inform DER `
  -in NekoWidgetWidget_AppStore.mobileprovision `
  -noverify `
  -out NekoWidgetWidget_AppStore.plist
```

展開したplistで、次を確認する。

- `TeamIdentifier`が同じTeam ID
- `application-identifier`が`TEAM_ID.Bundle_ID`
- `com.apple.security.application-groups`に決定済みApp Groupがある
- `get-task-allow`がfalse
- `ExpirationDate`が有効

CIもarchive前にTeam、Bundle ID、App Groupを、archive後に実効entitlementsを再検査する。

TestFlightだけならApple Development証明書、development profile、iPhone UDIDは不要である。後日MacからケーブルでDevelopment buildを直接入れる場合だけ別途用意する。

## 6. App Store Connect

### 6.1 アプリレコード

App Store ConnectのAppsでNew Appを選び、App本体のBundle IDを使う。Widget用の別アプリレコードは作らない。

- Platform：iOS
- Name：`ねこのまど - 猫の写真ウィジェット`（Build 8で確定。既存アプリレコードもこの名前へ変更する）
- Primary Language：Japanese
- Bundle ID：`APP_BUNDLE_IDENTIFIER`
- SKU：外部非表示の一意値。決定表へ記録する

最新契約が未承諾だとアプリレコードを作れない。Bundle IDとversion、build stringの組でbuildが識別されるため、workflowのbuild numberはuploadごとに増やす。

### 6.2 Team API Key

API access承認後、`Users and Access > Integrations > Team Keys`から作る。

- Name例：`GitHub Actions TestFlight`
- Role：`Developer`（build uploadに必要な最小権限）

Team Keyは特定アプリだけに限定できない。Keyのnameとroleは後から変更できず、変更時はrevokeして再作成する。`.p8`は1回だけdownloadできるため、直ちに安全な保管場所と暗号化バックアップへ保存する。Key ID、Issuer IDも同時に記録する。

2026-08-16に`GitHub Actions TestFlight`というTeam Keyを`Developer` roleで作成した。`.p8`はリポジトリ／OneDrive外の署名フォルダへ移動し、GitHub Environment Secretへ登録した。Key ID、Issuer IDおよび秘密鍵の値は公開ドキュメントへ記載しない。

## 7. GitHub EnvironmentとSecrets

### 7.1 Environment

リポジトリ`Settings > Environments > New environment`で、名前を厳密に`testflight`とする。

- Deployment branchは`main`だけに制限する。
- Required reviewerを設定できる場合は使う。
- 一人運用中に`Prevent self-review`を有効にすると自分で承認できなくなるため、別reviewerがいない間は有効にしない。
- 署名素材はRepository SecretsではなくEnvironment Secretsへ置く。

### 7.2 signing-onlyに必要な6 Secrets

| Secret | 値 |
| --- | --- |
| `APPLE_TEAM_ID` | Membership detailsの10文字Team ID |
| `APPLE_DISTRIBUTION_CERTIFICATE_BASE64` | `AppleDistribution.p12`全体の改行なしBase64 |
| `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD` | P12 export passwordの生文字列 |
| `KEYCHAIN_PASSWORD` | CI一時Keychain専用の新規ランダム文字列 |
| `APP_PROVISIONING_PROFILE_BASE64` | App本体profile全体の改行なしBase64 |
| `WIDGET_PROVISIONING_PROFILE_BASE64` | Widget profile全体の改行なしBase64 |

`retain_signed_artifacts = true`で配布buildのxcarchive／dSYMを保管する場合は、次のOptional Secretも追加する。

| Secret | 値 |
| --- | --- |
| `SIGNED_ARTIFACT_ENCRYPTION_PASSWORD` | 20文字以上の独立したランダム値。P12やKeychainと共用しない |

### 7.3 TestFlight uploadで追加する3 Secrets

| Secret | 値 |
| --- | --- |
| `APP_STORE_CONNECT_KEY_ID` | Team API Keyの10文字Key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | Team Keys画面のIssuer UUID |
| `APP_STORE_CONNECT_PRIVATE_KEY_BASE64` | `AuthKey_<KEY_ID>.p8`全体の改行なしBase64 |

GitHub Variablesは使わない。`GITHUB_TOKEN`、`GITHUB_RUN_NUMBER`、`RUNNER_TEMP`等はGitHub組み込みなので作成不要である。

### 7.4 PowerShellでBase64を直接Clipboardへ送る

Base64を画面やテキストファイルへ出さず、ClipboardからEnvironment SecretのValueへ貼る。

```powershell
function Copy-FileBase64([string] $Path) {
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $bytes = [System.IO.File]::ReadAllBytes($resolved)
    [Convert]::ToBase64String($bytes) | Set-Clipboard
    [Array]::Clear($bytes, 0, $bytes.Length)
}

Copy-FileBase64 ".\AppleDistribution.p12"
Copy-FileBase64 ".\NekoWidget_AppStore.mobileprovision"
Copy-FileBase64 ".\NekoWidgetWidget_AppStore.mobileprovision"
Copy-FileBase64 ".\AuthKey_XXXXXXXXXX.p8"
```

Secretへ貼り付けたら`Set-Clipboard -Value ''`で消去する。作業中はWindows設定のClipboard履歴とデバイス間同期を無効にする。

CI一時Keychain passwordとartifact暗号化passwordは、それぞれ別に生成する。次のコマンドを1回ずつ実行し、毎回すぐパスワードマネージャーと対応するEnvironment Secretへ貼り付ける。

```powershell
& $OpenSSL rand -base64 32 | Set-Clipboard
```

一方を`KEYCHAIN_PASSWORD`、もう一方を`SIGNED_ARTIFACT_ENCRYPTION_PASSWORD`とし、P12 passwordとも使い回さない。保存と貼り付け後にClipboardを消去する。

## 8. ExportOptionsとworkflow

`ci/ExportOptions.plist.template`は次を準備済みである。

- `method = app-store-connect`
- `destination = export`
- `signingStyle = manual`
- `signingCertificate = Apple Distribution`
- App／Widgetの2つのprofile UUID mapping
- `manageAppVersionAndBuildNumber = false`
- `stripSwiftSymbols = true`

workflowはTeam ID、Bundle IDs、App Group、profile、archive後の実効entitlementsを検査し、実行終了時に一時Keychainと署名素材を削除する。

手動入力`upload_to_testflight`と`retain_signed_artifacts`の既定値はどちらもfalseである。

1. 最初はfalseで実行する。
2. Apple Distribution identityのKeychain import、manual archive、署名検査、IPA exportまでを確認する。
3. falseではApp Store Connect API Secretsは不要で、IPAをAppleへ送らない。
4. signing-only成功後、アプリレコードとAPI Keyを確認する。
5. `upload_to_testflight = true`、`retain_signed_artifacts = true`で1回実行し、暗号化archiveのartifact保存成功後にvalidate・uploadする。

workflowは`main` branchからの手動実行だけを処理する。実IDと署名設定のmainへの反映後に実行する。

`retain_signed_artifacts = true`にすると、IPAと、dSYMを内包するxcarchiveをAES-256-CBC/PBKDF2で1つのartifactへ暗号化する。`SIGNED_ARTIFACT_ENCRYPTION_PASSWORD`はGitHub Secretから後で表示できないため、作成時にパスワードマネージャーへ保存する。実upload buildはtrueにし、14日以内にartifactをprivateな保管場所へ退避する。

Windowsで復号する。OpenSSLは対話的にパスワードを求める。

```powershell
& $OpenSSL enc `
  -d `
  -aes-256-cbc `
  -pbkdf2 `
  -iter 200000 `
  -in NekoWidget-signed-artifacts.tar.gz.enc `
  -out NekoWidget-signed-artifacts.tar.gz

tar -xzf NekoWidget-signed-artifacts.tar.gz
```

現行workflowはexport済みIPAを`altool`へ送り、dSYMはAppleへ別送信しない。そのためTestFlightクラッシュのApple側自動symbolicationは保証しない。暗号化xcarchiveを復号・保管することで後日のローカルsymbolicationは可能である。dSYM自動uploadを要件にする場合は、実署名buildで別の配布フローをスパイクしてから切り替える。

2026年4月28日以降のApple要件に合わせ、workflowはXcode 26.3とiOS 26 SDKを持つrunnerを明示している。minimum deployment targetのiOS 17.1はそのまま維持できる。

アプリはWidget cache名のSHA-256に加え、共有写真とまど名のためにCryptoKitのX25519、Ed25519、HKDF、ChaChaPolyを使用する。独自暗号実装や外部暗号ライブラリは含めず、暗号処理はApple OSが提供するAPIだけに限定している。[Appleの書類区分](https://developer.apple.com/help/app-store-connect/reference/export-compliance-documentation-for-encryption/)は「AppleのOS内の暗号化だけを使用する場合はApp Store Connectへの書類不要」としており、現行`ITSAppUsesNonExemptEncryption = false`はこの免除を前提とする。ただし[輸出コンプライアンスの判定責任](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)は配布者にあるため、外部TestFlightまたはApp Store提出前にAccount HolderがApp Store Connectの質問へ現行実装どおり回答し、その結果と配布地域をrelease記録へ残す。実装、依存関係、配布地域が変わった場合は次のupload前に再判定する。

## 9. 秘密素材の扱い

リポジトリの`.gitignore`は`.p12`、`.p8`、`.mobileprovision`、`.cer`、`.certSigningRequest`、`.key`、`.pem`を除外しているが、署名素材をリポジトリ内へ置かないことが第一である。

- P12とP8は別々の暗号化バックアップを持つ。
- 秘密鍵のパスフレーズ、P12 password、Keychain passwordは使い回さない。
- Key ID、Team ID、Bundle IDは秘密ではないが、秘密鍵と一緒に公開しない。
- P8、P12、または`AppleDistribution.private.pem`が漏れた疑いがあれば、該当API Keyまたは証明書を直ちにrevokeし、profileとSecretsを再作成する。
- App Group capabilityやcertificateを変更したら、App、Widget、Share Extensionの3つのprofileを再生成する。
- `retain_signed_artifacts = true`では署名済みIPA、xcarchive、dSYMを暗号化してartifactへ出す。artifactと復号パスワードを同じ場所に保管しない。

## 10. 承認後チェックリスト

- [ ] Membership active、最新契約承諾、Team ID記録
- [x] App Store Connect API access申請
- [x] App Group登録
- [x] App本体Explicit App ID登録、App Group割当
- [x] Widget Explicit App ID登録、同じApp Group割当
- [x] `Config.xcconfig`の3 IDを同時更新
- [x] Apple Distribution証明書発行
- [x] 証明書と秘密鍵の公開鍵hash一致
- [x] P12作成・検査
- [x] App／WidgetのApp Store Connect profile作成
- [x] 両profileのTeam、Bundle ID、App Group、期限を確認
- [x] App Store Connectアプリレコード作成
- [x] Team API Key作成、P8／Key ID／Issuer ID保管
- [x] GitHub `testflight` EnvironmentとSecrets登録
- [x] `upload_to_testflight = false`で署名・export成功
- [ ] build numberを確認
- [ ] artifact暗号化passwordを別保管し、`retain_signed_artifacts = true`にする
- [ ] `upload_to_testflight = true`で初回upload
- [ ] 暗号化artifactをdownload・復号し、xcarchive／dSYMをprivate保管
- [ ] App Store Connectの処理完了と輸出コンプライアンス状態を確認
- [ ] 内部TestFlight testerへ配布

## 公式資料

- [Apple：Create a certificate signing request](https://developer.apple.com/help/account/certificates/create-a-certificate-signing-request)
- [Apple：Certificates overview](https://developer.apple.com/help/account/certificates/certificates-overview)
- [Apple：Register an App ID](https://developer.apple.com/help/account/identifiers/register-an-app-id)
- [Apple：Register an app group](https://developer.apple.com/help/account/identifiers/register-an-app-group/)
- [Apple：Enable app capabilities](https://developer.apple.com/help/account/identifiers/enable-app-capabilities/)
- [Apple：Create an App Store Connect provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile)
- [Apple：Add a new app](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app)
- [Apple：App Store Connect API](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api)
- [Apple：Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- [Apple：View builds and metadata](https://developer.apple.com/help/app-store-connect/manage-builds/view-builds-and-metadata/)
- [Apple：Upcoming Requirements](https://developer.apple.com/news/upcoming-requirements/)
- [OpenSSL：PKCS#12 command](https://docs.openssl.org/3.5/man1/openssl-pkcs12/)
- [GitHub：Installing an Apple certificate on macOS runners](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [GitHub：Using secrets in GitHub Actions](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets)
