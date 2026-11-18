#!/usr/bin/env python3
"""Exercise staging/public release isolation against real plist/IPA inputs."""
import importlib.util
import json
import plistlib
import subprocess
import sys
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
    def test_real_family_requires_explicit_owner_staging_and_approved_groups(self):
        self.assertEqual(release.resolve_family(True, "owner-internal", "media-staging", "YES"), "YES")
        for profile in ("owner-internal", "existing-reviewed", "app-store-candidate", ""):
            for mode in ("media-staging", "production", "disabled"):
                for groups in ("YES", "NO"):
                    self.assertEqual(release.resolve_family(False, profile, mode, groups), "NO")
                    if (profile, mode, groups) != ("owner-internal", "media-staging", "YES"):
                        with self.subTest(profile=profile, mode=mode, groups=groups), self.assertRaises(ValueError):
                            release.resolve_family(True, profile, mode, groups)
        with self.assertRaises(ValueError):
            release.resolve_family("true", "owner-internal", "media-staging", "YES")

    def test_two_device_staging_requires_the_reviewed_owner_profile(self):
        self.assertEqual(release.resolve_two_device(True, "owner-internal", "media-staging", "YES"), "YES")
        for profile, mode, family in (("existing-reviewed", "media-staging", "YES"),
                                      ("app-store-candidate", "production", "YES"),
                                      ("owner-internal", "production", "YES"),
                                      ("owner-internal", "media-staging", "NO")):
            with self.subTest(profile=profile, mode=mode, family=family), self.assertRaises(ValueError):
                release.resolve_two_device(True, profile, mode, family)
        enabled = {**info(), "FamilyNotebookProductionEnabled": "YES",
                   "OwnerInternalReportsDisabled": "YES", release.TWO_DEVICE_KEY: "YES"}
        release.verify_info(enabled, "YES", "YES", "YES")
        for changed in ({"OwnerInternalReportsDisabled": "NO"},
                        {"SharingAPIBaseURL": "https://api.nekonomado.com"},
                        {release.TWO_DEVICE_KEY: "NO"}):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                release.verify_info({**enabled, **changed}, "YES", "YES", "YES")
        with self.assertRaises(ValueError):
            release.verify_info(enabled, "YES", "YES", "NO")
        with self.assertRaisesRegex(ValueError, "Public candidate carries"):
            release.validate_production(enabled, {}, {})

    def test_family_archive_ipa_and_export_are_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Info.plist"
            ipa = root / "app.ipa"
            export = root / "ExportOptions.plist"
            env = root / "env"
            app.write_bytes(plistlib.dumps({**info(), "FamilyNotebookProductionEnabled": "YES"}))
            export.write_bytes(plistlib.dumps({"method": "app-store-connect"}))
            with zipfile.ZipFile(ipa, "w") as archive:
                archive.writestr("Payload/NekoWidget.app/Info.plist", app.read_bytes())
            args = [sys.executable, str(Path(__file__).with_name("group-window-release.py")),
                    "--requested", "true", "--approval", "YES", "--mode", "media-staging",
                    "--family-requested", "true", "--profile", "owner-internal", "--env-file", str(env),
                    "--app-info-plist", str(app), "--ipa", str(ipa), "--export-options-plist", str(export)]
            subprocess.run(args, check=True, capture_output=True)
            self.assertIn("RELEASE_FAMILY_NOTEBOOK_ENABLED=YES\n", env.read_text())
            self.assertIs(plistlib.loads(export.read_bytes())["testFlightInternalTestingOnly"], True)
            for changed in ({"FamilyNotebookProductionEnabled": "NO"}, {"FamilyNotebookProductionEnabled": True},
                            {"FamilyNotebookProductionEnabled": "$(FAMILY_NOTEBOOK_PRODUCTION_ENABLED)"},
                            {"SharingAPIBaseURL": "https://api.nekonomado.com"}):
                with self.subTest(changed=changed), self.assertRaises(ValueError):
                    release.verify_info({**info(), "FamilyNotebookProductionEnabled": "YES", **changed}, "YES", "YES")
            with self.assertRaises(ValueError):
                release.verify_ipa(ipa, "YES", "NO")

    def test_two_device_billing_is_part_of_the_archive_and_ipa_boundary(self):
        trial = release.trial_config(json.dumps({"proof": "A" * 43, "owner": "A" * 43, "window": "A" * 22,
                                                  "family": "98b47c5f-0dc4-4ed2-a2c2-26d0173db946"}))
        signed = {**info(), "FamilyNotebookProductionEnabled": "YES",
                  "OwnerInternalReportsDisabled": "YES", release.TWO_DEVICE_KEY: "YES",
                  "PlusBillingClientEnabled": "YES", "PlusStorefrontEnabled": "YES",
                  "PlusBillingAPIBaseURL": release.ORIGIN, "PlusMonthlyProductID": "jp.nekowidget.plus.monthly",
                  "PlusAnnualProductID": "", "PlusBillingRecoveryEnabled": "NO",
                  "PlusWindowSponsorshipClientEnabled": "NO",
                  "ManagedPreservationEnabled": "NO", "MembershipAccessEnforced": True, release.TRIAL_KEY: trial}
        release.verify_info(signed, "YES", "YES", "YES", sandbox_billing=True, trial=trial)
        with self.assertRaises(ValueError):
            release.verify_info(signed, "YES", "YES", "YES")
        for key, value in (("PlusBillingClientEnabled", "NO"), ("PlusStorefrontEnabled", "NO"),
                           ("PlusBillingAPIBaseURL", "https://api.nekonomado.com"),
                           ("PlusMonthlyProductID", "wrong"), ("ManagedPreservationEnabled", "YES"),
                           ("PlusAnnualProductID", "annual"), ("PlusBillingRecoveryEnabled", "YES"),
                           ("PlusWindowSponsorshipClientEnabled", "YES"),
                           ("MembershipAccessEnforced", False)):
            with self.subTest(key=key), self.assertRaises(ValueError):
                release.verify_info({**signed, key: value}, "YES", "YES", "YES", sandbox_billing=True, trial=trial)
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "owner.ipa"
            with zipfile.ZipFile(ipa, "w") as archive:
                archive.writestr("Payload/NekoWidget.app/Info.plist", plistlib.dumps(signed))
            release.verify_ipa(ipa, "YES", "YES", "YES", sandbox_billing=True, trial=trial)
            with self.assertRaises(ValueError):
                release.verify_ipa(ipa, "YES", "YES", "YES")
        with self.assertRaises(ValueError):
            release.prepare_trial_info(signed, None)
        with self.assertRaises(ValueError):
            release.trial_config(json.dumps({**trial, "proof": "B" * 43}))

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
