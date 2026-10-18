# 接続の自動更新と一時的な復旧確認待ち

- 利用者の最新回答は「先ほどアプリ内の本人確認ボタンが出たが、今は出ていない」。今回新たな16分後の失敗と確定しない。16:41 JSTの読み取りでは有効な端末grantが3件、失効0、最新の明示接続は16:34:07。本人・token・写真・メモ本文を出力していない。
- 独立した実D1/ES256の再現で、owner recovery acknowledgementが一時的に不足すると、正当な未消費proofのsession更新が401になった。nativeはこの401で保存していた端末credentialを消す。既存のSQL guardは正しくaccess発行を止めているが、エラー分類が不適切だった。実機で過去に出たボタンの唯一原因とは断定しない。
- batch不成功時だけ現在のproofを再検証する。有効な未消費proofなら503として接続情報を保持し、失効・消費・owner境界違反は既存の拒否を伝播する。外部削除receiptの409や読取障害503も維持する。recovery条件・Apple再確認頻度・token期限・grant期限・課金・本人・保存内容は変更しない。
- 初回候補は2026-10-18 16:46:32 JST。修正前の対象testは401/503不一致で失敗（6.54秒）、修正後のdevice-session integration全36件は13.41秒で成功。回復前のsession不増・grant不変・proof未消費、ack後の同proof再試行成功、並行敗者401、provider待機中のchallenge失効を含む。元の失敗を保持する。
- 高コスト検査前の計画: 変更はbackend2ファイル。直接証拠は上の再現。実Apple/実端末の16分後自動更新とv3復元は未確認。独立レビュー、選択制御のローカル検査/main先行反映、同候補SHAの通常Preservation全test/typecheck/migration/bundleとplan、main確認、既存archive Workerのcode-only更新を行う。既存backend job92秒、制御検査226秒は参考で新scopeの実測ではない。初回候補から45分を計画し、待機・失敗も含めて記録する。新しいMac検査・TestFlightはapp入力不変なので不要。
- 262のapp/Shared/UITest/projectは現在mainと差分0。独立レビューでは両OS runtime42件の901秒後renewal/並行single-flight/503 credential保持と、v3合成別端末の実UI復元2caseの成功を確認した。実Apple通信はfixtureなので実機成功に代用しない。同期済み1台ではv3同revisionを強制復元するUIはなく、元データ削除・再インストール・強制競合を要求しない。
- 月980円、追加契約0、既存受付/予算/secret/cron/公開範囲は維持。正常更新の通信量は変わらず、batch不成功時だけ有限のD1読取・署名照合を加える。新規定期・手動cron・受付延長・一般公開・課金開始は行わない。

証拠: `C:/dev/neko-evidence/automatic-test-20261018/session-renewal-recovery-*.log`。
