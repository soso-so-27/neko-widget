# 大容量書き出しの完走と公開費用の更新

2026-10-08 23:48 JST、現行製品コードによるローカルの1,000件書き出しが完了した。写真4,998,000,000 bytes、暗号化metadataを含むquota会計4,998,964,890 bytes。77ページすべての写真SHA256・長さ、メモ・順序・ID・revision、complete/cursorを検証し、最終lease解放、inventory/generation不変を確認した。写真は合成bytesであり、実機ZIP・本番CPU/メモリ・実JPEG/KMS/S3/Appleの通し成功ではない。

製品・設定・許可・期限・費用基準は変更していない。測定した固定ソースは `e8372960160b7fb520e01fafd94cae717e281686`。PreservationServiceのtracked treeは開始時main `efc40975d2e759579be81031efbb8d9374a820b5` と同一。検査側はcheckout外。新しいアプリCI・配布は不要で、内部TestFlightは本人向け247が利用可能、247の実機導入は未確認のまま。

## 前回から変えた検査方法と時間

前回はfixture準備に15分sessionの約3分47秒を使い、consumerが大きな未完文字列全体を繰り返し走査していた。同じ13件で旧方式→新方式→新方式→旧方式の4比較を行い、全bytes・SQL・D1読取・unwrap数が一致、平均12.677秒から5.542秒になった。製品の高速化実績ではなく、ローカル検査側の差である。

この直接証拠を得てから、chunkを一度だけ走査し、完成した1レコードごとに連結・厳格UTF8/JSON・写真hash検証するconsumerへ変更した。fixture準備後に同じ合成本人で実装どおりの15分sessionを取得し、計測前に復旧ackをfixtureで確定。期限は延長せず、完了ページ境界で残り210秒未満なら停止する方針。実アプリの明示的な同本人再認証は実装済みだが、今回は途中再認証を使わず完走した。合成identityをApple認証成功と呼ばない。

書き出し4分48.375秒、準備・終了処理込み7分27.176秒で、今回の見込み10〜15分以内。前回中止13分09.185秒と小比較47.204秒を含む3実行の合計は21分23.565秒。最初のexport計測候補22:20:56から完走23:48:22までは87分26秒で、調査・公式まど配備を含む。前回の5〜12分見込み超過は保持する。

## 処理量と費用

全1,000件でSQL22,077回、D1読取164,391行・書込231行、R2 GET21,770回、unwrap2,000回。R2は削除format10,385、存在しない削除request10,385、写真1,000。wrap・R2書込・想定外復旧呼出し0、D1行数metadata欠落0。欠けた削除requestもGET試行として保守的に数えた。D1の同一SQL `all()`先頭投影による計測とnative firstとの7比較を保持した。outer Worker設定/IP制限、認証・再認証、native最終一覧照合、失敗ページ等は別。ローカル所要時間を本番CPU課金時間に置き換えない。

以前の保存・編集・復旧モデルの依存ソースを再照合。`storage.ts`全体のhash不一致で一度停止し、exportのbinary経路、同じreadのbase64投影分離、validateRead追加の差分を確認した。`put`以降のbyte一致と他の復旧・暗号化関連11ファイルの一致を根拠に、その範囲のモデルを保持。古いexport回数は完走の実測へ置換した。

既存AWSログインで本人アカウント一致後、`GetFreeTierUsage`を読取。KMSは月20,000回に対しactual64、forecast248。転送/S3の該当値はなく、欠落を使用0・残枠十分とは扱わない。課金対象のCost Explorer照会や契約・権限変更は行っていない。

試算は3人×十進5GB/1,000件を初月に埋め、合計300件の編集・300回の失敗を仮定。確認済みCloudflareの操作枠とKMS残枠を条件付きで適用し、将来の他用途消費は含まない。AWS転送枠と丸められたR2保存枠は控除なし。Workers $5とKMS鍵$1を全額配賦、Container月10時間は従来仮定。計画換算198円/USDで、実為替・現在の請求ではない。

| 各人の全量書き出し | 復旧対象 | 初月の部分小計（円） |
| --- | --- | ---: |
| 月1回 | なし | 2,124.49〜2,178.32 |
| 月1回 | 1人 | 2,367.59〜2,421.42 |
| 月1回 | 3人 | 2,853.80〜2,907.62 |
| 月30回 | なし | 2,227.85〜2,281.68 |
| 月30回 | 1人 | 2,470.95〜2,524.78 |
| 月30回 | 3人 | 2,957.15〜3,010.98 |

幅は失敗が暗号化/保存前に起こる場合と、復旧コピー準備後・DB確定前に起こり孤立物を月いっぱい保持する場合の差。発生確率・全失敗の上限ではない。3人復旧は3個の独立した空の隔離先への作業量で、同じ非空対象への復元機能の証拠ではない。復旧先の保持期間・追加保存費は未確定。

実CPU、保存/編集/認証等のD1行数・保存量、JPEG/Container/DOの実負荷、認証・通知・履歴・再試行等を含まないため、**完全な月額forecastではない**。既存2,200円受付停止に対し、軽い条件でも余裕は約22〜76円。毎日の全量exportや復旧を含む条件は未計測分を加える前に超える。AWS転送枠の確認で試算が変わる可能性があり、採算不能・即時請求増を断定しない。全無料枠0のストレス条件も別途保存した。R2の切上げをexportごとに重複課金していない。

料金は [R2](https://developers.cloudflare.com/r2/pricing/)、[Workers](https://developers.cloudflare.com/workers/platform/pricing/)、[D1](https://developers.cloudflare.com/d1/platform/pricing/)を本日再確認。AWS東京のS3/DataTransfer単価は本日取得済みの公式price listを保持。読取APIは [GetFreeTierUsage](https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_freetier_GetFreeTierUsage.html)に照合。

## 残る条件

ローカル全件export未完は解消。実iPhoneの全量ZIP、本番CPU/メモリと代表的な保存処理、AWS転送枠を含む完全な費用予測は未完。AWS無料プラン終了後も12か月保管を履行する継続契約と、販売容量・受付ペース・費用停止の整合と承認が必要。通報の実対応確認、実失効、ストア最終構成も維持。`publicReady=false`、一般受付・容量・停止閾値・pilot期限は変更していない。

証拠は `C:/dev/neko-evidence/launch-readiness-20261008/` 以下の `export-reader-diagnostic/result.json`、`export-complete-probe/{plan,result,assessment}.json`、`preservation/aws-free-usage-readonly.json`、`preservation/current-conditional-cost-20261008.json`。前回中止記録も保持。
