# Window hub: stable names above changing photos

## Scope and completion

User approved the first native-app mock: two-column photo shelf, names above
photos, existing monochrome window-cat artwork, a setup card in the same grid.
Keep subscribed public and private windows together. The person-plus entry has
a stable connection-options destination; each unfinished card resumes itself.
No new unread state, participant counts, chat, public-window taxonomy or colors.

Use current main `02ca041` in the free completed tools-brand checkout, on a new
`codex/window-hub-photo-first-20260929` branch. The LP checkout and unrelated
identity research stay untouched. The only open PR at the start is #66,
PairingView wording; this batch does not edit that file.

Completion: approved layout in the shipping SwiftUI views, directly observed
native rendering and owning navigation checks, required candidate CI, mainline
integration and an internal TestFlight upload under the existing authorization.
No public release, new invitations, billing change or feed replenishment.

## Evidence and remaining assumptions before native probing

- The conversational mock was inspected at normal and 320px host widths. This
  is not evidence of SwiftUI layout, native accessibility or actual iPhone use.
- Source inspection found existing per-window cover loading, expiry timelines,
  per-window errors, setup grouping and five already-bundled ToolCat poses.
- Cover data selection, authentication, retention, catalog reload fences,
  navigation identities, receiving/stop behavior and addition limits remain
  unchanged. Fixed decorative cat identity avoids caching a private photo in
  a new long-lived avatar. Empty states do not substitute expired photos.
- Decision-changing uncertainty: grid hit regions, wrapped title height,
  Dynamic Type, setup-card routing and its independent discover/connect paths.
  Validate the actual production SwiftUI via the existing offline window
  fixture; only account/network sources are substituted.

## Proportionate validation plan

First probe: three existing OfficialWindowUITests methods: mixed windows and
scoped recovery (dark/light/320pt/AX5), discover/receive/stop, and large-text
discovery/photo viewing. Diagnostic route currently supports three other
classes, so OfficialWindowUITests must be enabled without changing its exact
SHA, diagnostic-branch, one-class/one-to-three-method or no-release boundaries.

Recent focused native probes took 16.45–21.05 minutes including preparation.
This is a planning reference, not an observed time for this batch. Normal
candidate CI still needs build, Photos and both-OS runtime plus changed routes.
Broad app-view validation is not the first probe. Inspect the selected route
and observed duration before running normal CI; do not claim a 30-minute finish
if that route exceeds it. Record the first candidate time and failed attempts.

Current state: implementation prepared; native rendering, required CI, mainline
integration and internal Apple upload are not yet verified.

## Candidate and route decisions

- First product candidate: `05e76ec`, 2026-09-29 15:05:23 JST. All elapsed
  accounting starts here, not at the final green run.
- One user-authorized, history-free reviewer found no P1/P2 in the product or
  diagnostic extension. Minimum owning methods are the three above.
- Local development-flow checks passed (119.5 seconds) at `2717537`.
  The normal selector would require full-v1 (observed 64.43-97.92 minutes).
  That normal run was NOT launched. A bounded manual diagnostic, non-release,
  was dispatched instead: `36529924885`, exact source `2717537`, three methods.
- Prepare a separately reviewed closed window-hub scope during that probe.
  Exact three product git-blob pairs and six full CI companion pairs are bound;
  unknown inputs retain the pre-existing conservative selection. Build, real
  Photos bootstrap/scan, both-OS runtime and all three owning operations remain.
  Diagnostic results are not reused as the required normal candidate CI.
- Planning references after successful probing: prior three-operation tools
  scope 18.85 minutes, internal Apple upload 9.267 minutes. This scope is new,
  so these are references, not its measured duration. Expect roughly 50-65
  minutes from first candidate if this probe succeeds, including preparation,
  review, required CI and upload; rework/queue time can exceed that.
- Native evidence limitations to report: 320pt constrains list content, not
  device chrome; fixture names do not cover arbitrary long names; paired-account
  switching is unchanged and not exercised by the already-active setup fixture.
  No claim of hardware testing or live feed replenishment.

## First native result and first candidate failure

- Diagnostic36529924885 passed all3 cases, no failures/skips;13.917min wall,
  13.683 runner minutes. Actual screenshots were inspected in dark/light,
  320pt constrained content and AX5. Product files remained05e76ec.
- Candidatepush36531491897 atcaa3c45 failed in Build's Python guard before
  app compilation: test_window_list_preserves_cached_windows_and_scopes_pending_counts
  still demanded SubtleWindowThumbnail. This is a stale presentation assertion,
  not a native product defect. Source routing/privacy/retention guards passed up
  to that point. The unused thumbnail helper was not reintroduced to appease it.
- Update that assertion to the shipping setup card, bundled cat poses, actual
  expiry predicate and per-window placeholder. Other boundary assertions stay.
  Local boundary suite:62 passed,1 macOS-only check skipped on Windows; that
  platform check is still mandatory in the normal Mac Build job.
- Freeze the entire corrected boundary-test file as the seventh CI companion.
  Diagnostic/native product sources remain unchanged, so no new UI diagnostic
  is needed. Keep the old run's sibling results; do not cancel them. Release
  still requires a complete normal candidate run at the new SHA because this
  repository does not reuse a different-SHA guard correction as release evidence.
  Do not label the failed candidate successful or omit its cost.
