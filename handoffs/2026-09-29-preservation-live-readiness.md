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
- Apple Developer画面には、最新のProgram License Agreementへの同意期限が2026-10-02と表示されていた。その後の利用者による同意が契約履歴へ反映した。契約本文の確認・同意は本人の判断であり、この作業では行わない。
- App Store Connectの「ビジネス→契約」に有料アプリ契約は「新規」として現れたが、有効でない。審査前の月額商品骨格は別途作成済み。Apple公式の[アプリ内購入の設定](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/overview-for-configuring-in-app-purchases/)によれば、Sandbox試験にも有料アプリ契約のActive状態が必要。よって現時点の実Plus会員の購入・照合は成立しない。契約への同意と税務・銀行情報はAccount Holder本人の判断・入力が必要。

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

個人AWS Consoleの `recovery/v1/` 一覧には成功したownerフォルダ1件だけが表示され、先の失敗keyに対応する現行objectは見えない。過去versionや失敗のHTTP原因はこの画面では証明していない。Apple専用鍵の復旧用パラメータは利用者の作成後に個人AWS `164892691568` の東京リージョンで再読取し、指定名 `/neko/preservation/staging/apple-sign-in-private-key-v1`、種類 `SecureString`、値の伏字表示、version 1を確認した。続いて個人AWS CloudShellから値を復号したままパイプ内でPEM本体をDERへ戻してSHA-256を計算し、ローカル原本の同じDERハッシュと一致した。鍵本文は画面・会話・Git・ログに出していない。SSMのKeyIdは `alias/aws/ssm` と確認した。ローカルの一度限りの原本は維持する。

App Store Connectの契約一覧を再読取すると無料アプリ契約のみで、有料アプリ契約はない。Apple Developer Program使用許諾契約の更新もAccount Holderの確認待ち。`ねこのまど` に審査前グループ `ねこのまど Plus`（ID `22424520`）と月額商品 `jp.nekowidget.plus.monthly`（Apple ID `6817296251`、期間1か月）を作成した。価格・無料期間・配信地域・顧客向け説明は未設定、審査提出なし、実課金なし。既存の会員仕様で980円・初回7日は検証案なので販売条件とはしない。Apple公式はPaid Apps AgreementがActiveでないとSandboxの実購入試験もできないとしている。

最初の同意報告後はApple Developerアカウント画面に案内が残ったが、利用者が再度同意した後の再読取では、新しいProgram License Agreement `XG8DNV4HYY` の同意日が2026年9月29日となり、案内が消えた。App Store Connectにも無料アプリ契約が有効、有料アプリ契約が「新規」として現れた。有料契約の本文・添付ファイルと未選択の同意チェックを確認したが、同意操作は行っていない。契約ActiveやSandbox課金可能と扱わない。

サーバーのApple verifierとSharing verifier clientが年額IDを必須としていた前提を、年額ID省略・空欄なら月額のみ受理する候補に修正。任意の年額IDを設定した場合は書式と月額との重複を検査し、月額のみ構成では年額取引を拒否する。BillingVerificationServiceの型検査・構成9件、SharingServiceの型検査・verifier client 7件が局所成功。依存未導入による最初の実行環境失敗はoffline `npm ci` で解消した。候補は未push・未CI・未配布で、独立レビューと必要なbackend確認は本線反映前に残る。

1. Apple専用キーを登録し、private keyを一度だけ取得して保管Workerのsecretへ入れる。ここまでは済んだ。AWSの暗号化控えは指定名・`SecureString` 型・KeyId `alias/aws/ssm`・DERハッシュによる原本一致を確認した。tokenや鍵本文をログへ出さない。
2. [AWS接続の見直し](2026-09-29-preservation-aws-access.md)に従う同一アカウント・bucket versioning/公開遮断・KMS/IAM状態の照合、S3書込専用主体とKMS専用主体のsecret登録、受付OFFでのS3合成1件の版付き書込・読戻し、KMSの実Encrypt/Decryptは済んだ。前段のS3失敗1回の原因と残存有無は未確認。管理者の一時CLIログインはアプリ運用経路に使わない。
3. Account Holderによる更新契約と有料アプリ契約、銀行・税務情報の設定が必要。月額商品は審査前の骨格のみ作成済み。Sandboxに必要な価格・販売地域・ローカライズ・試験用Apple Accountを整え、契約Active後に実在するBillingAccountIDとApple側の正当なPlus権利を通す。`active`の仮置きでは済ませない。pilot本人HMACはApple検証済みsubjectからのみ作る。
4. 受付・復旧policy・会員/JPEG/KMSのgateを限定7日/最大3人の設定と共に結線して、1件保存→同ID読戻し→新session/別端末→ZIPを実証する。未達ならONにしない。

