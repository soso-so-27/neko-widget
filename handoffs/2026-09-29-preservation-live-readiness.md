# 個人保管 P1→P2 接続記録（2026-09-29）

目標は本人の写真1枚とメモをサービスへ保存し、同じApple本人が新しい端末／sessionから読み戻してZIPに書き出すこと。合成試験や設定追加をその達成と扱わない。最初の接続候補は15:57 JSTごろ。時間はこの候補から計測する。

## 直接確認した現状

- 基点 `02ca0418d2eaa30074298c616bce92af2f9ec8b6` の専用worktree。既存の汚れた研究checkoutは変更していない。
- Cloudflareの保管staging Workerは公開routeなし・受付OFF。secret名は `IDENTITY_INDEX_SECRET` と `KEY_WRAPPER_CALLER_SECRET` のみ。Apple認証、pilot本人一覧、S3資格情報は未登録。D1はowner/record各0、pilot enabled=0、復旧policyの2条件=0。従って実写真を受け付けない。
- private billing WorkerはOFF。共有staging D1はbilling account=0、active key=0、effective entitlement gate=0。実会員照合の成功はまだ不可能。nativeのPlus billingも既定OFF。
- private KMS WorkerにはKMSとcaller用secret名があるが、IAM鍵の有効状態はAWS再認証待ち。JPEG Workerも設定上OFF。S3の専用書込資格情報は保管Workerにない。
- Apple Developer `jp.nekowidget.app` App IDはSign In with Appleが未設定だった。利用者承認後にprimary App IDとして有効化し、再表示でONを確認。これで既存App StoreアプリプロファイルがInvalidになったため、同じ証明書を選んで再生成した。新プロファイルはApp ID一致、Apple Sign In entitlement `Default`、証明書1件をダウンロード現物で確認。AppleのProfiles一覧ではInvalidが消えた。GitHub `testflight` environmentの `APP_PROVISIONING_PROFILE_BASE64` を更新し、更新時刻を照合した。Widget/Shareのプロファイル・secretは変更していない。
- 利用者の続行指示を受け、AppleにNekoWidget App IDだけを対象とするSign in with Apple専用キー `KRG3JMSBCD` を登録。秘密鍵を一度だけDownloadsへ取得し、PEM形式とローカルACLを確認した。鍵本文は会話・Git・ログへ出していない。Cloudflareの同じ個人アカウントを照合して、非公開保管Workerの `APPLE_CREDENTIALS_JSON` に登録。secret名が存在し、現行deploymentの `PRESERVATION_ENABLED=NO` / `CLEANUP_ENABLED=NO` を再確認した。AWS SSMの暗号化控えが完成するまでローカルの一度限りの原本を消さない。
- AWS CLIのstagingプロファイルはsession期限切れ。最初の再ログインは既定の会社ブラウザを開いてしまい、利用者の指摘で中止した。`aws login --remote` で既定ブラウザ起動を抑え、Codex内ブラウザにサインイン画面を開いたが、利用者側には表示されなかった。したがってログイン完了とは扱わず、AWSの現在の鍵・bucket・IAMはこのバッチではまだ再確認できていない。個人用ブラウザから開ける公式サインインリンクを利用者へ渡した。
- Apple Developer画面には、最新のProgram License Agreementへの同意期限が2026-10-02と表示されている。契約本文の確認・同意は本人の判断であり、この作業では行わない。
- App Store Connectの「ビジネス→契約」は無料アプリ契約だけが表示され、有料アプリ契約は有効でない。「ねこのまど→サブスクリプション」にはグループも商品もない。Apple公式の[アプリ内購入の設定](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/overview-for-configuring-in-app-purchases/)によれば、Sandbox試験にも有料アプリ契約のActive状態が必要。よって現時点の実Plus会員の購入・照合は成立しない。契約への同意と税務・銀行情報はAccount Holder本人の判断・入力が必要。

## 固定候補の変更挙動・直接証拠・残り

アプリ側にManagedPreservationのビルド設定3値を追加し、既定はOFF。URLと会員audienceが両方妥当なときだけ入口を利用可能にした。Apple Sign In entitlementをホストアプリに追加。TestFlightの署名前チェックに、アプリだけ同entitlementを要求する検査を追加した。S3書込主体のstagingポリシーは `recovery/v1/*` のPUT/GET/版一覧と `purge/v1/*` の読取だけで、KMSと版削除を含まない候補を作った。

plist構文、プロファイル現物のApp ID/entitlement、CI preflight Python構文、JSON構文と禁止action不在、git diff空白検査は通過。Swiftの実ビルド、実Apple認証、実会員、実JPEG、S3書込、実iPhone、別端末復元、ZIPは未確認。無関係なWidget画面試験や全件CIを最初のprobeに使わない。
追加の局所確認として、disabled release設定11件と署名artifact認証4件は成功した。`Info.plist`・entitlements・xcconfig・TestFlight workflowを含む候補は現行iOS CIの限定ファイル集合に収まらず、pushすれば広域CIを選ぶ見込み。結線前の未完成候補では走らせない。

## 次の成立順

1. Apple専用キーを登録し、private keyを一度だけ取得して保管Workerのsecretへ入れる。ここまでは済んだ。AWSの暗号化控えは未完了。tokenや鍵本文をログへ出さない。
2. AWSを再認証し、同一アカウント・bucket versioning/公開遮断・KMS/IAM状態を照合。S3書込専用主体を最小権限で接続し、KMS既存鍵を再利用する。
3. 有料アプリ契約がActiveになり、商品・Sandbox購入が用意された後、実在するBillingAccountIDとApple側の正当なPlus権利を通す。`active`の仮置きでは済ませない。pilot本人HMACはApple検証済みsubjectからのみ作る。
4. 受付・復旧policy・会員/JPEG/KMSのgateを限定7日/最大3人の設定と共に結線して、1件保存→同ID読戻し→新session/別端末→ZIPを実証する。未達ならONにしない。

候補のpush/CI/TestFlightは、必要な設定が揃って範囲を固定した後に選ぶ。現時点で本線アプリ配布は行っていない。
