#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("signed-artifact-authentication.py")
PASSWORD_ENVIRONMENT = "SIGNED_ARTIFACT_ENCRYPTION_PASSWORD"


class SignedArtifactAuthenticationTests(unittest.TestCase):
    def run_tool(self, *arguments: str, password: str = "correct horse battery staple") -> subprocess.CompletedProcess[str]:
        environment = dict(os.environ)
        environment[PASSWORD_ENVIRONMENT] = password
        return subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            text=True,
            capture_output=True,
            check=False,
            env=environment,
        )

    def fixture(self, root: Path) -> tuple[Path, Path, Path]:
        ciphertext = root / "NekoWidget-signed-artifacts.tar.gz.enc"
        metadata = root / "moderation-release-metadata.json"
        authentication = root / "signed-artifact-authentication.json"
        ciphertext.write_bytes(bytes(range(256)) * 3)
        metadata.write_text('{"buildNumber":"99"}\n', encoding="utf-8")
        created = self.run_tool(
            "create",
            "--ciphertext", str(ciphertext),
            "--metadata", str(metadata),
            "--output", str(authentication),
        )
        self.assertEqual(created.returncode, 0, created.stderr)
        return ciphertext, metadata, authentication

    def verify(self, ciphertext: Path, metadata: Path, authentication: Path, **kwargs: str) -> subprocess.CompletedProcess[str]:
        return self.run_tool(
            "verify",
            "--ciphertext", str(ciphertext),
            "--metadata", str(metadata),
            "--authentication", str(authentication),
            **kwargs,
        )

    def test_create_and_verify_bind_ciphertext_and_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = self.fixture(Path(directory))
            result = self.verify(*paths)
            self.assertEqual(result.returncode, 0, result.stderr)
            value = json.loads(paths[2].read_text(encoding="utf-8"))
            self.assertEqual(
                set(value),
                {
                    "schema", "algorithm", "kdfSalt", "ciphertextFileName", "ciphertextSize",
                    "ciphertextSha256", "releaseMetadataFileName",
                    "releaseMetadataSize", "releaseMetadataSha256", "authenticationTag",
                },
            )

    def test_each_manifest_uses_a_distinct_kdf_salt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            salts: list[str] = []
            for index in range(2):
                fixture_root = root / str(index)
                fixture_root.mkdir()
                _, _, authentication = self.fixture(fixture_root)
                value = json.loads(authentication.read_text(encoding="utf-8"))
                salts.append(value["kdfSalt"])
            self.assertEqual(2, len(set(salts)))

    def test_tamper_or_wrong_password_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            ciphertext, metadata, authentication = self.fixture(Path(directory))
            ciphertext.write_bytes(ciphertext.read_bytes() + b"tamper")
            result = self.verify(ciphertext, metadata, authentication)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("mismatch", result.stderr)

        with tempfile.TemporaryDirectory() as directory:
            ciphertext, metadata, authentication = self.fixture(Path(directory))
            metadata.write_text('{"buildNumber":"100"}\n', encoding="utf-8")
            result = self.verify(ciphertext, metadata, authentication)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("mismatch", result.stderr)

        with tempfile.TemporaryDirectory() as directory:
            paths = self.fixture(Path(directory))
            result = self.verify(*paths, password="this is a different password")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("authentication tag mismatch", result.stderr)

    def test_manifest_shape_and_password_are_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            ciphertext, metadata, authentication = self.fixture(Path(directory))
            authentication.write_text('{"schema":"a","schema":"b"}\n', encoding="utf-8")
            result = self.verify(ciphertext, metadata, authentication)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("duplicate JSON key", result.stderr)

        with tempfile.TemporaryDirectory() as directory:
            ciphertext, metadata, authentication = self.fixture(Path(directory))
            result = self.run_tool(
                "verify",
                "--ciphertext", str(ciphertext),
                "--metadata", str(metadata),
                "--authentication", str(authentication),
                password="short",
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("at least 20 characters", result.stderr)


if __name__ == "__main__":
    unittest.main()
