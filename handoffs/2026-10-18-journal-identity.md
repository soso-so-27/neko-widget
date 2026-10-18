# 2026-10-18 実機J4と整理記録の同一性

## 観測と候補

- 14:05の利用者画像はTestFlight 261の「保存済み」と、整理記録の確認コードJ4。保存状態の訂正は実機に届いた。J4は旧実装のURL全体の等価比較であり、場所の表記とowner/index hashのどちらが不一致かは画像だけでは決まらない。
- 最初の診断候補は `115a4abd4bfb7ae1e3fed3ad9b3e811c8e17d9aa`。診断39099710415は19分30秒で成功し、既存runtime42件と削除再開UI1件を実行。日時の隣接4096値でhash再計算の不一致0、temporary/Application Support両方の通常URL列挙も等価だった。実機原因の再現成功とはしない。
- 製品候補 `c9bbd87fff815acbc351936a7614cc07f11df8a2` は、rootの非再帰列挙と通常ファイル・非symlink・サイズ・index検証の後で、ownerとindexを結合した完全hashのファイル名を照合する。既存journal/receipt名、本人filter順序、転送・削除・参照保護・保存先・表示・契約の処理は変えない。
- DEBUG fixtureは実Application Support内の専用ディレクトリを基底付きURLで開く。列挙されたURLと従来の期待URLが不等だが同じパス・bytesを指すことをassertし、旧guardならJ4、新guardなら再開成功となる経路を検査した。owner/index/名前改変J4、symlink/ディレクトリJ1の拒否と原本保持も成功した。
- 同候補の診断39101089286は19分47秒で成功。既存の削除再開・private copy復元の2caseが各1回成功し、UI logは `sameFileDifferentURL=true legacyJournalMatch=false dateMismatch=0/4096`。実iOSで合成したURL表記差の回帰検証であり、利用者の実ファイルでの原因確定ではない。診断を配布用成功証拠へ読み替えず、実機のJ4解消は更新後に確認する。

## 検査選択の境界

- `reviewed-journal-identity-v1` は上の3既存ファイルだけを完全before/after digestで固定する。AppRecordPersistenceの差分はDEBUG fixtureのみ、UITestは既存helperへの観測追加のみ、製品変更はToolBackupFiles.pendingDeletionsの識別比較のみ。通常handoff以外の追加・欠落・混在・部分差分、mode/type変更、制御同梱はこのscopeにしない。
- 制御変更は製品と別branchで先にmainへ統合する。その後、同じ制御のbase/headで製品を検査する。workflow、署名、依存、Widget、Shared、backend、写真走査、公開/課金設定の入力は不変。これらの描画caseは今回の比較分岐を呼ばず、無関係なgallery/全UIは繰り返さない。
- 新候補でBuild全体（privacy・migration・署名条件を含む）、Photos起動bootstrap、両OS runtime、削除再開・参照写真を含む復元UI2caseの4jobをすべて実行する。失敗・skipを成功へ数えず、main再利用と配布CLIは同じ候補SHAの通常push証拠を使用する。新しいarchive・署名・Apple uploadは必要。
- 新scopeは未計測。診断の参考は今回19分30秒、直近旧fullは94分48秒＋失敗2jobの約58分再検査、upload12分19秒。今回の4jobは30〜45分の計画値で、実績とはしない。初回候補の14:10:16 JSTから診断・試作・制御・CI・待機を含め記録し、全体150分の計画枠とする。超過時も計時をリセットしない。

## 保持する条件

- 月額980円。public repositoryの既存標準runner/artifact構成を使用し、新しい契約・有料設定・クラウド更新・受付/カウンター/定期変更は0。
- 利用者の写真・メモの復号、元データ削除、再インストール、繰り返し再保存を要求しない。
- 新v3の実機復元、一般利用量の長期容量・索引/復旧性能、動画クラウド保存、一般提供条件は別の残件。

ローカル証拠は `C:/dev/neko-evidence/automatic-test-20261018/journal-identity-*`。独立境界レビューは `journal_identity_review`。最初の通常URL診断が再現しなかった事実を保持し、実機原因を確定したと報告しない。

## 制御確認と配布候補

- ローカルlane27件と開発15suiteが成功（169.2秒）。独立した制御PR351の通常push39101595726も必要plan stepを実成功し、main `9402a963` へmerge commitで先行反映した。既存release CLI/workflowは変更していない。
- 製品branchはこのmainだけをmergeした。3製品ファイルは診断c9bbd87と同じ内容。診断の成功を保持しつつ、通常pushのBuild・Photos・両OS runtime・UI2caseを新候補で実行する。次の内部配布番号は262（直近配布は261）、preservation-pilot/internal-reports、billing OFFを維持する。

## 通常検査・main反映

- 固定候補 `a8f4b95fccdd48b1958411abb381ab66af0d0e08` の通常push `39102326231` は、必要な4native jobすべて初回成功。全体25分34秒、jobの実step範囲合計79.533分（請求分数ではない）。無関係な2placeholderはskipのまま成功件数に含めない。
- UIの実ログで両caseのstarted/passed各1回、失敗0、146.416秒を確認。`sameFileDifferentURL=true legacyJournalMatch=false dateMismatch=0/4096` も配布候補で確認した。両OS runtime・Photos bootstrap・Buildのprivacy/migration条件を通過。診断だけを通常CIの代わりにしていない。
- PR352をmerge commit `ede3e273f62a7969261679f6bc79607181b53c0b` でmainへ反映し、候補の祖先関係を確認。main run `39103868751` も成功した。配布CLIのdry-runは同じ候補SHA、成功CI、262の未使用、内部pilot/reports設定を確認した。
- TestFlight **262** / `39103926998` を一度dispatchし、**15:36:14.663 JSTにApple upload成功**。job `117605669381` のsource checkout a8f4b95、署名/App Group/privacy確認、archive/export、実ログ `VERIFY SUCCEEDED` / `UPLOAD SUCCEEDED` と後片付けの成功を確認。workflowは上記main、app sourceはa8f4b95。全体11分53秒、step範囲合計11.317分。既存testflight環境の今回runだけを承認し、環境規則や公開範囲は変更していない。
- 今回の測定を `ci-timing-baseline.json` に追加し、旧観測は保持する。初回候補05:10:16.7978355 UTCから計時し、最初の通常URLでは再現しなかった診断と制御作業を省略しない。
- 初回候補からApple uploadまで **1時間25分58秒**（診断2本・試作・制御・検査・待機込み）。150分計画枠内。新構成の通常CI25分34秒を、その全作業時間と混同しない。
- 残る実機確認: Apple処理後に262へ更新し、「設定 → 保存・復元」を開いたまま再確認ボタンを押さず待ち、J4が消えるかを確認する。その後、通常写真のメモを1件編集して自動で保存済みになるかを見る。利用者の実journalの原因・J4解消、Apple処理完了/262の端末表示はまだ未確認。元記録削除・再インストール・再保存は不要。
- 配布後の記録変更はhandoffと時間観測JSONのみ。新しい観測を含む開発15suiteは171.9秒で成功し、製品のnative/配布検査を再実行していない。
