# 本人削除：非公開接続・アプリ検証完了、内部236アップロード成功

## 現在の状態（2026-10-02 03:06 JST）

以下の旧「未配備」「承認待ち」は作業経緯。現在は利用者の明示承認と1名の独立レビューを受け、PR151をmainへmerge済み。

- 個人AWS `164892691568` に `neko-preservation-staging-version-eraser` を作成。権限は既存bucketの `recovery/v1/*` に対する `s3:DeleteObjectVersion` のみ。既存writerを変更せず、秘密値は暗号化保管し非公開executorだけに接続。
- schema31、外部削除台帳sentinel、公開保管Worker `5284e6ae-f486-4a61-ac2d-5517b9cdc26d`、非公開executor `ea593aed-e713-4b8a-a149-c0a002a3e8e5` を配備。executorはURL/previewなし、HTTP404、5分ごとの実scheduled実行成功を観測。一般受付と実課金はOFFのまま。
- 合成ownerのS3全世代削除・別owner保持を実AWSで確認。その後、実private inventory/KMS・S3・R2・D1へ接続した合成削除でcompleted、全対象不在、既存実記録1件不変を確認。Apple token失効のみ合成callbackであり、実本人のApple連携を試験解除していない。
- backend候補 `985716a`、専用CI `36892637846` は75秒で成功。PR151 merge `2c811c2`。アプリはPR152。初回CI `36893711423` は26.3分でBuild/Photos/runtime成功、5UI中4成功。取消行のないiOS 26 popoverをテストが誤認したため、実AXを根拠に当該テスト本文を修正した。
- 中間候補 `778da52` のUIだけ再実行 `36898215490` は7分14秒で取消。アプリのログイン解除と永久削除に同じ「記録は削除されません」のfooterが掛かっていると確認したため。Build成功直後・XCTest開始前で、テスト成功証拠は増えていない。footerを両操作の違いが明確な1文字列へ修正した最終候補 `2ae7df6ad1c2a105454cf1ed29ccec8bd53559d8` で通常v6の4job/5UIを実行する。製品入力が変わったので中間候補の成功3job再利用はしない。Widget galleryは対象外。
- 旧失敗は固定run/SHA/1テスト/レビュー済み修正祖先と完全差分で「原因確認済み」と判定するだけで、診断成功・CI成功としない。後続失敗は引き続き停止し、配布には最終候補の全4job成功を要求する。新preflightは40件成功。`app-final-preflight.json` はready=true、旧失敗・取消を含むCI開始後46.8分と、次CI26.3分＋upload12.2分を記録。
- 実ユーザーに残る旧失敗write lease2行は、session作成から253ms/242ms後、旧raw-fetch経路の送信前例外、診断previewの開始前/停止後という履歴を独立照合。01:56 JSTにexact write_id/owner_id/started_atで当該2行だけ解除した。lease 2→0、owner1/record1不変、object削除0。旧bundleの暗号学的一致は再取得できておらず、これは当時の配備・コード・実行記録を合わせた照合である。一般のlease保持条件は変えていない。
- Apple契約ページの現在値はログイン期限切れで未取得。内部アップロードの妨げにはせず、実Sandbox購入・復元・期限切れの確認は別の未完事項として保持。
- 購入Gatewayの7受付gateとprotected `BILLING_SANDBOX_ENABLED/SCOPE` はまだ準備段階。購入ON版の必須readinessを満たしたとは扱わない。本人削除を先に `--preservation-pilot` だけの内部版へ反映する。会員入口は構成が揃った版のみ有効になるため、この配布を実購入入口の配布完了とは報告しない。

最終候補のCI：`36899697286`（開始02:28:59 JST）は22分6秒で成功。Build/Photos/両OS runtime/app-uiの4jobを実行成功し、UIは5件・失敗0件。削除の確認・通信切断時の受付・完了の実画像を確認した。1名の独立レビュアーが最終候補の製品・制御・全ハッシュ一致と、全4jobを維持することを確認済み。PR152をmerge commit `069548cfcfcf76501ea812718d920e7516b75b81` で本線反映し、候補のmain祖先関係を確認した。

