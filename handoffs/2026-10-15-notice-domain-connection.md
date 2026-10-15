# nekonomado.com購入と通知の接続準備（2026-10-15）

**利用者承認で `nekonomado.com` を購入済み。メール送信元のDNS認証と、新ドメイン専用の配達結果の受け口まで実設定した。アプリの通知送信は未接続。980円維持。** [AWS実測・旧ドメイン候補](2026-10-15-aws-cost-reconciliation.md)の後続。旧 `neko-no-mado.com` は購入していない。

## 購入と用途

- 利用者はハイフンなし `nekonomado.com` と提示年額での購入を指定し、最終画面でCloudflareの規約と毎年の自動更新へ明示同意した。登録者情報は利用者が修正・確認し、残った全角数字/ハイフンだけNFKCで半角化した。個人の住所・連絡先・カード情報を本資料に転載しない。
- 最終checkoutのDue todayは**10.46米ドル、1年**。購入確定は1回だけ。画面がcheckoutに残ったため再押下せず登録一覧を確認し、**Active・期限2027-10-15・自動更新ON**を確認した。請求書の明細/税/決済円額はまだ照合していない。
- [公式の11/1料金改定](https://pricing.registrar.cloudflare.com/price-changes)で.comの登録/更新は11.17米ドルへ変更。初年度約1,660円・値上げ後更新年約1,770円は前回と同じ158.345円/米ドルの参考、税・カード換算別。1人ごとでなくアプリ全体の年額。自動更新は期限の最大30日前に行われることも利用者へ説明・承認済み。
- 主な用途は保管期限のお知らせの差出人。`notice@nekonomado.com` を接続候補にする。同じdomainを後でLPにも共用できるが、今回はWebの向け先や公開LPを変更していない。メールアドレスの受信箱や転送を作成したという意味でもない。

## 実設定と直接確認

| 対象 | 今回の結果 |
| --- | --- |
| 登録domain | `nekonomado.com` Active、自動更新ON、2027-10-15まで |
| Cloudflare zone | `3561d4111d62ccb1f0e099f81810879c` |
| Email Sending domain | `b5f06b6e376b4eaeb5795eb7ed018eea`、Enabled / DNS Configured |
| DNS | `cf-bounce`のMX3件・SPF TXT・DKIM TXTと`_dmarc` TXTを設定。新domainだけが対象、競合削除0 |
| 公開DNS | NS・MX・SPF・DKIM・DMARCの5照会が成功。MX3宛先、SPF/DKIMの内容、DMARC `p=reject`を確認 |
| 新domain専用Queue | `neko-retention-notice-events-nekonomado-v1` / `76ffce01882a4bf3b5f74cacc8802c1b`、consumer 0 |
| 配達結果のevent subscription | `neko-retention-delivered-nekonomado-v1` / `251f113543524fd1a9f81355ad182b06`、Enabled |
| イベント範囲 | source `email.sending`、上記zone、`nekonomado.com`、**`message.delivered`だけ**、destinationは新Queue |

[公式のDNS設定手順](https://developers.cloudflare.com/email-service/get-started/send-emails/)に従い、Cloudflareの生成した6レコードを確認してActivate。秘密DKIM鍵やSMTP/API keyの発行・持ち出しはしていない。公開DKIM値は公開DNS情報であり、秘密鍵ではない。

既存Queue `neko-retention-notice-events-v1` とDLQは当初再利用候補だったが、既存購読が別domain `neko-notify.trade-solo.com` の6種類のeventに紐付いていた。現consumerは設定source以外や非deliveredをretryするため、混ぜずに新domain専用Queue1件とdeliveredだけの購読1件を作った。旧2Queue・旧購読のsource/events/enabled/IDは完全不変をGET再読取で確認し、削除・無効化・purgeをしていない。新Queueのconsumerは未接続、失敗隔離先は接続前に専用の候補を確定する。

[Queuesの既存Paid共通枠](https://developers.cloudflare.com/queues/platform/pricing/)は月100万operations、超過100万あたり0.40米ドル。[Email Sending](https://developers.cloudflare.com/email-service/platform/pricing/)は月3,000通の共通枠、超過1,000通0.35米ドル。どちらも既存契約の範囲で、別の月額契約・plan変更は追加していない。準備後の実メール送信は0、通常利用の全原価や将来の無料保証ではない。

## アプリへ接続する具体的な残件

1. 現metadataを保った設定候補に、`NOTICE_EMAIL`のsend binding（`allowed_sender_addresses: ["notice@nekonomado.com"]`）、上記account/zone/subscription/domain/sender/queueを結ぶ。`NOTICE_RECIPIENT_TAG_SECRET`参照はまだないため、安全な保管・参照を準備する。別送信元や別Queueへ広げず、既存DB/R2/S3/key/本人grantは保持する。
2. sourceのaccount/zone/subscription/domain/sender、provider messageId、現在の本人の連絡先・会員終了episodeを照合する既存処理へ接続する。provider受付やDNS Configuredを実配達済みにしない。新senderからの実配達と、拒否/古い連絡先/再加入の停止確認は未実施。
3. tracking/send/events/cleanupの現gateはすべてNO。現scheduledではcleanup後に通知処理があるため、通知を試すためだけにcleanupをONにしない。対象・一般会員終了日の根拠・安全なGC・失敗隔離/再試行を確認してから接続する。一般保管の整理はreviewed-manualの条件を維持。
4. 一般容量/保存受付枠・停止条件・保持原資・AWS有料継続・公開原稿適用は別の残件。今回のdomainと規約の承認を、AWS Paid、一般公開、課金開始、利用者宛メール送信、削除、cron/定期タスクの新設・再実行へ拡張しない。

今回の依頼で完了したのは購入・送信元認証・配達結果の接続準備。通知の一般運用を開始したとは扱わない。

## 検証と保全

- クラウド前後のarchive Worker settings/schedules/deploymentsは全文一致。配信/保持/cleanupのgate、mail/consumer binding、secret参照、既存本人・写真・メモ・試用grant・期限は変更していない。新規メール送信/利用者本文読取/利用者データwrite・delete/cron・定期タスク変更や手動実行は0。
- アプリ/Worker/CI/依存の製品入力はmain `8b712086`から不変。既存256のuploadと製品検査を保持する。前回の15ローカルsuite成功（432.8秒）の入力・依存閉包を比較し、資料だけの今回に再実行を追加しない。今回の資料差分・リンク・preflightを別に確認する。
- private証拠と非配備の接続planは `C:/dev/neko-evidence/notice-domain-connection-20261015/`。`preparation-verified.json`が設定後の観測、`connection-plan*.json`は各準備時点の履歴。旧planの再利用候補/購入未完/remote write 0を現状へ読み替えず、後続証拠を優先する。登録者情報を含むprivate screenshotは公開しない。
- `registration-active.jpg`は対象domain行だけ、`email-sending-configured.jpg`と`delivery-subscription-configured.jpg`は設定の画面証拠。JSONのsourceとdestinationを再読取し、旧購読不変を照合した。API購読作成は1回で、未知結果の盲目的再送はしない。
