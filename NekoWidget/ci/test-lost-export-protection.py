"""Source boundaries for native fileProtection failure. Apple rerun required."""
from pathlib import Path
import subprocess
import unittest
ROOT = Path(__file__).resolve().parents[2]
PATH = "NekoWidget/NekoWidget/Services/CatPreparednessStore.swift"
SOURCE = (ROOT / PATH).read_text(encoding="utf-8")

class LostExportProtectionTests(unittest.TestCase):
    def test_atomic_final_file_is_protected_before_url_is_returned(self):
        baseline = subprocess.check_output(["git", "show", "b2a6d82:" + PATH], cwd=ROOT).decode("utf-8")
        self.assertNotIn("try enforceExportProtection(file)", baseline)
        writer = SOURCE.split("private static func writeExport", 1)[1].split("private static func enforceExportProtection", 1)[0]
        self.assertLess(writer.index("try enforceExportProtection(directory)"), writer.index("try data.write"))
        self.assertLess(writer.index("try data.write"), writer.index("try enforceExportProtection(file)"))
        self.assertLess(writer.index("try enforceExportProtection(file)"), writer.index("return file"))
        self.assertIn("catch { removeExport(file); throw error }", writer)

    def test_protection_is_set_verified_strictly_and_not_skipped_on_simulator(self):
        guard = SOURCE.split("private static func enforceExportProtection", 1)[1].split("static func removeExport", 1)[0]
        self.assertIn("try manager.setAttributes([.protectionKey: FileProtectionType.complete]", guard)
        self.assertIn("try manager.attributesOfItem", guard)
        self.assertIn("guard protection == FileProtectionType.complete.rawValue else", guard)
        self.assertIn("throw CocoaError(.fileWriteNoPermission)", guard)
        self.assertNotIn("targetEnvironment(simulator)", guard)
        self.assertNotIn("try?", guard)
        self.assertNotIn("completeUntilFirstUserAuthentication", guard)

    def test_image_and_pdf_remain_on_same_owned_lifecycle(self):
        self.assertEqual(SOURCE.count("return try writeExport(data, fileName:"), 2)
        self.assertIn("value.deletingLastPathComponent() == root", SOURCE)
        self.assertIn("UUID(uuidString: String(value.lastPathComponent.dropFirst(exportPrefix.count)))", SOURCE)
        self.assertIn(".isSymbolicLinkKey", SOURCE)
        fixture = (ROOT / "NekoWidget/NekoWidget/Views/CatPreparednessView.swift").read_text(encoding="utf-8")
        self.assertIn("try require(protection == FileProtectionType.complete.rawValue", fixture)
        self.assertIn(".fileProtection : .directoryProtection", fixture)

if __name__ == "__main__": unittest.main()
