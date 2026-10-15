# 980円のまま、普段の記録操作に保存・復元を組み込む

2026-10-16。候補 `ff3cf113d77deb73c04ceaa4d2c4fd829141a518`。月額980円は維持する。

## 実装した動作

- 設定の「保存・復元」で一度本人確認と説明への同意を行う。通常の写真メモ・ツール・猫情報の保存から変更分を自動送信し、毎回の別保管操作を不要にする。入力中の文章を送信する仕組みではなく、各機能が端末へ保存した内容が対象。
- 変更しない写真・JSONを再利用する。通信断・ACK消失・転送準備の欠落後も未送信分から再開する。アプリを閉じたりロックしたあとも通信が続くとは保証せず、次にアプリを開いたときに再開する。
- 同じ本人の完了した記録を検証して、通常のメモ・ツール・猫情報の画面へ復元する。元の記録と古い手動コピーを残す。未保存入力、端末側の変更、別端末との競合、本人や接続先の変更があれば上書きを止める。
- 復元した添付JPEGは、その端末の写真ライブラリ権限や別端末のPhotoKit識別子に依存しない。共有相手には自動送信しない。写真ライブラリ全体・原本・動画のクラウド保管は対象外。

## 運用開始と実装完了を分ける

**現行の期限切れ・完了済みツールtrialは、新しい自動保存には使えない。Sandbox会員情報の接続だけでは解決しない。** trialは一つのツールsnapshot専用で、通常メモ/猫情報や継続するCAS headに対応していない。旧trialの期限・counter・snapshotは変更しない。

既存コードには、新規登録0・既存本人1名だけ・有効なactive/grace会員情報・24時間以内の費用審査に結ぶ受付経路がある。登録上限0、総PUTと新規record各々の現期間counterに100回/128MiBの増分だけを許す案を準備した。counterをresetせずUTC月末を跨がせない。本人端末の署名で同じ既存ownerへ接続し、管理者INSERTや購入受付lease延長で代替しない。

この案は**未承認・未実行**。全体forecastと停止点が未確定のため、約14.4円の部分原価をforecastとして受付を開かない。forecast比較は実請求額の強制停止装置ではなく、受付停止後も読取・書出し・cron・履歴保管・固定費が続く。今回の互換クラウド更新は、この受付やtrialを変更しない。

## 1人当たりの費用

普通の利用を仮に「写真付きメモ1日1件、記録編集1日1回（30回のうち5回は5種のツール）、前月の写真30枚も保持した2か月目、年1回の全件復元」とする。実写真24枚の暗号化後平均は約0.93MB。ツール/猫情報7ファイルは500 UTF-8 bytesの共通合成本文による通信量計測で、各ツールの有効な入力やCPUの実測ではない。追加のツール写真は条件外。

- 保存・復元の既知小計：**月14.42494円/人（約14.4円）**。暗号鍵処理9.71円、S3操作2.61円、S3転送1.78円、R2/S3容量・R2操作0.33円。
- 既存共通固定費の対象部分：**月1,088.094円/サービス全体**（Workers $5/月、KMSキー $1/月、購入済みdomain初年度 $10.46/年を按分）。100人なら両者で**月25.31円/人**。3人という区切りは設けない。
- 予備費0、credit控除0。1人ずつ共通無料枠を重ねて引かない。変更しない写真の再送、無変化時のアプリ通信、復旧目録の全件複製を省いた経路で計算した。
- **全アプリ原価は未確定**。Workers実CPU・D1・JPEG/DO実資源・共有通信・終了後の保持分・Apple関連費/税等は別。動画原価を0円として含めない。長年ずっと同じ金額になる計算でもない。

