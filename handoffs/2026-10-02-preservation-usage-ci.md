# 保管件数・容量のCI分離

2026-10-02。control初回候補の開始は07:39:52 UTC（16:39:52 JST）。保管全体の初回候補2026-10-01T09:29:38Zを引き継ぎ、branch分割で累計をリセットしない。

## 変更と根拠

サーバーのusage応答・integration期待値・READMEの3ファイルを先行統合し、その後にnative4ファイルを載せる。元の製品候補b9000f6とAPI説明を含む4ad1143は元branchに保存している。今回のcontrol branchでは製品、workflow、native実行shell、署名・配布validatorは変更しない。

`preservation-service-v26` は4ad1143の保管service全tree `a6299352e82577e33aa0faf3e20c867729505c6d` を固定し、既存専用Node job・workflow全文hash・raw mode・混在拒否を維持する。新しい `reviewed-preservation-usage-ui-v1` はorigin/main037684a→b9000f6のnative4全文のSHA256 pairと既存UIメソッド実在を要求する。Build、安全確認、Photos bootstrap、両OS runtime、既存の保管会員同意/再試行UI1本を残す。Widgetの描画・timeline・shared model・画像・projectに変更がないためGalleryは選ばない。任意のクライアントやfixture変更への汎用免除ではない。

製品の直接証拠はb9000f6のNode CI36961103616（322件、70秒）とnative診断36960965074（既存UI1本、14分23秒）で、撮影画像の件数/上限と十進容量、同意・再試行・詳細・ZIPを確認した。診断は通常CI/main/TestFlightの合格証拠ではない。分離後の新SHAのNode job成功は別途必要。既存v6とその過去配布証拠は変更しない。

## control確認と時間

実製品のbefore/after4全文から新scopeが選ばれ、lanesはruntime/app-ui、選択UIは1本になることを直接確認。新しい境界テストは欠落・全文不一致・未知/backend混在・mode/type・重複・メソッド欠落・失敗/skip/cancel/別SHA/diagnostic-onlyの拒否を確認する。

独立レビュアーpolicy_ci_reviewが6既存CIファイルを読み取り確認し、4全文pairとservice treeの一致、generic必須job/実workflow/runner/releaseへの接続、拒否境界を確認した。指摘なし。製品の直接描画証拠と通常CI証拠を混同しない。

ローカル必須Python12 suiteは前回実測約315秒を計画参照とする。control候補のUbuntu planは前回約24秒で、新候補の初回実測は別途記録する。今回Mac/Simulator、クラウド設定、期限延長、TestFlightを起動しない。新native通常4jobの時間は未計測なので診断時間を配布所要時間と約束しない。

## 続き

controlだけをPythonと通常Ubuntu planで確認してmainへ反映。backend3ファイルだけを通常候補にし、iOS planと専用Node jobの同SHA成功を確認して先行統合する。そのmainからnative4ファイルの候補を準備する。購入の管理ログイン・実設定fresh確認・実Sandbox購入/復元/期限切れは利用者が操作可能になってから。既存pilot許可が期限切れ拒否を隠さないよう先に判定経路を確認する。

月額980円・対象者7日全機能体験という方針を維持。内部1GiB/200件、既存保管コピー、実本人削除の権限範囲を変えない。一般5GB/1000件や実課金・一般公開をこの制御変更で開始しない。

## 反映結果（2026-10-02 17時台）

control `b6db30e50473ad056efbc934279f1dbb06ce04c4` はPython必須12 suite全成功、459.5秒。Ubuntu通常push CI36980759348は24秒・plan成功、Mac jobは起動せずskip。PR159をmerge commitでmainへ反映し、ancestor確認済み。backend候補 `e466c38991f6be0171eaa3283ae32860ca45ce2b` は3ファイルだけでservice tree完全一致。通常iOS plan36981018710は23秒、専用Node36981018769は81秒成功。PR160をmerge commitで反映し、ancestor確認済み。反映後mainは `c744845d4994745652af81e003a199ffa6049630`。

新しい通常native候補はそのmainを基点に `codex/preservation-usage-app-20261002` へ4製品ファイルだけを移した。製品入力は描画確認済みb9000f6と一致。まだlocal commitのみでpush/native通常CI/TestFlightは未実行。旧draft PR158は診断用の混在候補なので直接mergeせず、購入用の完成候補へまとめる。サービスの実Workerへはこのturnでdeployしていない。

control・backendの詳細なpreflight/初回候補/CI JSONは `C:/dev/neko-evidence/preservation-offline-20261002/usage-ci-control-*` と `usage-backend-*`。時間はここに記したCIだけでなく、control初回16:39:52から準備・ローカル検証・review・mergeまでを含めて評価する。新native4jobは未計測。
