# 個人保管：アプリからの会員本人リンク

基点main `acdc9d0`、worktree `C:/dev/neko-preservation-native-link-20260922`。

## 目的・今回の完了条件

既定OFFの保管画面で、Appleによる保管本人確認の後、既存の会員情報への接続を明示同意で行う。未接続・通信失敗・応答紛失時の再確認を提供し、既存記録は解約後も会員照会なしに開く。勝手な新規billing作成、購入・復元・移行は行わない。

- 固定pathと環境audience・owner/account・期限を確認してから、端末の既存registered billing鍵でNWB1署名する。
- awaitの前後で保管session/epoch/Keychain、billing鍵/installationを再確認。別本人への遅延結果を適用しない。
- 接続と写真送信への同意は別。接続だけで写真・購入は送らない。会員確認失敗でも一覧・読み出し・編集・持ち出しは継続。
- native runtime境界確認、OFF入口と合成接続UIの2操作、実描画、独立レビュー、候補CI→mainまで。

## 検証範囲・費用計画

今回はSwift/UIのため本体/拡張build、Photos bootstrap、両OS runtime、変更経路のUI2操作を維持する。既存の共同記録UIは変更しない。旧v1固定manifestを流用せず、今回9つの既存製品/検証ファイルとCI companionを独立レビュー・固定する。

同構成の旧v1最終成功は14分47秒、失敗と診断を含む初回CI→mainは52分05秒。今回の新v2は未計測であり旧v1の時間を実績や保証にしない。preflightで既存full参照の適合性と時間上限を確認し、30分を超える場合は起動前に計画を記録し直す。必要のないTestFlightや重複Mac実行を行わない。

### 起動前の計画見直し

fullの観測時間は64.43 / 97.92 / 66.433分、最大97.92分。未計測v2に30分完了を約束せず、費用ゲートの計画上限を110分へ組み直す（配布なし）。これはv2を110分走らせる意味でも、短縮実績でもない。4必須jobを残したUI2件を初回計測し、失敗すれば最初の具体的原因で診断する。11群の安価なチェック後はpreflightのみを `--use-full-baseline --target-minutes 110` で行う。

独立レビューで本人越境/署名先差替えのブロッカーなし。保存拒否時の古い利用可能表示、UIテストのボタン有効待ちを修正した。fixtureは3つの応答境界でsession/鍵変更、同意なし、失敗→新challenge再試行、応答喪失→状態確認、解約後の一覧/詳細、保存時資格失効を確認する。実Apple・実backend相互接続・Task.cancelそのものの追加回帰はこのfixtureの証拠ではない。

## リリース境界

`ManagedPreservationEnabled`、Apple capability、実origin/audience/binding、課金/保存サービスは変更しない。実Appleや購入履歴は使わず、実2台復元・公開・配布の証拠にはしない。会員情報が失われた端末の実購入復元導線、アカウント変更、容量/保持/削除・実KMS/JPEG bridgeは残条件。

## 初回候補と診断

製品 `df6862c`、CI `94e7707`、初回候補 `3ff4340`。preflightは16実装/CIファイル＋資料1本、v2の4必須job、稼働中CIなしを確認して成功。

- 安価な11群の確認中に主担当がcommitしたため、実HEADと検査開始時SHAの一致を確認する2ケースが失敗した。製品失敗ではなく実行手順の不備。HEADを固定して該当2ケースだけ9.349秒で再確認し、未実行の残り6群も成功。成功済みの前半4群・同スイートの他13ケースは繰り返していない。以後チェック完了までcommitしない。
- native候補 `35692342424` は安全検査で試験用Viewの `error.localizedDescription` を検出。DEBUG fixtureにも生エラーを載せない方針に合わせ、固定の案内文へ置換。privacyの該当1ケースは0.190秒で成功。チェック自体を弱めず、同じ入力の盲目的なCI再実行はしなかった。Photos・両OS runtime・OFF入口は成功、候補全体は失敗（16分48秒、runner35.883分）。
- 両OS runtimeとOFF入口UIは成功。リンクUIはiOS 26の確認Popoverに存在しない「キャンセル」Button検索で失敗。描画とAXを回収して、外側の `PopoverDismissRegion` が閉じる操作であること、同じ確認Buttonが親子で2個現れることを確認。テストだけを実表示に合わせて `.firstMatch` とsystem dismissalへ変更し、閉じたことも待機する。製品の同意を自動承認する変更ではない。
- 専用diagnosticで `SoloMemoriesUITests/testManagedPreservationMembershipLinkConsentAndRetry` 1件だけ確認。起動前に近い診断経路の観測11分34秒〜16分08秒、専用job上限30分を参照し、今回そのものは未計測とした。診断 `35693419453` は `f53bc4c` で成功（11分42秒、runner11.483分）。同意を閉じる→接続→通信失敗→状況確認→新challengeで再試行→期限切れでも既存記録を開く、を実行した。

## 本線反映・完了結果

- 最終候補 `f53bc4c` / CI `35694399109` は15分11秒、runner53.083分で4必須jobが成功。実装・検証用2操作とも成功。UI診断だけを本線成功の代用にはしていない。
- main `35695660609` は同じSHAの候補証拠 `35694399109` を20秒で再利用、Macの重複実行なし。Native UI/SDKでの実装はこのSHAで本線化した。
- 同SHAのiPhone 17 Pro / iOS 26.2の描画3枚を確認。明示同意のpopover、接続済みかつ新規保管不可の表示、既存メモと書き出し/削除への入口に欠け・重なりなし。合成記録・合成sessionであり、実Apple/購入/本番サーバー/全画面サイズの検証ではない。
- 初回CI→main成功は46分18秒、最初の製品候補commit→main成功は48分15秒。実装開始以前からの総作業時間ではない。初期30分枠は超過、起動前の110分計画内。2つの検証コードの不備による再作業を含む。CI・診断・mainのrunner計100.666分は課金額やCodexトークン数ではない。
- 2回目preflightでは、確定した初回v2失敗16.8分を従来baselineに追加した外部計測ファイルを使用した。失敗を成功に変更せず、全必須job・稼働中・同SHAの診断成功ゲートは維持。確定値は今回のcloseoutで `ci-timing-baseline.json` へ記録する。
- 成功コードの後に別closeout branchで資料・時間計測だけを更新する。本体や診断対象は変更せず、資料更新のための再UI診断は行わない。初回失敗・診断を含む履歴は上記のまま残す。

今後は新しいfixtureを追加した時点で安価なprivacy source検査を先に行い、iOS標準popoverの取消を存在しないButton名で決め打ちしない。HEADに依存するローカル確認中にはcommitしない。繰り返し発生した検証指定の遅れを、追加の全件実行で埋め合わせない。

次は実環境のApple/KMS/JPEG private bridge・専用DB/R2、容量/保持/削除、会員情報を失った端末の復旧導線と実2台確認。実契約・サービス有効化・課金開始・公開・TestFlightは行っていない。