日本のAppleアプリ内購入の公式条件は通常21%＋決済5%、該当する優遇や長期継続購読は10%＋5%。資格は未確認。980円に料率だけを掛けた比較は254.80円/147円で、税調整済み入金額や利益ではない。[Apple日本の料金条件](https://developer.apple.com/jp/support/app-distribution-in-japan/)

単価：[Cloudflare R2](https://developers.cloudflare.com/r2/pricing/)、[Workers](https://developers.cloudflare.com/workers/platform/pricing/)、[Containers](https://developers.cloudflare.com/containers/platform/pricing/)、[AWS KMS](https://aws.amazon.com/kms/pricing/)、[AWS S3東京の単価JSON](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonS3/current/ap-northeast-1/index.json)。為替は2026-10-14 17:00の1 USD=158.345円。

## 一般提供前に残るもの

有限の本人用受付の費用条件と有効化、本人端末による会員接続と自動保存の往復、一般量での長期の件数/容量/復旧性能。内部200記録/1GiB、native999file/1000piece/256KiB index、全D1capture/全S3履歴からの災害復旧、古い端末root保持の成長は未解消。数字だけ外して無制限と扱わない。

LPの自動保存方針の原稿・描画確認は別checkoutで準備済み、公開版は変更していない。一般公開・販売・外部配布・AWS Paid・新有料契約は未実施。

既存Codex定期「ねこのまどの配信保守」は1件ACTIVE、毎日09:00/21:00の登録を読取確認した。作成・更新・再実行は0。会話履歴の削除・移動・圧縮は0。

## 検査の経過の扱い

最初の候補13:13:38 UTC、最初のCI13:14:32 UTC、作業開始12:23:44 UTCを保つ。11回のnative診断失敗、e03/c946のowning Build失敗と未完nativeの取消しを成功にしない。DEBUG raw errorのprivacy違反と、billing検査の古い直接root仮定を修正した。未承認Build-only制御案は保存した草案で、採用・pushしていない。

旧Native12の3操作とdevelopment-flow15組は**e03の証拠**。コピーされた一部の中間計画の「this exactSHA」という表記をff3の成功として使わない。ff3はowning full runの実job/stepとSolo27＋28件を別に照合する。Windowsで実行できないSwift host検査はMacでの実成功が必要で、skipを成功にしない。

## 本線反映とクラウドの実結果

[PR332](https://github.com/soso-so-27/neko-widget/pull/332)をmain `a21df31c348ca91910c804d9868e7d77a3b88d51`へmergeした。候補ff3はその祖先であり、署名/アプリ/両backendの入力は固定したまま扱う。

- [同一SHAのowning iOS](https://github.com/soso-so-27/neko-widget/actions/runs/38785577584)：必須8jobすべて成功。Build必須39step、smoke/各Sharing実step、Solo27＋28件の実開始/成功が各1回で、失敗/skipなしを個別照合。全体103分59秒。写真一覧2本は直列で38分39秒と26分4秒。
- [同一SHAのPreservation](https://github.com/soso-so-27/neko-widget/actions/runs/38785577502)：必須8step成功。backend tree `5d0e05900d205cadb66ae4d80f929d52a0b2dc7e`はNode32＋Vitest538・migration5・署名/構成28の成功時と同じ。mainのiOS `38799962065`は既存成功の再利用で完了し、全nativeを重複実行していない。
- クラウド：最初のSELECTでHTTP403となり変更前に停止。既存WranglerのSELECTで認証を回復後、migration39/40を一度だけ適用した。次のreader uploadはHTTP400。read-only監査で40migration/全31記録/owner/trial一致、両Workerのactive/latest version・設定・cron・公開範囲不変を確認し、無条件retryしなかった。
- 別レビューしたresumeは、metadataの`workers/triggered_by`送信を除く輸送形式だけ変更。[Version Uploadの仕様](https://developers.cloudflare.com/api/resources/workers/subresources/scripts/subresources/versions/methods/create/)とWranglerの既存送信形式を根拠とし、bundle/runtime/bindings/secret継承は同一。DDL再送の経路を除き、API受理とGET versionの全設定照合後にreader `513ccd0e-04d2-443d-8289-ef44ccde4739`、writer `01e36ade-de15-4f20-8079-b24346f9b139`を順に100%反映した。31記録・owner/trial・cron・公開範囲・他gateは保持。paged recoveryだけを有効化し、一般受付/試用/通知や削除の設定を広げていない。
- TestFlight257：[失敗したworkflow](https://github.com/soso-so-27/neko-widget/actions/runs/38801049579)はruntime検査で停止し、署名/archive/uploadはすべてskip。protected変数でSandboxが承認済みでも、現在のlive reportON/billingOFFと、選んだSandbox profile（reportOFF/billingON）は一致しない。配布profileの選択を誤っていた。live gateや検査を変えて通さず、失敗と番号予約を保持する。
- **内部TestFlight258はAppleへのupload成功**：[run38801763284](https://github.com/soso-so-27/neko-widget/actions/runs/38801763284)、job116652316086、`2026-10-15T20:37:32.0569540Z UPLOAD SUCCEEDED with no errors`の実ログを確認。run全体成功、署名/公開範囲/metadata/Apple upload等の必須17step成功を照合した。既存continuation probeで実サーバーのreportON/billingOFFと非認証の拒否を先行確認し、独立レビュー後、同一ff3、既存承認済みpreservation-pilot＋internal-reports、media-stagingの通常CLIで一度dispatchした。既存protectedのYES/internal-owner-first-connectionを確認済み。Apple処理完了/端末での自動PUT成功は未確認。登録済みの同一installationの会員署名情報だけを使い、欠落時に購入・新規登録へ代替しない。

upload runは20:37:40 UTCに完了。初CIから443.133分、最初の候補から444.033分、作業開始から493.933分。元の400分計画は未達で、450分は途中の再計画用であり利用者の期限ではない。過去の失敗・取消・待機を除外した時間や、制御試案の未採用テスト結果を速度改善実績として扱わない。開発CI/Codex等は通常の保存1人原価の外で、今回その請求額を0円と認定していない。

private証拠の保存先：`C:/dev/neko-evidence/integrated-save-restore-20261015/`。`owning-ff3-qualified.json`、`cloud-resume-transport/completion.json`、旧writer/失敗とread-only監査/別resume review、costの計測と独立照合を保持する。試験用worktree作成operation `d0ee4986-172e-4ea2-81b6-a814dba61223`はアプリがcreatingのままでpath未返却。本作業は既存checkoutで完了させ、未知pathや会話履歴を削除していない。
