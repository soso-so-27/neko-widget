# 個人保管 P1→P2 接続記録（2026-09-29）

目標は本人の写真1枚とメモをサービスへ保存し、同じApple本人が新しい端末／sessionから読み戻してZIPに書き出すこと。合成試験や設定追加をその達成と扱わない。最初の接続候補は15:57 JSTごろ。時間はこの候補から計測する。

## 直接確認した現状

- 基点 `02ca0418d2eaa30074298c616bce92af2f9ec8b6` の専用worktree。既存の汚れた研究checkoutは変更していない。
- Cloudflareの保管staging Workerは公開routeなし・受付OFF。Apple認証用secretとS3書込専用の資格情報は追加済みだが、pilot本人一覧は未登録。D1はowner/record各0、pilot enabled=0、復旧policyの2条件=0。従って実写真を受け付けない。
- private billing WorkerはOFF。共有staging D1はbilling account=0、active key=0、effective entitlement gate=0。実会員照合の成功はまだ不可能。nativeのPlus billingも既定OFF。
- private KMS WorkerにはKMSとcaller用secret名があるが、対応するAWS IAM鍵はInactive。JPEG Workerも設定上OFF。S3の専用書込資格情報は保管Workerへ登録済みで、実際の書込・読戻しは未検証。
- Apple Developer `jp.nekowidget.app` App IDはSign In with Appleが未設定だった。利用者承認後にprimary App IDとして有効化し、再表示でONを確認。これで既存App StoreアプリプロファイルがInvalidになったため、同じ証明書を選んで再生成した。新プロファイルはApp ID一致、Apple Sign In entitlement `Default`、証明書1件をダウンロード現物で確認。AppleのProfiles一覧ではInvalidが消えた。GitHub `testflight` environmentの `APP_PROVISIONING_PROFILE_BASE64` を更新し、更新時刻を照合した。Widget/Shareのプロファイル・secretは変更していない。
- 利用者の続行指示を受け、AppleにNekoWidget App IDだけを対象とするSign in with Apple専用キー `KRG3JMSBCD` を登録。秘密鍵を一度だけDownloadsへ取得し、PEM形式とローカルACLを確認した。鍵本文は会話・Git・ログへ出していない。Cloudflareの同じ個人アカウントを照合して、非公開保管Workerの `APPLE_CREDENTIALS_JSON` に登録。secret名が存在し、現行deploymentの `PRESERVATION_ENABLED=NO` / `CLEANUP_ENABLED=NO` を再確認した。AWS SSMの暗号化控えが完成するまでローカルの一度限りの原本を消さない。
- AWS CLIのstagingプロファイルはsession期限切れ。最初の再ログインは既定の会社ブラウザを開いてしまい、利用者の指摘で中止した。続く `aws login --remote` のリンクは、利用者の個人用ブラウザでも2回連続でAWS側の400 Bad Requestになった。2回目はCodex側でリンクを開いていないため、単なる再利用が原因との先の説明は誤り。再試行は中止し、現在の鍵・bucket・IAMはこのバッチでは未確認。CLIプロファイルはこのアカウントのroot login_sessionだけで、別の有効なAWSプロファイルは見つからなかった。厳密な400原因は未確定。
- 最新main `dc17357` を専用候補へ統合した。重複したタスク台帳だけを両方残して解決し、保管コードに競合はなかった。変更済みの保管コードの局所成功結果は入力が変わらないため再実行していない。
- CLI用URLを使わず、Codex内の個人用ブラウザーで通常のAWS Consoleを開くと、root userのメール入力画面まで到達し、400は発生しなかった。ただしAWS本人認証は未完で、アカウント・bucket・KMS・IAMの実状態を確認したことにはならない。会社Chromeは使用していない。
- 利用者が同じ個人用AWS Consoleへサインインした後、読取専用でIAM dashboardのアカウントID `164892691568`、root MFA有効・root access keyなしを確認。東京リージョンのS3 `neko-preservation-staging-recovery-164892691568` はversioning有効、Block Public Access全ON、bucket policyなし、lifecycle ruleなし、現行object一覧0件。過去versionの現存数はこの画面では再確認していない。既存KMS key `339319dc-388b-4bd7-adb8-29d37d836d72` は有効だが説明は「staging synthetic test only」。KMS用IAM user `neko-preservation-staging-kms-worker` のaccess key 1件はInactive。
- 利用者の明示承認後、個人AWSアカウントに `neko-preservation-staging-s3-writer-v1` policyと、コンソールアクセスのない `neko-preservation-staging-s3-writer` userを作成。`recovery/v1/*` のPUT/GET/GetVersion、指定prefixのListBucketVersions、`purge/v1/*` のGET/GetVersionだけを許可し、削除・他bucket・KMS権限は付けていない。ユーザーのアクセスキーは1本だけActiveで、鍵本文は会話・Git・ログに出していない。Cloudflareの個人アカウントの非公開Worker `neko-preservation-staging-disabled` に `RECOVERY_S3_ACCESS_KEY_ID` / `RECOVERY_S3_SECRET_ACCESS_KEY` を暗号化secretとして一括登録し、画面上で両方 `Value encrypted`、`PRESERVATION_ENABLED=NO` / `CLEANUP_ENABLED=NO` を確認。鍵の有効性とS3書込・読戻しはまだ実証していない。
- Apple Developer画面には、最新のProgram License Agreementへの同意期限が2026-10-02と表示されている。契約本文の確認・同意は本人の判断であり、この作業では行わない。
- App Store Connectの「ビジネス→契約」は無料アプリ契約だけが表示され、有料アプリ契約は有効でない。「ねこのまど→サブスクリプション」にはグループも商品もない。Apple公式の[アプリ内購入の設定](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/overview-for-configuring-in-app-purchases/)によれば、Sandbox試験にも有料アプリ契約のActive状態が必要。よって現時点の実Plus会員の購入・照合は成立しない。契約への同意と税務・銀行情報はAccount Holder本人の判断・入力が必要。

