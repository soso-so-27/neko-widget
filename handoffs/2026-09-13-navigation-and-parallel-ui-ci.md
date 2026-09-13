# 主要導線と追加CI短縮

## 範囲・完了条件

タスク台帳N01〜N05を進める小バッチ。起点main `1455930`、worktree `C:/dev/neko-ux-navigation-ci-20260913`、branch `codex/ux-navigation-ci-20260913`。研究worktreeは編集しない。

- N01はアップロード済み159のApple処理・既存内部グループ・更新説明を確認する。再アップロードしない。
- N03は「写真を見つけて戻る」「まどを追加する」「表示・通知・接続を設定する」に絞り、既存のネイティブ生成画面と製品の遷移処理を照合する。具体的な不一致を修正する。初見の利用者評価を代替したとは扱わない。
- N05はアプリUI試験だけを最大2workerにし、SpringBoardを操作するGalleryは直列で維持。全選択ケース・両OSの共有runtime・署名等の必須検証・同一コードの証拠を維持する。候補CIの時間と成否で採否を決める。
- 関連変更を一度の候補CIへまとめる。今回のCI改善だけを理由に新しいTestFlightを配布しない。

## N03：照合結果

1. **修正**：身近な人のまど設定にあるWidget案内が「写真源」を選ぶよう説明していた。実際のWidgetパラメーター名「表示する写真」に統一した。公式まど側は既に正しかった。
2. **既存導線を維持**：まど一覧の「＋」から追加画面へ進み、「猫の写真を受け取る」と「身近な人と送り合う」に分岐する。設定中のまどは再開へ誘導する。現在の生成画面でこれらの操作が分離されている。
3. **既存導線を維持**：写真詳細は親のNavigationStackに積み、設定もまど画面からNavigationLinkで開く。fixtureが画面をルートとして直接表示した画像に戻るボタンがないことを、製品の戻る操作欠落と誤認しない。猫別写真も写真ページから直接開く既存経路を確認した。
4. **既存導線を維持**：まど設定はWidget表示・通知・名前と接続・安全の順。追加説明を常設する改修は行わない。

根拠：`MainTabView.swift`、`HomeView.swift`、`FamilyWindowView.swift`、`LikedPhotosView.swift`、`OfficialWindowView.swift`、`NekoWidgetConfigurationIntent.swift`。画像は前候補 `03b141c` / iOS 26.2 の実生成物で、`C:/dev/neko-connection-flow-20260913/output/connection-flow/final-runtime/ios-26-2/composer-screenshots/` に保持。

- `78D29BB6-4E5A-4E63-9658-EB082CBD4196.png`：まど追加
- `AED31A77-5320-4C26-A98F-F8C302999EFE.png`：まど設定
- `7BBEDB04-9C31-4B7C-BD0D-2345F6ED5FCD.png`：写真詳細

短い案内文修正だけのテストは追加しない。CIハーネス変更に必要な候補CIで既存操作ケースを実行する。初見理解、実機VoiceOver、大量の実写真での操作感はこの照合だけで確認済みにしない。

## 現在の境界

- N01：このバッチ開始時もApp Store Connectはログイン画面。再ログイン依頼済み。159はAppleへアップロード済みで、内部配布表示・日本語更新説明の保存が残る。
- N02/N04：利用者の「ねことも」の接続回復と原本を使う画質比較は実機結果待ち。fixtureの成功を実際の送受信・写真品質の成功として報告しない。
- N05：2worker化を実装し、安価な検証と独立差分レビューまで完了。追加短縮時間は候補CI成功後に記録する。

## N05：候補の変更と安価な検証

既存scopeの選択集合を保ち、アプリ4class・33ケースは2workerで実行する。通常Gallery1件だけを別の直列実行へ移し、通常／長文・白背景／字幕なしの3条件を維持する。通常Galleryは同じbuild済み成果物を使用し、残り2条件は従来どおり専用buildを作る。

[AppleのXcode仕様](https://developer.apple.com/documentation/xcode-release-notes/xcode-10-release-notes)で、CLIフラグによるscheme設定の上書きと、workerごとのSimulator cloneを確認した。今回新しくできた選択端末のcloneだけを停止・消去してからGalleryへ進む。既存端末や別OSはこの追加処理の対象にしない。アプリの起動・保存実装は変更していない。

安価な検証：並行準備・ケース分割・clone限定・失敗伝播7件、Gallery境界12件、Bash構文、diff確認が成功。CI実装は担当を分け、rootが対象差分とApple仕様、成果物の参照先、全33ケースの保持を独立確認した。

候補CIでは、実際のworker配分・全33ケース・Gallery3条件・両OS runtime・終了時の清掃を確認する。並列実行の成功1回だけで長期の安定性を保証しない。`ui-parallelism.json` に同じSHAと新規clone数を残す。通常Galleryの成果物は `Widget-normal.xcresult` / `widget-normal-screenshots` へ分離した。
