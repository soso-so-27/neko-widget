# 個人保管：AWS KMS / Cloudflare 実環境準備（未実施）

2026-09-23の利用者指定は **AWS KMSを使う**。この資料は利用者のアカウント準備と開発側の接続条件を分ける。現時点ではAWSアカウント、管理鍵、実R2、実端末復元の成功証拠はない。`PRESERVATION_ENABLED` と `PRESERVATION_KMS_ENABLED` はともに `NO` を維持し、実データ・販売を始めない。

## 利用者がAWS画面で行うこと

1. [AWSアカウント](https://docs.aws.amazon.com/accounts/latest/reference/manage-acct-creating.html)を作成し、請求方法と[MFA](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_mfa_enable.html)を設定する。rootの日常使用を避ける。[AWS Budgets](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html)で少額の月間予算通知を作る。作成と請求への同意は利用者が行う。
2. AWS KMSの東京リージョン `ap-northeast-1` に、**対称・暗号化/復号用の顧客管理鍵**を1本作る。管理者と暗号操作の利用者を分け、鍵の無効化・削除予約は管理者だけにする。まず単一リージョン鍵で接続試験を行い、別リージョン複製は復旧設計後に判断する。KMSは[鍵ポリシーがIAM許可の前提](https://docs.aws.amazon.com/kms/latest/developerguide/key-policies.html)になるため、既定ポリシーのアカウント管理権限を不用意に除去しない。
3. 開発側へ伝えるのは**AWSアカウントID、リージョン、鍵ARN、鍵管理者との連絡経路だけ**。鍵素材、アクセスキーID、シークレットアクセスキー、セッショントークン、復旧コードはチャット・Git・チケットに貼らない。

顧客管理鍵は[1本あたり月1米ドル、対象の暗号APIには月2万リクエストの無料枠](https://aws.amazon.com/kms/pricing/)がある。別リージョン複製鍵、CloudTrail、保管、通信その他は別に見積もる。

## 利用者がCloudflare画面で確認すること

1. 現在の管理者で[R2 subscriptionが有効](https://developers.cloudflare.com/r2/get-started/)か確認する。R2は「Cloudflareアカウントがある」だけでは利用できない。
2. R2、D1、Workersの対象アカウントと請求条件を確認する。既存の共有用まどDB/bucketには触れず、保管専用の資源を用意する。現在のWrangler OAuthはD1を読める一方、R2一覧が認証エラーなので、利用者の端末でWrangler再ログインとR2権限確認が必要。管理画面にサインイン済みであることとCLIの許可は別。
3. CloudflareのアカウントIDだけを共有し、API token・OAuth token・Workers secret値を会話に貼らない。実操作は開発側のコマンドと出力を見ながら進め、公開routeや既存bucketへの接続はしない。

## 開発側が実接続前に用意すること

- 保管Workerと鍵Workerの**非公開service binding**、保管専用D1/R2、個別secret binding。`wrangler.kms.disabled.jsonc` と `wrangler.jsonc` は現時点では安全側のローカルOFF構成であり、そのまま本番デプロイできる設定ではない。
- KMS呼出元を当該鍵の `kms:Encrypt` / `kms:Decrypt` のみに限定し、[暗号化コンテキスト](https://docs.aws.amazon.com/kms/latest/developerguide/conditions-kms.html)の `neko-preservation-context-sha256` が存在する要求だけを許可する。コンテキスト値は各記録で異なるSHA-256なので固定値のIAM条件にはできない。`kms:EncryptionContextKeys` によるキー名制限とWorker側の64桁hex検査を併用し、管理・鍵削除・grant・他の鍵への権限を与えない。鍵ポリシーとIAMの両方をレビューする。
- Worker外からの認証は当面、専用IAM主体の最小権限資格情報をCloudflare secretに登録する方式を検証する。長期資格情報には漏えい・更新負担があるため、ローテーション・CloudTrail監査・失効訓練を受入条件とし、後から短期資格情報へ移行する。秘密値を標準出力・ログ・Gitに出さない。
- `KMS_REGION`、`KMS_KEY_ARN`、`KEY_WRAPPER_CALLER_SECRET`、`KMS_ACCESS_KEY_ID`、`KMS_SECRET_ACCESS_KEY` は実環境のWorkers vars/secretsへ設定する。`KEY_WRAPPER_CALLER_SECRET` は保管Workerと鍵Workerで同値の十分長いランダム値とし、公開経路には渡さない。`IDENTITY_INDEX_SECRET` は別の復旧必須資産として安全に保管する。
- OFFのまま署名済みKMS疎通と失敗時fail-closed、実R2/D1、旧鍵版の復号、バックアップからの復元、別端末での本人復元を検証する。どれか欠けたら有効化しない。

## 実接続を止める条件

AWS請求/MFA未設定、KMS鍵ARN未確定、Cloudflare R2権限なし、鍵ポリシーの広すぎる許可、secretを会話に貼る必要がある運用、独立バックアップ・復旧未実証の場合は停止する。コード上の模擬試験は実保存の証拠ではない。