2026-09-29追記：利用者が有料アプリ契約に同意した後、App Store Connectで同契約の期間と「ユーザ情報を保留中」を確認。銀行口座と税務フォームが未登録のためActiveではない。Small Business Programの別申請では、本人回答に基づき関連Apple Developerアカウント4問をすべてNoに設定。本人が前年収益の宣誓内容を確認して提出を許可した後、Appleの「Thank you for your submission」「審査結果はメールで通知」画面を確認。承認・15%適用は未確認。販売・課金・保管受付は引き続きOFF。

候補のpush/CI/TestFlightは、必要な設定が揃って範囲を固定した後に選ぶ。現時点で本線アプリ配布は行っていない。

## 2026-09-30 接続候補のレビューと配備用準備

- `origin/main` の `83f77d0` までを専用候補へ競合なく統合。候補 `11595aec634efb6229f769db4213e067ba06d1f1`。月額のみ構成 `07d67b6` は独立レビューで問題なし。年額省略以外の不正ID拒否、署名、bundle・環境・購読group・購入者の照合は維持される。対象サービス・依存にはmainの変更がなく、既存の型検査・関連16件を再実行していない。
- BillingVerificationServiceの配備用 `tsc -p tsconfig.build.json` が成功。Apple PKIの公式配布元から3種類のroot DERを取得し、NodeのX509実装で自己署名・CA属性、取得物の有効期間を確認した。最初のPython自己署名検査は旧rootのSHA-1に対する検査ライブラリの非対応で停止したため、実サービスと同じNodeの検査を使った。製品や署名検証条件は変更していない。
- 配備用のdist、固定package-lock、証明書の出典・SHA256、月額のみSandbox設定を `C:/dev/neko-evidence/preservation-sandbox-20260930/` に用意した。`sandbox.env.template` はruntimeと追加endpointがすべてNO、資格情報とRedis接続先は空欄。実ロードで起動が拒否されることを確認。秘密鍵・Apple JWS・個人写真を含まない。これは配備済み・購入成功の証拠ではない。
- App Store Connectを読取確認：有料アプリ契約は「ユーザ情報を保留中」、銀行情報は処理中、2つのUS納税フォームは未提出。居住住所の綴り修正はAppleへの依頼受付までで、反映は未確認。納税フォームは送信していない。
- **Apple承認だけでは接続は完了しない。** Verifier Nodeの隔離host、private ingress、TLS Redis、共有secretの注入、月額商品の販売条件とSandboxアカウント、アプリ側の保管origin、検証済み本人のpilot設定が残る。実購入→会員リンク→実写真の保存・新session/別端末読戻し→ZIPは未検証。仮のactive権利で代替しない。
- この段階ではremote配備・gate変更・push・CI・TestFlightを実行していない。月額候補の初回時刻は2026-09-29 19:24:53 JST。今回のビルドは約5秒、設定ロード確認は約2秒で、待機・調査を含む候補全体の所要時間とは区別する。

## 2026-09-30 利用者依頼1〜3の候補

1. 配備準備：最新main `cc4f396` を統合した専用checkoutを使用。Node/同一hostのTLS Redis/Tunnel/Accessの設定雛形、systemd unit、費用計算をBillingVerificationService/operationsへ追加。Redis専用CAは絶対path・単一CA・有効期間を検査し、Redisだけへ渡す。hostname検証とrejectUnauthorizedを維持。月額試算は既存の無料枠非控除2735円に、512MiB hostなら990円、推奨1GiBなら1386円を加える。最低3725円・推奨4121円で、3000円目標と2200円新規受付停止条件を超える。資源作成・予算条件変更・remote gate変更はしていない。メモリ適合・実TLS/Redis/Tunnelは未検証。
2. 解約後：期限切れ確認から12暦月、unknown中の期限停止、active/grace確認で期限解除は既存処理を維持。通知の現行Cloudflare send()→messageId契約は既存adapterと一致。送信domain・Queue・delivery subscriptionの設定雛形をPreservationService/operationsへ追加。staging設定の通知2gateを明示NO。domain未定、実送信・送達・実Apple失効/再契約は未検証。物理削除を開始していない。
3. 表示/再試行：端末のみ/保管中/保管済み/失敗を分け、応答消失は「結果の確認」として別表示。本人別に状態を保持し、同じIDのdocumentとJPEGをdetailで照合するまで再PUT不可。照合は送信と同じミリ秒精度に正規化し、server所有updatedAtだけ比較から外す。入力中に未送信メモを端末Keychainへ保持。失敗時は文章を控える操作・再保存、未永続化メモがある間の閉じる保護を表示。Keychain読込失敗でも同じ本人のmemory draftと保管済み一覧を失わない。再契約の操作説明、期限の時刻/現在timezoneを追加。

