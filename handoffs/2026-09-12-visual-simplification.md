# 文字の整理とまどカードの統一

2026-09-12。ユーザーの実機画像（カードの高さ違い・文字過多）を基準にした本線バッチ。

## 変更と完了条件

- private / official の棚を `WindowPhotoCard` に統一。同じ正方形写真枠、同じ1行の名前欄。棚はfillで表示し、写真を開くと従来どおり全体表示・拡大できる。
- 一覧の役割説明文は削り、非公開は鍵、公式は「公式」。AI生成写真は小さなAI表示を残し、完全な提供元・掲載日は写真詳細と読み上げへ。
- 追加・更新・管理・閉じるは既知のアイコンへ。読み上げ名と操作領域を維持。タブ名、独自機能、届け先、失敗への対処、削除・停止の確認は文字を残す。
- 設定中の行は名前と状態・再開案内1行に整理。共有のエラーや準備中はそのまどに限定し、カードの高さを増やさない。
- 写真・まど・思い出・成長アルバム・写真シャッフル案内の重複説明を削減。ハートは通常時アイコンで、送信中・失敗時の説明は維持。
- 公式の最近の写真は名前を中心にし、詳細情報は写真を開いて確認。設置ガイドは実動作に合わせ「Widgetの置き方」。

操作の意味が既知のものだけをアイコン化する。[Apple Design principles](https://developer.apple.com/design/human-interface-guidelines/design-principles)の不要な要素を除く方針と、[Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars)のわかるラベルを保つ指針に合わせる。文字を無条件に消す方針ではない。

## 検証

- 独立レビューの指摘（fill画像に重ねるバッジのクリップ、設置ガイドの名前）を修正。
- 既存の境界チェック61件（1件環境依存skip）、公式配布設定11件、private表紙3件（1件環境依存skip）成功。
- 既存の混在UI試験に縦長の公式写真とAI creditを使用。同じ列幅・高さ・上端を検証し、大文字表示・追加・設定復帰の実操作も維持。
- [候補CI 34620737288](https://github.com/soso-so-27/neko-widget/actions/runs/34620737288)は1回の実行ですべて成功。製品コードは `0624b752cb025f8ca19ccbc58aea6a73b2c0e1a5`。
- iOS 18.6 / 26.2の公式UI各7件が成功。通常ダークの混在一覧、大文字、追加、公式詳細・最近の写真を目視。まど一覧は実際の製品Viewを使うfixtureで、写真比率・カード寸法・操作を確認した。
- 共有runtimeはiOS 18.5 / 26.2で各37件成功。既存の写真詳細fixtureは写真領域を製品部品で描くが、閉じる・ハートの操作部は独自の仮ボタンである。そのスクリーンショットを、今回の製品側アイコン変更の描画確認とは扱わない。製品側の変更はソースレビューとビルドで確認した。
- [本線CI 34626226071](https://github.com/soso-so-27/neko-widget/actions/runs/34626226071)成功。ログで同一SHA・候補runの証拠再利用を確認。成功したnative確認は反復していない。
- 画像・メタデータ等の証拠は作業worktree内 `output/visual-simplification/`。iOS 26の一覧は `window-mixed-standard-ios26.png`。画像はレイアウト確認用で、ユーザー端末の写真を取得したものではない。

## TestFlight 153

- [配布run 34626353249](https://github.com/soso-so-27/neko-widget/actions/runs/34626353249)でバージョン1.0 / Build153の署名・検証・Appleへのアップロードが成功。
- sourceCommit・buildNumber・githubRunId・releaseModeが確認済みコード・153・34626353249・media-stagingと一致。IPA SHA-256は `946c9dcd0de9efaedf21ae6866a4836087c9b9c99a6a526013c8f0793618904c`。
- 暗号化署名artifact `10273899161`。既存14日保存を使用し、ローカルで復号していない。
- App Store Connectで処理完了、Build153の内部グループ「自分用」・テスター1人を確認。[Build153](https://appstoreconnect.apple.com/teams/c0938ad3-2941-4079-8248-0769666c8fd8/apps/6801962436/testflight/ios/cdfd3854-93ad-4fc7-a659-23cbe2917b20)。
- 日本語の変更点・確認箇所を登録し、App Store Connectの「保存済み」を確認した。ユーザーの再ログイン後、配布確認まで完了。
- 外部テスター追加・一般公開・審査提出・課金開始は行っていない。

## 範囲

最新main `99bd001` から別worktree `C:/dev/neko-visual-simplify-20260912`、branch `codex/visual-simplify-20260912`。研究worktreeには触れない。データ形式・通信・Widget選定・課金・外部公開は変更しない。TestFlightは既存の内部確認範囲。
