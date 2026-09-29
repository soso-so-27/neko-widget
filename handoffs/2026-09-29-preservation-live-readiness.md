# 個人保管 P1→P2 接続記録（2026-09-29）

目標は本人の写真1枚とメモをサービスへ保存し、同じApple本人が新しい端末／sessionから読み戻してZIPに書き出すこと。合成試験や設定追加をその達成と扱わない。最初の接続候補は15:57 JSTごろ。時間はこの候補から計測する。

## 直接確認した現状

- 基点 `02ca0418d2eaa30074298c616bce92af2f9ec8b6` の専用worktree。既存の汚れた研究checkoutは変更していない。
- Cloudflareの保管staging Workerは公開routeなし・受付OFF。Apple認証用secretとS3書込専用の資格情報は追加済みだが、pilot本人一覧は未登録。D1はowner/record各0、pilot enabled=0、復旧policyの2条件=0。従って実写真を受け付けない。
- private billing WorkerはOFF。共有staging D1はbilling account=0、active key=0、effective entitlement gate=0。実会員照合の成功はまだ不可能。nativeのPlus billingも既定OFF。
- private KMS WorkerにはKMSとcaller用secret名があり、KMS専用IAMの新しい鍵を登録した。旧鍵はInactiveのまま。KMS WorkerとJPEG Workerは設定上OFF。S3の専用書込資格情報は保管Workerへ登録済みで、合成1件の書込・版読戻しは成功。実写真・新端末復元は未検証。
- Apple Developer `jp.nekowidget.app` App IDはSign In with Appleが未設定だった。利用者承認後にprimary App IDとして有効化し、再表示でONを確認。これで既存App StoreアプリプロファイルがInvalidになったため、同じ証明書を選んで再生成した。新プロファイルはApp ID一致、Apple Sign In entitlement `Default`、証明書1件をダウンロード現物で確認。AppleのProfiles一覧ではInvalidが消えた。GitHub `testflight` environmentの `APP_PROVISIONING_PROFILE_BASE64` を更新し、更新時刻を照合した。Widget/Shareのプロファイル・secretは変更していない。
- 利用者の続行指示を受け、AppleにNekoWidget App IDだけを対象とするSign in with Apple専用キー `KRG3JMSBCD` を登録。秘密鍵を一度だけDownloadsへ取得し、PEM形式とローカルACLを確認した。鍵本文は会話・Git・ログへ出していない。Cloudflareの同じ個人アカウントを照合して、非公開保管Workerの `APPLE_CREDENTIALS_JSON` に登録。secret名が存在し、現行deploymentの `PRESERVATION_ENABLED=NO` / `CLEANUP_ENABLED=NO` を再確認した。AWS SSMの暗号化控えが完成するまでローカルの一度限りの原本を消さない。
- AWS CLIのstagingプロファイルはsession期限切れ。最初の再ログインは既定の会社ブラウザを開いてしまい、利用者の指摘で中止した。続く `aws login --remote` のリンクは、利用者の個人用ブラウザでも2回連続でAWS側の400 Bad Requestになった。2回目はCodex側でリンクを開いていないため、単なる再利用が原因との先の説明は誤り。再試行は中止し、現在の鍵・bucket・IAMはこのバッチでは未確認。CLIプロファイルはこのアカウントのroot login_sessionだけで、別の有効なAWSプロファイルは見つからなかった。厳密な400原因は未確定。
- 最新main `dc17357` を専用候補へ統合した。重複したタスク台帳だけを両方残して解決し、保管コードに競合はなかった。変更済みの保管コードの局所成功結果は入力が変わらないため再実行していない。
- CLI用URLを使わず、Codex内の個人用ブラウザーで通常のAWS Consoleを開くと、root userのメール入力画面まで到達し、400は発生しなかった。ただしAWS本人認証は未完で、アカウント・bucket・KMS・IAMの実状態を確認したことにはならない。会社Chromeは使用していない。
- 利用者が同じ個人用AWS Consoleへサインインした後、読取専用でIAM dashboardのアカウントID `164892691568`、root MFA有効・root access keyなしを確認。東京リージョンのS3 `neko-preservation-staging-recovery-164892691568` はversioning有効、Block Public Access全ON、bucket policyなし、lifecycle ruleなし、現行object一覧0件。過去versionの現存数はこの画面では再確認していない。既存KMS key `339319dc-388b-4bd7-adb8-29d37d836d72` は有効だが説明は「staging synthetic test only」。KMS用IAM user `neko-preservation-staging-kms-worker` のaccess key 1件はInactive。
- 利用者の明示承認後、個人AWSアカウントに `neko-preservation-staging-s3-writer-v1` policyと、コンソールアクセスのない `neko-preservation-staging-s3-writer` userを作成。`recovery/v1/*` のPUT/GET/GetVersion、指定prefixのListBucketVersions、`purge/v1/*` のGET/GetVersionだけを許可し、削除・他bucket・KMS権限は付けていない。ユーザーのアクセスキーは1本だけActiveで、鍵本文は会話・Git・ログに出していない。Cloudflareの個人アカウントの非公開Worker `neko-preservation-staging-disabled` に `RECOVERY_S3_ACCESS_KEY_ID` / `RECOVERY_S3_SECRET_ACCESS_KEY` を暗号化secretとして一括登録し、画面上で両方 `Value encrypted`、`PRESERVATION_ENABLED=NO` / `CLEANUP_ENABLED=NO` を確認。鍵の有効性とS3書込・読戻しはまだ実証していない。
- AWS IAM Policy Simulatorで同ユーザーの同一対象ARNを評価し、`s3:PutObject` は明示的許可、`s3:DeleteObjectVersion` は一致する許可がないため暗黙的拒否と表示された。これはポリシー評価であり、キー認証・実S3操作・bucket側の制約を通した証拠ではない。
- AWS画面でKMS専用user `neko-preservation-staging-kms-worker` の直接policyが1件、コンソールアクセスなしを確認。policy本文はローカルの `scripts/aws-kms-staging-worker-policy.json` と同じく、対象key `339319dc-388b-4bd7-adb8-29d37d836d72` のEncrypt/Decryptと暗号化context key `neko-preservation-context-sha256` に限定されている。利用者の明示承認後、新しいaccess keyを1本作り、Cloudflareの非公開KMS Workerの `KMS_ACCESS_KEY_ID` / `KMS_SECRET_ACCESS_KEY` を暗号化secretとしてそれぞれ差し替えた。画面では両方 `Value encrypted`、`PRESERVATION_KMS_ENABLED=NO` を確認。AWS画面では旧鍵がInactive、新鍵がActiveの計2本。鍵本文は会話・Git・ログに出していない。KMSの実Encrypt/Decryptと新鍵による認証は未検証。
- AWS KMS Consoleで対象keyのpolicyにアカウントrootをprincipalとする `Enable IAM User Permissions` があり、IAM側policyを適用できる形であることを確認した。これは実KMS認証の成功ではない。既存の実接続probeは「KMS鍵1本だけInactive」「人のAWS CLI session有効」を前提としており、現在の2本（旧Inactive・新Active）と期限切れCLIには適合しない。誤って実行せず、新しい鍵を無効化しない経路に改める。
- Apple Developer画面には、最新のProgram License Agreementへの同意期限が2026-10-02と表示されている。契約本文の確認・同意は本人の判断であり、この作業では行わない。
- App Store Connectの「ビジネス→契約」は無料アプリ契約だけが表示され、有料アプリ契約は有効でない。「ねこのまど→サブスクリプション」にはグループも商品もない。Apple公式の[アプリ内購入の設定](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/overview-for-configuring-in-app-purchases/)によれば、Sandbox試験にも有料アプリ契約のActive状態が必要。よって現時点の実Plus会員の購入・照合は成立しない。契約への同意と税務・銀行情報はAccount Holder本人の判断・入力が必要。

