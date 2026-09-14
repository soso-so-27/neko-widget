# 毎日一枚と、Widget内で送るハート

2026-09-14。利用者が承認した3点を同じ内部TestFlight候補へまとめる。
起点 `origin/main 1d2da21`、worktree `C:/dev/neko-widget-daily-heart-20260914`、branch `codex/widget-daily-heart-20260914`。

## 範囲と完了条件

1. 個人Widgetは暦日ごとに一枚。手動の「もう一枚」はこのiPhone全体で1日1回、成功した写真も翌日まで維持する。保存・候補補充・再起動で入れ替えない。旧20分のプランから画像・回数・履歴を引き継ぐ。
2. 受信Widgetのハートはアプリ画面を開かず、そのrequestを送信する。失敗時は待機を保持し、同じアイコンで同じrequestを再試行できる。受付が確認できた場合だけ塗りつぶす。
3. 「もう一枚」は全サイズでアイコンのみ。使用後はチェック。44ptの操作領域と読み上げを維持し、Widget追加の案内で「毎日一枚。1日1回だけ選び直せます。」を説明する。

実装・独立レビュー・Swift/iOS実行・製品描画・候補CI・main反映・Build 169のAppleアップロードまで完了。実際のOSによるWidget起動経路とホーム画面への更新時刻は実機未確認として区別する。

## 実装

- 個人Storeの既存プランに任意のtimezoneフィールドを追加。旧v1の現在写真を維持して日次へ移行する。日次計算は24時間の足し算でなくCalendarを使い、DSTにも対応。日付変更前の古い操作は翌日分を消費しない。
- 日次写真の参照保持を翌日境界+12時間へ延長し、同日の補充で退役させない。旧「70枚を使うまで補充しない」判定は、実際に保護が外れた表示済み写真の有無へ変更。日次化で新しい写真の候補入りが約70日止まることを避ける。
- ハートはhostだけの `ForegroundContinuableIntent` とiOS26以降のbackground/dynamic modesで実行し、前景継続APIと写真画面routeを呼ばない。Widget Extensionに鍵を移さない。
- hostの既存直列実行・認証・送信処理を再利用し、指定requestだけ処理。取得待ちの写真・まど名同期は新規起動しない。まど・space・lifecycle・閲覧期限・手元画像・既存requestを再確認する。
- request/resource timeoutはWidget用clientだけ15秒。通常の45秒は維持する。処理待ちや複数リクエストを含む全体が15秒で完了する保証ではない。

## 検証

- 独立レビュー：日次移行・回数・履歴・DST・写真保持・補充条件。主担当はハート実装の鍵/対象/同request/失敗状態を別に確認。
- 手元：development-flow 6 suites（31秒）、family Widget境界63件（既存skip1）、写真権限9件、診断privacy13件（既存skip1）、background18件、personal state15件、担当側disabled11件、差分チェック。
- 既存native harnessへ当日保持、翌日切替、使用/未使用の旧プラン移行、補充後の同写真、23/25時間のDSTを追加し、CIで成功。既存runtimeのハート境界へ通信失敗→同ID成功、別写真/期限/欠落request拒否、非host/保護データ不可、二重送信抑制を追加し、2OS構成の各38件が成功。
- 製品WidgetのGalleryで小・中・大の未使用/使用済み、計6画面を確認。全サイズで切替は矢印のみ、使用後はチェック、保存との分離と写真領域を維持。Gallery描画はHome Screen上のAppIntent呼び出しの検証とは別。
- アプリUIは42件成功。独立したsmoke・残りのGalleryを含む必須8項目が成功。

## Build 169の配布結果

- 製品SHA `fcd1d7ce2e72a51a1d9d2aef67fb8ec18775212f`。
- [候補CI 34830006233](https://github.com/soso-so-27/neko-widget/actions/runs/34830006233) は8項目成功、59分27秒。app-ui jobは49分39秒、そのうち42件のUI試験本体は36分50秒。
- [main CI 34835124670](https://github.com/soso-so-27/neko-widget/actions/runs/34835124670) は同一SHAの成功証拠を再利用、最終job完了まで15秒。
- 既存CLIのdry-runでSHA・CI・番号を確認し、一度だけdispatch。既存の内部配布範囲に一致するtestflight環境を承認。
- [TestFlight 34835230044](https://github.com/soso-so-27/neko-widget/actions/runs/34835230044) で **2026-09-14 19:59:56 JST、UPLOAD SUCCEEDED with no errors**。候補CI開始→アップロードは70分14秒。Apple処理完了・内部グループ画面は追加確認していない。
- 実機で残る確認は、受信Widgetでハートを押してもアプリ画面へ切り替わらないことと、iOSによる日次写真反映。ユーザーが問題なしとした通常の写真画質は未完了へ戻さない。

## 配布が長い理由と今回の扱い

CI分割導入時は56分18秒→38分37秒へ短縮したが、直近167は54分52秒、168初回は49分34秒。168はsmokeの局所再実行24分21秒を加えて候補最終77分07秒、起動からAppleアップロードまで88分15秒。main再利用は19秒、配布開始からアップロードは7分24秒。

168で中心だったのは42件のapp-ui（実行34分10秒、準備約12分33秒、全体48分30秒）。167ではさらに開始待ち11分56秒があった。169は既存CIで先に配布し、その後に[独立したCI改善](2026-09-14-ci-app-ui-priority.md)を実測して本線へ反映した。同じアプリの必須8項目で59分27秒→51分06秒、開始待ち9分48秒→22秒。試作中に30分のsmoke枠不足が判明し、その修正の再検証には追加時間を要した。長いUI試験自体は残っており、短時間で配布できる問題がすべて解消したとは扱わない。

参照：[AppleのWidget実行規則](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities?changes=_10_3)／[ForegroundContinuableIntent](https://developer.apple.com/documentation/AppIntents/ForegroundContinuableIntent)。
