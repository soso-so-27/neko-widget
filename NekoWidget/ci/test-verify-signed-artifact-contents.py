#!/usr/bin/env python3
"""Tests for authenticated signed-artifact content binding."""

from __future__ import annotations

import hashlib
import io
import json
import subprocess
import struct
import sys
import tarfile
import tempfile
import unittest
import plistlib
import zipfile
import internal_report_release as reports
from pathlib import Path


SCRIPT = Path(__file__).with_name("verify-signed-artifact-contents.py")
ARCHIVE_BYTES = b"plist"


def archive_digest() -> str:
    digest = hashlib.sha256(b"jp.nekowidget.xcarchive-content.v2\0")
    relative = b"Info.plist"
    digest.update(struct.pack(">Q", len(relative)))
    digest.update(relative)
    digest.update(struct.pack(">I", 0o600))
    digest.update(b"F")
    digest.update(struct.pack(">Q", len(ARCHIVE_BYTES)))
    digest.update(ARCHIVE_BYTES)
    return digest.hexdigest()


def metadata_bytes() -> bytes:
    return (
        json.dumps(
            {
                "archiveDigestAlgorithm": "sha256-tree-v2",
                "archiveSha256": archive_digest(),
            },
            sort_keys=True,
        )
        + "\n"
    ).encode("ascii")


def add_bytes(archive: tarfile.TarFile, name: str, value: bytes) -> None:
    member = tarfile.TarInfo(name)
    member.size = len(value)
    member.mode = 0o600
    archive.addfile(member, io.BytesIO(value))


