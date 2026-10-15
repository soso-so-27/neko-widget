# AWS再接続・実保存量と通知用ドメイン（2026-10-15）

**980円維持。AWS認証・S3全版本のmetadata・当月請求の未取得を解消。通知用ドメインは購入前、一般運用は接続前。** [直前の費用・公開準備](2026-10-15-nondevice-launch-readiness.md)の後続であり、その資料の「AWS期限切れ・未取得」は当時の状態。

後続：[利用者指定の `nekonomado.com` 購入・通知の接続準備](2026-10-15-notice-domain-connection.md)。以下のハイフン付きdomainは当時の候補で、購入していない。新domainの購入と規約/自動更新は承認・実施済み。

## 実際に確認できた費用と保存量

- 正規AWS CLI loginで既存profileを更新し、STSで既存ねこのまどaccountとの一致を確認した。cached sessionからの400とremote認証の失敗は成功へ読み替えず、最後の通常loginの終了0とSTSを接続成功の根拠にする。新しいIAM key・権限追加・Paid切替なし。
- 14:50 JSTに既存S3 bucket全体の全versions/delete markersを1pageで列挙完了。**129個・22,633,934 bytes（約22.6MB）**。写真25個/22,326,126 bytes、記録31個/106,525 bytes、commit目録31個/34,503 bytes、本人用目録42個/166,780 bytes。delete marker 0。異なるimmutable keyに過去世代が残るため、全件IsLatest=trueを「履歴なし」としない。
- 一覧は非atomicなmetadata観測。本文取得0、削除0、復元検証ではない。R2の24個とS3写真25個の差を、欠損・削除可能な孤立物と決めない。復元した添付写真の枚数とも別の集計。
- FREE/ACTIVE、残クレジット **119.36米ドル**、期限 **2027-03-25 13:30:49 JST**。AWS Billsの10月見込（14:49:54 JST更新）は**差引0.00米ドル**。東京の表示grossは0.45米ドル、KMS 0.45に無料枠credit -0.45。未確定請求であり将来無料・通常1人0円ではない。
- 使用中の参照KMS keyはEnabled、rotation OFF、過去rotation 0を確認。参照1本の標準固定費は[月1米ドル](https://aws.amazon.com/kms/pricing/)。他key不存在の全account証明はしていない。KMS APIは762回が共通無料枠内。S3/転送の表示0.00は丸め前の完全0を証明しない。
- Cost Explorer APIは従量課金を避け、認証済みBills画面で照合（CE API 0回）。保存データ本文は開いていない。

Cloudflareは既存Workers Paid/R2 Paid契約を認証済み画面で確認（次更新10/22）。**9/22〜10/21の課金周期、10/15までの従量費は表示0.00米ドル**。Worker requests 48.86k、CPU 169.84k ms、R2 A 4.01k/B 18.23k、Container/DO/D1、Queue 13 operations、Email 1通等がincluded内。これは基本料金を含む請求総額でも、ねこのまど1人の平均でもない。以前の直近30日analyticsとは期間が異なる。既存9/26請求4.76米ドルPaidの一覧を確認したが、明細のサービス帰属・税は未照合で、全額を本アプリへ配賦しない。

## 通知用ドメインの具体的な購入候補

利用者は、ねこのまど用の既存独自ドメインは**なし**と回答。Cloudflare内の他用途の登録domainを転用しない。

| 項目 | 購入前に確認した内容 |
| --- | --- |
| 候補 / 販売元 | `neko-no-mado.com` / Cloudflare Registrar |
| 用途 | 保管終了通知の差出人。アプリ全体で1件、利用者ごとの費用ではない |
| 現在の初年度小計 | **10.46米ドル**、1年、期限表示2027-10-15 |
| 更新料金の注意 | 画面の更新欄は10.46だが、同じ画面の告知で**2026-11-01から.comの登録・更新・移管が11.17米ドル**へ変更。次年更新を10.46と約束しない |
| 円換算の参考 | 初年度約1,660円、値上げ後年約1,770円。[日銀10/14 17時](https://www.boj.or.jp/statistics/market/forex/fxdaily/fxlist/fx261014.pdf)中間158.345円/米ドル。税・決済換算別 |
| 状態 | 認証済みcheckoutに候補が表示。購入・支払い・登録連絡先の送信・規約同意・DNS変更なし |

初期のpublic検索で「登録・更新とも10.46」と観測した後に値上げ告知を発見した。後続判断は上記を使う。候補の現在の取得可能性はcheckoutまで確認したが、取り置きはなく、最終支払総額・税は未確定。購入直前に再確認する。[公式の購入手順](https://developers.cloudflare.com/registrar/get-started/register-domain/)上、最終購入は規約同意を伴い返金不可。自動更新はcheckout既定ON（未保存）で、承認なく登録しない。既定の登録者連絡先は未検証・未編集なので、そのまま送信しない。

通知送信は既存[Workers Paidの月3,000通共通枠](https://developers.cloudflare.com/email-service/platform/pricing/)を使う候補。超過は1,000通0.35米ドル、Queue等は別。今回の画面でもEmail 1通/課金0、Queue 13/課金0を確認した。保管終了通知を今回送った証拠ではなく、過去の本人宛確認を再送しない。新しい月額メール契約を前提にしない。

## 購入承認後に接続する範囲と、残る別の判断

1. まず上記domainの名前・初年度費用・毎年の更新費を承認対象にする。税と決済換算を含む最終額、登録者情報、規約は購入時に確認する。domain承認をAWS Paid・一般公開・課金開始・実メール・cronの承認へ広げない。
2. domain取得後にCloudflare DNSと送信元のSPF/DKIM/DMARC等を準備し、既存 `NoticeMailProvider.send({to,from,subject,text})` とEmail bindingを接続する。provider受付のmessageIdを配達済みにせず、private Queueの実到達eventとaccount/zone/subscriptionを照合する。
3. **現在のscheduled経路はNOTICE_SENDにtracking/events/cleanup等のgateを要求し、cleanup後に通知を送る。** CLEANUPは一時upload等のGCも含む。通知テストのためだけにCLEANUPをONにしない。対象・安全性と本人の終了日根拠を確認してから接続し、全ownerの保持期限整理（reviewed-manual）と混同しない。
4. 会員終了追跡・unknown/再加入/未達での削除停止、全物理履歴と参照閉包、一般受付枠/支払継続/警戒・新規保存停止条件、LP/ストア公開適用は残る。AWS FREEの期限は12か月保持原資の保証にならず、将来のPaid継続には用途と費用を示した別承認が必要。

通常1人の総実費はまだ未確定。今回の22.6MBは現在の試用データ全体であり、一般利用平均へ変換しない。旧3人枠・月1万円案・予備費は採用/承認へ復活させない。980円は維持する。

## 保全・検証・証拠

- 新規契約/購入/有料切替/メール送信/データ本文取得/削除/アプリ再配布/定期タスク作成・変更・再実行は0。既存test grantの追加/延長なし。通常の既存cronを手動再実行していない。
- アプリ・Worker・CI・依存入力はmain `1be6faf0`から不変。内部256のApple uploadと既存成功検査を保持し、今回の記録変更を理由にMac CI/TestFlightを繰り返さない。256実機・別iPhone・v2保存往復等は前の記録の未確認を維持。
- private証拠は `C:/dev/neko-evidence/aws-reconciliation-20261015/`。`s3-versions-private.json`、`kms-metadata-private.json`は外へ添付せず、共有は集計だけ。認証code/tokenは資料へ保存しない。
- `s3-summary.json`の種別合計・全量列挙終了、当月creditの差引、円換算を照合。`domain-quote-before-purchase.jpg`と`domain-renewal-price-change.jpg`は個人情報を除いた価格証拠。公式価格・公開検索より後の認証済みcheckout告知を優先する。
- このbatchの開始は2026-10-15 14:35:52 JST。最初の認証失敗・再接続待ちも経過時間に含める。保存改善の最初の候補から内部256uploadまでの948.02分という累計は別の履歴として維持する。
