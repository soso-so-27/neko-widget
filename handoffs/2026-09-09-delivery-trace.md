# 送信待機の最小診断

Build144でhandoff記録から76.134秒後に送信1件成功したが、失敗段階と理由は旧ログから復元できない。今回の変更は今後の観測不足を補うもので、当該遅延の原因確定・解消ではない。

`moment-delivery`カテゴリに、実送信試行開始、再試行の保存成功、commit受付確認、再試行情報の保存失敗を記録する。待機時は予約／upload／commitと各ローカル処理段階、固定理由、累積失敗回数（`deliveryPriorFailures`）、実際に保存した次回時刻（UTC）を持つ。予定時刻前の同期skipでは追加ログを書かない。commit済みのローカルcleanup失敗は再送待機と呼ばず別イベントにする。

`deliveryTrace`はプロセス起動ごとのランダムnonceと写真の内部IDから作る12桁の短いdigest。同じ起動内の複数Coordinatorで待機・再試行・受付を結び付ける。nonce、内部ID、写真、本文、URL、認証情報、生エラーは出力しない。起動をまたぐ同一写真の追跡はできず、端末間の相関にも使えない。

理由と段階は閉じたenum、失敗回数は符号なし整数、時刻は既存ISO8601検証、digestは既存12桁hex検証でdefault-denyを維持する。既存APIが通信例外をまとめるため、transport-unclassifiedからtimeout／接続切断／通信取消などを断定できない。

送信回数、日次上限、バックオフ、Retry-After、wire、永続形式、通常UIは変更しない。受付確認は相手到達・閲覧の証拠ではない。

対象確認：`python NekoWidget/ci/test-diagnostic-log-privacy.py` 13件中12成功、既存Swift実行1件skip（WindowsにSwiftなし）。固定分類、同起動内／別起動の相関、任意文・URL・IDの拒否は既存Swift verifierに追加済みで、実行は候補iOS CI待ち。`git diff --check`成功。新しいCI・配布・実機ログ要求は行っていない。
