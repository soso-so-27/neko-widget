"""Source contracts; not a replacement for native scroll/render checks."""
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
HOME = (ROOT / "NekoWidget/Views/HomeView.swift").read_text(encoding="utf-8")
VM = (ROOT / "NekoWidget/ViewModels/AppViewModel.swift").read_text(encoding="utf-8")
class ReadingControls(unittest.TestCase):
    def test_scoped_return_drops_stale_callback(self):
        self.assertIn('userInfo: ["section": section]', HOME)
        self.assertIn('generation == restorationGeneration', HOME)
        self.assertIn('.onChange(of: self.section)', HOME)
    def test_month_jump_preserves_collection(self):
        jump = HOME.split('private func moveToMonth(', 1)[1].split('@ViewBuilder', 1)[0]
        self.assertIn('index + 24', jump)
        self.assertIn('PhotoLibraryGridRow.identifier(containing:', jump)
        self.assertIn('section: readingPositionKey ?? "all"', jump)
    def test_partial_failure_keeps_photos_and_retry(self):
        self.assertIn('if !catPhotos.isEmpty {', HOME)
        self.assertIn('scan.hasFailed || scan.hasDeferredAssets || scan.isScanning || scan.isPaused', HOME)
        self.assertIn('.disabled(scan.isScanning)', HOME)
        method = VM.split('func rescan() async {', 1)[1].split('func suspendScan()', 1)[0]
        self.assertLess(method.index('isManualRescanRequestPending = true'), method.index('await saveSnapshot'))
        self.assertIn('defer { isManualRescanRequestPending = false }', method)
    def test_reselecting_current_mode_preserves_scoped_position_owner(self):
        main=(ROOT / "NekoWidget/Views/MainTabView.swift").read_text(encoding="utf-8")
        selection=main.split('func select(_ section: PhotoLibrarySection)',1)[1].split('func resolveInitialSelection',1)[0]
        self.assertIn('if selection != section',selection)
        self.assertIn('hasResolvedSelection = true',selection)
    def test_saved_metadata_is_published_separately(self):
        self.assertIn('@Published private(set) var savedPhotoIdentifiers', VM)
        self.assertIn('savedPhotoStateReadFailed = true', VM)
        self.assertIn('savedPhotoStateReadFailed = false', VM)

# The following checks intentionally do not execute Swift or simulate native layout.
# They bind an event-order model to the shipping source; the unchanged page-31
# XCTest remains the evidence for real hittability after Back.
import copy
import re

from ios_ci_scope import swift_declaration_source

MAIN = (ROOT / "NekoWidget/Views/MainTabView.swift").read_text(encoding="utf-8")
FIXTURE = (ROOT / "NekoWidget/App/AppStoreScreenshotFixture.swift").read_text(encoding="utf-8")


def active_swift(source):
    # Preserve conditional locations while reusing the selector's comment/string
    # lexer. Individual contracts below reject conditional product declarations.
    source = re.sub(r"(?m)^([ \t]*)#(?=(?:if|elseif|else|endif)\b)", r"\1@", source)
    result = swift_declaration_source(source)
    if result is None:
        raise AssertionError("Cannot prove the active Swift source")
    return result


def conditionals_at(active, offset):
    stack = []
    for match in re.finditer(r"(?m)^[ \t]*@(if|elseif|else|endif)\b([^\n]*)", active[:offset]):
        kind, expression = match.groups()
        if kind == "if":
            stack.append(expression.strip())
        elif kind == "endif":
            stack.pop()
        else:
            stack[-1] = kind + expression
    return stack


def swift_block(source, marker, *, allowed_conditions=()):
    active = active_swift(source)
    if active.count(marker) != 1:
        raise AssertionError(f"Expected one active {marker}")
    start = active.index(marker)
    if conditionals_at(active, start) != list(allowed_conditions):
        raise AssertionError(f"Unexpected conditional owner for {marker}")
    opening = active.index("{", start)
    depth = 1
    for index in range(opening + 1, len(active)):
        depth += (active[index] == "{") - (active[index] == "}")
        if depth == 0:
            return source[start:index + 1]
    raise AssertionError(f"Unclosed {marker}")


