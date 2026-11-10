"""Private media must never use the ordinary public screenshot uploads."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PrivateCaptureTests(unittest.TestCase):
    def test_authenticated_transport_rejects_tampering_before_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plain = root / 'input'
            encrypted = root / 'encrypted'
            output = root / 'output'
            plain.write_bytes(b'\x00synthetic media\xff' * 100)
            env = dict(os.environ, NEKO_CAPTURE_KEY=os.urandom(32).hex())
            def run(mode, source, destination):
                return subprocess.run(['node', str(ROOT / 'NekoWidget/ci/private-capture-crypto.mjs'),
                    mode, str(source), str(destination)], env=env, capture_output=True)
            self.assertEqual(run('seal', plain, encrypted).returncode, 0)
            self.assertEqual(run('open', encrypted, output).returncode, 0)
            self.assertEqual(output.read_bytes(), plain.read_bytes())
            data = bytearray(encrypted.read_bytes()); data[-1] ^= 1
            encrypted.write_bytes(data)
            refused = root / 'must-not-exist'
            self.assertNotEqual(run('open', encrypted, refused).returncode, 0)
            self.assertFalse(refused.exists())

    def test_private_capture_has_no_plaintext_artifact_path(self):
        workflow = (ROOT / '.github/workflows/owner-store-capture.yml').read_text(encoding='utf-8')
        self.assertEqual(workflow.count('actions/upload-artifact@'), 1)
        upload = workflow.split('uses: actions/upload-artifact@', 1)[1].split('- name:', 1)[0]
        self.assertIn('path: ${{ runner.temp }}/private-capture-output.nekoenc', upload)
        self.assertNotIn('xcresult', upload)
        self.assertIn("if: github.ref == 'refs/heads/main'", workflow)
        self.assertIn('environment: testflight', workflow)
        synthetic = workflow.split('  synthetic:', 1)[1].split('\n  capture:', 1)[0]
        self.assertNotIn('secrets.', synthetic)
        self.assertIn("if: github.ref == 'refs/heads/main' && !inputs.synthetic", workflow)
        self.assertIn('git diff --quiet "$build_sha" "$GITHUB_SHA"', workflow)
        self.assertIn('.conclusion == "success"', workflow)

        self.assertIn('contents: read', workflow)
        self.assertIn('retention-days: 1', workflow)
        self.assertLess(workflow.index('Build before decrypting'), workflow.index('Authenticate and unpack'))
        self.assertIn('xcrun simctl delete', workflow)
        self.assertIn('rm -rf "$PRIVATE_ROOT"', workflow)
        helper = (ROOT / 'NekoWidget/NekoWidget/App/OwnerStoreCaptureFixture.swift').read_text(encoding='utf-8')
        self.assertTrue(helper.startswith('#if DEBUG\n'))
        self.assertTrue(helper.rstrip().endswith('#endif'))
        self.assertNotIn('URLSession', helper)
        fixture = (ROOT / 'NekoWidget/NekoWidget/App/AppStoreScreenshotFixture.swift').read_text(encoding='utf-8')
        self.assertIn('guard let supplied = OwnerStoreCaptureFixture.image', fixture)


if __name__ == '__main__':
    unittest.main()
