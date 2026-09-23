# 個人保管サービス — 既定OFFの接続候補

本番サービスではありません。専用D1/R2で、Appleの本人確認に結び付けた写真・メモのコピーを保管する接続候補です。共有のE2EE、CloudKit、配送期限、利用者データは変更しません。

## ローカルの確認

Node 22.17以上で `npm ci --ignore-scripts --legacy-peer-deps`、`npm run typecheck`、`npm test`。WranglerのIDはローカル用ダミーです。remote migration/deployを実行しないでください。

`wrangler.jsonc` の `staging` 環境だけは、共有用DBとは別の空の `neko-preservation-staging` D1を指します。2026-09-23にmigration 0001–0005を適用済みで、所有者・記録は0件。`neko-preservation-staging-private` R2は**予約名であり、作成・接続の実証はまだありません**。写真検証は `neko-preservation-jpeg-disabled` の非公開 `JPEGValidationService` へ向ける設定だけを用意しました。宛先Worker自体は未配備で、secretも未設定です。`PRESERVATION_ENABLED`、清掃、保持時計はすべて `NO`、公開routeも設定しません。宛先Worker、R2、秘密設定が揃う前にstagingを実配備しないでください。`wrangler deploy --dry-run --env staging` のbundle成功を、実R2・鍵・画像検証・Apple接続・写真保存の成功と扱わないでください。既存共有資源へは接続しません。

テストはローカルD1/R2、実JWT・実AES-256-GCM・実Ed25519署名を使います。鍵を包むauthorityと画像検証の返答はテスト注入です。会員リンクは既存billing検証関数と実ローカルSQLでも確認し、購入権利のprojectionはテスト用データです。Appleは生成鍵と模擬HTTPによる検証であり、実Appleアカウント成功や実KMSの復旧証明ではありません。

## 有効化前に必須の接続

- 固定HTTPS origin、専用DB/bucket、レート制限、`PRESERVATION_ENABLED=YES`。
- Sign in with AppleのApp ID capability、鍵・client ID。native tokenと交換tokenのnonceについて実際のApple経路で確認すること。
- `KEY_WRAPPER`: 非公開service binding。写真/本文はこのserviceで暗号化し、32byteのデータ鍵だけをauthorityへ送る。`/keys/wrap` `{version:1,key:<base64>,contextSHA256}` → `{version:1,keyId,wrappedKey:<base64>}`、`/keys/unwrap` `{version:1,keyId,wrappedKey:<base64>,contextSHA256}` → `{version:1,key:<base64>}`。保管serviceと鍵Workerの双方に同じ43文字以上の乱数 `KEY_WRAPPER_CALLER_SECRET` をsecretとして配り、非公開bindingの呼出元を認証する。keyIdを任意URLや任意テナントの鍵として解釈しない。テスト鍵や固定鍵へのfallbackは禁止。旧候補の`KEY_CUSTODY /seal /open`とは別契約で、未配備の候補を置換したもの。既存暗号文の無断移行はない。
- `MEMBERSHIP_AUTHORITY`: 独立billing workerのnamed entrypoint `BillingAuthority`への非公開service binding。両workerに一致する環境固有の`PRESERVATION_LINK_AUDIENCE`が必須。`/membership/verify-link`は二重本人証明、`/membership/verified-status`は`{billingAccountId}` → `{version:1,billingAccountId,status:'active'|'grace'|'expired'|'unknown'}`。未配備旧候補の`{ownerId}`契約は廃止。詳細は後述。
- `PHOTO_VALIDATOR`: `/images/validate-jpeg`。`{photoBase64}` → `{valid:true,mediaType:'image/jpeg',frames:1}`。サーバー側の実デコードと画素数制限が必須。JPEGヘッダーだけで合格にしない。
- `IDENTITY_INDEX_SECRET`: 32byte以上のbase64url乱数。identity HMACを変えると別所有者になるため、復旧・ローテーション設計なしで変更しない。
- `OWNER_QUOTA_BYTES` / `MAXIMUM_RECORDS`: 正整数。後者は保存中＋処理中の記録数の上限。削除済みIDは再送防止のため残すが、新規保存枠は消費しない。最終商品の容量・保存期限は未決定。
- `CLEANUP_ENABLED=YES`と専用cron。清掃はApple/課金/KMS停止中も動く。削除待ちを1時間ごとに再試行し、7日超の成功でキューを消す。全object棚卸し・バックアップ内削除・監視・復旧試験は公開前に別途必要。

