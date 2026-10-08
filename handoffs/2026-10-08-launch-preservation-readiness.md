# 公開保管条件の事前確認（2026-10-08）

販売案の容量・人数・費用を、既存pilotの確認済みというbooleanだけで通さないローカル確認を追加した。公開案、レビュー済みplan、実配備の容量と受付値、利用者単位の制限、保管継続中の人を含む容量予約を照合する。新しい1人分のquotaを確保できない場合もreadyにしない。承認や配備を行う道具ではない。

対象は `operating-readiness.mjs` とそのNodeテスト、READMEのみ。元のpilot確認は維持。11件成功（約0.47秒）、容量境界・期限・費用閾値・受付値・未承認/不正入力を含む。クラウド設定、pilot期限、受付量、購入条件、通知、削除に変更はない。

13時前後の読取では、保管は1人・1件、D1会計3,358,122 bytes。配備容量は1GiB/200件、全体3GiB。pilotと費用レビューの期限は過ぎており、enabledフラグだけを新規受付可能の証拠にできない。直近24時間のR2集計は7objects・payload最大3,358,413 bytes。10月1日からのaccount集計でListObjects1,870回、成功GetObject7,553回などを確認した。これは請求明細・将来の無料枠・S3全世代の実測ではない。

既存の一般案は十進5GB/1,000件/保管継続中を含む3人で未承認。現行の共有月間3GiB/新規300試行/変更500試行のままでは、1人がその容量・件数を1か月で満たすこともできない。容量だけ増やして販売条件を成立した扱いにしない。レビュー済みの利用者単位30回/分と、現配備のIP単位120回/分にも差がある。

料金の感度分析では15GB満量、復旧1世代、既存固定費・Container月10時間・予備500円を仮定すると、R2無料枠全量が使える場合は月1,828円、使えない場合は月2,820円。実請求予測ではない。履歴10世代ならそれぞれ2,450円/3,442円となり、既存の新規受付停止2,200円を超える。受付ペース・履歴を含む実測に合わせた案が必要で、費用上限を自動変更しない。

14:45 JSTの本人ログイン後の読取で、個人AWSアカウントを照合し、S3の全ページ・全世代を集計した。10オブジェクト版・3,377,890 bytes、非現行版0、削除マーカー0。すべて `recovery/v1/` で、ほかのprefixは0。10枚の写真や10個の復旧世代を意味しない。ObjectLockとLifecycleは未設定であることをエラーコードから確認した。写真本文の読取・削除・設定変更は行っていない。

実配備のKEY_WRAPPERが参照する東京の顧客管理KMS鍵と、AWSで読んだ鍵ARNは一致した。有効、単一リージョン、自動ローテーションOFF、完了したローテーション0。S3の既定AES256暗号化とは別にアプリの鍵ラップに使う鍵である。現在の鍵1本の通常月額は$1で、現在量を丸1か月保持するS3本体分は約$0.000079という試算になる。リクエスト・転送・ほかのサービスを含む請求額ではない。

AWS `GetAccountPlanState` の実測はFREE/ACTIVE、残クレジット$119.59、期限2027-03-25 13:30 JST。残額が先に尽きればそれ以前に終了する。[AWSの仕様](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/free-tier-plans.html)では無料プラン終了時に利用できなくなるため、現状の契約だけでは公開後12か月の保管継続を約束できない。公開前に予算を伴う有料プランへの移行条件を確定する。契約変更は未承認・未実行。無料クレジットを恒久的な原価0円や費用上限の証拠にはしない。

残件はリクエスト・転送・共有無料枠を含む費用予測、販売条件と受付ペースの整合と承認、AWSの継続利用条件、利用者単位の制限の接続、および実際の解約・期限切れ時の確認。現時点のpublic readinessはfalse。公開可能・一般受付ONとは報告しない。

