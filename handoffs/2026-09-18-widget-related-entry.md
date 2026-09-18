# 個人Widgetの関連写真入口を実経路へ接続

## 目的と範囲

TestFlight 183の利用者報告は「Widgetから開いた写真ではアイコンがない。写真タブにはある。このままなら価値は低め」。前者は接続漏れ、後者は体験価値の評価として分ける。関連メニューの追加を再訪・課金価値の達成とは扱わない。

最新main `c865945`から `codex/widget-related-entry-20260918` / `C:/dev/neko-widget-related-entry-20260918` を作成。研究worktreeには変更しない。

## 原因と修正

実AppRootは個人Widgetの写真を独立NavigationStackから `MainTabView.widgetPhotoDestination(for:shownAt:)` で直接描画する。MainTab.body側だけに追加した関連候補・開く操作・関連sheetを通らなかった。旧UI fixtureはMainTab内部の写真ルートを通り、実際の漏れを検出していなかった。

このdestination自体に、関連候補とsheetの表示状態を持つViewを組み込む。既存MainTabの未設置のStateを利用せず、実際に描画されるホストが状態を所有する。sheet本体はアプリ内経路と共有し、元の写真はその下に維持する。写真ID変更時は探索状態を持ち越さない。

実URL受信ホストのpersonal fixtureもこのdestinationを直接使う。MainTab.bodyやfixtureによる関連environmentの代替注入を経由せず、関連年への移動、Close、元写真への復帰を確認する。

写真の候補範囲・権限・明示所属・送信・個人記録・Widget更新は変更しない。共有と公式Widgetは別Viewerであり、個人写真のアルバム候補へ混ぜない。

## 完了条件と現在地

- 実Widget入口で候補がある写真にアイコンが表示され、関連写真を開閉して元の写真へ戻れる。
- 候補なし・権限/対象外の既存制約を維持する。
- 新しいWidgetリンクと既存の写真/設定画面を混同しない。
- 必要なコードレビュー・変更範囲の検証・候補CI・main反映・内部TestFlightアップロード。

製品 `7826029491e5dff3e8809f21fa3b5496deb9e2d7` をmainへ反映し、**内部TestFlight 1.0 (184)を2026-09-18 21:32:24 JSTにAppleへアップロード成功**。必要なCIと配布工程は完了。実写真で楽しさが増えたとは扱わない。N29は[一人の写真と言葉の復旧](2026-09-18-solo-photo-and-note-recovery.md)へ分けた。

## 検証結果

- ローカル開発フロー8群成功、diff check成功。製品部分とfixture/test部分を分けて独立レビューし、確認された指摘は解消した。
- 候補CI `35339247924` は必須8 job成功。2026-09-18 11:21:43〜12:21:48 UTC、60分05秒。再試行なし。アプリUI 50件・失敗0件（操作本体49分07秒）、smoke 22件・失敗0件。Widgetの3描画条件、共有runtime 2 OSも成功した。全scopeのため今回の配布速度は改善できていない。
- 新しい実URL→個人Widget destination→関連年→別日写真→Close→元写真の操作はsmokeで36.824秒で成功。製品destinationを通した2枚の画像を確認し、アイコン・異なる日付への移動・元の写真と日付への復帰を照合。fixtureの外側にはテスト用ラベルがあり、AppRootの画面全体を完全に再現した画像とは扱わない。
- main CI `35344306322` で同一SHAの候補証拠を再利用。既に成功した一式の再実行はしていない。
- 配布CLIのdry-runと一回のdispatchで既存media-staging構成を維持。配布run `35344423628`、job `105597567918` の実出力 `UPLOAD SUCCEEDED with no errors` を確認。run全体は8分50秒（承認待ちを含む）。Apple処理完了・内部グループ画面の再照合・184の実機操作は未確認で、毎回のログインや画面再確認は行っていない。
- [実URL操作のログと画像](C:/dev/neko-evidence/widget-related-smoke-35339247924)を保持。実機での使い心地・継続価値・Apple処理完了は上記技術検証と別。

## CI短縮の別候補

`C:/dev/neko-widget-entry-ci-20260918` / `codex/widget-entry-ci-20260918` / ローカル候補 `f497fe7` に、レビュー済みの個人Widget入口を6操作で確認する固定scopeを準備した。製品main `7826029` 上へrebase済み。AppRoot・保存・権限・Widget描画等を変える場合は対象外であり、未知の差分は一式へ戻す。

今回の製品CIへ後付けしていない。新scopeの候補はローカル検証までで、push・CI実行・採用・実時間短縮の計測は未実施。次に独立したCI候補として検証する。CIだけの変更で新たなTestFlightは作らない。

利用者の確認は、普段の個人Widgetから写真を開き、候補があるときの右上の関連アイコン→関連写真→閉じる、で元写真へ戻る流れに絞る。写真/アルバム/まど全体の再確認は求めない。公式・相手から届いた写真は個人PhotoKitの候補対象ではない。
