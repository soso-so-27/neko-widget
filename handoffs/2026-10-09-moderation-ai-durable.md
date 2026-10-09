# 通報AIの永続処理

## 変更と根拠

既存の通報受付・caseを使い、AI補助結果を同じ通報の入力版へ結ぶ未接続部品を追加した。`0030_moderation_advisory_jobs.sql` と `moderation-ai-durable.ts` が対象。通報本文・画像・復号鍵・API秘密・provider応答原文は新DBへ保存しない。派生したhash/分類結果も通報の保持期限に従う。

- case HMAC/key版と実reportのciphertext hash・commit時刻・既存期限をDBで照合。tombstoneだけ、期限切れ、内容削除、終了caseには送信しない。入力版は最小化済みAI入力の版であり、原画像の改変版を意味しない。
- 最初のawait前に入力を専有copy。同一入力は同じjobへ戻し、DBで勝った1 attemptだけが既存transportを実行する。通信後のクラッシュ/DB失敗は結果不明として本人確認へ残し、自動再送しない。
- 完了を保存するSQL内で最新入力版・実report・期限・唯一のattemptを再照合。古い結果、別case結果、attempt移植、REPLACEによる再実行を拒否する。AIの結果は常に本人確認待ちであり、終了/削除/承認権限を持たない。
- reportの終端状態・物理削除・tombstoneの内容削除とともにjob/attempt/resultを削除する。時刻だけの期限切れでも読出しは拒否し、100 jobずつの掃除関数を提供する。既存の最小case/受付記録は保持する。

workerdの実D1で、trigger拒否時のbatch全rollback、同時claimの勝者1件、FK cascadeを先に直接確認した。その後、実reportのFK/commit連鎖を通した合成fixtureで保存・競合・逆順完了・旧版・送信禁止・通信/DB失敗・期限・削除を検証した。新規20件と型検査、独立レビュー、最終同SHAの必須backend CIを証拠対象とする。CI前のローカル成功と、実CI結果は外部記録で区別する。

見つかった失敗: fixtureの非同期HMAC導出のawait漏れ（製品処理前の14失敗）を修正。D1の`meta.changes`がcascade行も数えるため掃除のjob件数が3となる製品不具合を`RETURNING job_id`の件数へ修正。独立レビューでは別jobへのattempt ID移植と最終読戻しの非同期例外漏れを修正し、それぞれ回帰試験を追加した。合格条件は変更していない。

初回owning CI `37911654185` は、既存 `staging-config.node-tests.mjs` の配備互換性検査一覧に0030がないことを正しく検出して停止した。`["0030_moderation_advisory_jobs.sql", 17]` の1行を加え、新migrationにもLF/CASE/文数の既存検査を適用する。20件の同Node検査成功を確認し、3製品blobは変更していない。未到達の後続検査はまずlocalで回収し、billing sponsorship drillも一覧29件固定で止まることを確認した。drillの一覧に0030を加え、所有テスト2箇所の件数を30へ更新した（12項目の検査・識別子0・全migration一致は不変）。drill3件成功後、残る未実行項目から検証を再開。失敗したpush/PRを履歴に保持し、同じ製品branch/PRを続行する。旧3ファイルの専用CI判定は保持し、この厳密な3検査fileの訂正を含む6ファイル形を別途レビューして登録する。

訂正後、未到達だったNode検査を最後まで回収し、workerdの全29ファイル・427件が成功した（Vitest実測125.32秒、コマンド経過128.36秒）。既存の環境条件付きskip 1件は成功件数へ含めない。全migration一致・30件適用・drillの12検査は維持し、3製品blobは初回候補から不変。3検査fileの訂正も独立レビューでP1/P2なし。最終候補の同SHA CIはこのローカル成功と別に確認する。

## 接続条件と残件

Worker route・実secret・実写真・実AI API・運営者権限へは接続していない。この関数は、入力がその通報の復号結果であること、最小化/事前screenや本人の認証を証明しない。これらを行うtrusted callerが必要。内容由来情報を含むため本番接続前に期限掃除の実scheduleと保持方針を必ず結ぶ。今回migrationをlive DBへ適用していない。

本人の署名付き判断、対象shared copy限定の非表示/解除、同一transactionの判断台帳と通知outbox、本人画面/実authenticator、実通報一件の訓練は引き続き未完。[本人運営の設計](2026-10-09-owner-moderation-workflow.md)に従う。既存の独立承認・復旧・データ削除・公開条件は緩めない。新しいアプリCI/TestFlightは不要で、本人配布247は維持する。

実時間は最初のfixtureから累計で記録。計画35〜65分、既存transport batch約21分にmigration/DB境界の追加を見込んだ。専用scopeを別制御候補でmain登録してから製品pushし、Sharing4 job、Preservation1 job、iOS planを同一SHAで確認する。既存不変検査の成功は保持し、native/Gallery/測定だけの重いCIは追加しない。

正本: `C:/dev/neko-evidence/launch-readiness-20261009/moderation-ai-durable/` の `plan.json`・`review.json`・各検証log・最終CI/統合記録。失敗や未完事項を成功に読み替えない。
