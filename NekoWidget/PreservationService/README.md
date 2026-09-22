# 個人保管サービス — 既定OFFの接続候補

本番サービスではありません。専用D1/R2で、Appleの本人確認に結び付けた写真・メモのコピーを保管する接続候補です。共有のE2EE、CloudKit、配送期限、利用者データは変更しません。

## ローカルの確認

Node 22.17以上で `npm ci --ignore-scripts --legacy-peer-deps`、`npm run typecheck`、`npm test`。WranglerのIDはローカル用ダミーです。remote migration/deployを実行しないでください。

テストはローカルD1/R2、実JWT・実AES-256-GCM・実Ed25519署名を使います。鍵を包むauthorityと画像検証の返答はテスト注入です。会員リンクは既存billing検証関数と実ローカルSQLでも確認し、購入権利のprojectionはテスト用データです。Appleは生成鍵と模擬HTTPによる検証であり、実Appleアカウント成功や実KMSの復旧証明ではありません。

## 有効化前に必須の接続

- 固定HTTPS origin、専用DB/bucket、レート制限、`PRESERVATION_ENABLED=YES`。
- Sign in with AppleのApp ID capability、鍵・client ID。native tokenと交換tokenのnonceについて実際のApple経路で確認すること。
- `KEY_WRAPPER`: 非公開service binding。写真/本文はこのserviceで暗号化し、32byteのデータ鍵だけをauthorityへ送る。`/keys/wrap` `{version:1,key:<base64>,contextSHA256}` → `{version:1,keyId,wrappedKey:<base64>}`、`/keys/unwrap` `{version:1,keyId,wrappedKey:<base64>,contextSHA256}` → `{version:1,key:<base64>}`。本番authorityは呼出元認証、管理KMS、許可した鍵版だけの解決、同じcontextによるwrap/unwrap、旧鍵の保持・復旧を実装する。keyIdを任意URLや任意テナントの鍵として解釈しない。テスト鍵や固定鍵へのfallbackは禁止。旧候補の`KEY_CUSTODY /seal /open`とは別契約で、未配備の候補を置換したもの。既存暗号文の無断移行はない。
- `MEMBERSHIP_AUTHORITY`: 独立billing workerのnamed entrypoint `BillingAuthority`への非公開service binding。両workerに一致する環境固有の`PRESERVATION_LINK_AUDIENCE`が必須。`/membership/verify-link`は二重本人証明、`/membership/verified-status`は`{billingAccountId}` → `{version:1,billingAccountId,status:'active'|'grace'|'expired'|'unknown'}`。未配備旧候補の`{ownerId}`契約は廃止。詳細は後述。
- `PHOTO_VALIDATOR`: `/images/validate-jpeg`。`{photoBase64}` → `{valid:true,mediaType:'image/jpeg',frames:1}`。サーバー側の実デコードと画素数制限が必須。JPEGヘッダーだけで合格にしない。
- `IDENTITY_INDEX_SECRET`: 32byte以上のbase64url乱数。identity HMACを変えると別所有者になるため、復旧・ローテーション設計なしで変更しない。
- `OWNER_QUOTA_BYTES` / `MAXIMUM_RECORDS`: 正整数。後者は削除済みのIDも数える運用上限で、顧客向け残容量として表示しない。最終商品の容量・保存期限は未決定。
- `CLEANUP_ENABLED=YES`と専用cron。清掃はApple/課金/KMS停止中も動く。削除待ちを1時間ごとに再試行し、7日超の成功でキューを消す。全object棚卸し・バックアップ内削除・監視・復旧試験は公開前に別途必要。

写真/本文の暗号化は `src/key-custody.ts` に実装済み。NKM1（8byte prefix + 上限8KiBの版付きJSON header + ciphertext/tag）はAES-256-GCM、データごとの32byte鍵、12byte IV、128bit tagを使う。header全体をAADにし、保管owner・用途・record/documentまたはrecord/photoのSHA256 contextをheaderと管理鍵の双方へ結び付ける。古いkeyIdを残すので鍵の切替後も旧記録を読む経路はあるが、鍵を実際に保全する責務は外部authorityに残る。JWE/AWS SDKとの形式互換はない。

外部KMSのauthorityと実JPEG providerのprivate bridgeは未配備です。会員の二重本人リンクはサーバー側のみで、native接続・同意画面・実billing bindingは未完。実リソース・秘密設定・実装の欠如を「設定だけで稼働可能」と扱わないこと。APIは依存が不足すれば閉じたまま。暗号データ鍵のbyte bufferは成功/失敗時に上書きするが、JS文字列/ランタイム内コピー全体の確実な消去を保証しない。鍵・token・写真はログへ出さない。

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
