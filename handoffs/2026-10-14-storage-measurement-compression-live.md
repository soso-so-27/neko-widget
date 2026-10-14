# 保存量の実観測と管理情報圧縮

月980円を維持する。実機255の保存・別端末復元と独立して、既存クラウドのmetadata読取りと管理情報の可逆圧縮設定を進める。基点main2778db68。製品ソース、native、署名、CI、配布候補は変更しない。

## 実測できた範囲

既存Cloudflare資格情報で、D1の所有者別件数・bytes・世代、R2写真のkey/size metadataを取得した。写真本文・記録本文・資格情報の値を取得・表示しない。観測前後の9組のD1 SELECT結果は同一で、全queryのchangesは0。これはatomic snapshotや保存停止を意味しない。実ownerと集計値を含む証拠はローカルの `C:/dev/neko-evidence/storage-usage-20261014/live-observation/metadata-private.json` に保存し、公開repoへ転載しない。

R2 API応答にはresult_infoが無いため、観測したobjectの合計だけとする。全ページ完走の証明や未一致objectの不存在とはしない。[API仕様](https://developers.cloudflare.com/api/resources/r2/subresources/buckets/subresources/objects/methods/list/)ではページ情報自体が任意である。既存の汎用集計部品の完全なlive adapter接続は未完了。

S3はD1が保持する確認済み版参照の集計まで。既存AWS CLI profileのSTSはregion指定後にsession expiredとなった。全S3版本・未参照版・削除marker・費目別請求は取得できていない。失敗を0bytesとせず、D1台帳値をS3物理全量へ読み替えない。既に利用者が確認した無料枠画面を無効扱いせず、再ログインや手入力を独立作業の条件にしない。

現在の試験データは少量で、通常1人の平均利用量とはいえない。21MiBはowner一覧の上限であって通常値ではない。管理情報は今回の観測では圧縮開始閾値より小さく、圧縮gateを有効にしても直ちに請求が減ったとは報告できない。S3/KMSのrequest、転送、CPU、共通固定費も別途必要。

## 設定候補と復元の条件

既存archive version705195d9のlive module SHA256 `4b757248e745f55dac9aaf035a3829b7bfda3ae41ccca9d4faeaa09c1f10f86b` をそのまま使用し、`OWNER_RECOVERY_COMPRESSION_ENABLED` だけNOからYESへ変更する凍結候補を準備した。dry-run出力は同一module全文一致。既存の設定・secret参照・DB・bucket・公開範囲・受付条件・試用期限を維持する。

freshな全10Worker設定で同じS3 bucket参照を持つのはarchiveと既存削除executorだけ。owner JSON readerはOwnerRecoveryCopy.readで、新旧両形式をwrite gateに関係なく読む。HTTP/auth/storage/membership、scheduled repair/notice、notice queueも同じarchive実module内。削除executorはLIST/HEAD/purgeとjournalを扱い、owner JSONを読まない。既存versionf61cf178を維持する。通常billing/key-wrapperもowner JSON readerではない。offline復旧コードを使うときも現行dual readerが必須。

source afbee65から現mainまでcodec・owner-copy・bounded-body・関連testは不変。既存Workerdの新旧読戻し・所有者認証・破損・展開上限の成功を保持し、同じ試験やiOS配布を繰り返さない。実S3/鍵での圧縮canaryと実端末復元は未実証。

書込みは4KiB以上かつ10%以上小さくなるときだけ圧縮し、owner/purpose認証付き暗号化の内側に保持する。写真や古い履歴を圧縮し直さない。rollbackはwrite gateをNOに戻し、dual readerを維持する。圧縮世代が存在し得る状態で旧readerを配備しない。

## 検証と境界

初回設定候補は2026-10-14 12:38:20 UTC。既知の凍結module配備経路を使い、CLI timeout180秒＋readbackを計画枠とする（全工程の完了保証ではない）。必要な確認は独立reader/configレビュー、直前のversion/module/全Worker設定、配備後のmodule不変・変更がgate一つだけ・削除Workerとcronの不変。広いCIを最初のprobeにしない。

最初のreadonly準備はschedules応答を空配列と想定したassertionで停止した。実応答 `{schedules: []}` に合わせて準備コードだけを訂正。クラウド変更前の検査誤りで、製品不具合や配備失敗ではない。

一般公開、課金開始、AWS Paid、新規契約、実データ削除・backfill・trial再発行は含めない。既存削除cronの登録を読取り確認し、定期処理の作成・変更・手動再実行はしない。

## 実反映の結果

独立レビューで設定・reader互換にblockerなし。レビューで指摘された全Worker設定と削除Worker状態の証拠hashをplanへ固定し、直前照合へ追加した。2026-10-14 12:46:53 UTCにarchive version `9cd0f8b0-516d-4685-b8dd-70c3ca4058b5` の100%配備を確認。moduleは上記SHA256と全文一致し、bindingを含む設定差分は圧縮gateのNO→YESだけ。削除Workerのdeployment/settings/既存cron、archive公開範囲/schedules、D1の観測schema/受付/集計は不変だった。

初回設定候補からreadback完了まで8分34秒。初回準備の停止・独立レビュー修正を含む。Wrangler内部の同じcandidateに対するretryを含み得る既存配備経路で、単一HTTP送信とは主張しない。outer実行の重複はなく、mutation markerがある場合の再実行は拒否する。証拠はローカル `C:/dev/neko-evidence/storage-usage-20261014/compression/completion.json` とbefore/after、凍結module、plan、独立reviewに保存した。

現在の管理情報を再書込みせず、実圧縮canaryや請求減の実測はしていない。今後条件を満たす管理情報の新しい世代に圧縮が適用される。既存写真・履歴の削除、trial再発行、定期処理の手動実行、新アプリ配布、新規有料契約は0。

## 次に必要なこと

- 実機255でツールを保存し、同じApple Accountの別iPhoneで復元する。新規保存の既存試用期限は10月15日20:17 JST。
- S3全版本の観測とrequest等の費目を合わせ、実際の使い方に基づく1人原価を計算する。現試験データ1件を平均として販売計画に使わない。
- 新しいツールsnapshotで変わらない写真を再利用する設計。現v1はsnapshotごとにpartが束縛されるため、単純なhash/UUID共有や過去版削除は不可。参照保護・owner/epoch・削除再生・旧reader互換を含む別バッチが必要。
- 一般提供前の保持・通知・整理運用とLP/審査資料の整合。具体的な有料継続・一般提供の承認は別途必要。
