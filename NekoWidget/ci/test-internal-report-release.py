#!/usr/bin/env python3
import copy
import plistlib
from pathlib import Path
import tempfile
import unittest
import zipfile
import subprocess
import sys
import internal_report_release as release


class InternalReportReleaseTests(unittest.TestCase):
    def test_preparation_archive_and_internal_export_use_same_reviewed_settings(self):
        for billing in ("false", "true"):
            with self.subTest(billing=billing):
                self.check_preparation_archive_and_export(billing)

    def check_preparation_archive_and_export(self, billing):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); app = root/"app.plist"; share = root/"share.plist"; widget = root/"widget.plist"
            app.write_bytes(plistlib.dumps({**self.info(), release.ENABLED: False, release.SCOPE_KEY: ""}))
            for path in (share, widget): path.write_bytes(plistlib.dumps({release.ENABLED: False, release.SCOPE_KEY: ""}))
            options = root/"export.plist"; options.write_bytes(plistlib.dumps({"method":"app-store-connect", "testFlightInternalTestingOnly":False}))
            command = [sys.executable, str(Path(release.__file__)), "--requested", "true", "--mode", "media-staging",
                "--approval", "YES", "--scope", release.SCOPE, "--billing-requested", billing,
                "--settings-file", str(root/"settings.json")]
            def run(extra): return subprocess.run(command+extra, capture_output=True, text=True)
            prepared = run(["--app-source-info-plist",str(app),"--env-file",str(root/"env")])
            self.assertEqual(prepared.returncode,0,prepared.stderr)
            archived = run(["--app-info-plist",str(app),"--share-info-plist",str(share),"--widget-info-plist",str(widget)])
            self.assertEqual(archived.returncode,0,archived.stderr)
            exported = run(["--export-options-plist",str(options)])
            self.assertEqual(exported.returncode,0,exported.stderr)
            self.assertIs(plistlib.loads(options.read_bytes())["testFlightInternalTestingOnly"],True)
            self.assertIn("RELEASE_INTERNAL_REPORTS_ENABLED=true",(root/"env").read_text())
            (root/"settings.json").write_text('{}')
            self.assertNotEqual(run(["--export-options-plist",str(options)]).returncode,0)

    def info(self):
        return {release.ENABLED: True, release.SCOPE_KEY: release.SCOPE,
                "SharingReleaseMode": "media-staging", "SharingAPIBaseURL": release.ORIGIN,
                "SharingModerationKeyID": "moderation-v2", "SharingModerationPublicKey": release.PUBLIC_KEY,
                "SharingFeatureEnabled": True, "SharingMediaEnabled": True,
                "SharingReviewPreviewEnabled": False, "SharingShareExtensionSendEnabled": False}

    def test_explicit_approval_and_billing_boundary(self):
        self.assertEqual(release.settings(False, "disabled", "", ""), {release.ENABLED: False, release.SCOPE_KEY: ""})
        self.assertEqual(release.settings(True, "media-staging", "YES", release.SCOPE), {release.ENABLED: True, release.SCOPE_KEY: release.SCOPE})
        for billing in (False, True):
            self.assertEqual(release.settings(True, "media-staging", "YES", release.SCOPE, billing),
                             {release.ENABLED: True, release.SCOPE_KEY: release.SCOPE})
            self.assertEqual(release.settings(False, "media-staging", "YES", release.SCOPE, billing),
                             {release.ENABLED: False, release.SCOPE_KEY: ""})
            for mode, approval, scope in [("disabled", "YES", release.SCOPE), ("media-staging", "", release.SCOPE),
                                           ("media-staging", "YES", "external")]:
                with self.subTest(mode=mode, approval=approval, scope=scope, billing=billing), self.assertRaises(ValueError):
                    release.settings(True, mode, approval, scope, billing)
        for requested, billing in [(1, True), (True, 1), ("true", False), (True, "true")]:
            with self.subTest(requested=requested, billing=billing), self.assertRaises(ValueError):
                release.settings(requested, "media-staging", "YES", release.SCOPE, billing)

    def test_compiled_flags_scope_target_and_extensions_fail_closed(self):
        expected = {release.ENABLED: True, release.SCOPE_KEY: release.SCOPE}
        release.verify_info(self.info(), expected)
        for key, value in [(release.ENABLED, "YES"), (release.ENABLED, 1), (release.SCOPE_KEY, "internal"),
                           ("SharingReleaseMode", "disabled"), ("SharingAPIBaseURL", "https://other.invalid"),
                           ("SharingModerationKeyID", "moderation-v1"), ("SharingModerationPublicKey", "other"),
                           ("SharingFeatureEnabled", 1), ("SharingMediaEnabled", "true"),
                           ("SharingReviewPreviewEnabled", True), ("SharingShareExtensionSendEnabled", True),
                           ("SharingReviewPreviewEnabled", 0), ("SharingShareExtensionSendEnabled", "false")]:
            changed = self.info(); changed[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): release.verify_info(changed, expected)
        with self.assertRaises(ValueError): release.verify_info(self.info(), expected, extension=True)
        release.verify_info({release.ENABLED: False, release.SCOPE_KEY: ""}, expected, extension=True)

    def test_exact_ipa_plists_reject_tampered_extension_and_duplicate(self):
        expected = {release.ENABLED: True, release.SCOPE_KEY: release.SCOPE}
        names = ["Payload/NekoWidget.app/Info.plist", "Payload/NekoWidget.app/PlugIns/NekoWidgetShareExtension.appex/Info.plist",
                 "Payload/NekoWidget.app/PlugIns/NekoWidgetWidgetExtension.appex/Info.plist"]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/"test.ipa"
            for tamper in (None, "extension", "duplicate", "missing"):
                with zipfile.ZipFile(path, "w") as archive:
                    for index, name in enumerate(names):
                        if tamper == "missing" and index == 2: continue
                        info = self.info() if index == 0 or (tamper == "extension" and index == 1) else {release.ENABLED: False, release.SCOPE_KEY: ""}
                        archive.writestr(name, plistlib.dumps(info))
                    if tamper == "duplicate": archive.writestr(names[0], plistlib.dumps(self.info()))
                if tamper is None: release.verify_ipa(path, expected)
                else:
                    with self.subTest(tamper=tamper), self.assertRaises(ValueError): release.verify_ipa(path, expected)

    def test_metadata_cannot_infer_reports_or_rebind_scope(self):
        value = {"schema": "jp.nekowidget.moderation-release-metadata.v3", "releaseMode": "media-staging",
                 "moderationKeyId": "moderation-v2", "moderationPublicKey": release.PUBLIC_KEY,
                 "internalEncryptedReportEnabled": True, "internalEncryptedReportScope": release.SCOPE, "testFlightInternalTestingOnly": True}
        self.assertTrue(release.metadata_settings(value)[release.ENABLED])
        for key, replacement in [("internalEncryptedReportEnabled", 1), ("internalEncryptedReportScope", "external"),
                                 ("releaseMode", "disabled"), ("moderationKeyId", "moderation-v1"), ("testFlightInternalTestingOnly", False)]:
            changed = copy.deepcopy(value); changed[key] = replacement
            with self.subTest(key=key), self.assertRaises(ValueError): release.metadata_settings(changed)
        with self.assertRaises(ValueError): release.metadata_settings({**value, "schema": "jp.nekowidget.moderation-release-metadata.v2"})


if __name__ == "__main__": unittest.main()
