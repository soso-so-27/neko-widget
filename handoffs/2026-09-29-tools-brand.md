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

Native screenshots, required CI and Apple upload remain pending at this record.
Build 222 belongs to the parallel lost-cat release; coordinate 223 or later.