写真/本文の暗号化は `src/key-custody.ts` に実装済み。NKM1（8byte prefix + 上限8KiBの版付きJSON header + ciphertext/tag）はAES-256-GCM、データごとの32byte鍵、12byte IV、128bit tagを使う。header全体をAADにし、保管owner・用途・record/documentまたはrecord/photoのSHA256 contextをheaderと管理鍵の双方へ結び付ける。古いkeyIdを残すので鍵の切替後も旧記録を読む経路はあるが、鍵を実際に保全する責務は外部authorityに残る。JWE/AWS SDKとの形式互換はない。

AWS KMS候補の非公開鍵Workerは `src/aws-kms-key-wrapper.ts` と既定OFFの `wrangler.kms.disabled.jsonc` に用意した。`PreservationKeyWrapper` named entrypointだけが応答し、公開default routeは404。`KMS_KEY_ARN`（対称鍵の完全なARN）・`KMS_REGION`・AWS認証情報・`PRESERVATION_KMS_ENABLED=YES` が揃う場合だけ、同じSHA256 contextをAWS KMSのEncryptionContextに入れて `Encrypt` / `Decrypt` を実行する。呼出元tokenが違う、鍵ARNが違う、AWSが異常／タイムアウト、返答鍵が違う場合はfail closed。現在のコードは**単一ARN**を対象とし、AWSの同じ鍵の自動ローテーション以外の新旧鍵切替・別リージョン復旧は未検証。AWSアカウント、最小権限IAM、secret、実KMS鍵、別リージョン復旧を準備してから有効化する。ローカルテストの署名リクエストは合成AWS応答で、実KMS成功ではない。[保持・鍵設計](../../handoffs/2026-09-23-preservation-retention-key-decision.md)参照。

