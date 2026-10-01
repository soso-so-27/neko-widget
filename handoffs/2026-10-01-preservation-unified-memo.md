# メモの保管導線と旧iCloud保管（2026-10-01）

端末内のメモと以前のiCloudコピーを、同じ「メモ」画面→「…」→「サービスに保管」に揃えた。旧コピーは選んだJPEG・文章・日付・猫名・体重を読み取り、本人と記録内容を準備前後に照合する。元のPhotoKit写真がなくても保管済みコピーから準備できる。選択コピーの画面から別の保管記録を編集する入口は出さず、設定の記録閲覧と本人に紐づく未送信メモの復旧を保持する。

新規iCloud保管のUI入口は、サービスOFFの場合も含め撤去した。設定は「以前のiCloud保管」。既存分の読込・編集・ZIP・削除は残し、以前に反映を選んだ編集はそのiCloudコピーに引き続き反映する。自動移行・自動送信はしない。

## 固定候補と確認の範囲

候補31a04fc8d5045e2f67c5e1b46c30019a94e7dbeb、比較base bbab9ab2a7b95c285eb63ad84fd01eeff46b766b、PR141。日常3ツールの会員境界PR140と本線記録PR142を統合した。14製品blob・5テスト本文/helperの入力不変を独立レビューし、影響のない4件の成功をCI36822696936から保持した。診察メモ選択1件だけは今回変更したメモ詳細に依存するため、通常保管jobへ加えた。

確認はBuild、Photos bootstrap、保管runtime3境界（両OS）、関連native7操作。Widget Gallery・通常Widget表示は対象外。署名とprivacy・内部配布の境界は保持する。サーバー配備、公開、実課金、pilot期限延長は行わない。

## 失敗・訂正を含む経過

- 診断36818401015: 201秒でcompile失敗。廃止した状態変数への残存代入を除去した。
- 診断36819156095: 1316秒でUI失敗。既存反映メモの編集・iCloud削除後の端末メモ保持は成功。旧コピーのメニュー・タイトル・正確な文章は観測したが、画像はplaceholderで同意操作も未準備。fixtureの片付けを安定したNavigationStackへ移し、画像loadedと操作準備を待つよう変更した。この初回失敗の因果関係は確定していない。
- 通常36822682643: 248秒でcancelled。新規iCloud保管を案内する旧説明1文が残っていたため、文言を直して再固定した。native未完了を成功扱いしない。
- 通常36823283166: 1782秒でfailure。Build・Photos・3runtime境界（両OS）は成功。native6件中5成功。選んだ写真の実描画と正確な文章も確認したが、同意スイッチが見出しの裏へ隠れ、isHittable=trueのまま試験が見出しを押した。製品を迂回する変更は行わず、行を見出しの下へ戻し、switch value1/0と保存enabled/disabledを確認する試験修正83e9f767を加えた。
- 統合後の制御bindingは、key順とbefore自己表のcanonical化で2件不一致をMac起動前に発見。sort_keysの完全literalとRAW before/自己表空afterへ訂正した。最終31a04fcは実11パスのbefore/afterをselectorへ渡してv5・7件を確認し、独立照合も成功した。

Python12suiteは265.8秒で成功。mainの制御変更統合後は影響するtest-plan86件/96.736秒とlane16件/2.637秒が成功。最終control-only CI36828363180は23秒で成功（Mac skip、native/配布証拠とは別）。成功した試験の入力不変を示せた部分は保持した。

## 最終確認と配布

focused Memory診断36828453069 attempt1は991秒でRunnerがXCTest接続前にsignal killとなり、操作0件・描画添付0件で終了した。アプリ/テストのビルドは完了しており、製品失敗とは確定しない。同SHA・同1メソッドをfresh runnerで再実行したattempt2は809秒で成功。メソッド全体159.224秒、選択JPEG/文章・同意ON1保存有効/OFF0保存不可・元写真と一覧への復帰を実際に確認した。失敗の時間は消さない。

通常候補[CI36831876667](https://github.com/soso-so-27/neko-widget/actions/runs/36831876667)は全4必須job成功。native7件を全実行、0失敗・0skip（629.480秒）。保管runtime3境界の両OS、Build、Photos bootstrapも成功。実描画で旧コピーのサービス入口・JPEG/文章・同意OFF、端末メモの同じサービス入口を確認した。

[PR141](https://github.com/soso-so-27/neko-widget/pull/141)を2026-10-01 17:10:40 JSTに本線へmerge（636dfa6bf75be2997477bbdc1ac249e475adb8a1）。main CI36834705579は候補31a04fcとCI36831876667の成功証拠を再利用し、Mac再検証はしなかった。

内部[build235/run36834987212](https://github.com/soso-so-27/neko-widget/actions/runs/36834987212)を同じ候補で1回だけdispatchし、**2026-10-01 17:25:39 JSTにAppleアップロード成功**。実ログの `UPLOAD SUCCEEDED with no errors`（08:25:39.225442 UTC）を確認した。製品sourceは31a04fc、workflow/mainは636dfa6。日常3ツールの会員境界とメモ/旧iCloud導線の両方を含む。既存のtestflight環境承認だけを適用し、保護設定・公開・実課金・保管サーバー・pilot期限は変更していない。

Apple側の処理完了、235の実機表示は未確認。一般提供の保持期限・事前通知・期限消去・販売の運用が完成したという意味ではない。既に利用者が成功した実写真保管・同本人での再確認/復元・ZIPの結果を保持し、今回の導線整理のために再要求しない。

## 時間

最初の調査04:34 UTCは概算。初回製品候補04:47:20.136587 UTCからAppleアップロード成功まで**218.3分（約3時間38分）**。失敗、訂正、cancel、main統合、制御binding訂正、最終確認とuploadを含む。当初45〜60分を大きく超過した。

通常成功CIは23.4分、upload runは12.183分であり、この2 runだけを総時間としない。CI runner75.467分、upload runner10.567分は実行資源の時間で、請求額やCodex token数ではない。途中で旧full-route最大を計画参照したことは、Widget検証を実行したことでも、このscopeの実績でもない。失敗した通常run29.7分とcompile/診断/cancelの個別時間も計測台帳へ保持した。
