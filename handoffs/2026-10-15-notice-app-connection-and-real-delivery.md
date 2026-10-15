# 通知のサーバー接続と実メール到達（2026-10-15）

**アプリが使う保管サーバーへ `notice@nekonomado.com` を接続し、試験メール1通の実配達と本人の受信トレイ到着を確認した。980円維持、新しい月額契約・購入なし。一般利用者への自動通知はまだ開始していない。** [ドメイン購入と接続準備](2026-10-15-notice-domain-connection.md)の後続。

## 完了した接続

- 稼働中の `neko-preservation-staging-disabled` に `NOTICE_EMAIL` bindingを追加。送信元は `notice@nekonomado.com` だけに制限し、account/zone/subscription/domain/sender/queueの6設定と、32byte乱数由来の `NOTICE_RECIPIENT_TAG_SECRET` を追加した。秘密値はクラウドへ直接渡し、資料・ログ・ディスクへ保存していない。
- Cloudflare account `829a34ef925a39d81b0e9e08800d7c7f`、zone `3561d4111d62ccb1f0e099f81810879c`、購読 `251f113543524fd1a9f81355ad182b06`、Queue `neko-retention-notice-events-nekonomado-v1` に固定。新しい失敗隔離先 `neko-retention-notice-dlq-nekonomado-v1` を作成した。旧ドメイン用Queue2件・旧購読は不変。
- 本体はsettingsだけを1回PATCHした。新しい稼働versionは **`d0adaee7-9e82-45e6-85fe-26d33354e6f4`**、100%単一配備。稼働version詳細のbindingも照合した。実行コードSHA256 **`2d9c74385a8783f38aee79d27a8397eed05d3bee5917b6e2c7216019ed918a9b`** は前後同一。既存DB/R2/S3/key/secret参照・保存受付・試用枠・期限・公開範囲を保持した。
- `RETENTION_TRACKING_ENABLED / NOTICE_SEND_ENABLED / NOTICE_EVENTS_ENABLED / CLEANUP_ENABLED` はすべて **NO** のまま。通知試験のためにcleanupをONにしていない。billingも変更していない。iOS入力やAPI接続先の変更がなく、新しいTestFlightは作成せず、既存256を維持した。

## 実メールの結果

利用者が「前回と同じ個人用Gmail」を選択。個人の宛先は公開資料へ転載しない。送信元・宛先を各1件に制限した試験専用binding、認証付き制御、30分の窓、永続的な最大1送信の制限を使った。実会員の期限を変えず、専用DBの合成ownerと、製品と同じ `NoticeDispatch / NoticeSubmissions / RetentionLedger / processDeliveredNoticeEvent` を使用した。

- **実送信1通**。件名に「テスト通知・実際の保管期限ではありません」を付け、本文にも試験であることを明記。実際の契約・保管期限が変わる通知ではない。写真・猫名・認証情報・持ち出しリンクを含めていない。
- 2026-10-15 **16:56:31.366 JST** の実 `message.delivered` を専用のprivate Queueから受信。providerのmessageId、eventId、account/zone/subscription/domain/sender、選択した宛先、合成ownerの送信記録を照合し、製品処理で **receipt evidence v2** へ進んだ。配達後30日以上の猶予も合成台帳で確認した。API受付だけを配達済みにはしていない。
- 利用者が **「受信トレイに届いた」** と回答。メールサーバーでの受付と、人が確認した受信トレイへの到着を区別して記録した。
- 終了後は試験を無効化し、実eventと送信台帳のprivate証拠を保全してから、今回の試験consumer・Worker・専用DBだけを撤去した。既存利用者のデータ変更・削除0。本体の31記録/22,378,689 quota bytes、owner1、contact1、retention0、submission0、migration inventoryは前後一致。

## 検証と途中停止の扱い

- 送信先/権限変更として独立レビューを行った。新しい閉じたfixtureで、全既存bindingのinheritと新設定/secret追加のPATCHを先に実測し、稼働version resourceと実行etagが一致することを確認してから本体へ適用した。
- 試験harnessのローカル境界10項目が成功。認証、activation/送信の1回制限、受付だけで配達にしない条件、異なるsource/非delivered拒否、receipt v2、30日猶予、削除禁止、無効化を確認した。連絡先変更/再加入の製品検査は、入力・依存が同一の既存成功を維持した。
- 最初の標準HTTP clientのhealth確認は403。識別用User-Agentで同じ閉fixtureを読取り確認し、製品やセキュリティ設定は変えず再配備もしなかった。その後、Queue APIの実応答が `script_name` でなく `script` だったため、**activation/dispatch前**の検査で停止。DBのowners/runs/submissionsが各0、送信要求未発行を確認し、応答fieldだけを修正して独立再レビューした。失敗を成功扱いにせず保存し、メールの再送はしていない。
- 最初の候補 **16:42:33.755 JST** から実配達照合・試験環境撤去 **16:56:45.690 JST** まで **14.2分**。準備見込15分＋配達観察上限8分を先に記録した。資料反映の時間はこの試験終了時刻に含めない。
- 製品/CI/依存の入力は `332f1545` の15ローカルsuite成功（432.8秒）から不変。NekoWidget/.githubの全tree、AGENTS、配布手順のGit entry一致で保存し、資料だけのための再検査・native CI・配布は追加しない。今回の差分/リンク/preflightは別に確認する。
- private証拠・実送信済みの再実行禁止helperは `C:/dev/neko-evidence/notice-app-connection-20261015/`。`verified-result.json` はサーバー側最終読取り、`inbox-confirmation.json` が後続の本人到達報告。`mail-once-execution-private.json` は未送信で停止した最初の記録、`mail-once-execution-identified-consumer-private.json` が実1通の結果。いずれも再実行しない。

## 残る運用条件と費用

1. 本体は一般通知の送受信gateを閉じているため、Queue consumerを本体へ付けたままretryを消費させない。試験後はconsumer **0**。将来の運用開始時に、現在の本人連絡先・会員終了日の根拠、配達照合/再試行/失敗隔離を実会員の経路へ接続する。今回の合成ownerの成功をApple連絡先由来や実会員終了の証明にはしない。Queueは4日、DLQは14日の有限保持であり、恒久保管ではない。
2. 自動通知の起動と、安全な保管整理の接続は未開始。現scheduledの通知処理はcleanupの後段なので、cleanupだけを勢いでONにしない。既存の保持条件・参照/復旧安全性・一般枠・停止条件・保持原資を満たしてから運用候補を確定する。今回cron/定期タスクの追加・変更・手動再実行0、既存本人退会削除cronは完全不変。
3. 今回は既存Workers Paid/Email Sending/Queuesの契約枠を利用し、新しい月額契約や購入はない。[Email Sendingの既存共通枠](https://developers.cloudflare.com/email-service/platform/pricing/)は月3,000通、[Queues](https://developers.cloudflare.com/queues/platform/pricing/)は月100万operations。将来の全原価の無料保証ではない。承認済みドメイン年額は前回資料のまま。AWS Paidへの変更・一般公開・課金開始・利用者への一斉送信・試用枠の追加/延長は行っていない。追加費用や新契約が必要な段階では、金額と用途を先に利用者へ伝える。
