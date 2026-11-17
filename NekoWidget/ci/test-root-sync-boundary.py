"""Only the two internal probe routes may reach the root sync store."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
STORE = ROOT / "NekoWidget/Services/RootSyncStore.swift"
VIEW = ROOT / "NekoWidget/Views/KeychainSyncProbeView.swift"
LIVE = ROOT / "NekoWidget/Services/GroupRecoveryLiveSession.swift"


class Boundary(unittest.TestCase):
    def test_definitions_and_callers_are_internal_compilation_only(self):
        for path in (STORE, VIEW):
            text = path.read_text(encoding="utf-8")
            self.assertTrue(text.startswith("#if DEBUG || INTERNAL_PRESENTATION\n"))
            self.assertTrue(text.rstrip().endswith("#endif"))
            self.assertEqual(len(re.findall(r"(?m)^#(?:if|elseif|else|endif)\b", text)), 2)
        live = LIVE.read_text(encoding="utf-8")
        self.assertTrue(live.startswith("#if DEBUG || INTERNAL_PRESENTATION\n"))
        self.assertTrue(live.rstrip().endswith("#endif"))
        self.assertEqual(sum(1 for line in live.splitlines() if "RootSyncStore(bundleID:" in line), 1)
        self.assertIn("sync.publishCurrentRoot(authenticate:", live)
        self.assertNotIn(".diagnostic.1115e", live)
        for path in (ROOT / "NekoWidget").rglob("*.swift"):
            if path in (STORE, VIEW, LIVE):
                continue
            self.assertNotRegex(path.read_text(encoding="utf-8"), r"\b(?:RootSyncStore|SystemRootSyncKeychain|P2RootSyncProbeView)\b", str(path))

    def test_no_other_targets_or_real_store_changes(self):
        project = (ROOT / "NekoWidget.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
        self.assertEqual(project.count("RootSyncStore.swift in Sources */ ="), 1)
        self.assertEqual(project.count("RootSyncStore.swift in Sources */,"), 1)
        text = STORE.read_text(encoding="utf-8")
        self.assertNotIn("SecItemUpdate", text)
        self.assertNotIn("ThisDeviceOnly", text)
        self.assertNotIn("GroupKeychainStore", text)
        view = VIEW.read_text(encoding="utf-8")
        self.assertIn('".diagnostic.1115e"', view)
        self.assertIn("environment: .synthetic", view)


if __name__ == "__main__":
    unittest.main()
