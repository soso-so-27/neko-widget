# ねこのまど SharingService

Cloudflare Workers + D1 + private R2を前提にした、招待制共有のserver componentです。Phase 1（pairing）とPhase 2（日次の暗号化canonical set同期）を実装しています。Productionへのdeploy、D1/R2の作成、secret設定は行っていません。

## Phase 1で成立すること

- 氏名、mail、password、電話番号、global installation IDを作らず、spaceごとの鍵だけで二台をpairingする。
- 32-byteのinvite secretをEd25519 seedとして端末内で使い、serverへは導出したinvite-proof public keyだけを送る。
- Server challengeへinvite-proof keyとinviteeのspace固有signing keyの両方で署名する。Raw secret、secret digest、HMAC verifierはHTTPにもD1にも出ない。
- 両端末のidentityを同じbinary transcriptへ固定し、verification phrase照合後にinviterだけがroom-key envelopeを承認できる。
- Member requestはEd25519署名、5分のclock skew、16-byte nonceで認証する。Bearer tokenは使わない。
- Invitation、challenge、pending enrollmentにはTTLがあり、一回限りのstate transitionをD1 triggerとtransactionで守る。
- 同じ`clientRequestId`と同じrequest bytesのretryは同じ結果を返し、異なるpayloadでの再利用は`409`にする。
- 共有解除では最初にspaceと全memberを失効し、Phase 2以降がR2/D1物理削除を続けるための`space_deletion_jobs`を同じtransactionで作る。
- Idempotency responseは48時間、active space metadataは最後に受理した操作から30日を上限にし、5分間隔のcleanupで物理削除する。

Phase 1は写真、render plan、reactionを一切受け取りません。

## Phase 2で成立すること

- Pairing済みのactive memberは各自1つだけ、server-bound sourceを持てる。二人ともpublishでき、Widgetは同じsourceを明示選択して同じ日次20枚を巡回する。
- ServerがspaceのUTC境界から`shareDayKey`を決め、`UNIQUE(source, day)`で1日1回のfreezeを守る。欠けた日のcatch-upはしない。
- 1 generationは1〜20個のunique `mediaId`だけを持つ。重複slotと順番、render plan、pixel寸法、構図hashは暗号化manifestの中にだけ置く。
- Canonical previewは写真ごとに1つだけ。ChaChaPoly combined ciphertext全体を300KiB以下、manifest ciphertextを64KiB以下に制限する。原本、PhotoKit ID、撮影日、EXIF/GPS、plaintext/JPEG hashは受け取らない。
- `reserve → immutable descriptor → media upload → prepare attempt → encrypted manifest → atomic commit`の順に進む。不完全な新generationは旧currentを置き換えない。
- Prepareはserver時刻から5分以上先にある最初の20分境界を返す。期限切れattemptは同じmediaを再利用して再prepareできるが、attempt ID/revision/anchorを変えてmanifestを再暗号化する。
- Upload/downloadはsigned member requestを通すWorker proxyだけ。R2 object key、public bucket URL、presigned URLをclientへ返さない。
- APNs、device token、global installation IDを使わない。同期はapp/widget側の明示的なpollだけで行う。
- Revoke/inactivityは最初にcredentialを無効化する。開始済みPUTの最大猶予後にexplicit object deletionとopaque space-prefixの複数回sweepを行い、R2が空になるまでD1 metadataを消さない。

## API contract

すべてのresponseはJSONで、`Cache-Control: no-store`です。Error shapeは次のとおりです。

```json
{"error":{"code":"stable_machine_code","message":"Human-readable message"}}
```

Pairing成功responseの正本は[`pairing-api-v1-responses.json`](../ci/fixtures/pairing-api-v1-responses.json)、日次共有responseの正本は[`sharing-api-v1-responses.json`](../ci/fixtures/sharing-api-v1-responses.json)です。Swift/Worker共通canonical vectorは[`pairing-protocol-v1.json`](../ci/fixtures/pairing-protocol-v1.json)と[`sharing-protocol-v1.json`](../ci/fixtures/sharing-protocol-v1.json)です。

