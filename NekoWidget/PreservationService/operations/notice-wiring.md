# 保管終了予告の接続準備

期限は解約ボタンを押した日ではなく、Appleで会員期限切れを確認した日から12暦月。
active/graceへの再契約を確認すると期限とその期間の通知状態を解除する。
会員照合unknownでは期限進行を止め、復旧した時点で確認不能だった期間を延長する。
期限60日前から最終予告の対象。宛先メールサーバーでの送達確認後も30日以上を確保する。
providerの送信受付やメール開封と、送達確認を同じ意味にしない。

`notice-wiring.template.json` は配備用差分の雛形で、placeholderを残して配備しない。
stagingの既存D1/R2/KMS/S3/JPEG/会員bindingを落とさずに設定を追加する。
現時点では送信domain・Zone ID・イベントsubscription IDが未確定。Cloudflare Email Serviceへの
domain登録とSPF/DKIM/DMARC等のDNS確認が必要。通知先はAppleで検証済みの現在の連絡先だけ。
個人用accountであることを照合し、送信者をbindingのallowlistでも制限する。

Cloudflare公式の現行Workers APIはsend({to,from,subject,text})からmessageIdを返す。
既存NoticeMailProviderと一致するので、新しいadapterや公共webhookを増やさない。
当該domainだけのdelivered subscriptionを非公開Queueへ結び、account/zone/domain/subscription/
sender/recipient/messageIdを既存の耐久submissionと照合する。配信遅延・欠落は送達扱いにしない。
Queueのdead-letterも用意し、認証や照合エラーを捨てて成功にしない。

最初の接続ではNOのまま設定を読戻し、Queueのsynthetic delivery fixtureが本物の削除許可を
作らないことを確認する。実メールの送信は、送信先・件数・内容を示して許可を得た1件のみ。
メールに猫の名前・写真・メモ・ログインtoken・決済情報を載せない。
送達の実接続、再契約の実Apple照合、削除の保全条件が揃うまで自動削除は開始しない。

公式参照：
- https://developers.cloudflare.com/email-service/get-started/send-emails/
- https://developers.cloudflare.com/email-service/configuration/send-bindings/
- https://developers.cloudflare.com/email-service/platform/event-subscriptions/
