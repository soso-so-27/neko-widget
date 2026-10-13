# 保管の公開判定に必要な運用証拠

公開条件の準備を続け、`reviewPublicPreservationOffer` が資金の記録だけで公開準備完了と判定する抜けを修正した。本人が254の返答入口と既存記録ZIPの保存・展開を確認済み。PCでの5GB ZIP検証も成功済みだが、iPhoneで5GBを作成した証拠とは区別する。

## 集約証拠の追加契約

- `budgetApproval` は `status: approved` と承認の `evidenceReference` を持ち、`monthlyTargetYen`、`warningForecastYen`、`pauseNewIntakeForecastYen` が計画と一致する。警告 < 新規受付停止 < 月額予算を要求する。旧3000円は試算であり、一般提供の承認とは扱わない。新規受付停止点は計画から参照する。
- `configuration.deploymentId` と、通知の `noticeAccountId` / `noticeZoneId` / `noticeSubscriptionId` / `noticeDomain` / `noticeSender` / `noticeQueue` を明記する。
- `retentionOperations` は `version: 1`、24時間以内の `confirmedAt`、同じ `deploymentId` と `recoveryAwsAccountId` を持つ。実配備の観測と証拠を参照する。テストfixtureの値で代用しない。
- `tracking` は実際に有効な保持追跡、検証済みの会員状態の取得元、予定実行を証拠付きで確認する。
- `notices` は送信・イベント処理・providerの準備、非公開queue、同じ通知scopeを確認する。配達証拠v2と申込・現在の連絡先・会員状態を照合した成功、送信受理だけでは配達と扱わない検査、連絡先変更・再加入の拒否証拠を要求する。
- `cleanup` は `mode: reviewed-manual` とし、物理在庫・全履歴・復旧コピー・維持費用、孤立コピーの清掃準備、期限終了利用者の別purge手順、独立承認、不明状態・未配達・再加入による削除停止を証拠付きで確認する。`CLEANUP` の有効化だけを期限終了利用者のpurge完了と扱わない。

これはローカルの証拠集約チェックであり、証拠そのものの署名検証や権限発行ではない。送信・削除・配備・一般公開の許可は常にfalse。実メール送信、利用者データ削除、cloud設定変更、料金・一般公開は実施していない。

## 直接確認と残件

関連Node検査32件成功。欠落、期限切れ、別配備・別AWS、無効な追跡、受理のみ、別通知scope、連絡先/再加入条件、未承認予算を拒否する。従来pilotの読取レビューと大容量書出し・本人の境界は保持する。

現行の実設定は追跡・通知・清掃OFF。提供用の設定と実運用証拠は未完了。AWS FREE/ACTIVEの期限2027-03-25から先の資金確保、一般受付の実構成、通知の実配達確認、整理手順と一般提供に一致する表示・審査資料が残る。費用の部分小計を完全な予測や請求上限とは呼ばない。

費用と既存検証の正本は `C:/dev/neko-evidence/recurring-cost-20261013/` および `C:/dev/neko-evidence/remaining-readiness-20261013/`。本線反映は候補の必要検証と独立レビューに従う。
