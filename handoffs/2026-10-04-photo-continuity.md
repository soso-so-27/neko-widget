# Photo continuity development candidate

Worktree: `C:/Users/soya_/Documents/Codex/2026-10-04/task-2/neko-five-improvements`.
Branch: `codex/photo-continuity-20261004`, base main `3809e5b`.
Existing PR #165 (`2b56a8e`) and the original checkout/candidate branches are
untouched. PR #165 is owned by the existing regular Codex task; this task does
not monitor, retry or cancel its CI.

The requested five areas are developed here as separate changes:

1. Existing profile transfer gains an optional portable metadata manifest and
   explicit photo confirmation on the receiving phone. No image or PhotoKit ID
   is in the file. Permission/missing photos, duplicate matches, old-v1 files,
   state conflicts and excluded photos remain fail-closed. See
   `profile-photo-transfer-20261004.md` for the exact supported transfer scope.
2. Related photos were mixed with editing/export/preservation in the overflow
   menu. A dedicated visible "見返す" menu uses the existing routes and current
   cat scope. No new album generation, ranking or automatic identity inference
   is added. Related-photo UI regressions now open this direct entry.
3. Related-photo controls expose group and destination in their accessibility
   labels. Memo-row content is combined and explains that the link opens the
   full memo. The original photo-action menu remains separately labelled.
   Transfer candidates have numbered controls and selection state.
4. The existing membership-to-archive test gains a continuous synthetic
   active/cancellation-before-expiry/expired/unknown/restored-owner flow. Real
   StoreKit purchase, sheet cancellation and restoration are separate evidence.
5. Local operating-evidence review checks fresh counts, retained owners,
   historical recovery storage, cost and Sandbox evidence. It has no remote
   writes, notification or deletion authority. Current retention implementation
   and published contract agree on 12 calendar months and the final delivered
   notice's additional 30-day floor. See billing-retention readiness handoff.

Independent reviews: main reviewed transfer and backend changes; backend
implementer reviewed the navigation/accessibility changes. Transfer review
identified and fixed subsecond timestamp round-trip loss. Invalid plan values
in the advisory review now stop readiness. These reviews do not prove rendering,
spoken VoiceOver order or actual purchase results.

## Validation and release boundary

Photo permission bootstrap: 9 passed. Family/Widget boundary checks: 62 passed,
1 existing Swift-dependent check skipped because Swift is absent. Backend
TypeScript typecheck passed. Operating-review Node tests: 6 passed, including
separate purchase-sheet cancellation and renewal-cancellation evidence.
Diff whitespace checks passed.

Native transfer regression was added to the existing
`ci/verify-cat-household-identity.swift`, already compiled/executed by required
Build CI. It has not run locally: Swift and Xcode are absent. Related-photo and
memo XCUI regressions were updated but have not run. Existing reference-image
path did not provide a matching related-photo screenshot in this environment;
current rendering and subjective rediscovery value are unverified.

Six targeted Workerd suites stopped before running tests due to the restricted
Windows parent's read/mkdir access. No ACL, security setting or path-access
workaround was used. The same account still cannot successfully complete the
mandatory Bash-based smoke/runtime preparation checklist. Preflight readiness
is not permission to skip these checks.

Before push, a supported standard environment must complete mandatory local
checks and the six targeted Workerd suites, including the newly added transition
test. The existing preservation-service workflow runs Node/Workerd/typecheck
and migration/dry-run validation. Keep those results separate from full-v1
native evidence. Then fix one release candidate and use its required CI once;
reuse successful unchanged checks and evidence according to the existing
development-release procedure. Do not dispatch measurement-only full CI.

Remaining user-device checks: transfer on two phones (including missing and
duplicate photos); actual layout/large text and VoiceOver in the photo/album/memo
path; and real Sandbox purchase/cancel/restore/expiry. Existing Apple/account
authentication and current deployed usage/cost evidence are needed only at
their specific operational stage. Do not send real photos, issue notifications,
permanently delete real records, enable paid intake or change permissions as
part of this candidate. No TestFlight update has been performed here.