`src/s3-recovery-copy.ts` は独立復旧先の候補で、暗号化済みobjectの版付き書込／チェックサム照合／指定版の読出しだけを持つ。**現行の保存APIには未接続**で、owner・認証情報・記録・削除台帳の整合した復元や実AWS書込の証拠ではない。S3のversioningだけは削除不能性を保証しない。書込主体から `DeleteObjectVersion` 権限を外し、専用の消去主体と分離し、bucket policy・lifecycle・Object Lockの有無と保持期間を実アカウントで確認する。Object Lockを使う場合は期限後消去や本人削除を妨げない設定が必要。単にバケットでversioningを有効化しただけで「独立バックアップ完成」と表示しない。[S3 Object Lock](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html)、[版別削除](https://docs.aws.amazon.com/AmazonS3/latest/userguide/DeletingObjectVersions.html)。

外部KMSの実接続と実JPEG providerのprivate bridgeは未配備です。会員の二重本人リンクにはnative接続・同意/再試行画面まで本線実装がありますが、実billing binding・実Apple/購入/別端末の接続確認は未完です。実リソース・秘密設定・実装の欠如を「設定だけで稼働可能」と扱わないこと。APIは依存が不足すれば閉じたまま。暗号データ鍵のbyte bufferは成功/失敗時に上書きするが、JS文字列/ランタイム内コピー全体の確実な消去を保証しない。鍵・token・写真はログへ出さない。

## 期限切れ後の持ち出し時計（既定OFF）

`RETENTION_TRACKING_ENABLED=YES` のときに限り、本人の保管sessionで `GET /v1/retention` を使えます。未リンクなら `status: "unlinked"`、リンク済みなら検証した `active` / `grace` / `expired` / `unknown`、予定日 `dueAt`（Unixミリ秒またはnull）、`paused`、最終通知の配達時刻を返します。請求照会失敗は `unknown` として時計を停止し、別のownerの指定や照会は受け付けません。`PRESERVATION_ENABLED` も必要で、通常運用は両方OFFです。

これは、会員期限切れ後12か月の閲覧・持ち出しと事前通知後の消去という決定に向けた、時計と本人向け状態照会の土台です。通知先、実配送、一次/復旧コピーの最終消去、別端末復元は未実装・未実証であり、このAPIの存在をもって消去予定やバックアップを利用者へ約束しません。[安全条件](../../handoffs/2026-09-23-preservation-retention-ledger.md)を参照してください。

## 使用量の確認

本人の保管sessionで `GET /v1/usage`。query・所有者ID指定は不可、`Cache-Control: no-store`。会員資格・鍵の復号・写真ダウンロードには依存しない読み取りAPIです（本人の有効sessionとサービスの構成は必要）。アプリ表示への接続は別バッチです。

追加migration `0004_upload_owner_index.sql` は予約表に所有者単位のcovering indexを作ります。旧migrationの変更やデータ変換はなく、全所有者の予約を走査しないことをローカルのquery planで確認しています。本番DBへは未適用です。

```json
{
  "version": 1,
  "accounting": "encrypted-records-v1",
  "storage": { "usedBytes": 1200, "reservedBytes": 800, "limitBytes": 10000, "availableBytes": 8000, "overLimit": false },
  "records": { "saved": 1, "pending": 1, "creationLimitReached": false }
}
```

上の数値は説明用で、提供容量の決定ではありません。

- `usedBytes` は保管中の暗号化JPEG＋暗号化本文/メタデータ。元写真の容量やR2全体の実請求量ではありません。
- `reservedBytes` は保存処理で確保した容量。期限切れでも清掃が完了するまでは含みます。コミット時に予約→保管済みへ移り、同一SQL snapshotで二重計上しません。
- `availableBytes` は使用中＋予約中を引き、最小0。既存本文の編集や設定容量の引下げで超過しても、既存記録を削除/非表示にせず `overLimit` を返します。この値は新規保存の予約や成功保証ではありません。
- `saved` は未削除の記録数（本文だけの記録も含む）、`pending` は未清掃の保存処理数。`creationLimitReached` はこの合計が件数上限に達したことを示します。削除済みIDは再送防止のため残しますが上限へ数えず、削除で枠が空きます。空き容量だけでは次の保存成功を保証しません。
- 会計行の欠落/不一致は `ARCHIVE_ACCOUNTING_UNAVAILABLE` / 503。0件/空き容量として成功させず、記録を消して帳尻を合わせません。使用量はR2実体や復号可能性の検査結果ではありません。

現行コードに解約連動の自動削除はありません。利用者指定の「期限切れ後12か月の持ち出し、事前通知後に消去」を実行するには、通知の送達確認、停止可能な最終消去、復旧コピー内の消去、復元訓練が別途必要です。それまでは無期限保持も期限消去も販売上の保証にしません。現行の明示削除は本文/参照を即時に消し、R2を清掃待ちへ移します。清掃の7日は遅延書込みへの再消去期間で、7日間の取消・ごみ箱ではありません。提供容量、誤削除の取消、運営終了時の持ち出し条件も提供開始前に決めます。

## 保管ownerと購入者のリンク

1. 保管sessionのBearerで`POST /v1/membership/challenges` `{billingAccountId}`。応答は`{challenge,signingPath,signingBody}`。まだ権利は付かない。
2. nativeの既存billing秘密鍵で、method `POST`、返された固定path `/v1/preservation/membership-link`、`signingBody`のUTF-8 bytesを既存NWB1署名形式で署名。bodyを勝手に整形し直さない。
3. **同じ保管session**で`POST /v1/membership/link` `{challengeId,proof:{billingKeyId,timestamp,nonce,signature}}`。timestampは既存billing規約通り秒の文字列。応答`{linked:true}`。challengeは5分・一回限り、失敗時は発行し直す。
4. `GET /v1/membership`は`{linked,status}`のみ返す。通信結果が失われたときの確認にも使える。所有者/購入IDを照会パラメータとして受け取らない。

保管DBの`0003_membership_links.sql`が一対一リンクを固定する。別owner/billingへの変更・削除はしない。新challengeを取り直した同じ組み合わせの確認は成功する。請求鍵の更新でリンクは変わらない。Appleサインイン本人の変更、購入account変更、退会に伴う破棄/移行は別の明示的な回復/削除手順が必要であり未実装。

`wrangler.billing.disabled.jsonc`は独立workerのローカル例。実billing DBを自動検出せず、migrationも所有しない。default公開fetchは常に404。named entrypointのみ利用可能で、`PRESERVATION_BILLING_ENABLED=YES`も必要。本人リンクの検証はactive課金を条件にせず、status照会だけ既存env/D1の課金有効化gateを尊重する。権利の鮮度・失効・猶予期間は`SharingService/src/billing-entitlement.ts`を再利用し、暫定権利や家族共有を独自に昇格しない。

署名の成功はその照合時点のbilling鍵の所持を示す。保管DBとは分散transactionではないため、返答後の鍵更新を巻き戻して無効化する保証はない。保管側では外部照会後もsession/owner epoch/期限を再検査する。会員失効や課金サービス停止は既存記録の読出しを妨げない。

## 守る境界

新規保管には明示同意とactive/graceが必要。既存記録の読み出し・本文編集・削除・持ち出しに会員資格は要求しません。本人確認は必要です。新規UUID・版番号・予約上限で競合を管理し、元の写真/ローカルメモは変更しません。

サービス運営が復号できる設計でありE2EEではありません。原本・動画のバックアップではなく、選択されたJPEGとメモのコピーです。アカウント削除・Apple通知/失効・継続ログイン・全体復旧運用・容量/保管期限の最終方針は、一般提供前のゲートです。

今回の証拠と残条件は `handoffs/2026-09-22-preservation-billing-link.md`、鍵は `handoffs/2026-09-22-preservation-custody.md`、アプリ統合は `handoffs/2026-09-22-preservation-parallel-plan.md` を参照してください。
