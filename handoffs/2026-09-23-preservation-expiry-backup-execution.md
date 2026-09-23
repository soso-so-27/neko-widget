# 個人保管：独立復旧コピーと期限消去の実行境界（設計中）

2026-09-23。基点 `d82f495`。この記録は実装・実環境試験の順序を固定するためのもの。実データ保存、バックアップ、期限消去を有効化した証拠ではない。

## 現在の実装から確かめた事実

- `pa_records` の暗号化本文はD1、写真暗号文はR2。`pa_uploads` は書込途中の予約、`pa_pending_deletes` は既知の写真objectの後処理。どちらも独立した復旧コピーではない。
- `RetentionLedger.eligibleAfterFreshCheck` は期限・通知の助言的判定だけで、実削除を行わない。`pa_retention.final_notice_*` は現在の通知送達候補から昇格されるが、昇格済みという値だけで復旧コピーや現在の課金権利まで証明しない。
- 送信用の `DurableAuth.verifiedNoticeContactForCandidate` は未送達の候補だけを読むため、送達後の消去審査に再利用できない。消去用には現在の暗号化宛先を非公開で再照合し、`pa_notice_submissions.recipient_tag` と同じ鍵付き照合値まで確認する別経路が必要。`final_notice_receipt` は送信受付IDではなく `delivery_event_id` を保持しており、通知時に延長された `due_at` は送信行の旧期限と一致しない場合がある。
- iOSには写真を含む全件ZIPの経路がある。ただし端末の一時容量が不足する大容量時の持ち出し保証にはならない。
- 保管専用サービスは既定OFF。AWSアカウント、実KMS/R2、通知ドメイン、別端末復元は未確認。Cloudflareの現行CLI権限ではR2一覧が失敗する。
- 通知先照合値は owner ID とアドレスの組を鍵付きで計算し、同一アドレスの別ownerをDB上で関連付けない。0009以前の既存連絡先は照合値がNULLのため、初回の同一アドレス再認証でも最終通知を一度だけ再要求する。早期消去を避ける保守的な扱いで、実連絡先を持つ本番運用前に移行する。
- 2026-09-24 JST、保管専用の **staging** D1に `0009_notice_contact_fingerprint.sql` を適用した。事前Time Travel bookmarkは `00000008-00000002-000050ef-02c373786b3b6ff4f57312a3f87a07d2`。事前のowner/record/contactは全て0、適用後は未適用migration 0、`email_tag`列1・関連trigger 2・owner/record 0を確認。本番DB、共有DB、Worker配備には触れていない。
- 次の候補では、期限後の正確な保持台帳版、復号した現在のApple連絡先、同一ownerに閉じた宛先照合値、配送イベントIDと提出行、30日以上の猶予を読み取り専用で再照合する経路を追加中。これ単体は削除許可ではなく、外部の新鮮な課金照会、一次・独立復旧コピーの完全inventory、owner fence、冪等消去台帳は依然として必要。
- 送達台帳の旧v1宛先照合値はowner間で同じアドレスを関連付け得るうえ、旧行の `provider_accepted_at` が欠け得る。`0010_notice_evidence_version.sql` は旧v1の照合値をランダム値に置き換え、既存の最終送達receiptを取り消して再通知を要求する。旧行・旧claimは監査用に残すがv2の送達証拠には使わない。移行前に実owner数と復元位置を記録し、実送信の有効化前にstageで構造確認する。
- 2026-09-24 JST、保管専用 **staging** D1へ0010を適用。事前bookmark `00000009-00000000-000050ef-bffd9fc126ff9e3b3e404268d578b426`、事前owner/record/submission/claimは全て0。適用後の未適用migration 0、`evidence_version`列1、v2書込guard 4、旧receipt再昇格guard 1、owner/record 0を確認。旧形式の合成ownerを用いたNode SQLite移行試験と保管サービス124試験、独立レビューは成功。本番DBやWorker配備は未変更。
- `0011_expiry_review_cursor.sql` は削除許可を持たないowner単位の巡回位置と期限用indexを追加する。古い不適格ownerを飛ばして次の候補へ進み、最後まで進むと先頭へ戻る。候補の各件は課金・送達・連絡先・コピー・fenceの再照合が依然として必須。ローカル型検査と保管サービス125試験に成功。
- 2026-09-24 JST、専用 **staging** D1へ0011を適用。事前bookmark `0000000a-00000002-000050ef-52b0a6a521331e083a9bc337cbbe35f5`、事前owner/record/submission/claimは全て0。適用後は未適用migration 0、初期cursor行1・index 1・owner/record 0を確認。本番DBやWorker配備は未変更。

