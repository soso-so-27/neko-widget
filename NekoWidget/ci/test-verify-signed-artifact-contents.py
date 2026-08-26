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
