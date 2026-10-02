# 保管：購入対応版への統合候補

2026-10-02 18時台。利用者は外出中で管理ログインできない。既存の会員入口、購入Gateway、本人削除、圧縮reader、実写真の保存・同じApple本人での復元・ZIPを再実装・再確認しない。

## 最新状態

本線main `c9e189a65cd46f86fac850e106fdef394febb7aa` にCI制御PR159、保管usage応答PR160、アプリ表示PR161をmerge commitで反映済み。候補SHA5a351d7がmainの祖先であることを確認した。controlは独立レビュー指摘なし、Python12 suite全成功459.5秒、通常Ubuntu plan24秒。backend3ファイルは通常Node81秒とplan23秒成功。

保管Worker `neko-preservation-staging-disabled` は、レビュー済みusage応答の件数上限1行だけを実配備した。現行version `ce8fbd21-d21d-401a-82bb-71a2c15c3534`。配備前の実JavaScriptとの全文比較は maximumRecords 1行だけで、配備後のmoduleはdry-run bundleに完全一致。21 plain vars、6 secret名、D1/R2、3 service entrypoint、rate limiter、compatibility、公開・preview設定、空scheduleを維持し、独立レビュー指摘なし。実DBの1本人・1記録・削除0件、pilot終了・費用確認期限・一般受付0を配備後SELECTで確認。データへの書込みは0。

アプリ候補はcheckout `C:/dev/neko-preservation-launch-minimum-20261001`、branch `codex/preservation-usage-app-20261002`、SHA `5a351d72ae535a3a2c62eafd4e31904ce0fd4541`、PR161。件数・実設定上限、準備中件数、十進容量を表示する。旧応答の上限欠落は許容し、無効値・加算overflow・停止flag不一致は拒否する。引下げ後に上限を超える保管済み記録は停止flagとの整合が取れていれば読める。

4製品入力は元候補b9000f6と同一。元のnative診断36960965074は既存保管UI1操作、失敗・skip0、14分23秒。iOS26.2/iPhone17 Proで件数・上限と十進容量を描画確認し、同意・再試行・記録詳細・ZIPを確認済み。この診断単体は通常CI・main・TestFlightの配布証拠ではない。旧draft PR158は元混在候補の参照先で、直接mergeしない。

通常候補CI36983313031はBuild・Photos bootstrap・両OS runtimeに成功。初回app-uiはconfirmボタンのexists成功後にenabled/hittable待機がtimeoutし失敗した。実サーバーとの通信不良を示す失敗ではなく、最初の503はfixture内で意図した再試行条件。独立レビューで、スクロールやList更新によるpopover消失との断定を退けた。原因は未確定なので、製品・テストの挙動は変えず、同じSHAの失敗したapp-ui1ジョブだけを1回再確認し、1件成功・失敗0で完了した。通常runの最終結果はsuccess、必須4ジョブすべて成功。初回失敗の原因を「修正済み」とは扱わない。成功した3ジョブの実行時刻が同じまま引き継がれていることをAPIで確認した。Widget Gallery・通常Widget描画テストは0件。再失敗は自動再実行せず、isEnabled/isHittable/frameと画面を同時に取る最小の切り分けに戻る。

## 購入の現在設定と残件

Cloudflare管理APIは現在の認証で読取に成功した。2026-10-02T08:14:20Zのprivate購入Gatewayはversion `601b10a4-30ac-4d7a-822d-a8a0d2f57490`、固定DB `cb3b2386-3a6f-4253-b918-8aafed9ff735`、上位8項目NO、下位generation0・8項目0、Sandbox構成・既存verifier binding。古い認証失敗や保存設定を現在の状態として扱わない。

Apple App Store ConnectはCodex内の個人用ブラウザの読取でlogin/authResult=FAILEDへ戻った。会社Chromeは操作していない。今日は利用者にログインを再要求せず、管理セッションが利用可能になってから有料契約・実商品・価格・7日体験の設定を現在画面で確認する。管理画面がログアウトしたことをAppleの審査・契約待ちと混同しない。

1. Apple現在設定を確認後、既存CLIでprivate Sandbox Gatewayのfresh settings/version、D1世代・全8状態、保管の費用期限と空き枠を再照合する。下位OFFのhealthや古いgen0候補で代用しない。pilot独立許可が期限切れの新規保管拒否を覆い隠していないか判定経路を先に確認する。
2. 実Sandbox購入・購入復元・期限切れと保管可否を接続する。既存のprivate設定候補とCAS手順を使い、旧familyを凍結したまま購入Gatewayだけを段階接続する。未知の製品変更を固定scopeへ押し込まない。
3. 実Sandbox確認へ進めるApple現在設定を確かめ、完成した購入対応構成を固定する。必要な確認と有効期間内の同SHA通常CI成功をそろえ、内部TestFlightへ1回配布する。検証済み表示候補はmain反映済みで、件数表示だけの追加配布を挟まず購入対応版へまとめる。現在の実内部版は236で、新配布はしていない。

## 保持する利用者方針・時間・証拠

月額980円・対象者7日全機能体験という方針を維持。内部1GiB/200件は不変。一般5GB/1,000件/最初3人は未承認の案で適用しない。一般公開・実課金・受付期限延長、12か月後の自動通知・期限削除を今回開始しない。費用確認は10月2日23:59 JST、pilot本体は10月8日09:44:57 JSTのまま。新規受付を続ける場合は実使用量に基づく現在確認が必要で、期限を自動更新しない。

保管全体の初回候補2026-10-01T09:29:38Z、native初回変更2026-10-02T03:28:00Z、通常CI初回2026-10-02T08:18:43Zを引き継ぐ。初回通常CIは約17分で3成功・1失敗。再確認はapp-ui1ジョブだけで16分台。初回通常CIから最終成功まで49.4分、失敗した実行も含むrunner稼働時間の合計78.0分。native初回変更から通常成功まで約340分、保管全体の初回候補から約1,419分で、夜間や待機を含む経過時間であり作業工数・請求額ではない。当初30分の枠に収まったとは扱わない。新scopeの失敗・再確認を含む実測をci-timing-baseline.jsonへ反映した。

証拠は `C:/dev/neko-evidence/preservation-offline-20261002/` の purchase-management-fresh-read-20261002.json、usage-service-deployment-completion.json、usage-service-live-after.json、usage-service-postdeploy-storage-read.json、usage-native-ui-failure-review.json、usage-native-normal-rerun-current.json。サーバー配備時のローカルstdout文字コード例外は再配備せず実versionを読取確認して解消。MIME外枠をcodeとして比較した差分はmodule抽出で解消。任意のDB読取SQLの表名誤りは実schemaへ訂正し、最終SELECTはchanges0。これらを製品不具合・成功テストへ読み替えない。