def require_active(source, fragment):
    # A comment, unused string, duplicate, or conditional copy cannot satisfy a
    # required statement. Keep literal arguments (including section identity).
    if source.count(fragment) != 1:
        raise AssertionError(f"Expected one source fragment: {fragment}")
    start = source.index(fragment)
    active = active_swift(source)
    if active[start:start + len(fragment)] != active_swift(fragment):
        raise AssertionError(f"Inactive source fragment: {fragment}")
    if conditionals_at(active, start):
        raise AssertionError(f"Conditional source fragment: {fragment}")


def compact(source):
    return re.sub(r"\s+", "", active_swift(source))


RETURN_CLOSURE = '''.onDisappear {
    PhotoLibraryReadingPosition.returnToOpenedPhoto(
        PhotoLibraryGridRow.identifier(containing: localIdentifier, in: photoLibraryCatPhotos),
        section: photoLibraryPositionKey
    )
    if photosPath.isEmpty {
        photoLibraryRevision &+= 1
        PhotoLibraryReadingPosition.diagnose("diagnostic text is not a control input")
    }
}'''


def validate_return_sources(main=MAIN, home=HOME):
    destination = swift_block(main, "private func photosDestination(")
    route = destination.split("case let .collectionPhoto(localIdentifier):", 1)[1].split("case .automaticAlbums:", 1)[0]
    if compact(swift_block(route, ".onDisappear")) != compact(RETURN_CLOSURE):
        raise AssertionError("Save/post must precede the only empty-path revision mutation")
    save_return = swift_block(home, "static func returnToOpenedPhoto(")
    require_active(save_return, "save(identifier, section: section)")
    require_active(save_return, 'NotificationCenter.default.post(name: returnToPhotoNotification, object: identifier,\n                                        userInfo: ["section": section])')
    if save_return.index("save(identifier") > save_return.index("NotificationCenter.default.post"):
        raise AssertionError("Persist before notifying retained roots")
    library = swift_block(main, "private var photoLibrary: some View")
    require_active(library, r'photoLibraryContent.id("\(photoLibraryRevision)-\(photoLibraryPositionKey)")')
    require_active(library, "PhotoLibrarySectionPicker(selection: photoLibrarySelection.binding)")
    stack = swift_block(main, "NavigationStack(path: $photosPath)")
    require_active(stack, "photoLibrary\n                .navigationDestination(for: PhotosRoute.self, destination: photosDestination)")
    if "photoLibraryRevision" in stack:
        raise AssertionError("Reidentify the collection, not its navigation owner")
    position_key = swift_block(main, "private var photoLibraryPositionKey: String")
    require_active(position_key, "let mode = photoLibrarySelection.selection.rawValue")
    require_active(position_key, r'return photoLibraryProfileIdentifier.map { "\(mode)-\($0)" } ?? mode')
    restoration = swift_block(home, "private struct PhotoLibraryPositionRestoration:")
    require_active(restoration, "@State private var position: String?")
    require_active(restoration, "_position = State(initialValue: nil)")
    require_active(restoration, ".scrollPosition(id: $position, anchor: .top)")
    appearance = swift_block(restoration, ".onAppear")
    for statement in ("let saved = PhotoLibraryReadingPosition.identifier(for: section).map(normalize)",
                      "userScrolled = false", "position = saved", "isVisible = true"):
        require_active(appearance, statement)
    require_active(restoration, "guard isVisible, generation == restorationGeneration else { return }")
    require_active(restoration, ".onDisappear { isVisible = false; restorationGeneration += 1 }")
    require_active(restoration, "if isVisible, userScrolled, !isSearching,\n                       PhotoLibraryReadingPosition.activeSection == section, let value {\n                        PhotoLibraryReadingPosition.save(value, section: section)\n                    }")
    home_view = swift_block(home, "struct HomeView:")
    require_active(home_view, '_initialReadingIdentifier = State(initialValue: isEmbedded\n            ? PhotoLibraryReadingPosition.identifier(for: readingPositionKey ?? "all") : nil)')
    restored_count = swift_block(home_view, "private var restoredDetectedPhotoCount: Int")
    require_active(restored_count, "let index = catPhotos.firstIndex(where: { $0.localIdentifier == initialReadingIdentifier })")
    require_active(restored_count, "return max(visibleDetectedPhotoCount, index + 24)")
    require_active(home_view, "ForEach(PhotoLibraryGridRow.rows(Array(catPhotos.prefix(restoredDetectedPhotoCount)))) { row in")


