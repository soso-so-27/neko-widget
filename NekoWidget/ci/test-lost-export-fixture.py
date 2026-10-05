"""Source regressions only; Apple runtime verifies attribute values and lifecycle."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
VIEW = ROOT / "NekoWidget/NekoWidget/Views/CatPreparednessView.swift"
UI = ROOT / "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift"

class LostExportFixtureTests(unittest.TestCase):
    def test_native_unsupported_still_fails_closed_before_modeled_success(self):
        source = VIEW.read_text(encoding="utf-8")
        case = source.split("static func verifyExportLifecycle", 1)[1].split("static func prepareSavedInformation", 1)[0]
        self.assertIn("[LostCatFlyerRenderer.createImage, LostCatFlyerRenderer.createPDF]", case)
        self.assertIn("failure.target == .directory && failure.reason == .missing", case)
        self.assertIn("try require(nativeMissing", case)
        self.assertIn("try ownedDirectories() == before", case)
        self.assertLess(case.index("try require(nativeMissing"), case.index("createFixtureImage"))
        self.assertIn("UIImage(data: Data(contentsOf: png))", case)
        self.assertIn('Data("%PDF-".utf8)', case)
        self.assertIn(".unknownType, .wrongClass, .readFailed, .setFailed", case)

    def test_failure_codes_are_closed_and_do_not_contain_raw_errors(self):
        source = VIEW.read_text(encoding="utf-8")
        fixture = source.split("struct LostCatDraftFixtureView", 1)[1]
        self.assertIn("private enum ExportLifecycleFailure: String, Error", fixture)
        self.assertIn('lifecycleResult = "failed:\(failure.rawValue)"', fixture)
        self.assertIn('lifecycleResult = "failed:operation"', fixture)
        self.assertNotIn('\(error)', fixture)
        self.assertNotIn("String(describing: error)", fixture)
        self.assertIn("requested == .complete", fixture)
        self.assertIn(".foreignCopy)", fixture)
        self.assertIn(".symbolicLink)", fixture)

    def test_fixture_injection_is_debug_only_and_scoped_to_fixture_view(self):
        source = VIEW.read_text(encoding="utf-8")
        renderer = (ROOT / "NekoWidget/NekoWidget/Services/CatPreparednessStore.swift").read_text(encoding="utf-8")
        self.assertIn("#if DEBUG\n    static func createFixtureImage", renderer)
        self.assertIn("#if DEBUG\n        // Explicit fixture injection", renderer)
        self.assertIn("case .native: try LostCatFlyerRenderer.enforceExportProtection", renderer)
        model = renderer.split("case .fixture(let verify):", 1)[1].split("#endif", 1)[0]
        self.assertIn("try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete]", model)
        self.assertLess(model.index("setAttributes"), model.index("try LostCatFlyerRenderer.validateExportProtection(verify"))
        self.assertIn("static let defaultValue:", source)
        self.assertIn("= nil", source.split("private struct LostCatFixtureVerificationKey", 1)[1].split("private extension", 1)[0])
        self.assertEqual(source.count(".environment(\\.lostCatFixtureVerification"), 1)
        self.assertIn(".environment(\\.lostCatFixtureVerification, Self.verifyFixtureExport)", source.split("struct LostCatDraftFixtureView", 1)[1])

    def test_ui_case_waits_for_completion_then_reports_fixed_failure(self):
        source = UI.read_text(encoding="utf-8")
        case = source.split("func testLostCatExportLifecycleProtectsAndRemovesOnlyManagedCopies", 1)[1].split("@MainActor", 1)[0]
        self.assertIn('label == %@ OR label BEGINSWITH %@', case)
        self.assertIn('"passed", "failed:"', case)
        self.assertIn('XCTAssertEqual(result.label, "passed"', case)

if __name__ == "__main__":
    unittest.main()
