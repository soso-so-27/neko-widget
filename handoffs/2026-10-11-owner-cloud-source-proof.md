# Fixed source backend inventory correction

The original Sharing run `38120852416` at source
`5a2a7dea45265e9e6b5d382e1aa761bc43ad087b` contains four executed checks
plus conditional job `114415116222`, `Validate private billing caller`.
That fifth job is completed/skipped with no steps. The API inventory includes
it, so the previous four-job inventory check rejected the otherwise accepted
fixed source proof.

The correction requires exactly five unique jobs, all bound to that source,
run, and attempt 1. It excludes only the exact named and numbered placeholder
after checking completed/skipped and empty steps. The original four executed
checks still require their existing successes or the exact diagnosed Worker
failure. Missing, extra, substituted, or skipped executed checks fail closed.
The placeholder supplies no successful-check evidence.

Original runtime evidence remains attributed to its original SHA. Fresh full
Build and all five owning backend checks remain required at the new candidate
SHA. Original failures, active runs, elapsed time, closure pins, and release
proof requirements are unchanged.

Validation: `python -B NekoWidget/ci/test-plan-ios-ci.py OwnerCloudCorrectionTests`
passed seven tests. The five-job fixture and negative identity, inventory,
state, steps, and executed-job-skip cases are included. No CI, remote writes,
commit, or push was performed. The control change requires independent review
and main approval before product use.