class ReturnIdentitySourceContracts(unittest.TestCase):
    def test_shipping_source_binds_the_event_model(self):
        validate_return_sources()

    def test_return_contract_rejects_guard_order_and_state_mutations(self):
        mutations = (
            MAIN.replace("if photosPath.isEmpty {\n                        // A retained", "if true {\n                        // A retained", 1),
            MAIN.replace("photoLibraryRevision &+= 1\n                        PhotoLibraryReadingPosition.diagnose", "photosPath = NavigationPath()\n                        photoLibraryRevision &+= 1\n                        PhotoLibraryReadingPosition.diagnose", 1),
            MAIN.replace("photoLibraryRevision &+= 1\n                        PhotoLibraryReadingPosition.diagnose", "photoLibrarySelection.select(.all)\n                        photoLibraryRevision &+= 1\n                        PhotoLibraryReadingPosition.diagnose", 1),
            MAIN.replace("photoLibraryRevision &+= 1\n                        PhotoLibraryReadingPosition.diagnose", "photoLibraryProfileIdentifier = nil\n                        photoLibraryRevision &+= 1\n                        PhotoLibraryReadingPosition.diagnose", 1),
            MAIN.replace("PhotoLibraryReadingPosition.returnToOpenedPhoto(\n                        PhotoLibraryGridRow", "photoLibraryRevision &+= 1\n                    PhotoLibraryReadingPosition.returnToOpenedPhoto(\n                        PhotoLibraryGridRow", 1),
            MAIN.replace("private func photosDestination(", "/* private func photosDestination(", 1) + "\n*/",
            MAIN.replace("    @ViewBuilder\n    private func photosDestination(", "#if false\n    @ViewBuilder\n    private func photosDestination(", 1) + "\n#endif",
        )
        for index, source in enumerate(mutations):
            with self.subTest(mutation=index), self.assertRaises((AssertionError, IndexError)):
                validate_return_sources(source, HOME)

    def test_identity_initial_state_and_batch_mutations_fail(self):
        for old, new in (
            (r'photoLibraryContent.id("\(photoLibraryRevision)-\(photoLibraryPositionKey)")', r'photoLibraryContent.id("\(photoLibraryPositionKey)")'),
            (r'photoLibraryContent.id("\(photoLibraryRevision)-\(photoLibraryPositionKey)")', r'photoLibraryContent.id("\(photoLibraryRevision)")'),
        ):
            with self.subTest(old=old, new=new), self.assertRaises(AssertionError):
                validate_return_sources(MAIN.replace(old, new, 1), HOME)
        for old, new in (("_position = State(initialValue: nil)", '_position = State(initialValue: PhotoLibraryReadingPosition.identifier(for: section ?? "all"))'),
                         ("return max(visibleDetectedPhotoCount, index + 24)", "return visibleDetectedPhotoCount"),
                         ("guard isVisible, generation == restorationGeneration else { return }", "guard isVisible else { return }")):
            with self.subTest(old=old), self.assertRaises(AssertionError):
                validate_return_sources(MAIN, HOME.replace(old, new, 1))

    def test_debug_trace_is_scoped_to_paging_with_an_isolated_suite(self):
        fixture = swift_block(FIXTURE, "struct AppStoreScreenshotFixtureRootView:", allowed_conditions=("DEBUG",))
        receiver = swift_block(fixture, ".onReceive(NotificationCenter.default.publisher(for: PhotoLibraryReadingPosition.diagnosticNotification))")
        require_active(receiver, 'guard widgetRecoveryCase == "paging",\n                  ProcessInfo.processInfo.environment["NEKO_PHOTO_UI_PREFERENCES_SUITE"] != nil else { return }')
        require_active(receiver, 'photoPositionDiagnostics = PhotoLibraryReadingPosition.diagnosticEvents.joined(separator: "\\n")')
        markers = swift_block(fixture, "private var loadedAccessibilityMarkers: some View")
        gate = swift_block(markers, 'if widgetRecoveryCase == ')
        require_active(gate, 'if widgetRecoveryCase == "paging",\n               ProcessInfo.processInfo.environment["NEKO_PHOTO_UI_PREFERENCES_SUITE"] != nil {')
        require_active(gate, '.accessibilityIdentifier("photo-reading-position-diagnostics")')
        require_active(gate, ".accessibilityValue(photoPositionDiagnostics)")


