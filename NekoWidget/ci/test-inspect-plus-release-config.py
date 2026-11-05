"""Synthetic encrypted fixture only; never opens a real signed release locally."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

CI = Path(__file__).resolve().parent


def module(name):
    spec = importlib.util.spec_from_file_location(name, CI / (name + ".py"))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class InspectionTests(unittest.TestCase):
    def test_workflow_head_and_selected_release_are_independently_pinned(self):
        inspect = module("inspect-plus-release-config")
        for build, (run_id, artifact_id, source) in inspect.RELEASES.items():
            head = inspect.WORKFLOW_HEADS[build]
            run = {"id": run_id, "run_attempt": 1, "head_sha": head, "head_branch": "main",
                "event": "workflow_dispatch", "status": "completed", "conclusion": "success",
                "path": ".github/workflows/testflight.yml", "repository": {"full_name": "soso-so-27/neko-widget"}}
            prefix = "production-candidate" if build == "328" else "nekowidget-signed-artifacts"
            artifact = {"id": artifact_id, "expired": False, "name": f"{prefix}-{run_id}-1",
                "workflow_run": {"id": run_id, "head_sha": head}}
            inspect.validate_provenance(build, run, artifact)
            with self.assertRaises(inspect.d.DiagnosticError):
                inspect.validate_provenance(build, {**run, "head_sha": "0" * 40}, artifact)
            with self.assertRaises(inspect.d.DiagnosticError):
                inspect.validate_provenance(build, run, {**artifact, "workflow_run": {"id": run_id, "head_sha": "0" * 40}})
            if build == "325":
                self.assertNotEqual(head, source)
                with self.assertRaises(inspect.d.DiagnosticError):
                    inspect.validate_provenance(build, {**run, "head_sha": source}, artifact)

    def test_authenticated_ipa_allowlist_tamper_rejection_and_cleanup(self):
        inspect = module("inspect-plus-release-config")
        auth = module("signed-artifact-authentication")
        openssl = shutil.which("openssl") or "C:/Program Files/Git/usr/bin/openssl.exe"
        self.assertTrue(Path(openssl).is_file(), "OpenSSL required for the encryption boundary test")
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {
            "SIGNED_ARTIFACT_ENCRYPTION_PASSWORD": "synthetic test only password 1102zw",
            "PATH": str(Path(openssl).parent) + os.pathsep + os.environ.get("PATH", ""),
        }):
            root = Path(temporary)
            run_id, artifact_id, source = inspect.RELEASES["328"]
            (root / "run.json").write_text(json.dumps({"id": run_id, "run_attempt": 1,
                "head_sha": source, "head_branch": "main", "event": "workflow_dispatch",
                "status": "completed", "conclusion": "success", "path": ".github/workflows/testflight.yml",
                "repository": {"full_name": "soso-so-27/neko-widget"}}))
            (root / "artifact.json").write_text(json.dumps({"id": artifact_id, "expired": False,
                "name": f"production-candidate-{run_id}-1", "workflow_run": {"id": run_id, "head_sha": source}}))
            info = plistlib.dumps({"CFBundleIdentifier": "jp.nekowidget.app", "CFBundleVersion": "328",
                "PlusMonthlyProductID": "jp.nekowidget.plus.monthly", "NeverPrintThis": "private sentinel"})
            ipa = io.BytesIO()
            with zipfile.ZipFile(ipa, "w") as archive:
                archive.writestr("Payload/NekoWidget.app/Info.plist", info)
            bundle = root / "synthetic.tar.gz"
            with tarfile.open(bundle, "w:gz") as archive:
                for name, content in {"NekoWidget.xcarchive/Products/Applications/NekoWidget.app/Info.plist": info,
                                      "Export/NekoWidget.ipa": ipa.getvalue()}.items():
                    entry = tarfile.TarInfo(name); entry.size = len(content)
                    archive.addfile(entry, io.BytesIO(content))
            cipher = root / "production-candidate.tar.gz.enc"
            subprocess.run([openssl, "enc", "-aes-256-cbc", "-pbkdf2", "-iter", "200000",
                "-pass", "env:SIGNED_ARTIFACT_ENCRYPTION_PASSWORD", "-in", str(bundle), "-out", str(cipher)], check=True, capture_output=True)
            metadata = root / "production-owner-metadata.json"
            metadata.write_text(json.dumps({"schema": "jp.nekowidget.production-owner-artifact.v1",
                "source": source, "build": "328", "run": str(run_id), "attempt": "1",
                "internalOnly": True, "profile": "app-store-candidate", "ipaSHA256": hashlib.sha256(ipa.getvalue()).hexdigest()}))
            signature = root / "production-owner-authentication.json"
            auth.create_manifest(cipher, metadata, signature)

            def pack():
                with zipfile.ZipFile(root / "artifact.zip", "w") as archive:
                    for file in (cipher, metadata, signature): archive.write(file, file.name)

            pack()
            result = inspect.inspect(root, "328")
            self.assertEqual(result["publicConfiguration"]["PlusMonthlyProductID"], "jp.nekowidget.plus.monthly")
            self.assertNotIn("private sentinel", json.dumps(result))
            self.assertEqual(list(root.glob("private-*")), [])
            cipher.write_bytes(cipher.read_bytes() + b"tampered")
            pack()
            with self.assertRaises(inspect.d.DiagnosticError): inspect.inspect(root, "328")
            self.assertEqual(list(root.glob("private-*")), [])


if __name__ == "__main__":
    unittest.main()