| Method | Path | 認証 | 用途 |
|---|---|---|---|
| `POST` | `/v1/spaces` | creation signature | Space、owner、one-time invitationを作る |
| `POST` | `/v1/invitations/{id}/challenges` | opaque invitation ID + transient rate limit | 5分challengeを作る |
| `POST` | `/v1/invitations/{id}/enrollments` | invite-proof + invitee signature | Invitationを一度だけpending enrollmentへ変える |
| `GET` | `/v1/pairing/pending` | owner signed request | 承認待ちidentityとtranscriptを読む |
| `GET` | `/v1/pairing/status` | member signed request | Pairing stateと、inviteeだけに承認済みenvelopeを返す |
| `POST` | `/v1/pairing/enrollments/{id}/approve` | owner signed request + approval signature | Envelopeを承認する |
| `POST` | `/v1/pairing/enrollments/{id}/complete` | pending invitee signed request | 復号・保存後にmemberをactive化し、server上のenvelopeを消す |
| `POST` | `/v1/pairing/enrollments/{id}/cancel` | pending invitee signed request | 自分の未完了enrollmentだけを取り消し、envelopeとchallengeを消す |
| `POST` | `/v1/pairing/revoke` | active member signed request | Space全体を即時失効し削除jobを作る |
| `POST` | `/v1/sharing/generations/reserve` | active member signed request | Server dayへunique media ID集合をfreezeする |
| `POST` | `/v1/sharing/generations/{id}/descriptors` | publisher signed request | Ciphertext size/SHA-256を一度だけ登録する |
| `PUT` | `/v1/sharing/generations/{id}/media/{mediaId}` | publisher signed request | 300KiB以下のcanonical ciphertextをprivate R2へproxyする |
| `POST` | `/v1/sharing/generations/{id}/prepare` | publisher signed request | Latest prepare attempt、reserved revision、20分anchorを確定する |
| `PUT` | `/v1/sharing/generations/{id}/prepares/{attemptId}/manifest` | publisher signed request | 64KiB以下のencrypted manifestをproxyする |
| `POST` | `/v1/sharing/generations/{id}/commit` | publisher signed request | Latest verified attemptだけをatomicにcurrentへ切り替える |
| `GET` | `/v1/sharing/generations/{id}` | publisher signed request | Draft/prepare/upload状態を再開する |
| `GET` | `/v1/sharing/sources` | active member signed request | Space内sourceとcurrent summaryを読む |
| `GET` | `/v1/sharing/sources/{id}/current` | active member signed request | Current descriptorを読む。`If-None-Match`で`304`対応 |
| `GET` | `/v1/sharing/generations/{id}/manifest` | active member signed request | Current encrypted manifestだけをproxyする |
| `GET` | `/v1/sharing/generations/{id}/media/{mediaId}` | active member signed request | Current canonical ciphertextだけをproxyする |

Pending inviteeはspace全体をrevokeできません。`cancel`はpendingまたはapproved-before-completionのinvitee本人にだけ許可し、owner spaceはactiveのまま残します。同じrequestのretryは取消後も48時間のidempotency window内なら同じ`202`を返します。Completionが先に成立したraceは`409 invalid_pairing_state`です。

### Invite code

Clientはrandom 32 bytesを作り、次のcodeを表示します。

```text
NW1.<server-generated invitation ID>.<base64url raw 32-byte secret>
```

Raw secretはdeep-link fragmentまたはQR内だけに置きます。Clientはsecretを`Curve25519.Signing.PrivateKey(rawRepresentation:)`へ渡し、`POST /v1/spaces`にはpublic keyだけを送ります。

### Signed member request

Headerは次の5個です。

```text
Neko-Protocol-Version: 1
Neko-Member-ID: <22-character base64url ID>
Neko-Timestamp: <Unix seconds>
Neko-Nonce: <base64url 16 bytes>
Neko-Signature: <base64url Ed25519 64-byte signature>
```

署名対象は、次の各UTF-8 fieldを順にUInt16 big-endian length prefixして連結したbytesです。

```text
NW1.REQUEST
1
memberId
timestamp
nonce
UPPERCASE_METHOD
exact URL pathname
base64url(SHA256(exact HTTP body bytes))
```

API base URLはorigin rootに固定し、path prefix、query、fragmentを許可しません。これによりClientとWorkerが署名するpathnameがずれません。

### Pairing transcriptとapproval

Enrollment transcript、pairing verification transcript、request transcriptのfield順は共通golden vectorで固定しています。JSON field orderやlocaleへ依存しません。

Room-key envelopeは`X25519-HKDF-SHA256-CHACHA20POLY1305`の60 bytesです。Inviterは次をlength-prefix encodingしてEd25519署名します。

```text
NW1.APPROVE
1
pairingTranscriptHash
X25519-HKDF-SHA256-CHACHA20POLY1305
base64url key envelope
```

Serverも署名を検証しますが、inviteeはstatus responseの`approvalSignature`をinviter public keyで再検証してからAEADをopenします。Completion後、revoke後、またはpending expiry後はenvelopeとapproval signatureをD1から消します。

## D1 state safety

[`0001_pairing.sql`](migrations/0001_pairing.sql)のtriggerが次をtransaction内で行います。

- Validなlive invitation + single-use challengeだけを`pending` enrollmentへ変える。
- Enrollment insertと同時にinvitation proof public keyを削除し、他のchallengeを無効化する。
- Active ownerだけがpending enrollmentをapproveできる。
- Approved invitee本人だけがcompletionできる。
- Pending invitee本人だけが自分の未完了enrollmentをcancelできる。
- Active memberだけがspace全体をrevokeできる。
- Revokeと同時に全credential access、invitation、pending、envelopeを失効する。

Consumed challenge rowはpending pairing中だけ残ります。Completion、pending expiry、revokeでは`ON DELETE SET NULL`によりenrollmentの参照整合性を保ったまま削除します。

## Retention cleanup

