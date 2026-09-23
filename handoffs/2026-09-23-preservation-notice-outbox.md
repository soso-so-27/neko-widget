# 個人保管：削除予告の送達台帳（実送信前の設計）

## 2026-09-24 本線反映

既定OFFの通知候補巡回・送信claim・送達イベント照合・昇格を `d82f49572936a9855d8e14c1fed20ba0fc456546` でmainへ反映。候補iOS [35879970178](https://github.com/soso-so-27/neko-widget/actions/runs/35879970178) は必須8 jobが全て成功（全体4145秒、Mac runner 193.8分）。候補の保管サービス [35879970188](https://github.com/soso-so-27/neko-widget/actions/runs/35879970188) も成功。本線iOS [35888602069](https://github.com/soso-so-27/neko-widget/actions/runs/35888602069) は候補の同一SHA証拠を再利用し、本線保管サービス [35888601773](https://github.com/soso-so-27/neko-widget/actions/runs/35888601773) も成功。実送信、実R2/KMS、期限消去、TestFlightは行っていない。

## この段階の目的

会員期限切れから12か月の持ち出し期間を守り、削除予告が宛先メールサーバーに受理された証拠と少なくとも30日の猶予がない限り、最終消去を許可しない。Cloudflare Email Sendingの `send()` が返す `messageId` は送信受付であり、送達証拠ではない。送達には送信ドメインに紐付く `cf.email.sending.message.delivered` イベントを使う。開封の証拠とは呼ばない。

この設計・模擬試験は、送信ドメイン、Email Sending、Queue、Apple Private Email Relay、実R2/KMSを有効化した証拠ではない。全て揃うまで通知と期限消去は既定OFF。

`pa_notice_submissions` と `NoticeSubmissions` は送信受付IDとQueueイベントの照合材料を保持する。`recordDelivery` 自体は保持台帳を変えない。別の `promoteDelivered` は新鮮な非公開課金照会、現在の連絡先、同じ期限切れエピソードを再検証してから、送達証拠を保持台帳へ反映する。Workerの予定処理・非公開Queue入口はコードで接続したが、`NOTICE_SEND_ENABLED` と `NOTICE_EVENTS_ENABLED` は既定OFFで、送信binding・Queue consumer・送信ドメインは設定していない。実配達・最終消去を有効化したという意味ではない。

`0008_notice_claims.sql` の単一owner送信claimで並行実行を抑え、送信とDB保存の間に成功不明が残っても送達扱いしない。送達イベント時はownerの非公開課金状態を新たに取得してから照合する。送信候補と送達済み未昇格候補は永続カーソルで巡回し、古い連絡先不明の行で後続が止まらないようにする。各行の失敗は次の行を妨げず、予定処理全体では失敗を明示する。これらはローカル模擬検証であり、実際の送信・実Queue受信・本番配備の証拠ではない。

## 送達の照合

1. 課金権利の新しい検証結果を保持台帳へ反映し、期限切れ・時計停止なし・本人有効・通知未配達・期限まで60日以内の候補だけを選ぶ。取得失敗は `unknown` として停止する。
2. Apple署名済み本人情報から保存した、現在の暗号化連絡先だけを復号して送る。連絡先なし・復号失敗・別owner・アカウント無効なら送らない。宛先の平文を台帳やログへ残さない。
3. 送信受付時は `messageId`、owner、期限切れエピソード、送信時刻、宛先の鍵付き照合値、送信元、Cloudflareのaccount/zone/domain/subscriptionを記録する。書込不明・失敗では「配達済み」にしない。
4. Queue経由のイベントで、種別・schema version・account/zone/domain/subscription・`messageId`・送信元・宛先照合値・時刻・`terminal` と `delivered` をすべて照合する。欠損、別宛先、別エピソード、bounce、deferred、failed、rejected、重複不一致は送達にしない。
5. 照合後も保持台帳のエピソードと期限切れ状態、現在の連絡先との一致を再確認し、送達時刻を記録する。期限は元の12か月日と送達後30日を比べて遅い方へ延ばす。再購読・権利不明・時計停止・連絡先変更なら消去しない。連絡先の更新後に古い宛先への送達を再利用しないため、最終消去時にも同じ宛先照合を要求する。
6. 最終消去は別の既定OFF経路で、直前の課金再検証、一次/復旧コピーの対象・同一owner・鍵を検査する。送達台帳だけでは削除を開始しない。

## 外部設定の受入条件

- Cloudflare DNSの送信ドメインとWorkers Paid、専用送信元だけを許す `allowed_sender_addresses` binding、送信ドメイン単位のEvent Subscription→専用Queue、Queueの書込主体を確認する。
- Appleの非公開メール利用者へ送るドメインは、Apple Developerで登録しSPF/DKIMを認証する。宛先が実際に受理される試験を行う。
- `message.delivered` は宛先メールサーバーの受理で、受信者の開封や受信箱への表示保証ではない。アプリにも期限と持ち出しを示す。
- 実送信や消去のON/OFFを独立させる。模擬イベントのテスト成功を実配送、復旧、削除の成功と呼ばない。
- 現在のCloudflare OAuthではD1・Workerの権限はあるが、R2 bucket一覧は認証エラー `10000`。専用R2の閲覧・作成・実保存は未確認。AWSアカウントも未作成で、実KMS管理鍵と独立復旧コピーは未接続。送信ドメイン・Workers Paid・Queueの実設定も未完。認証情報をこの資料へ貼らない。

## 必須の模擬境界検証

別owner、期限切れエピソード更新、再購読、会員照会失敗、通知先なし/変更、別宛先、別送信元、別Cloudflare account/zone/subscription、イベント欠落/順序逆転/二重配送、bounce/failed/rejected、送信成功直後のDB失敗、期限当日の競合、30日未満の猶予、無効化済み本人を確認する。後続の実環境では、独立復旧コピーからの復元と消去も実証する。
