# 個人保管：期限後消去の再出現防止と作業台帳（設計ゲート）

2026-09-25。基点は main `69e9e57`。公開保管、通知、期限消去はOFF。本資料は実削除の指示・証明ではない。

## なぜ既存の削除前fenceだけでは足りないか

- `pa_purge_fences` は`proposed/fenced/aborted`だけを持つ。`fenced`には10分のleaseがあり、停止した作業を自動で解除する。物理消去を始めた後にこの解除が走ると、欠けた写真を残したownerを再び使えてしまう。
- owner復旧policyがONなら、現行のDB triggerは`disabled/purge_fence_id`の変更を禁止する。S3に事前の取消・消去intentがない状態でfenceを本番運用してはいけない。
- D1のTime Travelで消去前へ戻すと、DB内だけの削除記録も巻き戻る。S3には全過去版が残り得る。通常のS3 DELETEは版を物理消去せずdelete markerを作るため、版ID指定の消去と再一覧が必要。

## 安全な状態遷移の提案

1. 新鮮な非公開課金結果が`expired`、12か月の持ち出し期限経過、同じApple通知先へのv2実配達、30日以上の猶予を照合する。`unknown`、会員復帰、連絡先変更なら停止する。
2. ownerへの新規書込と後片付けを止め、D1/R2/S3の全ページを二巡して不変の対象一覧・各版ID・件数・byte数のハッシュを作る。欠落、余分、途中変化は停止する。
3. 別の永続領域へ、ownerを直接示す写真・メモ・連絡先を含まない消去intentと対象manifestのハッシュを書き、実読戻しする。これが失敗したらDBのfenceも消去も始めない。実際の復元処理はこの台帳を先に読む。台帳に到達できない復元ownerは有効化せず隔離する。
4. D1でownerを停止し、期限・通知・世代・外部intent参照を一つの原子的条件で固定する。物理消去開始前に、leaseで再開放されない`erasing`状態へ移す。以後の障害は台帳から再開し、通常アクセスへ戻さない。
5. S3は全version/delete markerを版ID指定で、R2はownerの全objectを消す。D1は写真・本文・credential・連絡先・session・鍵参照を分けて処理する。途中の204や一回の空一覧を完了扱いにしない。
6. 全保存先を再一覧し、D1の参照も再照合する。消去証跡を外部台帳へ書き、復元試験では古いD1 bookmarkからの再出現を拒否できることを確認する。

## 保持と利用者への説明が必要な点

写真・メモを消した後も、古いDB復元による再出現を防ぐ最小の削除済み識別子が一時的に要る。D1 Time TravelはWorkers Paidで最大30日、Freeで7日と公式に記載されている。ただし手動の長期exportなど別の復元元を運用するなら、その保持期間も含めて識別子を保持しなければならない。**最終的な保持日数・置き場所・本人への説明は未確定**。35日は管理外の長期exportを行わない場合の検討値であり、現時点の販売条件ではない。

事前にユーザーへ約束する「削除」は、アプリから見えなくなる時刻、一次/復旧コピーの物理消去完了時刻、D1の過去状態が利用不能になる時刻を区別する。即時の全コピー消去とは表現しない。保管容量の上限とAWS Budgets通知も請求の絶対上限ではない。

## 実装・検証のゲート

- まず外部intentとD1作業台帳の形式、owner-boundな照合、再試行・二重実行・復帰競合を合成で実装。送信権限と版削除権限を分離し、公開Workerに版削除資格情報を置かない。
- `revokeOwner`や期限fenceのpolicy ON経路、復元時の台帳再適用、版ごとの消去と再一覧を一つの契約で検証する。D1 Time Travelを使った旧状態の隔離復元と、別端末ownerの本人確認も必要。
- 実AWS/KMS/R2で**合成データだけ**を削除して版・marker 0を確認し、最後に実iPhoneと請求状態の境界を確認するまで自動消去はOFF。課金不明・通知未達・S3失敗時はデータ保持を優先する。

根拠：[Cloudflare D1 Time Travel](https://developers.cloudflare.com/d1/reference/time-travel/)、[D1 Limits](https://developers.cloudflare.com/d1/platform/limits/)、[AWS S3の版別削除](https://docs.aws.amazon.com/AmazonS3/latest/userguide/DeletingObjectVersions.html)。
