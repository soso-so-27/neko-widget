# 同じ中断スナップショットの有限補正に対応するCI登録

製品初回候補は2026-10-14 14:24:56.733342 UTC。先行fingerprint修正の13:43:13 UTCからの障害対応時間も保持し、今回の別batchでリセットしたとは扱わない。製品はa39d71a9からの固定6本、2追加・4変更・100644。新scope `preservation-tool-trial-repair-v1` はdefault-empty0036、元debtを維持する排他的補正lane、削除inventory/順序、disabled復旧の残留拒否と境界testのみを扱う。

rootの独立source/testレビューでblockerなし。全36migrationのSQLite適用と新表emptyを直接確認、repair13件成功13.52秒、型fixture訂正後HTTP1件6.42秒、既成功の旧trial15/schema3/quarantine1を維持、typecheck成功。最初の2失敗は試験時計を期限後へ進めて古い10分sessionでGETしたfixture、型失敗はsynthetic verifier不足。製品の認証条件を緩めずfixtureを修正し、元失敗・skipを成功に読み替えない。

固定before/after blobsと全tracked閉包を使用する。製品6本/control4本/通常handoff Markdown以外1,183行のSHA256は `3f123afda2b3ecbd4b27d8650c47d59483c8c5079bd81dbc298f5662f0737c9e`。release-candidate notesも閉包内。未知、部分、mode/type、削除、重複、未承認control、欠落登録を拒否する。新selector8件0.198秒、budget2件0.001秒成功。

controlを先に独立レビュー・CI・main反映し、製品に取り込む。同じ製品SHAのowning pushでPreservation全8stepとiOS plan必須3stepの実成功が必要。型、全test、synthetic migration、archive/削除executorのprivate bundleは省略しない。native/JPEG/workflow/署名/依存入力は不変、iOS配布を起動・証明しない。

新scopeは未計測baseline。直近control local260秒/plan50秒、製品local262秒/Node99秒/plan48秒は計画参考に限る。helper準備15〜20分を並行、fresh確認と配備も加える。初回からの累計・失敗・activeを保持し、5分timeoutや旧scope時間を実測に読み替えない。

実配備は別の凍結planと独立レビューで空0036→既存archive/削除executorのcode-only更新→最後に一度だけ同snapshot補正INSERT。元期限、owner/epoch、既存grant/debt/記録、設定・secret参照・公開範囲・cronは維持する。補正9,448,280 bytesは原残3,023,016と失敗6,425,264の合計で二重加算しない。22追加attempt/総30slot、再発行・refillなし。新契約・有料移行・一般公開・980円変更を含まず、実機完了はユーザーの次の試行まで未確認。
