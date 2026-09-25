# 個人保管：Paid切替前の費用ゲート（未提供）

2026-09-25。利用者は「まず費用の上限を確認したい」と指定。AWSはFree plan、保管Workerと期限消去はOFF。Paid切替・販売容量の確約・公開提供はまだ行わない。

## 確認できた従量課金と概算

| 項目 | 公開単価・注意 |
| --- | --- |
| Cloudflare Workers Paid | アカウント最低 **$5/月**。既にPaidなら保管Worker専用の追加基本料ではない。超過CPU/要求は別。 |
| Cloudflare R2 Standard | **$0.015/GB月**、アカウント全体で最初の10GB月と所定操作数は無料。無料枠が既存用途に使われれば、保管分は最初から有料になり得る。 |
| AWS KMS customer-managed key | **$1/鍵・月**＋無料枠を超えるAPI要求。鍵の存在期間に課金。 |
| AWS S3 Standard・東京 | AWSの東京リージョン構成例では **$0.025/GB月**。これは見積もり用の参考値であり、Paid切替直前にはPricing Calculatorで現行料金・操作・転送も再確認する。過去版・未掃除objectも保管量に加算。 |

たとえば保管JPEG合計10GB、R2無料枠に他の利用がない、S3の暗号文が10GB、操作・転送超過がない**仮定**なら、上記の基本額は Workers Paid $5 + KMS $1 + S3 $0.25 + R2 $0 = **約$6.25/月**。既存のWorkers Paid料金、税、為替、S3の過去版、KMS/各storageの操作、AWSからの転送、写真検証の実行費は別。**請求上限ではない**。

最悪例として一人が50GiBを満たして1か月で解約し、その後12か月持ち出しを保証する場合、50GiB ≒ 53.7GB。R2無料枠を他用途で使い切っていれば、一次R2約 **$9.66**、S3一コピー約 **$16.11**、合計 **約$25.77** の12か月保管費だけが残る。実際には過去版、要求、転送が加わる。したがって50GiBを月980円の販売容量として先に約束しない、という既存判断は妥当。写真1枚の実サイズ、典型/上位利用量、解約率、過去版の増加を測って商品容量を決める。

## 「上限」と呼べないもの

- AWS Budgetsは通知や条件付きアクションの仕組みで、請求の絶対的な停止上限ではない。
- 既存の `GLOBAL_ACTIVE_STORAGE_LIMIT_BYTES` は新規の現行写真保存を止める。S3の全過去版、R2の清掃待ち、既存データの12か月維持、要求・転送費を止めない。
- AWS Free plan/クレジットの範囲は12か月持ち出し保証に使えない。Paidへの切替は実提供前に必要で、利用者の判断までは行わない。

## 次の実測ゲート

1. 合成データの限定運用だけで、R2現物・S3全版のbyte数、各操作数、KMS要求、Worker CPUを日次集計する。過去版も含め、想定と差が出たら新規保存を停止できる運用を先に作る。
2. まず小さな**試験専用**の全体容量・owner数に制限し、1件あたり平均/95パーセンタイルと編集後の版増加を測る。これは販売容量ではない。
3. AWS/Cloudflareの予算通知を設定し、通知先を利用者が確認する。通知をhard capと呼ばず、停止手順を演習する。
4. 実測した月額・12か月の解約後負債・商品容量案を利用者へ提示したうえで、Paid切替と一般提供を別々に判断する。

出典：[Cloudflare Workers](https://developers.cloudflare.com/workers/platform/pricing/)、[R2](https://developers.cloudflare.com/r2/pricing/)、[AWS KMS](https://aws.amazon.com/kms/pricing/)、[AWS東京リージョンのS3試算例](https://aws.amazon.com/jp/cdp/onpre-restore-backup/)、[AWS Budgets](https://aws.amazon.com/aws-cost-management/aws-budgets/faqs/)。
