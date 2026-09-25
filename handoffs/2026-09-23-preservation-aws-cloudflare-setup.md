# 個人保管：AWS KMS / Cloudflare 実環境準備（当時の手順と現況）

> 2026-09-25 更新：以下の「AWSアカウント未作成」「R2バケット未確認」は作成当時の記録。現在、AWSアカウントは作成済みだが**Free plan**で、KMS/S3の合成データ疎通は部品単位に限る。Cloudflareには保管専用の空R2バケットと空staging D1があり、D1の0013–0016は適用済み。ただしWranglerの現行OAuthはR2 API権限がなく、R2実書込・秘密設定・保管Worker配備は未実施。費用目安はサービス全体で月3,000円程度。[最新の費用ゲート](2026-09-25-preservation-cost-gate.md)と[staging migration記録](2026-09-25-preservation-staging-migrations.md)を優先し、以下をそのまま実施手順と見なさない。

2026-09-23の利用者指定は **AWS KMSを使う**。この資料は利用者のアカウント準備と開発側の接続条件を分ける。利用者確認時点でAWSアカウントは未作成。管理鍵、実R2、実端末復元の成功証拠もない。`PRESERVATION_ENABLED` と `PRESERVATION_KMS_ENABLED` はともに `NO` を維持し、実データ・販売を始めない。

## 利用者がAWS画面で行うこと

