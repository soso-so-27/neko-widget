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

実装と検証を進行中。実写真で楽しさが増えたとは扱わない。N28/N29の一人でも長く残せる記録については別の設計資料へ整理する。
