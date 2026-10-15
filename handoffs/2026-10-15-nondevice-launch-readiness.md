# 実機以外の準備と費用判断（2026-10-15）

**980円を維持。今回の観測・計算・公開原稿は準備済み、一般運用の接続と総原価は未完了。** [クラウド反映・内部256のupload](2026-10-15-tool-storage-completion-internal256.md)の後続。人数3人、予備費、最大容量の一括投入を通常1人の実費にしない。アプリ・Workerの製品コードは変更していない。

## 今回進めたこと

- 既存Cloudflare接続で台帳・設定・object metadata・直近30日のアカウント集計を読取り観測。本文取得、利用者データ変更、メール送信、cronの実行・変更は0。
- 固定費と使用量を分け、人数を任意に変えられるオフライン計算を作成。解約後の保管者は費用には含め、売上の人数には含めない。無料枠はアカウント全体で一度だけ計上する。
- 実際のLP入口 `app/page.tsx → ExhibitionLanding` を確認し、ツールを含む保存・復元、手動保存、画面を開いて待つこと、個人保管と共有の区別をローカル修正版に反映。非表示の旧 `PricingSection` を現行ページと扱わない。
- [ストア説明原稿](2026-10-15-membership-store-copy-draft.md)と運用接続の順序を準備。旧local-onlyの署名・ストアmetadataは上書きしていない。
- AWS再認証後に使うS3全版本collectorを準備。既存アカウント・bucketを固定し、paginationの終了まで揃わなければ全量確認済みにしない。認証更新・key発行は行わない。

## 読取りで確認できた量

2026-10-15 14:09 JSTのD1前後の集計は一致。

| 観測項目 | 結果 | 限界 |
| --- | ---: | --- |
| 保存記録 | 31件、削除済み0 | JSON・目録を含む。写真枚数ではない |
| 写真の台帳合計 | 22,313,590 bytes（約22.3MB） | 全クラウド請求量ではない |
| 取得できたR2 metadata | 24 objects / 22,326,094 bytes | 全pageの証明なし、S3履歴は別 |
| 本人用の復旧目録 | 42 versions / 166,780 bytes | 既存履歴。削除していない |
| pending deletes | 0 | 観測時点 |
| 保管終了追跡台帳 / 通知送信記録 | 0 / 0 | 一般運用が動いている証拠ではない |

直近30日（9/15 14:11〜10/15 14:11 JST）の**アカウント全体**は、Containerメモリ0.831924 GiB時、disk 3.327696 GB時、CPU 141.75秒、送出778,603 bytes、DO duration 374.842828 GB秒。試験・他サービスを含み、通常1人の平均ではない。Containerの3資源だけを公式単価で計算すると、無料枠適用前で約0.01116米ドル（約1.77円）。基本料金・送出・DO等は別で、請求総額ではない。30日集計と課金更新周期も区別する。

14:24 JSTの追加集計では、アカウント全体・直近30日のWorker requestsは80,136、CPUは280,912.521ms、D1 rows readは1,453,155、rows writtenは27,138。公式のPaid共通枠と比較できる量を取得したが、課金更新周期・実請求との照合や通常1人への配賦は未完了。保管bucketの直近24時間のanalytics最大値は30 objects、payload 22,327,286 bytes、metadata 1,242 bytes。R2 listingと時刻・対象・集計が違うため、その差を記録欠損や削除してよい孤立物と判断しない。これは現時点の全object列挙や月のGB月計測の代わりでもない。

AWS profile `neko-preservation-test` はSTSで認証期限切れ。接続可能なChromeのAWSタブも操作接続できなかった。S3全版本・AWS請求・最新クレジット残高は未取得。旧残高119.39米ドルを最新値にせず、未取得を0円にしない。

## 何に費用がかかるか

通常1人の**総実費は未確定**。下記は条件付き小計で、平均原価・売上人数制限・予算承認・利益予測ではない。

