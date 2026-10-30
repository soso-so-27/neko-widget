# 内部TestFlight 317（1030g）

## 配布前：2026-10-30 12:14 JST
- 製品候補main ba3d2d80d87f797965e602ac92ca1063673577a2。iOS build check run40990026382成功を確認。316からの増分は#610/#612/#616と#611/#613/#614/#615。
- 既存記録は正規verifierでunexpected_fields。altool-result.py追加とworkflow/verifier変更の計3ファイルが原因。1030gに従い未dispatchで停止し、所有者から再署名・既存鍵利用の追加承認を得た。
- 承認後の作業開始12:07。既存の鍵確認プロセスが停止していたため、所有者のUAC許可で同じ本人・鍵・scope・期限の有限プロセスを再開。期限は2026-10-30 21:36:15.223 JSTのまま。初回再確認は失敗、後続で正規の鍵保管確認成功。期限・クラウド設定の延長なし。
- 旧記録の正規2署名と316のソース一致を確認。現在32ファイルのうち変更3件をレビューし、codeSHA256と2署名だけを更新。issuedAt・expiresAt・過去の写真確認/対応不要の証拠は全てそのまま。今回新しく写真を開いたとは扱わない。新規通報・新規鍵・鍵の交換なし。
- 更新候補の正規verifyReadiness成功、改ざん/期限/対象拒否を含む既存3テスト成功。正規staging runtime検査成功。外部書込み・D1適用・Worker更新なし。
- この候補の変更は運営確認記録と本リリースメモだけ。変更に依存しないmainの製品検査結果は保持。残る必須チェックは候補CI、archive/export、署名済み設定、Apple検証/uploadとTestFlight状態。
- 設定は316と同じ：media-staging、公式黒猫preview feed、preservation_pilot=true、internal_reports=true、billing_sandbox=true、group_windows=true、upload_to_testflight=true、retain_signed_artifacts=true、legacy_release_evidence=false。内部グループ「自分用」だけ。
- FAMILY_NOTEBOOK_PRODUCTION_ENABLED、GroupReportingProductionEnabledなど従来NOを維持。App Store Connectはログイン済み。設定変更・審査提出・公開はしない。
- 最初の再署名候補12:14。これからのCIと配布は35〜45分程度＋Apple処理待ちを見込む。316配布は起動から最終確認22分36秒、直近CI約14分。初回未承認調査の厳密な開始時刻は未記録で、承認後12:07からの累計も報告する。

## iPhone確認項目（未確認）
- 内部版で新しいアルバムと4タブが出ること、作品到着日の端末内予約通知。
- 保存量と容量/件数/両方の超過案内。サーバー未反映時の未集計表示。
- CatCare/家族の手帳の保存復元と、復元した手帳が個人の控えとして残ること。
- 病院/預けるときの継続編集、他の猫の宛先/期間と個人の写真が保持されること。
- 実機描画と本物の2台確認は今回のCIでは未確認。2台/AASAの実施は別承認。