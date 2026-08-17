# ねこのまど SharingService

Cloudflare Workers + D1 + R2を前提にした、招待制共有のserver componentです。現在の実装範囲はPhase 1（pairing）だけです。Productionへのdeploy、D1/R2の作成、secret設定は行っていません。

## Phase 1で成立すること

- 氏名、mail、password、電話番号、global installation IDを作らず、spaceごとの鍵だけで二台をpairingする。
- 32-byteのinvite secretをEd25519 seedとして端末内で使い、serverへは導出したinvite-proof public keyだけを送る。
- Server challengeへinvite-proof keyとinviteeのspace固有signing keyの両方で署名する。Raw secret、secret digest、HMAC verifierはHTTPにもD1にも出ない。
- 両端末のidentityを同じbinary transcriptへ固定し、verification phrase照合後にinviterだけがroom-key envelopeを承認できる。
- Member requestはEd25519署名、5分のclock skew、16-byte nonceで認証する。Bearer tokenは使わない。
- Invitation、challenge、pending enrollmentにはTTLがあり、一回限りのstate transitionをD1 triggerとtransactionで守る。
- 同じ`clientRequestId`と同じrequest bytesのretryは同じ結果を返し、異なるpayloadでの再利用は`409`にする。
- 共有解除では最初にspaceと全memberを失効し、Phase 2以降がR2/D1物理削除を続けるための`space_deletion_jobs`を同じtransactionで作る。
- Idempotency responseは48時間、active space metadataは最後に受理した操作から30日を上限にし、hourly cleanupで物理削除する。

Phase 1は写真、render plan、reactionを一切受け取りません。`MEDIA` R2 bindingはPhase 2の拡張点としてexample configにだけ置いています。

## API contract

すべてのresponseはJSONで、`Cache-Control: no-store`です。Error shapeは次のとおりです。

```json
{"error":{"code":"stable_machine_code","message":"Human-readable message"}}
```

成功responseの正本は[`pairing-api-v1-responses.json`](../ci/fixtures/pairing-api-v1-responses.json)、Swift/Worker共通canonical vectorの正本は[`pairing-protocol-v1.json`](../ci/fixtures/pairing-protocol-v1.json)です。

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

`17 * * * *`のscheduled handlerは、期限切れnonce、48時間を過ぎたidempotency response、30日間受理されたactivityがないPhase 1 space metadataをoldest-firstで削除します。1 runはnonce/idempotency各1,000 row、pairing expiry/inactive space/deletion job各90 spaceまでに制限し、公開creationへのabuseで巨大な全表transactionが毎回rollbackすることを防ぎます。上限を超えたbacklogは次のhourly runへ持ち越すため、Productionでは残件数/最古期限の監視をdeploy gateにします。

Activityを延長するのは、認可され成功したstatus/pending/approve/completeと、同じ成功responseを返すlive memberのidempotent retryです。署名だけが正しいsemantic error、expired/revoked/cancelled member、cancel/revokeのterminal操作はowner spaceのTTLを延長しません。D1のactivity update自身もmemberとspaceがliveか再確認するため、handlerが読んだ直後の失効raceでも延長できません。

Scheduled cleanupは最初にspace/member credentialと未完了pairing materialを失効させ、`space_deletion_jobs`を通してからD1 metadataを物理削除します。Phase 1はR2 objectを持たないためjobも同じrunで消えます。Phase 2以降は`requires_object_deletion=1`のjobを残し、R2削除完了までspace metadataの物理削除をgateできます。

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

`npm run check`はTypeScript strict check、Cloudflare Workers runtime、D1 migration、Ed25519 happy path、invalid invite proof、nonce replay、idempotent retry、pending invitee revoke rejection、cancel/complete race、completion/cancel時のenvelope削除、atomic challenge cap、revoke、48時間/30日retention cleanup、revoked memberがTTLを延長できないこと、Swiftと共通のgolden vectorを検証します。

Local Workerを起動する前にmigrationを適用します。

```sh
npm run db:migrate:local
npm run dev
```

## Productionへ進める前のgate

[`wrangler.example.jsonc`](wrangler.example.jsonc)をcopyし、D1/R2 identifierとaccount固有rate-limit namespaceを設定します。このrepositoryにはProduction credentialや`.dev.vars`をcommitしません。Deploy scriptも意図的に定義していません。

Phase 2では同じspace/member/auth/idempotency基盤へdaily generation draft、canonical R2 object、commit、30日TTLを追加します。R2 upload/downloadは短時間credentialまたはsigned URL相当の方式とし、canonical本文を通常Worker logやD1へ入れません。