`*/5 * * * *`のscheduled handlerは、期限切れnonce、48時間を過ぎたidempotency response、30日間受理されたactivityがないPhase 1 space metadataをoldest-firstで削除します。1 runの上限はnonce 10,000 row、idempotency 2,500 row、daily freeze 1,000 rowです。IDを`IN`へbindするpairing expiry／inactive space／deletion jobは90 spaceに限定し、D1の100 bound parameter上限へ10枠を残します。各stageは小さいchunkをcommitしてから次へ進むため、途中で停止しても次のrunがDB上のoldest rowから再開します。

ProductionはWorkers Paidを前提とし、設定でCPU 30秒、subrequest 1,200を上限にします。最悪構成でもD1 queryは900/invocation未満、R2 multi-delete/listは公式上限の1,000 key/call以下です。5分runは一日288回なので、nonceは最大288万row/day（想定約48万/day）、明示object deletionは最大691.2万key/day（10,000 publishing sourceが旧20 canonical + manifestを全交換する21万key/day）を処理できます。Production deploy gateではCron CPU 30秒未満、D1 query 1,000未満、残件数、最古`not_before`／expiry、実`rows_written`をload testと運用monitorで確認します。Workers Freeはrequest、D1 write、CPUのいずれもこの規模のProduction対象ではありません。

実行上限の正本は[Workers limits](https://developers.cloudflare.com/workers/platform/limits/)、[D1 limits](https://developers.cloudflare.com/d1/platform/limits/)、[R2 Workers API](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/)とし、Production deploy前に再確認します。

Activityを延長するのは、認可され成功したstatus/pending/approve/completeと、同じ成功responseを返すlive memberのidempotent retryです。署名だけが正しいsemantic error、expired/revoked/cancelled member、cancel/revokeのterminal操作はowner spaceのTTLを延長しません。D1のactivity update自身もmemberとspaceがliveか再確認するため、handlerが読んだ直後の失効raceでも延長できません。

Scheduled cleanupは最初にspace/member credentialと未完了pairing materialを失効させ、`space_deletion_jobs`を通してからD1 metadataを物理削除します。Phase 1はR2 objectを持たないためjobも同じrunで消えます。Phase 2以降は`requires_object_deletion=1`のjobを残し、R2削除完了までspace metadataの物理削除をgateできます。

Phase 2 draftのaccess TTLは最大60分か当日境界の早い方、current contentはcommitから最大30日です。Generation close後は新しいPUTを拒否し、10分のin-flight猶予を置いてからobjectを削除します。5分Cronが正常稼働しbacklogがない場合、staging objectは作成から最大約75分で物理削除されます。10,000 sourceが同時に最大21 objectをqueueする負荷でも、generation close 10,000/run、object 24,000/runにより9 run（45分）で排出し、60分access TTLと10分猶予を含め作成から約2時間以内を維持します。Terminal generationと`cleanup_blocked` sourceは各1,000/run、revoke prefixは50 space/runです。障害時もaccessは60分でfail closedし、exact `(object_key, attempts)` CASによる物理削除をbounded retryします。通常rotation/expiryの削除中はsourceを`cleanup_blocked`にして、current 20 + staging 20を超える次のreserveを止めます。

## Rate limitとlogging

Production exampleはCloudflare Rate Limiting bindingを三つ使います。

- Space creation: source networkごとに5/min
- Challenge/enrollment: source network + invitationごとに10/min
- Signed member API: source networkごとに120/min

Network addressはrate-limit bindingのtransient keyにだけ渡し、D1へ保存しません。Bindingはper-locationかつeventually consistentなので、正確なquotaやone-time enforcementには使わず、D1 constraint/triggerを正本にします。

Workers Logs/Traceはexampleで無効です。Codeはrequest body、header、public key、signature、network addressを`console`へ出しません。Productionでrate-limit bindingが欠けた場合はfail closedで`503`にします。

## Local verification

Node.js 22以降で実行します。

```sh
npm ci
npm run check
```

`npm run check`はTypeScript strict check、Cloudflare Workers runtime、D1 migration、Pairingのsecurity/race/retention、日次reserveからprivate R2 upload・atomic commit・conditional/current downloadまでのhappy path、partial/tamper/size cap、双方向publisherの共通opaque prefix、revoke deletion gate、bounded cleanup、Swiftと共通のgolden vectorを検証します。

Local Workerを起動する前にmigrationを適用します。

```sh
npm run db:migrate:local
npm run dev
```

## Productionへ進める前のgate

[`wrangler.example.jsonc`](wrangler.example.jsonc)をcopyし、D1/R2 identifierとaccount固有rate-limit namespaceを設定します。このrepositoryにはProduction credentialや`.dev.vars`をcommitしません。Deploy scriptも意図的に定義していません。

R2 bucketはpublic access/custom domainを無効のままにし、Worker bindingからだけ到達させます。Canonical ciphertext本文は通常Worker logやD1へ入れません。Production deploy前にはD1/R2 identifier、rate-limit namespace、R2 public access無効、Cron、削除backlogの最古時刻をreviewします。
