"""Offline adversarial contract tests; macOS CI checks the actual generated products."""
import copy
import json
from pathlib import Path
import plistlib
import re
import tempfile
import unittest
from unittest.mock import patch

import production_candidate as candidate
import distribution_profile


class ProductionCandidateTests(unittest.TestCase):
    def setUp(self):
        self.contract = candidate.fixture()
        self.settings = candidate.settings(self.contract, synthetic=True)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / "NekoWidget.app"
        for target, (relative, source, privacy) in candidate.TARGETS.items():
            directory = self.app / relative
            directory.mkdir(parents=True, exist_ok=True)
            info = plistlib.loads((candidate.ROOT / source / "Info.plist").read_bytes())
            for key, value in info.items():
                if isinstance(value, str) and re.fullmatch(r"\$\([A-Z_0-9]+\)", value) and value[2:-1] in self.settings:
                    info[key] = self.settings[value[2:-1]]
            info.update(CFBundleVersion="1", CFBundleShortVersionString="1.0", AppGroupIdentifier="group.synthetic")
            setting = {"NekoWidget": "APP_BUNDLE_IDENTIFIER", "NekoWidgetShareExtension": "SHARE_EXTENSION_BUNDLE_IDENTIFIER", "NekoWidgetWidgetExtension": "WIDGET_BUNDLE_IDENTIFIER"}[target]
            info["CFBundleIdentifier"] = re.search(r"(?m)^" + setting + r"\s*=\s*(\S+)", (candidate.ROOT / "Config.xcconfig").read_text(encoding="utf-8"))[1]
            if "GroupShareKeychainGroup" in info:
                info["GroupShareKeychainGroup"] = "SYNTHETIC1.jp.synthetic.group-share"
            (directory / "Info.plist").write_bytes(plistlib.dumps(info))
            (directory / "PrivacyInfo.xcprivacy").write_bytes((candidate.ROOT / privacy).read_bytes())

    def verify(self):
        return candidate.verify_products(self.app, self.contract, synthetic=True)

    def test_complete_three_product_contract(self):
        self.verify()

    def test_synthetic_never_a_signed_candidate(self):
        with self.assertRaises(ValueError):
            candidate.settings(self.contract)
        contract = copy.deepcopy(self.contract)
        contract["synthetic"] = False
        with self.assertRaises(ValueError):
            candidate.settings(contract)
        with self.assertRaises(ValueError):
            candidate.run_build(self.contract, ["archive", "-sdk", "iphoneos"], synthetic=True)

    def test_settings_probe_cannot_consume_archive_output_paths(self):
        from types import SimpleNamespace
        result = SimpleNamespace(stdout=json.dumps([{"target": "NekoWidget", "buildSettings": {
            **self.settings, "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "NEKO_HOST_APP"}}]))
        with patch.object(candidate.subprocess, "run", return_value=result) as run:
            candidate.run_build(self.contract, ["-sdk", "iphonesimulator", "-archivePath", "candidate.xcarchive",
                                               "-resultBundlePath", "candidate.xcresult", "archive"], synthetic=True)
        probe, archive = [call.args[0] for call in run.call_args_list]
        self.assertNotIn("-archivePath", probe); self.assertNotIn("candidate.xcarchive", probe)
        self.assertNotIn("-resultBundlePath", probe); self.assertNotIn("candidate.xcresult", probe)
        self.assertIn("-archivePath", archive); self.assertIn("-resultBundlePath", archive)
        self.assertFalse(any(item.startswith("SWIFT_ACTIVE_COMPILATION_CONDITIONS=") for item in archive))

    def test_build_for_testing_uses_the_same_settings_boundary(self):
        from types import SimpleNamespace
        result = SimpleNamespace(stdout=json.dumps([{"target": "NekoWidget", "buildSettings": {
            **self.settings, "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "NEKO_HOST_APP"}}]))
        with patch.object(candidate.subprocess, "run", return_value=result) as run:
            candidate.run_build(self.contract, ["-sdk", "iphonesimulator", "build-for-testing"], synthetic=True)
        probe, build = [call.args[0] for call in run.call_args_list]
        self.assertIn("-showBuildSettings", probe)
        self.assertNotIn("build-for-testing", probe)
        self.assertIn("build-for-testing", build)
        result.stdout = result.stdout.replace('NEKO_HOST_APP', 'NEKO_HOST_APP INTERNAL_PRESENTATION')
        with patch.object(candidate.subprocess, "run", return_value=result) as run, self.assertRaises(ValueError):
            candidate.run_build(self.contract, ["-sdk", "iphonesimulator", "build-for-testing"], synthetic=True)
        self.assertEqual(run.call_count, 1)

    def test_testing_coverage_option_is_preserved_only_on_real_build(self):
        from types import SimpleNamespace
        result = SimpleNamespace(stdout=json.dumps([{"target": "NekoWidget", "buildSettings": {
            **self.settings, "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "NEKO_HOST_APP"}}]))
        for value in ("YES", "NO"):
            with self.subTest(coverage=value), patch.object(candidate.subprocess, "run", return_value=result) as run:
                candidate.run_build(self.contract, ["-sdk", "iphonesimulator", "-enableCodeCoverage", value,
                                                   "build-for-testing"], synthetic=True)
            probe, build = [call.args[0] for call in run.call_args_list]
            self.assertNotIn("-enableCodeCoverage", probe)
            self.assertNotIn(value, probe)
            self.assertEqual(build[build.index("-enableCodeCoverage") + 1], value)
            self.assertIn("build-for-testing", build)

    def test_resolved_conditions_reject_debug_and_missing_target_boundary(self):
        from types import SimpleNamespace
        for target, conditions in [("NekoWidget", ""), ("NekoWidget", "DEBUG NEKO_HOST_APP"),
                                   ("NekoWidgetShareExtension", "NEKO_HOST_APP")]:
            rows = [{"target": "NekoWidget", "buildSettings": {**self.settings, "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "NEKO_HOST_APP"}},
                    {"target": target, "buildSettings": {**self.settings, "SWIFT_ACTIVE_COMPILATION_CONDITIONS": conditions}}]
            result = SimpleNamespace(stdout=json.dumps(rows))
            with patch.object(candidate.subprocess, "run", return_value=result) as run, self.assertRaises(ValueError):
                candidate.run_build(self.contract, ["-sdk", "iphonesimulator", "build"], synthetic=True)
            self.assertEqual(run.call_count, 1, "Must fail before compilation")

    def test_internal_defines_rejected_before_build_for_every_product(self):
        from types import SimpleNamespace
        for target in candidate.TARGETS:
            for key, value in [
                ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "INTERNAL_PRESENTATION NEKO_HOST_APP NEKO_SHARE_EXTENSION"),
                ("INTERNAL_PRESENTATION_CONDITION", "INTERNAL_PRESENTATION"),
                ("OTHER_SWIFT_FLAGS", "-DINTERNAL_PRESENTATION"),
                ("OTHER_SWIFT_FLAGS", "-D INTERNAL_PRESENTATION"),
                ("OTHER_SWIFT_FLAGS", '-D "INTERNAL_PRESENTATION"'),
                ("OTHER_SWIFT_FLAGS", "-Xfrontend -D -Xfrontend INTERNAL_PRESENTATION"),
                ("OTHER_SWIFT_FLAGS", "-DDEBUG"),
                ("OTHER_SWIFT_FLAGS", "-DWIDGET_SCREENSHOT_FIXTURE"),
            ]:
                rows = [{"target": name, "buildSettings": {
                    **self.settings,
                    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": {
                        "NekoWidget": "NEKO_HOST_APP", "NekoWidgetShareExtension": "NEKO_SHARE_EXTENSION",
                        "NekoWidgetWidgetExtension": ""}[name]}} for name in candidate.TARGETS]
                next(row for row in rows if row["target"] == target)["buildSettings"][key] = value
                result = SimpleNamespace(stdout=json.dumps(rows))
                with self.subTest(target=target, key=key, value=value):
                    with patch.object(candidate.subprocess, "run", return_value=result) as run, self.assertRaises(ValueError):
                        candidate.run_build(self.contract, ["-sdk", "iphonesimulator", "build"], synthetic=True)
                    self.assertEqual(run.call_count, 1, "Internal code must be rejected before compilation")

    def test_reject_recipient_origin_and_incomplete_inputs(self):
        for key, value in [("SHARING_MODERATION_PUBLIC_KEY", "T5C7__1xlc4XmIDr6zTJqMtdhBjPnMD10O3vFK_bYWg"),
                           ("SHARING_MODERATION_PUBLIC_KEY", "A" * 43),
                           ("SHARING_API_BASE_URL", "https://staging.candidate.test"),
                           ("SHARING_API_BASE_URL", "http://api.candidate.test"),
                           ("SHARING_API_BASE_URL", "https://api.candidate.test/private"),
                           ("APP_PRIVACY_URL", "https://user:secret@policy.candidate.test/privacy/"),
                           ("OFFICIAL_WINDOW_FEED_URL", ""),
                           ("MANAGED_PRESERVATION_MEMBERSHIP_AUDIENCE", "neko-staging")]:
            contract = copy.deepcopy(self.contract); contract["values"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                candidate.settings(contract, synthetic=True)
        contract = copy.deepcopy(self.contract); contract["recipientSHA256"] = "0" * 64
        with self.assertRaises(ValueError): candidate.settings(contract, synthetic=True)
        contract = copy.deepcopy(self.contract); contract["values"].pop("APP_SUPPORT_URL")
        with self.assertRaises(ValueError): candidate.settings(contract, synthetic=True)

    def test_every_target_rejects_internal_tools_and_mismatched_mode(self):
        for relative, _, _ in candidate.TARGETS.values():
            path = self.app / relative / "Info.plist"
            original = path.read_bytes()
            for key, value in [("SharingReleaseMode", "media-staging"), ("OwnerInternalReportsDisabled", "YES"),
                               ("SharingInternalEncryptedReportEnabled", True), ("SharingInternalEncryptedReportScope", "internal"),
                               ("CFBundleVersion", "2"), ("AppGroupIdentifier", "other")]:
                info = plistlib.loads(original); info[key] = value; path.write_bytes(plistlib.dumps(info))
                with self.subTest(target=relative, key=key), self.assertRaises(ValueError): self.verify()
                path.write_bytes(original)

    def test_feature_transport_and_recipient_mutations(self):
        mutations = {"": {"FamilyNotebookProductionEnabled": "NO", "SharingModerationPublicKey": "wrong",
                          "ManagedPreservationOrigin": "https://other.candidate.test", "PlusBillingAPIBaseURL": "https://other.candidate.test",
                          "MembershipAccessEnforced": "NO", "PersonalArchiveReadOnly": "NO", "OfficialWindowFeedURL": "",
                          "SharingShareExtensionSendEnabled": "YES", "GroupReportingProductionEnabled": "NO"},
                     "PlugIns/NekoWidgetShareExtension.appex": {"GroupShareAPIBaseURL": "https://other.candidate.test",
                          "SharingModerationPublicKey": "unexpected", "SharingShareExtensionSendEnabled": "YES", "GroupShareKeychainGroup": "wrong"},
                     "PlugIns/NekoWidgetWidgetExtension.appex": {"MembershipAccessEnforced": "NO", "OfficialWindowFeedURL": "", "GroupShareKeychainGroup": "unexpected"}}
        for relative, values in mutations.items():
            path = self.app / relative / "Info.plist"; original = path.read_bytes()
            for key, value in values.items():
                info = plistlib.loads(original); info[key] = value; path.write_bytes(plistlib.dumps(info))
                with self.subTest(target=relative, key=key), self.assertRaises(ValueError): self.verify()
                path.write_bytes(original)

    def test_privacy_manifests_and_extension_activation(self):
        for relative, _, _ in candidate.TARGETS.values():
            path = self.app / relative / "PrivacyInfo.xcprivacy"; original = path.read_bytes()
            value = plistlib.loads(original); value["NSPrivacyTracking"] = True; path.write_bytes(plistlib.dumps(value))
            with self.assertRaises(ValueError): self.verify()
            path.write_bytes(original)
        path = self.app / "PlugIns/NekoWidgetShareExtension.appex/Info.plist"
        value = plistlib.loads(path.read_bytes()); value["NSExtension"]["NSExtensionAttributes"]["NSExtensionActivationRule"] = "TRUEPREDICATE"
        path.write_bytes(plistlib.dumps(value))
        with self.assertRaises(ValueError): self.verify()

    def test_distribution_is_explicit_and_export_is_not_internal_or_upload(self):
        distribution_profile.validate(candidate.PROFILE, "production", False)
        for profile, mode, internal in [(candidate.PROFILE, "media-staging", False), (candidate.PROFILE, "production", True),
                                       ("owner-internal", "production", False), ("existing-reviewed", "production", False)]:
            with self.assertRaises(ValueError): distribution_profile.validate(profile, mode, internal)
        options = plistlib.loads((candidate.ROOT / "ci/ExportOptions.plist.template").read_bytes())
        candidate.verify_export(options)
        for key, value in [("testFlightInternalTestingOnly", True), ("destination", "upload"), ("method", "debugging"),
                           ("signingStyle", "automatic"), ("manageAppVersionAndBuildNumber", True)]:
            with self.assertRaises(ValueError): candidate.verify_export({**options, key: value})


if __name__ == "__main__":
    unittest.main()
