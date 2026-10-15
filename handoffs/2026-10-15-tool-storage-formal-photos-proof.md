# ツール保存・復元の写真検査と配布判定

- 価格980円、内部配布の範囲を維持する。製品候補は `fb5a1dce3696703e3942c77c34287c9319886eb1`、製品22入力と署名済み配布CLIは変更しない。
- 正式写真検査 [38678383169](https://github.com/soso-so-27/neko-widget/actions/runs/38678383169) は承認済みmain `e0b68d2` のcontrollerから固定製品をcheckoutし、2026-10-15 04:08:56 UTCに成功。Linux `116237087305` とMac `116237161983` の全stepが成功。元の2 XCTest、TCC/fixture・scan/Widget連携、smoke最終markerを含む元の検査を変更せず実行した。実iPhoneやインストール済みWidgetの描画確認とは区別する。
- 原run `38667725132` のPhotos失敗、後続の受付済み再実行がjobを割り当てない状態、最初のcontroller `38676316408` のshallow checkoutによる準備失敗は保持する。原7jobと準備失敗2jobを成功に読み替えず、診断の成功も正式結果に代用しない。
- 実run/job、両生ログ・全step・両phase観測の12項目を固定し、controller履歴が既知準備失敗と今回の厳密2件であることを共通の判定で確認する。専用判定は同repoの固定製品と等価なmainだけに限定し、別repo・他候補の通常探索を維持する。明示premerge観測は `release_qualified=false` のまま。
- この制御候補はplanner/testの通常2変更と本記録だけ。現mainのbefore8を固定し、原製品のbefore8、残り制御、3controller artifact、全製品、依存、署名入力を維持する。main先行反映後に製品をmergeし、実mainのdefault graph・元Build/runtime/UI9・同SHA backend8step・現在時刻の署名を確認してからクラウドと内部256へ進める。
- 0037、既存2Workerの更新、TestFlight256の実uploadはこの記録時点で未実行。新規有料契約・AWS Paid・一般公開・課金開始・試用枠の追加や延長・cron/定期タスクの変更や手動再実行は含まない。
- 最初の製品候補は2026-10-14 12:59:13 UTC。今回のcontrollerは17分58秒、Macは17分32秒。原失敗・診断・待機を含む累計を消さず、再計画1050分を完了保証や当初目標達成とは扱わない。
