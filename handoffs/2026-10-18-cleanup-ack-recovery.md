# 2026-10-18 整理完了記録の再試行

- 実機の赤いJ4は消えたが、利用者は15:43の「保存済み／以前の保存データの整理…」が1〜2分後も残ると報告。端末build番号は画像から独立確認していない。
- 15:49〜15:54のD1 SELECTのみの観測で、自動head revision 3の必要34部品はすべてlive、以前の31件はrevision/サイズも不変。旧indexの削除revision 2がD1と復旧versionへcommit済みだが、完了markerが1件欠けている。不要になったjson部品1件（2,057 bytes）が残る。利用者の写真・メモを復号していない。
- usageは欠落markerでRECOVERY_PENDINGを返す。実アプリは整理の前にusageを確認するため、その先へ進まない。既存15分定期はowner修復を実行するが、legacy backfillがNOのときrecord marker修復を呼ばず、owner snapshotも欠落markerで失敗する。15:45の定期失敗を観測。最初にmarker保存が失敗した通信原因自体は未確定。
- 既存record修復へincludeLegacy:falseを追加し、既存復旧versionの欠落markerだけを20件上限・cursor・purge fenceのまま補完する。既存定期はrecord→ownerの順に修復する。旧データの一括移行は現在の設定に従う。同じ削除revisionの再送もmarkerを先に補完し、新しい削除のowner snapshot・参照保護・delete intent・CASは保持する。
- 実D1、実OwnerRecoveryCopy/RecordRecoveryCopy、合成S3で旧removeの再試行失敗を再現し、修正後に成功。最初のfixtureは全体rollout policyの前提不足で失敗し、製品再現とはしない。新境界はpending-only修復とlegacy除外、別owner/誤revisionの無変更、新規削除のowner snapshot失敗時の無変更、既存scheduledの順序を検査する。
- 独立レビュー: journal_identity_review。月980円、既存登録・cron・受付・予算・secret・公開範囲は不変。新規定期/手動cron/削除実行/会員付与/有料契約は0。アプリ/署名/Widget/UI/依存/migrationは不変なので262の成功を保持し、新TestFlightは不要。今回変更のbackend typecheck・全既存test・migration・bundle・通常push CIを確認後にarchive Workerだけを反映し、自然な次の定期で確認する。
- 初回候補は2026-10-18 15:57:41 JST（最初の合成fixture開始。失敗を含め計時）。backend既存CIは5分timeout、local検査は数十秒〜数分。選択制御の独立反映とcloud状態照合、次の自然な定期最大15分を含め60分の計画。新scopeのCI実測とは扱わず、変更後の候補を固定してから実行する。元のnative成功の再実行でこの判断を調査しない。
- 費用は新契約なし。今回の未完了tombstoneは写真なし。一般にlive photoのmarker修復では既存暗号化写真の検証GETが発生するため、写真I/Oなし・費用不変とは主張しない。既存20件上限・payloadWork・S3 write leaseを保持する。

証拠: `C:/dev/neko-evidence/automatic-test-20261018/cleanup-*`。

## 候補固定前の検証記録

- 制御4ファイルの全15 suiteが226.2秒で成功。制御push `39106748398` の必要3 step成功後、PR354をmain `6f555c3`へ統合した。製品はこの承認済み制御を取り込む。
- 全npm検査を開始した後、主担当が検査中に制御branchへ切り替えたため、その実行は直ちに中断した。`cleanup-ack-service-tests.log` はcancelledとして保持し、全検査成功には数えない。以後、検査中のbranch切替・入力変更をしない。最終製品候補の変更範囲を再検査し、通常pushの全backend検査を必須とする。
- 現在の製品4入力は `3ee7d5c` の独立レビュー済み内容と同一。署名・native・依存・migrationは不変。

## クラウド反映

