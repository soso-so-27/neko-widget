# 公開まど共通化・第2バッチ

## 範囲と完了条件

N07の第2段階。既存「どこかの猫」を維持し、追加の公開まどをIDで扱う。現在の配信登録は旧公式まど1件だけで、お題・猫別まどの運用は開始しない。

- catalog、購読世代、取得中の処理、プレビュー、写真保存先をまどごとに分離する。
- 一覧→写真詳細とWidget→写真詳細に対象まどIDと写真IDを渡す。未知・停止・期限切れのまどを別のまどや個人写真で補わない。
- 旧 `official-cats`、`official-window.v1`、`nekowidget://official-window`、旧配信URLを維持する。
- 2まどで同じ写真IDを使い、片方の停止・遅い応答・別配信先・期限が他方へ影響しないことを対象チェックと製品UI fixtureで確かめる。
- 配信ツールは追加catalogを `windows/<id>/` へまとめる。既存rootへの上書き・窓IDの不一致を拒否する。今回はWorkerを配備しない。

## 実装

`PublicWindowDefinition`と固定の登録一覧を導入。追加分のWidget IDは `public-window:<id>`、保存先は `public-windows.v1/<id>`、リンクは `nekowidget://public-window?window=<id>&photo=<id>`。旧公式は元のIDと保存先を使う。

一覧・追加画面・写真詳細は同じ部品を再利用。表示名・Widget案内・受信停止の対象名を選択中のまどに合わせる。架空のお題カードや投稿ボタンは表示しない。非公開まどのWidget案内の「写真源」は実際の項目名「表示する写真」に合わせた。

固定登録を変更するときは、アプリとWidgetの同一一覧、配信URL、まどIDを一緒に変更する。任意URL入力や探索APIは設けていない。

## 確認

- 配信側：Node 23件、publisher 30件成功＋既存symlink 1件skip、fixture 5件成功。
- 既存境界：family Widget 60件成功＋既存1件skip、disabled release 11件、official release 11件成功。
- UI/Widgetの独立レビューで `contains` のSwift条件式の曖昧さを修正。IDの別まど・個人写真へのfallbackは見つからなかった。
- Swiftの旧データ互換・複数まどの取得/停止/プレビュー、製品UIで二つ目を止めて旧公式の写真が残るケースを追加。WindowsではSwift/Xcodeを実行できないため、候補CIで確認する。

候補 `6d22fe7860f9f005adbf2ac2036a44b060c4639c` の[CI 34732148079](https://github.com/soso-so-27/neko-widget/actions/runs/34732148079)は全ジョブ成功。Swiftの境界123項目、iOS 18.6のUI13件（Official12件）、iOS 26.2のアプリUI34件とGallery3条件を含む。追加した2まどの操作は両OSで成功した。mainへ同じSHAを反映し、[main CI 34734412492](https://github.com/soso-so-27/neko-widget/actions/runs/34734412492)も成功。同じ候補の成功証拠を再利用し、再度一式を走らせていない。

今回のCIは54分11秒。生ログは作業worktreeの `output/public-window-build.log`、`public-window-smoke.log`、`public-window-sharing.log` に保持し、約453MBの全artifactを手元へ再ダウンロードしていない。新規公開まどの実端末運用や実Workers配信を完了済みとは扱わない。現在のTestFlightは159で、この土台だけの新規配布はしていない。

## 配布確認の方針

ユーザーは159のアップロードを確認済み。run34726931914のUPLOAD SUCCEEDEDを完了証拠とし、毎回のApple画面確認や再ログインを次の開発の前提にしない。配布が見えない・Apple側処理エラーがある場合に絞って画面を確認する。アップロード成功を内部配布画面の照合済みとは書かない。

失敗した2worker CI候補ae2790eは取り込まない。現在の直列UIチェックを維持し、この製品バッチの候補CIを1回実行する。
