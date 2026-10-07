"""Synthetic protocol tests; these bytes are not claimed as real movie exports."""
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

import diagnostic_fixture as fixture

ROOT = Path(__file__).resolve().parents[2]
SHA = "a" * 40


def output_fixture(documents, failed=False):
    output = documents / "MovieSyntheticAcceptance-12345678-1234-1234-1234-123456789abc"
    output.mkdir()
    files = {"exported-on.mp4": b"synthetic-on-protocol", "exported-off.mp4": b"synthetic-off-protocol",
             "opening.png": b"synthetic-png-protocol"}
    for name, data in files.items():
        (output / name).write_bytes(data)
    receipt = {"syntheticOnly": True, "shippingExporterInvoked": True, "exportAttempts": 2,
        "fixtureManifestSHA256": fixture.MANIFEST_SHA256, "buildSourceSHA": SHA,
        "exports": [{"file": name, "soundEnabled": name == "exported-on.mp4", "duration": 370/24,
                     "sha256": fixture.digest(data)} for name, data in files.items() if name.endswith("mp4")],
        "photoBaselineRestored": not failed, "managedCleanupSucceeded": not failed,
        "returnedManagedExportsCleaned": not failed, "remainingNewManagedDirectories": [],
        "result": "failed" if failed else "exported; external inspection pending",
        "visualInspection": "not performed", "listening": "not performed"}
    (output / "receipt.json").write_text(json.dumps(receipt), encoding="utf-8")
    return output, receipt


class DiagnosticFixtureTests(unittest.TestCase):
    def test_pinned_seed_rejects_changes_and_overwrite(self):
        original = fixture.pinned_inputs()
        self.assertEqual(len(original), 9)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app_tmp = root / "tmp"; app_tmp.mkdir()
            self.assertEqual(fixture.seed(app_tmp), {name: fixture.digest(data) for name, data in original.items()})
            with self.assertRaises(FileExistsError):
                fixture.seed(app_tmp)
            self.assertEqual(fixture.pinned_inputs(app_tmp / "movie-synthetic-inputs"), original)
            changed = root / "changed"; shutil.copytree(fixture.FIXED_INPUTS, changed)
            (changed / "still-1.png").write_bytes(b"wrong-input")
            other_tmp = root / "other-tmp"; other_tmp.mkdir()
            with self.assertRaises(ValueError):
                fixture.seed(other_tmp, changed)
            self.assertEqual(list(other_tmp.iterdir()), [])

    def test_success_failure_evidence_and_foreign_files_preserved(self):
        for failed in [False, True]:
            with self.subTest(failed=failed), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                documents = root / "Documents"; documents.mkdir()
                foreign = documents / "foreign-personal-file.txt"; foreign.write_bytes(b"untouched")
                output, _ = output_fixture(documents, failed)
                before = {path.name: path.read_bytes() for path in output.iterdir()}
                destination = root / "evidence"
                report = fixture.collect(documents, destination, SHA)
                self.assertEqual(report["collectionCheck"], "failed" if failed else "passed")
                self.assertEqual({item["file"] for item in report["copied"]}, fixture.OUTPUT_NAMES)
                self.assertEqual({path.name: path.read_bytes() for path in output.iterdir()}, before)
                self.assertEqual(foreign.read_bytes(), b"untouched")
                self.assertFalse((destination / foreign.name).exists())
                self.assertEqual(report["externalMP4Inspection"], "pending")
                with self.assertRaises(FileExistsError):
                    fixture.collect(documents, destination, SHA)

    def test_invalid_receipt_hash_extra_file_and_absence_fail_closed(self):
        for damage in ["receipt", "hash", "extra", "missing", "source-sha"]:
            with self.subTest(damage=damage), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                documents = root / "Documents"; documents.mkdir()
                output, receipt = output_fixture(documents)
                if damage == "receipt":
                    receipt["personalPath"] = "must-not-be-uploaded"
                    (output / "receipt.json").write_text(json.dumps(receipt), encoding="utf-8")
                elif damage == "hash":
                    (output / "exported-on.mp4").write_bytes(b"changed")
                elif damage == "extra":
                    (output / "personal.txt").write_bytes(b"must-not-be-uploaded")
                elif damage == "missing":
                    (output / "receipt.json").unlink()
                else:
                    receipt["buildSourceSHA"] = "b" * 40
                    (output / "receipt.json").write_text(json.dumps(receipt), encoding="utf-8")
                report = fixture.collect(documents, root / "evidence", SHA)
                self.assertEqual(report["collectionCheck"], "failed")
                self.assertNotIn("must-not-be-uploaded", json.dumps(report))
                self.assertTrue((root / "evidence/collection.json").is_file())
                self.assertFalse((root / "evidence/personal.txt").exists())
                if damage in {"hash", "extra", "source-sha"}:
                    self.assertTrue((root / "evidence/receipt.json").is_file())
                if damage == "hash":
                    self.assertTrue((root / "evidence/opening.png").is_file())
                    self.assertTrue((root / "evidence/exported-off.mp4").is_file())
                    self.assertFalse((root / "evidence/exported-on.mp4").exists())

    def test_symlink_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            documents = root / "Documents"; documents.mkdir()
            output, _ = output_fixture(documents)
            saved = root / "saved.mp4"; saved.write_bytes(b"foreign-sentinel")
            (output / "exported-on.mp4").unlink()
            try:
                (output / "exported-on.mp4").symlink_to(saved)
            except OSError as error:
                self.skipTest("Host cannot create symbolic links: " + type(error).__name__)
            report = fixture.collect(documents, root / "evidence", SHA)
            self.assertEqual(report["collectionCheck"], "failed")
            self.assertEqual(saved.read_bytes(), b"foreign-sentinel")
            self.assertFalse((root / "evidence/exported-on.mp4").exists())

    def test_native_registration_and_existing_diagnostic_guard(self):
        sys.path.insert(0, str(ROOT / "NekoWidget/ci"))
        import ios_ci_scope
        source = (ROOT / "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift").read_text(encoding="utf-8")
        name = "testSyntheticMovieShippingExportsSoundOnAndOff"
        self.assertEqual(ios_ci_scope.diagnostic_tests("OfficialWindowUITests", name, source),
            ("NekoWidgetUITests/OfficialWindowUITests/" + name,))
        with self.assertRaises(ValueError):
            ios_ci_scope.diagnostic_tests("PhotoPermissionUITests", name, source)
        script = (ROOT / "NekoWidget/ci/run-sharing-runtime-matrix.sh").read_text(encoding="utf-8")
        self.assertIn('source != os.environ.get("GITHUB_SHA")', script)
        self.assertIn('if [[ "$DIAGNOSTIC_REQUESTED" != true ]]', script)
        self.assertIn('TEST_RUNNER_NEKO_MOVIE_SYNTHETIC_DIAGNOSTIC="$MOVIE_SYNTHETIC_REQUESTED"', script)
        self.assertLess(script.index('diagnostic_fixture.py" collect'), script.index('cleanup_runtime "$simulator_udid" || cleanup_status'))
        self.assertIn('throw XCTSkip("Run only through the pinned synthetic movie', source)


if __name__ == "__main__":
    unittest.main()
