# Purchase connection: family adapter and private gateway

## Changed behavior

The deployed family v5 Worker lacked billing routes. Its exact downloaded module
is retained as immutable input; only `/v1/billing` traffic is delegated to the
named private Sandbox gateway. Existing family/photo fetches, `/health` and all
family schedules remain with the old implementation. No native UI, Widget,
production purchase, public enrollment or actual charge changes are included.

The gateway is public-default 404, workers.dev/preview disabled, Sandbox only,
explicit route/method allowlist, existing authentication/body/nonce ordering,
and eight runtime upper gates all OFF. It uses the existing billing database and
private verifier binding, with no photo buckets. Existing database generation 0
and all eight lower gates were read-only confirmed OFF; no migration was needed.

## Direct evidence and uncertainty

- Original deployed module: 362790 bytes, SHA-256
  `1007ddf74044922ef7dcd2ec34c858d6f31cb53cea374be6c14645bb28ac68c6`.
  Historical TypeScript rebuild equality is unresolved, so it is not substituted.
- Real workerd: original/new health and family/nonbilling responses match;
  billing alone reaches a private binding without changing signed body bytes.
- Real workerd gateway: public/Production denied, explicit gates, bounded stream,
  Ed25519 authentication, repeated nonce rejected. Typecheck and both Worker
  dry-runs passed. Config mapping rejects unknown/duplicate database bindings.
- Independent source/config and CI reviews are recorded in the primary task.
- Remote verifier bad-JWS/HMAC/replay probe already passed and finished OFF in
  39 seconds. Its unchanged tree is retained, not tested again here.
- Real Apple purchase, restore and expiry remain unverified. Paid Apps Agreement
  was pending user information; tax information incomplete and bank processing.
  Backend success is not completion of these external requirements.

## Candidate and verification cost

Overall first product candidate: 2026-10-01 18:29:38 JST. Gateway first candidate:
19:48:31 JST. Changing checkout/scope does not reset cumulative time.

Required candidate checks: private gateway/caller Node job, preservation Node
job and iOS selector. Frozen `billing-private-service-v2` binds 12 product paths,
the complete four backend trees, workflow and all four CI companions. Changed
or unknown inputs return to the broader selector and must be investigated
before running it. No native/Widget job or TestFlight upload is required.
Earlier backend runs took 50–74 seconds; this new scope is unmeasured, with
five-minute job execution ceilings plus runner queue time. Full CI is not the
first probe: runtime and config observations above precede the candidate run.

The first planner test run passed 86 unchanged cases; one new expectation used
the wrong API signature and retained an obsolete job tuple. Those test-only
expectations were corrected and the one boundary case passed. The product was
not changed to satisfy this test failure. Other independent CI control checks
were run concurrently locally to avoid the prior sequential waiting cost.

## Deployment boundary

Parent chat alone owns candidate CI and remote deployment. Capture and compare
fresh actual family settings/active version before replacing its entrypoint.
Preserve all existing secrets, vars, database, buckets, rate limits, compatibility
and schedules, adding one named private binding. Install the existing encrypted
staging HMAC in the new private gateway, retaining the same verifier key.
Check unchanged public family health, separate billing health, OFF mutation
rejection and actual deployed configuration after connection. Do not activate
production, general registration, purchase or upload another native build.
