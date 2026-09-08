# Build 134: block withdrawal on the existing sharing Worker

This branch is a server-only backport. The iOS release candidate is
`e78495b8599af570a3a5b71dfbcc98462cf32593` on `codex/testflight134`.
Do not merge this older repository snapshot over current main or build its iOS app.

## Live baseline and scope

The active staging Worker was downloaded through Wrangler on 2026-09-08.
Version `68f8c519-7f80-43c9-ad16-0cffccd0c531` matches a bundle built from
`3690332` except for the received-moment `sequence: row.sequence` field already
implemented in `742616d`, generated bundle names, and the source map comment.
An independent comparison checked the complete bundle and the relevant modules.

The D1 database has migrations 0001–0018. It does not have the billing schema.
Deploying current main's Worker would require unrelated billing tables in health
and scheduled cleanup. This branch preserves the live health, cron and runtime
gate code and adds only:

- the existing sequence field;
- the block-withdrawal capability and route from the iOS candidate's server code;
- migration 0026 and its integration tests.

Old clients can continue using their existing block request. Only blocks created
with the new capability can be withdrawn; withdrawal does not resume sharing or
restore photos, old credentials or pending deliveries.

## Validation and rollout

Local typechecking and all 33 moment integration tests pass with migrations
0001–0018 plus 0026. Independent review found no blocking issue. Run the existing
server CI on this exact commit before deployment. No iOS CI is needed for this
server-only branch; the mainline iOS candidate has its own CI.

The first remote migration attempt rolled back with `incomplete input`. Its
unparenthesized CASE expression violated the existing Cloudflare-compatibility
rule, but 0026 had not been registered in that check. CASE is now parenthesized,
0026 is registered, and the check requires every migration file to be listed.
This changes SQL parsing compatibility only; the trigger condition is unchanged.

Use the live downloaded bindings, vars and three cron expressions in an ignored
deployment config. Preserve media/APNs ON, report OFF at runtime gate generation 5,
the three rate limiters, the two private R2 buckets, and existing APNs secrets.
Recheck active version and D1 identity before applying only pending migration 0026,
then deploy this branch's Worker. Do not apply billing migrations 0019–0025.

Afterward verify the migration receipt/table/triggers, unchanged runtime gate,
public health and unauthenticated endpoint boundaries, and new active version.
An unauthenticated withdrawal request must return 401 without changing any block.
The real block → withdraw → fresh invitation path is checked after internal
TestFlight availability, using a disposable test sharing window.

If the Worker update needs rollback, restore the recorded previous version while
retaining additive migration 0026. Do not drop the table or modify runtime gates
as routine rollback. Do not distribute Build 134 while its server route is absent.

The private release handoff records exact CI runs, remote versions and rollout
results. External invitations and review submission are outside this release.
