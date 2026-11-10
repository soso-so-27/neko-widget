"""Source contracts for two observed Simulator failures; native rerun still required."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
VIEW = (ROOT / "NekoWidget/Views/PhotoMemoryNoteLibraryView.swift").read_text(encoding="utf-8")
UI = (ROOT / "NekoWidgetUITests/PhotoPermissionUITests.swift").read_text(encoding="utf-8")

class MemoRowNavigationTests(unittest.TestCase):
    def test_plain_memo_link_has_a_hit_shape_without_thumbnail(self):
        row = VIEW.split("private func row(", 1)[1].split("private struct MemoryNotesSearchBar", 1)[0]
        self.assertIn(".contentShape(Rectangle())", row)
        denied = UI.split("func testAlbumRootUpdatesAndPreservesFavoritesAndReflectionDestinations()", 1)[1].split("    @MainActor", 1)[0]
        self.assertIn('unavailableMemo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()', denied)
        self.assertIn('memory-note-photo-unavailable', denied)
        self.assertIn('XCTAssertFalse(memoApp.buttons["memory-note-photo"].exists', denied)
        self.assertIn('Photo authority changes must preserve local memo text.', denied)

    def test_large_weight_fixture_reveals_the_matching_record(self):
        helper = UI.split("private func launchWeightMemo(", 1)[1].split("    @MainActor", 1)[0]
        self.assertIn('app.keyboards.firstMatch.waitForNonExistence', helper)
        self.assertIn('app.scrollViews["memory-notes-list"]', helper)
        self.assertIn('notesList.swipeUp(velocity: .slow)', helper)
        self.assertIn('row.exists && row.isHittable', helper)
        self.assertIn('食べる量が少なかった', helper)
        case = UI.split("func testVeterinaryWithoutPhotoKeepsUnknownMeasurementDayAtLargestText()", 1)[1].split("    @MainActor", 1)[0]
        self.assertIn('reading.staticTexts["むぎ · 測定日 不明"]', case)
        self.assertIn('XCTAssertFalse(reading.staticTexts["選んでいない別の猫の記録"].exists)', case)

    def test_rows_name_only_assigned_cats_and_every_list_route_knows_them(self):
        row = VIEW.split("private func row(", 1)[1].split("private struct MemoryNotesSearchBar", 1)[0]
        # 11/10: no cat assigned shows nothing; current names, else 「メモを書いたとき」.
        self.assertNotIn("写っている猫を選んでいません", VIEW)
        self.assertIn('Text(currentNames.joined(separator: "・"))', row)
        self.assertIn('Text("メモを書いたとき：" + item.cats.joined(separator: "・"))', row)
        main = (ROOT / "NekoWidget/Views/MainTabView.swift").read_text(encoding="utf-8")
        route = main.split("case .memoryNotes:", 1)[1].split("case let .memoryNote(", 1)[0]
        self.assertIn("currentPhotoAssignments: currentPhotoLibraryAssignments", route)
        self.assertIn("registeredProfileIdentifiers: photoLibraryRegisteredIdentifiers", route)
        self.assertIn("currentProfileNames: currentPhotoLibraryProfileNames", route)

    def test_memo_page_reaches_the_vet_only_through_its_picker(self):
        detail = VIEW.split("struct PhotoMemoryNoteDetailView: View {", 1)[1].split("struct PhotoMemoryNotePhotoDestination", 1)[0]
        # 11/10: one place: 病院で見せる → 「写真を選ぶ」 → 「写真に付けたメモ」.
        self.assertNotIn("診察メモに追加", detail)
        self.assertNotIn("VeterinaryVisitsView", detail)
        self.assertIn('"memory-note-deliver-group"', detail)
        self.assertNotIn("memory-note-add-vet", UI)
        helper = UI.split("private func openVetConfirmationThroughPicker(", 1)[1].split("    @MainActor", 1)[0]
        self.assertIn('app.buttons["vet-pick-records"]', helper)
        self.assertIn("revealVetPickerMemos(app)", helper)
        self.assertIn('app.navigationBars["内容を確認"]', helper)
        for name in ("testVeterinarySelectionIsExplicitAndRemovalKeepsSource",
                     "testVeterinaryWithoutPhotoKeepsUnknownMeasurementDayAtLargestText"):
            case = UI.split(f"func {name}()", 1)[1].split("    @MainActor", 1)[0]
            self.assertIn("openVetConfirmationThroughPicker(cat, memo:", case)
            self.assertIn('buttons["vet-pick-done"].tap()', case)


if __name__ == "__main__":
    unittest.main()