内部236の[run 36902663038](https://github.com/soso-so-27/neko-widget/actions/runs/36902663038)を1回だけdispatchし、03:02:59 JSTに実際の `UPLOAD SUCCEEDED with no errors` を確認した。runは03:03:05 JSTにsuccess、作成から10分13秒。配布元は固定候補 `2ae7df6`、CI証拠は上のrun。`--preservation-pilot` のみで、購入ONの `--billing-sandbox` は指定していない。既存の内部配布許可に基づき当該runのtestflight環境だけ承認した。Apple処理完了・236の実機表示・実Apple token失効は未確認。

初回本人削除候補00:24:40からアップロード成功まで158.3分。会員入口候補10月1日22:37からは266.0分、保管完成作業全体の初回10月1日18:29:38からは513.4分。初回UI失敗26.3分、中間取消7分14秒、最終CI22分6秒、配布10分13秒と、その間の調査・修正・準備を含む。最終CIだけを総工数や時間短縮実績にしない。runner分は課金額ではない。

残件は実Sandbox購入・購入復元・期限切れ、購入Gatewayの受付/protected設定、一般提供の容量と人数の確定。Apple契約の現在確認はApp Store Connectログイン切れで、再ログインを1回依頼済み。容量は[比較案](2026-10-02-preservation-capacity-comparison.md)を準備したが決定・配備していない。今回の本人削除完了を保管サービス全体の一般提供完了とは扱わない。

証拠：`C:/dev/neko-evidence/owner-deletion-20261002/` 内の `cloud-connection-readback.json`、`executor-cron.json`、`live-deletion-chain.json`、`legacy-lease-reconciliation.json`、`app-final-preflight.json`、`app-final-ci.json`、`testflight-236.json`、`testflight-236-diagnostics/altool-upload.log`。削除UIの実画像は `app-final-ui/ios-26-2/composer-screenshots/manifest.json` に対応。実本人の写真を消す追試は依頼しない。

## 以下は時点別の作業履歴

現在の完了・残件は上段を優先する。以下の「未配備」「承認待ち」「lease残存」は当時の状態。

## 依頼と現在の境界

保管サービスを完成させる依頼は継続中。AWS接続・費用確認だけで停止したのは誤りだった。既存の許可で実装とローカル確認を再開した。一般公開・実課金・実ユーザーの削除・IAM追加・新Worker配備はまだ行っていない。

この候補は12か月後の期限削除と独立した本人要求による削除。Apple連携解除部品を、受付・外部受付票・書込停止・消去・確認へ接続した。期限purgeの会員失効や通知証拠を偽造していない。元写真、端末メモ、以前のiCloud、共有まど、定期購読の契約は削除対象外。

## 実装

- POST /v1/account-deletion：有効な本人sessionと明示確認。ownerはsessionから解決し、送信bodyにowner指定を認めない。端末が先に保管したランダムな受付tokenのhashをR2へ耐久記録する。
- GET /v1/account-deletion/:owner：専用受付tokenで処理中／完了を取得。通常のloginが失効しても確認できる。
- R2 `__owner_deletion/v1/` は写真の `personal/` 外。受付後のlogin、session利用、復旧書込、隔離復元を遮断する。古いD1復元でも外部受付を確認する。外部台帳が欠落した時は新規登録も止める。
- 独立した非公開Workerに限定した削除executorを接続。公開archive WorkerへS3削除資格情報を渡さない。別設定 `wrangler.owner-deletion.jsonc` は既定NO。
- 未照合書込・upload・期限fenceが残る間は待機。leaseの経過時間を削除許可にしない。R2新規書込も同じ永続leaseで保護。
- Apple refresh tokenを解除してから全R2写真・全S3世代の安定一覧を固定する。計画にない追加／差替えを検出したら止まる。削除後の再一覧とD1残存確認で完了を判定。
- schema31は本人要求専用のauthorityを追加。既存期限authority viewを変えず、該当DELETE gateに別型のauthorityを追加。migration適用のみで消去や受付は開始しない。
- アプリ候補は設定側のサービス保管に「アカウントを削除」を追加。明示確認、送信前のKeychain受付票、通信切断時の受付確認、処理中／完了表示、定期購読管理へのリンク。アプリ候補は別の購入入口候補へ統合して配布をまとめる。

## 得られた証拠と未確認

初回ソース作成：2026-10-02 00:24:40 JST。保管完成全体の初回は10月1日18:29:38 JSTから継続し、リセットしない。

- TypeScript型検査成功。
- 非公開executorのWrangler bundle dry-run成功（244 KiB、実配備なし）。最終の本人削除／pilot接続14件と型検査も成功。
- 本人削除9ケース成功：明示確認／本人境界、旧D1状態のlogin・書込・復元拒否、全世代削除と別本人保持、Apple失敗後の再開、未照合lease待機、DELETE成功だけで完了にしない、台帳欠落、既定OFF、固定計画外の版本拒否。D1 snapshot policy=1でも消去経路を確認。
- storage/recovery-write-leaseを含む該当3ファイル50件成功（追加2削除ケースの前）。その後本人削除9件を実行し成功。auth、既存期限fence／D1 eraseの該当36件も成功済み。
- 最初に既存lease fenceで1件失敗。外部受付時点で新アクセスを止め、未完writeが消えるまでD1 fenceを待つよう修正。その後snapshot policyを変更したテストが後続に影響するfixture不備と、既存pilot fixtureの台帳未初期化を修正。製品の既存拒否境界を外して通過させていない。
- R2直接bindingのread/list/delete整合性はCloudflare公式 https://developers.cloudflare.com/r2/reference/consistency/ で照合。CDN経由ではない。
- **Swiftのcompile、実描画、アプリ側の新しい操作テスト、独立レビュー、実AWS全世代削除、Apple実token解除は未確認。** Node成功を代用しない。
- 未照合の実S3 lease2件は残る。独立照合が済むまで実本人の消去を進めない。
- 完了後に古いD1を戻した場合は外部台帳が本人アクセス／隔離復元を拒否し、残存がある間は完了を返さない。隔離した復旧環境での照合は必要。古いR2/DBを無条件で本番化する経路は追加しない。

## 配備前に必要な具体作業

1. 変更した削除・認証境界の独立レビュー。自動で新agentを作らない指示があるため、1名でのレビュー実施を追加権限と一緒に質問済み。回答を待つ間も候補準備は継続。
2. 提案IAM user `neko-preservation-staging-version-eraser` と、同梱 `deploy/owner-deletion-staging-policy.json` の承認。個人AWS164892691568、既存bucketのrecovery/v1/*へDeleteObjectVersionのみ。既存writerは変更しない。鍵は非公開executorのsecretへ直接登録し、チャット・log・gitへ出さない。
3. 合成ownerで既存S3 live probeを拡張／再利用し、全世代削除・隣のowner保持を確認。実ユーザーの写真を試験対象にしない。
4. 外部台帳の初期sentinel `__owner_deletion/v1/format.json` を本文 `{"version":1}`（改行なし）で一度だけ用意し、読取確認。既存公開Workerへ新コードを配備する前に必須。災害時に欠落した台帳を空で作り直さない。
5. schema31、既存公開Workerの正しい現用設定を引き継いだ候補、非公開executorを準備。既存disabled baselineを誤って配備しない。費用／pilot終了／一般受付OFFを維持。
6. アプリ候補は購入入口候補とまとめて、変更経路のnative確認と1回の内部配布。広いCIはまだ起動していない。新規source/Keychain/fixture差分は既知scopeへ偽装せず、選択器を先に確認し必要な範囲へ設計する。

権限追加以外の実装・確認は改めて「進めて」を求めない。承認済みでない削除専用権限だけは、回答前に付けない。

## 00:52 JSTの候補固定と検証経路

- サーバー候補 `478832e706c212309d266dd9a9a697d539f87a4c`、上記checkout。アプリ候補は `C:/dev/neko-billing-sandbox-release-20261001` の `1dea1a5f2d2775b54d4ddfe98d0b01d29ff9645f`。既存会員入口 `79d5415` を保持して6ファイルを統合し、転送前後の全ファイルhash一致を確認。アプリ候補をサーバーPRへ混ぜていない。
- 双方のpreflightを各約6秒で実行し、**CI起動前に停止**。新backendファイル群と、アプリの専用Keychain storeが未分類で `full-v1` へ落ちる。これはデータ削除の必須試験という意味ではなく選択器の未対応。64〜98分の全件nativeとWidget galleryは起動していない。アプリを含めた一般CI／uploadは0回。
- 次の作業は独立レビューの指摘反映と、backend専用／このアプリ動作だけに対応する選択経路の準備。未知差分を既存profileに偽装したり、時間目標だけ110分へ伸ばして全件を起動したりしない。必要なnative描画・Keychain/通信境界は残す。
- `C:/dev/neko-evidence/owner-deletion-20261002/` に両preflight JSON、アプリ転送patch、非公開Workerのdry-run bundleを保存。新コード初回から約27分。保管完成全体の経過とは別。
- 承認質問は未回答。新IAM／本番の削除／配備を実行せず、候補を保持。独立レビューと実AWS削除を通していない候補を完成や安全確認済みと扱わない。
