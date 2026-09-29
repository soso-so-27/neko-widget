# Tools hub — approved window-cat artwork

## Changed behavior

- Four working tools remain directly reachable in a stable two-column grid.
- Accessibility Dynamic Type uses one column. Text has no truncation limit.
- The veterinary tool stays visible as a full-width upcoming card; tapping
  explains the planned use, without implying that the tool is available.
- Existing navigation, selected-photo scope, stored care/evacuation/lost-cat
  information, billing and the app icon are unchanged.

## Artwork provenance

Reuse the five approved window-cat poses from the 2026-09-18 LP character set:
`C:/dev/neko-lp-character-integration-20260918/public/brand/cat-*.webp`.
Their original studies are G2-liquid-fit, H1-low-peek, H2-side-peek,
S1-deadpan-side-eye and S2-curious-head-tilt. PNG conversion changes only the
container format, not the decoded pixels. Do not generate replacement cats.
The app icon's G1-squished-cheeks master remains untouched.

Light and dark appearance retain the original black cat on its pale window.
Only the existing accent blue is used for tool symbols. Decorative artwork is
hidden from accessibility; buttons expose the tool name and short purpose.

## Validation plan before first candidate

Decision-changing assumption: the compact card composition, native navigation,
preview sheet and accessibility layout must work in actual SwiftUI rendering.
Windows cannot render the iOS app, so source inspection is not visual evidence.

First probe: existing focused native diagnostic, three owning tests:

- testToolsReplaceAlbumShowcaseEntryAtStandardAndLargeText (dark/light/AX5;
  grid, care and evacuation navigation, upcoming preview and close)
- testShowcaseOpensSquareGalleryAndReturnsWithoutAuthentication
- testUnpreparedLostCatDraftPreviewsAndCreatesImageAndPDF

Diagnostic screenshots will be visually reviewed before normal CI. Related
diagnostics previously took 10–14 minutes; this is a planning reference, not a
promise for this new combination. A normal exact reviewed scope should retain
Build, Photos and both-OS runtime plus the three owning UI tests. No safety,
signing or release gate is waived. The prior full fallback took up to 97.92
minutes, so do not launch that as a first probe or describe it as a 30-minute
delivery. Independently review the bounded selector before adopting it.

At the initial plan, native screenshots, required CI and Apple upload were
pending. Build 222 belonged to the parallel lost-cat release. The results below
supersede that initial state; build 223 is reserved for this candidate.

## First native observation and correction

- First product candidate: 9fd318f, 2026-09-29 11:08:57 JST.
- Diagnostic 36511431307 at 78a2c45: 21.05 minutes overall; two owning tests
  (showcase/gallery and lost-cat export) passed. Preserve these probe results.
- Tools hub rendered in dark appearance; reviewed the actual 402-point iPhone
  17 Pro screenshot. Five distinct window-cat poses, all four tools and the
  upcoming card fit; labels and eyes remain readable, with no new accent hues.
- Tools test failed at its assumed registered-cat selector title. The exported
  native hierarchy instead proves `NavigationBar: 迷子のとき`: this harness
  has zero registered cats and correctly opens the editor directly.
- 008dc43 changes only that test expectation plus a comment, not product behavior.
  Re-run only the corrected tools method in the focused diagnostic before normal
  CI. The first run spent about 15 minutes before XCTest started; do not promise
  the earlier 10–14-minute reference. Normal CI retains all three owning cases.
- Product/CI review found no P1/P2. Closed scope retains four required jobs and
  freezes all 13 product blobs plus four CI companions. Existing generic app-view
  selection is unchanged when the newly added ToolCat assets are not in the diff.
- Build 223 reserved with the mainline owner. Apple upload is not yet complete.

## Verified candidate and mainline integration

- Corrected focused diagnostic 36513611018 at 313c93d passed in 16.45 minutes.
  Inspected actual Simulator screenshots in dark, light and AX5. The tools hub
  uses one column at AX5; all four routes and the upcoming preview open/close
  passed. The sheet screenshot tagged large still uses fixture-default text;
  do not claim that sheet's AX5 typography or a physical iPhone was verified.
- Required candidate **push** CI 36515439688 passed all four jobs, including all
  three owning UI cases with zero failures. Total 18.85 minutes; candidate
  runner time 62.75 minutes. First source candidate to normal CI success was
  73.433 minutes, not 18.85. Failed diagnostic and rework remain counted.
- Creating the normal branch at an existing diagnostic SHA emitted CreateEvent
  only. PR run 36515117672 was skipped and is not successful evidence. Created
  `codex/tools-brand-20260929-ci` at the existing base and fast-forwarded the
  exact same SHA to cause a push. This changes no validation/release inputs;
  the original task clock and failures remain in the timing observation.
- PR 98 merged as d3e6394 on 2026-09-29 at 12:22 JST. Confirmed full candidate
  313c93d633ea0fb6f88d31a30dad9af9974a232b remains an ancestor of origin/main.
- Release CLI dry-run passed with CI 36515439688 and unused build 223, then
  dispatched TestFlight run 36516927611 exactly once. Its source is the fixed
  candidate, not newer documentation-only main changes. Internal testflight
  environment approval covered only this run; no public release/invites.
- At this subsection's creation the upload was running; it is not yet evidence
  of Apple acceptance. Final upload evidence is recorded separately below.
