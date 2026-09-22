# 個人保管サービス — 既定OFFの接続候補

本番サービスではありません。専用D1/R2で、Appleの本人確認に結び付けた写真・メモのコピーを保管する接続候補です。共有のE2EE、CloudKit、配送期限、利用者データは変更しません。

## ローカルの確認

Node 22.17以上で `npm ci --ignore-scripts --legacy-peer-deps`、`npm run typecheck`、`npm test`。WranglerのIDはローカル用ダミーです。remote migration/deployを実行しないでください。

テストはローカルD1/R2と注入した鍵・課金・画像検証を使います。Appleは生成鍵と模擬HTTPによる検証であり、実Appleアカウント成功や実KMSの復旧証明ではありません。

## 有効化前に必須の接続

- 固定HTTPS origin、専用DB/bucket、レート制限、`PRESERVATION_ENABLED=YES`。
- Sign in with AppleのApp ID capability、鍵・client ID。native tokenと交換tokenのnonceについて実際のApple経路で確認すること。
- `KEY_CUSTODY`: 非公開service bindingの `/keys/seal` / `/keys/open`。`{bytes:<base64>,context:{ownerId,purpose,recordId?}}` → `{bytes:<base64>}`。本番は管理KMS、認証済み暗号・context束縛・鍵版管理・旧鍵復旧を実装する。テスト鍵や固定鍵へのfallbackは禁止。
- `MEMBERSHIP_AUTHORITY`: `/membership/verified-status`。`{ownerId}` → `{status:'active'|'grace'|'expired'|'unknown'}`。ownerは本人確認で確定した保管専用ID。クライアント申告の購入IDをそのまま結び付けない。接続前に購入所有者の照合と失効反映時間を決める。
- `PHOTO_VALIDATOR`: `/images/validate-jpeg`。`{photoBase64}` → `{valid:true,mediaType:'image/jpeg',frames:1}`。サーバー側の実デコードと画素数制限が必須。JPEGヘッダーだけで合格にしない。
- `IDENTITY_INDEX_SECRET`: 32byte以上のbase64url乱数。identity HMACを変えると別所有者になるため、復旧・ローテーション設計なしで変更しない。
- `OWNER_QUOTA_BYTES` / `MAXIMUM_RECORDS`: 正整数。後者は削除済みのIDも数える運用上限で、顧客向け残容量として表示しない。最終商品の容量・保存期限は未決定。
- `CLEANUP_ENABLED=YES`と専用cron。清掃はApple/課金/KMS停止中も動く。削除待ちを1時間ごとに再試行し、7日超の成功でキューを消す。全object棚卸し・バックアップ内削除・監視・復旧試験は公開前に別途必要。

これらのprivate providerは本候補では**接続インターフェースのみ**です。実リソース・秘密設定・実装の欠如を「設定だけで稼働可能」と扱わないこと。APIは依存が不足すれば閉じたままです。

## 守る境界

新規保管には明示同意とactive/graceが必要。既存記録の読み出し・本文編集・削除・持ち出しに会員資格は要求しません。本人確認は必要です。新規UUID・版番号・予約上限で競合を管理し、元の写真/ローカルメモは変更しません。

サービス運営が復号できる設計でありE2EEではありません。原本・動画のバックアップではなく、選択されたJPEGとメモのコピーです。アカウント削除・Apple通知/失効・継続ログイン・全体復旧運用・容量/保管期限の最終方針は、一般提供前のゲートです。

今回の証拠と本線接続方法は `handoffs/2026-09-22-managed-preservation-goal.md` を参照してください。
