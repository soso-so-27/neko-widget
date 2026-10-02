# 保管：購入対応版への統合候補

2026-10-02 17時台。利用者は外出中で管理ログインできない。既存の会員入口、private購入Gateway、本人削除、圧縮reader、実写真の保存/復元/ZIPを再実装・再確認しない。

## 最新状態

本線main `c744845d4994745652af81e003a199ffa6049630` にCI制御PR159と保管usage応答PR160を反映済み。controlは独立レビュー指摘なし、Python12 suite全成功459.5秒、通常Ubuntu plan24秒。backend3ファイルは通常Node81秒とplan23秒成功。実Workerへのdeployはしていない。実内部版は236のまま。

checkout `C:/dev/neko-preservation-launch-minimum-20261001`、branch `codex/preservation-usage-app-20261002` はそのmainにnative4ファイルだけを載せたlocal候補。件数/実設定上限、準備中件数、十進容量を表示し、旧応答の上限欠落を許容する。無効値・加算overflow・停止flag不一致を拒否し、上限引下げ後の超過保管済み記録は停止flagとの整合が取れていれば読める。

4製品入力は元候補b9000f6と同一。元のnative診断36960965074は既存保管UI1操作、失敗/skip0、14分23秒。iOS26.2/iPhone17 Proの描画で件数/上限と十進容量を直接確認し、同意・再試行・記録詳細・ZIP操作を確認済み。この成功は通常CI/main/TestFlightの配布証拠ではない。旧draft PR158はこの元混在候補の参照先であり、直接mergeしない。

## ここからの順番

1. 管理ログイン可能になってからApple有料契約・実StoreKit商品、private Sandbox Gatewayのfresh settings/version、D1世代・全8状態、費用と空き枠を既存CLIで確認する。下位OFFのhealthや古いgen0候補で代用しない。pilot独立許可が期限切れの新規保管拒否を覆い隠していないか実判定経路を先に確認する。
2. 実Sandbox購入・購入復元・期限切れと保管可否を接続し、native候補へ必要な完成変更をまとめる。既存4全文固定scopeを借りて未知の追加変更を通さない。必要な依存に沿って候補を確認し、新scopeの所要時間は未計測として先に計画する。
3. 完成したnative候補の通常CI成功後、merge commitでmainへ反映して同じSHAを内部TestFlightへ1回配布する。現4ファイルだけならBuild・Photos bootstrap・両OS runtime・既存保管UI1本でWidget Galleryは選ばない。今回のlocal候補は未push/通常nativeCI未実行で、新TestFlightを作っていない。

月額980円・対象者7日全機能体験という方針を維持。内部1GiB/200件は不変。一般5GB/1,000件/最初3人は未承認の案で適用しない。一般公開・実課金・受付期限延長、12か月後の自動通知/期限削除を今回開始しない。

保管全体の初回候補2026-10-01T09:29:38Zを引き継ぐ。CI分離の初回16:39:52、実測・拒否境界・main反映は[CI分離の記録](2026-10-02-preservation-usage-ci.md)、製品の直接証拠は `C:/dev/neko-evidence/preservation-offline-20261002/usage-limit-completion.json`。ユーザーの既確認写真を消しての試験や同じ保存/復元確認を要求しない。