## 固定候補の変更挙動・直接証拠・残り

アプリ側にManagedPreservationのビルド設定3値を追加し、既定はOFF。URLと会員audienceが両方妥当なときだけ入口を利用可能にした。Apple Sign In entitlementをホストアプリに追加。TestFlightの署名前チェックに、アプリだけ同entitlementを要求する検査を追加した。S3書込主体のstagingポリシーは `recovery/v1/*` のPUT/GET/版一覧と `purge/v1/*` の読取だけで、KMSと版削除を含まない候補を作った。

AWSログインを使い回さないため、固定設定にsession tokenがある場合はS3復旧コピーとKMS Workerが通信前に拒否する候補を追加。関連13件と型検査を局所実行して成功。AWS現物の資格情報・接続・復元は未確認で、この変更はWorkerの受付をONにしない。

plist構文、プロファイル現物のApp ID/entitlement、CI preflight Python構文、JSON構文と禁止action不在、git diff空白検査は通過。Swiftの実ビルド、実Apple認証、実会員、実JPEG、S3書込、実iPhone、別端末復元、ZIPは未確認。無関係なWidget画面試験や全件CIを最初のprobeに使わない。
追加の局所確認として、disabled release設定11件と署名artifact認証4件は成功した。`Info.plist`・entitlements・xcconfig・TestFlight workflowを含む候補は現行iOS CIの限定ファイル集合に収まらず、pushすれば広域CIを選ぶ見込み。結線前の未完成候補では走らせない。
S3資格情報の登録後、stagingの接続先（AWS account/region/bucket）を `wrangler.jsonc` に固定し、`RECOVERY_COPY_ENABLED=NO` を明記した。Wrangler 4.125.0のstaging dry-runは約4秒で成功し、受付・cleanup・復旧コピーの3 gateがすべて `NO` と表示された。これは設定・bundleの検証であり、遠隔Workerへの配備やS3到達の証拠ではない。
次のstaging配備候補はこのS3接続先と復旧コピーOFFを遠隔Workerへ反映するだけで、受付・cleanup・復旧コピーをONにしない。配備前の現行version `475c54a1-be40-4ebd-be57-ffa6228f3e64` は必要なApple/S3/caller secret名を持ち、上記3つのうち受付・cleanupはOFF、S3接続先のvarsは未設定。秘密値を表示せず確認した。局所dry-runを直接証拠とし、遠隔配備・再読取の所要目安は約2分。実S3書込やアプリ配布の成功とは扱わない。
この設定を遠隔staging Workerへ配備し、version `5da0175f-b7b0-4a8f-a4ff-e20e4a32d6ed` のbindingsでS3接続先4値、Apple/S3/caller secret名、受付・cleanup・復旧コピーすべて `NO` を再読取した。Wranglerの初回配備でローカル既定のpreview URLがON扱いになる差分警告が出たため、`workers_dev=false` に加え `preview_urls=false` を明記して即時再配備。Cloudflare Domains画面では最終状態のProduction URL・Preview URLがともにOFF、custom domain/routeなし。初回versionのpreview URL有効時間と外部アクセス有無は直接確認していない。遠隔S3への実リクエストはまだ行っていない。
KMSの実接続用には、期限切れの管理者CLI sessionや旧Inactive鍵を使うprobeを避け、ローカル127.0.0.1だけで開ける合成round-tripフォームと90秒でKMS gateを自動OFFに戻す手順を用意した。TypeScript型検査、PowerShell構文、局所フォームGET 200、KMS YESのWrangler dry-runは成功。利用者承認後、private KMS Workerだけを一時YESにし、SSM SecureStringのcaller tokenをローカルフォームへ一度入力。実AWS KMSに対する合成32-byte鍵のwrap/unwrapで元の鍵との一致を検査するPOST `/run` がHTTP 200を返した（2回）。直後に自動OFFへ復帰し、遠隔version `826e7823-544c-4caf-a95c-fab010bdfe05` の `PRESERVATION_KMS_ENABLED=NO`、本体の受付/cleanup/復旧コピーすべてNOを読戻した。IAM鍵は変更していない。KMS Workerは公開URL/preview URL/custom routeなしを事前確認し、設定でも両URLをOFFに固定した。これはKMS実接続の証拠であり、S3書込・実写真・実会員・復元の証拠ではない。

