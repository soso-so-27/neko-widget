#!/usr/bin/env python3
"""Behavioral coverage for selecting and reusing iOS checks (no network)."""

import copy
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import ios_ci_scope as scope


spec = importlib.util.spec_from_file_location("planner", Path(__file__).with_name("plan-ios-ci.py"))
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)


class PlanTests(unittest.TestCase):
    @staticmethod
    def memory_changes():
        classes = {}
        for identifier in scope.REVIEWED_MEMORY_TESTS:
            _, owner, method = identifier.split("/")
            classes.setdefault(owner, []).append(f"    func {method}() {{}}")
        source = "\n".join(f"final class {owner}: XCTestCase {{\n" + "\n".join(methods) + "\n}"
                           for owner, methods in classes.items())
        changes = {path: ("before", source if path == scope.MEMORY_TEST_PATH else "after")
                   for path in scope.REVIEWABLE_MEMORY_PATHS}
        review = {"schemaVersion": 1, "scope": scope.REVIEWED_MEMORY_SCOPE,
                  "purpose": "Reviewed personal memory reading experience", "visualReview": "user-device",
                  "dataReview": "read-only-projection",
                  "files": {path: {"before": scope.source_digest(pair[0]), "after": scope.source_digest(pair[1])}
                            for path, pair in changes.items()}}
        changes[scope.REVIEW_MANIFEST] = ("{}", json.dumps(review))
        return changes

    def test_memory_review_requires_exact_complete_batch_and_known_profile(self):
        changes = self.memory_changes()
        self.assertEqual(scope.select_scope(changes), scope.REVIEWED_MEMORY_SCOPE)
        for path in changes:
            with self.subTest(missing=path):
                altered = dict(changes)
                del altered[path]
                self.assertEqual(scope.select_scope(altered), scope.FULL_SCOPE)
        for path in scope.REVIEWABLE_MEMORY_PATHS:
            for index in (0, 1):
                with self.subTest(path=path, side=index):
                    pair = list(changes[path])
                    pair[index] += "unreviewed"
                    self.assertEqual(scope.select_scope(dict(changes, **{path: tuple(pair)})), scope.FULL_SCOPE)
        for extra in ("NekoWidget/NekoWidget/App/AppRootView.swift",
                      "NekoWidget/Shared/Storage/PhotoStore.swift",
                      "NekoWidget/NekoWidget/Services/PersonalArchiveCloudClient.swift",
                      "NekoWidget/NekoWidget/Services/PhotoMemoryNoteStore.swift",
                      "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                      "NekoWidget/NekoWidget/Views/FamilyWindowView.swift", scope.CI_WORKFLOW,
                      "NekoWidget/ci/ios_ci_scope.py", "unknown.swift", "../MainTabView.swift"):
            with self.subTest(extra=extra):
                self.assertEqual(scope.select_scope(dict(changes, **{extra: ("before", "after")})), scope.FULL_SCOPE)
                self.assertEqual(planner.required_jobs(list(changes) + [extra], scope.REVIEWED_MEMORY_SCOPE), planner.FULL)
        self.assertEqual(scope.select_scope({path: changes[path] for path in scope.REVIEWABLE_MEMORY_PATHS}),
                         scope.FULL_SCOPE)
        self.assertEqual(scope.select_scope(dict(changes, **{"handoffs/review.md": ("", "review")})),
                         scope.REVIEWED_MEMORY_SCOPE)

    def test_memory_review_rejects_malformed_stale_and_duplicate_manifests(self):
        changes = self.memory_changes()
        review = json.loads(changes[scope.REVIEW_MANIFEST][1])
        malformed = ["[]", "null", "{", json.dumps(dict(review, scope="unknown-v1")),
                     json.dumps(dict(review, scope=scope.REVIEWED_APP_SCOPE)),
                     json.dumps(dict(review, scope="reviewed-memory-read-ui-v1")),
                     json.dumps(dict(review, schemaVersion=2)), json.dumps(dict(review, schemaVersion=True)),
                     json.dumps(dict(review, purpose=" ")), json.dumps(dict(review, visualReview="none")),
                     json.dumps(dict(review, dataReview="unchecked")),
                     json.dumps({k: v for k, v in review.items() if k != "dataReview"}),
                     json.dumps(dict(review, files={})), json.dumps(dict(review, tests=[])),
                     changes[scope.REVIEW_MANIFEST][1][:-1] + ', "purpose": "duplicate"}']
        path = next(iter(scope.REVIEWABLE_MEMORY_PATHS))
        stale = copy.deepcopy(review)
        stale["files"][path]["after"] = "f" * 64
        malformed.append(json.dumps(stale))
        for manifest in malformed:
            with self.subTest(manifest=manifest):
                self.assertEqual(scope.select_scope(dict(changes, **{scope.REVIEW_MANIFEST: ("{}", manifest)})),
                                 scope.FULL_SCOPE)

    def test_memory_review_requires_all_selected_test_methods_in_head(self):
        changes = self.memory_changes()
        for test in scope.REVIEWED_MEMORY_TESTS:
            for duplicate in (False, True):
                altered = copy.deepcopy(changes)
                path = scope.MEMORY_TEST_PATH
                before, after = altered[path]
                method = test.rsplit("/", 1)[1]
                declaration = f"    func {method}() {{}}"
                after = after.replace(declaration, declaration * 2 if duplicate else "")
                altered[path] = (before, after)
                review = json.loads(altered[scope.REVIEW_MANIFEST][1])
                review["files"][path]["after"] = scope.source_digest(after)
                altered[scope.REVIEW_MANIFEST] = ("{}", json.dumps(review))
                with self.subTest(test=test, duplicate=duplicate):
                    self.assertEqual(scope.select_scope(altered), scope.FULL_SCOPE)

    def test_memory_single_file_review_reads_fixed_test_dependency_from_head(self):
        full = self.memory_changes()
        source = full[scope.MEMORY_TEST_PATH][1]
        for path in scope.REVIEWABLE_MEMORY_PATHS - scope.MEMORY_PROJECTION_PATHS:
            review = json.loads(full[scope.REVIEW_MANIFEST][1])
            review["files"] = {path: review["files"][path]}
            changes = {path: full[path], scope.REVIEW_MANIFEST: ("{}", json.dumps(review))}
            self.assertEqual(scope.select_scope(changes, memory_test_source=source),
                             scope.REVIEWED_MEMORY_SCOPE)
            if path == scope.MEMORY_TEST_PATH:
                continue
            self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
            paths = sorted(changes)
            base = "b" * 40
            raw = "".join(f":100644 100644 {'c' * 40} {'d' * 40} M\0{item}\0" for item in paths)
            for dependency in (source, source.replace("testMemoryLibraryEntryReadsEditsAndOpensTheOriginalPhoto", "absent"), None):
                def git(*args):
                    if args[0] == "diff":
                        return raw
                    if args[0] == "show":
                        revision, item = args[1].split(":", 1)
                        if item == scope.MEMORY_TEST_PATH:
                            self.assertEqual(revision, self.sha)
                            if dependency is None:
                                raise subprocess.CalledProcessError(1, ["git", *args])
                            return dependency
                        return changes[item][0 if revision == base else 1]
                    return self.sha
                with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                    self.assertEqual(planner.runtime_scope(paths, {}, self.env),
                                     scope.REVIEWED_MEMORY_SCOPE if dependency == source else scope.FULL_SCOPE)

    def test_memory_projection_requires_the_exact_store_and_existing_verifier_together(self):
        full = self.memory_changes()
        source = full[scope.MEMORY_TEST_PATH][1]
        review = json.loads(full[scope.REVIEW_MANIFEST][1])
        for paths in (scope.MEMORY_PROJECTION_PATHS, *({p} for p in scope.MEMORY_PROJECTION_PATHS)):
            manifest = dict(review, files={p: review["files"][p] for p in paths})
            changes = {p: full[p] for p in paths}
            changes[scope.REVIEW_MANIFEST] = ("{}", json.dumps(manifest))
            self.assertEqual(scope.select_scope(changes, memory_test_source=source),
                             scope.REVIEWED_MEMORY_SCOPE if paths == scope.MEMORY_PROJECTION_PATHS else scope.FULL_SCOPE)
        # An unknown named profile with only a legacy-allowed UI path must not
        # silently downgrade to the older four-test profile.
        path = "NekoWidget/NekoWidget/Views/MainTabView.swift"
        for claimed in (scope.REVIEWED_MEMORY_SCOPE, "unknown-v1", scope.REVIEWED_APP_SCOPE):
            manifest = dict(review, scope=claimed, files={path: review["files"][path]})
            manifest.pop("dataReview")
            self.assertEqual(scope.select_scope({path: full[path], scope.REVIEW_MANIFEST: ("{}", json.dumps(manifest))},
                                               memory_test_source=source), scope.FULL_SCOPE)

    def test_memory_allowlist_and_current_test_declarations_are_explicit(self):
        self.assertEqual(scope.REVIEWABLE_MEMORY_PATHS, {
            "NekoWidget/NekoWidget/Views/PhotoMemoryNoteLibraryView.swift",
            "NekoWidget/NekoWidget/Views/PersonalArchiveView.swift",
            "NekoWidget/NekoWidget/Views/LikedPhotosView.swift",
            "NekoWidget/NekoWidget/Views/MainTabView.swift",
            "NekoWidget/NekoWidget/Views/HomeView.swift",
            "NekoWidget/NekoWidget/Views/SettingsView.swift",
            "NekoWidget/NekoWidget/App/AppStoreScreenshotFixture.swift",
            "NekoWidget/NekoWidgetUITests/AppStoreScreenshotUITests.swift",
            "NekoWidget/ci/test-family-window-widget-boundaries.py",
            "NekoWidget/ci/test-app-store-screenshot-workflow.py",
            "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift",
            "NekoWidget/NekoWidget/Services/PersonalArchiveStore.swift",
            "NekoWidget/ci/verify-personal-archive.swift",
        })
        root = Path(__file__).resolve().parents[2]
        source = (root / scope.MEMORY_TEST_PATH).read_text(encoding="utf-8")
        self.assertTrue(scope.memory_tests_available(source))

    def test_memory_test_names_in_comments_and_strings_do_not_count(self):
        changes = self.memory_changes()
        path = scope.MEMORY_TEST_PATH
        before, source = changes[path]
        declaration = "func testMemoryLibraryEntryReadsEditsAndOpensTheOriginalPhoto() {}"
        class_declaration = "final class MomentDeliveryComposerUITests: XCTestCase {"
        hidden = (
            source.replace(declaration, "// " + declaration),
            source.replace(declaration, "/* " + declaration + " */"),
            source.replace(declaration, "/* outer /* nested */ " + declaration + " */"),
            source.replace(declaration, 'let text = "' + declaration + '"'),
            source.replace(declaration, 'let text = "value \\(flag ? "' + declaration + '" : "b")"'),
            source.replace(declaration, 'let text = """\n' + declaration + '\n"""'),
            source.replace(declaration, 'let text = #"' + declaration + '"#'),
            source.replace(class_declaration, "// " + class_declaration),
            source.replace(class_declaration, "/* " + class_declaration + " */"),
            source.replace(class_declaration, 'let text = "' + class_declaration + '"'),
            'let text = """\n' + source + '\n"""',
            'let text = #"""\n' + source + '\n"""#',
            "#if false\n" + source + "\n#endif",
            source + "\n/* unterminated",
            source + '\nlet text = "unterminated',
        )
        for after in hidden:
            altered = copy.deepcopy(changes)
            altered[path] = (before, after)
            review = json.loads(altered[scope.REVIEW_MANIFEST][1])
            review["files"][path]["after"] = scope.source_digest(after)
            altered[scope.REVIEW_MANIFEST] = ("{}", json.dumps(review))
            with self.subTest(source=after):
                self.assertFalse(scope.memory_tests_available(after))
                self.assertEqual(scope.select_scope(altered), scope.FULL_SCOPE)
        # Decoys beside real declarations must not become duplicate methods.
        decoys = ('\n// ' + declaration + '\n/* ' + class_declaration + ' */\n'
                  + 'let text = "' + declaration + '"\n'
                  + 'let interpolation = "value \\(flag ? "' + declaration + '" : "b")"\n')
        self.assertTrue(scope.memory_tests_available(source + decoys))

    def test_memory_planner_rejects_added_deleted_renamed_and_nonregular_files(self):
        changes = self.memory_changes()
        paths = sorted(changes)
        base = "b" * 40
        def selected(headers):
            raw = "".join(f"{headers.get(path, ':100644 100644')} {'c' * 40} {'d' * 40} M\0{path}\0"
                          for path in paths)
            def git(*args):
                if args[0] == "diff":
                    return raw
                if args[0] == "show":
                    revision, path = args[1].split(":", 1)
                    return changes[path][0 if revision == base else 1]
                return self.sha
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(paths, {}, self.env)
        self.assertEqual(selected({}), scope.REVIEWED_MEMORY_SCOPE)
        for path in paths:
            for modes in (":000000 100644", ":100644 000000", ":100644 100755", ":100644 120000"):
                self.assertEqual(selected({path: modes}), scope.FULL_SCOPE)
        # Status is checked independently of modes, including copy/rename.
        for status in ("A", "D", "R100", "C100", "T"):
            raw = "".join(f":100644 100644 {'c' * 40} {'d' * 40} {status}\0{path}\0" for path in paths)
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", return_value=raw):
                self.assertEqual(planner.runtime_scope(paths, {}, self.env), scope.FULL_SCOPE)
        self.assertEqual(planner.runtime_scope(paths, {}, dict(self.env, GITHUB_EVENT_NAME="workflow_dispatch")),
                         scope.FULL_SCOPE)

    def test_memory_selection_keeps_safety_jobs_and_cannot_supply_full_evidence(self):
        selected = scope.REVIEWED_MEMORY_SCOPE
        changes = self.memory_changes()
        required = planner.required_jobs(list(changes), selected)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(selected))
        self.assertEqual(scope.smoke_tests(selected),
                         ("NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",))
        self.assertEqual(scope.lanes(selected), ("runtime", "app-ui"))
        self.assertEqual(scope.matrix_lanes(selected), ("runtime",))
        tests = scope.lane_tests(selected, "app-ui")
        self.assertEqual(len(tests), 8)
        self.assertEqual(len(set(tests)), 8)
        self.assertIn("NekoWidgetUITests/SoloMemoriesUITests/testPhotosOpenEachCatsPhotosDirectlyAndKeepManagementInSettings", tests)
        self.assertIn("NekoWidgetUITests/SoloMemoriesUITests/testEmptyAndSingleFavoriteRemainReachableIncludingDeniedAccess", tests)
        full = scope.native_tests(scope.FULL_SCOPE)
        for test in tests:
            self.assertTrue(any(test.startswith(suite + "/") for suite in full), test)
        for gallery in scope.LANES[2:]:
            with self.assertRaises(ValueError):
                scope.lane_tests(selected, gallery)
        jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success"}
                for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, self.sha))
        self.assertTrue(planner.covers_jobs(self.jobs, required, self.sha))
        old_jobs = [dict(job, name=job["name"].replace("reviewed-memory-read-ui-v2", "reviewed-memory-read-ui-v1"))
                    for job in jobs]
        self.assertFalse(planner.covers_jobs(old_jobs, required, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, planner.FULL, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, planner.required_jobs_from_scope(scope.REVIEWED_APP_SCOPE), self.sha))
        self.assertFalse(planner.covers_jobs(jobs, required, "b" * 40))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, self.sha))
            self.assertFalse(planner.covers_jobs(jobs + [jobs[index]], required, self.sha))
            for conclusion in ("failure", "skipped", "cancelled"):
                altered = copy.deepcopy(jobs)
                altered[index]["conclusion"] = conclusion
                self.assertFalse(planner.covers_jobs(altered, required, self.sha))

    def archive_picker_batch(self):
        changes = {path: ("before " + path, "after " + path)
                   for path in scope.ARCHIVE_PICKER_PATHS}
        manifest = {"schemaVersion": 1, "scope": scope.ARCHIVE_PICKER_SCOPE,
                    "purpose": "Reviewed screen-owned picker and seeded real-picker regression",
                    "files": {path: {"before": scope.source_digest(pair[0]),
                                     "after": scope.source_digest(pair[1])}
                              for path, pair in changes.items()}}
        changes[scope.ARCHIVE_PICKER_MANIFEST] = ("{}", json.dumps(manifest))
        return changes

    def test_archive_picker_requires_exact_review_of_complete_batch(self):
        changes = self.archive_picker_batch()
        self.assertEqual(scope.select_scope(changes), scope.ARCHIVE_PICKER_SCOPE)
        for path in changes:
            self.assertEqual(scope.select_scope({p: v for p, v in changes.items() if p != path}),
                             scope.FULL_SCOPE)
        for path in scope.ARCHIVE_PICKER_PATHS:
            for pair in ((changes[path][0] + "stale", changes[path][1]),
                         (changes[path][0], changes[path][1] + "extra")):
                self.assertEqual(scope.select_scope(dict(changes, **{path: pair})), scope.FULL_SCOPE)
        for path in (scope.REVIEW_MANIFEST, "NekoWidget/ci/ios_ci_scope.py",
                     "NekoWidget/NekoWidget/Services/PersonalArchiveStore.swift",
                     "NekoWidget/NekoWidget/App/AppRootView.swift", "../unsafe.swift"):
            self.assertEqual(scope.select_scope(dict(changes, **{path: ("a", "b")})), scope.FULL_SCOPE)
        for malformed in ("[]", "null", "{", "{}", changes[scope.ARCHIVE_PICKER_MANIFEST][1]
                          .replace(scope.ARCHIVE_PICKER_SCOPE, scope.REVIEWED_APP_SCOPE)):
            self.assertEqual(scope.select_scope(dict(changes, **{
                scope.ARCHIVE_PICKER_MANIFEST: ("{}", malformed)})), scope.FULL_SCOPE)

    def test_archive_picker_keeps_build_photo_scan_and_two_os_runtime(self):
        selected = scope.ARCHIVE_PICKER_SCOPE
        required = (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(selected)
        self.assertEqual(planner.required_jobs(list(self.archive_picker_batch()), selected), required)
        self.assertEqual(scope.lanes(selected), ("runtime", "app-ui"))
        self.assertEqual(scope.lane_tests(selected, "app-ui"), (
            "NekoWidgetUITests/SoloMemoriesUITests/testPersonalArchiveRestoresPhotoAndTextAndExplicitlySavesNewText",))
        self.assertEqual(scope.smoke_tests(selected),
            ("NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",))
        # Existing metadata test iterates every scope and requires both runtime OSes.
        jobs = [dict(name=name, head_sha=self.sha, status="completed", conclusion="success")
                for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, planner.FULL, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, planner.required_jobs_from_scope(scope.REVIEWED_APP_SCOPE), self.sha))
        self.assertFalse(planner.covers_jobs(jobs, required, "b" * 40))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, self.sha))
            for conclusion in ("skipped", "failure", "cancelled"):
                altered = copy.deepcopy(jobs)
                altered[index]["conclusion"] = conclusion
                self.assertFalse(planner.covers_jobs(altered, required, self.sha))
        self.assertFalse(planner.covers_jobs(jobs + [jobs[-1]], required, self.sha))

    def test_archive_picker_raw_modes_and_manual_dispatch_fail_closed(self):
        changes = self.archive_picker_batch()
        paths = sorted(changes)
        base = "b" * 40
        def select(header=":100644 100644", status="M", event_name="push"):
            def git(*args):
                if args[0] == "diff":
                    return "".join(f"{header if i == 0 else ':100644 100644'} {base} {self.sha} "
                                   f"{status if i == 0 else 'M'}\0{p}\0" for i, p in enumerate(paths))
                if args[0] == "show":
                    revision, path = args[1].split(":", 1)
                    return changes[path][0 if revision == base else 1]
                return self.sha
            env = dict(self.env, GITHUB_EVENT_NAME=event_name)
            with patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(paths, {"before": base}, env)
        self.assertEqual(select(), scope.ARCHIVE_PICKER_SCOPE)
        for header, status in ((":000000 100644", "A"), (":100644 000000", "D"),
                               (":100644 100755", "M"), (":100644 120000", "T")):
            self.assertEqual(select(header, status), scope.FULL_SCOPE)
        self.assertEqual(select(event_name="workflow_dispatch"), scope.FULL_SCOPE)

    def test_empty_archive_manifest_allows_ci_candidate_but_not_product_exemption(self):
        manifest = json.dumps({"schemaVersion": 1, "scope": scope.ARCHIVE_PICKER_SCOPE,
                               "purpose": "Inactive CI candidate", "files": {}})
        self.assertEqual(scope.select_scope({scope.ARCHIVE_PICKER_MANIFEST: ("", manifest),
            "NekoWidget/ci/ios_ci_scope.py": ("old selection", "new selection")}), scope.CI_SELECTION_SCOPE)
        self.assertEqual(scope.select_scope(dict(self.archive_picker_batch(), **{
            scope.ARCHIVE_PICKER_MANIFEST: ("{}", manifest)})), scope.FULL_SCOPE)

    def test_reviewed_app_batch_requires_exact_contents_and_entire_change_set(self):
        path = "NekoWidget/NekoWidget/Views/MainTabView.swift"
        pair = ("old app body\n", "new app body\n")
        manifest = json.dumps({"schemaVersion": 1, "purpose": "User reviews visual layout on device",
            "visualReview": "user-device", "files": {
                path: {"before": scope.source_digest(pair[0]), "after": scope.source_digest(pair[1])}}})
        changes = {path: pair, scope.REVIEW_MANIFEST: ("{}", manifest)}
        self.assertEqual(scope.select_scope(changes), scope.REVIEWED_APP_SCOPE)
        for altered in (
            {path: pair},
            dict(changes, **{path: (pair[0] + "unreviewed", pair[1])}),
            dict(changes, **{path: (pair[0], pair[1] + "unreviewed")}),
            dict(changes, **{"NekoWidget/Shared/Storage/AtomicJSON.swift": ("a", "b")}),
            dict(changes, **{"NekoWidget/NekoWidget/Views/HomeView.swift": ("a", "b")}),
            dict(changes, **{"NekoWidget/ci/ios_ci_scope.py": ("a", "b")}),
            dict(changes, **{scope.REVIEW_MANIFEST: ("{}", "[]")}),
            dict(changes, **{scope.REVIEW_MANIFEST: ("{}", manifest.replace("user-device", "none"))}),
        ):
            self.assertEqual(scope.select_scope(altered), scope.FULL_SCOPE)
        self.assertEqual(planner.required_jobs(list(changes), scope.REVIEWED_APP_SCOPE),
            (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(scope.REVIEWED_APP_SCOPE))
        self.assertEqual(scope.lanes(scope.REVIEWED_APP_SCOPE), ("runtime", "app-ui"))
        self.assertEqual(len(scope.native_tests(scope.REVIEWED_APP_SCOPE)), 4)

    def test_reviewed_evidence_does_not_cover_full_or_missing_checks(self):
        jobs = [{"name": name, "head_sha": "a" * 40, "status": "completed", "conclusion": "success"}
                for name in planner.required_jobs_from_scope(scope.REVIEWED_APP_SCOPE)]
        self.assertTrue(planner.covers_jobs(jobs, tuple(j["name"] for j in jobs), "a" * 40))
        self.assertFalse(planner.covers_jobs(jobs, planner.FULL, "a" * 40))
        self.assertFalse(planner.covers_jobs(jobs[:-1], tuple(j["name"] for j in jobs), "a" * 40))

    @staticmethod
    def cat_entry_changes(companion=None):
        before = ('func configure() {\n'
                  '        bar.placeholder = "言葉・猫の名前で探す"\n'
                  '        bar.delegate = context.coordinator\n}\n')
        changes = {
            scope.CAT_ENTRY_PATH: ("old cat list", "new cat list"),
            scope.CAT_ENTRY_SEARCH_COMPANION: companion or (
                before, before.replace('"言葉・猫の名前で探す"', '"メモを検索"')),
        }
        review = {"schemaVersion": 1, "purpose": "Cat list and exact search placeholder",
                  "visualReview": "user-device",
                  "files": {path: {"before": scope.source_digest(pair[0]), "after": scope.source_digest(pair[1])}
                            for path, pair in changes.items()}}
        changes[scope.REVIEW_MANIFEST] = ("{}", json.dumps(review))
        return changes

    def test_cat_entry_exact_placeholder_keeps_existing_four_operations_and_safety_jobs(self):
        changes = self.cat_entry_changes()
        self.assertEqual(scope.select_scope(changes), scope.REVIEWED_APP_SCOPE)
        self.assertNotIn(scope.CAT_ENTRY_SEARCH_COMPANION, scope.REVIEWABLE_APP_PATHS)
        self.assertNotIn(scope.CAT_ENTRY_SEARCH_COMPANION, scope.PHOTO_VIEWS)
        self.assertEqual(planner.required_jobs(list(changes), scope.REVIEWED_APP_SCOPE),
                         (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(scope.REVIEWED_APP_SCOPE))
        self.assertEqual(len(scope.native_tests(scope.REVIEWED_APP_SCOPE)), 4)
        self.assertEqual(scope.lanes(scope.REVIEWED_APP_SCOPE), ("runtime", "app-ui"))

    def test_cat_entry_companion_rejects_other_changes_even_with_matching_hashes(self):
        before, after = self.cat_entry_changes()[scope.CAT_ENTRY_SEARCH_COMPANION]
        for pair in (
            (before, after.replace('"メモを検索"', '"別の検索"')),
            (before, after.replace("bar.delegate = context.coordinator", "bar.delegate = nil")),
            (before, after + "// another changed line\n"),
            (before + before, after + after),
            (before.replace('        bar.placeholder = "言葉・猫の名前で探す"\n',
                            '        bar.placeholder = "言葉・猫の名前で探す"\n' * 2),
             after.replace('        bar.placeholder = "メモを検索"\n',
                           '        bar.placeholder = "メモを検索"\n'
                           '        bar.placeholder = "言葉・猫の名前で探す"\n')),
            (after, before),
            (before, before),
        ):
            with self.subTest(pair=pair):
                self.assertEqual(scope.select_scope(self.cat_entry_changes(pair)), scope.FULL_SCOPE)
        changes = self.cat_entry_changes()
        for missing in (scope.CAT_ENTRY_PATH, scope.REVIEW_MANIFEST):
            altered = dict(changes)
            del altered[missing]
            if missing != scope.REVIEW_MANIFEST:
                review = json.loads(altered[scope.REVIEW_MANIFEST][1])
                del review["files"][missing]
                altered[scope.REVIEW_MANIFEST] = ("{}", json.dumps(review))
            self.assertEqual(scope.select_scope(altered), scope.FULL_SCOPE)
        self.assertFalse(scope.accepts_paths(scope.REVIEWED_APP_SCOPE,
                                            {scope.CAT_ENTRY_SEARCH_COMPANION, scope.REVIEW_MANIFEST}))
        for side in (0, 1):
            altered = dict(changes)
            pair = list(altered[scope.CAT_ENTRY_SEARCH_COMPANION])
            pair[side] += "unreviewed"
            altered[scope.CAT_ENTRY_SEARCH_COMPANION] = tuple(pair)
            self.assertEqual(scope.select_scope(altered), scope.FULL_SCOPE)
        for side in ("before", "after"):
            review = json.loads(changes[scope.REVIEW_MANIFEST][1])
            review["files"][scope.CAT_ENTRY_SEARCH_COMPANION][side] = "f" * 64
            altered = dict(changes, **{scope.REVIEW_MANIFEST: ("{}", json.dumps(review))})
            self.assertEqual(scope.select_scope(altered), scope.FULL_SCOPE)

    def test_cat_entry_companion_still_requires_existing_regular_files(self):
        changes = self.cat_entry_changes()
        paths = sorted(changes)
        base = "b" * 40
        def selected(header=":100644 100644", status="M"):
            raw = "".join(
                f"{header if path == scope.CAT_ENTRY_SEARCH_COMPANION else ':100644 100644'} "
                f"{'c' * 40} {'d' * 40} {status if path == scope.CAT_ENTRY_SEARCH_COMPANION else 'M'}\0{path}\0"
                for path in paths)
            def git(*args):
                if args[0] == "diff":
                    return raw
                if args[0] == "show":
                    revision, path = args[1].split(":", 1)
                    return changes[path][0 if revision == base else 1]
                return self.sha
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(paths, {}, self.env)
        self.assertEqual(selected(), scope.REVIEWED_APP_SCOPE)
        for header, status in ((":000000 100644", "A"), (":100644 000000", "D"),
                               (":100644 100755", "M"), (":100644 120000", "T"),
                               (":100644 100644", "R100")):
            with self.subTest(header=header, status=status):
                self.assertEqual(selected(header, status), scope.FULL_SCOPE)

    def setUp(self):
        self.sha = "a" * 40
        self.now = dt.datetime(2026, 9, 7, 12, tzinfo=dt.timezone.utc)
        self.env = {
            "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/main",
            "GITHUB_SHA": self.sha, "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "20",
        }
        self.current = {"id": 20, "workflow_id": 5, "head_sha": self.sha}
        self.run = dict(self.current, id=10, event="push", head_branch="codex/movie",
                        status="completed", conclusion="success", updated_at="2026-09-07T11:00:00Z",
                        repository={"full_name": "owner/repo"}, head_repository={"full_name": "owner/repo"})
        self.jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success",
                      "completed_at": "2026-09-07T11:00:00Z"}
                     for name in planner.FULL]
        checkout = patch.object(planner, "git", return_value=self.sha)
        checkout.start()
        self.addCleanup(checkout.stop)

    def test_movie_screen_keeps_build_and_boundary_tests(self):
        for paths in ([planner.MOVIE_VIEW], [planner.MOVIE_ADR, planner.MOVIE_VIEW]):
            self.assertEqual(planner.required_jobs(paths), (planner.BUILD,))

    def test_unknown_mixed_deleted_or_policy_paths_keep_full_checks(self):
        for extra in (
            "NekoWidget/NekoWidget/Services/SeasonalMovieExportService.swift",
            "NekoWidget/NekoWidget/Views/OnboardingView.swift",
            "NekoWidget/Shared/Storage/AtomicJSON.swift",
            ".github/workflows/ios-build.yml", "NekoWidget/Config.xcconfig",
            "NekoWidget/NekoWidget/Info.plist", "NekoWidget/ci/plan-ios-ci.py",
            "AGENTS.md", "unknown.swift",
        ):
            with self.subTest(extra=extra):
                self.assertEqual(planner.required_jobs([planner.MOVIE_VIEW, extra]), planner.FULL)
        for paths in (None, [], [planner.MOVIE_ADR]):
            self.assertEqual(planner.required_jobs(paths), planner.FULL)

    def test_run_identity_event_freshness_and_completion_are_required(self):
        self.assertTrue(planner.reusable_run(self.run, self.current, "owner/repo", self.now))
        for field, value in (
            ("id", 20), ("workflow_id", 9), ("head_sha", "b" * 40),
            ("event", "pull_request"), ("head_branch", "main"),
            ("head_repository", {"full_name": "outsider/fork"}),
            ("repository", {"full_name": "outsider/fork"}),
            ("status", "in_progress"), ("conclusion", "cancelled"),
            ("conclusion", "failure"), ("updated_at", "2026-09-05T11:00:00Z"),
            ("updated_at", "2026-09-08T11:00:00Z"), ("updated_at", "invalid"),
            ("updated_at", None), ("head_branch", None),
            ("head_sha", "invalid"), ("head_sha", None),
        ):
            with self.subTest(field=field, value=value):
                self.assertFalse(planner.reusable_run(dict(self.run, **{field: value}), self.current, "owner/repo", self.now))
        self.assertFalse(planner.reusable_run({}, self.current, "owner/repo", self.now))

    def test_required_jobs_must_have_actually_executed(self):
        self.assertTrue(planner.covers_jobs(self.jobs, planner.FULL, self.sha))
        for conclusion in ("skipped", "failure", "cancelled", None):
            jobs = copy.deepcopy(self.jobs)
            jobs[0]["conclusion"] = conclusion
            self.assertFalse(planner.covers_jobs(jobs, planner.FULL, self.sha))
        self.assertFalse(planner.covers_jobs(self.jobs[1:], planner.FULL, self.sha))
        self.assertFalse(planner.covers_jobs(self.jobs + self.jobs, planner.FULL, self.sha))
        self.assertFalse(planner.covers_jobs(self.jobs, planner.FULL, "b" * 40))
        self.assertFalse(planner.covers_jobs(self.jobs[:1], planner.FULL, self.sha))
        self.assertTrue(planner.covers_jobs(self.jobs[:1], (planner.BUILD,), self.sha))

    def api(self, path):
        if path.endswith("/runs/20"):
            return self.current
        if "/workflows/ios-build.yml/runs?" in path:
            return {"workflow_runs": [self.run]}
        if "/runs/10/jobs?filter=latest" in path:
            return {"total_count": len(self.jobs), "jobs": self.jobs}
        self.fail(f"Unexpected API endpoint: {path}")

    def test_main_uses_exact_commit_evidence(self):
        self.assertEqual(planner.find_evidence(self.env, planner.FULL, self.api, self.now), (10, self.sha))
        # A prior narrow check cannot stand in for newly required full coverage.
        self.jobs = self.jobs[:1]
        self.assertIsNone(planner.find_evidence(self.env, planner.FULL, self.api, self.now))

    def test_ancestor_evidence_still_requires_candidate_job_sha_and_provenance(self):
        candidate = "b" * 40
        self.run["head_sha"] = candidate
        with patch.object(planner, "equivalent_inputs", return_value=True):
            # Jobs for the current SHA cannot impersonate execution on candidate.
            self.assertIsNone(planner.find_evidence(self.env, planner.FULL, self.api, self.now))
            for job in self.jobs:
                job["head_sha"] = candidate
            self.assertEqual(planner.find_evidence(self.env, planner.FULL, self.api, self.now), (10, candidate))
            for field, value in (("workflow_id", 9), ("event", "pull_request"),
                                 ("head_branch", "main"), ("conclusion", "failure"),
                                 ("head_repository", {"full_name": "outsider/fork"}),
                                 ("updated_at", "2026-09-05T11:00:00Z")):
                with self.subTest(field=field):
                    run = dict(self.run, **{field: value})
                    self.assertFalse(planner.reusable_run(run, self.current, "owner/repo", self.now))

    def test_checkout_mismatch_prevents_even_exact_sha_reuse(self):
        with patch.object(planner, "git", return_value="b" * 40):
            self.assertIsNone(planner.find_evidence(self.env, planner.FULL, self.api, self.now))

    def test_manual_candidate_and_pr_never_reuse(self):
        for event, ref in (("workflow_dispatch", "refs/heads/main"),
                           ("push", "refs/heads/codex/movie"), ("pull_request", "refs/pull/1/merge")):
            env = dict(self.env, GITHUB_EVENT_NAME=event, GITHUB_REF=ref)
            self.assertIsNone(planner.find_evidence(env, planner.FULL, lambda _: self.fail("Unexpected API call"), self.now))

    def test_incomplete_job_response_does_not_allow_reuse(self):
        def api(path):
            result = self.api(path)
            if "jobs" in result:
                result["total_count"] = 101
            return result
        self.assertIsNone(planner.find_evidence(self.env, planner.FULL, api, self.now))

    def test_api_or_diff_failure_falls_back_to_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "event.json").write_text("{}")
            env = dict(self.env, GITHUB_EVENT_PATH=str(root / "event.json"),
                       GITHUB_OUTPUT=str(root / "output"), GITHUB_STEP_SUMMARY=str(root / "summary"))
            for error in (OSError, AttributeError, TypeError, ValueError,
                          subprocess.CalledProcessError(1, "git")):
                with self.subTest(error=error), patch.dict(os.environ, env), \
                        patch.object(planner, "changed_paths", side_effect=ValueError), \
                        patch.object(planner, "find_evidence", side_effect=error):
                    (root / "output").write_text("")
                    planner.main()
                    outputs = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                    self.assertEqual(outputs, {"build": "true", "build_name": planner.BUILD, "smoke": "true", "sharing": "true",
                        "smoke_name": planner.SMOKE, "app_ui": "true", "matrix_parallelism": "2",
                        "runtime_scope": scope.FULL_SCOPE,
                        "lanes": json.dumps(scope.LANES, separators=(",", ":")),
                        "matrix_lanes": '["runtime","gallery-normal","gallery-white","gallery-no-caption"]'})

    def test_mapped_photo_and_official_ui_keep_build_smoke_and_core_runtime(self):
        change = ('Text("before")\n', 'Text("after")\n')
        for path in scope.PHOTO_VIEWS:
            self.assertEqual(scope.select_scope({path: change}), scope.PHOTO_SCOPE)
        self.assertEqual(scope.select_scope({scope.OFFICIAL_VIEW: change}), scope.OFFICIAL_SCOPE)
        home = "NekoWidget/NekoWidget/Views/HomeView.swift"
        selected = scope.select_scope({home: change, scope.OFFICIAL_VIEW: change})
        self.assertEqual(selected, scope.COMBINED_SCOPE)
        self.assertEqual(planner.required_jobs([home], scope.PHOTO_SCOPE),
                         (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(scope.PHOTO_SCOPE))
        self.assertEqual(set(scope.native_tests(selected)), set(scope.PHOTO_TESTS + scope.OFFICIAL_TESTS))
        self.assertEqual(set(scope.native_tests(scope.FULL_SCOPE)),
                         set(scope.PHOTO_TESTS + scope.OFFICIAL_TESTS + ("NekoWidgetUITests/PersonalRediscoveryUITests", scope.GALLERY_TEST)))
        for selected in (scope.PHOTO_SCOPE, scope.OFFICIAL_SCOPE, scope.COMBINED_SCOPE):
            self.assertNotIn(scope.GALLERY_TEST, scope.native_tests(selected))

    def test_unknown_sensitive_and_inline_fixture_changes_force_full(self):
        home = "NekoWidget/NekoWidget/Views/HomeView.swift"
        change = ('Text("before")\n', 'Text("after")\n')
        for extra in (
            "NekoWidget/NekoWidget/Views/FamilyWindowView.swift",
            "NekoWidget/NekoWidget/Views/PairingView.swift",
            "NekoWidget/NekoWidget/Views/MainTabView.swift",
            "NekoWidget/NekoWidget/Views/SettingsView.swift",
            "NekoWidget/Shared/Models/WidgetManifest.swift",
            "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
            "NekoWidget/NekoWidget/Info.plist", "NekoWidget/NekoWidget/NekoWidget.entitlements",
            "NekoWidget/NekoWidget/App/AppStoreScreenshotFixture.swift",
            "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift",
            "NekoWidget/ci/ios_ci_scope.py", "NekoWidget/ci/run-sharing-runtime-matrix.sh",
            ".github/workflows/ios-build.yml", "docs/scope.md", "unknown.swift",
        ):
            with self.subTest(extra=extra):
                self.assertEqual(scope.select_scope({home: change, extra: change}), scope.FULL_SCOPE)
                self.assertEqual(planner.required_jobs([home, extra], scope.PHOTO_SCOPE), planner.FULL)
        protected = '#if DEBUG\n#if targetEnvironment(simulator)\nText("fixture")\n#endif\n#else\nText("shipping")\n#endif\n'
        self.assertEqual(scope.select_scope({home: (protected + change[0], protected + change[1])}), scope.PHOTO_SCOPE)
        for after in (protected.replace('"fixture"', '"changed"'),
                      protected.replace('"shipping"', '"changed"'),
                      protected.replace("#if DEBUG", "#if NEW"), protected + "#if DEBUG\n",
                      protected + "#endif\n"):
            self.assertEqual(scope.select_scope({home: (protected, after)}), scope.FULL_SCOPE)
        for text in ('requestAuthorization()', 'hasPhotoPermission = true', 'consent = nil',
                     'privacyURL = changed', 'fixtureTitle = "x"', '"--new-launch-switch"'):
            self.assertEqual(scope.select_scope({home: (change[0], text)}), scope.FULL_SCOPE)

    def test_only_literal_copy_and_known_literal_style_lines_can_use_ui_scope(self):
        home = "NekoWidget/NekoWidget/Views/HomeView.swift"
        for before, after in (
            ('Text("Before")', 'Text("After")'),
            ('.font(.title3.bold())', '.font(.headline)'),
            ('.font(.system(size: 18, weight: .semibold))', '.font(.system(size: 17, weight: .regular))'),
            ('.padding(.horizontal, 12)', '.padding(.horizontal, 16)'),
            ('.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)',
             '.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)'),
            ('.foregroundStyle(.secondary)', '.foregroundStyle(Color.primary)'),
            ('.multilineTextAlignment(.center)', '.multilineTextAlignment(.leading)'),
            ('Text("Before").font(.body)', 'Text("After").font(.headline)'),
        ):
            with self.subTest(after=after):
                self.assertEqual(scope.select_scope({home: (before, after)}), scope.PHOTO_SCOPE)
        for before, after in (
            ('save(photo)', 'remove(photo)'),
            ('isSaved = true', 'isSaved = false'),
            ('if mayDisplay {', 'if true {'),
            ('HStack(spacing: 12) {', 'VStack(spacing: 12) {'),
            ('.font(existingFont)', '.font(.body)'),
            ('Text("Before")', 'Text("Value \\(helper())")'),
            ('Text("Before")', 'Text(changedValue)'),
            ('.padding(12)', '.padding(helper())'),
            ('.frame(height: 44)', '.frame(height: model.value)'),
            ('.foregroundStyle(.secondary)', '.foregroundStyle(computeColor())'),
            ('.font(.body)', '.font(.body); save()'),
            ('.disabled(true)', '.disabled(false)'),
            ('@State var value = 1', '@State var value = 2'),
            ('Text("Before")', '// Text("After")'),
            ('"""\nText("Before")\n"""', '"""\nText("After")\n"""'),
            ('Text(#"Before"#)', 'Text(#"After"#)'),
        ):
            with self.subTest(after=after):
                self.assertEqual(scope.select_scope({home: (before, after)}), scope.FULL_SCOPE)

    def test_reuse_requires_scope_version_and_exact_subset_or_full_execution(self):
        required = planner.required_jobs_from_scope(scope.PHOTO_SCOPE)
        # Full executed coverage can serve a narrower main diff.
        self.assertTrue(planner.covers_jobs(self.jobs, required, self.sha))
        photo_jobs = [{"name": name, "status": "completed", "conclusion": "success", "head_sha": self.sha,
                       "completed_at": "2026-09-07T11:00:00Z"}
                      for name in required]
        self.assertTrue(planner.covers_jobs(photo_jobs, required, self.sha))
        self.assertFalse(planner.covers_jobs(photo_jobs, planner.FULL, self.sha))
        for name in (scope.lane_job(scope.OFFICIAL_SCOPE, "app-ui"),
                     scope.SHARING_JOB_PREFIX, required[-1].replace("v1", "v0")):
            jobs = copy.deepcopy(photo_jobs)
            jobs[-1]["name"] = name
            self.assertFalse(planner.covers_jobs(jobs, required, self.sha))
        for conclusion in ("skipped", "failure", "cancelled"):
            jobs = copy.deepcopy(photo_jobs)
            jobs[-1]["conclusion"] = conclusion
            self.assertFalse(planner.covers_jobs(jobs, required, self.sha))
        self.assertFalse(planner.covers_jobs(photo_jobs + [self.jobs[3]], required, self.sha))
        self.jobs = photo_jobs
        self.assertEqual(planner.find_evidence(self.env, required, self.api, self.now), (10, self.sha))
        self.assertIsNone(planner.find_evidence(self.env, planner.FULL, self.api, self.now))

    def test_scope_metadata_and_arguments_are_generated_from_same_validated_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            metadata, tests = Path(directory) / "scope.json", Path(directory) / "tests.txt"
            for selected in scope.SCOPES:
                with patch("sys.argv", ["ios_ci_scope.py", "--scope", selected,
                                        "--metadata", str(metadata), "--tests", str(tests)]):
                    scope.main()
                result = json.loads(metadata.read_text())
                self.assertEqual(result["scope"], selected)
                self.assertEqual(result["sharingRuntime"], ["ios-18-5", "ios-26-2"])
                self.assertEqual(result["widgetGallery"], "gallery-normal" in scope.lanes(selected))
                self.assertEqual(tests.read_text().splitlines(),
                                 ["-only-testing:" + name for name in result["nativeTests"]])
        with self.assertRaises(ValueError):
            scope.native_tests("unknown")

    def test_selected_native_suites_still_exist_and_workflow_carries_scope_identity(self):
        project = Path(__file__).resolve().parents[1]
        sources = [path.read_text(encoding="utf-8") for path in (project / "NekoWidgetUITests").glob("*.swift")]
        for identifier in scope.native_tests(scope.FULL_SCOPE):
            parts = identifier.split("/")
            self.assertEqual(parts[0], "NekoWidgetUITests")
            found = [text for text in sources if re.search(r"class " + re.escape(parts[1]) + r"\s*:\s*XCTestCase", text)]
            self.assertEqual(len(found), 1, identifier)
            if len(parts) == 3:
                self.assertIn("func " + parts[2] + "(", found[0])
        workflow = (project.parent / ".github/workflows/ios-build.yml").read_text(encoding="utf-8")
        self.assertIn("name: " + scope.LANE_JOB_PREFIX + " [${{ matrix.lane }}; scope ${{ needs.plan.outputs.runtime_scope }}]", workflow)
        self.assertIn("runtime_scope: ${{ steps.scope.outputs.runtime_scope }}", workflow)
        self.assertIn("NEKO_IOS_RUNTIME_SCOPE: ${{ needs.plan.outputs.runtime_scope }}", workflow)

    def test_independent_jobs_start_after_plan_without_removing_release_evidence(self):
        project = Path(__file__).resolve().parents[1]
        workflow = (project.parent / ".github/workflows/ios-build.yml").read_text(encoding="utf-8")
        for identifier, output in (("build-without-signing", "build"),
                                   ("simulator-smoke-test", "smoke"),
                                   ("sharing-app-ui", "app_ui"),
                                   ("sharing-runtime-matrix", "sharing")):
            body = re.split(r"\n  (?=\S)", workflow.split("\n  " + identifier + ":", 1)[1], maxsplit=1)[0]
            self.assertIn("    needs: plan\n", body)
            self.assertIn("    if: needs.plan.outputs." + output + " == 'true'", body)
            self.assertNotIn("continue-on-error:", body)
        # Parallel runtime success cannot stand in for a failed/skipped Release.
        for result in ("failure", "skipped", "cancelled"):
            jobs = copy.deepcopy(self.jobs)
            jobs[0]["conclusion"] = result
            self.assertFalse(planner.covers_jobs(jobs, planner.FULL, self.sha))

    def test_real_git_ui_selection_rejects_moves_additions_deletions_and_mode_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home = "NekoWidget/NekoWidget/Views/HomeView.swift"
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args], text=True,
                                               encoding="utf-8", stderr=subprocess.PIPE).rstrip("\n")
            def commit(stage=True):
                if stage:
                    git("add", ".")
                git("-c", "user.name=CI", "-c", "user.email=ci@example.invalid", "commit", "--allow-empty", "-qm", "fixture")
                return git("rev-parse", "HEAD")
            git("init", "-q")
            git("config", "core.filemode", "false")
            target = root / home
            target.parent.mkdir(parents=True)
            target.write_text('Text("before")\n')
            base = commit()
            git("update-ref", "refs/remotes/origin/main", base)
            def selected():
                env = dict(self.env, GITHUB_REF="refs/heads/codex/ui", GITHUB_SHA=git("rev-parse", "HEAD"))
                paths = planner.changed_paths({}, env)
                return planner.runtime_scope(paths, {}, env)
            with patch.object(planner, "git", side_effect=git):
                target.write_text('Text("after")\n')
                commit()
                self.assertEqual(selected(), scope.PHOTO_SCOPE)
                handoff = root / "handoffs/change.md"
                handoff.parent.mkdir()
                handoff.write_text("The source change is described here.\n")
                commit()
                self.assertEqual(selected(), scope.PHOTO_SCOPE)
                git("update-index", "--chmod=+x", "handoffs/change.md")
                commit(stage=False)
                self.assertEqual(selected(), scope.FULL_SCOPE)
                env = dict(self.env, GITHUB_SHA=git("rev-parse", "HEAD"), GITHUB_EVENT_NAME="workflow_dispatch")
                self.assertEqual(planner.runtime_scope([home], {}, env), scope.FULL_SCOPE)
                git("checkout", "--detach", "-q", base)
                git("mv", home, scope.OFFICIAL_VIEW)
                commit()
                self.assertEqual(selected(), scope.FULL_SCOPE)
                git("checkout", "--detach", "-q", base)
                (target.parent / "MonthlyWindowView.swift").write_text('Text("new")\n')
                commit()
                self.assertEqual(selected(), scope.FULL_SCOPE)
                git("checkout", "--detach", "-q", base)
                git("rm", "-q", home)
                commit()
                self.assertEqual(selected(), scope.FULL_SCOPE)
                git("checkout", "--detach", "-q", base)
                git("update-index", "--chmod=+x", home)
                commit(stage=False)
                self.assertEqual(selected(), scope.FULL_SCOPE)
                git("checkout", "--detach", "-q", base)
                blob = git("rev-parse", base + ":" + home)
                git("update-index", "--cacheinfo", f"120000,{blob},{home}")
                commit(stage=False)
                self.assertEqual(selected(), scope.FULL_SCOPE)
        with patch.object(planner, "git", side_effect=OSError):
            self.assertEqual(planner.runtime_scope([home], {}, self.env), scope.FULL_SCOPE)

    def test_real_git_research_exception_is_narrow_and_ancestor_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args], text=True,
                                               encoding="utf-8", stderr=subprocess.PIPE).rstrip("\n")
            def write(path, text):
                target = root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(text, encoding="utf-8")
            def commit(stage=True):
                if stage:
                    git("add", ".")
                git("-c", "user.name=CI", "-c", "user.email=ci@example.invalid", "commit", "--allow-empty", "-qm", "fixture")
                return git("rev-parse", "HEAD")
            git("init", "-q")
            # The mode case below changes the index deliberately; do not let
            # host filesystem permissions create an unrelated dirty checkout.
            git("config", "core.filemode", "false")
            app = "NekoWidget/NekoWidget/App.swift"
            research = planner.INDEPENDENT_RESEARCH + "Sources/Probe.swift"
            workflow = ".github/workflows/ios-build.yml"
            for path in (app, research, workflow, "docs/release.md", "AGENTS.md"):
                write(path, "base")
            base = commit()
            with patch.object(planner, "git", side_effect=git):
                write(research, "research update")
                head = commit()
                self.assertTrue(planner.equivalent_inputs(base, head))
                # Exercise discovery and job validation with real git, not only
                # the helper. API must search beyond the current head_sha.
                self.env["GITHUB_SHA"] = self.current["head_sha"] = head
                self.run["head_sha"] = base
                for job in self.jobs:
                    job["head_sha"] = base
                def api(path):
                    if "/workflows/" in path:
                        self.assertNotIn("head_sha=", path)
                    return self.api(path)
                self.assertEqual(planner.find_evidence(self.env, planner.FULL, api, self.now), (10, base))
                self.assertFalse(planner.equivalent_inputs(head, base))  # Checkout mismatch.
                for candidate in ("invalid", "f" * 40, None):
                    self.assertFalse(planner.equivalent_inputs(candidate, head))
                for path in (app, workflow, "NekoWidget/ci/plan-ios-ci.py", "docs/release.md", "AGENTS.md",
                             "experiments/PetIdentityProbe-other/Probe.swift", "unknown.txt"):
                    with self.subTest(path=path):
                        git("checkout", "--detach", "-q", base)
                        write(path, "changed")
                        self.assertFalse(planner.equivalent_inputs(base, commit()))
                git("checkout", "--detach", "-q", base)
                git("rm", "-q", app)
                self.assertFalse(planner.equivalent_inputs(base, commit()))
                git("checkout", "--detach", "-q", base)
                git("mv", app, planner.INDEPENDENT_RESEARCH + "Moved.swift")
                self.assertFalse(planner.equivalent_inputs(base, commit()))
                git("checkout", "--detach", "-q", base)
                git("mv", research, "NekoWidget/Moved.swift")
                self.assertFalse(planner.equivalent_inputs(base, commit()))
                git("checkout", "--detach", "-q", base)
                git("update-index", "--chmod=+x", app)
                self.assertFalse(planner.equivalent_inputs(base, commit(stage=False)))
                git("checkout", "--detach", "-q", base)
                git("rm", "-qr", planner.INDEPENDENT_RESEARCH)
                write(planner.INDEPENDENT_RESEARCH.rstrip("/"), "replaced by file")
                self.assertFalse(planner.equivalent_inputs(base, commit()))
                # Identical files on divergent branches are not ancestry proof.
                git("checkout", "--detach", "-q", base)
                write(research, "research update")
                git("add", ".")
                git("-c", "user.name=CI", "-c", "user.email=ci@example.invalid", "commit", "-qm", "divergent")
                divergent = git("rev-parse", "HEAD")
                self.assertEqual(git("rev-parse", head + "^{tree}"), git("rev-parse", divergent + "^{tree}"))
                self.assertFalse(planner.equivalent_inputs(head, divergent))

    def test_git_failure_cannot_claim_equivalent_inputs(self):
        for error in (OSError, subprocess.CalledProcessError(1, "git"), UnicodeError):
            with patch.object(planner, "git", side_effect=error):
                self.assertFalse(planner.equivalent_inputs("b" * 40, self.sha))

    def test_branch_diff_includes_earlier_commits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args], text=True).strip()
            def commit():
                git("add", ".")
                git("-c", "user.name=CI", "-c", "user.email=ci@example.invalid", "commit", "-qm", "fixture")
                return git("rev-parse", "HEAD")
            git("init", "-q")
            (root / "baseline.txt").write_text("base")
            base = commit()
            git("update-ref", "refs/remotes/origin/main", base)
            (root / "storage.swift").write_text("earlier change")
            commit()
            movie = root / planner.MOVIE_VIEW
            movie.parent.mkdir(parents=True)
            movie.write_text("latest change")
            head = commit()
            env = dict(self.env, GITHUB_SHA=head, GITHUB_REF="refs/heads/codex/movie")
            with patch.object(planner, "git", side_effect=git):
                paths = planner.changed_paths({}, env)
                self.assertIn("storage.swift", paths)
                self.assertIn(planner.MOVIE_VIEW, paths)
                self.assertEqual(planner.required_jobs(paths), planner.FULL)
                self.assertIsNone(planner.changed_paths({}, dict(env, GITHUB_EVENT_NAME="workflow_dispatch")))


if __name__ == "__main__":
    unittest.main()
