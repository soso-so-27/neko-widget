# 185：記録の作成画面を開く際のクラッシュ

## 現在の状態（2026-09-19、186アップロード完了）

185の実報告2件は iOS 27.0 (24A437)。配布185とUUIDが一致するdSYMで、終了時に全写真の並べ替えが主スレッドを占有していたことを確認した。通常アルバムの集計を描画から切り離す修正を含む **186を内部TestFlight向けにAppleへアップロード済み**。実iOS 27端末でのクラッシュ解消、Apple側の処理完了・配布画面の表示は未確認。

製品修正 `0b3189c`、テストの型補正 `feebe7b`、既存検証の参照先調整 `822c942` をまとめた候補 **`822c942bd7c675ba1061de644c67175e347e8ba2`**（commit日時 2026-09-19 11:13:09 JST）を検証し、その同じSHAを `origin/main` へfast-forwardして配布した。検証待ち・配布前に別の製品差分は加えていない。

| 証拠 | 結果・時刻（JST） |
| --- | --- |
| 候補CI [35415010889](https://github.com/soso-so-27/neko-widget/actions/runs/35415010889) | full-v1全8job成功。11:13:16–12:12:46、59分30秒 |
| アルバム集計の既存Swift検証 | 最新候補の6,002写真で除外・成長写真上書き・取消境界PASS、Mac上の集計0.4055秒。実機の画面応答時間を示す値ではない |
| app-ui job `105822048052` | 51件、失敗0。`testPersonalArchiveRestoresPhotoAndTextAndExplicitlySavesNewText` は12:05:03にPASS（27.940秒）。実Settings経路を通るが、保管transportはfixtureであり実CloudKit通信の証明ではない |
| main CI [35417942551](https://github.com/soso-so-27/neko-widget/actions/runs/35417942551) | 12:13:33–12:13:53、成功。上記同SHA候補の全必須成功をplanが再利用 |
| 配布 [35418036611](https://github.com/soso-so-27/neko-widget/actions/runs/35418036611) / job `105830349833` | build 186、media-staging。既存CLI dry-runで直前予約185・186未使用を確認後、同一引数でdispatch。対象SHA/buildを照合して既存testflight環境を承認。12:15:31–12:22:00、成功 |
| Apple upload | **12:21:55 `UPLOAD SUCCEEDED with no errors`**。Delivery UUID `377d41a8-d4fb-4a73-8a34-ec331db65924`。archive/export/validateも成功 |

配布ログではbuild 186、PersonalArchive有効、archiveのiCloud `Production` / `iCloud.jp.nekowidget.app.personal` を確認。署名設定の確認と、実端末のCloudKit動作確認は区別する。証拠は `C:/dev/neko-evidence/crash185-20260919/` の `candidate-822c942/`、`main-822c942/`、`testflight186/` とCLI dry-run/dispatch記録に保存。旧候補 `35414441311` / `35414698132` のキャンセル結果は成功証拠に使用していない。

以下は調査時点の経緯を残したもの。「OS未確認」「未配布」「検証未実施」等の過去記述より、この現在状態を優先する。

## 利用者報告と調査開始時の状態（履歴）

2026-09-19、設定→記録の保管は開くが、「写真と言葉を選ぶ」を押した直後にアプリが落ちるとの報告。写真選択後や保管実行時ではない。最新main c4a2318から独立worktree `C:/dev/neko-archive-crash-20260919` / `codex/archive-crash-20260919` を作成した。原因確定・修正版配布・実機解決はまだできていない。

利用者からTestFlight報告を送信済みとの回答あり。送信後にApp Store Connectのクラッシュ一覧を再読込したが、185は未掲載。通常のスクリーンショットフィードバック側も「ありません」だった。再送・再ログインは依頼しない。過去の177/179にはiOS 27.0の報告があるが、今回の端末OSと同一と断定しない。今回のOS版は未確認。報告が掲載されたら詳細画面のダウンロードからzip内のクラッシュ記録を確認する。Apple公式手順: https://developer.apple.com/help/app-store-connect/test-a-beta-version/view-tester-feedback 。常駐監視・定期自動確認は設定していない。

## 確認できた不備と未確認の仮説

### 端末の実報告を受領（2026-09-19）

利用者が添付した `NekoWidget-2026-09-19-101454.ips` と `NekoWidget-2026-09-19-001324.ips` を確認。両方とも Build 185 / iPhone17,1 / iOS 27.0 (24A437)、アプリUUID `e803afbf-f0d4-3feb-a6b0-db20e0944ebd`。一般Analyticsファイルは今回の原因特定には使用していない。

- 例外は `EXC_CRASH / SIGKILL`、FRONTBOARD `0x8BADF00D`。終了要求に5秒以内で応答できなかった `process-exit` watchdog。強制終了時のサンプルであり、操作直後の最初の停止箇所と同一とまでは断定しない。
- 主スレッド56フレーム中53が一致。アプリ内の同期処理から `NavigationStack` / `TabView` / SwiftUIの画面再描画へつながる。同じ根にある処理負荷が疑われる。
- CloudKit、例外送出、queue違反assertのフレームはない。下記CKAccountChanged対策は確認できた別の不備であり、この停止の原因を示す証拠ではない。
- 配布run `35357759789` / artifact `10553770172` の暗号化archiveは保持期間内。正しい185のdSYMをHMAC検証・復号し、UUID一致後にアプリoffsetを照合する。新しくビルドした異なるUUIDのdSYMで代用しない。
- 現時点で直接の原因関数・修正版配布・実機解決は未確認。ASC掲載待ち・報告の再送依頼は不要。

診断のみのmain `ef489e8` は固定185を認証/復号して関数・行番号だけ出す手動workflowとスクリプト。製品・署名・配布処理の変更なし。独立実装＋主担当レビュー、専用境界8件、既存関連6件、development-flow8群を通したうえで導入。保護されたtestflight環境のルールは維持し、解析run `35413062491` だけ承認した。副作用で起動したmainの全件iOSチェック `35413058028` がMac5枠を占有して診断を待たせたため停止。停止runを成功証拠として再利用しない。製品修正は新しい候補SHAで必要CIを実行してから配布する。

以下のOS未確認・報告待ちという記載は、実報告受領前の調査経緯。

### dSYM照合結果

解析run `35413833057` 成功（main `83b9503`）。認証・archive digest・185 UUID一致を通し、両報告のアプリフレームを解決した。ローカル証拠: `C:/dev/neko-evidence/crash185-20260919/symbolication.log`。

共通経路（配布185時点の行番号）:

1. Swift配列のstable sort / merge
2. `CuratedAlbumBuilder.orderedUniquePhotos(_:)` — `AppPresentationModels.swift:480`
3. `CuratedAlbumBuilder.sections(...)` — 同353
4. `MainTabView.curatedAlbumSections(for:)` — `MainTabView.swift:956`
5. `MainTabView.albumsView(...)` — 同617
6. `MainTabView.body` — NavigationStack / TabView生成

終了時に全写真の並べ替えが主スレッドを占有していたことを2件で確認。記録のCloudKit送信処理を直接指す報告ではない。描画のたびにアルバム全件を同期生成する構造が具体的な修正対象。除外Setの反復生成だけを直して解決済みとはしない。

修正方針: 通常のアルバム一覧の集計とピックアップ生成を描画から切り離し、写真・権限・ソース・所属・除外・生年月日・成長上書き・推薦日が変わった場合だけ背景で生成。入力が変わった直後は古い結果を渡さず、世代が一致した結果だけ表示する。MainTab.bodyを通らないWidget直行経路の詳細解決は維持する。完了・実機解決は検証結果を追記してから判断する。

診断の初回はatos出力の画像名を固定しすぎたため結果取り出しに失敗。2回目は関数名を不明扱いし、3回目でDWARFの元のファイル名維持と出力形式対応を修正して上記結果を取得。調査側の手戻りであり、アプリ修正成功とは別。診断のみの自動iOS run `35413679244` / `35413832665` も停止し、成功証拠として使わない。

2026-09-19再開時、ASCのテスター詳細で185を入れた実機はiPhone 16 Pro（iOS 27.0）とiPhone 11（iOS 26.6.2）の2台と確認した。今回落ちた端末がどちらかは未回答。クラッシュフィードバックは引き続き177/179/176/172の4件のみで185なし。再送の繰り返しではなく、端末にある当該時刻の `NekoWidget` の `.ips` を直接受け取って原因を絞る手段がある。Apple公式の取得手順: https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs 。

単独再現の既存手段を独立担当が確認した。既存workflowの手動起動はfull固定、登録self-hosted runnerは0台、既存SSH接続先もなく、現在のWindowsからこの1件だけを既存Macへ実行できる入口はない。Macが利用できる場合の対象selectorは `NekoWidgetUITests/SoloMemoriesUITests/testPersonalArchiveRestoresPhotoAndTextAndExplicitlySavesNewText`。旧ログではビルド開始→初回テスト約7分、対象操作21.7秒。今回の実Settings経路は未実行。既存CIのiOS 26.2で通しても、当該26.6.2/27.0実機の再現・解決証明にはならない。新しいCIや無関係な一式検査を原因不明のまま起動していない。

- CKAccountChangedは任意queueで通知される。保管一覧と作成画面の2箇所がmain queueへ移さず画面状態を更新していたため、`.receive(on: DispatchQueue.main)` を追加した。独立レビュー済み。同期的なaccount epoch無効化は維持。今回の直接原因と断定しない。
- 185のUI試験は同じ製品ViewとStoreを使うが、root NavigationStackからの入口だった。実物の設定sheet→NavigationLink→作成sheetの経路を通していなかった。この不足を、fake transportだけを注入する実Settings経路の試験に置き換える。
- 写真未選択時点なので、画像の変換・metadata除去・CloudKit zone/record保存処理にはまだ進まない。再accountContextの通常エラーは捕捉済み。署名・container初期化を原因とする証拠も現時点ではない。
- クラッシュstackのスレッド違反／SwiftUI・UIKit・input accessory系を確認して仮説を絞る。OSのせいと決めつけたり、未確定の修正だけを「解決」として配布したりしない。

ローカルではSettingsSheetHostへ既存NavigationStack/Close toolbar/drag indicatorを共通化し、製品MainTabとfixtureで再利用。fixtureは実SettingsView/実NavigationLinkから作成画面を開く。archive Storeだけを専用temp＋fake transportとして注入し、他の設定操作は無副作用callbacksとする。MainTab全体の既存note/movieストアは起動しない。既存のN29試験1本に、空の作成画面→戻る→再表示→入力・Done・保存→一覧を組み込んだ。実AppRoot全体・実iOS27・実CloudKit通信の試験ではない。

4ファイルの製品/fixture差分は読解レビューとdiffcheckまで。Macコンパイル・UI実行は未実施、commit/push/修正版配布も未実施。クラッシュの直接原因を確認できる報告を待ち、原因修正と検証をまとめる。今回の未確定対策だけで配布を繰り返さない。

Appleの通知仕様： https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/ckaccountchanged

## 機能の目的と扱い

目的は、写真に添えたアプリ独自の言葉や記録を、機種変更や端末紛失で失わず取り戻すための基盤。独立した保管庫の操作を増やすこと自体は利用者価値の完成ではない。現在の別画面は明示登録・保存・読込を確認する内部試用の入口であり、最終的には普段の写真・メモの流れにつなぐ。既存記録の無断アップロードはしない。

185の試用画面の意味が分かりにくかった点と、起動クラッシュの不具合をともに未解決として扱う。全件同期・編集削除・原本バックアップ・販売開始は今回完成したものではない。