## 次の成立順

### S3実接続の次候補（2026-09-29 18:25 JSTごろ開始）

変更する挙動は、公開経路のない保管staging Workerを一時的な合成S3検査入口へ切り替え、同Workerの既存のS3 secretでランダムな32 byteを1件だけPUT→版指定GET→版一覧で確認した後、通常の受付OFFコードへ自動復帰すること。実写真・D1 owner・有料会員は触らない。検査用ワンタイムtokenは短時間の一時varだけで、通常配備へ戻すと消える。合成オブジェクトは書込主体に削除権限がないため残し、keyとversionを記録する。

直接証拠は専用entrypointの型検査、PowerShell構文検査、遠隔配備候補のWrangler dry-run成功。S3実操作、remote service bindingの到達、実行後の通常entrypointへの復帰は未確認。局所dev起動と2回の非公開配備を含む予想は数分で、iOS CI/TestFlightは対象外。失敗時は最初のHTTP段階と合成keyを記録し、正常復帰が確認できない場合はincidentとして扱う。

初回実行はローカルWranglerに `--local` を明示したため、`remote: true` のservice bindingが無効となりHTTP 503（対象Workerがローカルで見つからない）で停止。これは検査環境の起動指定の誤りで、S3へは未到達。自動復帰で通常entrypointと3 gateのNO、ワンタイムtoken削除を遠隔で確認。次回は `--local` を外し、同じ合成1件だけ再実行する。

