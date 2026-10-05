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
        self.assertLess(writer.index("try verification.verify(directory, target: .directory)"), writer.index("try data.write"))
        self.assertLess(writer.index("try data.write"), writer.index("try verification.verify(file, target: .file)"))
        self.assertLess(writer.index("try verification.verify(file, target: .file)"), writer.index("return file"))
        self.assertIn("catch { removeExport(file); throw error }", writer)

    def test_protection_is_set_verified_strictly_and_not_skipped_on_simulator(self):
        guard = SOURCE.split("private static func enforceExportProtection", 1)[1].split("static func removeExport", 1)[0]
        self.assertIn("try manager.setAttributes([.protectionKey: FileProtectionType.complete]", guard)
        self.assertIn("try manager.attributesOfItem", guard)
        self.assertIn("guard protection == FileProtectionType.complete.rawValue else", guard)
        self.assertIn("throw ExportProtectionFailure(target: target, reason: .wrongClass)", guard)
        self.assertNotIn("targetEnvironment(simulator)", guard)
        self.assertNotIn("try?", guard)
        self.assertNotIn("completeUntilFirstUserAuthentication", guard)

    def test_diagnostics_are_closed_and_do_not_expose_underlying_errors(self):
        definition = SOURCE.split("struct ExportProtectionFailure", 1)[1].split("static func removeExport", 1)[0]
        self.assertIn("case directory, file", definition)
        self.assertIn("case createFailed, writeFailed, setFailed, readFailed, missing, unknownType, wrongClass", definition)
        for reason in ("setFailed", "readFailed", "missing", "unknownType", "wrongClass"):
            self.assertIn("reason: ." + reason, definition)
        for forbidden in ("localizedDescription", "NSError", "error.userInfo"):
            self.assertNotIn(forbidden, definition)
        self.assertIn("target: .directory, reason: .createFailed", SOURCE)
        self.assertIn("target: .file, reason: .writeFailed", SOURCE)
        fixture = (ROOT / "NekoWidget/NekoWidget/Views/CatPreparednessView.swift").read_text(encoding="utf-8")
        self.assertIn("catch let failure as LostCatFlyerRenderer.ExportProtectionFailure", fixture)
        self.assertIn("failure.diagnosticCode", fixture)

    def test_image_and_pdf_remain_on_same_owned_lifecycle(self):
        self.assertIn('return try writeExport(data, fileName: "迷子の猫.png")', SOURCE)
        self.assertIn('return try writeExport(data, fileName: "迷子の猫.pdf")', SOURCE)
        self.assertIn("value.deletingLastPathComponent() == root", SOURCE)
        self.assertIn("UUID(uuidString: String(value.lastPathComponent.dropFirst(exportPrefix.count)))", SOURCE)
        self.assertIn(".isSymbolicLinkKey", SOURCE)
        fixture = (ROOT / "NekoWidget/NekoWidget/Views/CatPreparednessView.swift").read_text(encoding="utf-8")
        self.assertIn("verifiedTargets == [.directory, .file, .directory, .file]", fixture)
        self.assertIn("requested == .complete", fixture)

if __name__ == "__main__": unittest.main()
