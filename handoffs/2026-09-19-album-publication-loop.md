# 186の再発：アルバム更新ループと記録作成画面

## 状態

利用者が186へ更新後、記録作成の問題は改善せず、アルバムが点滅して読み込み表示になると報告。186を解決済みとして扱わない。修正版 `7e71b66730b92004a0bd664fd6b65a99794f4192` は独立候補 `codex/album-loop-20260919`（main `e38b348` 起点）で検証成功後、同じSHAをmainへ反映。**187は9月19日14:38:56 JSTにAppleへ内部TestFlight向けアップロード成功**。Apple側の処理完了・実機での解消は未確認。

## 実報告と検証不足

- `NekoWidget-2026-09-19-125743.ips` は186、iPhone17,1、iOS 27.0 (24A437)、アプリUUID `8068bd8b-8152-3280-b3e9-99f8bf1efc04`。
- 今回はFRONTBOARD `0x8BADF00D` のscene-update watchdog（10秒）。主スレッドはUIKitのtrait変更、view挿入/除去、SwiftUI DisplayList、navigation bar/split viewのレイアウト。185で採取された写真ソートとは異なる終了時点である。
- 前回は終了時の重い集計を直したが、最初に固まる原因と修正後の更新頻度を十分確認していなかった。試験は実Settingsを通っても、その背後のAppRoot/アルバムを動かしていなかった。
- 下記の更新ループはコード上の具体的な不備。これが今回のiOS 27実機のwatchdogをすべて説明するかは、修正版の実機結果まで断定しない。

## 確認した更新ループ

1. スキャン進捗のsnapshotは写真が不変でも `updatedAt` を更新する。
2. 186はその時刻をアルバムの再生成キーに含め、進捗通知ごとに前の集計を無効化する。
3. 無効化のたびにアルバムの子画面全体をProgressViewへ置き換え、旧taskを中断する。
4. 集計より通知間隔が短ければ完了できず、速ければ内容とspinnerが交互に現れる。設定sheet/NavigationLinkの背後も同時に組み直される。

同じ写真ソース集合を再代入しただけでsource revisionを増やす処理も、不要な無効化につながっていた。

## 修正

- snapshot公開時に実際の写真変更と写真脱落を判定し、進捗・保存時刻・アルバム利用回数だけでは写真の表示revisionを変えない。View.bodyで全配列のhash比較はしない。
- 集計を所有するcoordinatorで同時workerを1本にし、処理中の内容更新は最新1件へまとめる。安全な表示済み内容は更新中も維持する。
- 写真削除、除外・所属・表示元・権限の変更は内容追加と分け、旧結果を即時拒否する。取消後に遅れて終わったworkerも世代で拒否する。
- 同じsource集合の再解決ではrevisionを増やさない。
- スキャン中は、季節ムービーの準備と同じ条件でPhotoKitのvideo digest取得も停止する。
- 権限縮小時の許可ID解決についても独立確認し、旧集合を新しいlimited権限キーで作り直さない境界を追加。limited移行・選択変更・前景復帰では現在の許可IDを背景で照合し、世代一致後に表示を再開する。通常のauthorized権限では全ID照合を追加せず、進捗や自動アルバム更新で表示を閉じない。保留中のWidget URLも許可ID解決後に処理する。

永続写真・所属データの削除、課金・CloudKit保管仕様、公開範囲の変更は行わない。

## 今回の確認範囲

- 純粋Swift検証：進捗100回、同数写真差し替え、猫候補脱落、処理中の更新集約、取消非協調worker、削除/権限喪失と復帰。最大同時worker数1と最終内容を確認する。
- 既存の記録保管UI試験1本を実AppRoot/MainTab＋6,000枚＋2匹所属のfixtureへ置換。進捗通知中の表示維持、設定→記録→入力の開閉、背景/前景復帰、保存、実内容更新、写真削除、権限変更を通す。
- `albums-root` があるだけで成功にしない。内容の可視性・写真数・問題対象IDの非表示・worker開始数を確認する。
- fixtureの外部入力と保管transportは擬似データ。実PhotoKit/CloudKit通信、iOS 27実機の成功とは区別する。
- ローカルdevelopment-flow8群成功（38.4秒）、既存共有/Widget境界63件成功（既存skip1）、設定境界11件成功、差分チェック成功。Macの結果は下記。

## 候補・本線での検証結果

| 確認 | 結果 |
| --- | --- |
| 候補CI [35421396865](https://github.com/soso-so-27/neko-widget/actions/runs/35421396865) | full-v1、8 jobすべて成功。13:28:54–14:26:43 JST、57分49秒 |
| アルバムの純粋Swift検証 | 重複要求・最新要求への集約・表示維持・権限変更・削除・取消後の遅い結果を確認。進捗だけのrevision不変と、limited権限の縮小/古い照合/拒否/全面再許可/空選択も成功 |
| 実AppRootを通る記録UI | `testPersonalArchiveRestoresPhotoAndTextAndExplicitlySavesNewText` が14:16:59 JSTに成功、94.312秒。6,000枚・2プロフィール・進捗更新・設定sheet/作成画面開閉・前景復帰・保存・更新/削除/権限境界を一つの試験で確認 |
| アプリ操作全体 | iPhone 17 Pro Simulator、iOS 26.2、51件すべて成功。実iOS 27の確認とは区別する |
| 画面画像 | アルバム表示後、作成画面、作成からアルバムへ戻った後の3枚を主担当が確認。アルバムは前後とも内容を表示。画像はfixtureで、下部の更新/削除/権限ボタンも試験専用 |
| main CI [35424089521](https://github.com/soso-so-27/neko-widget/actions/runs/35424089521) | 同一SHA候補の全必須成功を再利用して成功。14:29:40–14:29:57 JST、17秒。未実施項目を成功扱いした省略ではない |

証拠は `C:/dev/neko-evidence/album-loop186-20260919/`。約703MBのUI artifact全体を展開せず、zipの範囲取得でmanifestと対象3画像のみ取得（約1.84MB）。実CloudKit保管通信はこのfixtureの成功範囲に含めない。

## 完了の区別

実装、候補CI成功、内部TestFlightアップロード、利用者の実機で点滅/作成画面の停止が解消した確認を別々に記録する。前回と同様にアップロードしただけで「クラッシュ解決」とはしない。

## 187の内部アップロード結果

- 配布run [35424156898](https://github.com/soso-so-27/neko-widget/actions/runs/35424156898)、job `105847098855` は成功。14:30:59–14:39:03 JST、8分4秒。
- 既存release CLIのdry-runで同一SHAの候補/本線CI成功、直前予約186、187未使用を確認し、同じ引数で一度dispatch。対象SHA/187と一致するrunだけ既存testflight環境を承認した。
- archive・export成功、14:38:56 JSTに `UPLOAD SUCCEEDED with no errors`。Delivery UUID `0f888e47-9a8b-4de0-90ea-b27516bb469e`。
- 証拠は上記ローカルフォルダの `release187-dry-run.json`、`release187-dispatch.json`、`testflight187/upload.log`。通常の完了証拠としてApple uploadを使用し、App Store Connectの再ログイン/画面巡回は行っていない。
- 次に利用者が187で確認するのは、アルバムが点滅せず内容を保つことと、設定→記録の保管→「写真と言葉を選ぶ」を開いて戻れること。iOS 27で解消したと確認できるまでは、クラッシュ全体を解決済みとしない。