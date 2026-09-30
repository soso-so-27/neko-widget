#!/usr/bin/env python3
"""Ensure split jobs conserve checks and cannot reuse partial/legacy evidence."""

import copy
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import ios_ci_scope as scope

CI = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("planner", CI / "plan-ios-ci.py")
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)


def workflow_jobs():
    workflow = (CI.parents[1] / ".github/workflows/ios-build.yml").read_text(encoding="utf-8")
    return dict(re.findall(r"^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)",
                           workflow.split("\njobs:\n", 1)[1], re.M | re.S))


class LaneTests(unittest.TestCase):
    def test_care_handoff_frozen_sources_modes_and_evidence(self):
        selected = scope.CARE_HANDOFF_SCOPE
        methods = "\n".join("    func " + test.rsplit("/", 1)[1] + "() {}"
                            for test in scope.CARE_HANDOFF_TESTS)
        tests = "final class SoloMemoriesUITests: XCTestCase {\n" + methods + "\n}"
        changes = {path: ("" if path in scope.CARE_HANDOFF_NEW_PATHS else "before",
                          tests if path == scope.MEMORY_TEST_PATH else "after")
                   for path in scope.CARE_HANDOFF_PATHS}
        digests = {path: list(map(scope.source_digest, pair)) for path, pair in changes.items()}
        base, head = "a" * 40, "b" * 40

        def raw_scope(override=None, extra=False):
            records = []
            for path in sorted(changes):
                added = path in scope.CARE_HANDOFF_NEW_PATHS
                modes, status = (":000000 100644", "A") if added else (":100644 100644", "M")
                if override and override[0] == path:
                    modes, status = override[1:]
                records.append(f"{modes} {'0' * 40 if added else 'c' * 40} {'d' * 40} {status}\0{path}\0")
            if extra:
                records.append(f":100644 100644 {'c' * 40} {'d' * 40} M\0unreported.swift\0")

            def git(*args):
                if args[0] == "diff":
                    return "".join(records)
                if args[0] == "show":
                    revision, path = args[1].split(":", 1)
                    return changes[path][0 if revision == base else 1]
                return head

            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(sorted(changes), {}, {"GITHUB_SHA": head})

        with patch.object(scope, "CARE_HANDOFF_DIGESTS", digests):
            self.assertEqual(scope.select_scope(changes), selected)
            self.assertEqual(raw_scope(), selected)
            self.assertEqual(raw_scope(extra=True), scope.FULL_SCOPE)
            for path in changes:
                self.assertEqual(scope.select_scope({p: v for p, v in changes.items() if p != path}), scope.FULL_SCOPE)
                for index in (0, 1):
                    modified = dict(changes)
                    pair = list(modified[path]); pair[index] += "unreviewed"
                    modified[path] = tuple(pair)
                    self.assertEqual(scope.select_scope(modified), scope.FULL_SCOPE)
                for modes, status in ((":100644 000000", "D"), (":100644 100755", "M"),
                                      (":100644 120000", "T"), (":000000 120000", "A"),
                                      (":100644 100644", "R100")):
                    self.assertEqual(raw_scope((path, modes, status)), scope.FULL_SCOPE)
                incorrect = (":100644 100644", "M") if path in scope.CARE_HANDOFF_NEW_PATHS else (":000000 100644", "A")
                self.assertEqual(raw_scope((path, *incorrect)), scope.FULL_SCOPE)
            for path in ("NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                         "NekoWidget/ci/ios_ci_scope.py", ".github/workflows/ios-build.yml",
                         "NekoWidget/Shared/Models/WidgetManifest.swift"):
                self.assertEqual(scope.select_scope(changes | {path: ("old", "new")}), scope.FULL_SCOPE)
        self.assertEqual(len(scope.CARE_HANDOFF_PATHS), 9)
        self.assertEqual(len(scope.CARE_HANDOFF_NEW_PATHS), 5)
        self.assertEqual(len(set(scope.CARE_HANDOFF_TESTS)), 3)
        self.assertEqual(scope.lanes(selected), ("runtime", "app-ui"))
        self.assertEqual(scope.lane_tests(selected, "app-ui"), scope.CARE_HANDOFF_TESTS)
        self.assertEqual(scope.smoke_tests(selected),
                         ("NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",))
        required = planner.required_jobs_from_scope(selected)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(selected))
        self.assertTrue(scope.accepts_paths(selected, changes))
        self.assertNotIn(scope.GALLERY_TEST, scope.native_tests(selected))
        jobs = [dict(name=name, head_sha=head, status="completed", conclusion="success") for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, head))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, head))
            for outcome in ("skipped", "failure", "cancelled"):
                failed = copy.deepcopy(jobs); failed[index]["conclusion"] = outcome
                self.assertFalse(planner.covers_jobs(failed, required, head))

    def test_evacuation_frozen_sources_modes_and_evidence(self):
        selected = scope.EVACUATION_SCOPE
        methods = "\n".join("    func " + test.rsplit("/", 1)[1] + "() {}"
                            for test in scope.EVACUATION_TESTS)
        tests = "final class SoloMemoriesUITests: XCTestCase {\n" + methods + "\n}"
        changes = {path: ("" if path in scope.EVACUATION_NEW_PATHS else "before",
                          tests if path == scope.MEMORY_TEST_PATH else "after")
                   for path in scope.EVACUATION_PATHS}
        digests = {path: list(map(scope.source_digest, pair)) for path, pair in changes.items()}
        base, head = "a" * 40, "b" * 40

        def raw_scope(override=None, extra=False):
            records = []
            for path in sorted(changes):
                added = path in scope.EVACUATION_NEW_PATHS
                modes, status = (":000000 100644", "A") if added else (":100644 100644", "M")
                if override and override[0] == path:
                    modes, status = override[1:]
                records.append(f"{modes} {'0' * 40 if added else 'c' * 40} {'d' * 40} {status}\0{path}\0")
            if extra:
                records.append(f":100644 100644 {'c' * 40} {'d' * 40} M\0unreported.swift\0")

            def git(*args):
                if args[0] == "diff":
                    return "".join(records)
                if args[0] == "show":
                    revision, path = args[1].split(":", 1)
                    return changes[path][0 if revision == base else 1]
                return head

            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(sorted(changes), {}, {"GITHUB_SHA": head})

        with patch.object(scope, "EVACUATION_DIGESTS", digests):
            self.assertEqual(scope.select_scope(changes), selected)
            self.assertEqual(raw_scope(), selected)
            self.assertEqual(raw_scope(extra=True), scope.FULL_SCOPE)
            for path in changes:
                self.assertEqual(scope.select_scope({p: v for p, v in changes.items() if p != path}), scope.FULL_SCOPE)
                for index in (0, 1):
                    modified = dict(changes)
                    pair = list(modified[path]); pair[index] += "unreviewed"
                    modified[path] = tuple(pair)
                    self.assertEqual(scope.select_scope(modified), scope.FULL_SCOPE)
                for modes, status in ((":100644 000000", "D"), (":100644 100755", "M"),
                                      (":100644 120000", "T"), (":000000 120000", "A"),
                                      (":100644 100644", "R100")):
                    self.assertEqual(raw_scope((path, modes, status)), scope.FULL_SCOPE)
                incorrect = (":100644 100644", "M") if path in scope.EVACUATION_NEW_PATHS else (":000000 100644", "A")
                self.assertEqual(raw_scope((path, *incorrect)), scope.FULL_SCOPE)
            for path in ("NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                         "NekoWidget/ci/ios_ci_scope.py", ".github/workflows/ios-build.yml",
                         "NekoWidget/Shared/Models/WidgetManifest.swift"):
                self.assertEqual(scope.select_scope(changes | {path: ("old", "new")}), scope.FULL_SCOPE)
        self.assertEqual(len(scope.EVACUATION_PATHS), 9)
        self.assertEqual(len(scope.EVACUATION_NEW_PATHS), 5)
        self.assertEqual(len(set(scope.EVACUATION_TESTS)), 3)
        self.assertEqual(scope.lanes(selected), ("runtime", "app-ui"))
        self.assertEqual(scope.lane_tests(selected, "app-ui"), scope.EVACUATION_TESTS)
        self.assertEqual(scope.smoke_tests(selected),
                         ("NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",))
        required = planner.required_jobs_from_scope(selected)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(selected))
        self.assertTrue(scope.accepts_paths(selected, changes))
        self.assertNotIn(scope.GALLERY_TEST, scope.native_tests(selected))
        jobs = [dict(name=name, head_sha=head, status="completed", conclusion="success") for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, head))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, head))
            for outcome in ("skipped", "failure", "cancelled"):
                failed = copy.deepcopy(jobs); failed[index]["conclusion"] = outcome
                self.assertFalse(planner.covers_jobs(failed, required, head))

    def test_lost_cat_ux_scope_keeps_store_boundaries_and_three_ui_checks(self):
        store_path = scope.LOST_CAT_STORE_PATH
        view_path = scope.LOST_CAT_PHOTO_PATH
        before = (CI.parents[0] / "NekoWidget/Services/CatPreparednessStore.swift").read_text(
            encoding="utf-8")
        method = ("    func removePhoto(_ role: CatPreparednessStore.PhotoRole,\n"
                  "                     draft: LostCatDraft, for key: String) throws -> LostCatDraft {\n"
                  "        var updated = draft\n"
                  "        if role == .face { updated.faceFileName = nil }\n"
                  "        else { updated.bodyFileName = nil }\n"
                  "        try save(updated, for: key)\n"
                  "        return updated\n"
                  "    }\n\n")
        after = before.replace("    func image(_ name:", method + "    func image(_ name:", 1)
        after = after.replace("猫を探しています。", "この猫を探しています。", 1)
        self.assertTrue(scope.lost_cat_store_changes(before, after))
        tests = (CI.parents[0] / "NekoWidgetUITests/PhotoPermissionUITests.swift").read_text(
            encoding="utf-8")
        changes = {view_path: ("struct Before {}", "struct After {}"),
                   store_path: (before, after)}
        selected = scope.LOST_CAT_UX_SCOPE
        self.assertEqual(scope.select_scope(changes, memory_test_source=tests), selected)
        self.assertTrue(scope.accepts_paths(selected, changes))
        self.assertEqual(scope.lanes(selected), ("runtime", "app-ui"))
        self.assertEqual(scope.lane_tests(selected, "app-ui"), scope.LOST_CAT_PHOTO_TESTS)
        self.assertEqual(scope.smoke_tests(selected),
                         ("NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",))
        self.assertEqual(planner.required_jobs_from_scope(selected),
                         (planner.BUILD, planner.BOOTSTRAP_SMOKE,
                          scope.lane_job(selected, "runtime"),
                          scope.lane_job(selected, "app-ui")))
        for unsafe in (after.replace("safe.name = String(record.name.prefix(60))", "safe.name = record.name"),
                       after.replace("static let schemaVersion = 1", "static let schemaVersion = 2"),
                       after.replace("try save(updated, for: key)", "try delete(for: key)", 1),
                       after + "\nstruct ExtraStore {}\n"):
            self.assertFalse(scope.lost_cat_store_changes(before, unsafe))
            self.assertNotEqual(scope.select_scope({view_path: changes[view_path],
                store_path: (before, unsafe)}, memory_test_source=tests), selected)
        self.assertNotEqual(scope.select_scope({**changes,
            "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift": ("old", "new")},
            memory_test_source=tests), selected)

    def test_reviewed_lost_cat_photo_change_uses_only_owning_ui_checks(self):
        path = scope.LOST_CAT_PHOTO_PATH
        before_tests = """import XCTest
final class SoloMemoriesUITests: XCTestCase {
    @MainActor
    func testUnpreparedLostCatDraftPreviewsAndCreatesImageAndPDF() {
        XCTAssertTrue(true)
    }
    @MainActor
    func testLostCatDraftOffersThisCatsPhotosBeforeEntireLibrary() {
        XCTAssertTrue(true)
    }
    @MainActor
    func testOtherAlbumRoute() {
        XCTAssertTrue(true)
    }
}
final class UnrelatedUITests: XCTestCase {
    func testOther() {}
}
"""
        after_tests = before_tests.replace(
            "    @MainActor\n    func testOtherAlbumRoute()",
            "    @MainActor\n    func testLostCatPhotoTapSelectsOnlyTheTappedCandidate() {\n"
            "        XCTAssertTrue(true)\n    }\n"
            "    @MainActor\n    func testOtherAlbumRoute()",
        )
        before_view = '#if DEBUG\nlet fixture = 1\n#endif\n'
        after_view = '#if DEBUG\nlet fixture = 2\n#endif\n'
        selected = scope.LOST_CAT_PHOTO_SCOPE
        self.assertEqual(selected, "lost-cat-photo-ui-v2")
        self.assertEqual(scope.lanes(selected), ("runtime", "app-ui"))
        self.assertEqual(scope.lane_tests(selected, "app-ui"), scope.LOST_CAT_PHOTO_TESTS)
        self.assertEqual(len(set(scope.LOST_CAT_PHOTO_TESTS)), 3)
        self.assertEqual(scope.smoke_tests(selected),
                         ("NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",))
        self.assertEqual(planner.required_jobs_from_scope(selected),
                         (planner.BUILD, planner.BOOTSTRAP_SMOKE,
                          scope.lane_job(selected, "runtime"),
                          scope.lane_job(selected, "app-ui")))
        self.assertTrue(scope.accepts_paths(selected, [path]))
        self.assertTrue(scope.accepts_paths(selected, [path, scope.MEMORY_TEST_PATH]))
        self.assertFalse(scope.accepts_paths(selected, [path,
            "NekoWidget/NekoWidget/Services/CatPreparednessStore.swift"]))
        changes = {path: (before_view, after_view),
                   scope.MEMORY_TEST_PATH: (before_tests, after_tests)}
        self.assertEqual(scope.select_scope(changes), selected)
        edited_owned_test = after_tests.replace(
            "func testUnpreparedLostCatDraftPreviewsAndCreatesImageAndPDF() {\n"
            "        XCTAssertTrue(true)",
            "func testUnpreparedLostCatDraftPreviewsAndCreatesImageAndPDF() {\n"
            "        XCTAssertTrue(false)")
        self.assertEqual(scope.select_scope({path: (before_view, after_view),
            scope.MEMORY_TEST_PATH: (before_tests, edited_owned_test)}), selected)
        self.assertEqual(scope.select_scope({path: (before_view, after_view)},
                         memory_test_source=after_tests), selected)
        self.assertEqual(scope.select_scope({path: (before_view, after_view)},
                         memory_test_source=before_tests), scope.APP_VIEW_SCOPE)
        for changed_tests in (
            after_tests.replace("func testOtherAlbumRoute() {\n        XCTAssertTrue(true)",
                                "func testOtherAlbumRoute() {\n        XCTAssertTrue(false)"),
            after_tests.replace("import XCTest", "import XCTest\nimport Photos"),
            after_tests.replace("func testOther() {}", "func testOther() { XCTAssertTrue(true) }"),
            after_tests.replace("func testOtherAlbumRoute()", "func newHelper() {}\n"
                                "    @MainActor\n    func testOtherAlbumRoute()"),
        ):
            with self.subTest(changed_tests=changed_tests[-75:]):
                self.assertEqual(scope.select_scope({path: (before_view, after_view),
                    scope.MEMORY_TEST_PATH: (before_tests, changed_tests)}), scope.APP_VIEW_SCOPE)
        self.assertEqual(scope.select_scope({**changes,
            "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift": ("old", "new")}),
            scope.FULL_SCOPE)
        self.assertNotEqual(scope.select_scope({**changes,
            "NekoWidget/NekoWidget/Services/CatPreparednessStore.swift": ("old", "new")}),
            selected)

    def test_app_view_scope_sources_belong_only_to_app_or_ui_test_target(self):
        project = (CI.parents[0] / "NekoWidget.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
        phases = dict(re.findall(
            r"([A-F0-9]{24}) /\* Sources \*/ = \{\s*isa = PBXSourcesBuildPhase;.*?files = \((.*?)\);",
            project, re.S,
        ))
        app_sources = phases["A00000000000000000000021"]
        ui_test_sources = phases["A00000000000000000000028"]
        for name in ("MainTabView.swift", "PhotoMemoryNoteLibraryView.swift"):
            marker = f"/* {name} in Sources */"
            self.assertIn(marker, app_sources)
            self.assertEqual(sum(marker in sources for sources in phases.values()), 1)
        marker = "/* PhotoPermissionUITests.swift in Sources */"
        self.assertIn(marker, ui_test_sources)
        self.assertEqual(sum(marker in sources for sources in phases.values()), 1)

    def test_app_view_changes_keep_full_app_checks_without_widget_gallery(self):
        main = "NekoWidget/NekoWidget/Views/MainTabView.swift"
        notes = "NekoWidget/NekoWidget/Views/PhotoMemoryNoteLibraryView.swift"
        ui_test = scope.MEMORY_TEST_PATH
        changed = {path: ("old", "new") for path in (main, notes, ui_test)}
        selected = scope.APP_VIEW_SCOPE
        self.assertEqual(scope.select_scope(changed), selected)
        self.assertEqual(scope.lanes(selected), ("runtime", "app-ui-solo", "app-ui-other"))
        self.assertEqual(scope.native_tests(selected),
                         tuple(test for test in scope.native_tests(scope.FULL_SCOPE)
                               if test != scope.GALLERY_TEST))
        self.assertEqual(scope.smoke_tests(selected), scope.smoke_tests(scope.FULL_SCOPE))
        self.assertEqual(scope.matrix_lanes(selected), ("runtime",))
        self.assertEqual(planner.required_jobs_from_scope(selected), (
            planner.BUILD, planner.SMOKE,
            scope.lane_job(selected, "runtime"),
            scope.lane_job(selected, "app-ui-solo"),
            scope.lane_job(selected, "app-ui-other"),
        ))
        release_note = "NekoWidget/ci/release-candidates/2026-09-25-showcase-ia.md"
        self.assertEqual(scope.select_scope({ui_test: ("old", "new")}), selected)
        self.assertEqual(scope.select_scope({ui_test: ("old", "new"), release_note: ("", "reviewed")}), selected)
        self.assertEqual(planner.required_jobs([ui_test, release_note], selected),
                         planner.required_jobs_from_scope(selected))
        for unsafe in (
            {ui_test: ("old", "new"), "NekoWidget/ci/release-candidates/selector.py": ("", "code")},
            {ui_test: ("old", "new"), "NekoWidget/ci/release-candidates/nested/review.md": ("", "note")},
            {ui_test: ("old", "new"), "NekoWidget/NekoWidget/Services/PhotoMemoryNoteStore.swift": ("old", "new")},
            dict(changed, **{"NekoWidget/NekoWidgetWidget/NekoWidgetTimelineProvider.swift": ("old", "new")}),
            dict(changed, **{"NekoWidget/Shared/AppGroup/SharedContainer.swift": ("old", "new")}),
        ):
            self.assertEqual(scope.select_scope(unsafe), scope.FULL_SCOPE)
            self.assertEqual(planner.required_jobs(list(unsafe), selected), planner.FULL)

    def test_full_partition_preserves_all_app_suites_and_three_gallery_conditions(self):
        self.assertEqual(scope.lanes(scope.FULL_SCOPE),
                         ("runtime", "app-ui-solo", "app-ui-other", "gallery-normal", "gallery-white", "gallery-no-caption"))
        self.assertEqual(scope.lane_tests(scope.FULL_SCOPE, "runtime"), ())
        solo = scope.lane_tests(scope.FULL_SCOPE, "app-ui-solo")
        other = scope.lane_tests(scope.FULL_SCOPE, "app-ui-other")
        self.assertTrue(solo and other)
        self.assertFalse(set(solo) & set(other))
        app = solo + other
        self.assertEqual(set(app), set(scope.native_tests(scope.FULL_SCOPE)) - {scope.GALLERY_TEST})
        self.assertEqual(len(app), len(set(app)))
        self.assertEqual(scope.lane_tests(scope.FULL_SCOPE, "gallery-normal"), (scope.GALLERY_TEST,))
        self.assertEqual(scope.lane_tests(scope.FULL_SCOPE, "gallery-no-caption"), (scope.GALLERY_TEST,))
        self.assertIn("WhiteBackground", scope.lane_tests(scope.FULL_SCOPE, "gallery-white")[0])
        self.assertIn("NO_CAPTION", scope.GALLERY_CONDITIONS["gallery-no-caption"])
        self.assertIn("LONG_CAPTION", scope.GALLERY_CONDITIONS["gallery-white"])
        self.assertIn("LARGE_TEXT", scope.GALLERY_CONDITIONS["gallery-white"])

    def test_mapped_scope_keeps_runtime_and_its_existing_ui_suites(self):
        for selected in (scope.PHOTO_SCOPE, scope.OFFICIAL_SCOPE, scope.COMBINED_SCOPE,
                         scope.REVIEWED_MANAGED_PRESERVATION_SCOPE):
            self.assertEqual(scope.lanes(selected), ("runtime", "app-ui"))
            self.assertEqual(scope.lane_tests(selected, "app-ui"), scope.native_tests(selected))
            with self.assertRaises(ValueError):
                scope.lane_tests(selected, "gallery-normal")
        for selected, lane in (("unknown", "runtime"), (scope.FULL_SCOPE, "unknown")):
            with self.assertRaises(ValueError):
                scope.lane_tests(selected, lane)
        selected = scope.REVIEWED_MANAGED_PRESERVATION_SCOPE
        self.assertEqual(selected, 'reviewed-managed-preservation-app-v3')
        self.assertEqual(scope.matrix_lanes(selected), ('runtime',))
        self.assertEqual(scope.lane_tests(selected, 'app-ui'), (
            'NekoWidgetUITests/SoloMemoriesUITests/testManagedPreservationDisabledHidesEntries',
            'NekoWidgetUITests/SoloMemoriesUITests/testManagedPreservationLostCopyResultShowsConfirmationAndStoredState',
        ))
        self.assertEqual(planner.required_jobs_from_scope(selected), (
            planner.BUILD, planner.BOOTSTRAP_SMOKE,
            'Sharing checks [runtime; scope reviewed-managed-preservation-app-v3]',
            'Sharing checks [app-ui; scope reviewed-managed-preservation-app-v3]',
        ))
        with self.assertRaises(ValueError):
            planner.required_jobs_from_scope('reviewed-managed-preservation-app-v1')

    def test_each_missing_failed_skipped_duplicate_or_wrong_sha_lane_prevents_reuse(self):
        sha = "a" * 40
        jobs = [dict(name=name, status="completed", conclusion="success", head_sha=sha)
                for name in planner.FULL]
        self.assertTrue(planner.covers_jobs(jobs, planner.FULL, sha))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], planner.FULL, sha))
            self.assertFalse(planner.covers_jobs(jobs + [jobs[index]], planner.FULL, sha))
            for key, value in (("conclusion", "failure"), ("conclusion", "skipped"),
                               ("conclusion", "cancelled"), ("head_sha", "b" * 40)):
                altered = copy.deepcopy(jobs)
                altered[index][key] = value
                self.assertFalse(planner.covers_jobs(altered, planner.FULL, sha))
        legacy = jobs[:2] + [dict(jobs[2], name=scope.sharing_job(scope.FULL_SCOPE))]
        self.assertFalse(planner.covers_jobs(legacy, planner.FULL, sha))

    def test_lane_metadata_reports_only_executed_os_and_exact_test_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for lane in scope.lanes(scope.FULL_SCOPE):
                result = subprocess.run([sys.executable, str(CI / "ios_ci_scope.py"),
                    "--scope", scope.FULL_SCOPE, "--lane", lane, "--metadata", str(root / "meta.json"),
                    "--tests", str(root / "tests.txt")], env=dict(os.environ, GITHUB_SHA="a" * 40),
                    capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                meta = json.loads((root / "meta.json").read_text())
                self.assertEqual(meta["lane"], lane)
                self.assertEqual(meta["commit"], "a" * 40)
                self.assertEqual(meta["sharingRuntime"], ["ios-18-5", "ios-26-2"] if lane == "runtime" else ["ios-26-2"])
                self.assertEqual(meta["nativeTests"], list(scope.lane_tests(scope.FULL_SCOPE, lane)))
                self.assertEqual((root / "tests.txt").read_text().splitlines(),
                                 ["-only-testing:" + test for test in meta["nativeTests"]])

    def test_workflow_isolates_products_and_preserves_independent_failures(self):
        jobs = workflow_jobs()
        matrix = jobs["sharing-runtime-matrix"]
        app_ui = jobs["sharing-app-ui"]
        self.assertIn("fail-fast: false", matrix)
        self.assertIn("fail-fast: false", app_ui)
        self.assertIn("lane: ${{ fromJSON(needs.plan.outputs.app_ui_lanes) }}", app_ui)
        self.assertIn("lane: ${{ fromJSON(needs.plan.outputs.matrix_lanes) }}", matrix)
        self.assertIn("NEKO_IOS_RUNTIME_LANE: ${{ matrix.lane }}", matrix)
        self.assertIn("${{ matrix.lane }}-${{ needs.plan.outputs.runtime_scope }}-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}", matrix)
        for identifier in ("sharing-app-ui", "sharing-runtime-matrix"):
            body = jobs[identifier]
            self.assertNotIn("download-artifact", body)
            self.assertNotIn("continue-on-error", body)
            expected_timeout = 75 if identifier == "sharing-app-ui" else 60
            self.assertIn(f"timeout-minutes: {expected_timeout}", body)
            # Scheduling must not change checkout isolation, commands, flags,
            # artifact provenance or whether a failure is propagated.
            steps = body.split("    steps:\n", 1)[1]
            self.assertEqual(steps.strip(), matrix.split("    steps:\n", 1)[1].strip())

    def test_actual_workflow_keeps_app_ui_in_first_five_without_losing_evidence(self):
        jobs = workflow_jobs()
        for selected in scope.SCOPES:
            with self.subTest(scope=selected):
                remaining = scope.matrix_lanes(selected)
                ui_lanes = scope.app_ui_lanes(selected)
                has_app_ui = bool(ui_lanes)
                partition = ui_lanes + remaining
                self.assertCountEqual(partition, scope.lanes(selected))
                self.assertEqual(len(partition), len(set(partition)))
                outputs = {"lanes": scope.lanes(selected), "matrix_lanes": remaining,
                           "app_ui_lanes": ui_lanes}
                parallelism = 3 if selected == scope.WIDGET_STYLE_SCOPE else 1 if selected == scope.FULL_SCOPE else 2
                maximum_running = 0
                names = []
                for identifier, body in jobs.items():
                    if "    runs-on: macos-15\n" not in body:
                        continue
                    if selected == scope.ICON_SCOPE and identifier != "build-without-signing":
                        continue
                    if identifier == "sharing-app-ui" and not has_app_ui:
                        self.assertIn("if: needs.plan.outputs.app_ui == 'true'", body)
                        continue
                    matrix = re.search(r"lane: \$\{\{ fromJSON\(needs.plan.outputs.(\w+)\) \}\}", body)
                    expansion = outputs[matrix[1]] if matrix else (None,)
                    limit = parallelism if identifier == "sharing-runtime-matrix" else len(expansion)
                    if matrix:
                        if identifier == "sharing-runtime-matrix":
                            self.assertIn("max-parallel: ${{ fromJSON(needs.plan.outputs.matrix_parallelism) }}", body)
                    maximum_running += min(len(expansion), limit)
                    # Every Mac check depends only on the planner. A failed
                    # sibling neither blocks another check nor forces its rerun.
                    self.assertIn("    needs: plan\n", body)
                    self.assertNotIn("continue-on-error", body)
                    name = re.search(r"^    name: (.+)$", body, re.M)[1]
                    for lane in expansion:
                        expanded_name = name.replace("${{ needs.plan.outputs.runtime_scope }}", selected)
                        expanded_name = expanded_name.replace("${{ needs.plan.outputs.build_name }}",
                            planner.ICON_BUILD if selected == scope.ICON_SCOPE else planner.BUILD)
                        expanded_name = expanded_name.replace("${{ needs.plan.outputs.smoke_name }}", planner.smoke_job(selected))
                        if lane:
                            expanded_name = expanded_name.replace("${{ matrix.lane }}", lane)
                        names.append(expanded_name)
                self.assertCountEqual(names, planner.required_jobs_from_scope(selected))
                self.assertEqual(len(names), len(set(names)))
                if has_app_ui:
                    self.assertIn("    name: Sharing checks [${{ matrix.lane }}; scope ${{ needs.plan.outputs.runtime_scope }}]", jobs["sharing-app-ui"])
                self.assertLessEqual(maximum_running, 5)
                self.assertEqual(maximum_running, 1 if selected == scope.ICON_SCOPE else
                    4 if selected in (scope.TOOL_CAT_AUTOFILL_SCOPE, scope.VET_SAVED_CAT_SCOPE) else
                    4 if selected in (scope.PHOTO_SCOPE, scope.OFFICIAL_SCOPE, scope.COMBINED_SCOPE, scope.REVIEWED_APP_SCOPE, scope.LOST_CAT_PHOTO_SCOPE, scope.LOST_CAT_UX_SCOPE, scope.EVACUATION_SCOPE, scope.CARE_HANDOFF_SCOPE, scope.TOOLS_HUB_SCOPE, scope.WINDOW_HUB_SCOPE, scope.ARCHIVE_PICKER_SCOPE, scope.REVIEWED_MEMORY_SCOPE, scope.REVIEWED_MEMORY_FAMILY_SCOPE, scope.REVIEWED_CAT_NOTE_SCOPE, scope.REVIEWED_PHOTO_ACTIONS_SCOPE, scope.REVIEWED_FAMILY_EXPORT_SCOPE, scope.FAMILY_WINDOW_UI_SCOPE, scope.REVIEWED_MEMBERSHIP_OFFER_SCOPE, scope.REVIEWED_DELIVERY_MEMBERSHIP_SCOPE, scope.REVIEWED_WINDOW_SUPPORT_SCOPE, scope.REVIEWED_RECORD_PORTABILITY_SCOPE, scope.REVIEWED_MANAGED_PRESERVATION_SCOPE) else 5)
                if selected in (scope.TOOL_CAT_AUTOFILL_SCOPE, scope.VET_SAVED_CAT_SCOPE) or selected in (scope.PHOTO_SCOPE, scope.OFFICIAL_SCOPE, scope.COMBINED_SCOPE, scope.REVIEWED_APP_SCOPE, scope.LOST_CAT_PHOTO_SCOPE, scope.LOST_CAT_UX_SCOPE, scope.EVACUATION_SCOPE, scope.CARE_HANDOFF_SCOPE, scope.TOOLS_HUB_SCOPE, scope.WINDOW_HUB_SCOPE, scope.ARCHIVE_PICKER_SCOPE, scope.REVIEWED_MEMORY_SCOPE, scope.REVIEWED_MEMORY_FAMILY_SCOPE, scope.REVIEWED_CAT_NOTE_SCOPE, scope.REVIEWED_PHOTO_ACTIONS_SCOPE, scope.REVIEWED_FAMILY_EXPORT_SCOPE, scope.FAMILY_WINDOW_UI_SCOPE, scope.REVIEWED_MEMBERSHIP_OFFER_SCOPE, scope.REVIEWED_DELIVERY_MEMBERSHIP_SCOPE, scope.REVIEWED_WINDOW_SUPPORT_SCOPE, scope.REVIEWED_RECORD_PORTABILITY_SCOPE, scope.REVIEWED_MANAGED_PRESERVATION_SCOPE):
                    self.assertEqual(remaining, ("runtime",))
        with self.assertRaises(ValueError):
            scope.matrix_lanes("unknown")

    def test_partial_rerun_keeps_passed_siblings_and_uses_only_latest_result(self):
        run = dict(id=42, head_sha="a" * 40, run_attempt=2)
        first = [dict(id=index + 1, run_id=42, run_attempt=1, name=name,
                      status="completed", conclusion="success", head_sha=run["head_sha"])
                 for index, name in enumerate(planner.FULL)]
        first[-1]["conclusion"] = "failure"
        retry = dict(first[-1], id=20, run_attempt=2, conclusion="success")
        def select(records):
            return planner.executed_jobs(run, "owner/repo", lambda path: {
                "jobs": records, "total_count": len(records)})
        self.assertTrue(planner.covers_jobs(select(first + [retry]), planner.FULL, run["head_sha"]))
        for value in ("failure", "skipped", "cancelled"):
            self.assertFalse(planner.covers_jobs(select(first + [dict(retry, conclusion=value)]),
                                                planner.FULL, run["head_sha"]))
        for records in (first + [retry, dict(retry, id=21)], first + [dict(retry, head_sha="b" * 40)],
                        first + [dict(retry, run_id=43)], first + [dict(retry, run_attempt=3)]):
            with self.assertRaises(ValueError):
                select(records)
        with self.assertRaises(ValueError):
            planner.executed_jobs(run, "owner/repo", lambda path: {"jobs": first, "total_count": 101})

    def test_rerun_cannot_refresh_stale_sibling_evidence(self):
        now = dt.datetime(2026, 9, 13, 6, tzinfo=dt.timezone.utc)
        jobs = [dict(name=name, head_sha="a" * 40, status="completed", conclusion="success",
                     completed_at="2026-09-13T05:00:00Z") for name in planner.FULL]
        self.assertTrue(planner.covers_jobs(jobs, planner.FULL, "a" * 40, now))
        for stale in ("2026-09-11T05:00:00Z", "2026-09-14T05:00:00Z", "invalid", None):
            changed = copy.deepcopy(jobs)
            changed[0]["completed_at"] = stale
            self.assertFalse(planner.covers_jobs(changed, planner.FULL, "a" * 40, now))


if __name__ == "__main__":
    unittest.main()
