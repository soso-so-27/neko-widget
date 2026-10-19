# 保存処理の集約と履歴増加の抑制

月額980円を維持する。今回の候補は、新しい写真メモ・ツール等の分割データのうち、写真本体以外の部品を最大16件まとめ、保存先の目録更新を共有する。最後のhead更新と復元検証は従来どおり残す。写真や既存の履歴を削除して費用を下げる変更ではない。

## 候補の状態

`codex/save-batch-history-20261019`、基点main `0968afc`。実装と直接検査・独立レビューまで完了。Mac検査、main反映、0047/0048 migration、archive/削除用の両Worker反映、内部TestFlight配布は、まだ完了していない。この時点の稼働中アプリは265、クラウドは前回のまま。

## 変更と直接確認

- 部品のまとめ保存は、owner・epoch・固定manifest・生の送信byteのhash・device grant・削除状態を検証する専用経路だけで続行する。通常の認証条件は緩めない。部品の到着、目録の確定、アプリ全体の保存完了は別に扱う。
- 暗号化済みの途中作業を記録し、送信結果が不明でも同じkeyとbyteで再試行する。変更済み作業の競合・改ざん・鍵失効は拒否する。端末に途中ファイルがない場合と、接続期限切れの場合も、通常読取より先に本人に結び付いた目録を少しずつ修復する。
- 契約の定期確認は続ける。同じ有効/猶予状態だけの観察で保存履歴を毎回増やさない。期限切れ/不明/通知/削除の既存条件は残す。再開位置と一度の再試行を記録し、予算切れや恒常的な障害のownerで巡回全体を止め続けない。
- 巡回対象の読取後・予約前に利用者が無効化された場合の競合を実local D1で再現し、予約SQL内でowner状態を再確認するよう修正。未適用0047の削除guardと0048の既存外部キーで、旧版の削除処理でも新しい作業行・巡回参照を残して削除完了とならないことを4条件で確認した。新しい削除処理は参照を整理して正常完了する。対象50件と型検査は成功、元失敗を保持。
- 実local D1と暗号処理による集約・中断・権限・復元の境界検査、型検査、migration検査を実施。定期確認/両削除経路等の最終対象50件も成功。新しいSwiftの実行はまだ未確認で、既存の所有XCTest内に中断再開と途中ファイル喪失の検査を登録した。

## 効果と限界

合成3,650件の現在目録に新しい部品9個を追加した比較では、その部品保存段階のowner目録履歴が9回から1回、追加S3 byteが202,285から122,754になった。写真3,650枚の実データや10年分の履歴ではなく、総費用/利益の確定値でもない。ローカル保存時間は2.645秒から3.927秒で、速度向上は確認していない。

10回連続の検査では、以前の保存byte・tombstone・記録履歴を保全し、完了時の作業状態はbatch 1行、work/node 0行に戻った。既存部品の退役とhead更新は集約していないため、必要な記録履歴は増え続ける。退役処理の集約、長期の総原価、本番大容量復旧・別iPhoneの確認は別の残件。

## 検査・配布計画と時間

最初の候補6057953の通常backend検査39210489763は、型検査/Node32件が成功し、Vitest756件成功・1件失敗だった。既存trialテストの部分的な代用品に新しい機能判定が欠けていたためで、製品は変えず代用品の非対応判定とその確認だけを訂正した。同ファイル15件はlocal成功。元失敗/後続skipを保持し、残る必須CI/main/cloud/配布の成功へ読み替えない。

開始05:23:30 UTC、最初の0048候補05:41:39 UTC。元のfixture失敗、検査登録の訂正、巡回の不公平を発見したprobeと修正を保持し、途中で計時をリセットしない。既存の成功は依存入力が不変な範囲だけ継承する。

新しいnative入力があるため、旧265の成功は流用しない。選択器は変更せず、確定候補のpreflightで必須graphを確認する。予想はfull-v1のplan＋8 native jobと同SHAのPreservation全8 step。過去のfull経路64〜98分、upload約7〜13分を参照し、残り約1〜2時間を計画する。未知の待機・失敗・Apple処理時間は別に記録する。

