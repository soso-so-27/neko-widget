"""Only the 機種変更 connection and the internal probe may reach the root sync store.

11/19: the store and the live connection ship in the App Store build with
機種変更 (the relay's gate decides whether anything happens). The diagnostic
probe screen stays internal. The person key is still published only after
the person's own tap and device-owner authentication.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
STORE = ROOT / "NekoWidget/Services/RootSyncStore.swift"
VIEW = ROOT / "NekoWidget/Views/KeychainSyncProbeView.swift"
LIVE = ROOT / "NekoWidget/Services/GroupRecoveryLiveSession.swift"


class Boundary(unittest.TestCase):
    def test_definitions_and_callers(self):
        # The probe screen is internal compilation only.
        view = VIEW.read_text(encoding="utf-8")
        self.assertTrue(view.startswith("#if DEBUG || INTERNAL_PRESENTATION\n"))
        self.assertTrue(view.rstrip().endswith("#endif"))
        self.assertEqual(len(re.findall(r"(?m)^#(?:if|elseif|else|endif)\b", view)), 2)
        # The store and the live connection are public, without a compilation gate.
        store = STORE.read_text(encoding="utf-8")
        self.assertNotRegex(store, r"(?m)^#(?:if|elseif|else|endif)\b")
        live = LIVE.read_text(encoding="utf-8")
        self.assertFalse(live.startswith("#if DEBUG || INTERNAL_PRESENTATION\n"))
        self.assertEqual(sum(1 for line in live.splitlines() if "RootSyncStore(bundleID:" in line), 1)
        # Publishing the person key: only from the tap, after the device owner's check.
        self.assertEqual(live.count("sync.publishCurrentRoot(authenticate:"), 1)
        self.assertIn("context.evaluatePolicy(.deviceOwnerAuthentication,", live)
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
