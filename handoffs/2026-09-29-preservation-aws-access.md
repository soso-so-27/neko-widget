# 個人保管のAWS接続を立て直す（2026-09-29）

## 結論

`aws login` は開発者がAWSを管理するための一時認証であり、保管サービスや利用者の保存操作に使わない。AWS公式資料ではCLIセッションは最大12時間で切れる。いまのCloudflare WorkerはAWS資格情報を設定値として読み、期限切れ後に自動更新する仕組みを持たないため、CLIで得た一時資格情報をWorkerへコピーしてはいけない。

Stagingの小規模検証では、AWSアカウント `164892691568` に保管専用の最小権限主体を**一度**用意し、その主体だけのS3資格情報をCloudflareの非公開secretに設定する。既存の `scripts/aws-s3-staging-writer-policy.json` は `recovery/v1/*` の書込み・読取りと限定したversion一覧、`purge/v1/*` の読取りを候補にしている。KMS用主体、S3消去主体、開発者の管理者認証は分離する。資格情報の変更・失効・漏えい時の停止手順を持ち、毎回の保存や配布に個人ログインを挟まない。長期運用ではAWSが推奨する外部ワークロード向けの短期資格情報（IAM Roles Anywhere等）も候補だが、証明書管理・自動更新の設計と実証なしに既存Workerへ導入しない。

## 今回確認できた境界

- CLIの `neko-preservation-test` はrootの `login_session` だけ。別の有効なAWSプロファイルはない。
- `aws login --remote` は個人用ブラウザで2回ともAWSの400。2回目はCodex側でリンクを開いていない。原因をリンク再利用と断定できず、再試行を止めた。Cookie削除や会社用Chromeの利用を求めない。
- S3の現物、IAM鍵、KMS鍵状態は今回未再確認。秘密鍵のAWS SSM控えも未完了。Apple専用鍵はCloudflareの非公開secretへ設定済みで、原本はローカルのアクセス制限付きファイルに残す。
- 保管Workerは公開routeなし、受付・cleanupともOFF。実会員の購入・照合も未成立。実保存・別端末復元・ZIPは未検証。

## 再開時の一回限りの管理手順

1. 個人のAWS管理画面に通常の方法で入り、対象アカウントとRegionを**画面で**照合する。CLIの400解消を保管サービスの前提条件にしない。会社アカウントのブラウザや別アカウントを流用しない。
2. versioning、Block Public Access、bucket policy、KMS鍵と既存KMS主体を読み取る。ここで差があれば変更前に原因を確定する。
3. S3専用主体に上記の限定policyを適用し、消去権限・他bucket権限がないことを確認する。資格情報はログ、Git、チャットに出さずCloudflare secretへ一度だけ登録する。人のCLIセッションtokenを登録しない。
4. 受付OFFのまま、資格情報の有効性とS3の保存・読戻しを合成1件で確かめ、残存0件に戻す。KMS・R2・D1を含む実フローと実会員を別に確認する。失敗を成功扱いしない。
5. Apple鍵の独立した暗号化控えを作り、読戻しを照合する。これは復旧可能性の条件であり、同じAWSログイン障害を解くための先行タスクにはしない。

## いま進められることと停止条件

Apple App ID、署名profile、CloudflareのApple secret、アプリとWorkerの既定OFF結線は準備済み。局所のdisabled release 11件と署名認証4件は成功済みで、入力が変わらない限り繰り返さない。実Plusの商品と有料アプリ契約は未成立であり、AWSだけ整っても受付はONにしない。現状で広域CIやTestFlightを起動しても実保存の成功証拠にはならない。

参照: [AWS CLIログインの期限](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html)、[AWSの外部ワークロード向け認証](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_common-scenarios_non-aws.html)。