## 固定候補の変更挙動・直接証拠・残り

アプリ側にManagedPreservationのビルド設定3値を追加し、既定はOFF。URLと会員audienceが両方妥当なときだけ入口を利用可能にした。Apple Sign In entitlementをホストアプリに追加。TestFlightの署名前チェックに、アプリだけ同entitlementを要求する検査を追加した。S3書込主体のstagingポリシーは `recovery/v1/*` のPUT/GET/版一覧と `purge/v1/*` の読取だけで、KMSと版削除を含まない候補を作った。

AWSログインを使い回さないため、固定設定にsession tokenがある場合はS3復旧コピーとKMS Workerが通信前に拒否する候補を追加。関連13件と型検査を局所実行して成功。AWS現物の資格情報・接続・復元は未確認で、この変更はWorkerの受付をONにしない。

plist構文、プロファイル現物のApp ID/entitlement、CI preflight Python構文、JSON構文と禁止action不在、git diff空白検査は通過。Swiftの実ビルド、実Apple認証、実会員、実JPEG、S3書込、実iPhone、別端末復元、ZIPは未確認。無関係なWidget画面試験や全件CIを最初のprobeに使わない。
追加の局所確認として、disabled release設定11件と署名artifact認証4件は成功した。`Info.plist`・entitlements・xcconfig・TestFlight workflowを含む候補は現行iOS CIの限定ファイル集合に収まらず、pushすれば広域CIを選ぶ見込み。結線前の未完成候補では走らせない。

## 次の成立順

1. Apple専用キーを登録し、private keyを一度だけ取得して保管Workerのsecretへ入れる。ここまでは済んだ。AWSの暗号化控えは未完了。tokenや鍵本文をログへ出さない。
2. [AWS接続の見直し](2026-09-29-preservation-aws-access.md)に従う同一アカウント・bucket versioning/公開遮断・KMS/IAM状態の照合とS3書込専用主体のsecret登録は済んだ。受付OFFのままS3合成1件の書込・版読戻しと残存確認を行う。KMS側のInactive鍵は別途整理し、既存KMS鍵の実接続を確認する。管理者の一時CLIログインはアプリ運用経路に使わない。
3. 有料アプリ契約がActiveになり、商品・Sandbox購入が用意された後、実在するBillingAccountIDとApple側の正当なPlus権利を通す。`active`の仮置きでは済ませない。pilot本人HMACはApple検証済みsubjectからのみ作る。
4. 受付・復旧policy・会員/JPEG/KMSのgateを限定7日/最大3人の設定と共に結線して、1件保存→同ID読戻し→新session/別端末→ZIPを実証する。未達ならONにしない。

候補のpush/CI/TestFlightは、必要な設定が揃って範囲を固定した後に選ぶ。現時点で本線アプリ配布は行っていない。
