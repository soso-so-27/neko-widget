# 同じツール保管を完了するための有限補修

既存本人の同snapshot・元期限を保ち、不具合で成功しなかった入力debtを消さずに補修する。一般受付、新規owner、旧record更新、新契約、AWS Paid移行、一般公開・課金、月980円やcronを変更しない。初回製品候補2026-10-14 14:24:56.733342 UTC、最新main a39d71a9d8633b98db7309f0ffd7492408e07186から独立branch。

追加0036は初期空のpa_tool_trial_resume_repairsだけ。発行時に原grantの20MiB/400attempt/200slot・bytes17,948,504/attempts27/slots20、成功19piecesのpayload11,484,328、未commit photo801,110 bytesのrecord/fingerprint/hash、同owner/epoch/snapshot/review/cost証拠/元期限を照合する。owner PKで一度だけ、追加量6,425,264 bytes固定。原残3,023,016を含む修復総残は9,448,280 bytesであり、原残を再度足さない。修復行のあるownerは排他的repair laneを使い、旧bytesを固定、新bytesを修復ledgerへ返却なしで計上する。旧attemptsは27から49まで単調増加し、総slot30（新10）まで。Malformed/429/duplicate/provider failureも消費し、repair失効・撤回・不整合時は原trial/pilotへfallbackしない。

原0035のimmutable triggerは変更せず、新triggerで旧Workerからの原bytes変更・修復refill/reissueを拒否する。文書/payload debitはKMS/S3/JPEG前、bind時のgeneration CAS、reservationとatomic commitで同owner/epoch/snapshot/review/期限・repair evidenceを再照合する。indexは元piecesとexact一致し、完了後の新createを拒否。既存GET/再ログインは期限と独立に保持する。

計算上、30piecesはファイル29＋index1。初回usageはfile payloadを20,971,520−200×2,048−262,144=20,299,776以下にする。成功一巡debitの上界は20,623,360。成功19piecesのdebit11,523,240を引くと残成功一巡≤9,100,120、総残9,448,280で348,160 bytesの差がある。snapshotの全file実サイズ・実機request順序を直接captureした証拠ではない。6,425,264=8×(801,110+2,048)というdebt一致を、8回全てprovider未到達の証拠にしない。

正規owner erasureに新tableを分類し、親grantより先に削除する。Offline recoveryは既存どおりdisabled/no sessionsでstagingし、grant/slots/repairを復元・自動再発行しない。empty-target guardも新tableを確認する。D1 bookmarkを巻き戻して修復rowを失った状態を未発行と解釈しない。独立したprivate issuance/実行markerを保持し、operatorによる自動再発行・再開は禁止する。今回汎用D1 rollback耐性基盤は追加しない。

局所検証：合成SQLite全36migration適用/新table空、旧trial15件＋schema/FK3件＋disabled restore1件成功を保持。新修復fixtureは初回11件中9成功/2失敗（expiry後に期限切れsessionを使ったtest原因）とHTTP verifier型欠落を保存し、同owner再認証のfixtureへ訂正。修復13件が13.52秒（test8.11秒）で成功し、index check後のslot競合・R2後revocation・失敗debt・22並行attempt・他owner保持と正規削除を確認。最終typecheck成功、実interfaceに合わせたHTTP fixture1件も6.42秒で成功。12 skippedは今回成功と数えず、未変更の12件の既存成功を入力一致で保持する。型訂正の中間失敗もprivate validationに保存する。成功した未変更入力を広く繰り返さない。実機の全保存/別端末復元・クラウド反映は未実施。

配備は独立レビューとexact scopeのmain先行登録、候補同SHA owning Preservation全8step＋iOS planを経て主担当が行う。migration36空→archiveと既存削除executorの同source code更新→両exact bundle/settings/secret refs/exposure/cron照合→最後に別private planの一度限りの修復INSERT。新tableが非空になる前に削除executorを更新する。追加量の金額は写真各保存先1copyと検証read1回の算定部分で約$0.00093、CPU/KMS/owner世代増等は未測定。新契約・有料移行を自動承認する資料ではない。
