# アルバムの入口・日替わりの見せ方（N24）

利用者が2026-09-17のメモ4点を「すべてすすめて」と承認。Build180のe313efeを確認し、別worktree `C:/dev/neko-album-discovery-flow-20260917`、別branch `codex/album-discovery-flow-20260917`で実装する。研究worktreeは触らない。

## 目的と変更

- **楽しみたい内容から入る。** アルバムトップの猫別入口を外す。テーマ・比較・年の写真の中で必要な猫に絞る。写真タブの猫別入口は維持。月・ムービーは世帯全体の内容を保持する。
- **ピックアップを開く周期を伝える。** 「今日のピックアップ」とし、既存の同日固定・翌日再選定・未閲覧優先・直前の重複回避を維持。新しい棚や通知は追加しない。候補不足の日まで異なる内容を約束しない。
- **昔の一枚に気づく。** 古い写真のピックアップと写真詳細に、撮影日から計算した「○年前」、日付が一致すれば「○年前の今日」を添える。実際の撮影年月日も残す。猫の年齢や当時の状況を推測しない。既存の同日写真・比較・写真→まど選択→送信確認につなぐ。自動で文章を写真へ書き込んだり送ったりしない。
- **保存アイコンの見た目を整える。** アルバムの入口と通常写真詳細のbookmarkをSF Symbolsのsmall scaleにし、縦の強さを抑える。44ptの操作領域・保存の意味・ハートとの区別を保つ。図形を縦横別倍率で変形しない。

## 保つ条件

猫フィルターは開いた画面の状態とし、他タブや別アルバムへ勝手に引き継がない。猫プロフィール削除・権限変更時に無断で全猫へ広げない。複数猫テーマは選んだ猫も写っている写真を対象とし、単独写真へ置換しない。対象がない場合も猫選択を残し、全猫へ戻れる。閲覧・保存・送信の写真と所属を一致させ、既存の権限/宛先確認を保つ。

## 根拠と限界

[Day OneのOn This Day](https://dayoneapp.com/guides/tips-and-tutorials/on-this-day-view/)は過去の同じ日の再提示の実例。[Google Photosのメモリー紹介](https://blog.google/products-and-platforms/products/photos/relive-your-best-memories-new-features-google-photos/)も過去写真の再発見と共有を結び付ける。本アプリでは既存の写真閲覧・送信経路を活かす。日次ラベルや相対日付だけで再訪率・送信意欲が改善したと断定しない。

[Appleのシンボル設定](https://developer.apple.com/documentation/uikit/configuring-and-displaying-symbol-images-in-your-ui)に沿ってシンボルのscaleを使い、操作領域と図形の見た目の大きさを分ける。

## 確認範囲

ユーザー指定により外観は実機確認。今回の正確な差分をreviewed-app-ui.jsonに記録し、既存代表4操作、Build内の必須境界/権限/privacy等、Photos権限とスキャン、共有runtimeを実行する。今回の猫filter動作は実MainTabを通る代表操作に含める。成功後の同じ検証は繰り返さず、4点をまとめて内部TestFlightへ配布する。

### 実機で見るところ

1. テーマを開いて猫を選び、全猫に戻す流れが分かるか。
2. 「今日のピックアップ」と昔の撮影時期が伝わり、翌日も開きたくなるか。少ない候補では再登場しうる。
3. 昔の写真を開いた時の時間の手がかりと保存マークの収まり。送りたい一枚があれば既存のまど送信へ進める。

## 完了結果（2026-09-18）

4点を実装しmainへ反映。製品SHA `aa55dbf4b132a1abb3054a635ef7ffc30ad6f592`、**TestFlight 1.0 (181)を9月18日00:08:04 JSTにAppleへアップロード成功**。実際のログで `UPLOAD SUCCEEDED with no errors` とarchiveアップロード成功を確認。Apple処理完了・内部グループでの表示・181の実機外観は未確認。

- [候補CI 35234780175](https://github.com/soso-so-27/neko-widget/actions/runs/35234780175)：reviewed-app-ui-v1の全必須ジョブ成功。代表4件/0失敗、操作実行543秒（約9分）。CI全体21分05秒、UI job20分44秒。今回は失敗による再実行なし。操作件数を限定しても準備・ビルドを含む待ち時間は残る。
- [main CI 35237230015](https://github.com/soso-so-27/neko-widget/actions/runs/35237230015)：同じSHA・scopeの成功証拠を再利用して成功。
- [配布35237404031](https://github.com/soso-so-27/neko-widget/actions/runs/35237404031)：配布CLIのdry-runで旧予約180と同SHA証拠を確認し、181を一度だけdispatch。既存testflight環境のそのrunを承認し、署名/archive/export/upload成功。job6分26秒。App Store審査提出や一般公開はしていない。
- 安価なローカル確認：開発フロー8群75.5秒、既存共有/Widget境界63件（既存skip1）成功。SwiftUI動作は上記4件で確認。独立担当のレビューを主担当に統合し、写真所属・権限・削除された猫の範囲保持・暦年維持・送信対象に新しい漏れは見つからなかった。

代表テスト内で、どアップ→写真なしの猫→全猫に戻る、2025年→ミケ→正しい日付の1枚だけを閲覧/横送り→戻って猫選択維持→全猫に戻る、既存猫別写真・お気に入り作成・送信先確認を実行。外観全体や再訪率/送信意欲の改善を自動テスト済みとは扱わない。

変更ファイルはLikedPhotosView.swift、MainTabView.swift、既存PhotoPermissionUITests.swiftとレビューmanifest。モデル/永続化/Widget/共有処理の変更なし。更新後は上の実機3項目を普段の写真で確認する。
