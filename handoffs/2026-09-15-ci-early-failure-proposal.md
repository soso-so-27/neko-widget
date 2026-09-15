# 変更関連UIを先行する最小案

2026-09-15。読取に基づく未実装案。今回の製品候補・TestFlight条件には追加しない。主担当が確認し、次回の基盤改善候補として集約した。

推奨は、既存app-ui jobの中に**少数の先行テスト → 従来の全対象**という順次実行を設けること。job分割やMac枠追加は行わない。成功時の必須試験は一つも減らさない。

今回の実測（run34909923241、ログ時刻はUTC）:

| 出来事 | 時刻・時間 |
|---|---|
| UI一式開始 | 2026-09-14 23:51:29 |
| 受信操作テストの旧ラベルで失敗 | 2026-09-15 00:01:25、当該テスト50.162秒 |
| 新しい共有一覧のButton限定queryで失敗 | 00:04:20、当該テスト13.173秒 |
| UI一式終了 | 00:28:17、UI本体約36分48秒 |

最初の失敗後に約26分52秒、二つ目の失敗後に約23分57秒続いた。両テストの今回の失敗時実行時間は合計63.335秒。これは成功時の所要時間でも、CI全体を短縮できる量でもない。[実ログ](C:/dev/neko-shared-window-album-20260915/output/app-ui-failure.log:7498)

現行はselector配列を一度の `xcodebuild test` に渡し、コマンドが戻るまで個別失敗の終了コードを受け取らない。実際の順序も、配列ではComposerクラスが先なのにログではCatProfileから始まっている。selectorの並べ替えだけでは先行実行を保証できない。[実行箇所](C:/dev/neko-shared-window-album-20260915/NekoWidget/ci/run-sharing-runtime-matrix.sh:410)、[選択定義](C:/dev/neko-shared-window-album-20260915/NekoWidget/ci/ios_ci_scope.py:152)

具体的な構成:

1. 既存の変更path判定に、小さな「画面path → 独立fixtureの代表method」対応を足し、通常の `nativeTests` と別に `priorityTests` を出力する。今回のFamilyWindowView/MomentDeliveryComposer変更なら `MomentDeliveryComposerUITests/testReceivedProductControlsBindRequestsAndPendingStateToTheVisiblePhoto` と `testSharedAlbumMixesBothSidesAndOpensTheSelectedPhoto` の2件。先行対象は現在のscopeの実行対象内に限る。対応がない変更・判定不能・手動全件実行では従来の選択を維持する。Swiftコード全体の自動依存解析は導入しない。
2. 既存のfixture画像投入後に `build-for-testing` を一度実行し、同じビルド・Simulator・署名/言語条件で2件を `test-without-building`。別名のxcresultへ記録する。
3. 先行が失敗したら、そのxcresult/添付を出力し、非0終了でapp-ui jobを失敗させる。残りは未実施と明示する。0件実行や欠けた結果を先行成功としない。既存のcleanupと `if: always()` artifact uploadを維持し、他jobの失敗を隠さない。
4. 先行が全成功した場合のみ、現在のselector全体を `test-without-building` で実行する。初版では先行2件も再度含め、差集合処理や成功証拠の合成を導入しない。従来の全対象が成功するまでapp-uiをgreenにしない。

実装規模は、既存selector/planの優先method情報、shellの2段階実行・失敗時添付、対応する選択/終了コード境界テストが中心。新job・成功証拠の免除・署名/privacy/runtimeの変更は不要。優先対象は独立fixtureに限定し、先行実行が後段へ状態を漏らさないことも確認する。

成功時の追加コストは、優先2件の成功時実行時間＋追加のxcodebuild/XCTest起動・結果出力。失敗時63.3秒を成功時の増分に流用できず、`build-for-testing` 化の差とSimulator再利用時の影響も未計測。先行リストが大きくなると常に遅くなるため、まず今回の2件で専用CI候補を測る。全jobの最長時間やTestFlight到達時間が同じだけ縮むとは約束しない。

修正後の[run34913782399](https://github.com/soso-so-27/neko-widget/actions/runs/34913782399)は必須8項目成功、全体51分50秒、画面操作43件の本体38分30秒。共有一覧の新規テスト単体は100.950秒で成功した。2件を二重に走らせる案が成功時にも短くなるという証拠ではなく、失敗を早く返す案の評価に使う。mainは同じ成功SHAの証拠を再利用し16秒で完了した。

[配布手順](C:/dev/neko-shared-window-album-20260915/handoffs/development-release-workflow.md)どおり、CI試作は製品候補と分離する。失敗/未実施をmainの成功証拠に再利用せず、採用は全必須チェックと成功時の全体時間・runner分を実測してから判断する。今回、CI起動・監視・既存コードの変更はしていない。
