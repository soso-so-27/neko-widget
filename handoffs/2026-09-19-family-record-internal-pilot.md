# Private-window family records: internal pilot

This batch connects the existing private window to an independent encrypted record
catalog. It does not turn the delivery inbox/TTL into a long-term original or
provide all-device-loss recovery. The initial implementation handoff below preceded
deployment; the root completed the internal worker rollout on 2026-09-19.

## Current delivery status (2026-09-19)

App `04e637b` / TestFlight 1.0 (190) uploaded to Apple at 23:17:18 JST, run
`35447825611`. Candidate full-v1 `35444894339` passed; main reused that exact
SHA in `35447741311`. Native family runtime/UI passed. Apple processing and real
two-device synchronization have not been confirmed.

Separated worker source `1986ccd` is deployed as version
`64707b0f-e436-49ad-858d-88c8d2f61a06`, internal family gate YES. Only migration
0027 was applied; unrelated billing migrations/code were not deployed. Authenticated
dashboard inspection confirmed no completed-object expiration rules on MEDIA:
only incomplete multipart uploads are aborted after 7 days. Public access remains
disabled. Prior bindings, secret binding names and three crons remain unchanged.
Health returned 200; family records and existing delivery rejected unsigned requests
with 401. No real customer records/photos were created or deleted by verification.

## Implemented path and boundaries

After authenticated capability confirmation, the private window exposes 共同記録.
The user explicitly selects an image and up to 500 Swift graphemes. No private
memo, PhotoKit identifier, local record UUID, path or cat identity is copied.
Image ingress strips metadata using the existing service; outbound and inbound
images use the existing sensitivity moderation. Only a display JPEG is retained.

Photo and words have separate author-owned IDs/revisions. Either person may append
their own words; only their author may edit/withdraw them. A photo withdrawal keeps
all words, including the photo author's own words. CAS conflicts retain the draft.
Retry uses a fixed operation ID, encrypted bytes and sorted JSON. If the photo is
confirmed before words fail, the editor says so and retries only the unfinished
operation. This is not an atomic two-record addition. A cancelled editor never
withdraws an already confirmed photo implicitly.

The client uses the existing signed ephemeral no-redirect transport and validates
the active private window, media consent and lifecycle token before and after
awaits. AAD binds window, author, record, parent, kind and revision. The server
checks current participant/device/space/block/key epoch, including inside its D1
mutation batch. It does not accept a restored snapshot as membership or revive a
tombstone. The current epoch-1 limitation matches the existing moment client;
unknown epochs fail closed instead of trying another room key.

Reopening fetches the current catalog, including the author's own records. This
supports currently authorized additional devices that still have the matching
room key. It does not recover missing participant credentials/keys. Offline access
is not granted from a local cache. Backgrounding clears shared display but keeps
the unsent editor draft; temporary inactive state from PhotosPicker does not dismiss
the editor. Remote changes become visible on refresh/foreground/current sync;
previously delivered bytes or explicit personal copies cannot be recalled.

## Server deployment boundary (root owns application)

Production worker currently predates unrelated main billing work. Prepare a
separate candidate from deployed `d4ecc3d`, carrying only:

- `src/family-records.ts`, `migrations/0027_family_records.sql`.
- `src/env.ts`: `FAMILY_RECORD_RUNTIME_ENABLED?: string`.
- `src/index.ts`: family imports, route gate/dispatch, withdrawal cleanup in the existing moment cron.
- `test/family-records.integration.test.ts` for local verification.

Do not deploy main's unrelated billing routes/configuration. Use the existing
internal worker, D1 and R2 bindings; no new service/account/auth system is required.

1. Keep `FAMILY_RECORD_RUNTIME_ENABLED` absent or `NO`; it is independently OFF.
2. Verify the deployed migration ledger and apply the additive family table migration
   without opportunistically applying unrelated pending migrations.
3. Verify the existing R2 lifecycle rules. `family-records/v1/` must not match a
   delivery TTL expiration rule or a bucket-wide expiration rule. An inability to
   inspect those rules is a blocker to enabling this feature. Existing delivery
   cleanup prefixes do not authorize deletion of this new prefix.
4. Review/deploy the separated worker with the gate still OFF. Its cron must have
   the new tables before it runs `runFamilyRecordCleanup`.
5. After backend/native regression and internal configuration review, set the exact
   value `YES` only on the existing internal pilot. The existing moment upper gate
   and D1 media lower gate must also be ON. The app shows no entry while capability
   is absent/unavailable; disabling the gate stops ordinary reads/writes while
   scheduled withdrawal cleanup remains active.

The pilot permits 100 photo records and 1,000 word records per private window,
including tombstones. Capacity rejects additions; it does not evict old records.
Photos use a dedicated R2 prefix, words use encrypted D1 values, and withdrawal
object deletions are queued atomically with the tombstone. Ambiguous D1 writes
never trigger deletion of a possibly committed object. A process interruption
before D1 commit may leave an inaccessible orphan ciphertext; an operational
orphan sweep/retention policy is still needed before a wider service launch.

Catalog rows deliberately do not cascade with expired delivery spaces. If pairing
expires or the space ends, the retained catalog is not sufficient to authorize
retrieval. No indefinite retention, service-closure recovery or access after
space termination is promised. Determine those policies before a paid/wider offer.

Family records do not have delivery moment IDs, so existing photo-report evidence
submission cannot yet report one of these records. Existing moderation/block/access
revocation remains enforced. A dedicated report/evidence path is a prerequisite
for external rollout; this gate is an internal pilot only.

## Verification

- `npm run typecheck`: production and integration test TypeScript passed.
- `npx vitest run test/family-records.integration.test.ts`: 5 passed. Actual signed
  authentication, D1 and R2 test bindings; author/withdrawal/restore/replay/conflict/
  cross-space/ended-space/block/gate boundaries. No deployed endpoint was called.
- `test-diagnostic-log-privacy.py`: 13 cases, 1 existing skip, passed.
- `verify-family-records.swift`: registered in existing ios-build core validation;
  grapheme limit, authenticated context substitutions, ciphertext tampering,
  tombstone preservation and catalog identity. Native execution pending on Mac.
- `FamilyRecordUIFixture`: actual product view/editor with injected in-memory
  authority and a fake image chooser; no real store/Keychain/Photos/network. Root
  owns the single UI regression wiring. This fixture does not prove system
  PhotosPicker behavior or production two-device synchronization.

Native family UI, R2 lifecycle configuration and internal worker rollout are now
verified as described above. Actual two-device service synchronization remains
unverified. The report/evidence and retention/recovery limitations above still
apply; this is not authorization or readiness for external rollout or billing.