### 検証と残る不確実性

- 初回の本修正候補は2026-09-30 11:33 JSTごろ。先行の接続先・費用・現状調査はこの候補作成前から行っており、局所テスト秒数をタスク全体の時間にしない。
- Billing strict typecheck +設定/Redis 15件が約8秒で成功、production build成功。公式CAを一時ファイルへ置く正のconfig-loadも成功。これはRedis TLS接続の証拠ではない。
- 保管期限・通知送信・delivery eventの3file/20件が約13秒で成功。実メールや実billingの証拠ではない。
- 独立レビューで当初の3点（ログイン解除で閉じる保護解除、Date精度で照合不一致、本人切替で未確定書込状態消失）を修正後、追加の修正必須指摘なし。static reviewである。
- WindowsではSwift/Xcode描画を直接実行できない。既存のfocused diagnostic routeで、同じcandidateのSoloMemoriesUITests/testManagedPreservationLostCopyResultShowsConfirmationAndStoredStateを1件実行する。このrouteはビルド後に既存runtime fixture 41件を準備確認し、Widget関連の内部ケースも含む。Widgetの画面操作job、全件CI、TestFlightは起動しない。端末同意・応答消失・同ID読戻し・stored表示、owner切替と日時精度を確認する。
- 過去focused diagnosticの所要時間は約14〜21分。通常pushの広域CIと混同せずdiagnostic/**を使う。これは配布証拠には使えない。描画・native挙動は結果が出るまで未検証。実Keychain障害、実保管復元・別端末・ZIPは依然未達。

### focused diagnosticのテスト修正

候補 `8e420b4` のrun `36662428729` は約9分でnative runtime準備に失敗。41件中40件成功、失敗はmanaged-preservation-membership-boundaryで、画面操作には到達していない。追加した本人切替テストが、Date()を含む保存前のCredentialをcompare-and-replaceの期待値へ使っていた。SessionStoreはwire encoderで日時をミリ秒に正規化し、読戻したCredentialとの完全一致を要求するため、この期待値は一致しない。テストは保存後の本人・tokenを照合した読戻し値を期待値に使うよう修正。製品の本人確認や保存方式は変更しない。

再検証は同じUI1件のdiagnosticのみとし、成功済みbackend・TLS・dry-run・開発ツール検査は入力不変のため再実行しない。予想は過去実測14〜21分、初回失敗9分を含むMac累計は23〜30分。調査・実装・レビューを含む候補全体は30分を超過しており、当初目標内の完了と報告しない。追加の失敗では再実行せず、まず最初の原因を特定する。

候補 `a3d93bd` のrun `36664005881` は約15分で終了。native runtime 41件は全成功し、追加した保管結果照合・Date正規化・本人切替・未永続化メモ保護も通過。UI1件は同意後の保存ボタン有効化の待機で失敗した。操作ログはSwitchのtapを記録し、録画末尾の画面では同意スイッチがOFFで、保存ボタンも無効。SwiftUI Formの行全体へ合成されたtapでは同意を変更できていない。UIテストを、会員確認完了を待ってスイッチ右端を押し、value=1を確認してから保存する形へ修正。製品コードは変更しない。

再々実行はしない。最後のテスト操作修正は未実行で、結果不明→照合→保管済みの画面操作は未完了。端末のみ表示・容量・期限説明の描画は録画で確認したが、未実行の状態の描画成功へ広げない。実Keychain失敗はoversized synthetic draftによる拒否経路の検査であり、実端末の障害復旧を証明しない。Mac計算時間は2回合計約25分、候補作成11:33 JSTからここまで約70分。次の実接続候補で、このUI1操作だけを確認してからアプリ配布判断へ進む。

### 今回の到達点

利用者依頼1〜3の配備資材・期限/通知結線準備・保管状態/再試行/未送信メモの実装は専用候補に保存。サービス受付・通知・削除はOFF、資源作成・main反映・TestFlightは行っていない。費用条件と本人所有のdomain、実Verifier/Redis/Tunnel、Apple契約と正当なSandbox会員、実保存/新session/別端末/ZIPが未達。今回の準備をサービス運用開始や全体完成と扱わない。
