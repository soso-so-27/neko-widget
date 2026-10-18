# 接続の自動更新と一時的な復旧確認待ち

- 利用者の最新回答は「先ほどアプリ内の本人確認ボタンが出たが、今は出ていない」。今回新たな16分後の失敗と確定しない。16:41 JSTの読み取りでは有効な端末grantが3件、失効0、最新の明示接続は16:34:07。本人・token・写真・メモ本文を出力していない。
- 独立した実D1/ES256の再現で、owner recovery acknowledgementが一時的に不足すると、正当な未消費proofのsession更新が401になった。nativeはこの401で保存していた端末credentialを消す。既存のSQL guardは正しくaccess発行を止めているが、エラー分類が不適切だった。実機で過去に出たボタンの唯一原因とは断定しない。
- batch不成功時だけ現在のproofを再検証する。有効な未消費proofなら503として接続情報を保持し、失効・消費・owner境界違反は既存の拒否を伝播する。外部削除receiptの409や読取障害503も維持する。recovery条件・Apple再確認頻度・token期限・grant期限・課金・本人・保存内容は変更しない。
- 初回候補は2026-10-18 16:46:32 JST。修正前の対象testは401/503不一致で失敗（6.54秒）、修正後のdevice-session integration全36件は13.41秒で成功。回復前のsession不増・grant不変・proof未消費、ack後の同proof再試行成功、並行敗者401、provider待機中のchallenge失効を含む。元の失敗を保持する。
- 高コスト検査前の計画: 変更はbackend2ファイル。直接証拠は上の再現。実Apple/実端末の16分後自動更新とv3復元は未確認。独立レビュー、選択制御のローカル検査/main先行反映、同候補SHAの通常Preservation全test/typecheck/migration/bundleとplan、main確認、既存archive Workerのcode-only更新を行う。既存backend job92秒、制御検査226秒は参考で新scopeの実測ではない。初回候補から45分を計画し、待機・失敗も含めて記録する。新しいMac検査・TestFlightはapp入力不変なので不要。
- 262のapp/Shared/UITest/projectは現在mainと差分0。独立レビューでは両OS runtime42件の901秒後renewal/並行single-flight/503 credential保持と、v3合成別端末の実UI復元2caseの成功を確認した。実Apple通信はfixtureなので実機成功に代用しない。同期済み1台ではv3同revisionを強制復元するUIはなく、元データ削除・再インストール・強制競合を要求しない。
- 月980円、追加契約0、既存受付/予算/secret/cron/公開範囲は維持。正常更新の通信量は変わらず、batch不成功時だけ有限のD1読取・署名照合を加える。新規定期・手動cron・受付延長・一般公開・課金開始は行わない。

証拠: `C:/dev/neko-evidence/automatic-test-20261018/session-renewal-recovery-*.log`。

## 独立レビューと制御検査

- journal_identity_reviewが製品2ファイルと新しい限定scopeを独立レビュー。SQL・認証境界・外部削除receipt・回復前の無発行を維持し、blocking findingなし。
- 制御の初回検査は2suite成功後、planner494case中1件が失敗。新testがpatch後registryから候補も生成して比較対象を同時に置換していた。元候補を保持する`self.select(original)`へ修正し、その1件は0.014秒で成功。変更しない制御本体と他493case/2suiteの成功を保持し、残り12suiteを122.2秒で成功確認した。失敗を削除せず、通常CIでは全15suiteを実行する。
- control候補5ea1fd2はpreflight ready、PR358。製品2blobは1d6bb09と同一のまま、control main承認後に取り込む。追加Mac起動・workflow変更なし。

## main統合・クラウド反映完了

- control push39109387777の必要3step成功後、PR358をmain556a144へ統合。最終製品b71b17fは限定scopeでpreflight ready。最初のpreflightはGitHubのactive一覧が不完全として停止し、5状態の実読取で件数整合を確認して再試行した。古いqueued5件を取消・再実行せず、条件も緩めていない。
- 通常push plan39109576858は56秒、Preservation39109576835は123秒で成功。全601 Vitest/70file、Node32件、typecheck、合成migration、private bundle2本の実成功を確認。PR359をmain27be086へ統合し、tree一致とmain plan39109754248/47秒、backend39109754233/122秒の必要step成功も確認した。PRのskipを成功として扱っていない。
- 固定bundle・multipart・既存設定をjournal_identity_reviewが独立レビュー。実配信コードとの差分はrenewal失敗batch後の再proofと503だけ。writer/plan hashと同SHA push CI・main祖先を実行直前に照合した。
- 17:03:02 JSTに既存archive Workerだけをversion `e1840824-a64c-48af-a5a1-a4ab1a9eafee`へ更新。実module SHA256 `7cd4ad196727470654682fa98a0c00f1b16c169c8a7378e21b7fc07198a6ce12`一致。version作成/activation各1POST、再送0。bindings/secret継承/runtime/cron/公開範囲は不変、migration/手動cron/app API呼出0。受付期限やcounterを変更していない。
- 17:03:27のD1 SELECTで最新head revision3の必要34部品が全てlive、旧31記録のrevision/サイズ不変、upload予約なしを確認。本文・写真・tokenを読み出していない。
- 初回候補16:46:32から反映まで16分30秒、反映後保全読取まで16分56秒。元の再現失敗、control fixture失敗、preflight環境停止、レビュー、CI、待機を含む。45分計画内。新規契約0、価格980円、app入力不変/TestFlight再配布0。失敗batchの追加処理はD1読取・署名照合に加え、既存の外部削除journalのR2読取2件も含む。正常更新・Apple/KMS頻度は不変で、従量処理が完全にゼロとは主張しない。
- 次は利用者へ、通常写真メモを編集・保存後に再確認を押さず保存済みになるかを依頼した。17:00の読取では最新access期限16:49を過ぎ、device grantは有効なので、次の編集で自動更新を確認できる。実機結果は未回答として保持する。長期容量と別端末v3復元は[残確認](2026-10-18-save-restore-remaining-checks.md)を参照。

## 実機の自動更新・変更到着を確認

- 利用者が上記の「再確認を押さず通常メモを編集」依頼に「保存済みになった」と回答。17:05のmetadata読取で、17:04:40.159に既存grantから新しい短期sessionが発行され、直前の署名challengeが消費されたことを確認。grant新規登録数3件と最新作成16:34:07、identity credential/check時刻は不変なので、新しいApple明示ログインによる更新ではない。前accessは16:49:07に期限切れ、明示ログインから約30分32秒後の自動更新である。
- 17:05:41のpublication読取でhead revisionが3→4となり、今回のメモ変更が到着。必要34部品すべてlive、旧31記録のrevision/サイズ不変、予約なし。17:06:23には旧index/JSONの自動整理も完了し、未参照live部品0、全record/owner acknowledgement確認、repair失敗0。owner generation156、使用量43,756,122bytes、予約0。受付期限と上限は不変で、変更に伴う通常counter増加だけを観測した。
- 期限後の既存接続自動更新→通常メモ送信→端末保存済み→不要部品の整理は実機とサーバーの両方で確認済み。初回候補16:46:32から最後の保全観測17:06:23まで19分51秒。新v3の別端末実復元・長期容量設計は未完了のまま。
- 証拠: `device-session-state-20261018T080508Z.json`、`session-renewal-device-publication.log`、`session-renewal-device-cleanup.log`（private/summary JSONは各読取時刻）。本文の復号・手動定期・app API実行は0。