新規有料契約、料金プラン変更、容量/テスト受付枠の変更、期限延長、定期の作成・手動再実行、一般公開、審査提出は行わない。cloudは新しい2 migrationと両Workerを、稼働設定・秘密情報参照・保護対象の記録を保った手順で別途確認する。

詳細な入力hash・private証拠・元失敗log: `C:/dev/neko-evidence/save-batch-history-20261019`。主な記録は `candidate-plan.md`、`batch-boundary-review-final.md`、`batch-recovery-review.md`、`retention-fairness-fix.md`、`retention-final-independent-review.md`、`batch-cost-measurement.md`、`release-route-plan.md`。

追加の削除競合検査は `cursor-delete-guard/report.md`。旧schemaで準備したcloud package/protected manifestは新guardを含まないため未武装のまま保持し、最終候補で新しく固定する。旧scheduled実行がすべて終了したという推測は、DB側の防止策の成功証拠とは区別する。

## 最初のnative検査の切り分け

6057953 / iOS39210489764ではBuild・Photos smoke・runtime・gallery-variantsが成功し、solo-2は28件中27件成功・1件失敗。今回のまとめ保存を含む `testToolBackupRestoresPrivateCopiesWithoutPhotoLibraryIdentity` は160.350秒で成功した。既存の `testAlbumRelatedPhotoRoutesPreserveScopeAndReturnToOrigin` だけがthemeのforeground判定で失敗した。兄弟jobは取り消さず、全体成功とは扱わない。

失敗前にPhotosダイアログをXCTest default handlerが拒否したことをraw logで確認。ただし取得した録画の20秒時点では、Menuとtheme/cat/yearの項目が見えているため、「Menuが開かなかった」とは断定しない。該当methodと関連route/fixture等7ファイルは0968/6057/b88で同一。製品を変えず、当該fixtureのPhotos前提を明示処理し、元の一意性/hittable assertionを保ったままAX role/ID/label/count/状態と失敗直前画像を取得する限定候補を用意した。この時点ではその限定候補の実行・原因解決は未確認。

初回の約1〜2時間見込みを超過。元候補・backend fixture失敗・native失敗・診断待機を累積のまま記録し、限定診断約20〜30分＋その後の既存必須検査/配布約1〜2時間を追加計画とした。成功済み15 control検査等は依存入力不変として保持し、同じ確認を再実行しない。新たなCI scope/selector免除を作らない。

その後solo-1も成功、app-ui-otherは53件中skip1/失敗1。失敗した既存family wrapperは、共有ZIPの実ShareSheet containerが出た後、OSのclose button待ちで止まり、後半の共有撤回/権限解除には未到達。元AXはremote subtreeが空で代替のclose/handleを示さず、アプリ録画だけではsystem共有画面の実描画を確定できない。UIHostingControllerのreparenting警告もあるが原因とは断定しない。製品を変えず、同じ5秒waitの結果を固定してからdevice全体の画像と失敗時AXを保存する限定probeを追加した。実cancel・sheet消失・後続assertionは維持。二つの別classの既存失敗操作を確認してから、最終候補の必須CIへ進む。


続くed6 / run39228041265は必須native8系統のうち7系統成功、solo-2だけ28件中27件成功・1件失敗。まとめ保存・中断再開・復元の新検査は154.356秒で成功。失敗は未変更の会員接続検査が書き出しShareSheetを閉じた後、5秒以内にremote AX containerの消失を確認できなかった点。対象method/helperと表示・終了・ZIP生成の4製品ファイルは0968/6057/ed6で同一。取得した画像には2KBのZIPとcloseが描画され、合成tap座標も位置に整合するが、tap受理・実画面消失・cleanupの完了は未確認。環境原因・製品原因のどちらとも断定せず、元selector/tap/5秒wait/assertを維持し、終了判定の直後に全画面とAXを記録する最小の限定候補を追加した。成功済みcontrol検査は依存不変として保持。初候補/最初のCIからの累計を継続し、限定診断約20分＋通常必須CI最大実測105.5分＋配布参考12.2分等を追加計画とする。初回120分・後の360分計画は未達となる見込みで、次の計画枠は最初のCIから480分とする。AGENTS.mdの差し替えは本PR完了後に別の1本で行い、現候補では変更しない。