証拠は `C:/dev/neko-evidence/launch-readiness-20261008/preservation/` の `live-readonly.json`、`r2-usage-readonly.json`、`public-cost-proposal.json`、`validation.json`、`aws-inventory-readonly.json`、`key-binding-readonly.json`、`aws-account-plan-readonly.json`、`aws-cost-and-continuity-assessment.json`。料金源は [AWS KMS](https://aws.amazon.com/kms/pricing/) と同ディレクトリの `aws-s3-price.json`（公式東京料金表、2026-10-08取得）。初回候補は12:38 JST。ローカルチェックだけでApple環境や配布を検証済みとはしない。

19時時点では、保管写真を3人同時に書き出すローカルworkerdのメモリ問題を修正した。写真全体のbase64と日本語metadataを一つの文字列にする経路を除き、復号bytesから最大1MiBずつ送る。同一isolateの大きい処理は同時1件に制限し、通常取得・保存・写真を読む削除・修復との重複も抑える。待機は最大16件/30秒、写真応答120秒、session15分は延長しない。取消中の読込完了まで枠を保持し、各chunkの本人・更新・削除確認と最終complete判定を維持する。

20MiBの暗号化写真を使う同一isolate計測で、3人同時exportは最大観測87.26MiB、detail混在/低速読取は67.28MiB。初期の疎な観測は243.26MiBで、同じ実配備互換設定での文字列分割だけの中間候補でも約250MiBだった。Inspectorのused/embedder/backing合計であり、本番128MiBへの適合保証ではない。実行中に強制GCせず、本文をため込まない外部consumerで測定した。最大PUT単独、販売5GB全体の実機完了は未確認。

書き出し46件と影響する保存・復元・認証・payload補助の91件、合計137種類のテスト、型検査が成功。独立レビューでP1/P2なし。既存テストの本文未消費を修正し、30件準備する1ケースはUTC分境界の最大4秒待機を含めて10秒のテスト期限とした。製品期限・件数・429・本文検証は維持。初期失敗、npm経由のフィルター不適用による重複実行も費用/時間記録へ残した。証拠は同evidence rootの `export-memory-validation.json` と `export-memory-chunked-probe/encrypted-path-result.json`。今回のメモリ修正は約35分、12:38の初回候補からは約6時間24分（待機・他修正・診断を含む）で、CIだけの実行時間ではない。

このメモリ修正は未配備。本人向けTestFlightは1.0(246)のまま。cf7fe22のApple再認証付きexport診断成功は保持するが、通常の配布用CI証拠には代用しない。最終の製品差分を固定し、既に調査した必須範囲を厳密なCI選択へ接続する工程が残る。公開費用は操作/転送/隔離復元を加えると無料枠なしの部分小計でも月3,883.60〜4,041.18円となり、従来の2,200円受付停止/3,000円目標と不整合。CPU/D1等の残額も未算定で、公開案・AWS契約・権限・受付・期限は変更していない。

## 21:14 JST以降の統合・実配備

上の19時時点の未配備状態は更新済み。候補 `e8372960160b7fb520e01fafd94cae717e281686` の関連4 UIはrun `37772225394` で全件成功（24分03秒、23.75 runner分）。元候補 `feb9c756` のBuild/privacy/migration・Photos・両OS runtimeと両backendの実成功を、入力不変と実job/log照合で保持した。既存Family fixtureが共有シートを強制終了してZIPを残したため、実際のキャンセルを完了してから再起動するテスト修正だけを加えた。原本維持と一時ファイル0の条件は緩めていない。元の通常CI失敗22分58秒と、原因切り分けの3 UI成功19分01秒も時間記録に含む。

main `b1925f9cbec6be0fe974b5f0697cc49ae3220081` へmerge commitで反映済み。mainとの差は承認済みCI制御2本だけで、製品・署名・backendは同じ。main側run `37775329413` はその制御差分による全tree不一致で停止し、Macを重複起動しなかった。この停止を成功扱いにせず、既存CLIの `--checkout` で検証済み固定候補を配布する。mainのPreservation `37775329301` とSharing `37775329480` は成功。

既存非公開保管Workerをversion `6050c487-1b03-41e8-8993-2771f7dd39f1` へ更新し、migration32/33を適用した。実moduleはレビュー済みbundleと完全一致。保存済み1本人/1記録/3,358,122 quota bytes、設定・secret参照・DB/R2/service binding・公開範囲・cron・受付と期限を前後保持。本人データの削除0、一般受付の開始・期限延長・新契約・権限変更なし。旧246との互換を保持する。実機の新しい大量exportの完走は未確認。

内部247はrun `37775869422` で21:29:42 JSTにAppleへアップロード成功。全配布runは11分56秒、11.083 runner分、追加dispatchなし。本人1名の「自分用」グループと既存の自動配布を実画面で確認済み。Apple処理完了後、1.0(247)の「テスト中」・「自分用」を確認し、本人が更新できる状態になった。247の実機インストールと新しいexportの完走は未確認。証拠は同evidence rootの `export-corrected-qualified-ci.json`、`export-main-integration.json`、`export-deployment/completion.json`、`testflight-247-apple-availability.json`、`testflight-247-completion.json`。初回候補12:38 JSTからアップロードまで約8時間51分（失敗・修正・診断・別の公開準備を含む）で、最終CI24分だけを作業全体の時間としない。当初60〜90分の見込みは超過した。

公開残件は、実機のStoreKit価格一致と解約後の実失効、販売容量・受付ペース・費用停止の整合と承認、AWS無料プラン終了後の継続条件、本番メモリと実5GB export、通報の実運用・担当者の対応確認、最終公開構成とストア申告である。購入・復元の既確認結果を繰り返さず、既存の10月9日失効確認と公式配信保守automationは変更していない。public readinessは引き続きfalse。

### 費用モデルの追加確認

`preservation/public-cpu-d1-boundary-20261008.json` に現行経路と公式単価の照合を保存。月3,831〜10,530 requestは実測でなく作業量の仮定であり、CPU時間とD1課金行数の実測はない。SQL回数を課金行数やCPU時間で代用しない。1MiBごとの認証・削除確認を加えた現行exportと旧試算のsource hashは一致しないため、上記3,883.60〜4,041.18円も現在の完全な予測として再利用できない。

[Workers CPU](https://developers.cloudflare.com/workers/platform/pricing/)は100万msあたり$0.02、[D1](https://developers.cloudflare.com/d1/platform/pricing/)は読取100万行$0.001・書込100万行$1・保存1GB月$0.75。計画換算198円/USD、無料枠なしでは、仮定した総平均CPU100ms/requestなら月1.52〜4.17円、1秒なら15.17〜41.70円となる。これは感度計算であり、実費・上限・forecastではない。実CPU、D1のrows_read/rows_writtenとDB保存量、共有無料枠を含む現行経路の観測が必要。

既存の「無料枠0・固定費全額配賦・R2両操作クラスの正の使用を各100万件単位に切上げ・Container月10時間」仮定では、容量による保存/転送とCPU/D1を加える前で2,205.74円となり、受付停止2,200円を超える。同アカウントの限界費用の下限を示すものではないが、単に販売容量を小さくすれば通るという根拠もない。現在の完全な予測を先に確定し、容量/件数/人数/受付条件と予算・AWS継続契約の判断を分ける。料金枠・契約・実受付の変更は行っていない。

### 22時前後の実績取得で補えたこと

Cloudflareの既存認証でGraphQLの集計を読み、10月1日00:00 UTCからの実績を保存した。アカウント全体でWorker呼出し21,068回、CPU 54.228秒、D1読取290,493行・書込3,704行。DBごとの最大サイズの合計は2,830,336 bytes。保管DBだけでは読取10,688行・書込236行、最大544,768 bytesだった。写真本文・SQL本文・個人の記録は取得していない。これは請求書や公開後の月額予測ではない。

CPU・D1行数の3項目だけを、無料枠0・計画換算198円/USDで換算すると約1.006円。固定費・DB保存・リクエスト・Container・R2・AWS等を含まず、アプリ全体の費用とは呼ばない。実績が小さいことは分かったが、配備更新後の集計には新しいexport本体の呼出しが現れず、大容量の代表的な処理を測れた証拠にはならない。過去の少量利用を5GB提供時の原価へ直接外挿しない。

請求期間を確定する公式のsubscription GETはHTTP403/code10000だった。Analytics読取の成功と請求情報の読取権限は別で、権限追加・回避・契約変更は行っていない。既存ログイン・請求権限での期間/無料枠確認と、現行経路の代表的な大容量操作の計測が残る。一般提供条件を勝手に変更せず、`publicReady=false`を維持する。

追加証拠は同evidence rootの `preservation/cpu-d1-schema-readonly.json`、`cpu-d1-usage-readonly.json`、`cloudflare-subscription-period-readonly.json`、`observed-cpu-d1-assessment.json`。数値の意味は[公式D1集計仕様](https://developers.cloudflare.com/d1/observability/metrics-analytics/)と[Workers料金](https://developers.cloudflare.com/workers/platform/pricing/)、[D1料金](https://developers.cloudflare.com/d1/platform/pricing/)に照合。今回の操作は集計読取と記録のみで、製品・配備・検証用のクラウド負荷・CI・再配布・料金設定は変更しない。
