"""Static contracts for the measured screen-speed fixes (11/10, ScreenSpeedSweep).

Source checks only: each rule keeps one measured fix from quietly coming back.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
MAIN = (ROOT / "NekoWidget/Views/MainTabView.swift").read_text(encoding="utf-8")
GROUP = (ROOT / "NekoWidget/Views/GroupWindowView.swift").read_text(encoding="utf-8")
FIXTURE = (ROOT / "NekoWidget/App/AppStoreScreenshotFixture.swift").read_text(encoding="utf-8")


def block(source, start, end):
    head = source.index(start)
    return source[head:source.index(end, head)]


def struct_body(source, declaration):
    """The text of one top-level type, from its declaration to the next one."""
    head = source.index(declaration)
    following = re.search(r"\n(?:@MainActor\n)?(?:private |fileprivate )?(?:struct|final class|class|enum|actor|extension) ",
                          source[head + len(declaration):])
    return source[head:head + len(declaration) + (following.start() if following else len(source))]


class TabSelectionTests(unittest.TestCase):
    def setUp(self):
        self.setter = block(MAIN, "TabView(selection: Binding(get: { selectedTab }, set: { tab in", "photosTab\n")

    def test_last_tab_is_written_only_when_it_changes(self):
        self.assertIn("if lastViewedTab != tab.rawValue { lastViewedTab = tab.rawValue }", self.setter)
        writes = re.findall(r"lastViewedTab\s*=\s*tab\.rawValue", self.setter)
        self.assertEqual(len(writes), 1, "only the guarded write")

    def test_last_tab_is_still_written_only_from_a_tap(self):
        # #861: routes set selectedTab directly; only the tap setter remembers.
        outside = MAIN.replace(self.setter, "")
        stray = re.search(r"(?<!var )lastViewedTab\s*=(?!=)", outside)
        self.assertIsNone(stray, "lastViewedTab written outside the tap setter")
        self.assertIn("MainTabStartupPolicy.selection(lastTab: lastViewedTab", MAIN)

    def test_no_user_defaults_write_in_the_setter(self):
        self.assertNotIn("UserDefaults.standard.set", self.setter)

    def test_leaving_mado_writes_only_a_newer_visit(self):
        visit = block(MAIN, "private func rememberMadoVisit() {", "\n    }\n")
        guard = visit.index("guard latest.timeIntervalSince1970 > UserDefaults.standard.double(forKey: key) else { continue }")
        write = visit.index("UserDefaults.standard.set(latest.timeIntervalSince1970, forKey: key)")
        self.assertLess(guard, write)
        self.assertEqual(visit.count("UserDefaults.standard.set("), 1)


class DeliverySheetTests(unittest.TestCase):
    def setUp(self):
        self.sheet = struct_body(GROUP, "struct GroupLibraryDeliverySheet: View {")

    def test_list_remembers_its_order(self):
        remember = block(GROUP, "func rememberListed(_ windows: [GroupWindow]) {", "}\n")
        self.assertIn("lastListed = windows", remember)

    def test_sheet_shows_the_last_list_before_reading_again(self):
        task = block(self.sheet, ".task {", ".announcesWhenShown(list.message)")
        cached = task.index("list.showListed(GroupWindowListNavigation.shared.lastListed)")
        load = task.index("await list.load()")
        self.assertLess(cached, load)
        # The fresh list always decides in the end.
        self.assertGreater(task.rindex("chooseOnlyWindow()"), load)

    def test_cache_never_replaces_a_loaded_list(self):
        show = block(GROUP, "func showListed(_ listed: [GroupWindow]) {", "\n    }\n")
        self.assertIn("guard !hasLoaded, !listed.isEmpty else { return }", show)

    def test_stale_single_window_falls_back_to_the_list(self):
        choose = block(self.sheet, "private func chooseOnlyWindow() {", "\n    }\n")
        self.assertIn("if openWindows.count == 1 {", choose)
        self.assertIn("} else if screen != nil {\n            screen = nil", choose)


class FixtureHarnessTests(unittest.TestCase):
    def test_image_loads_do_not_redraw_the_fixture_root(self):
        root = struct_body(FIXTURE, "struct AppStoreScreenshotFixtureRootView: View {")
        self.assertNotIn("loadTracker", root)
        self.assertIn("AppStoreScreenshotFixtureLoadedMarkers()", root)
        markers = struct_body(FIXTURE, "private struct AppStoreScreenshotFixtureLoadedMarkers: View {")
        self.assertIn("@ObservedObject private var loadTracker = AppStoreScreenshotFixture.loadTracker", markers)
        self.assertIn("AppStoreScreenshotFixture.loadedAccessibilityIdentifierPrefix", markers)


if __name__ == "__main__":
    unittest.main()
