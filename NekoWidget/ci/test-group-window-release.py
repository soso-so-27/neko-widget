#!/usr/bin/env python3
"""Exercise staging/public release isolation against real plist/IPA inputs."""
import importlib.util
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


def info(flag="YES", trial="NO"):
    return {"GroupWindowsEnabled": flag, "SharingReleaseMode": "media-staging", "SharingAPIBaseURL": release.ORIGIN,
            "SharingFeatureEnabled": "YES", "SharingMediaEnabled": "YES", release.TRIAL_KEY: trial,
            "SharingInternalEncryptedReportEnabled": True,
            "SharingInternalEncryptedReportScope": release.internal_report_release.SCOPE,
            "SharingModerationKeyID": "moderation-v2",
            "SharingModerationPublicKey": release.internal_report_release.PUBLIC_KEY,
            "SharingReviewPreviewEnabled": "NO", "SharingShareExtensionSendEnabled": "NO"}


def write_ipa(path, app_info, extension_flag="NO"):
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("Payload/NekoWidget.app/Info.plist", plistlib.dumps(app_info))
        for target in ("NekoWidgetShareExtension", "NekoWidgetWidgetExtension"):
            archive.writestr(f"Payload/NekoWidget.app/PlugIns/{target}.appex/Info.plist", plistlib.dumps({
                release.TRIAL_KEY: extension_flag, "SharingInternalEncryptedReportEnabled": False,
                "SharingInternalEncryptedReportScope": "",
            }))


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

    def test_trial_requires_explicit_request_and_existing_internal_approvals(self):
        scope = release.internal_report_release.SCOPE
        self.assertEqual(release.resolve_trial(False, "YES", "media-staging", True, "YES", scope), "NO")
        self.assertEqual(release.resolve_trial(True, "YES", "media-staging", True, "YES", scope), "YES")
        for values in (("NO", "media-staging", True, "YES", scope),
                       ("YES", "media-staging", False, "YES", scope),
                       ("YES", "disabled", True, "YES", scope),
                       ("YES", "media-staging", True, "", scope),
                       ("YES", "media-staging", True, "YES", "foreign-scope")):
            with self.subTest(values=values), self.assertRaises(ValueError):
                release.resolve_trial(True, *values)

    def test_ordinary_build_rejects_accidental_real_report_enablement(self):
        for value in ("YES", True, "$(GROUP_REPORTING_PRODUCTION_ENABLED)", None):
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.verify_info({**info(), release.TRIAL_KEY: value}, "YES")

    def test_trial_archive_requires_correct_key_endpoint_and_internal_scope(self):
        release.verify_info(info(trial="YES"), "YES", "YES")
        for changed in ({release.TRIAL_KEY: "NO"}, {release.TRIAL_KEY: True},
                        {"SharingInternalEncryptedReportEnabled": False},
                        {"SharingInternalEncryptedReportScope": ""},
                        {"SharingModerationKeyID": "moderation-v1"},
                        {"SharingModerationPublicKey": "foreign-key"},
                        {"SharingAPIBaseURL": "https://production.invalid"},
                        {"SharingShareExtensionSendEnabled": "YES"}):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                release.verify_info({**info(trial="YES"), **changed}, "YES", "YES")

    def test_trial_checks_actual_exported_ipa_and_extensions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "trial.ipa"
            write_ipa(path, info(trial="YES"))
            release.verify_ipa(path, "YES", "YES")
            with self.assertRaises(ValueError):
                release.verify_ipa(path, "YES", "NO")
            write_ipa(path, info(trial="NO"))
            with self.assertRaises(ValueError):
                release.verify_ipa(path, "YES", "YES")
            write_ipa(path, info(trial="YES"), extension_flag="YES")
            with self.assertRaises(ValueError):
                release.verify_ipa(path, "YES", "YES")
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("Payload/NekoWidget.app/Info.plist", plistlib.dumps(info(trial="YES")))
            with self.assertRaises(ValueError):
                release.verify_ipa(path, "YES", "YES")

    def test_trial_cli_prepares_and_verifies_export_before_upload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, ipa, env, options = (root / n for n in ("Info.plist", "trial.ipa", "env", "ExportOptions.plist"))
            app.write_bytes(plistlib.dumps(info(trial="YES")))
            write_ipa(ipa, info(trial="YES"))
            options.write_bytes(plistlib.dumps({"method": "app-store-connect"}))
            command = [sys.executable, str(Path(release.__file__)), "--requested", "true", "--mode", "media-staging",
                       "--approval", "YES", "--report-trial-requested", "true", "--internal-reports-requested", "true",
                       "--internal-reports-approval", "YES", "--internal-reports-scope", release.internal_report_release.SCOPE]
            for arguments in (("--env-file", str(env)),
                              ("--app-info-plist", str(app), "--export-options-plist", str(options)),
                              ("--ipa", str(ipa), "--verify-export-options-plist", str(options))):
                result = subprocess.run(command + list(arguments), capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("RELEASE_GROUP_REPORTING_PRODUCTION_ENABLED=YES", env.read_text())
            self.assertIs(plistlib.loads(options.read_bytes())["testFlightInternalTestingOnly"], True)
            options.write_bytes(plistlib.dumps({"method": "app-store-connect", "testFlightInternalTestingOnly": False}))
            rejected = subprocess.run(command + ["--ipa", str(ipa), "--verify-export-options-plist", str(options)],
                                      capture_output=True, text=True)
            self.assertNotEqual(rejected.returncode, 0)

    def test_workflow_keeps_default_off_and_checks_trial_before_upload(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github/workflows/testflight.yml").read_text(encoding="utf-8")
        input_block = workflow.split("      group_reporting_trial:", 1)[1].split("      upload_to_testflight:", 1)[0]
        self.assertIn("default: false", input_block)
        self.assertIn("type: boolean", input_block)
        self.assertIn("Real group report trial (YES = 試験専用・自分用のみ)", workflow)
        self.assertIn('GROUP_REPORTING_PRODUCTION_ENABLED="$RELEASE_GROUP_REPORTING_PRODUCTION_ENABLED"', workflow)
        # Check each real invocation, including post-export; omitting the flag
        # from any one stage would either ship NO or leave the IPA unchecked.
        calls = workflow.split('python3 "$PROJECT_DIRECTORY/ci/group-window-release.py"')[1:]
        self.assertEqual(len(calls), 3)
        for call in calls:
            invocation = call.split("\n\n", 1)[0]
            for argument in ("--report-trial-requested", "--internal-reports-requested",
                             "--internal-reports-approval", "--internal-reports-scope"):
                self.assertIn(argument, invocation)
        self.assertLess(workflow.index('--ipa "$ipa_path"'), workflow.index("- name: Validate and upload IPA to TestFlight"))
        project = (root / "NekoWidget/NekoWidget.xcodeproj/project.pbxproj").read_text()
        self.assertEqual(project.count("GROUP_REPORTING_PRODUCTION_ENABLED = NO;"), 2)
        self.assertNotIn("GROUP_REPORTING_PRODUCTION_ENABLED = YES;", project)


if __name__ == "__main__":
    unittest.main()
