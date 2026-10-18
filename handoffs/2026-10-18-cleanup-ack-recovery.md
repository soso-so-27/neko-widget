# 2026-10-18 整理完了記録の再試行

- 実機の赤いJ4は消えたが、利用者は15:43の「保存済み／以前の保存データの整理…」が1〜2分後も残ると報告。端末build番号は画像から独立確認していない。
- 15:49〜15:54のD1 SELECTのみの観測で、自動head revision 3の必要34部品はすべてlive、以前の31件はrevision/サイズも不変。旧indexの削除revision 2がD1と復旧versionへcommit済みだが、完了markerが1件欠けている。不要になったjson部品1件（2,057 bytes）が残る。利用者の写真・メモを復号していない。
- usageは欠落markerでRECOVERY_PENDINGを返す。実アプリは整理の前にusageを確認するため、その先へ進まない。既存15分定期はowner修復を実行するが、legacy backfillがNOのときrecord marker修復を呼ばず、owner snapshotも欠落markerで失敗する。15:45の定期失敗を観測。最初にmarker保存が失敗した通信原因自体は未確定。
- 既存record修復へincludeLegacy:falseを追加し、既存復旧versionの欠落markerだけを20件上限・cursor・purge fenceのまま補完する。既存定期はrecord→ownerの順に修復する。旧データの一括移行は現在の設定に従う。同じ削除revisionの再送もmarkerを先に補完し、新しい削除のowner snapshot・参照保護・delete intent・CASは保持する。
- 実D1、実OwnerRecoveryCopy/RecordRecoveryCopy、合成S3で旧removeの再試行失敗を再現し、修正後に成功。最初のfixtureは全体rollout policyの前提不足で失敗し、製品再現とはしない。新境界はpending-only修復とlegacy除外、別owner/誤revisionの無変更、新規削除のowner snapshot失敗時の無変更、既存scheduledの順序を検査する。
- 独立レビュー: journal_identity_review。月980円、既存登録・cron・受付・予算・secret・公開範囲は不変。新規定期/手動cron/削除実行/会員付与/有料契約は0。アプリ/署名/Widget/UI/依存/migrationは不変なので262の成功を保持し、新TestFlightは不要。今回変更のbackend typecheck・全既存test・migration・bundle・通常push CIを確認後にarchive Workerだけを反映し、自然な次の定期で確認する。
- 初回候補は2026-10-18 15:57:41 JST（最初の合成fixture開始。失敗を含め計時）。backend既存CIは5分timeout、local検査は数十秒〜数分。選択制御の独立反映とcloud状態照合、次の自然な定期最大15分を含め60分の計画。新scopeのCI実測とは扱わず、変更後の候補を固定してから実行する。元のnative成功の再実行でこの判断を調査しない。
- 費用は新契約なし。今回の未完了tombstoneは写真なし。一般にlive photoのmarker修復では既存暗号化写真の検証GETが発生するため、写真I/Oなし・費用不変とは主張しない。既存20件上限・payloadWork・S3 write leaseを保持する。

証拠: `C:/dev/neko-evidence/automatic-test-20261018/cleanup-*`。現時点ではcloud未反映・自然定期による復旧未確認。
