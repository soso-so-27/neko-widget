# Photo recovery and continuity integration

Base: freshly fetched main `c12ff935a1dfd3656d709237a6984b223aca5bd5`.
Branch: `codex/photo-recovery-continuity-20261005` in a separate clean worktree.
The original checkout and the source-candidate worktrees are unchanged.

## Candidate and evidence

- Integrates `2e2ca9e`, `d4d3151`, `0e19b09`, `3d0adf1`, and `4611850`.
  The two predecessor commits are required parts of candidate `3d0adf1`.
- Memo loading distinguishes pending, absent and failed reads; a read-only retry
  and request-token reducer preserve saved content and photo identity.
- Partial initial-scan failure retains available photos and offers rescan without
  continuing to display an in-progress indicator.
- Single preservation-record access reads only the requested JPEG while using
  the same materialization, digest, partial-image, tombstone and account checks.
- Related photos have a dedicated accessible menu. Portable cat/photo transfer
  requires explicit selection and revalidation; no local PhotoKit ID or pixels
  are exported. The existing-profile notice now explains photo-only additions.
- Synthetic membership and operating-readiness checks remain local. Startup
  identity-failure tests prove store byte preservation/reread, not an automatic
  application-startup repair. No server deployment or intake change is included.

Direct evidence before native CI: clean cherry-picks, source/data-boundary review,
9 Photos-bootstrap tests, service typecheck, 6 operating-advisory Node tests and
targeted Workerd tests. Native Swift execution/rendering is unavailable locally;
the new Swift verifiers are mandatory in Build CI. The related-photo UI test
captures normal and maximum-text rendering and checks destinations/return scope.
Use the existing focused diagnostic for that method before the complete graph.
Failure-message rendering and two-device photo transfer remain separate device
observations; do not describe code review or synthetic tests as those observations.

## Cost and required route

Record all candidate/diagnostic runs and real times outside the repository under
`C:/dev/neko-evidence/photo-recovery-continuity-20261005/`. Source-candidate dates
precede this integration batch; preserve them in the evidence rather than resetting
the elapsed-time clock after a retry. First integrated candidate is `d29a8d4`.

Mandatory local development checks -> fixed-SHA focused related-photo diagnostic
-> distribution-inclusive preflight -> one required candidate push CI -> merge
commit -> existing owner-only internal TestFlight CLI. Required service CI is
separate from iOS evidence. No measurement-only CI or unchanged-code reruns.

This batch changes photo-membership application and AppViewModel identity/snapshot
inputs used for photo and Widget selection, beyond the existing private-memo-only
scope. The current selector requires full-v1; retain its mandatory graph rather
than manually skipping it. Prior comparable full CI was 78m05; historical maximum
in the existing timing baseline is 97m55. Upload observations are approximately
8-13 minutes. With focused UI preparation, plan approximately 100-125 minutes
for CI and upload, using a 150-minute planning ceiling, not a speedup claim or
guaranteed delivery time. Identify the first actionable failure before any retry.

Preservation pilot settings and self-only TestFlight group stay as in build 238.
No paid intake, public release, external testers, new permissions or cloud writes.
