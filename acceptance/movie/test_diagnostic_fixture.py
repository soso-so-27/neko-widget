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
    def diagnostic_receipt(self, documents, **changes):
        directory = documents / "MovieSyntheticDiagnostic-12345678-1234-1234-1234-123456789abc"
        directory.mkdir()
        receipt = {"schemaVersion": 1, "syntheticOnly": True, "result": "failed",
                   "stage": "photos-authorization", "photosAuthorization": "denied", "buildSourceSHA": SHA}
        receipt.update(changes)
        (directory / "receipt.json").write_text(json.dumps(receipt), encoding="utf-8")
        return directory

    def test_pending_and_denied_diagnostics_never_pass_or_modify_source(self):
        for state in sorted(fixture.PHOTOS_STATES):
            for result in ["pending", "failed"]:
                with self.subTest(state=state, result=result), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary); documents = root / "Documents"; documents.mkdir()
                    foreign = documents / "personal.txt"; foreign.write_bytes(b"private-sentinel")
                    directory = self.diagnostic_receipt(documents, photosAuthorization=state, result=result)
                    before = (directory / "receipt.json").read_bytes()
                    # Even complete export protocol evidence cannot override a failed phase.
                    output_fixture(documents)
                    report = fixture.collect(documents, root / "evidence", SHA)
                    self.assertEqual(report["collectionCheck"], "failed")
                    self.assertEqual((root / "evidence/failure-receipt.json").read_bytes(), before)
                    self.assertEqual((directory / "receipt.json").read_bytes(), before)
                    self.assertEqual(foreign.read_bytes(), b"private-sentinel")
                    self.assertNotIn("private-sentinel", json.dumps(report))
                    self.assertFalse((root / "evidence/personal.txt").exists())

    def test_early_failure_is_captured_without_native_exports(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); documents = root / "Documents"; documents.mkdir()
            self.diagnostic_receipt(documents, result="pending", photosAuthorization="notDetermined")
            report = fixture.collect(documents, root / "evidence", SHA)
            self.assertEqual(report["collectionCheck"], "failed")
            self.assertEqual({item["file"] for item in report["copied"]}, {"failure-receipt.json"})

    def test_completed_diagnostic_requires_original_export_protocol(self):
        for exports in [False, True]:
            with self.subTest(exports=exports), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); documents = root / "Documents"; documents.mkdir()
                self.diagnostic_receipt(documents, result="completed", stage="synthetic-fixture",
                                        photosAuthorization="authorized")
                if exports:
                    output_fixture(documents)
                report = fixture.collect(documents, root / "evidence", SHA)
                self.assertEqual(report["collectionCheck"], "passed" if exports else "failed")
                self.assertEqual({item["file"] for item in report["copied"]}, fixture.OUTPUT_NAMES if exports else set())

    def test_malformed_diagnostic_fields_are_not_copied(self):
        changes = [{"photoIdentifier": "private-sentinel"}, {"stage": "private-sentinel"},
                   {"photosAuthorization": "private-sentinel"}, {"buildSourceSHA": "private-sentinel"},
                   {"result": "passed"}, {"result": []}, {"schemaVersion": True}, {"syntheticOnly": False}]
        for change in changes:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); documents = root / "Documents"; documents.mkdir()
                self.diagnostic_receipt(documents, **change)
                report = fixture.collect(documents, root / "evidence", SHA)
                self.assertEqual(report["collectionCheck"], "failed")
                self.assertEqual(report["copied"], [])
                self.assertNotIn("private-sentinel", json.dumps(report))

    def test_duplicate_fields_cannot_hide_private_raw_bytes(self):
        for native in [False, True]:
            with self.subTest(native=native), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); documents = root / "Documents"; documents.mkdir()
                directory = output_fixture(documents)[0] if native else self.diagnostic_receipt(documents)
                path = directory / "receipt.json"
                original = path.read_text(encoding="utf-8")
                field = "result" if native else "stage"
                path.write_text('{"' + field + '":"private-sentinel",' + original[1:], encoding="utf-8")
                report = fixture.collect(documents, root / "evidence", SHA)
                self.assertEqual(report["collectionCheck"], "failed")
                self.assertEqual(report["copied"], [])
                self.assertNotIn("private-sentinel", json.dumps(report))
                for copied in (root / "evidence").iterdir():
                    self.assertNotIn(b"private-sentinel", copied.read_bytes())

    def test_ambiguous_extra_oversize_and_source_drift_fail_closed(self):
        for damage in ["duplicate", "extra", "oversize", "source", "completed-denied", "completed-stage"]:
            with self.subTest(damage=damage), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); documents = root / "Documents"; documents.mkdir()
                changes = {"buildSourceSHA": "b" * 40} if damage == "source" else {}
                if damage.startswith("completed"):
                    changes.update(result="completed", stage="synthetic-fixture", photosAuthorization="authorized")
                    changes["photosAuthorization" if damage == "completed-denied" else "stage"] = "denied" if damage == "completed-denied" else "cleanup-lifecycle"
                directory = self.diagnostic_receipt(documents, **changes)
                if damage == "duplicate":
                    shutil.copytree(directory, documents / "MovieSyntheticDiagnostic-aaaaaaaa-1234-1234-1234-123456789abc")
                elif damage == "extra":
                    (directory / "private.txt").write_bytes(b"private-sentinel")
                elif damage == "oversize":
                    with (directory / "receipt.json").open("ab") as stream:
                        stream.write(b" " * 4096)
                output_fixture(documents)
                report = fixture.collect(documents, root / "evidence", SHA)
                self.assertEqual(report["collectionCheck"], "failed")
                self.assertEqual((root / "evidence/failure-receipt.json").exists(), damage == "source")
                self.assertNotIn("private-sentinel", json.dumps(report))

    def test_authorization_change_is_confined_to_pinned_simulator_route(self):
        source = (ROOT / "NekoWidget/NekoWidget/App/MainlineMovieAcceptance.swift").read_text(encoding="utf-8")
        wrapper = source.split("private static func runAuthorizedCapture()", 1)[0]
        self.assertTrue(source.startswith("#if DEBUG && targetEnvironment(simulator)"))
        self.assertIn('environment["NEKO_MAINLINE_ACCEPTANCE_CASE"] == "movie"', wrapper)
        self.assertIn('environment["NEKO_MOVIE_SYNTHETIC_FIXTURE_DIR"] == "@app-tmp/movie-synthetic-inputs"', wrapper)
        self.assertIn("CommandLine.arguments.contains(AppStoreScreenshotFixture.launchArgument)", wrapper)
        self.assertIn("return try await runAuthorizedCapture()", wrapper)
        self.assertIn("if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined", wrapper)
        self.assertLess(wrapper.index("result: .pending"), wrapper.index("await PHPhotoLibrary.requestAuthorization"))
        self.assertLess(wrapper.index("await PHPhotoLibrary.requestAuthorization"), wrapper.index("== .authorized"))
        self.assertIn("throw error", wrapper)
        self.assertNotIn("localIdentifier", wrapper)
        ui = (ROOT / "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift").read_text(encoding="utf-8").split("func test", 2)[1]
        self.assertIn('localizedCaseInsensitiveContains("photos")', ui)
        self.assertLess(ui.index("addUIInterruptionMonitor"), ui.index("app.launch()"))
        self.assertIn("XCTAssertTrue(ready.exists", ui)
        self.assertIn("180", ui)

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
