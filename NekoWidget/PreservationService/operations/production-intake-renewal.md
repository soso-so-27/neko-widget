# 本番保存受付の自動更新（OFFで準備）

このWorkerは非公開・cronなし・INTAKE_RENEWAL_ENABLED=NO。0050は制御行を1件追加するだけで、既存受付・上限・カウンターを変更しない。AWS/Cloudflareの資格が未設定なら費用は取得できず、更新もしない。

## 本番有効化前に必要なこと

- 専用AWS IAM主体にproduction-cost-reader-policy.jsonだけを付ける。Cost Explorerはresource指定に対応しないためResourceは`*`だが、ActionはGetCostAndUsageのみ。console、S3、KMS、D1の管理権限を付けない。Workerへroot/CLI資格をコピーしない。
- 対象Cloudflare accountだけの請求読取資格を用意し、billable-usageの実応答でBillingAccountId/通貨/周期/欠落を確かめる。現在のWrangler OAuthは403。ブラウザーへログイン済みであることとAPIの請求読取権限は別。
- COST_AWS_ACCESS_KEY_ID / COST_AWS_SECRET_ACCESS_KEY / COST_CLOUDFLARE_TOKENはsecretで投入。providerの実応答、請求周期の最初の1日、初回30日履歴不足、未知のサービス/訂正/empty時の閉鎖を確認する。現時点の実provider試験は未完了。
- 初期枠は100人、登録10/日、新規保存試行200/日・6200/月・3.1GB/月、mutation600/日・18600/月・6.2GB/月を提案。100人×1日1写真＋1メモ、1操作最大3 PUT、平均写真1MBの仮定。初回1GB×100人の一括投入枠ではない。実際の内部呼出/平均bytesを測り直し、上限拡大が必要なら別判断。既存の0枠はこの準備で変更しない。
- 1102cの警戒5000円・停止10000円・保全3000円を保持。forecastはmax(100人モデルの5610円、AWS/Cloudflare全accountの31日換算＋Workers/Apple/domain/CEの費用)に保全3000円を加える。通貨は見積りの160円/USD、実測系には税係数1.1。初期モデルなら8610円で警戒になる。保全費用は請求上限の保証ではなく、月額予測の外へ除外しないための枠。
- 成功してもDBの既存上限がコードの固定値と一致し、更新許可の期限内でなければ開かない。公開の保存/課金gateは別承認。試験のためにYESへ変えない。
- 許可の期限は運営判断で明示する（無期限なし）。有効期限は8時間、取得は6時間ごと。cron `0 */6 * * *` の有効化と月額増加は別承認。作成時のcronは空。

## 取得回数と費用

1つの6時間枠に1つだけD1のclaimを取り、AWS最大2ページ、Cloudflare1回。SDKの自動再試行は使わない。AWS 3ページ目が必要なら追加取得せず閉じる。30日最大240 request=$2.40、31日248 request=$2.48。AWSが1ページなら半額。更新失敗も枠を消費し、同じ枠の再実行で費用を重ねない。

Cost Explorerは少なくとも24時間ごとの更新で、リアルタイムの請求上限にはならない。全account利用を含めるため他用途の費用によって早く閉じることもある。無料枠やcreditを推定控除しない。Cloudflare usage APIは従量のみなので、固定契約を別加算する。データが48時間より古い、欠落・HTTP失敗・通貨/account違い、将来時刻、二重明細は閉鎖側とする。本番APIの形は資格を接続後に実観測が必要。

## 停止と競合

管理者停止は、同一D1 batchでpa_intake_renewal.enabled=0・generationを増分し、pa_intake_control.enabled=0・valid_until=reviewed_atにする。新しいWorker/受付のglobal gateを閉じる操作も独立して可能。古いclaimはgenerationの比較で再開できない。

受付更新は既存受付をいったん閉じてから費用を取得する。失敗なら閉じたまま。成功時も全受付列のCASを行い、上限・期限・カウンターの並行変更があれば上書きしない。カウンターをリセットせず、月日の区切りは既存IntakeControlが判断する。既存のログイン・読み出し・書き出し・本人データは更新処理の対象外。

## 6段目へ

警戒/閉鎖結果を運営の通知・メール・ログへ接続し、担当不在時の扱いを整える。現在のWorkerはlast_result/checked_at/forecast_yen/warningだけを保存し、メールを送らない。本人や写真の識別子を費用記録へ入れない。

Sources: https://aws.amazon.com/aws-cost-management/aws-cost-explorer/pricing/ ; https://aws.amazon.com/aws-cost-management/aws-cost-explorer/ ; https://developers.cloudflare.com/api/resources/billing/subresources/usage/methods/paygo/
## Stage 6 operator notification boundary (1102zq)

Warning uses measured AWS/Cloudflare 31-day usage plus fixed costs and the bounded cost-API allocation. It excludes the model floor and preservation reserve. Stop forecasting still includes both. The notification sender reuses the report mail binding and fixed templates; recipients and sender addresses must be Worker secrets, with the private binding restricted to the approved mailbox/sender. No separate provider API key is needed for the native binding.

Migration 0051 adds only notification state. A state transition emits a fixed structured log and, when mail is explicitly enabled, a fixed message. Concurrent claims suppress duplicates. Failed or uncertain delivery retries no sooner than six hours; provider acknowledgement is not proof of inbox delivery. Logs never contain provider diagnostics, mailbox, photo, report identifier or credentials. Rejected credentials (401/403) are distinct from unavailable cost evidence. Expired authorization can be observed without collecting costs. An in-progress collection is not a closure alert.

The production renewal gate, mail gate and cron remain OFF. The scheduled path observes status after a permitted renewal invocation; it is not an independent watchdog while cron is OFF, and cannot report a scheduler/platform outage by itself. Enabling production gates/cron and registering the production operator are separate owner steps. Do not copy staging operator keys or registered credentials. A production read/decision test requires the production origin, Access audience and per-action WebAuthn verification.
