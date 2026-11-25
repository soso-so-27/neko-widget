import importlib.util
from io import BytesIO
from pathlib import Path
import plistlib
import tarfile
import tempfile
import unittest
import zipfile


spec = importlib.util.spec_from_file_location("restore_candidate", Path(__file__).with_name("restore-app-store-candidate.py"))
restore = importlib.util.module_from_spec(spec)
spec.loader.exec_module(restore)


class RestoreCandidateTest(unittest.TestCase):
    def archive(self, target, *, info=None, export=None):
        identity = {"CFBundleIdentifier": "jp.nekowidget.app", "CFBundleShortVersionString": "1.0",
                    "CFBundleVersion": "412", "AppStorePagePublished": "YES", "ITSAppUsesNonExemptEncryption": False}
        options = {"method": "app-store-connect", "destination": "export", "signingStyle": "manual",
                   "manageAppVersionAndBuildNumber": False}
        ipa = BytesIO()
        with zipfile.ZipFile(ipa, "w") as file:
            file.writestr("Payload/NekoWidget.app/Info.plist", plistlib.dumps(identity | (info or {})))
        with tarfile.open(target, "w:gz") as bundle:
            for name, value in (("Export/app.ipa", ipa.getvalue()), ("production-candidate.json", b"{}"),
                                ("ExportOptions.plist", plistlib.dumps(options | (export or {}))),
                                ("../../outside", b"not required by the release")):
                member = tarfile.TarInfo(name)
                member.size = len(value)
                bundle.addfile(member, BytesIO(value))

    def test_extracts_only_expected_files_for_exact_candidate(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / "bundle.tar.gz"
            self.archive(bundle)
            output = root / "release"
            restore.extract_candidate(bundle, output, "412")
            self.assertEqual({"NekoWidget.ipa", "production-candidate.json", "ExportOptions.plist"},
                             {file.name for file in output.iterdir()})

    def test_refuses_other_build_internal_only_or_different_encryption(self):
        for build, info, export in [
            ("413", {}, {}),
            ("412", {}, {"testFlightInternalTestingOnly": True}),
            ("412", {"AppStorePagePublished": "NO"}, {}),
            ("412", {"ITSAppUsesNonExemptEncryption": True}, {}),
        ]:
            with self.subTest(build=build, info=info, export=export), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                bundle = root / "bundle.tar.gz"
                self.archive(bundle, info=info, export=export)
                with self.assertRaises(ValueError):
                    restore.extract_candidate(bundle, root / "release", build)


if __name__ == "__main__":
    unittest.main()
