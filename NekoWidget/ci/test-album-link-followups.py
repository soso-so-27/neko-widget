"""Source contracts for the build 365 follow-ups (11/13).

1. The 写真 tab's cat filter (count, grid, theme row, favourite and memo
   filters) reads every cat's whole set: explicit includes, the linked album,
   the single-cat rule, minus exclusions. The index is built once per
   presentation version in AppViewModel, never per render. A chosen cat's
   grid is its page's photo list, so album photos the scan did not find are
   listed and counted alike.
2. 写真を見せる: a cat's picker shows its photos first and the others under
   「ほかの猫の写真」; a set made only by おすすめ is chosen again when the
   cat's photos grew. Hand-picked or pinned photos are never replaced.
3. The album link sheet: a caption, not a box; no empty albums; most photos
   first, the linked one leading; counts in plain grey.
4. The key-photo picker's cells are squares the photo fills.
5. 「○○を探しています」 only while searching (LostCatDraft.isSearching).

Native behaviour: NekoWidgetTests AlbumLinkFollowupsTests and
ci/verify-tool-outputs.swift.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


IDENTITY = read("Shared/Models/CatHouseholdIdentity.swift")
MODEL = read("NekoWidget/ViewModels/AppViewModel.swift")
ROOT_VIEW = read("NekoWidget/App/AppRootView.swift")
MAIN = read("NekoWidget/Views/MainTabView.swift")
CURATION = read("NekoWidget/Views/CatProfilePhotoCurationViews.swift")
SHOWCASE = read("NekoWidget/Views/ShowcasePhotoView.swift")
STORE = read("NekoWidget/Services/ShowcasePhotoStore.swift")
LOST = read("NekoWidget/Services/LostCatIncident.swift")
LOST_VIEW = read("NekoWidget/Views/CatPreparednessView.swift")
HOME = read("NekoWidget/Views/CatHomeView.swift")
READABLE = read("NekoWidget/Services/ReadablePreservationExport.swift")


def block(source, marker):
    if source.count(marker) != 1:
        raise AssertionError(f"Expected one {marker!r}")
    start = source.index(marker)
    depth = 0
    for index in range(source.index("{", start), len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[start:index + 1]
    raise AssertionError(f"Unclosed {marker!r}")


class PhotosTabCatFilter(unittest.TestCase):
    def test_assignments_are_the_inverse_of_the_whole_sets(self):
        inverse = block(IDENTITY, "static func profileIdentifiersByAsset(")
        self.assertIn("result[identifier, default: []].insert(key)", inverse)
        sets = block(MODEL, "private var catProfilePhotoSets: (")
        self.assertIn("CatHouseholdIdentityState.profileIdentifiersByAsset(sets)", sets)
        self.assertIn("cached.version == version, cached.received == received", sets)

    def test_the_tab_reads_the_cache_not_manual_memberships(self):
        self.assertIn("photoLibraryAssignments: viewModel.catHouseholdIdentity == nil\n"
                      "                ? [:] : viewModel.catProfilePhotoAssignments,", ROOT_VIEW)
        self.assertNotIn("for membership in value.memberships where membership.decision == .included",
                         ROOT_VIEW)
        projection = block(ROOT_VIEW, "private func profileIdentityProjection(")
        self.assertIn("let assignedByAsset = viewModel.catProfilePhotoAssignments", projection)

    def test_a_chosen_cat_lists_its_page_photos(self):
        photos = block(MAIN, "private var photoLibraryCatPhotos: [PhotoPresentation]")
        self.assertIn('identifier != "unassigned"', photos)
        self.assertIn("let photos = profileAlbumPhotos[identifier]", photos)
        # The 「○枚」 row counts the same list.
        self.assertIn("? photoLibraryCatPhotos : []", block(MAIN, "private var photoLibraryCatRow: some View"))


class ShowcaseForACat(unittest.TestCase):
    def test_picker_shows_this_cat_first_then_the_others(self):
        picker = block(SHOWCASE, "private struct ShowcaseCandidatePicker: View")
        self.assertNotIn("この子の写真だけ", picker)
        self.assertNotIn("onlyThisCat", picker)
        self.assertIn('heading("ほかの猫の写真")', picker)
        self.assertIn('heading("最近の写真")', picker)
        self.assertIn("if own.contains(photo.localIdentifier) { mine.append(photo) } else { others.append(photo) }",
                      picker)
        self.assertIn("let ordered = (split.own + split.others).map(\\.localIdentifier)", picker)
        self.assertIn("own: knownIdentifiers,", SHOWCASE)

    def test_only_a_recommended_set_is_refreshed_when_the_cat_grew(self):
        only = block(STORE, "func isRecommendationOnly(_ scopeID: String) -> Bool")
        self.assertIn("current.allSatisfy { !$0.pinned }", only)
        grown = block(STORE, "func recommendationHasGrown(_ scopeID: String, candidateCount: Int) -> Bool")
        self.assertIn("recommendedFromCount ?? allEntries(in: scopeID).count", grown)
        self.assertIn("var recommendedFromCount: Int? = nil", STORE)
        apply = block(STORE, "func applyRecommendations(")
        self.assertIn("if let candidateCount { scope.recommendedFromCount = candidateCount }", apply)
        self.assertIn("let pinned = current.filter(\\.pinned)", apply)
        prepare = block(MAIN, "private func prepareShowcaseIfNeeded(")
        self.assertIn('let refreshes = hasSet && !scopeID.isEmpty && showcaseStore.isRecommendationOnly(scopeID)',
                      prepare)
        self.assertLess(prepare.index("showcaseStore.recommendationHasGrown(scopeID, candidateCount: candidates.count)"),
                        prepare.index("preparingShowcaseScopes.insert(scopeID)"))
        self.assertIn("candidateCount: candidates.count, undoable: !refreshes)", prepare)
        # Hand edits pin: add, replace, move and 先頭にする.
        for name in ("func addPhotos(", "func replace(", "func move(_ entry: Entry, to target: Entry) throws",
                     "func moveToFront(_ entry: Entry) throws"):
            body = block(STORE, name)
            self.assertTrue("pinned: true" in body or "isPinned = true" in body, name)
        self.assertIn('"recommendedFromCount", "photoRemoved", "pendingPhotoCleanup"]', READABLE)


class AlbumLinkSheet(unittest.TestCase):
    def test_caption_order_and_grey_counts(self):
        sheet = block(CURATION, "private struct CatProfilePhotoAlbumLinkSheet: View")
        self.assertIn("ForEach(Array(shownAlbums.enumerated()), id: \\.element.id)", sheet)
        self.assertIn("} header: {\n", sheet)
        self.assertIn(".textCase(nil)", sheet)
        self.assertIn(".foregroundStyle(Color(.secondaryLabel))", sheet)
        self.assertIn('.accessibilityIdentifier("cat-photo-album-link-row-\\(index)")', sheet)
        order = block(CURATION, "enum CatProfilePhotoAlbumLinkOrder")
        self.assertIn("$0.accessiblePhotoCount > 0 || $0.identifier == linkedIdentifier", order)
        self.assertIn("first.element.accessiblePhotoCount > second.element.accessiblePhotoCount", order)


class KeyPhotoGrid(unittest.TestCase):
    def test_cells_are_squares_the_photo_fills(self):
        grid = block(CURATION, "private struct CatSelectablePhotoGrid: View")
        cell = grid[grid.index("private func cell("):]
        self.assertLess(cell.index("Color.clear\n            .aspectRatio(1, contentMode: .fit)"),
                        cell.index("PhotoAssetImageView("))
        self.assertIn(".clipped()", cell)
        self.assertIn('"\\(photo.detectedCatCount)匹"', cell)
        self.assertIn("LazyVGrid(columns: columns, spacing: 3)", grid)


class LostCatSearching(unittest.TestCase):
    def test_searching_needs_a_flyer_or_an_office(self):
        searching = block(LOST, "var isSearching: Bool")
        self.assertIn("flyerMadeAt != nil || !(incident?.contactedOffices ?? []).isEmpty", searching)
        self.assertIn("incident?.foundMessage", searching)
        self.assertIn("var flyerMadeAt: Date? = nil", LOST)
        self.assertIn("next.flyerMadeAt = nil", block(LOST, "func endingIncident() -> LostCatDraft"))
        self.assertIn("static let schemaVersion = 1", LOST)
        # hasIncident keeps its meaning (「見つかりました」 is offered).
        self.assertIn("|| lastSeenAt != nil || incident != nil", block(LOST, "var hasIncident: Bool"))

    def test_the_flyer_marks_it_and_the_page_reads_it(self):
        preview = block(LOST_VIEW, "private struct LostCatPreviewView: View")
        self.assertIn("UIPasteboard.general.string = draft.message; copied = true; onMade()", preview)
        self.assertIn("exportError = false\n                        onMade()", preview)
        self.assertIn("LostCatPreviewView(draft: value, onMade: markFlyerMade)", LOST_VIEW)
        self.assertIn("draft.flyerMadeAt = .now", block(LOST_VIEW, "private func markFlyerMade()"))
        self.assertIn("LostCatDraftStore.shared.drafts.filter { $0.value.isSearching }", HOME)
        self.assertNotIn("$0.value.hasIncident", HOME)
        self.assertIn('"flyerMadeAt": "チラシを作った日"', READABLE)
        self.assertIn('"lastSeenAt", "flyerMadeAt",', READABLE)


class Registration(unittest.TestCase):
    def test_unit_tests_are_in_the_test_target(self):
        project = read("NekoWidget.xcodeproj/project.pbxproj")
        self.assertEqual(project.count("path = AlbumLinkFollowupsTests.swift;"), 1)
        sources = project.index("C1108C000000000000000006 = { isa = PBXSourcesBuildPhase;")
        self.assertIn("C1A1BF100000000000000001,", project[sources:project.index("};", sources)])
        self.assertIn("python3 ci/test-album-link-followups.py", read("ci/run-quick-ios-checks.sh"))
        self.assertIn("try lostCatSearchingNeedsAFlyerOrAnOffice()", read("ci/verify-tool-outputs.swift"))


if __name__ == "__main__":
    unittest.main()
