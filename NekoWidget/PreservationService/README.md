# 個人保管サービス — 既定OFFの接続候補

本番サービスではありません。専用D1/R2で、Appleの本人確認に結び付けた写真・メモのコピーを保管する接続候補です。共有のE2EE、CloudKit、配送期限、利用者データは変更しません。

## ローカルの確認

Node 22.17以上で `npm ci --ignore-scripts --legacy-peer-deps`、`npm run typecheck`、`npm test`。WranglerのIDはローカル用ダミーです。remote migration/deployを実行しないでください。

テストはローカルD1/R2と実JWT・実AES-256-GCMを使います。鍵を包むauthority、会員判定、画像検証の返答はテスト注入です。Appleは生成鍵と模擬HTTPによる検証であり、実Appleアカウント成功や実KMSの復旧証明ではありません。再ログインからHTTP API・owner・暗号化された記録の復元までをまとめた試験も含みます。

## 有効化前に必須の接続

- 固定HTTPS origin、専用DB/bucket、レート制限、`PRESERVATION_ENABLED=YES`。
- Sign in with AppleのApp ID capability、鍵・client ID。native tokenと交換tokenのnonceについて実際のApple経路で確認すること。
- `KEY_WRAPPER`: 非公開service binding。写真/本文はこのserviceで暗号化し、32byteのデータ鍵だけをauthorityへ送る。`/keys/wrap` `{version:1,key:<base64>,contextSHA256}` → `{version:1,keyId,wrappedKey:<base64>}`、`/keys/unwrap` `{version:1,keyId,wrappedKey:<base64>,contextSHA256}` → `{version:1,key:<base64>}`。本番authorityは呼出元認証、管理KMS、許可した鍵版だけの解決、同じcontextによるwrap/unwrap、旧鍵の保持・復旧を実装する。keyIdを任意URLや任意テナントの鍵として解釈しない。テスト鍵や固定鍵へのfallbackは禁止。旧候補の`KEY_CUSTODY /seal /open`とは別契約で、未配備の候補を置換したもの。既存暗号文の無断移行はない。
- `MEMBERSHIP_AUTHORITY`: `/membership/verified-status`。`{ownerId}` → `{status:'active'|'grace'|'expired'|'unknown'}`。ownerは本人確認で確定した保管専用ID。クライアント申告の購入IDをそのまま結び付けない。接続前に購入所有者の照合と失効反映時間を決める。
- `PHOTO_VALIDATOR`: `/images/validate-jpeg`。`{photoBase64}` → `{valid:true,mediaType:'image/jpeg',frames:1}`。サーバー側の実デコードと画素数制限が必須。JPEGヘッダーだけで合格にしない。
- `IDENTITY_INDEX_SECRET`: 32byte以上のbase64url乱数。identity HMACを変えると別所有者になるため、復旧・ローテーション設計なしで変更しない。
- `OWNER_QUOTA_BYTES` / `MAXIMUM_RECORDS`: 正整数。後者は削除済みのIDも数える運用上限で、顧客向け残容量として表示しない。最終商品の容量・保存期限は未決定。
- `CLEANUP_ENABLED=YES`と専用cron。清掃はApple/課金/KMS停止中も動く。削除待ちを1時間ごとに再試行し、7日超の成功でキューを消す。全object棚卸し・バックアップ内削除・監視・復旧試験は公開前に別途必要。

写真/本文の暗号化は `src/key-custody.ts` に実装済み。NKM1（8byte prefix + 上限8KiBの版付きJSON header + ciphertext/tag）はAES-256-GCM、データごとの32byte鍵、12byte IV、128bit tagを使う。header全体をAADにし、保管owner・用途・record/documentまたはrecord/photoのSHA256 contextをheaderと管理鍵の双方へ結び付ける。古いkeyIdを残すので鍵の切替後も旧記録を読む経路はあるが、鍵を実際に保全する責務は外部authorityに残る。JWE/AWS SDKとの形式互換はない。

外部KMSのauthorityと会員の本人リンクは**未実装**、実JPEG providerのprivate bridgeも未配備です。実リソース・秘密設定・実装の欠如を「設定だけで稼働可能」と扱わないこと。APIは依存が不足すれば閉じたまま。暗号データ鍵のbyte bufferは成功/失敗時に上書きするが、JS文字列/ランタイム内コピー全体の確実な消去を保証しない。鍵・token・写真はログへ出さない。

## 守る境界

新規保管には明示同意とactive/graceが必要。既存記録の読み出し・本文編集・削除・持ち出しに会員資格は要求しません。本人確認は必要です。新規UUID・版番号・予約上限で競合を管理し、元の写真/ローカルメモは変更しません。

サービス運営が復号できる設計でありE2EEではありません。原本・動画のバックアップではなく、選択されたJPEGとメモのコピーです。アカウント削除・Apple通知/失効・継続ログイン・全体復旧運用・容量/保管期限の最終方針は、一般提供前のゲートです。

今回の証拠と残条件は `handoffs/2026-09-22-preservation-custody.md`、アプリ統合は `handoffs/2026-09-22-preservation-parallel-plan.md` を参照してください。