1. [AWSアカウント](https://docs.aws.amazon.com/accounts/latest/reference/manage-acct-creating.html)を作成し、請求方法と[MFA](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_mfa_enable.html)を設定する。rootの日常使用を避ける。[AWS Budgets](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html)で少額の月間予算通知を作る。作成と請求への同意は利用者が行う。**現段階では鍵やアクセスキーを先に作らない**。次の権限・復旧構成を確定してから行う。
2. AWS KMSの東京リージョン `ap-northeast-1` に、**対称・暗号化/復号用の顧客管理鍵**を1本作る。独立復旧コピーを別リージョンで取り出せる設計を目指すため、実データ用には**マルチリージョン主キー**を推奨し、複製先とデータ所在は復旧設計で決める。マルチリージョン鍵は作成後に単一リージョン鍵から変換できないため、単一リージョン鍵を既に試作用に作った場合は実データへ使う前に相談する。管理者と暗号操作の利用者を分け、鍵の無効化・削除予約は管理者だけにする。KMSは[鍵ポリシーがIAM許可の前提](https://docs.aws.amazon.com/kms/latest/developerguide/key-policies.html)になるため、既定ポリシーのアカウント管理権限を不用意に除去しない。[鍵種別の変更制限](https://docs.aws.amazon.com/kms/latest/developerguide/multi-region-keys-overview.html)も確認する。
3. 開発側へ伝えるのは**AWSアカウントID、リージョン、鍵ARN、鍵管理者との連絡経路だけ**。鍵素材、アクセスキーID、シークレットアクセスキー、セッショントークン、復旧コードはチャット・Git・チケットに貼らない。

顧客管理鍵は[1本あたり月1米ドル、対象の暗号APIには月2万リクエストの無料枠](https://aws.amazon.com/kms/pricing/)がある。別リージョン複製鍵、CloudTrail、保管、通信その他は別に見積もる。

## 利用者がCloudflare画面で確認すること

1. 現在の管理者で[R2 subscriptionが有効](https://developers.cloudflare.com/r2/get-started/)か確認する。R2は「Cloudflareアカウントがある」だけでは利用できない。
2. R2、D1、Workersの対象アカウントと請求条件を確認する。既存の共有用まどDB/bucketには触れず、保管専用の資源を用意する。現在のWrangler OAuthはD1を読める一方、R2一覧が認証エラー。再ログインは承認コード待ちでタイムアウトし、権限は未確認。管理画面にサインイン済みであることとCLIの許可は別。[R2用API権限](https://developers.cloudflare.com/r2/api/tokens/#permissions)の管理読取／書込が必要な場合は、権限を絞ったトークンを端末内で設定し、チャットやGitには貼らない。
3. CloudflareのアカウントIDだけを共有し、API token・OAuth token・Workers secret値を会話に貼らない。実操作は開発側のコマンドと出力を見ながら進め、公開routeや既存bucketへの接続はしない。

R2 subscriptionと送信に使える独自ドメインの有無は、現在利用者へ確認中。未確認を「利用可能」と読み替えない。

## 12か月後の消去通知に使う送信基盤（候補）

鍵管理はAWS KMSのまま、通知はまず[Cloudflare Email Sending](https://developers.cloudflare.com/email-service/)を検証する。Workers PaidとCloudflare DNS上の送信ドメインが必要で、任意宛先への送信は2026-09-23時点でbeta。送信bindingが同じWorkers基盤で使え、[Email Sendingの配達・失敗・拒否イベントをQueueへ購読](https://developers.cloudflare.com/email-service/platform/event-subscriptions/)できる。送信APIが受理しただけでは「届いた通知」にしない。`message.delivered` のmessage ID、宛先、エピソード、配送時刻を照合して台帳へ記録し、bounce・拒否・イベント欠落では自動削除を停止する。recipient serverへの到達は受信者の開封を意味しないため、アプリ内の期限表示と持ち出し導線も必要。

利用者が持つ送信ドメインをCloudflare DNSへ接続できるか、Workers Paid/Email Sendingを有効化できるかを確認する。Appleの非公開メール宛てには[Apple Developerで送信元ドメインを登録しSPF/DKIMを認証](https://developer.apple.com/help/account/capabilities/configure-private-email-relay-service)する。これらが実証できなければ通知を「送れた」と扱わず、期限消去を有効化しない。Cloudflare Email Sendingを利用できない場合、[Amazon SES](https://docs.aws.amazon.com/ses/latest/dg/request-production-access.html)を代替候補とするが、新規アカウントはsandboxに入り任意の利用者宛送信にはproduction accessが必要。どちらの実契約・ドメイン設定も未実施。

Workersの送信bindingは、無制限の送信元ではなく `allowed_sender_addresses` で専用アドレスに限定する。制限属性を指定しないbindingはアカウント内の検証済み宛先へしか送れず、一般利用者の宛先への通知を実証したことにならない。[bindingの仕様](https://developers.cloudflare.com/email-service/configuration/send-bindings/)参照。

Cloudflareの現行料金表では、任意宛先へのEmail SendingはWorkers Paidが必要で、月3,000通を含み、超過分は1,000通あたり0.35米ドル。これは送信量の費用のみで、ドメイン・Workers・Queues等の費用や配達成功を保証しない。[料金表](https://developers.cloudflare.com/email-service/platform/pricing/)参照。

## Apple本人確認の署名前提

アプリのentitlementsには現在 `com.apple.developer.applesignin` がない。実端末での成功確認前に、Apple Developerの対象App IDでSign in with Appleを有効化し、アプリtargetに `Default` のentitlementを付け、変化したApp IDに対応するprovisioning profileを再生成する必要がある。既存の署名済み配布に影響するため、App IDだけ先に変更して配布済み構成が正常だとみなさない。[Appleの能力設定手順](https://developer.apple.com/help/account/identifiers/enable-app-capabilities)参照。

## 独立復旧コピーの条件（S3案、未採用）

R2と別事業者に暗号化済み写真・DB復旧点・鍵の設定/権限手順を保持し、定期的に別環境へ復元して照合する。R2自身の冗長化だけを独立バックアップとは呼ばない。S3案を採る場合は対象者ごとの削除を一次/全バージョン/復旧点まで追跡する。[S3 Object Lockのcompliance mode](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html)は保持期間中に管理者でも消せないため、本人の明示削除や通知後消去と両立する設計が証明できるまで設定しない。独立コピーの契約・費用・削除/復元試験は未実施。

## 開発側が実接続前に用意すること

- 保管Workerと鍵Workerの**非公開service binding**、保管専用D1/R2、個別secret binding。`wrangler.kms.disabled.jsonc` と `wrangler.jsonc` は現時点では安全側のローカルOFF構成であり、そのまま本番デプロイできる設定ではない。
- KMS呼出元を当該鍵の `kms:Encrypt` / `kms:Decrypt` のみに限定し、[暗号化コンテキスト](https://docs.aws.amazon.com/kms/latest/developerguide/conditions-kms.html)の `neko-preservation-context-sha256` が存在する要求だけを許可する。コンテキスト値は各記録で異なるSHA-256なので固定値のIAM条件にはできない。`kms:EncryptionContextKeys` によるキー名制限とWorker側の64桁hex検査を併用し、管理・鍵削除・grant・他の鍵への権限を与えない。鍵ポリシーとIAMの両方をレビューする。

  専用IAM主体に付ける許可の形は次のとおり。`<KEY_ARN>` は作成した1本の鍵の完全なARNに置き換える。`ForAnyValue` はコンテキストの存在を要求し、`ForAllValues` は余計なキーを拒否する。これは鍵ポリシー側の許可や実KMS疎通試験を代替しない。

  ```json
  {
    "Version": "2012-10-17",
    "Statement": [{
      "Sid": "PreservationRecordKeyOnly",
      "Effect": "Allow",
      "Action": ["kms:Encrypt", "kms:Decrypt"],
      "Resource": "<KEY_ARN>",
      "Condition": {
        "ForAnyValue:StringEquals": {
          "kms:EncryptionContextKeys": "neko-preservation-context-sha256"
        },
        "ForAllValues:StringEquals": {
          "kms:EncryptionContextKeys": ["neko-preservation-context-sha256"]
        }
      }
    }]
  }
  ```
- Worker外からの認証は当面、専用IAM主体の最小権限資格情報をCloudflare secretに登録する方式を検証する。長期資格情報には漏えい・更新負担があるため、ローテーション・CloudTrail監査・失効訓練を受入条件とし、後から短期資格情報へ移行する。秘密値を標準出力・ログ・Gitに出さない。
- `KMS_REGION`、`KMS_KEY_ARN`、`KEY_WRAPPER_CALLER_SECRET`、`KMS_ACCESS_KEY_ID`、`KMS_SECRET_ACCESS_KEY` は実環境のWorkers vars/secretsへ設定する。`KEY_WRAPPER_CALLER_SECRET` は保管Workerと鍵Workerで同値の十分長いランダム値とし、公開経路には渡さない。`IDENTITY_INDEX_SECRET` は別の復旧必須資産として安全に保管する。
- OFFのまま署名済みKMS疎通と失敗時fail-closed、実R2/D1、旧鍵版の復号、バックアップからの復元、別端末での本人復元を検証する。どれか欠けたら有効化しない。
- 別リージョン復旧では、保存済み主キーARNと複製鍵ARNの**同一AWSアカウント・同一`mrk-`鍵ID**だけを許す実装を合成試験済み。複製鍵の作成、地域別ポリシー、実KMS復号は未確認であり、主キーと複製鍵が本当に関連することを実環境で検証するまで復旧成功とは言わない。

## 実接続を止める条件

AWS請求/MFA未設定、KMS鍵ARN未確定、Cloudflare R2権限なし、鍵ポリシーの広すぎる許可、secretを会話に貼る必要がある運用、独立バックアップ・復旧未実証の場合は停止する。コード上の模擬試験は実保存の証拠ではない。