def photo(number):
    return f"app-store-screenshot-fixture-page-{number}"


class ReadingRootModel:
    """Source-bound state-event model, without native layout/hittability claims."""
    def __init__(self, owner):
        self.owner = owner
        self.identity = (owner.revision, owner.section)
        self.section = owner.section
        self.initial = owner.preferences.get(self.section)
        self.position = None
        self.user_scrolled = self.visible = self.searching = False
        self.generation = 0
        self.assignments = []
        self.callbacks = []
        self.visible_count = 24

    def normalized(self, identifier):
        if identifier not in self.owner.photos:
            return identifier
        return self.owner.photos[(self.owner.photos.index(identifier) // 3) * 3]

    @property
    def included(self):
        count = self.visible_count
        if self.initial in self.owner.photos:
            count = max(count, self.owner.photos.index(self.initial) + 24)
        return self.owner.photos[:count]

    def assign(self, position):
        self.position = position
        self.assignments.append(position)

    def appear(self):
        self.user_scrolled = False
        self.assign(self.normalized(self.owner.preferences.get(self.section)))
        self.visible = True
        self.owner.active_section = self.section

    def disappear(self):
        self.visible = False
        self.generation += 1

    def receive(self, identifier, section):
        if not self.visible or section != self.section:
            return
        self.user_scrolled = False
        self.assign(None)
        self.generation += 1
        self.callbacks.append((self.generation, identifier))

    def flush(self):
        callbacks, self.callbacks = self.callbacks, []
        for generation, identifier in callbacks:
            if self.visible and generation == self.generation:
                self.assign(self.normalized(identifier))

    def observe(self, value):
        self.position = value
        if self.visible and self.user_scrolled and not self.searching and self.owner.active_section == self.section and value is not None:
            self.owner.preferences[self.section] = value


class ReadingOwnerModel:
    def __init__(self, section="all"):
        self.section = section
        self.preferences = {section: photo(1)}
        self.photos = [photo(n) for n in range(1, 51)]
        self.revision = 0
        self.active_section = section
        self.selection = "all"
        self.profile = "cat-a"
        self.selected_tab = "photos"
        self.path = ["collectionPhoto"]
        self.persistent_data = {"photos": tuple(self.photos), "notes": {"memo": "keep"}, "saved": {photo(7)}}
        self.root = ReadingRootModel(self)

    def detail_disappears(self, identifier):
        row = self.root.normalized(identifier)
        self.preferences[self.section] = row
        self.root.receive(row, self.section)
        if not self.path:
            self.revision += 1
            self.root = ReadingRootModel(self)


class ReturnIdentityEventOrderModelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        validate_return_sources()

    def test_old_root_appears_before_or_after_return(self):
        for old_appears_first in (True, False):
            with self.subTest(old_appears_first=old_appears_first):
                owner = ReadingOwnerModel()
                old = owner.root
                if old_appears_first:
                    old.appear()
                owner.path = []
                owner.detail_disappears(photo(31))
                new = owner.root
                if not old_appears_first:
                    old.appear()
                self.assertIsNot(new, old)
                self.assertIsNone(new.position)
                self.assertEqual(new.initial, photo(31))
                self.assertIn(photo(31), new.included)
                new.appear()
                self.assertEqual(new.assignments, [photo(31)])
                self.assertEqual(owner.preferences["all"], photo(31))

    def test_same_id_return_recreates_a_fresh_nil_binding(self):
        owner = ReadingOwnerModel()
        owner.preferences["all"] = photo(31)
        owner.root.appear()
        old = owner.root
        owner.path = []
        owner.detail_disappears(photo(31))
        self.assertEqual(old.position, None)  # Existing notification reset.
        self.assertIsNone(owner.root.position)
        self.assertNotEqual(owner.root.identity, old.identity)
        owner.root.appear()
        self.assertEqual(owner.root.assignments, [photo(31)])

    def test_queued_old_callback_cannot_mutate_replacement(self):
        for disappear_old in (True, False):
            with self.subTest(disappear_old=disappear_old):
                owner = ReadingOwnerModel()
                old = owner.root
                old.appear()
                owner.path = []
                owner.detail_disappears(photo(31))
                new = owner.root
                new.appear()
                before = (new.position, list(new.assignments), dict(owner.preferences))
                if disappear_old:
                    old.disappear()
                old.flush()
                old.observe(photo(49))
                self.assertEqual((new.position, new.assignments, owner.preferences), before)
                self.assertEqual(old.callbacks, [])

    def test_nonempty_paths_do_not_rebuild_on_tab_switch_or_deeper_navigation(self):
        for path, tab in ((["collectionPhoto"], "memories"),
                          (["collectionPhoto", "memo"], "photos"),
                          (["album", "collectionPhoto"], "photos")):
            with self.subTest(path=path, tab=tab):
                owner = ReadingOwnerModel()
                owner.path, owner.selected_tab = path, tab
                old = owner.root
                owner.detail_disappears(photo(31))
                self.assertIs(owner.root, old)
                self.assertEqual(owner.revision, 0)
                self.assertEqual(owner.path, path)
                self.assertEqual(owner.selected_tab, tab)

    def test_rebuild_preserves_parent_selection_profile_path_and_photo_data(self):
        owner = ReadingOwnerModel(section="all-cat-a")
        owner.preferences["favorites-cat-b"] = photo(7)
        owner.path = []
        before = copy.deepcopy((owner.selection, owner.profile, owner.selected_tab, owner.path, owner.persistent_data))
        owner.detail_disappears(photo(32))
        self.assertEqual((owner.selection, owner.profile, owner.selected_tab, owner.path, owner.persistent_data), before)
        self.assertEqual(owner.preferences, {"all-cat-a": photo(31), "favorites-cat-b": photo(7)})
        self.assertEqual(owner.root.identity, (1, "all-cat-a"))

    def test_latest_saved_row_wins_before_replacement_appearance(self):
        owner = ReadingOwnerModel()
        owner.path = []
        owner.detail_disappears(photo(25))
        intermediate = owner.root
        owner.detail_disappears(photo(31))
        self.assertEqual(owner.root.initial, photo(31))
        self.assertNotEqual(owner.root.identity, intermediate.identity)
        owner.root.appear()
        intermediate.appear()
        intermediate.flush()
        self.assertEqual(owner.root.position, photo(31))
        self.assertEqual(owner.preferences["all"], photo(31))

    def test_bottom_clamp_does_not_trigger_an_equality_retry_loop(self):
        owner = ReadingOwnerModel()
        owner.path = []
        owner.detail_disappears(photo(50))
        root = owner.root
        self.assertIn(photo(50), root.included)
        root.appear()
        self.assertEqual(root.position, photo(49))
        for observed in (photo(43), photo(46), photo(43)):
            root.observe(observed)
            root.flush()
        self.assertEqual(root.assignments, [photo(49)])
        self.assertEqual(root.callbacks, [])
        self.assertEqual(owner.preferences["all"], photo(49))

    def test_native_observation_still_saves_only_visible_active_nonsearch_drag(self):
        for visible, active, searching, dragged in ((False, True, False, True),
                                                   (True, False, False, True),
                                                   (True, True, True, True),
                                                   (True, True, False, False),
                                                   (True, True, False, True)):
            with self.subTest(visible=visible, active=active, searching=searching, dragged=dragged):
                owner = ReadingOwnerModel()
                root = owner.root
                root.appear()
                root.visible, root.searching, root.user_scrolled = visible, searching, dragged
                owner.active_section = owner.section if active else "favorites"
                root.observe(photo(31))
                expected = photo(31) if visible and active and not searching and dragged else photo(1)
                self.assertEqual(owner.preferences["all"], expected)


if __name__ == "__main__":
    unittest.main()
