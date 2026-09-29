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

Current state: native rendering and required CI passed; PR100 is merged into
main and internal TestFlight224 was uploaded to Apple with no errors.
Apple processing and physical-device visibility have not been checked.

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

## Final candidate, integration and release

- Product and owning native test sources did not change after `05e76ec`.
  Independent review covered the corrected guard and all seven frozen CI
  companions as well; no P1/P2 findings. No second reviewer/history fork.
- Corrected candidate `72d29f07bd40bdaaaf13a4b3aec185d786e93c47` passed normal
  push CI `36533648139`: all four mandatory jobs actually executed successfully
  (Build, real Photos bootstrap/scan, iOS18.5/26.2 runtime, three owning UI
  operations). 20.05 minutes wall, 72.45 unweighted runner minutes. The
  macOS-only guard skipped locally was executed successfully in Mac Build.
- PR100: https://github.com/soso-so-27/neko-widget/pull/100, merged as
  `da9ed9c74de5e693ecc824db0c0eea7d11ac8e96`. Fixed candidate72d29f0 is a
  verified ancestor of main. Main CI `36535645109` succeeded and its actual
  plan log confirms reuse of `36533648139`; no duplicate native jobs.
- Internal TestFlight224: dry-run verified source72d29f0, CI36533648139 and
  unused build224 before dispatch. Upload run `36535759050` uses main's
  workflow atda9ed9c and the fixed product source72d29f0. Approved only that
  run's matching `testflight` deployment, without changing protection rules.
  Actual altool log confirms `VERIFY SUCCEEDED with no errors` and
  `UPLOAD SUCCEEDED with no errors` at2026-09-29T07:28:59.420Z. Upload step
  source72d29f0 and build224 match the fixed candidate. Mode remains the
  existing `media-staging`; no public release or external invitations.
  Workflow11.633min including approval wait,10.25 unweighted runner minutes.

## Actual scope and known limits

- Names and existing monochrome cat artwork appear above photos; private and
  subscribed public windows remain in one grid. An unfinished connection is
  an equal-size card that resumes itself. Person-plus always opens connection
  options; compass opens discovery. No extra explanatory copy or new colors.
- Dark/light, 320pt constrained list content and maximum AX5 rendering were
  directly inspected. Discovery, subscription/stop, setup, scoped recovery
  and photo viewing passed native assertions. 320pt is not device/chrome
  coverage; arbitrary long names, hardware rendering and switching to another
  private account were not directly exercised.
- Fixture images are synthetic test photos, and its tab bar has three tabs.
  The production four-tab shell is unchanged. The images do not demonstrate
  live feed replenishment; expiry and recipient/account boundaries remain.
- Diagnostic evidence: `C:/dev/neko-evidence/window-hub-diagnostic-36529924885/`
  `ios-26-2/composer-screenshots/manifest.json`. These local images are native
  evidence, not product photos or proof of Apple processing/device delivery.

## Time and cost accountability

The initial whole-task50-65 minute estimate was missed because the old source
guard was not updated before the first normal candidate. This was a test-update
omission, not a product defect; normal CI was not used to change native behavior.
The revised70-85 minute plan retains that failed run and the exact-SHA rerun.
The longer watcher backoff also delayed notification; later stages use one60s
watcher. No duplicate monitors or cancelled sibling jobs.

Diagnostic plus both normal candidates consumed131.666 unweighted runner
minutes; this excludes upload/main and is not billed minutes or money. Baseline
records both failed18.217 and successful20.05 minute candidates. Do not report
the latter as the elapsed time from the first candidate at15:05:23 JST.

Apple upload succeeded at16:28:59 JST, **83.607 minutes from the first product
candidate**, including the failed run and correction (not just final CI).
This exceeds the original50-65 minute plan and falls within the revised70-85
minute estimate. Final documentation/integration time is additional. The
timing-only follow-up does not change the shipped app or require another upload.
