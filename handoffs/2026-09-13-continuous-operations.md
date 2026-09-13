# 公式まどの継続運用：予定配信への移行結果

2026-09-13 21:43 JST、既存内部TestFlight向けpreviewを予定配信方式へ移行した。サービス実装は `00a027c`。アプリの写真送受信や課金、外部配布先は変更していない。

## 完了したこと

- 承認済み写真の追加・掲載期限による削除・catalog更新を17版の有限予定にした。PC・Codexが終了していても、サーバーが時刻に合った版を返す。
- 現在の「どこかの猫」4枚、「おひるね」2枚、「キジ白のまど」2枚の画像と写真metadataを維持。既存queueも変更していない。
- 未掲載の5枚は、公式/お題が9/15・17・19日の09:00 JST、キジ白が9/16・20日の09:00 JSTに配信可能になる。別猫をキジ白へ流用しない。
- 予定の終了は **9/27 09:00 JST**。写真の期限は延ばしていない。終了後は503で停止し、履歴を保った明示的な補充・復旧を行える。
- 停止・取り下げ時は今有効な版から残りの予定全体を作り直し、未来に復活させない。未来の最終版を掲載実績として使用しない。
- 既存の09:00・21:00 heartbeatを読取専用の監視へ変更した。予定の実行に日々の再配備は不要。窓別在庫・予定終了の接近・実際の失敗を通知し、同じ正常結果や同じ不足を繰り返さない。
- [運用窓口](2026-09-13-operating-desk.md)に、問い合わせの整理、48時間以内の安全連絡確認、共有障害の切り分け、停止、補充を集約した。

## 検証結果

既存83件と追加20件のサービス検証、最終強化箇所の対象20件、構文・diff確認が成功。新機能と実装を別担当でレビューした。実queueでも、既存画像/掲載日/期限が不変で、予定通りの5枚だけが追加されることを別の照合scriptで確認した。

固定Wrangler 4.125.0のdry-run後、既存previewへ1回配備。実Worker versionは **`de1d9a35-ccef-4219-b5dd-8f5dde79d968`**。3catalogと8JPEGをHTTP/hash照合し、内部・未来URL14件の拒否を確認した。排他的なpendingを使い、成功後だけcurrentを更新した。

新監視scriptも手動で1回実行して成功。`notify:false`、新しい不足なし、未掲載在庫は公式3枚・キジ白2枚。移行前の旧heartbeatには9/13 21:03の正常自動実行記録があるが、移行後の次の時刻起動や、9/15以降の予定写真の実配信を確認した意味ではない。

## 正本・証拠

- 固定checkout：`C:/dev/neko-official-supply-20260913`。準備・検証はここで行う。別worktreeで生成したWorkerは改行の違いでもbyte照合に失敗し得るため、そのまま配備候補に使わない。
- 運用手順：[SCHEDULED_OPERATIONS.md](../OfficialWindowService/SCHEDULED_OPERATIONS.md)、[MAINTENANCE.md](../OfficialWindowService/MAINTENANCE.md)。
- 現在状態：固定checkoutの `output/runtime/current.json`。`mode:scheduled`、queueと実bundleとversionを記録。
- 実bundle：`C:/dev/neko-continuous-ops-20260913/output/schedule-deploy-20260913/bundle`。同階層の他のscheduleフォルダーは配備していない候補であり、使わない。
- 配備記録：固定checkoutの `output/runtime/runs/20260913-scheduled-migration/`。
- 新監視の初回記録：`output/runtime/runs/20260913T124359959Z-schedule-check/`。
- 監視のコード正本：`OfficialWindowService/tools/monitor_schedule.mjs`。入口は `output/runtime/check-schedule.mjs`。現在の結果は `output/runtime/last-schedule-check.json`。

原本・queue・未来の掲載履歴・実行記録はgit管理外。公開リポジトリへ画像や承認記録を追加していない。新しい保存サービスや認証基盤も追加していない。

## 残る確認・継続する仕事

写真の新規供給・掲載判断と、人による問い合わせ確認は継続する運用。予定表を置けば永久に新しい写真が作られるという機能ではない。監視の通知にはPC/Codexが動いている必要があり、サーバーの写真切替とは区別する。

実機Widgetへの反映時刻・接続からの写真送受信・拡大画質は、HTTPやローカル検証の成功で代用しない。LP掲載、外部審査・招待、課金開始は保留のまま。
