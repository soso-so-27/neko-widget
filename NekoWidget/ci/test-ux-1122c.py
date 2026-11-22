#!/usr/bin/env python3
"""11/22: five places where a first-time user could not tell what to do next.

A1 the first-run Widget guide walks through every step with 「つぎへ」 and then
   waits for the Widget (no button that seemed to place it).
A2 the album's year strip: this month's tile opens the 写真 tab at this month;
   months without a work are only a faint label.
A3 「まどに届ける」 is always the blue main action.
B1 no faint question in the empty memo box.
B2 no 「テーマ」 heading over the 写真 tab's theme row.
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def section(text: str, start: str, end: str) -> str:
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


GUIDE = source("NekoWidget/Views/WidgetPlacementGuideView.swift")
COPY = source("NekoWidget/Views/OnboardingPresentation.swift")
ONBOARDING = source("NekoWidget/Views/OnboardingView.swift")
APP_ROOT = source("NekoWidget/App/AppRootView.swift")
ALBUM = source("NekoWidget/Views/AlbumPrototypeView.swift")
MAIN = source("NekoWidget/Views/MainTabView.swift")
LIKED = source("NekoWidget/Views/LikedPhotosView.swift")
NOTE = source("NekoWidget/Views/PhotoNoteInput.swift")
UI_SHOTS = source("NekoWidgetUITests/ReviewScreenshotUITests.swift")


class WidgetGuideTests(unittest.TestCase):
    def test_next_walks_through_the_steps(self):
        self.assertIn('static let widgetNextAction = "つぎへ"', COPY)
        buttons = section(GUIDE, ".safeAreaInset(edge: .bottom) {", "/// A secondary button")
        self.assertIn("} else if page < steps.count - 1 {", buttons)
        self.assertIn("withAnimation { page += 1 }", buttons)
        self.assertIn("Text(OnboardingPresentationCopy.widgetNextAction)", buttons)
        self.assertIn('.accessibilityIdentifier("widget-placement-next")', buttons)
        # Swiping still moves the pages: the same selection drives both.
        self.assertIn("TabView(selection: $page)", GUIDE)

    def test_last_step_waits_instead_of_a_button(self):
        self.assertIn('static let widgetWaitingText = "ホーム画面に置くのを待っています"', COPY)
        waiting = section(GUIDE, "} else {\n                    // The last step", "// 「あとで」")
        self.assertIn("ProgressView()", waiting)
        self.assertIn("Text(OnboardingPresentationCopy.widgetWaitingText)", waiting)
        self.assertNotIn("Button", waiting)
        self.assertIn('.accessibilityIdentifier("widget-placement-waiting")', waiting)
        # The old button and its hint are gone everywhere.
        for text in (GUIDE, COPY, APP_ROOT):
            self.assertNotIn("widgetAction", text)
            self.assertNotIn("widgetReturnHint", text)
            self.assertNotIn("ホーム画面で置いてきます", text)
            self.assertNotIn("追加してアプリへ戻ると、自動で確認します。", text)
        self.assertNotIn("widget-placement-complete", GUIDE)

    def test_later_stays_on_every_first_run_page(self):
        buttons = section(GUIDE, ".safeAreaInset(edge: .bottom) {", "/// A secondary button")
        later = section(buttons, "if closeTitle == nil {", ".accessibilityIdentifier(\"widget-placement-skip\")")
        self.assertIn("Button(OnboardingPresentationCopy.widgetLaterAction, action: onSkip)", later)
        # Its own `if`, after the next/waiting choice has closed: every page.
        self.assertIn('.accessibilityIdentifier("widget-placement-waiting")\n                }\n\n                if closeTitle == nil {',
                      buttons)

    def test_placed_screen_still_replaces_the_guide(self):
        guide_case = section(ONBOARDING, "case .widgetGuide:", "case .plusOffer:")
        self.assertIn("if isWidgetPlaced {", guide_case)
        self.assertIn("OnboardingWidgetPlacedPage(photo: resultPhotos.first, close: finish)", guide_case)
        self.assertIn("isWidgetPlaced: widgetInstallationChecker.isInstalled", APP_ROOT)

    def test_settings_guide_keeps_its_close_button(self):
        self.assertIn("if let closeTitle {", GUIDE)
        self.assertIn('.accessibilityIdentifier("widget-placement-close")', GUIDE)
        self.assertIn("Button(action: onComplete) {\n                        Text(closeTitle)", GUIDE)


class AlbumStripTests(unittest.TestCase):
    def test_this_month_opens_the_photos_tab_at_this_month(self):
        self.assertIn("var openPhotosMonth: ((Date) -> Void)? = nil", ALBUM)
        slot = section(ALBUM, "} else if month == thisMonth, let next {", "} else {\n            // 11/22")
        self.assertIn("Button { openPhotosMonth?(next.start) } label: {", slot)
        self.assertIn('.accessibilityIdentifier("album-prototype-this-month")', slot)
        self.assertIn("openPhotosMonth: openPhotos(atMonthOf:)", MAIN)
        jump = section(MAIN, "private func openPhotos(atMonthOf date: Date) {", "\n    }\n")
        # The 日付 jump's own way to a row: the saved reading place, then a
        # list made again (as when coming back from a photo).
        self.assertIn("PhotoLibraryGridRow.identifier(containing:", jump)
        self.assertIn("PhotoLibraryReadingPosition.save(", jump)
        self.assertIn("section: photoLibraryPositionKey(.all))", jump)
        self.assertIn("photoLibraryRevision &+= 1", jump)
        self.assertIn("photoLibrarySelection.select(.all)", jump)
        self.assertIn("selectedTab = .photos", jump)

    def test_months_without_a_work_are_only_a_label(self):
        empty = section(ALBUM, "} else {\n            // 11/22", "/// The year's work")
        self.assertNotIn("shape.fill", empty)
        self.assertNotIn("tertiarySystemFill", empty)
        self.assertNotIn("Button", empty)
        self.assertIn("Color.clear\n                .frame(width: Self.slotSize.width, height: Self.slotSize.height)", empty)
        self.assertIn('Text(verbatim: "\\(month)月")', empty)


class DeliverButtonTests(unittest.TestCase):
    def test_always_the_prominent_style(self):
        self.assertNotIn("DeliverButtonEmphasis", LIKED)
        self.assertNotIn("knowsAnyWindow", LIKED)
        button = section(LIKED, 'Label("まどに届ける", systemImage: "paperplane.fill")',
                         '.accessibilityIdentifier("photo-browser-deliver-group")')
        self.assertIn(".buttonStyle(.borderedProminent)", button)
        self.assertNotIn(".tint(Color.primary)", button)
        # The tap is unchanged: it opens the sheet for choosing or making a まど.
        self.assertIn("groupDelivery = GroupDeliveryRequest(localIdentifier: selectedPhoto.localIdentifier)", LIKED)


class TextRemovalTests(unittest.TestCase):
    def test_memo_box_has_no_hint(self):
        self.assertNotIn("このあと、どうなった？", NOTE)
        self.assertNotIn("photo-note-writing-hint", NOTE)
        self.assertIn('.accessibilityLabel("メモ")', NOTE)

    def test_photos_theme_row_has_no_heading(self):
        row = section(MAIN, "private func photoThemeRow(", "private var settingsSheet")
        self.assertNotIn('Text("テーマ")', row)
        self.assertIn('.accessibilityIdentifier("photos-theme-row")', row)


class CaptureTests(unittest.TestCase):
    def test_widget_guide_captures_still_reach_their_pages(self):
        # The 設定 guide is captured page by page; the first run's guide is
        # captured on its first page and left with 「あとで」.
        self.assertIn('app.buttons["widget-placement-close"]', UI_SHOTS)
        self.assertIn('one.buttons["widget-placement-skip"]', UI_SHOTS)
        self.assertNotIn("widget-placement-complete", UI_SHOTS)


if __name__ == "__main__":
    unittest.main()
