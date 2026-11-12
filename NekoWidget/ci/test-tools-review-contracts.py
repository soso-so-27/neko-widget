"""Source contracts only; these do not execute Swift or confirm native UI behavior."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
def source(name):
    return next((ROOT / "NekoWidget").rglob(name)).read_text(encoding="utf-8")

class ToolsReviewContracts(unittest.TestCase):
    # 11/12 (案D): the tools are one row of five equal round buttons; at the
    # accessibility text sizes they become one column of rows (it was a
    # two-column grid of tiles with one column at those sizes).
    def assert_tools_bar_columns(self, text):
        bar=text.split('private struct CatHomeToolBar: View {',1)[1].split('/// A round button:',1)[0]
        body=bar.split('    var body: some View {',1)[1].split('    /// 「書きかけ」 in orange',1)[0]
        rows,buttons=body.split('} else {',1)
        self.assertIn('if typeSize.isAccessibilitySize {',rows)
        self.assertIn('CatHomeToolRow(tool: tool, state: state(tool))',rows)
        self.assertNotIn('HStack',rows)
        self.assertIn('let column = (width - 32) / 5',buttons)
        self.assertIn('let circle = min(66, max(column - 8, 44))',buttons)
        self.assertIn('.frame(width: column)',buttons)
        self.assertIn('CatHomeToolButton(tool: tool, state: state(tool), circle: circle)',buttons)

    def test_tools_bar_keeps_five_equal_columns_and_accessibility_rows(self):
        self.assert_tools_bar_columns(source('CatHomeView.swift'))

    def test_unequal_or_unscaled_columns_are_rejected(self):
        text=source('CatHomeView.swift')
        for good,bad in (('let column = (width - 32) / 5','let column = (width - 32) / 4'),
                         ('let circle = min(66, max(column - 8, 44))','let circle = CGFloat(66)'),
                         ('.frame(width: column)','.frame(maxWidth: .infinity)')):
            with self.subTest(part=good):
                self.assertEqual(text.count(good),1)
                with self.assertRaises(AssertionError):
                    self.assert_tools_bar_columns(text.replace(good,bad))

    def test_picker_keeps_saving_sheet_and_selection_stable(self):
        picker = source("ShowcasePhotoView.swift").split("private struct ShowcaseCandidatePicker", 1)[1]
        self.assertIn('Button("キャンセル") { dismiss() }.disabled(isSaving)', picker)
        self.assertIn('.interactiveDismissDisabled(isSaving)', picker)
        self.assertIn('guard !isSaving else { return }', picker)
        self.assertIn('.accessibilityLabel(candidateLabel(photo, index: index))', picker)
        self.assertIn('index + 1', picker)
        self.assertIn('photo.creationDate', picker)

    def test_name_validation_does_not_change_persistent_schema_acceptance(self):
        store = source("VeterinaryVisitStore.swift")
        self.assertIn('guard Self.isValidCatName(catName) else { throw VeterinaryVisitError.invalidName }', store)
        self.assertIn('guard state.visits.count < 36_500 else { throw VeterinaryVisitError.visitLimit }', store)
        self.assertIn('guard Self.validName(visit.catName)', store)
        self.assertIn('private static func validName(_ name: String) -> Bool { !name.isEmpty', store)
        view = source("VeterinaryVisitView.swift")
        # The name prompt is gone (10/21); a vet memo starts from a cat the tools know,
        # and the store still refuses an invalid name.
        self.assertNotIn('alert("猫の名前"', view)
        verifier = (ROOT / "ci/verify-veterinary-visits.swift").read_text(encoding="utf-8")
        self.assertIn('Legacy whitespace name became unreadable', verifier)
        self.assertIn('Invalid name changed records', verifier)
        self.assertIn('The former 100-visit ceiling still blocked a new visit', verifier)
        self.assertIn('Capacity migration changed prior visits', verifier)

    def test_lost_cat_cleanup_is_owned_and_wired_without_legacy_file_deletion(self):
        renderer = source("CatPreparednessStore.swift").split('enum LostCatFlyerRenderer', 1)[1]
        self.assertIn('UUID(uuidString: String(value.lastPathComponent.dropFirst(exportPrefix.count)))', renderer)
        self.assertIn('value.deletingLastPathComponent() == root', renderer)
        self.assertIn('.isSymbolicLinkKey', renderer)
        self.assertIn('[.atomic, .completeFileProtection]', renderer)
        self.assertEqual(renderer.count('return try writeExport(data, fileName:'), 3)
        # Every file written for sharing is one the cleanup owns (round 2: the
        # story, the small flyer and 「見つかりました」 too).
        self.assertIn('return try writeExport(data, fileName: "迷子の猫.png")', renderer)
        self.assertIn('return try writeExport(data, fileName: "迷子の猫.pdf")', renderer)
        self.assertIn('return try writeExport(data, fileName: LostCatOutput.foundFileName)', renderer)
        self.assertEqual(renderer.count('fileName: output.fileName'), 2)
        self.assertIn('guard LostCatOutput.exportFileNames.contains(file.lastPathComponent) else { return }', renderer)
        model = source('LostCatIncident.swift')
        for name in ('"迷子の猫.png"', '"迷子の猫.pdf"', '"迷子の猫_ストーリー.png"', '"迷子の猫_小さいチラシ.pdf"', '"見つかりました.png"'):
            self.assertIn(name, model)
        self.assertIn('Set(allCases.map(\\.fileName)).union([foundFileName])', model)
        self.assertIn('LostCatFlyerRenderer.cleanupOnLaunch()', source('NekoWidgetApp.swift'))
        view = source('CatPreparednessView.swift')
        self.assertIn('LostCatFlyerRenderer.removeExport(item.url)', view)
        self.assertIn('user-saved-copy', view)
        self.assertIn('FileProtectionType.complete.rawValue', view)

if __name__ == '__main__':
    unittest.main()
