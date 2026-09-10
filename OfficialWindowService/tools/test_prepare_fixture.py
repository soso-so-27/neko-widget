from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image

import prepare_fixture as fixture


NOW = datetime(2026, 9, 10, 12, 0, 0, 900000, tzinfo=timezone.utc)


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="official-fixture-test-")
        self.root = Path(self.temporary.name)
        self.output = self.root / "new-batch"

    def tearDown(self):
        self.temporary.cleanup()

    def test_three_states_reuse_publisher_and_contain_only_public_files(self):
        publisher = fixture.load_publisher()
        with patch.object(fixture, "load_publisher", return_value=publisher), \
             patch.object(publisher, "build_catalog", wraps=publisher.build_catalog) as build:
            result = fixture.prepare_fixture(self.output, now=NOW)
        self.assertEqual(build.call_count, 3)
        self.assertEqual(set(path.name for path in self.output.iterdir()), {"first", "updated", "paused"})
        self.assertEqual([row["id"] for row in result["first"]["photos"]], ["synthetic-test-a"])
        self.assertEqual([row["id"] for row in result["updated"]["photos"]],
                         ["synthetic-test-b", "synthetic-test-a"])
        self.assertIs(result["paused"]["enabled"], False)
        self.assertEqual(result["paused"]["photos"], [])
        self.assertEqual(result["first"]["photos"][0], result["updated"]["photos"][1])
        hashes = set()
        for name, catalog in result.items():
            folder = self.output / name
            raw = (folder / "catalog.json").read_text(encoding="utf-8")
            self.assertEqual(json.loads(raw), catalog)
            for private in ("publicationApproved", "sourceFilename", "internal", "prepare_fixture.py"):
                self.assertNotIn(private, raw)
            expected = {"catalog.json"}
            for row in catalog["photos"]:
                self.assertIn("テスト", row["catName"])
                self.assertIn("実在猫・提供者なし", row["credit"])
                self.assertIn("実際の猫写真ではありません", row["caption"])
                expected.add(row["imageFilename"])
                binary = (folder / row["imageFilename"]).read_bytes()
                self.assertEqual(hashlib.sha256(binary).hexdigest(), row["sha256"])
                hashes.add(row["sha256"])
                with Image.open(folder / row["imageFilename"]) as image:
                    self.assertEqual(image.format, "JPEG")
                    self.assertEqual(image.size, (1024, 1024))
                    self.assertEqual(dict(image.getexif()), {})
            self.assertEqual(set(path.name for path in folder.iterdir()), expected)
        self.assertEqual(len(hashes), 2, "A and B must visibly encode different test images")
        source_dir = build.call_args_list[0].kwargs["images_dir"]
        self.assertFalse(source_dir.exists(), "temporary originals were retained")

    def test_versions_are_seconds_monotonic_and_within_future_allowance(self):
        result = fixture.prepare_fixture(self.output, now=NOW)
        publisher = fixture.load_publisher()
        clocks = [publisher.parse_utc(result[name]["generatedAt"], "generatedAt")
                  for name in ("first", "updated", "paused")]
        base = NOW.replace(microsecond=0)
        self.assertEqual(clocks, [base, base + timedelta(seconds=1), base + timedelta(seconds=2)])
        self.assertLessEqual(clocks[-1] - NOW, timedelta(seconds=300))
        self.assertEqual(result["updated"]["photos"][0]["publishedAt"], result["updated"]["generatedAt"])
        for name in result:
            catalog = result[name]
            generated = publisher.parse_utc(catalog["generatedAt"], "generatedAt")
            self.assertEqual(publisher.parse_utc(catalog["validUntil"], "validUntil") - generated,
                             timedelta(hours=48))
            for photo in catalog["photos"]:
                self.assertLessEqual(publisher.parse_utc(photo["publishedAt"], "publishedAt"), generated)

    def test_existing_directory_or_file_is_not_changed(self):
        self.output.mkdir()
        sentinel = self.output / "existing.txt"
        sentinel.write_text("unchanged", encoding="utf-8")
        with self.assertRaises(ValueError):
            fixture.prepare_fixture(self.output, now=NOW)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "unchanged")
        occupied_file = self.root / "occupied"
        occupied_file.write_bytes(b"existing")
        with self.assertRaises(ValueError):
            fixture.prepare_fixture(occupied_file, now=NOW)
        self.assertEqual(occupied_file.read_bytes(), b"existing")

    def test_checkout_output_and_missing_parent_are_rejected(self):
        # Use an isolated pretend checkout; do not create generated files in Git.
        with patch.object(fixture, "REPO_ROOT", self.root):
            with self.assertRaisesRegex(ValueError, "outside this checkout"):
                fixture.prepare_fixture(self.output, now=NOW)
        self.assertFalse(self.output.exists())
        with self.assertRaises(OSError):
            fixture.prepare_fixture(self.root / "absent" / "batch", now=NOW)
        self.assertFalse((self.root / "absent").exists())

    def test_cli_creates_a_local_batch(self):
        completed = subprocess.run(
            [sys.executable, "-B", str(Path(fixture.__file__)), "--output", str(self.output)],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("Nothing was uploaded or published", completed.stdout)
        self.assertTrue((self.output / "first" / "catalog.json").is_file())
        self.assertTrue((self.output / "updated" / "catalog.json").is_file())
        self.assertTrue((self.output / "paused" / "catalog.json").is_file())


if __name__ == "__main__":
    unittest.main()
