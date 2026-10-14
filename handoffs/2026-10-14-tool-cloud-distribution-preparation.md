# 2026-10-14 ツール保存のクラウド接続と内部配布準備

月980円を維持する。今回の依頼は、保存・復元を実際に使うためのクラウド接続と配布準備。新規契約、AWS有料化、一般公開、課金開始、定期タスクの作成・再実行は含めない。

## クラウド側で完了したこと

- 既存 `neko-preservation-staging-disabled` を、main `e84a232b09ce9a9b1247d6558e5c2001fc987c6a` のツール保存v3対応へ更新した。version `b502db9a-d169-4afd-9bb4-c0fd66d6b0c1`、凍結bundle SHA256 `31cc8dbc3d82b1f7458a5dcae42a6212fa60fbcde72babe90359efadc84d404d` の完全一致を確認。
- migration34は月間mutation byte列2本をdefault0で追加。旧1 owner／1 record、設定・secret参照・公開範囲・cron・期限を保持。既存本人の記録へのwrite0、新規リソース・契約0。
- 初回はmigration適用後、SQL文字列のCRLF/LF差で検証が停止。実schemaと旧値をLF正規化して照合し、別の独立レビュー済み継続手順でcodeだけを一度uploadした。DDL再実行なし。元の停止記録は保持。
- ブラウザの未認証GETで `SESSION_INVALID` を実表示。PythonからのGETは403 plain textで停止し、認証や保護を回避しなかった。到達と未認証拒否の証拠であり、iPhone本人確認・実ツールroundtripの証拠ではない。

## 内部配布候補

