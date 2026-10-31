import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('restore319', Path(__file__).with_name('restore-owner-319.py'))
restore = importlib.util.module_from_spec(spec)
spec.loader.exec_module(restore)


class RestoreTests(unittest.TestCase):
    def test_extracts_only_the_regular_ipa_and_trust_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle = root / 'bundle.tar.gz'
            with tarfile.open(bundle, 'w:gz') as archive:
                for name in ['NekoWidget.ipa', 'moderation-key-trust-manifest.json', 'NekoWidget.xcarchive/ignored']:
                    member = tarfile.TarInfo(name); member.size = 4
                    archive.addfile(member, io.BytesIO(b'test'))
            out = root / 'out'; out.mkdir()
            ipa, trust = restore.extract_payload(bundle, out)
            self.assertEqual(ipa.read_bytes(), b'test')
            self.assertEqual(trust.read_bytes(), b'test')
            self.assertEqual(len(list(out.iterdir())), 2)

    def test_unsafe_duplicate_and_link_payloads_are_rejected(self):
        for problem in ['../escape', 'NekoWidget.ipa', 'symlink']:
            with self.subTest(problem=problem), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); bundle = root / 'bundle.tar.gz'
                with tarfile.open(bundle, 'w:gz') as archive:
                    for name in ['NekoWidget.ipa', 'moderation-key-trust-manifest.json']:
                        member = tarfile.TarInfo(name); member.size = 4
                        if problem == 'symlink' and name.endswith('.ipa'):
                            member.type = tarfile.SYMTYPE; member.linkname = '/private'; member.size = 0
                            archive.addfile(member)
                        else:
                            archive.addfile(member, io.BytesIO(b'test'))
                    if problem != 'symlink':
                        member = tarfile.TarInfo(problem); member.size = 4
                        archive.addfile(member, io.BytesIO(b'test'))
                out = root / 'out'; out.mkdir()
                with self.assertRaises(ValueError): restore.extract_payload(bundle, out)
                self.assertEqual(list(out.iterdir()), [])


if __name__ == '__main__': unittest.main()