class SignedArtifactContentTests(unittest.TestCase):
    def test_v3_checks_report_boundary_in_archive_and_ipa(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); metadata = root / "moderation-release-metadata.json"
            ipa = root / "NekoWidget.ipa"; trust = root / "moderation-key-trust-manifest.json"
            trust.write_bytes(b'{"environment":"testflight","keys":{"moderation-v2":"a"},"revision":2,"schema":"jp.nekowidget.moderation-key-trust.v1"}\n')
            info = {reports.ENABLED: True, reports.SCOPE_KEY: reports.SCOPE, "SharingReleaseMode": "media-staging",
                "SharingAPIBaseURL": reports.ORIGIN, "SharingModerationKeyID": "moderation-v2", "SharingModerationPublicKey": reports.PUBLIC_KEY,
                "SharingFeatureEnabled": True, "SharingMediaEnabled": True,
                "SharingReviewPreviewEnabled": False, "SharingShareExtensionSendEnabled": False}
            entries = {"Info.plist": plistlib.dumps(info),
                "PlugIns/NekoWidgetShareExtension.appex/Info.plist": plistlib.dumps({reports.ENABLED: False, reports.SCOPE_KEY: ""}),
                "PlugIns/NekoWidgetWidgetExtension.appex/Info.plist": plistlib.dumps({reports.ENABLED: False, reports.SCOPE_KEY: ""})}
            with zipfile.ZipFile(ipa, "w") as archive:
                for name, data in entries.items(): archive.writestr("Payload/NekoWidget.app/"+name, data)
            def bundle(tamper):
                actual = dict(entries)
                if tamper: actual["PlugIns/NekoWidgetShareExtension.appex/Info.plist"] = plistlib.dumps(info)
                digest = hashlib.sha256(b"jp.nekowidget.xcarchive-content.v2\0")
                for name, data in sorted(actual.items()):
                    relative = ("Products/Applications/NekoWidget.app/"+name).encode()
                    digest.update(struct.pack(">Q", len(relative)));digest.update(relative);digest.update(struct.pack(">I",0o600))
                    digest.update(b"F");digest.update(struct.pack(">Q",len(data)));digest.update(data)
                metadata.write_text(json.dumps({"schema":"jp.nekowidget.moderation-release-metadata.v3", "releaseMode":"media-staging",
                    "moderationKeyId":"moderation-v2", "moderationPublicKey":reports.PUBLIC_KEY, "internalEncryptedReportEnabled":True,
                    "internalEncryptedReportScope":reports.SCOPE, "testFlightInternalTestingOnly":True,
                    "archiveDigestAlgorithm":"sha256-tree-v2", "archiveSha256":digest.hexdigest()}))
                path = root / "bundle.tar.gz"
                with tarfile.open(path,"w:gz") as archive:
                    for name, data in actual.items(): add_bytes(archive,"NekoWidget.xcarchive/Products/Applications/NekoWidget.app/"+name,data)
                    for item in (metadata,ipa,trust): add_bytes(archive,item.name,item.read_bytes())
                return path
            accepted = self.run_verifier(bundle(False),metadata,ipa,trust)
            self.assertEqual(accepted.returncode,0,accepted.stderr)
            rejected = self.run_verifier(bundle(True),metadata,ipa,trust)
            self.assertNotEqual(rejected.returncode,0)
            self.assertIn("Compiled internal report",rejected.stderr)

    def run_verifier(
        self,
        bundle: Path,
        metadata: Path,
        ipa: Path,
        trust: Path | None,
    ) -> subprocess.CompletedProcess[str]:
        command = [
            sys.executable,
            str(SCRIPT),
            "--bundle",
            str(bundle),
            "--external-metadata",
            str(metadata),
            "--external-ipa",
            str(ipa),
            "--release-mode",
            "media-staging" if trust else "disabled",
        ]
        if trust:
            canonical = trust.read_bytes().removesuffix(b"\n")
            command.extend(
                [
                    "--external-trust-manifest",
                    str(trust),
                    "--expected-trust-manifest-sha256",
                    hashlib.sha256(canonical).hexdigest(),
                ]
            )
        return subprocess.run(command, capture_output=True, text=True)

    def test_media_bundle_binds_metadata_ipa_and_trust_preimage(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            metadata = root / "moderation-release-metadata.json"
            metadata.write_bytes(metadata_bytes())
            ipa = root / "NekoWidget.ipa"
            ipa.write_bytes(b"signed ipa")
            trust = root / "moderation-key-trust-manifest.json"
            trust_value = {
                "environment": "testflight",
                "keys": {"moderation-v1": "a" * 64},
                "revision": 1,
                "schema": "jp.nekowidget.moderation-key-trust.v1",
            }
            trust.write_bytes(
                json.dumps(
                    trust_value,
                    separators=(",", ":"),
                    sort_keys=True,
                ).encode("ascii")
                + b"\n"
            )
            bundle = root / "bundle.tar.gz"
            with tarfile.open(bundle, "w:gz") as archive:
                add_bytes(archive, "NekoWidget.xcarchive/Info.plist", ARCHIVE_BYTES)
                add_bytes(archive, metadata.name, metadata.read_bytes())
                add_bytes(archive, ipa.name, ipa.read_bytes())
                add_bytes(archive, trust.name, trust.read_bytes())
            accepted = self.run_verifier(bundle, metadata, ipa, trust)
            self.assertEqual(0, accepted.returncode, accepted.stderr)

            ipa.write_bytes(b"different upload ipa")
            rejected = self.run_verifier(bundle, metadata, ipa, trust)
            self.assertNotEqual(0, rejected.returncode)
            self.assertIn("IPA", rejected.stderr)

    def test_non_media_bundle_rejects_trust_manifest_residue(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            metadata = root / "moderation-release-metadata.json"
            metadata.write_bytes(metadata_bytes())
            ipa = root / "NekoWidget.ipa"
            ipa.write_bytes(b"ipa")
            bundle = root / "bundle.tar.gz"
            with tarfile.open(bundle, "w:gz") as archive:
                add_bytes(archive, "NekoWidget.xcarchive/Info.plist", ARCHIVE_BYTES)
                add_bytes(archive, metadata.name, metadata.read_bytes())
                add_bytes(archive, ipa.name, ipa.read_bytes())
                add_bytes(archive, "moderation-key-trust-manifest.json", b"{}\n")
            rejected = self.run_verifier(bundle, metadata, ipa, None)
            self.assertNotEqual(0, rejected.returncode)
            self.assertIn("unexpectedly contains", rejected.stderr)


if __name__ == "__main__":
    unittest.main()
