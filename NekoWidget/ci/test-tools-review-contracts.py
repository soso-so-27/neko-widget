"""Source contracts only; these do not execute Swift or confirm native UI behavior."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
def source(name):
    return next((ROOT / "NekoWidget").rglob(name)).read_text(encoding="utf-8")

class ToolsReviewContracts(unittest.TestCase):
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
        self.assertIn('guard state.visits.count < 100 else { throw VeterinaryVisitError.visitLimit }', store)
        self.assertIn('guard Self.validName(visit.catName)', store)
        self.assertIn('private static func validName(_ name: String) -> Bool { !name.isEmpty', store)
        view = source("VeterinaryVisitView.swift")
        self.assertIn('.disabled(!VeterinaryVisitStore.isValidCatName(newName.trimmingCharacters', view)
        verifier = (ROOT / "ci/verify-veterinary-visits.swift").read_text(encoding="utf-8")
        self.assertIn('Legacy whitespace name became unreadable', verifier)
        self.assertIn('Invalid name changed records', verifier)
        self.assertIn('Visit limit changed records', verifier)

    def test_lost_cat_cleanup_is_owned_and_wired_without_legacy_file_deletion(self):
        renderer = source("CatPreparednessStore.swift").split('enum LostCatFlyerRenderer', 1)[1]
        self.assertIn('UUID(uuidString: String(value.lastPathComponent.dropFirst(exportPrefix.count)))', renderer)
        self.assertIn('value.deletingLastPathComponent() == root', renderer)
        self.assertIn('.isSymbolicLinkKey', renderer)
        self.assertIn('[.atomic, .completeFileProtection]', renderer)
        self.assertEqual(renderer.count('return try writeExport(data, fileName:'), 2)
        self.assertIn('LostCatFlyerRenderer.cleanupOnLaunch()', source('NekoWidgetApp.swift'))
        view = source('CatPreparednessView.swift')
        self.assertIn('LostCatFlyerRenderer.removeExport(item.url)', view)
        self.assertIn('user-saved-copy', view)
        self.assertIn('FileProtectionType.complete.rawValue', view)

if __name__ == '__main__':
    unittest.main()