[製品PR296](https://github.com/soso-so-27/neko-widget/pull/296)の候補 `856194e2635e17821b539e3076563267ba6b1f8f` をmain `a1403efd476759d7d00e49a9c9045ce259b774cd`へ08:45:47Zにmergeした。候補祖先と全tracked treeの一致を確認した。[候補push CI38533784539](https://github.com/soso-so-27/neko-widget/actions/runs/38533784539)は成功。新Build115752091106は08:16:24→08:39:04Zの22分40秒、39必須step全成功。全45stepのうち43成功、対象外icon2stepはskip。plan115751648121も成功、CI全体23分59秒。元native3と固定PR backendは旧SHAの実成功として保持し、新candidateの実行と混同しない。

実CLIの `check_ci` が新Build39＋旧3 native＋固定PR backend＋元失敗を現時刻で適格化し、[main CI38537431077](https://github.com/soso-so-27/neko-widget/actions/runs/38537431077)も候補証拠を再利用して成功した。未実行/skipを成功扱いせず、追加Mac実行なし。外部照合wrapperは最初にowning CI directoryをimport pathへ追加していないため、GitHub通信前に `app_icon_ci` import errorで停止した。wrapperだけを修正し、製品とCIの成功は保持した。

候補checkoutで実配布CLIのdry-runが成功し、未使用build255／前の予約254、`media-staging`＋`preservation_pilot=true`＋`internal_reports=true`を確認した。`billing_sandbox`と `--dispatch` は付けない。JSON内 `upload_to_testflight=true` は将来の入力計画であり、アップロードの実行証拠ではない。実Archive・Apple upload・255の処理/実機操作は未実施。現在配布済み254は維持する。

制御PR295／`d8b1f4c` のowning push38533254219、plan115749899076は50秒で成功し、main `02fedd9`へmerge。正確な3製品blob、1183 tracked inputs／SHA256 `4c8fcee0e7c46537fccb4c38b7aa5b44123b659c2c8ee4d5dce863da32dc04ec`、main承認control、現時刻二署名とfresh Build39を同じproofで要求する。元の `tool_recovery_inputs` は変更しない。

CLI67テスト、署名済みmedia設定28テスト成功。制御planner355／preflight153、閉包訂正後の実Git回帰を含む5件成功。最初のfixture2 errorと新budget fixture NameError、4 release-candidate notesの閉包定義不一致は外部記録に残し、既存成功を未実行の成功へ読み替えない。

新readinessは既存の二権威で実署名し、現在のowner/adoption・custody・固定code・履歴と独立レビューを照合した。同じ鍵・目的・許可flagを維持し、production/実写真/backupの新しい承認を発行しない。有効期限は `2026-10-14T10:26:58.711Z`（19:26:58 JST）。配布直前にも再確認が必要。protected変数と29 codeSHA／公開鍵／manifestの一致を独立にread確認し、変数は変更しなかった。

## 保存試用・実機で残ること

1. 本人がAWS既存アカウント `164892691568`へログインし、現在のplan/利用可能credit/サービス利用可否を確認する。本日のCLI照会はidentity exit255で停止、未retry。ブラウザもlogin画面のまま。古い119.41 USDを現在残高や料金保証にしない。
2. 実際の端末内ツール目録でJSON部品・JPEG・indexのN/byteを測り、本人と固定snapshot、部品ID、24時間以内、合計20MiB以下、有限試行数と新しい費用証拠を固定するtrial grantを準備する。このgrantは設計のみで未実装・未発行。既存pilot SQLだけでは現owner／1snapshot／byte上限を強制できない。migration34は一般モードのIntakeControl用であり、現在pilot PUTのbyte制限ではない。旧100/day・500/monthと旧1GiB/200件・全体3GiBの内部値は販売人数や通常原価に転用しない。
3. 費用を具体化して必要な承認を得た後、限定受付と内部TestFlight配布を行い、同じApple Accountの別iPhoneで5ツール・添付写真・日付・元記録保持・復元コピー編集とoffline表示を確認する。実機手順は外部 `owner-tool-check-guide.md`。現record1は新ツールsnapshotではないため、旧GETだけで5ツール復元を成功扱いしない。

pilotと24時間cost reviewは期限切れのまま。新規保存試用・実機ツールroundtrip・Apple uploadは未実施。旧コピーのGETはpilot/cost期限に依存しないが、session/owner/epoch/削除/ackとKMS/R2/S3の利用可能性に依存する。別端末の新Appleログインはcredential/session更新とKMS/S3 owner recoveryを伴い、無料readと断定しない。

## 費用・公開条件

今回、新しい有料契約やAWS有料化は行わない。既存Cloudflare Workers Paid標準基本料月5 USDはアカウントの既存固定費であり、1人ごと・保存1回ごとの料金ではない。[公式料金](https://developers.cloudflare.com/workers/platform/pricing/)。今回の公開GitHub標準runnerは無料。[公式条件](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job)。

10/1〜10/14 08:25:47 UTCの既存CFアカウント集計はWorkers40084 requests/CPU134.9秒、D1 read740053/write11904 rows、R2操作22363、period bucket最大payload合計46130486 bytes。管理・検査・共有込み、adaptive/delayあり、billing cycle/請求書・GB-month・全AWS物理版・通常1人原価・将来無料枠ではない。R2無料枠はStandard・月間保存/操作種別の条件付き。[公式料金](https://developers.cloudflare.com/r2/pricing/)。

費用承認が残るのは、AWS無料枠終了後の有料継続、実構成と保持約束に対応する運用・保持資金、有限実試用に追加料金が必要な場合の具体額。実額未確定のまま承認を求めない。旧1,773円・旧予備費込み予算・3人枠を最新の実費/承認/販売人数にしない。実クラウド更新と、試用受付・一般提供・課金開始を区別する。

## 証拠と時間

外部証拠rootは `C:/dev/neko-evidence/tool-cloud-preparation-20261014`。`deployment/completion.json`、`deployment/after.json`、`migration-failure-diagnosis.json`、browser/host診断、AWS失敗、CF集計、`finite-trial-review.json`、`fee-approval-preparation.md`、release各review/preflight/qualification/dry-runを保持。

cloud first candidate07:21:07.791491Z→反映完了07:38:47.833654Z、17分40秒。release preparation first07:17:55Z→候補main反映08:45:47Zは1時間27分52秒。dry-runと引き継ぎもこの起点から計上し、Buildだけの22分40秒を全作業時間としない。元tool候補は03:08:47Z以前で、その失敗・診断・全累計を消さない。23分54秒は前のBuild参照、30分はtimeout予約であり今回の完了保証ではない。

既存の「ねこのまどの配信保守」は確認済みの登録1件を維持。新規作成・再実行・変更なし。研究worktree・LP・task historyを変更/整理しない。
