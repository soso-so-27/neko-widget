# 保管容量・費用と本人削除の照合

2026-10-01の利用者依頼「済んでいる部分も確認して進める」に対応。保存・読み直し・同じApple本人の再確認後の復元・写真とメモのZIPは既確認として保持し、再試験や新TestFlightを追加しない。

## 完了・実配備との区別

- 現行内部pilotの実設定を **20:51 JST（11:51 UTC）** にAPI/DB読取で確認。本人1人、1GiB/200件、全体3GiB。新保存50回/日・300回/月・3GiB/月、PUT100回/日・500回/月。既存費用確認は10月1日21:45 JSTまで、pilotは10月8日09:44:57 JSTまで。期限を延長していない。
- 実Worker version `7ec5e448-1aa0-49ce-ba82-2f96241c18c9`、migration28まで、一般modeなし、cleanup/通知/期限削除OFF。保管1件・利用中3,358,122 bytes、R2削除待ち0、未照合S3書込lease2。利用者のコピーを変更・削除していない。
- PR150/main `9a97bba` で一般受付の費用停止を補完。一般の登録・PUT事前判定・容量予約へ、確認済み予測が明示された停止額未満というatomic条件を追加。未設定・等値以上・確認期限切れで停止。pilotは従来の費用判定を保持。
- migration29/30を21:14 JSTに準備適用。一般人数/保存回数の上限は0、予測はNULL、停止額は0のまま。全既存pilot値・カウンタ・費用確認期限と実Worker versionが前後一致。一般受付はOFF。Worker再配備、一般提供数値の約束、課金開始は行っていない。
- 費用判定は受付制限であり、クラウド請求の強制上限ではない。旧S3版本、読取、固定費等を含む最新の実費予測は未採取。内部pilotの数値を一般販売の容量・無制限の約束へ転用しない。

証拠は `C:/dev/neko-evidence/preservation-launch-minimum-20261001/` の `preservation-controls-readonly.json`、`general-schema-applied.json`、`cost-candidate-plan.json`、`cost-preflight.json`。固定候補 `8f2e9b77421eb97065ee78d1566bd03e38db301b`、Node run36860163614（job64秒/run69秒）、plan36860163540（run24秒）成功。native・Widget描画・TestFlightは対象外。

## 本人削除は未完

既存record DELETEはD1論理削除とS3削除intent/tombstone。cleanupはOFFで、全R2/S3世代と本人登録を消去した証明ではない。session解除もaccount削除ではない。独立調査でも公開account削除routeは見つかっていない。

期限purgeのfence・SQL削除authority・外部intentは、会員失効・期限episode/revision・通知証拠を要求する。本人削除のために期限判定を外したり、偽の期限episodeを作らない。12か月後の自動処理は引き続き後続。

本人削除の完成条件:

1. 同じApple本人の明示要求をアプリから受け付け、expiryとは別型の外部耐久request/receiptへ保存する。client指定ownerや有料会員の判定を削除authorityにしない。
2. 対象はサービス保管の本人登録・コピー。端末原写真/メモ、以前のiCloudコピー、まどの相手のデータを混ぜない。Apple認証失効が同じclientを使う他の登録へ及ぶ範囲を結線前に確かめる。Apple会員の自動解約とは区別する。
3. epoch/inventory fence、全R2と全S3版本のstable manifest/hash、外部prepared→erasing→completed記録、削除後の再一覧、D1残存0の確認を再利用する。期限専用authorityは変更しない。
4. 既存writerはGet/Putのみを維持。別のprivate executorへ最小限のDeleteObjectVersion権限を与える。実本人の削除で試験せず、限定された合成ownerだけで全版本・隣のowner非削除・中断再開・復元拒否を確認する。
5. credentialの消去前にApple refresh tokenの失効を確認。失敗時は暗号化credentialを保持し、完了と表示しない。新 `apple-revocation.ts` は既定OFF・未接続のローカル部品で、最初のtypecheckと合成3件を確認。独立レビューで非200時のstream cancelが待ち続ける問題を1件発見し、best-effortの非同期cleanupへ修正した。修正後のtypecheckと追加1件は成功（3.84秒）。他の3件は今回選択対象外で、最初の成功証拠を保持した。当該deltaの独立レビューにも追加の阻害事項なし。実tokenは送信していない。
6. 未照合lease2を含む実S3 inventory/権限を確認し、D1や古いowner snapshotから要求を復活・消失させないreplayを実装する。全account削除・復旧保証はまだ完成としない。

## 現在の接続待ち

AWS profile `neko-preservation-test` は東京regionを明示したSTS読取でsession expired。個人Codexブラウザへ新しい `aws login --remote` の通常root sign-inを表示し、利用者へログインを依頼済み。会社Chromeは使わない。認証コード/秘密鍵を利用者にチャット送信させない。AWS bucket/versioning/全版本使用量と削除roleの実確認が未完。古いリンクの再使用や秘密鍵の再作成は行わない。

今回の開始20:41:44 JST、費用コード初回20:55:44 JST、CI完了21:13:01 JST、schema準備完了21:14:10 JST。費用コードからCIは17分17秒、調査開始からschema準備まで32分26秒。Windowsの開発制御チェック321.6秒と、全4companion要求を見落とした最初のローカルpreflight STOPを含む。広いCIは起動せず、既成功チェックを保持してコメント1行/digest修正だけで経路を直した。保管完成全体の初回18:29:38 JSTからの累計をリセットしない。AWS接続・本人削除の作業時間も別に追記する。

21:35 JST時点までの今回の経過は約54分（ログイン待ちと削除設計・独立レビュー・修正を含む）、18:29:38 JSTからの保管完成作業の累計は約185分。本人削除はこの時点でも未完成であり、CI64秒だけを総工数としない。本人削除の部品とこの追記はローカル候補で、費用判定のPR150とは別に保持する。追加CI・配布は開始していない。