## 保存完了と復旧の提案（利用者判断待ち）

独立コピーの第一候補は、AWS KMSを置くアカウントの専用S3 bucket。R2と別の事業者・認証境界に暗号文を置ける。ただし同一AWSアカウントにKMSとS3を置くため、AWSアカウント全体の事故から完全には独立しない。別アカウント／リージョンは復旧演習と費用を見て選ぶ。

実環境に進むための利用者操作は、請求方法を設定したAWSアカウントの作成と、rootへのMFA設定まで。rootのアクセスキーは作らず、認証情報をチャットに貼らない。アカウント作成後、こちらで日常作業用の限定権限・鍵・S3 bucketの構成を提案し、実環境の権限と費用を確認する。AWS公式の[アカウント設定](https://docs.aws.amazon.com/IAM/latest/UserGuide/getting-started-account-iam.html)と[rootの保護](https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-best-practices.html)を根拠とする。Cloudflareは現行Wrangler OAuthが`workers_scripts (write)`/`d1 (write)`のみでR2操作が拒否された。`workers:write`を含む権限更新の承認が必要。2026-09-24のOAuth再試行は承認コード待ちで時間切れとなり、権限は未更新。ユーザーがPCで承認できる時にのみ再試行する。

AWSの[現行アカウントプラン](https://docs.aws.amazon.com/en_en/awsaccountbilling/latest/aboutv2/free-tier-plans.html)ではFreeプランが6か月またはクレジット消尽時に終了し、未アップグレードだとアカウントが閉じデータへのアクセスを失う。12か月持ち出し期間の独立復旧コピーを本番運用するにはPaidプランが必要。新規AWSアカウントを最初からPaidにするか、検証後・本番前にPaidへ切り替えるか利用者判断待ち。無料枠やクレジットを「12か月の保全保証」として扱わない。

S3の版付き暗号文の転送・SHA-256照合・指定版読出しの候補を追加したが、現行の保存APIには未接続。版管理だけでは削除権限やlifecycleによる版消去を防げないため、書込主体と消去主体のIAM分離、bucket policy、lifecycle、Object Lockの利用有無・消去可能時期を実アカウントで検証するまで保管完了の証拠としない。Object Lockの保持期間が利用者への削除約束と衝突しないことも条件。

次の別ブランチで、S3の所有者prefix内にある旧versionとdelete markerを読み取る `listOwnerVersionsPage` を追加。レスポンスのbucket/prefix、ページ継続マーカー、同一keyのversion継続、版ID・件数を検証し、不正/欠落は503で拒否する。独立レビューで見つかった2件のページ欠落可能性を修正し、型検査・対象6件・保管サービス全131件・合成ownerのmigration試験に成功。これは**読み取り専用の1ページ**で、全件一覧、R2/D1照合、書込fence、物理削除、実AWSの確認ではない。版一覧の途中に書込が起きない条件と、全ページ後の再照合がない限り、消去可能と判定しない。

同じ後続ブランチにR2のowner写真一覧と、D1の失効owner記録・削除済みIDのページ一覧を読み取り専用で追加。D1は単一transactionでowner状態と一覧を読み、保管中アップロードと途中ページのgeneration/epoch変化を拒否する。どちらもまだ三者の全件照合や消去許可ではない。失効ownerであることは、期限経過・通知送達・課金権利消失の証拠にはならない。

さらに削除前専用のowner fenceを後続ブランチに追加。新鮮な非公開課金結果、保持episode/改訂、現在のApple通知先、v2の送達証拠、inventory generation、未完了uploadの不在を一つのD1 batchで照合してからownerの通常アクセスを止める。再照会が非失効・不明なら古い通知証拠を消して解除する。Workerが停止しても10分のlease切れ後、scheduled maintenanceが削除前fenceだけを解除・証拠無効化する。物理削除の権限や実行経路はまだない。将来`begin()`を呼ぶ前には`CLEANUP_ENABLED`とscheduled triggerが動作し、最初の不可逆操作より前に`fenced`から別状態へ遷移することが必須。ローカル型検査、保管サービス140試験、合成migration試験、独立安全レビューを通過。Workerコードは未配備・本線未反映。

2026-09-24 JST、保管専用 **staging** D1（`955a8530-9015-486c-8d0c-1b5a2c5b6d4f`）へ0012を適用。事前Time Travel bookmarkは `0000000b-00000000-000050ef-439271be4b66aa56d22c0a3a03b79e10`。事前owner/record/retention/contact/submission/credentialは全て0。適用後は未適用migration 0、`purge_fence_id`・`lease_expires_at`列各1、owner/record/fence 0を確認。本番DBやWorker配備は未変更。

同ブランチでR2一次写真のowner限定 `listOwnerPhotoPage` も追加。R2が上限より少ない件数を返しても `truncated` とcursorで継続し、異なるowner・順序逆転・不正キーを拒否する。現時点では読み取り候補のみで、実R2の棚卸し・D1参照やS3版との全件照合は未実施。

推奨は、保存成功を返す前にD1参照、R2写真、S3復旧コピーの全てを照合すること。S3障害時は新規保存を完了扱いにしない。既存の閲覧・持ち出しは可能にする。バックアップが非同期なら「保管済み」と「復旧コピー完了」を別状態にして、最大損失時間を販売前に明示する必要がある。どちらを採るか、利用者に確認中。

復旧コピーは写真objectだけでは足りない。ownerと認証情報、record ID/版/暗号化本文/写真hashとkey、削除済みID、保管期限、通知、課金ownerとの不変リンクを再構築する最小の整合したmanifestが要る。鍵素材と `IDENTITY_INDEX_SECRET` の保全、復元後の削除済みowner再適用も必須。復旧点から別の環境へ実際に戻し、本文・写真hash・owner隔離を照合するまで「バックアップ完了」と呼ばない。

## 期限消去の実装条件

1. 永続的に巡回するowner単位の候補カーソルを設け、古い不適格ownerが後続を塞がない。候補抽出は削除許可ではない。
2. 候補ごとに非公開課金元から現在の `expired` を再取得する。`unknown`、`active`、`grace`、owner無効、期限episode変更、連絡先変更、時計停止は拒否。課金照会成功時刻を保持し、長い外部I/Oの後は再照会する。
3. `final_notice_receipt` と提出行の `delivery_event_id`、送達時刻、owner、episode、現在の宛先の鍵付き照合値を再照合し、少なくとも30日の猶予を証明する。通知時の期限から30日猶予で延長された現在の期限を扱い、旧期限の単純一致だけを条件にしない。`send()` の受付ID、合成receipt、開封推測だけでは許可しない。
4. 一次・復旧コピーのobject一覧を所有者prefixとmanifestから照合し、削除対象を不変の作業台帳へ記録する。既知のobjectだけを消して「全件」と報告しない。書込中reservation・再送と競合する間は削除しない。
5. 削除開始と更新・課金復帰の競合を閉じる所有者単位のfenceを作る。fence後は新規保管／編集と保管復旧を止め、期限切れ判定と通知証拠を再確認する。失敗時には作業台帳を残し再開可能にする。
6. S3を採る場合、versioning bucketで通常の `DELETE` はdelete markerを追加するだけ。全versionとmarkerを列挙して消去し、Object Lockで削除不能な版を持たないことを確認する。R2もdelete応答だけでなく再list/HEADとDB参照を照合する。
7. 写真・暗号化本文・本人連絡先／credential・token・復旧コピーの消去証跡を分ける。D1 Time Travelなど即時個別消去できない過去状態の最大残存期間を明示し、復元時は削除台帳を再適用する。保存件数0だけでは完了としない。
8. 復帰・誤判定・外部失敗の試験を先に実施し、実2端末で期限中の書き出し・復元を検証するまで、自動消去のflagはOFF。

## 次の実装単位と受入証拠

- まず保存と独立復旧コピーの整合した契約、owner単位の可観測な状態、障害時fail-closed、復元fixtureを実装する。モックだけで本番復旧済みと表示しない。
- 次に削除対象inventory・課金／通知の再照合・owner fence・各コピー消去の冪等作業台帳を実装し、継続課金／課金不明／通知未達／復旧コピー欠落／途中失敗を境界試験する。
- 実環境のKMS/R2/S3、通知ドメイン、Apple本人確認、2端末復元、容量別のZIP持ち出し、削除／復元演習が成功して初めて有効化判断を行う。

## 公式仕様の確認先

- [Amazon S3のversion別削除](https://docs.aws.amazon.com/AmazonS3/latest/userguide/DeletingObjectVersions.html)：通常の削除マーカーは実体消去ではない。
- [Amazon S3 Object Lock](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html)：compliance modeの保護版は期限前に削除できない。
- [Cloudflare R2料金](https://developers.cloudflare.com/r2/pricing/)：一次コピーと12か月持ち出し期間の費用を容量実測後に評価する。
- [既存の保持・鍵判断](2026-09-23-preservation-retention-key-decision.md)：利用者指定の12か月と通知条件、実環境の未確認事項。
