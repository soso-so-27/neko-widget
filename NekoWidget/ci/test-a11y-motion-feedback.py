"""Source contracts for the 11/20 accessibility and feel pass
(視差効果を減らす・選択状態・読み上げ・触覚).

Under Reduce Motion the stories wait for a tap (no auto-advance, no eased
page turn), a Live Photo plays only when held, and the 写真 tab's pages, the
received まど, the first-run scan tiles and the この子のこと ring move without
spring, slide or scale. At default settings nothing on screen changes.

Each haptic is one moment: its trigger changes once at that moment (a false
to true edge, or a count that only grows then), never on appear or a redraw.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


VIEWS = "NekoWidget/Views/"
ALBUM = read(VIEWS + "AlbumPrototypeView.swift")
TABS = read(VIEWS + "MainTabView.swift")
ONBOARDING = read(VIEWS + "OnboardingView.swift")
SCAN = read(VIEWS + "ScanStatusView.swift")
CARE = read(VIEWS + "CatCareView.swift")
HOME = read(VIEWS + "CatHomeView.swift")
WINDOW = read(VIEWS + "GroupWindowView.swift")
FAMILY = read(VIEWS + "FamilyNotebookView.swift")
CURATION = read(VIEWS + "CatCandidateCurationView.swift")
GROWTH = read(VIEWS + "GrowthAlbumView.swift")
LIKED = read(VIEWS + "LikedPhotosView.swift")
PREPAREDNESS = read(VIEWS + "CatPreparednessView.swift")
OFFER = read("NekoWidget/Services/MembershipOfferModel.swift")
QUICK = read("ci/run-quick-ios-checks.sh")


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


class ReduceMotion(unittest.TestCase):
    def test_stories_wait_for_a_tap(self):
        self.assertIn("guard !paused, !reduceMotion, !UIAccessibility.isVoiceOverRunning, "
                      "index + 1 < currentPageCount else { return }", ALBUM)
        self.assertIn("guard !paused, !reduceMotion, !UIAccessibility.isVoiceOverRunning, "
                      "index + 1 < pages.count else { return }", ALBUM)
        self.assertEqual(ALBUM.count("withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) { index = next }"), 2)
        self.assertNotIn("withAnimation(.easeInOut(duration: 0.4)) { index = next }", ALBUM)

    def test_live_photo_plays_by_itself_only_with_motion(self):
        hold = block(ALBUM, "struct LivePhotoHold: ViewModifier {")
        self.assertIn("@Environment(\\.accessibilityReduceMotion) private var reduceMotion", hold)
        shown = hold[hold.index(".task(id: shown) {"):]
        self.assertLess(shown.index("guard !reduceMotion else { return }"), shown.index("playing = .hint"))
        # Holding still plays it.
        self.assertIn("withAnimation(.easeOut(duration: 0.15)) { playing = .full }", hold)

    def test_photo_tab_pages_and_received_windows(self):
        self.assertIn("withAnimation(reduceMotion ? nil : .snappy) { pager.position", TABS)
        self.assertIn("withAnimation(reduceMotion ? nil : .snappy(duration: 0.35)) { photoPage = section }", TABS)
        self.assertIn("withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.82))", TABS)
        self.assertIn(".transition(reduceMotion ? AnyTransition.opacity\n", TABS)
        self.assertEqual(TABS.count("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"), 3)

    def test_scan_tiles_and_ring(self):
        self.assertIn(".animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: scan.displayedCatCount)",
                      ONBOARDING)
        self.assertIn(".transition(reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .scale(scale: 0.9)))",
                      ONBOARDING)
        self.assertIn(".transition(reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .scale(scale: 0.96)))",
                      SCAN)
        self.assertIn(".animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: scan.hasPreliminaryResult)",
                      SCAN)
        ring = block(CARE, "struct CatCareRing: View {")
        self.assertIn(".animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: count.0)", ring)


class AssistiveTech(unittest.TestCase):
    def test_selected_state(self):
        self.assertIn(".accessibilityAddTraits(isSelected ? .isSelected : [])", CURATION)
        self.assertIn(".accessibilityAddTraits(photo.localIdentifier == selectedIdentifier ? .isSelected : [])",
                      GROWTH)

    def test_album_photo_names_its_cats_from_what_is_held(self):
        label = block(LIKED, "private func photoAccessibilityLabel(_ photo: PhotoPresentation) -> String {")
        self.assertIn("assignmentsByPhotoIdentifier[photo.localIdentifier]", label)
        self.assertIn('"\\(names.joined(separator: "と"))、\\(date)の写真"', label)
        self.assertIn('"\\(subject)、お気に入りの写真"', label)
        self.assertNotIn("await", label)

    def test_support_code_has_a_voiceover_route(self):
        self.assertIn('.accessibilityAction(named: "コード") { showsSendCode = true }', FAMILY)

    def test_red_values_are_spoken(self):
        self.assertIn('.accessibilityHint(problem ? "15桁の数字にすると保存されます。" : "")', CARE)
        self.assertIn('Label("15桁の数字にすると保存されます。"', CARE)
        self.assertIn(".accessibilityHint(photoError ?? \"\")", PREPAREDNESS)


class Haptics(unittest.TestCase):
    def test_once_only_triggers(self):
        self.assertIn(".sensoryFeedback(.success, trigger: page == .widgetGuide && isWidgetPlaced) "
                      "{ old, new in !old && new }", ONBOARDING)
        self.assertIn(".sensoryFeedback(.success, trigger: title == OnboardingPresentationCopy.scanFoundTitle) "
                      "{ old, new in !old && new }", ONBOARDING)
        self.assertIn(".sensoryFeedback(.success, trigger: addedCat) { old, new in old == nil && new != nil }", HOME)
        self.assertIn(".sensoryFeedback(.success, trigger: result) { old, new in old != .joined && new == .joined }",
                      FAMILY)
        self.assertIn(".sensoryFeedback(.success, trigger: careCompletion, condition: CareCompletion.justCompleted)", CARE)
        self.assertIn("new.cat != nil && old.cat == new.cat && !old.complete && new.complete", CARE)

    def test_plus_completion_counts_only_completions(self):
        sheet = block(OFFER, "struct MembershipOfferSheet: View {")
        self.assertIn(".sensoryFeedback(.success, trigger: plusCompletions)", sheet)
        # Grows only in a completed purchase and a completed restore.
        self.assertEqual(sheet.count("plusCompletions &+= 1"), 2)
        complete = block(sheet, "private func completePurchase() {")
        self.assertIn("plusCompletions &+= 1", complete)
        self.assertIn("if result == .completed {\n                        plusCompletions &+= 1", sheet)

    def test_delivery_gives_one_success(self):
        self.assertEqual(WINDOW.count(".sensoryFeedback(.success, trigger: model.sendCompleted)"), 2)
        self.assertIn("{ old, new in givesDeliveryHaptic && !old && new }", WINDOW)
        # Inside a まど the send bar under the sheet gives it, not the sheet as well.
        self.assertIn("givesDeliveryHaptic: false, close: close)", WINDOW)

    def test_tile_heart_matches_the_page(self):
        tile = block(WINDOW, "private struct GroupPhotoTile: View {")
        self.assertIn(".sensoryFeedback(.impact(weight: .light), trigger: heartsSentHere)", tile)
        toggle = block(tile, "private func toggleHeart() {")
        self.assertIn("if !model.myHeartIsActive(entry.id) { heartsSentHere &+= 1 }", toggle)
        self.assertIn(".sensoryFeedback(.impact(weight: .light), trigger: mine) { _, sent in sent }", WINDOW)


class Registration(unittest.TestCase):
    def test_runs_in_quick_checks(self):
        self.assertIn("python3 ci/test-a11y-motion-feedback.py", QUICK)


if __name__ == "__main__":
    unittest.main()