- 最終候補 `456ba835a1093fb6b27bf140029d8644b187a976` の変更範囲52 testが11.26秒で成功。通常pushのiOS plan `39106901784` は必要3 step、Preservation `39106901764` は全8 stepが成功。後者はNode 32件＋Vitest 70 file/600件、typecheck、合成migration、private bundle2本を含む。backend jobは16:14:11〜16:15:43 JSTの92秒。PR355をmain `4f6d38af`へmerge commitで統合し、同一製品treeのmain plan `39107073894` とbackend `39107073864` も成功。
- 実行前preflightは未計測の初回baselineとしてready。成功後に再度呼んだpreflightは、新しいCIを追加する場合の所要時間baselineが未登録なので `cumulative_cost_requires_replanning`。追加CIは起動せず、実成功した同SHAの必要stepとmain祖先を凍結writerで直接照合して反映した。これはpreflightを検査成功や配備資格に読み替えたものではない。
- archive Worker `neko-preservation-staging-disabled` のみ、16:19:45 JSTにversion `d751abbc-be13-433e-bdd2-083537284dd1`へ反映完了。実配信module SHA256 `5d0e4885e762455ce0b6ec1fac3926821be68de32bb9dc78ea32e96600432dac` がレビュー済みmultipartと一致。独立reviewのwriter hash・plan hash、本人/record/権限を含む既存bindings・secret参照・runtime・cron・公開範囲の不変を確認。新version作成POSTと100%反映POST各1回、再送0。
- 新規契約・有料移行・migration・新定期・手動定期・アプリAPI呼出は0。
- 初回候補15:57:41からcloud反映まで22分04秒。失敗fixtureと中断したlocal全検査、制御準備、CI、待機を含む。自然な次の定期と実機結果の時刻は後続に追記する。

## 自然な定期による復旧を確認

- 既存16:30の定期が16:30:48に開始。欠けていた旧index削除revision2のmarkerを16:30:57に補完し、owner generation148のsnapshot acknowledgementも16:31:03に完了。16:31:39に定期全体が正常終了し、`last_run_error_code=null`。16:32のD1 SELECTで確認した。record/owner repair failureはともに0件。
- 原因となったrecord/owner acknowledgementの停止は解消。受付/期限/試行数/bytes/更新回数/使用量・最新headの必要34部品は変わっていない。元の未参照JSON部品1件（2,057bytes）は端末の整理再開待ちであり、こちらから削除していない。
- 利用者へ「設定 → 保存・復元」を開いて1〜2分待ち、再確認ボタンを押さず案内が消えるかを依頼。実機の案内消失と端末の整理完了はまだ未確認。月980円を維持し、アプリ更新・削除・再インストール・メモ再保存は不要。
- 初回候補15:57:41から自然定期の正常終了16:31:39まで33分58秒。60分計画内。これはクラウド復旧までの実測で、実機の表示確認を完了扱いにしない。

## 実機まで解消確認

- 上記の確認依頼に利用者が「消えた」と回答。再確認ボタンを押さず1〜2分待つ手順に対する結果として受領した。
- 16:34:21のpublication観測でhead revision3/必要34部品がすべてlive、元31記録のrevision/サイズ不変。16:34:37のcleanup graph観測で未参照live部品0、旧JSON1件のrevision2削除marker、owner generation151のacknowledgementを確認。使用量は2,057bytesだけ減り43,756,030bytes、予約0。最新の写真26部品とJSON8部品に欠けなし。record/owner repair failure0、自然定期errorなし、受付/期限/予算/counter不変。
- エージェントが削除APIや定期を手動実行した事実はなく、端末の既存の整理処理が再開した結果。月980円・追加契約0・アプリ再配布0を維持。今回の「整理の案内が残る」問題は完了。別件の実機v3復元・長期容量/性能・動画クラウド保存・一般提供は未確認のまま。
- 初回候補から実機返答と最後のD1観測まで約37分（元失敗・中断・CI・自然定期待機を含む）。60分計画内。最終証拠は `cleanup-ack-after-cron-publication.log`、`cleanup-ack-device-cleanup-read.log` と同時刻のprivate/summary JSON。
