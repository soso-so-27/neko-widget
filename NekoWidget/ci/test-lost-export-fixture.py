"""Source regressions only; Apple runtime verifies attribute values and lifecycle."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
VIEW = ROOT / "NekoWidget/NekoWidget/Views/CatPreparednessView.swift"
UI = ROOT / "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift"

class LostExportFixtureTests(unittest.TestCase):
    def test_valid_typed_protection_is_not_rejected_as_non_string(self):
        source = VIEW.read_text(encoding="utf-8")
        baseline = subprocess.check_output(["git", "show", "d70f4c2:NekoWidget/NekoWidget/Views/CatPreparednessView.swift"], cwd=ROOT).decode("utf-8")
        self.assertNotIn("(attributes[.protectionKey] as? FileProtectionType)?.rawValue", baseline)
        self.assertIn("(attributes[.protectionKey] as? FileProtectionType)?.rawValue", source)
        self.assertIn("?? (attributes[.protectionKey] as? String)", source)
        self.assertIn("protection == FileProtectionType.complete.rawValue", source)
        self.assertNotIn("targetEnvironment(simulator)", source)

    def test_failure_codes_are_closed_and_do_not_contain_raw_errors(self):
        source = VIEW.read_text(encoding="utf-8")
        fixture = source.split("struct LostCatDraftFixtureView", 1)[1]
        self.assertIn("private enum ExportLifecycleFailure: String, Error", fixture)
        self.assertIn('lifecycleResult = "failed:\(failure.rawValue)"', fixture)
        self.assertIn('lifecycleResult = "failed:operation"', fixture)
        self.assertNotIn('\(error)', fixture)
        self.assertNotIn("String(describing: error)", fixture)
        self.assertIn(".fileProtection : .directoryProtection", fixture)
        self.assertIn(".foreignCopy)", fixture)
        self.assertIn(".symbolicLink)", fixture)

    def test_ui_case_waits_for_completion_then_reports_fixed_failure(self):
        source = UI.read_text(encoding="utf-8")
        case = source.split("func testLostCatExportLifecycleProtectsAndRemovesOnlyManagedCopies", 1)[1].split("@MainActor", 1)[0]
        self.assertIn('label == %@ OR label BEGINSWITH %@', case)
        self.assertIn('"passed", "failed:"', case)
        self.assertIn('XCTAssertEqual(result.label, "passed"', case)

if __name__ == "__main__":
    unittest.main()