`--local` を外した次の実行はprivate binding経由でWorkerへ到達したが、`putVersioned` 内で503となった。これはS3 PUTそのものか、その後のHEADかを区別できないエラー応答だった。合成keyは `recovery/v1/2ab1b06d-0395-463f-9be7-143bad87e5ee/photo/3059a17e-2433-46fb-b7d6-a18868bb8880`。この実行のS3実応答・残存有無は未確認。検査用入口の自動復帰と3 gateのNOを確認した。

AWS応答段階だけを返す診断を付けた再実行で、同じWorkerの登録済み資格情報から合成32 byteの版付きPUT、版指定GETの内容一致、owner版一覧の当該version一致を確認。`S3_SYNTHETIC_ROUND_TRIP_PASS` のkeyは `recovery/v1/3ff2fb4d-5a86-486f-8c43-1caae8a53069/photo/1f768bcf-614e-4258-be65-0319e36b4fc9`、versionは `3HADRtH5Z1Y14n5pn_0JixaU0YPbduWk`。合成objectは意図的に保持する。通常entrypointへ戻し、一時tokenの消失と受付/cleanup/復旧コピーの3 gate `NO` を再読取した。最初の実S3失敗の原因は不明であり、単回成功から安定稼働までは断定しない。S3実接続の初候補から成功・復帰まで約15分。実写真・会員・別端末復元は依然未検証。

個人AWS Consoleの `recovery/v1/` 一覧には成功したownerフォルダ1件だけが表示され、先の失敗keyに対応する現行objectは見えない。過去versionや失敗のHTTP原因はこの画面では証明していない。Apple専用鍵の復旧用パラメータは利用者の作成後に個人AWS `164892691568` の東京リージョンで再読取し、指定名 `/neko/preservation/staging/apple-sign-in-private-key-v1`、種類 `SecureString`、値の伏字表示、version 1を確認した。復号化チェックは押しておらず、値の一致とKMSキーIDは未確認。鍵本文をモデル出力やshellログへ出さず、ローカルの一度限りの原本は維持する。

App Store Connectの契約一覧を再読取すると無料アプリ契約のみで、有料アプリ契約はない。Apple Developer Program使用許諾契約の更新もAccount Holderの確認待ち。`ねこのまど` に審査前グループ `ねこのまど Plus`（ID `22424520`）と月額商品 `jp.nekowidget.plus.monthly`（Apple ID `6817296251`、期間1か月）を作成した。価格・無料期間・配信地域・顧客向け説明は未設定、審査提出なし、実課金なし。既存の会員仕様で980円・初回7日は検証案なので販売条件とはしない。Apple公式はPaid Apps AgreementがActiveでないとSandboxの実購入試験もできないとしている。

サーバーのApple verifierとSharing verifier clientが年額IDを必須としていた前提を、年額ID省略・空欄なら月額のみ受理する候補に修正。任意の年額IDを設定した場合は書式と月額との重複を検査し、月額のみ構成では年額取引を拒否する。BillingVerificationServiceの型検査・構成9件、SharingServiceの型検査・verifier client 7件が局所成功。依存未導入による最初の実行環境失敗はoffline `npm ci` で解消した。候補は未push・未CI・未配布で、独立レビューと必要なbackend確認は本線反映前に残る。

1. Apple専用キーを登録し、private keyを一度だけ取得して保管Workerのsecretへ入れる。ここまでは済んだ。AWSの暗号化控えは指定名・`SecureString` 型・伏字値を確認したが、原本との一致とKMSキーIDは未確認。tokenや鍵本文をログへ出さない。
2. [AWS接続の見直し](2026-09-29-preservation-aws-access.md)に従う同一アカウント・bucket versioning/公開遮断・KMS/IAM状態の照合、S3書込専用主体とKMS専用主体のsecret登録、受付OFFでのS3合成1件の版付き書込・読戻し、KMSの実Encrypt/Decryptは済んだ。前段のS3失敗1回の原因と残存有無は未確認。管理者の一時CLIログインはアプリ運用経路に使わない。
3. Account Holderによる更新契約と有料アプリ契約、銀行・税務情報の設定が必要。月額商品は審査前の骨格のみ作成済み。Sandboxに必要な価格・販売地域・ローカライズ・試験用Apple Accountを整え、契約Active後に実在するBillingAccountIDとApple側の正当なPlus権利を通す。`active`の仮置きでは済ませない。pilot本人HMACはApple検証済みsubjectからのみ作る。
4. 受付・復旧policy・会員/JPEG/KMSのgateを限定7日/最大3人の設定と共に結線して、1件保存→同ID読戻し→新session/別端末→ZIPを実証する。未達ならONにしない。

候補のpush/CI/TestFlightは、必要な設定が揃って範囲を固定した後に選ぶ。現時点で本線アプリ配布は行っていない。
