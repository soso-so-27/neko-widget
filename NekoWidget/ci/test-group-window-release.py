#!/usr/bin/env python3
"""Exercise staging/public release isolation against real plist/IPA inputs."""
import importlib.util
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("group_release", Path(__file__).with_name("group-window-release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def info(flag="YES"):
    return {"GroupWindowsEnabled": flag, "SharingReleaseMode": "media-staging", "SharingAPIBaseURL": release.ORIGIN,
            "SharingFeatureEnabled": "YES", "SharingMediaEnabled": "YES"}


class GroupWindowReleaseTests(unittest.TestCase):
    def test_default_never_follows_media_or_protected_approval(self):
        for mode in ("disabled", "review-preview", "pairing-only", "media-staging"):
            self.assertEqual(release.resolve(False, mode, "YES"), "NO")

    def test_only_explicit_internal_media_request_can_enable(self):
        self.assertEqual(release.resolve(True, "media-staging", "YES"), "YES")
        for mode, approval in (("disabled", "YES"), ("pairing-only", "YES"), ("review-preview", "YES"),
                               ("media-staging", ""), ("media-staging", "yes")):
            with self.subTest(mode=mode, approval=approval), self.assertRaises(ValueError):
                release.resolve(True, mode, approval)

    def test_processed_info_cannot_enable_unrequested_or_wrong_endpoint(self):
        release.verify_info(info(), "YES")
        release.verify_info(info("NO"), "NO")
        for changed in ({"GroupWindowsEnabled": "YES"}, {"GroupWindowsEnabled": True}, {"GroupWindowsEnabled": "$(GROUP_WINDOWS_ENABLED)"}):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                release.verify_info({**info("NO"), **changed}, "NO")
        for changed in ({"SharingReleaseMode": "disabled"}, {"SharingAPIBaseURL": "https://production.invalid"},
                        {"SharingMediaEnabled": "NO"}, {"GroupWindowsEnabled": "yes"}):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                release.verify_info({**info(), **changed}, "YES")
        with self.assertRaises(ValueError):
            release.verify_info({}, "NO")

    def test_ipa_rejects_changed_compiled_flag(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app.ipa"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("Payload/NekoWidget.app/Info.plist", plistlib.dumps(info()))
            release.verify_ipa(path, "YES")
            with self.assertRaises(ValueError):
                release.verify_ipa(path, "NO")

    def test_internal_export_is_required_and_preserves_other_pilots(self):
        options = release.prepare_export({"method": "app-store-connect"}, "YES")
        self.assertIs(options["testFlightInternalTestingOnly"], True)
        release.verify_export(options, "YES")
        for value in ({}, {"testFlightInternalTestingOnly": False}, {"testFlightInternalTestingOnly": "true"}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.verify_export(value, "YES")
        self.assertEqual(release.prepare_export(options.copy(), "NO"), options)


if __name__ == "__main__":
    unittest.main()
