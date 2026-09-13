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
- N05：2worker化を実測した結果、不採用。以下の候補変更はmainへ入れない。案内文1行は次の製品バッチへ取り込む候補として保存する。

## N05：候補の変更と安価な検証

既存scopeの選択集合を保ち、アプリ4class・33ケースは2workerで実行する。通常Gallery1件だけを別の直列実行へ移し、通常／長文・白背景／字幕なしの3条件を維持する。通常Galleryは同じbuild済み成果物を使用し、残り2条件は従来どおり専用buildを作る。

[AppleのXcode仕様](https://developer.apple.com/documentation/xcode-release-notes/xcode-10-release-notes)で、CLIフラグによるscheme設定の上書きと、workerごとのSimulator cloneを確認した。今回新しくできた選択端末のcloneだけを停止・消去してからGalleryへ進む。既存端末や別OSはこの追加処理の対象にしない。アプリの起動・保存実装は変更していない。

安価な検証：並行準備・ケース分割・clone限定・失敗伝播7件、Gallery境界12件、Bash構文、diff確認が成功。CI実装は担当を分け、rootが対象差分とApple仕様、成果物の参照先、全33ケースの保持を独立確認した。

候補CIでは、実際のworker配分・全33ケース・Gallery3条件・両OS runtime・終了時の清掃を確認する。並列実行の成功1回だけで長期の安定性を保証しない。`ui-parallelism.json` に同じSHAと新規clone数を残す。通常Galleryの成果物は `Widget-normal.xcresult` / `widget-normal-screenshots` へ分離した。

## N08：確認用写真の期限更新

現行HTTPS応答から、確認用3枚が2026-09-13 10:32 JSTで期限切れになることを確認。既に利用者が差し替え・反映を承認したキジ白・茶トラ・白黒猫の3枚を、同じ確認用Workerで継続表示できるよう期限を更新した。新しい写真・募集・外部テスターを追加する作業とは別。

- 新期限：**2026-09-15 09:52:36 JST**。catalog生成から48時間、写真ごとの掲載期間も14日上限内。
- 変更は `generatedAt` / `validUntil` / 3枚の `expiresAt` だけ。写真のID・順序・元の掲載日時・ひとこと・AI生成の出自・JPEG bytes/hash/寸法を保持。元画像は再圧縮しない。
- rootが旧配備パッケージと比較。Worker本文は改行形式を除き同一、アカウント・Worker名・bindingも同じ。準備担当とroot確認・配備を分離した。
- Wrangler 4.125.0 のdry-runと配備が成功。アップロードはcatalog1ファイルだけで、画像3枚は既存assetを再利用。版 `0a0cdde0-7573-4bc3-9943-ad877d0f993f`。
- 配備後、catalogが候補と一致し、JPEG3枚がHTTP 200かつSHA-256一致することを確認。利用者の端末が新期限を取得したことまでは確認していない。

証拠は `output/official-renewal/renewal-20260913T005236Z/` の `verification.json`、`dry-run.log`、`deploy.log`、`http-result.json`。元のlocal assetは `C:/dev/neko-widget-official-local-proof-20260910/generated-cats-v3-20260911/bundle/assets/`。生成物・依存パッケージはcommitしない。

自動更新は作っていない。期限更新だけを繰り返して新着が届くように見せず、継続運用はN08の写真供給・更新頻度の判断とセットで残す。

## 候補CIの結果と不採用の判断

[run34728780573](https://github.com/soso-so-27/neko-widget/actions/runs/34728780573)、候補 `ae2790e167dc36d3b1c9f72b2d744c3517052ca9`。作成から最後のjob終了まで**48分56秒で失敗**。前回の全条件成功48分43秒より速くなく、今回は未実行条件もあるため、同等の性能を示す結果にも使えない。

- Release build：7分29秒で成功。
- SMOKE：21分15秒、既存UI12件成功。このjobのコードは今回変更していない。
- 両OSの共有runtime：各38件成功。
- アプリUI：33件が実際に二つのcloneへ渡され、32件成功・1件失敗。Clone 1はSolo 12件＋Composer 9件＋Cat 1件、Clone 2はOfficial 11件。ケース時間の合計は1577.249秒（26分17秒）対441.362秒（7分21秒）。これは各workerの壁時計時間ではないが、配分と処理時間の偏りが残ることを示す。
- 失敗：`SoloMemoriesUITests.testEmptyAndSingleSavedPhotoStartWithPhotosIncludingDeniedAccess`。添付には `solo-memories-other-screen` の要素記述がある。原因を未確認のまま製品不具合・負荷だけと断定しない。
- 通常Gallery：小サイズにfixture写真が表示されず失敗（`WidgetPlacementScreenshotUITests.swift:747`）。長文・白背景／字幕なしの2条件は、その後のため実行されていない。通常Galleryで元Simulatorを初期化せず再利用した構成も次の検討対象だが、根本原因は未確定。

**2workerフラグ追加＋通常Gallery分離の候補は不採用。** 候補の同一SHA再実行や、失敗を無視したmain更新・TestFlight配布は行わない。既に19%短縮できている従来CIを維持する。必要なら次回は重いUI群を明示的に分担し、Galleryの実行環境を先に整える案から検討する。単なるworker数の増加を次の作業にしない。

製品差分は案内文の1行だけで、今回のまど設定ケース自体は成功した。ただし不採用CIと同じ候補にあるため、次の製品バッチへ1行だけ取り込む。今回mainへ反映するのは台帳・調査結果のみ。159のアプリ・配布元のコードは変更しない。

ログと集計は `output/parallel-ui-ci/sharing.log`、`smoke.log`、`parallel-result-summary.json`。詳細添付は上記runの `ios-sharing-runtime-matrix-34728780573-1` artifactに保持される。失敗箇所を特定できたため、全414MBを再取得して全画面を再監査する作業には拡げない。