- [Workers Paid](https://developers.cloudflare.com/workers/platform/pricing/)はアカウント全体で月5米ドル。[KMS](https://aws.amazon.com/kms/pricing/)はcustomer managed key 1本につき月1米ドル、rotationで追加の場合あり。**1本・rotation追加なしなら全体で月6米ドル**。実key version・請求は未確認。
- [R2 Standard](https://developers.cloudflare.com/r2/pricing/)は月10GBの共通枠を超える保存が0.015米ドル/GB月、課金単位を切上げ。[S3東京の公式価格表](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonS3/current/ap-northeast-1/index.json)は先頭帯が0.025米ドル/GB月。履歴・復旧情報も物理量に含める。
- [通知](https://developers.cloudflare.com/email-service/platform/pricing/)はWorkers Paidに月3,000通の共通枠を含み、超過は1,000通0.35米ドル。Queue等は別。別の定額メールサービスを先に新規契約する前提を置かない。実際の枠・送信元等は未接続。
- 円換算は[日銀10/14 17時](https://www.boj.or.jp/statistics/market/forex/fxdaily/fxlist/fx261014.pdf)の中間値158.345円/米ドル。税・カード換算・為替予備費は加えていない。

**比較例：全員がR2に物理1GB月、S3全履歴にも物理1GB月を保存し、R2共通10GB枠が使える場合。** 1GBは実測平均や販売容量ではない。固定月6米ドルの条件を使用。

| 有料会員数 | 全体の固定費＋保存費の月小計 | 有料会員1人あたりの小計 |
| ---: | ---: | ---: |
| 1 | 約954円 | 約954円 |
| 10 | 約990円 | 約99円 |
| 100 | 約1,560円 | 約16円 |
| 1,000 | 約7,260円 | 約7円 |

これは**一部費目のみ**。アプリ全体のrequest・CPU・D1/DO、S3/KMS API・転送、通知/Queue/domain、Apple手数料・Developer年会費・税等は未加算。100人が有料、別の100人が解約後も同じ量を保管する例なら、全体約2,193円、有料会員1人あたり約22円。売上0人でも保管費は残る。

[Appleの日本向け条件](https://developer.apple.com/jp/support/app-distribution-in-japan/)は通常21%＋Apple決済5%、条件を満たす場合10%＋5%。本アカウントの優遇資格は未確認で15%を既定にしない。税込980円からの実入金には税・refund等の照合も必要。上表と合わせて利益と呼ばない。

## 安くする方針

- 256に入った未変更写真の再利用を使い、編集のたびに添付写真を丸ごと重複保存しない。実際の削減率・請求減は未検証。
- 選んだ保存用JPEGに絞り、原本・動画・全ライブラリ自動保管を新たに約束しない。
- 基本料金と無料枠を人・サービスごとに重複計上しない。画像検査を常時起動する前提にせず実際の資源量を集計する。
- 通知は既存構成への接続を優先。復元に必要な履歴は、参照閉包・復元確認なしで削らない。保持12か月・実到達後30日を費用の都合で短縮しない。

## 一般運用を接続する順序と承認境界

14:09 JSTの実設定はtracking/send/events/cleanupとbillingの各gateがNO。mail・queue bindingなし、archive cronなし。**既存の本人退会削除Workerはexecutor YES・5分ごとのcron 1件**。保管終了時の整理OFFと混同せず、どちらも変更・手動実行していない。

1. **読取り測定を完了**：既存AWSログインが使える状態でS3 collectorを実行。R2全量性、全体のrequest/CPU/D1/DO、実請求・共通無料枠を照合する。測定のために試用追加保存を促さない。
2. **支払候補を確定して承認**：一般運用の月額・警戒額・新規保存停止額・停止後の保管費の支払方法を具体化。旧1万円/月や15万円予備費を復活させない。AWSの有料継続への切替は用途・継続条件を示した承認後。今は新規契約しない。
3. **会員状態の追跡**：正規membership authority、終了日の根拠、unknownで停止、再加入を接続・検証。試用期限を会員の終了日に代用しない。
4. **終了通知**：本人のdomain/sender、Email Sending、private Queue、到達eventのaccount/zone/subscriptionとsecret参照を確定。既存providerを使い、受付messageIdだけで到達扱いにしない。未達・古い連絡先・再加入で削除停止。実メール送信・新しい有料設定・cron追加は未実施。
5. **整理と公開枠**：全S3版・復旧コピー・参照・書込中データのinventory、復元確認、具体的な削除対象と独立確認を揃える。最初はreviewed-manual。一般の上限・同時予約・受付停止・持ち出し証拠を既存 `operating-readiness.mjs` に接続し、新規課金を先に開けない。
6. **原稿適用**：LP・ストア・アプリの容量/保持/購入条件を一致させ、一般公開の承認後に適用。256uploadは一般販売開始の証拠ではない。

今回完了したのは観測、計算、原稿、collector、接続順序の準備。実機以外にも上記の接続・測定・費用承認は残る。

## 検証・保全・次回の入口

- LP: `C:/dev/neko-lp-offer-alignment-20261001`、branch `codex/tools-preservation-copy-20261015`、local commit `6098923`。Site `appgprj_6a90e385f1e08191b946a58203cf14d7` はpublic/version134のまま。source同期・save/deployは0。既存untracked archiveは変更なし。
- LPのTypeScript検査と既存conversion境界検査が成功。実ブラウザーのローカル表示と保存条件を開く動作を確認。未確認の狭い画面や一般公開版を確認済みにしない。
- 費用計算の4検査（共通枠・切上げ・売上0人・解約後保管の分母）成功。S3 collectorは構文検査のみ、期限切れAWSに再実行していない。
- 証拠・計算source: `C:/dev/neko-evidence/nondevice-launch-readiness-20261015/`。`metadata-private.json` はowner/key/settingsを含むため外へ添付しない。共有は集計だけ。`readiness-summary.json` は一般運用未準備、`cost-components.json` の総原価欄は未確定。
- Codexの既存定期タスク「ねこのまどの配信保守」は1件、ACTIVE、毎日9時・21時。追加・変更・再実行0。Cloudflareの既存cronとは別。
- 製品入力不変のため既存成功検査・クラウド反映・256uploadを保持し、今回Mac CI・TestFlightを繰り返さない。新しい動作変更時は必要な検証を選び直す。
- 今回の準備開始は2026-10-15 05:02 UTC（14:02 JST）。保存改善の初回候補からuploadまで948.02分という累計・旧失敗履歴を上書きしない。
