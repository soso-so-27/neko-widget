# 本人削除：接続候補（未配備）

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
