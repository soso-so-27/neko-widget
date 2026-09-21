#!/usr/bin/env python3
"""Behavioral coverage for selecting and reusing iOS checks (no network)."""

import copy
import datetime as dt
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
import urllib.error
from unittest.mock import patch

import ios_ci_scope as scope


spec = importlib.util.spec_from_file_location("planner", Path(__file__).with_name("plan-ios-ci.py"))
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)


class PlanTests(unittest.TestCase):
    @staticmethod
    def evidence_maintenance_changes():
        changes = {path: ("before " + path, "after " + path) for path in scope.CI_EVIDENCE_PATHS}
        selector = "NekoWidget/ci/ios_ci_scope.py"
        empty = "CI_EVIDENCE_DIGESTS = {}\n"
        changes[selector] = (changes[selector][0], empty + "# reviewed selector\n")
        digests = {path: list(map(scope.source_digest, pair)) for path, pair in changes.items()}
        binding = "CI_EVIDENCE_DIGESTS = " + json.dumps(digests, indent=4, sort_keys=True) + "\n"
        changes[selector] = (changes[selector][0], changes[selector][1].replace(empty, binding))
        return changes, digests

    def test_evidence_maintenance_is_complete_frozen_and_not_release_evidence(self):
        changes, digests = self.evidence_maintenance_changes()
        with patch.object(scope, "CI_EVIDENCE_DIGESTS", digests):
            self.assertEqual(scope.select_scope(changes), scope.CI_EVIDENCE_SCOPE)
            for path in changes:
                missing = dict(changes); del missing[path]
                self.assertEqual(scope.select_scope(missing), scope.FULL_SCOPE)
                for side in (0, 1):
                    pair = list(changes[path]); pair[side] += " unreviewed"
                    self.assertEqual(scope.select_scope(dict(changes, **{path: tuple(pair)})), scope.FULL_SCOPE)
            for path in (scope.CI_WORKFLOW, scope.CI_DIAGNOSTIC_WORKFLOW, scope.CI_DIAGNOSTIC_MATRIX,
                         "NekoWidget/NekoWidget/Views/MainTabView.swift", "NekoWidget/ci/preflight-ci.py",
                         "NekoWidget/Config.xcconfig", "unknown.swift"):
                self.assertEqual(scope.select_scope(dict(changes, **{path: ("old", "new")})), scope.FULL_SCOPE)
        self.assertEqual(planner.required_jobs(sorted(changes), scope.CI_EVIDENCE_SCOPE), (planner.PLAN_JOB,))
        self.assertEqual(planner.required_jobs(sorted(changes) + [scope.CI_WORKFLOW], scope.CI_EVIDENCE_SCOPE), planner.FULL)
        self.assertNotIn(scope.CI_EVIDENCE_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError):
            planner.required_jobs_from_scope(scope.CI_EVIDENCE_SCOPE)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / "event.json").write_text("{}")
            env = dict(self.env, GITHUB_EVENT_PATH=str(root / "event.json"),
                       GITHUB_OUTPUT=str(root / "output"), GITHUB_STEP_SUMMARY=str(root / "summary"))
            with patch.dict(os.environ, env), patch.object(planner, "changed_paths", return_value=sorted(changes)), \
                    patch.object(planner, "runtime_scope", return_value=scope.CI_EVIDENCE_SCOPE), \
                    patch.object(planner, "find_evidence") as lookup:
                planner.main()
            lookup.assert_not_called()
            output = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
            self.assertTrue(all(output[name] == "false" for name in ("build", "smoke", "sharing", "app_ui")))
            self.assertEqual(output["matrix_lanes"], "[]")

    def test_evidence_maintenance_requires_raw_modifications_and_main_ancestry(self):
        changes, digests = self.evidence_maintenance_changes()
        base, paths = "b" * 40, sorted(changes)
        def selected(path=None, mode=":100644 100644", status="M", ancestor=True):
            def git(*args):
                if args[0] == "merge-base" and not ancestor:
                    raise subprocess.CalledProcessError(1, "git")
                if args[0] == "diff":
                    return "".join(f"{mode if item == path else ':100644 100644'} {'c' * 40} {'d' * 40} "
                                   f"{status if item == path else 'M'}\0{item}\0" for item in paths)
                if args[0] == "show":
                    revision, item = args[1].split(":", 1)
                    return changes[item][0 if revision == base else 1]
                return self.sha
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(paths, {}, self.env)
        with patch.object(scope, "CI_EVIDENCE_DIGESTS", digests):
            self.assertEqual(selected(), scope.CI_EVIDENCE_SCOPE)
            self.assertEqual(selected(ancestor=False), scope.FULL_SCOPE)
            for path in paths:
                for mode, status in ((":000000 100644", "A"), (":100644 000000", "D"),
                                     (":100644 100755", "M"), (":100644 120000", "T"),
                                     (":100644 100644", "R100"), (":100644 100644", "C100")):
                    self.assertEqual(selected(path, mode, status), scope.FULL_SCOPE)

    @staticmethod
    def membership_access_changes(*, enforced=False, extra_step=False):
        classes = {}
        for identifier in scope.REVIEWED_MEMBERSHIP_ACCESS_TESTS:
            _, owner, method = identifier.split("/")
            classes.setdefault(owner, []).append(f"    func {method}() {{}}")
        source = "\n".join(f"final class {owner}: XCTestCase {{\n" + "\n".join(methods) + "\n}"
                           for owner, methods in classes.items())
        changes = {path: ("" if path in scope.MEMBERSHIP_ACCESS_NEW_PATHS else "before " + path,
                          source if path == scope.MEMORY_TEST_PATH else "after " + path)
                   for path in scope.MEMBERSHIP_ACCESS_PATHS}
        anchor = "      - name: Verify personal Widget photo rotation\n"
        workflow = "jobs:\n" + anchor + "        run: existing-safe-check\n"
        changes[scope.CI_WORKFLOW] = (workflow, workflow.replace(anchor, scope.MEMBERSHIP_ACCESS_WORKFLOW_ADDITION + anchor))
        if extra_step:
            changes[scope.CI_WORKFLOW] = (workflow, changes[scope.CI_WORKFLOW][1] + "unreviewed-step\n")
        for path in ("NekoWidget/NekoWidget/Info.plist", "NekoWidget/NekoWidgetWidget/Info.plist"):
            after = '<plist version="1.0"><dict><key>MembershipAccessEnforced</key>' + ('<true/>' if enforced else '<false/>') + '</dict></plist>'
            changes[path] = (changes[path][0], after)
        product = {path: tuple(map(scope.source_digest, pair)) for path, pair in changes.items()}
        review = {"schemaVersion": 1, "scope": scope.REVIEWED_MEMBERSHIP_ACCESS_SCOPE,
                  "purpose": "Reviewed beta-disabled membership access", "visualReview": "native-ui-required",
                  "dataReview": scope.MEMBERSHIP_ACCESS_DATA_REVIEW,
                  "files": {path: {"before": pair[0], "after": pair[1]} for path, pair in product.items()}}
        changes[scope.REVIEW_MANIFEST] = ("{}", json.dumps(review))
        changes.update({path: ("before " + path, "after " + path) for path in scope.MEMBERSHIP_ACCESS_COMPANION_PATHS})
        selector = "NekoWidget/ci/ios_ci_scope.py"
        empty = "MEMBERSHIP_ACCESS_COMPANION_DIGESTS = {}\n"
        changes[selector] = ("old selector", empty + "# reviewed selector source\n")
        companions = {path: list(map(scope.source_digest, changes[path]))
                      for path in scope.MEMBERSHIP_ACCESS_COMPANION_PATHS | {scope.REVIEW_MANIFEST}}
        literal = "MEMBERSHIP_ACCESS_COMPANION_DIGESTS = " + json.dumps(companions, indent=4, sort_keys=True) + "\n"
        changes[selector] = (changes[selector][0], changes[selector][1].replace(empty, literal))
        return changes, product, companions

    def test_membership_access_requires_complete_frozen_product_and_companions(self):
        changes, product, companions = self.membership_access_changes()
        with patch.object(scope, "MEMBERSHIP_ACCESS_DIGESTS", {}):
            self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
        with patch.object(scope, "MEMBERSHIP_ACCESS_DIGESTS", product), \
                patch.object(scope, "MEMBERSHIP_ACCESS_COMPANION_DIGESTS", companions):
            self.assertEqual(scope.select_scope(changes), scope.REVIEWED_MEMBERSHIP_ACCESS_SCOPE)
            for path in changes:
                missing = dict(changes); del missing[path]
                self.assertEqual(scope.select_scope(missing), scope.FULL_SCOPE)
                for side in (0, 1):
                    altered = list(changes[path]); altered[side] += " unreviewed change"
                    self.assertEqual(scope.select_scope(dict(changes, **{path: tuple(altered)})), scope.FULL_SCOPE)
            for extra in (scope.CI_WORKFLOW, scope.CI_DIAGNOSTIC_MATRIX,
                          "NekoWidget/NekoWidget/Services/UnknownMembership.swift",
                          "NekoWidget/Config.xcconfig", "NekoWidget/NekoWidget/Info.plist",
                          "NekoWidget/NekoWidget/Services/FamilyRecordClient.swift",
                          "NekoWidget/NekoWidget/Services/PhotoMemoryNoteStore.swift"):
                self.assertEqual(scope.select_scope(dict(changes, **{extra: ("old", "new")})), scope.FULL_SCOPE)
            selector = "NekoWidget/ci/ios_ci_scope.py"
            source = changes[selector][1]
            for altered in (source + source, source.replace("DIGESTS = ", "DIGESTS=", 1)):
                self.assertEqual(scope.select_scope(dict(changes, **{selector: (changes[selector][0], altered)})),
                                 scope.FULL_SCOPE)

    def test_membership_access_rehashed_flags_and_extra_workflow_step_still_fail_closed(self):
        for arguments in ({"enforced": True}, {"extra_step": True}):
            changes, product, companions = self.membership_access_changes(**arguments)
            with patch.object(scope, "MEMBERSHIP_ACCESS_DIGESTS", product), \
                    patch.object(scope, "MEMBERSHIP_ACCESS_COMPANION_DIGESTS", companions):
                self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)

    def test_membership_access_raw_diff_and_safety_evidence_remain_required(self):
        changes, product, companions = self.membership_access_changes()
        base, paths = "b" * 40, sorted(changes)
        def selected(path=None, modes=":100644 100644", status="M", extra=False):
            raw = ""
            for item in paths:
                default_modes = ":000000 100644" if item in scope.MEMBERSHIP_ACCESS_NEW_PATHS else ":100644 100644"
                default_status = "A" if item in scope.MEMBERSHIP_ACCESS_NEW_PATHS else "M"
                raw += (f"{modes if item == path else default_modes} {'c' * 40} {'d' * 40} "
                        f"{status if item == path else default_status}\0{item}\0")
            if extra:
                raw += f":100644 100644 {'c' * 40} {'d' * 40} M\0unreported.swift\0"
            def git(*args):
                if args[0] == "diff":
                    return raw
                if args[0] == "show":
                    revision, item = args[1].split(":", 1)
                    if revision == base and item in scope.MEMBERSHIP_ACCESS_NEW_PATHS:
                        raise AssertionError("An approved addition has no base blob")
                    return changes[item][0 if revision == base else 1]
                return self.sha
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(paths, {}, self.env)
        with patch.object(scope, "MEMBERSHIP_ACCESS_DIGESTS", product), \
                patch.object(scope, "MEMBERSHIP_ACCESS_COMPANION_DIGESTS", companions):
            self.assertEqual(selected(), scope.REVIEWED_MEMBERSHIP_ACCESS_SCOPE)
            self.assertEqual(selected(extra=True), scope.FULL_SCOPE)
            for path in paths:
                invalid = [(":100644 000000", "D"), (":100644 100755", "M"),
                           (":100644 120000", "T"), (":100644 100644", "R100"),
                           (":100644 100644", "C100"), (":000000 100755", "A"),
                           (":000000 120000", "A")]
                invalid.append((":100644 100644", "M") if path in scope.MEMBERSHIP_ACCESS_NEW_PATHS
                               else (":000000 100644", "A"))
                for modes, status in invalid:
                    self.assertEqual(selected(path, modes, status), scope.FULL_SCOPE)
        selected_scope = scope.REVIEWED_MEMBERSHIP_ACCESS_SCOPE
        required = planner.required_jobs(paths, selected_scope)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(selected_scope))
        self.assertTrue(scope.accepts_paths(selected_scope, paths))
        self.assertEqual(scope.lanes(selected_scope), scope.LANES)
        tests = scope.lane_tests(selected_scope, "app-ui")
        self.assertEqual(len(tests), 2)
        self.assertEqual(len(set(tests)), 2)
        self.assertTrue(scope.memory_tests_available(changes[scope.MEMORY_TEST_PATH][1], tests))
        self.assertFalse(scope.memory_tests_available(changes[scope.MEMORY_TEST_PATH][1].replace(
            "testMembershipAccessPreservesExistingMemoAndDistinguishesUnknown", "absent"), tests))
        jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success"} for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, required, base))
        self.assertFalse(planner.covers_jobs(jobs, planner.required_jobs_from_scope(scope.REVIEWED_CAT_NOTE_SCOPE), self.sha))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, self.sha))
            self.assertFalse(planner.covers_jobs(jobs + [jobs[index]], required, self.sha))
            for conclusion in ("failure", "skipped", "cancelled"):
                altered = copy.deepcopy(jobs); altered[index]["conclusion"] = conclusion
                self.assertFalse(planner.covers_jobs(altered, required, self.sha))

    DELIVERY_TESTS = (
        "NekoWidgetUITests/MomentDeliveryComposerUITests/testPhotoDeliveryProgressAllowsOtherActionsAndShowsTruthfulStates",
        "NekoWidgetUITests/MomentDeliveryComposerUITests/testPhotoWindowRetryPreservesConfirmedPhotoAndCaption",
        "NekoWidgetUITests/MomentDeliveryComposerUITests/testFamilyRecordKeepsOtherAuthorsWordsWhenPhotoIsWithdrawnAndRevokesAccess",
    )

    @staticmethod
    def delivery_membership_changes():
        classes = {}
        for identifier in scope.REVIEWED_DELIVERY_MEMBERSHIP_TESTS:
            _, owner, method = identifier.split("/")
            classes.setdefault(owner, []).append(f"    func {method}() {{}}")
        source = "\n".join(f"final class {owner}: XCTestCase {{\n" + "\n".join(methods) + "\n}"
                           for owner, methods in classes.items())
        changes = {path: ("" if path in scope.DELIVERY_MEMBERSHIP_NEW_PATHS else "before " + path,
                          source if path == scope.MEMORY_TEST_PATH else "after " + path)
                   for path in scope.DELIVERY_MEMBERSHIP_PATHS}
        product = {path: tuple(map(scope.source_digest, pair)) for path, pair in changes.items()}
        review = {"schemaVersion": 1, "scope": scope.REVIEWED_DELIVERY_MEMBERSHIP_SCOPE,
                  "purpose": "Reviewed explicit delivery support boundary", "visualReview": "native-ui-required",
                  "dataReview": scope.DELIVERY_MEMBERSHIP_DATA_REVIEW,
                  "files": {path: {"before": pair[0], "after": pair[1]} for path, pair in product.items()}}
        changes[scope.REVIEW_MANIFEST] = ("{}", json.dumps(review))
        changes.update({path: ("before " + path, "after " + path) for path in scope.DELIVERY_MEMBERSHIP_COMPANION_PATHS})
        selector = "NekoWidget/ci/ios_ci_scope.py"
        empty = "DELIVERY_MEMBERSHIP_COMPANION_DIGESTS = {}\n"
        changes[selector] = ("old selector", empty + "# reviewed selector source\n")
        companions = {path: list(map(scope.source_digest, changes[path]))
                      for path in scope.DELIVERY_MEMBERSHIP_COMPANION_PATHS | {scope.REVIEW_MANIFEST}}
        literal = "DELIVERY_MEMBERSHIP_COMPANION_DIGESTS = " + json.dumps(companions, indent=4, sort_keys=True) + "\n"
        changes[selector] = (changes[selector][0], changes[selector][1].replace(empty, literal))
        return changes, product, companions

    @patch.object(scope, "REVIEWED_DELIVERY_MEMBERSHIP_TESTS", DELIVERY_TESTS)
    def test_delivery_membership_requires_complete_frozen_product_and_companions(self):
        changes, product, companions = self.delivery_membership_changes()
        with patch.object(scope, "DELIVERY_MEMBERSHIP_DIGESTS", {}):
            self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
        with patch.object(scope, "DELIVERY_MEMBERSHIP_DIGESTS", product), \
                patch.object(scope, "DELIVERY_MEMBERSHIP_COMPANION_DIGESTS", companions):
            self.assertEqual(scope.select_scope(changes), scope.REVIEWED_DELIVERY_MEMBERSHIP_SCOPE)
            with patch.object(scope, "REVIEWED_DELIVERY_MEMBERSHIP_TESTS", ()):
                self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
            for path in changes:
                missing = dict(changes); del missing[path]
                self.assertEqual(scope.select_scope(missing), scope.FULL_SCOPE)
                for side in (0, 1):
                    altered = list(changes[path]); altered[side] += " unreviewed change"
                    self.assertEqual(scope.select_scope(dict(changes, **{path: tuple(altered)})), scope.FULL_SCOPE)
            for extra in (scope.CI_WORKFLOW, scope.CI_DIAGNOSTIC_MATRIX,
                          "NekoWidget/NekoWidget/Services/UnknownMembership.swift",
                          ".github/workflows/sharing-service.yml",
                          "NekoWidget/SharingService/package.json", "NekoWidget/SharingService/package-lock.json",
                          "NekoWidget/SharingService/wrangler.jsonc",
                          "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                          "NekoWidget/Shared/Models/WidgetRenderPlan.swift",
                          "NekoWidget/Config.xcconfig", "NekoWidget/NekoWidget/Info.plist",
                          "NekoWidget/NekoWidget/Services/FamilyRecordClient.swift",
                          "NekoWidget/NekoWidget/Services/PhotoMemoryNoteStore.swift"):
                self.assertEqual(scope.select_scope(dict(changes, **{extra: ("old", "new")})), scope.FULL_SCOPE)
            selector = "NekoWidget/ci/ios_ci_scope.py"
            source = changes[selector][1]
            for altered in (source + source, source.replace("DIGESTS = ", "DIGESTS=", 1)):
                self.assertEqual(scope.select_scope(dict(changes, **{selector: (changes[selector][0], altered)})),
                                 scope.FULL_SCOPE)

    @patch.object(scope, "REVIEWED_DELIVERY_MEMBERSHIP_TESTS", DELIVERY_TESTS)
    def test_delivery_membership_raw_diff_and_safety_evidence_remain_required(self):
        changes, product, companions = self.delivery_membership_changes()
        base, paths = "b" * 40, sorted(changes)
        def selected(path=None, modes=":100644 100644", status="M", extra=False):
            raw = ""
            for item in paths:
                default_modes = ":000000 100644" if item in scope.DELIVERY_MEMBERSHIP_NEW_PATHS else ":100644 100644"
                default_status = "A" if item in scope.DELIVERY_MEMBERSHIP_NEW_PATHS else "M"
                raw += (f"{modes if item == path else default_modes} {'c' * 40} {'d' * 40} "
                        f"{status if item == path else default_status}\0{item}\0")
            if extra:
                raw += f":100644 100644 {'c' * 40} {'d' * 40} M\0unreported.swift\0"
            def git(*args):
                if args[0] == "diff":
                    return raw
                if args[0] == "show":
                    revision, item = args[1].split(":", 1)
                    if revision == base and item in scope.DELIVERY_MEMBERSHIP_NEW_PATHS:
                        raise AssertionError("An approved addition has no base blob")
                    return changes[item][0 if revision == base else 1]
                return self.sha
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(paths, {}, self.env)
        with patch.object(scope, "DELIVERY_MEMBERSHIP_DIGESTS", product), \
                patch.object(scope, "DELIVERY_MEMBERSHIP_COMPANION_DIGESTS", companions):
            self.assertEqual(selected(), scope.REVIEWED_DELIVERY_MEMBERSHIP_SCOPE)
            self.assertEqual(selected(extra=True), scope.FULL_SCOPE)
            for path in paths:
                invalid = [(":100644 000000", "D"), (":100644 100755", "M"),
                           (":100644 120000", "T"), (":100644 100644", "R100"),
                           (":100644 100644", "C100"), (":000000 100755", "A"),
                           (":000000 120000", "A")]
                invalid.append((":100644 100644", "M") if path in scope.DELIVERY_MEMBERSHIP_NEW_PATHS
                               else (":000000 100644", "A"))
                for modes, status in invalid:
                    self.assertEqual(selected(path, modes, status), scope.FULL_SCOPE)
        selected_scope = scope.REVIEWED_DELIVERY_MEMBERSHIP_SCOPE
        required = planner.required_jobs(paths, selected_scope)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(selected_scope))
        self.assertTrue(scope.accepts_paths(selected_scope, paths))
        self.assertEqual(scope.lanes(selected_scope), ("runtime", "app-ui"))
        tests = scope.native_tests(selected_scope)
        self.assertEqual(len(tests), 3)
        self.assertEqual(len(set(tests)), 3)
        self.assertTrue(scope.memory_tests_available(changes[scope.MEMORY_TEST_PATH][1], tests))
        self.assertFalse(scope.memory_tests_available(changes[scope.MEMORY_TEST_PATH][1].replace(
            "testPhotoDeliveryProgressAllowsOtherActionsAndShowsTruthfulStates", "absent"), tests))
        jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success"} for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, required, base))
        self.assertFalse(planner.covers_jobs(jobs, planner.required_jobs_from_scope(scope.REVIEWED_CAT_NOTE_SCOPE), self.sha))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, self.sha))
            self.assertFalse(planner.covers_jobs(jobs + [jobs[index]], required, self.sha))
            for conclusion in ("failure", "skipped", "cancelled"):
                altered = copy.deepcopy(jobs); altered[index]["conclusion"] = conclusion
                self.assertFalse(planner.covers_jobs(altered, required, self.sha))

    def test_delivery_gallery_exclusion_requires_unchanged_render_inputs_and_widget_project(self):
        for path in ("NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                     "NekoWidget/Shared/Models/WidgetRenderPlan.swift",
                     "NekoWidget/Shared/UI/CatPawMark.swift",
                     "NekoWidget/Shared/Storage/PersonalRediscoveryStore.swift",
                     "NekoWidget/NekoWidget/Services/CanonicalPreviewBuilder.swift"):
            self.assertFalse(scope.delivery_gallery_inputs_unchanged({path: ("old", "new")}))
        project = "NekoWidget/NekoWidget.xcodeproj/project.pbxproj"
        widget = "\t\tA00000000000000000000025 /* Sources */ = {\n\t\t\tfiles = (unchanged);\n\t\t};\n"
        sections = "".join("/* Begin " + name + " section */\nfrozen\n/* End " + name + " section */\n"
                           for name in ("PBXNativeTarget", "XCBuildConfiguration", "XCConfigurationList",
                                        "PBXResourcesBuildPhase", "PBXFrameworksBuildPhase"))
        before = widget + sections + "app sources before"
        after = widget + sections + "app sources after"
        self.assertTrue(scope.delivery_gallery_inputs_unchanged({project: (before, after)}))
        for bad in (after.replace("unchanged", "new-widget-source"), after.replace("frozen", "changed", 1),
                    after + "\n" + widget, "missing project sections"):
            self.assertFalse(scope.delivery_gallery_inputs_unchanged({project: (before, bad)}))

    @staticmethod
    def membership_offer_changes():
        classes = {}
        for identifier in scope.REVIEWED_MEMBERSHIP_OFFER_TESTS:
            _, owner, method = identifier.split("/")
            classes.setdefault(owner, []).append(f"    func {method}() {{}}")
        source = "\n".join(f"final class {owner}: XCTestCase {{\n" + "\n".join(methods) + "\n}"
                           for owner, methods in classes.items())
        changes = {path: ("" if path in scope.MEMBERSHIP_OFFER_NEW_PATHS else "before " + path,
                          source if path == scope.MEMORY_TEST_PATH else "after " + path)
                   for path in scope.MEMBERSHIP_OFFER_PATHS}
        product = {path: tuple(map(scope.source_digest, pair)) for path, pair in changes.items()}
        review = {"schemaVersion": 1, "scope": scope.REVIEWED_MEMBERSHIP_OFFER_SCOPE,
                  "purpose": "Reviewed disabled membership offer", "visualReview": "native-ui-required",
                  "dataReview": scope.MEMBERSHIP_OFFER_DATA_REVIEW,
                  "files": {path: {"before": pair[0], "after": pair[1]} for path, pair in product.items()}}
        changes[scope.REVIEW_MANIFEST] = ("{}", json.dumps(review))
        changes.update({path: ("before " + path, "after " + path) for path in scope.MEMBERSHIP_OFFER_COMPANION_PATHS})
        selector = "NekoWidget/ci/ios_ci_scope.py"
        empty = "MEMBERSHIP_OFFER_COMPANION_DIGESTS = {}\n"
        changes[selector] = ("old selector", empty + "# reviewed selector source\n")
        companions = {path: list(map(scope.source_digest, changes[path]))
                      for path in scope.MEMBERSHIP_OFFER_COMPANION_PATHS | {scope.REVIEW_MANIFEST}}
        literal = "MEMBERSHIP_OFFER_COMPANION_DIGESTS = " + json.dumps(companions, indent=4, sort_keys=True) + "\n"
        changes[selector] = (changes[selector][0], changes[selector][1].replace(empty, literal))
        return changes, product, companions

    def test_membership_offer_requires_complete_frozen_product_and_companions(self):
        changes, product, companions = self.membership_offer_changes()
        with patch.object(scope, "MEMBERSHIP_OFFER_DIGESTS", {}):
            self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
        with patch.object(scope, "MEMBERSHIP_OFFER_DIGESTS", product), \
                patch.object(scope, "MEMBERSHIP_OFFER_COMPANION_DIGESTS", companions):
            self.assertEqual(scope.select_scope(changes), scope.REVIEWED_MEMBERSHIP_OFFER_SCOPE)
            for path in changes:
                missing = dict(changes); del missing[path]
                self.assertEqual(scope.select_scope(missing), scope.FULL_SCOPE)
                for side in (0, 1):
                    altered = list(changes[path]); altered[side] += " unreviewed change"
                    self.assertEqual(scope.select_scope(dict(changes, **{path: tuple(altered)})), scope.FULL_SCOPE)
            for extra in (scope.CI_WORKFLOW, scope.CI_DIAGNOSTIC_MATRIX,
                          "NekoWidget/NekoWidget/Services/UnknownMembership.swift",
                          "NekoWidget/Config.xcconfig", "NekoWidget/NekoWidget/Info.plist",
                          "NekoWidget/NekoWidget/Services/FamilyRecordClient.swift",
                          "NekoWidget/NekoWidget/Services/PhotoMemoryNoteStore.swift"):
                self.assertEqual(scope.select_scope(dict(changes, **{extra: ("old", "new")})), scope.FULL_SCOPE)
            selector = "NekoWidget/ci/ios_ci_scope.py"
            source = changes[selector][1]
            for altered in (source + source, source.replace("DIGESTS = ", "DIGESTS=", 1)):
                self.assertEqual(scope.select_scope(dict(changes, **{selector: (changes[selector][0], altered)})),
                                 scope.FULL_SCOPE)

    def test_membership_offer_raw_diff_and_safety_evidence_remain_required(self):
        changes, product, companions = self.membership_offer_changes()
        base, paths = "b" * 40, sorted(changes)
        def selected(path=None, modes=":100644 100644", status="M", extra=False):
            raw = ""
            for item in paths:
                default_modes = ":000000 100644" if item in scope.MEMBERSHIP_OFFER_NEW_PATHS else ":100644 100644"
                default_status = "A" if item in scope.MEMBERSHIP_OFFER_NEW_PATHS else "M"
                raw += (f"{modes if item == path else default_modes} {'c' * 40} {'d' * 40} "
                        f"{status if item == path else default_status}\0{item}\0")
            if extra:
                raw += f":100644 100644 {'c' * 40} {'d' * 40} M\0unreported.swift\0"
            def git(*args):
                if args[0] == "diff":
                    return raw
                if args[0] == "show":
                    revision, item = args[1].split(":", 1)
                    if revision == base and item in scope.MEMBERSHIP_OFFER_NEW_PATHS:
                        raise AssertionError("An approved addition has no base blob")
                    return changes[item][0 if revision == base else 1]
                return self.sha
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(paths, {}, self.env)
        with patch.object(scope, "MEMBERSHIP_OFFER_DIGESTS", product), \
                patch.object(scope, "MEMBERSHIP_OFFER_COMPANION_DIGESTS", companions):
            self.assertEqual(selected(), scope.REVIEWED_MEMBERSHIP_OFFER_SCOPE)
            self.assertEqual(selected(extra=True), scope.FULL_SCOPE)
            for path in paths:
                invalid = [(":100644 000000", "D"), (":100644 100755", "M"),
                           (":100644 120000", "T"), (":100644 100644", "R100"),
                           (":100644 100644", "C100"), (":000000 100755", "A"),
                           (":000000 120000", "A")]
                invalid.append((":100644 100644", "M") if path in scope.MEMBERSHIP_OFFER_NEW_PATHS
                               else (":000000 100644", "A"))
                for modes, status in invalid:
                    self.assertEqual(selected(path, modes, status), scope.FULL_SCOPE)
        selected_scope = scope.REVIEWED_MEMBERSHIP_OFFER_SCOPE
        required = planner.required_jobs(paths, selected_scope)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(selected_scope))
        self.assertTrue(scope.accepts_paths(selected_scope, paths))
        self.assertEqual(scope.lanes(selected_scope), ("runtime", "app-ui"))
        tests = scope.native_tests(selected_scope)
        self.assertEqual(len(tests), 2)
        self.assertEqual(len(set(tests)), 2)
        self.assertTrue(scope.memory_tests_available(changes[scope.MEMORY_TEST_PATH][1], tests))
        self.assertFalse(scope.memory_tests_available(changes[scope.MEMORY_TEST_PATH][1].replace(
            "testMembershipOfferPreviewWaitingAndRestore", "absent"), tests))
        jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success"} for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, required, base))
        self.assertFalse(planner.covers_jobs(jobs, planner.required_jobs_from_scope(scope.REVIEWED_CAT_NOTE_SCOPE), self.sha))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, self.sha))
            self.assertFalse(planner.covers_jobs(jobs + [jobs[index]], required, self.sha))
            for conclusion in ("failure", "skipped", "cancelled"):
                altered = copy.deepcopy(jobs); altered[index]["conclusion"] = conclusion
                self.assertFalse(planner.covers_jobs(altered, required, self.sha))

    @staticmethod
    def photo_actions_changes():
        classes = {}
        for identifier in scope.REVIEWED_PHOTO_ACTIONS_TESTS:
            _, owner, method = identifier.split("/")
            classes.setdefault(owner, []).append(f"    func {method}() {{}}")
        source = "\n".join(f"final class {owner}: XCTestCase {{\n" + "\n".join(methods) + "\n}"
                           for owner, methods in classes.items())
        changes = {path: ("before " + path, source if path == scope.MEMORY_TEST_PATH else "after " + path)
                   for path in scope.PHOTO_ACTIONS_PATHS}
        product = {path: tuple(map(scope.source_digest, pair)) for path, pair in changes.items()}
        review = {"schemaVersion": 1, "scope": scope.REVIEWED_PHOTO_ACTIONS_SCOPE,
                  "purpose": "Reviewed photo actions and shared memo reading", "visualReview": "user-device",
                  "dataReview": scope.PHOTO_ACTIONS_DATA_REVIEW,
                  "files": {path: {"before": pair[0], "after": pair[1]} for path, pair in product.items()}}
        changes[scope.REVIEW_MANIFEST] = ("{}", json.dumps(review))
        changes.update({path: ("before " + path, "after " + path) for path in scope.PHOTO_ACTIONS_COMPANION_PATHS})
        selector = "NekoWidget/ci/ios_ci_scope.py"
        empty = "PHOTO_ACTIONS_COMPANION_DIGESTS = {}\n"
        changes[selector] = ("old selector", empty + "# reviewed selector source\n")
        companions = {path: list(map(scope.source_digest, changes[path]))
                      for path in scope.PHOTO_ACTIONS_COMPANION_PATHS | {scope.REVIEW_MANIFEST}}
        literal = "PHOTO_ACTIONS_COMPANION_DIGESTS = " + json.dumps(companions, indent=4, sort_keys=True) + "\n"
        changes[selector] = (changes[selector][0], changes[selector][1].replace(empty, literal))
        return changes, product, companions

    def test_photo_actions_requires_complete_frozen_product_and_companions(self):
        changes, product, companions = self.photo_actions_changes()
        with patch.object(scope, "PHOTO_ACTIONS_DIGESTS", {}):
            self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
        with patch.object(scope, "PHOTO_ACTIONS_DIGESTS", product), \
                patch.object(scope, "PHOTO_ACTIONS_COMPANION_DIGESTS", companions):
            self.assertEqual(scope.select_scope(changes), scope.REVIEWED_PHOTO_ACTIONS_SCOPE)
            for path in changes:
                missing = dict(changes); del missing[path]
                self.assertEqual(scope.select_scope(missing), scope.FULL_SCOPE)
                for side in (0, 1):
                    altered = list(changes[path]); altered[side] += " unreviewed change"
                    self.assertEqual(scope.select_scope(dict(changes, **{path: tuple(altered)})), scope.FULL_SCOPE)
            for extra in (scope.CI_WORKFLOW, scope.CI_DIAGNOSTIC_MATRIX,
                          "NekoWidget/NekoWidget/Services/FamilyRecordClient.swift",
                          "NekoWidget/NekoWidget/Services/PhotoMemoryNoteStore.swift"):
                self.assertEqual(scope.select_scope(dict(changes, **{extra: ("old", "new")})), scope.FULL_SCOPE)
            selector = "NekoWidget/ci/ios_ci_scope.py"
            source = changes[selector][1]
            for altered in (source + source, source.replace("DIGESTS = ", "DIGESTS=", 1)):
                self.assertEqual(scope.select_scope(dict(changes, **{selector: (changes[selector][0], altered)})),
                                 scope.FULL_SCOPE)

    def test_photo_actions_raw_diff_and_safety_evidence_remain_required(self):
        changes, product, companions = self.photo_actions_changes()
        base, paths = "b" * 40, sorted(changes)
        def selected(path=None, modes=":100644 100644", status="M", extra=False):
            raw = "".join(f"{modes if item == path else ':100644 100644'} {'c' * 40} {'d' * 40} "
                          f"{status if item == path else 'M'}\0{item}\0" for item in paths)
            if extra:
                raw += f":100644 100644 {'c' * 40} {'d' * 40} M\0unreported.swift\0"
            def git(*args):
                if args[0] == "diff":
                    return raw
                if args[0] == "show":
                    revision, item = args[1].split(":", 1)
                    return changes[item][0 if revision == base else 1]
                return self.sha
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(paths, {}, self.env)
        with patch.object(scope, "PHOTO_ACTIONS_DIGESTS", product), \
                patch.object(scope, "PHOTO_ACTIONS_COMPANION_DIGESTS", companions):
            self.assertEqual(selected(), scope.REVIEWED_PHOTO_ACTIONS_SCOPE)
            self.assertEqual(selected(extra=True), scope.FULL_SCOPE)
            for path in paths:
                for modes, status in ((":000000 100644", "A"), (":100644 000000", "D"),
                                      (":100644 100755", "M"), (":100644 120000", "T"),
                                      (":100644 100644", "R100"), (":100644 100644", "C100")):
                    self.assertEqual(selected(path, modes, status), scope.FULL_SCOPE)
        selected_scope = scope.REVIEWED_PHOTO_ACTIONS_SCOPE
        required = planner.required_jobs(paths, selected_scope)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(selected_scope))
        self.assertTrue(scope.accepts_paths(selected_scope, paths))
        self.assertEqual(scope.lanes(selected_scope), ("runtime", "app-ui"))
        tests = scope.native_tests(selected_scope)
        self.assertEqual(len(tests), 8)
        self.assertEqual(len(set(tests)), 8)
        root = Path(__file__).resolve().parents[2]
        self.assertTrue(scope.memory_tests_available((root / scope.MEMORY_TEST_PATH).read_text(encoding="utf-8"), tests))
        jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success"} for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, required, base))
        self.assertFalse(planner.covers_jobs(jobs, planner.required_jobs_from_scope(scope.REVIEWED_CAT_NOTE_SCOPE), self.sha))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, self.sha))
            self.assertFalse(planner.covers_jobs(jobs + [jobs[index]], required, self.sha))
            for conclusion in ("failure", "skipped", "cancelled"):
                altered = copy.deepcopy(jobs); altered[index]["conclusion"] = conclusion
                self.assertFalse(planner.covers_jobs(altered, required, self.sha))

    @staticmethod
    def cat_note_changes(values=None, **overrides):
        if values is None:
            classes = {}
            for identifier in scope.REVIEWED_CAT_NOTE_TESTS:
                _, owner, method = identifier.split("/")
                classes.setdefault(owner, []).append(f"    func {method}() {{}}")
            source = "\n".join(f"final class {owner}: XCTestCase {{\n" + "\n".join(methods) + "\n}"
                               for owner, methods in classes.items())
            values = {path: ("before " + path, source if path == scope.MEMORY_TEST_PATH else "after " + path)
                      for path in scope.CAT_NOTE_PATHS}
        values = {path: pair for path, pair in values.items() if path != scope.REVIEW_MANIFEST}
        review = {"schemaVersion": 1, "scope": scope.REVIEWED_CAT_NOTE_SCOPE,
                  "purpose": "Independently reviewed explicit memo sharing", "visualReview": "user-device",
                  "dataReview": scope.CAT_NOTE_DATA_REVIEW,
                  "files": {path: {"before": scope.source_digest(pair[0]), "after": scope.source_digest(pair[1])}
                            for path, pair in values.items()}}
        review.update(overrides)
        return dict(values, **{scope.REVIEW_MANIFEST: ("{}", json.dumps(review))})

    def test_cat_note_scope_requires_frozen_complete_review_not_just_rehashed_manifest(self):
        changes = self.cat_note_changes()
        digests = {path: tuple(map(scope.source_digest, changes[path])) for path in scope.CAT_NOTE_PATHS}
        with patch.object(scope, "CAT_NOTE_DIGESTS", {}):
            self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
        with patch.object(scope, "CAT_NOTE_DIGESTS", digests):
            self.assertEqual(scope.select_scope(changes), scope.REVIEWED_CAT_NOTE_SCOPE)
            self.assertEqual(scope.select_scope(dict(changes, **{"handoffs/review.md": ("", "reviewed")})),
                             scope.REVIEWED_CAT_NOTE_SCOPE)
            for path in changes:
                missing = dict(changes); del missing[path]
                self.assertEqual(scope.select_scope(missing), scope.FULL_SCOPE)
            for path in scope.CAT_NOTE_PATHS:
                for side in (0, 1):
                    altered = list(changes[path]); altered[side] += " unreviewed change"
                    # An updated manifest cannot approve changed source independently.
                    self.assertEqual(scope.select_scope(self.cat_note_changes(
                        dict(changes, **{path: tuple(altered)}))), scope.FULL_SCOPE)
            for extra in ("NekoWidget/NekoWidget/Services/PhotoMemoryNoteStore.swift",
                          "NekoWidget/Shared/Sharing/PairingCore.swift",
                          "NekoWidget/Shared/Sharing/MomentSharingCore.swift",
                          "NekoWidget/NekoWidget.xcodeproj/project.pbxproj",
                          "NekoWidget/ci/ios_ci_scope.py", scope.CI_WORKFLOW):
                self.assertEqual(scope.select_scope(self.cat_note_changes(
                    dict(changes, **{extra: ("old", "new")}))), scope.FULL_SCOPE)
            for fields in ({"schemaVersion": True}, {"scope": scope.REVIEWED_MEMORY_FAMILY_SCOPE},
                           {"visualReview": "unchecked"}, {"dataReview": "read-only-projection"},
                           {"purpose": " "}, {"files": {}}, {"unexpected": True}):
                self.assertEqual(scope.select_scope(self.cat_note_changes(changes, **fields)), scope.FULL_SCOPE)
            for manifest in ("[]", "null", "{invalid", changes[scope.REVIEW_MANIFEST][1].replace(
                    '"schemaVersion": 1', '"schemaVersion": 1, "schemaVersion": 1')):
                self.assertEqual(scope.select_scope(dict(changes, **{scope.REVIEW_MANIFEST: ("{}", manifest)})),
                                 scope.FULL_SCOPE)
            for identifier in scope.REVIEWED_CAT_NOTE_TESTS:
                source = changes[scope.MEMORY_TEST_PATH][1]
                method = identifier.split("/")[-1]
                altered = dict(changes, **{scope.MEMORY_TEST_PATH: ("before", source.replace(method, "absent"))})
                # Even a separately reviewed hash table cannot select missing tests.
                revised = dict(digests, **{scope.MEMORY_TEST_PATH: tuple(map(scope.source_digest, altered[scope.MEMORY_TEST_PATH]))})
                with patch.object(scope, "CAT_NOTE_DIGESTS", revised):
                    self.assertEqual(scope.select_scope(self.cat_note_changes(altered)), scope.FULL_SCOPE)

    def test_cat_note_repair_accepts_only_the_frozen_complete_companion_sources(self):
        changes = self.cat_note_changes()
        product = {path: tuple(map(scope.source_digest, changes[path])) for path in scope.CAT_NOTE_PATHS}
        companions = {path: ("old " + path, "new " + path) for path in scope.CAT_NOTE_REPAIR_PATHS}
        selector = "NekoWidget/ci/ios_ci_scope.py"
        companions[selector] = ("old selector", "CAT_NOTE_REPAIR_DIGESTS = {}\n# frozen executable source\n")
        changes.update(companions)
        bindings = {path: list(map(scope.source_digest, changes[path]))
                    for path in scope.CAT_NOTE_REPAIR_PATHS | {scope.REVIEW_MANIFEST}}
        literal = "CAT_NOTE_REPAIR_DIGESTS = " + json.dumps(bindings, indent=4, sort_keys=True) + "\n"
        changes[selector] = (companions[selector][0], companions[selector][1].replace(
            "CAT_NOTE_REPAIR_DIGESTS = {}\n", literal))
        with patch.object(scope, "CAT_NOTE_DIGESTS", product), patch.object(scope, "CAT_NOTE_REPAIR_DIGESTS", bindings):
            self.assertEqual(scope.select_scope(changes), scope.REVIEWED_CAT_NOTE_SCOPE)
            self.assertTrue(scope.accepts_paths(scope.REVIEWED_CAT_NOTE_SCOPE, list(changes)))
            self.assertEqual(planner.required_jobs(list(changes), scope.REVIEWED_CAT_NOTE_SCOPE),
                             (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(scope.REVIEWED_CAT_NOTE_SCOPE))
            for path in scope.CAT_NOTE_REPAIR_PATHS | {scope.REVIEW_MANIFEST}:
                missing = dict(changes); del missing[path]
                self.assertEqual(scope.select_scope(missing), scope.FULL_SCOPE)
                for side in (0, 1):
                    altered = list(changes[path]); altered[side] += " unreviewed"
                    self.assertEqual(scope.select_scope(dict(changes, **{path: tuple(altered)})), scope.FULL_SCOPE)
            for source in (changes[selector][1] + literal,
                           changes[selector][1].replace(literal, literal.replace(" = ", "=", 1))):
                self.assertEqual(scope.select_scope(dict(changes, **{selector: (companions[selector][0], source)})),
                                 scope.FULL_SCOPE)
            self.assertEqual(scope.select_scope(dict(changes, **{scope.CI_WORKFLOW: ("old", "new")})), scope.FULL_SCOPE)

    def test_cat_note_planner_preserves_raw_diff_modes_status_and_complete_paths(self):
        changes = self.cat_note_changes()
        digests = {path: tuple(map(scope.source_digest, changes[path])) for path in scope.CAT_NOTE_PATHS}
        base = "b" * 40
        paths = sorted(changes)
        def selected(path=None, modes=":100644 100644", status="M", extra=False):
            raw = "".join(f"{modes if item == path else ':100644 100644'} {'c' * 40} {'d' * 40} "
                          f"{status if item == path else 'M'}\0{item}\0" for item in paths)
            if extra:
                raw += f":100644 100644 {'c' * 40} {'d' * 40} M\0unreported.swift\0"
            def git(*args):
                if args[0] == "diff":
                    return raw
                if args[0] == "show":
                    revision, item = args[1].split(":", 1)
                    return changes[item][0 if revision == base else 1]
                return self.sha
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(paths, {}, self.env)
        with patch.object(scope, "CAT_NOTE_DIGESTS", digests):
            self.assertEqual(selected(), scope.REVIEWED_CAT_NOTE_SCOPE)
            self.assertEqual(selected(extra=True), scope.FULL_SCOPE)
            for path in paths:
                for modes, status in ((":000000 100644", "A"), (":100644 000000", "D"),
                                      (":100644 100755", "M"), (":100644 120000", "T"),
                                      (":100644 100644", "R100"), (":100644 100644", "C100")):
                    self.assertEqual(selected(path, modes, status), scope.FULL_SCOPE)
        # The same raw-diff gate covers every repair companion before content
        # approval; a source matcher cannot approve additions, links or renames.
        changes.update({path: ("before", "after") for path in scope.CAT_NOTE_REPAIR_PATHS})
        paths = sorted(changes)
        with patch.object(scope, "reviewed_cat_note_changes", return_value=True):
            self.assertEqual(selected(), scope.REVIEWED_CAT_NOTE_SCOPE)
            for path in scope.CAT_NOTE_REPAIR_PATHS:
                for modes, status in ((":000000 100644", "A"), (":100644 100755", "M"),
                                      (":100644 120000", "T"), (":100644 100644", "R100")):
                    self.assertEqual(selected(path, modes, status), scope.FULL_SCOPE)

    def test_cat_note_eleven_existing_operations_keep_safety_jobs_and_distinct_evidence(self):
        selected = scope.REVIEWED_CAT_NOTE_SCOPE
        tests = scope.native_tests(selected)
        self.assertEqual(len(tests), 11)
        self.assertEqual(len(set(tests)), 11)
        self.assertFalse(any("testAlbum" in test or "testPhotosOpenEachCats" in test for test in tests))
        root = Path(__file__).resolve().parents[2]
        self.assertTrue(scope.memory_tests_available((root / scope.MEMORY_TEST_PATH).read_text(encoding="utf-8"), tests))
        required = planner.required_jobs(list(self.cat_note_changes()), selected)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(selected))
        self.assertEqual(scope.lanes(selected), ("runtime", "app-ui"))
        self.assertEqual(scope.smoke_tests(selected),
                         ("NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",))
        jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success"}
                for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, self.sha))
        self.assertTrue(planner.covers_jobs(self.jobs, required, self.sha))
        for other in (scope.FULL_SCOPE, scope.REVIEWED_MEMORY_FAMILY_SCOPE):
            self.assertFalse(planner.covers_jobs(jobs, planner.required_jobs_from_scope(other), self.sha))
        self.assertFalse(planner.covers_jobs(jobs, required, "b" * 40))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, self.sha))
            self.assertFalse(planner.covers_jobs(jobs + [jobs[index]], required, self.sha))
            for conclusion in ("failure", "skipped", "cancelled"):
                altered = copy.deepcopy(jobs); altered[index]["conclusion"] = conclusion
                self.assertFalse(planner.covers_jobs(altered, required, self.sha))

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

    def test_diagnostic_extension_hashes_preserve_normal_execution_and_reject_unreviewed_commands(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / scope.CI_DIAGNOSTIC_WORKFLOW).read_text(encoding="utf-8")
        matrix = (root / scope.CI_DIAGNOSTIC_MATRIX).read_text(encoding="utf-8")
        self.assertEqual(scope.source_digest(workflow), scope.DIAGNOSTIC_WORKFLOW_DIGEST)
        changes = {scope.CI_DIAGNOSTIC_WORKFLOW: (workflow, workflow),
                   scope.CI_DIAGNOSTIC_MATRIX: (matrix, matrix)}
        self.assertTrue(scope.ci_selection_only(changes))
        for path, token in ((scope.CI_DIAGNOSTIC_WORKFLOW, "timeout-minutes: 30"),
                            (scope.CI_DIAGNOSTIC_MATRIX, "DIAGNOSTIC_REQUESTED=false"),
                            (scope.CI_DIAGNOSTIC_MATRIX, 'COMPOSER_TEST_ARGUMENTS=()')):
            changed = dict(changes)
            source = changes[path][1]
            changed[path] = (source, source.replace(token, token + " # unreviewed", 1))
            self.assertFalse(scope.ci_selection_only(changed))

    def test_family_companion_is_exact_reviewed_presentation_and_keeps_every_memory_operation(self):
        changes = self.memory_changes()
        # Synthetic full sources exercise the hash boundary; production hashes
        # remain fixed to the independently reviewed FamilyRecordView pair.
        family_pair = ("existing family view", "reviewed family presentation")
        changes[scope.FAMILY_PRESENTATION_PATH] = family_pair
        changes[scope.PAIRING_EXPLANATION_PATH] = (
            "existing\n" + scope.PAIRING_EXPLANATION_BEFORE + "\nunchanged revocation",
            "existing\n" + scope.PAIRING_EXPLANATION_AFTER + "\nunchanged revocation")
        classes = {}
        for identifier in scope.REVIEWED_MEMORY_FAMILY_TESTS:
            _, owner, method = identifier.split("/")
            classes.setdefault(owner, []).append(f"    func {method}() {{}}")
        source = "\n".join(f"final class {owner}: XCTestCase {{\n" + "\n".join(methods) + "\n}"
                           for owner, methods in classes.items())
        changes[scope.MEMORY_TEST_PATH] = ("before", source)
        def reviewed(values, **overrides):
            review = {"schemaVersion": 1, "scope": scope.REVIEWED_MEMORY_FAMILY_SCOPE,
                      "purpose": "Reviewed presentation", "visualReview": "user-device",
                      "dataReview": "read-only-projection",
                      "files": {path: {"before": scope.source_digest(pair[0]), "after": scope.source_digest(pair[1])}
                                for path, pair in values.items() if path != scope.REVIEW_MANIFEST}}
            return dict(values, **{scope.REVIEW_MANIFEST: ("{}", json.dumps(dict(review, **overrides)))})
        with patch.object(scope, "FAMILY_PRESENTATION_DIGESTS", tuple(map(scope.source_digest, family_pair))):
            valid = reviewed(changes)
            self.assertEqual(scope.select_scope(valid), scope.REVIEWED_MEMORY_FAMILY_SCOPE)
            self.assertEqual(scope.native_tests(scope.REVIEWED_MEMORY_FAMILY_SCOPE)[:len(scope.REVIEWED_MEMORY_TESTS)],
                             scope.REVIEWED_MEMORY_TESTS)
            self.assertEqual(len(scope.native_tests(scope.REVIEWED_MEMORY_FAMILY_SCOPE)), 10)
            self.assertEqual(scope.lanes(scope.REVIEWED_MEMORY_FAMILY_SCOPE), scope.lanes(scope.REVIEWED_MEMORY_SCOPE))
            self.assertEqual(planner.required_jobs(list(valid), scope.REVIEWED_MEMORY_FAMILY_SCOPE),
                             planner.required_jobs_from_scope(scope.REVIEWED_MEMORY_FAMILY_SCOPE))
            # Removing a test, mutating a protected body, or falsifying dataReview
            # stays full even with a freshly recalculated manifest.
            for path in scope.FAMILY_COMPANION_PATHS:
                for side in (0, 1):
                    pair = list(changes[path]); pair[side] += "\nchanged write or permission"
                    self.assertEqual(scope.select_scope(reviewed(dict(changes, **{path: tuple(pair)}))), scope.FULL_SCOPE)
                missing = dict(changes); del missing[path]
                self.assertEqual(scope.select_scope(reviewed(missing)), scope.FULL_SCOPE)
            self.assertEqual(scope.select_scope(reviewed(changes, dataReview="unchecked")), scope.FULL_SCOPE)
            self.assertEqual(scope.select_scope(reviewed(changes, scope=scope.REVIEWED_MEMORY_SCOPE)), scope.FULL_SCOPE)
            for identifier in scope.REVIEWED_MEMORY_FAMILY_TESTS:
                altered = dict(changes)
                altered[scope.MEMORY_TEST_PATH] = ("before", source.replace(identifier.split("/")[-1], "absent"))
                self.assertEqual(scope.select_scope(reviewed(altered)), scope.FULL_SCOPE)
            for extra in ("NekoWidget/NekoWidget/Services/FamilyRecordClient.swift",
                          "NekoWidget/Shared/Sharing/FamilyRecordCore.swift"):
                self.assertEqual(scope.select_scope(reviewed(dict(changes, **{extra: ("old", "new")}))), scope.FULL_SCOPE)
            no_test_change = dict(changes); del no_test_change[scope.MEMORY_TEST_PATH]
            self.assertEqual(scope.select_scope(reviewed(no_test_change), memory_test_source=source), scope.REVIEWED_MEMORY_FAMILY_SCOPE)
            self.assertEqual(scope.select_scope(reviewed(no_test_change)), scope.FULL_SCOPE)
            editor_pair = ("existing editor", "reviewed local account guard and DEBUG regression hook")
            with patch.object(scope, "LOCAL_EDITOR_DIGESTS", tuple(map(scope.source_digest, editor_pair))):
                editor = dict(changes, **{scope.LOCAL_EDITOR_PATH: editor_pair})
                valid_editor = reviewed(editor, dataReview=scope.LOCAL_EDITOR_DATA_REVIEW)
                self.assertEqual(scope.select_scope(valid_editor), scope.REVIEWED_MEMORY_FAMILY_SCOPE)
                self.assertEqual(planner.required_jobs(list(valid_editor), scope.REVIEWED_MEMORY_FAMILY_SCOPE),
                                 planner.required_jobs_from_scope(scope.REVIEWED_MEMORY_FAMILY_SCOPE))
                self.assertEqual(len(scope.native_tests(scope.REVIEWED_MEMORY_FAMILY_SCOPE)), 10)
                # Both the whole-source hashes and specific data review are
                # mandatory. Rehashing an unknown editor cannot approve it.
                self.assertEqual(scope.select_scope(reviewed(editor)), scope.FULL_SCOPE)
                self.assertEqual(scope.select_scope(reviewed(editor, dataReview=scope.LOCAL_EDITOR_DATA_REVIEW,
                                                             scope=scope.REVIEWED_MEMORY_SCOPE)), scope.FULL_SCOPE)
                for side in (0, 1):
                    altered = list(editor_pair); altered[side] += " changed account or storage action"
                    unknown = dict(editor, **{scope.LOCAL_EDITOR_PATH: tuple(altered)})
                    self.assertEqual(scope.select_scope(reviewed(unknown, dataReview=scope.LOCAL_EDITOR_DATA_REVIEW)), scope.FULL_SCOPE)
                stale = copy.deepcopy(valid_editor)
                manifest = json.loads(stale[scope.REVIEW_MANIFEST][1])
                manifest["files"][scope.LOCAL_EDITOR_PATH]["after"] = "0" * 64
                stale[scope.REVIEW_MANIFEST] = ("{}", json.dumps(manifest))
                self.assertEqual(scope.select_scope(stale), scope.FULL_SCOPE)
                self.assertEqual(scope.select_scope(reviewed({scope.LOCAL_EDITOR_PATH: editor_pair},
                    dataReview=scope.LOCAL_EDITOR_DATA_REVIEW)), scope.FULL_SCOPE)
                # The planner still rejects added/symlink/executable editor
                # files before the exact reviewed source pair is considered.
                paths = sorted(valid_editor)
                base = "b" * 40
                for old_mode, new_mode, status, allowed in (
                        ("100644", "100644", "M", True), ("000000", "100644", "A", False),
                        ("100644", "120000", "T", False), ("100644", "100755", "M", False)):
                    raw = "".join(f":{old_mode if path == scope.LOCAL_EDITOR_PATH else '100644'} "
                        f"{new_mode if path == scope.LOCAL_EDITOR_PATH else '100644'} {'c' * 40} {'d' * 40} "
                        f"{status if path == scope.LOCAL_EDITOR_PATH else 'M'}\0{path}\0" for path in paths)
                    def git(*args):
                        if args[0] == "diff":
                            return raw
                        if args[0] == "show":
                            revision, path = args[1].split(":", 1)
                            return valid_editor[path][0 if revision == base else 1]
                        return self.sha
                    with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                        self.assertEqual(planner.runtime_scope(paths, {}, self.env),
                                         scope.REVIEWED_MEMORY_FAMILY_SCOPE if allowed else scope.FULL_SCOPE)
        self.assertNotIn(scope.FAMILY_PRESENTATION_PATH, scope.REVIEWABLE_MEMORY_PATHS)
        self.assertNotIn(scope.PAIRING_EXPLANATION_PATH, scope.REVIEWABLE_APP_PATHS)
        self.assertNotIn(scope.LOCAL_EDITOR_PATH, scope.REVIEWABLE_MEMORY_PATHS)
        self.assertNotIn(scope.LOCAL_EDITOR_PATH, scope.REVIEWABLE_APP_PATHS)

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
            with self.assertRaises(ValueError):
                planner.find_evidence(self.env, planner.FULL, self.api, self.now)

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
        with self.assertRaises(ValueError):
            planner.find_evidence(self.env, planner.FULL, api, self.now)

    def test_evidence_lookup_failure_stops_before_authorizing_mac_jobs(self):
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
                    with self.assertRaises(SystemExit):
                        planner.main()
                    self.assertEqual((root / "output").read_text(), "")
            # A complete lookup that finds no eligible evidence still runs
            # every required job; lookup failure must not impersonate this.
            with patch.dict(os.environ, env), \
                    patch.object(planner, "changed_paths", side_effect=ValueError), \
                    patch.object(planner, "find_evidence", return_value=None):
                planner.main()
                outputs = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual(outputs, {"build": "true", "build_name": planner.BUILD, "smoke": "true", "sharing": "true",
                    "smoke_name": planner.SMOKE, "app_ui": "true", "matrix_parallelism": "2",
                    "runtime_scope": scope.FULL_SCOPE,
                    "lanes": json.dumps(scope.LANES, separators=(",", ":")),
                    "matrix_lanes": '["runtime","gallery-normal","gallery-white","gallery-no-caption"]'})

    def test_same_sha_lookup_does_not_depend_on_unrelated_old_candidate_api(self):
        calls = []
        def api(path):
            calls.append(path)
            if "/workflows/" in path:
                self.assertIn("head_sha=" + self.sha, path)
                return {"workflow_runs": [dict(self.run, id=9, head_sha="b" * 40), self.run]}
            return self.api(path)
        self.assertEqual(planner.find_evidence(self.env, planner.FULL, api, self.now), (10, self.sha))
        self.assertFalse(any("/runs/9/" in path for path in calls))

    def test_unavailable_candidate_does_not_hide_another_verified_candidate(self):
        def api(path):
            if "/workflows/" in path:
                return {"workflow_runs": [dict(self.run, id=11), self.run]}
            if "/runs/11/jobs" in path:
                raise OSError("private error body")
            return self.api(path)
        output = io.StringIO()
        with patch("sys.stdout", output):
            self.assertEqual(planner.find_evidence(self.env, planner.FULL, api, self.now), (10, self.sha))
        self.assertIn('"stage":"candidate_unavailable"', output.getvalue())
        self.assertIn('"stage":"evidence_selected"', output.getvalue())
        self.assertNotIn("private error body", output.getvalue())

    def test_evidence_api_logs_status_without_credentials_or_response_bodies(self):
        path = "/repos/owner/repo/actions/runs/20"
        env = dict(self.env, GH_TOKEN="private-token")
        for error in (urllib.error.HTTPError("https://private.invalid/private-token", 403,
                                            "private response body", {}, None),
                      TimeoutError("private-token"), ValueError("private response body")):
            output = io.StringIO()
            with self.subTest(error=type(error).__name__), patch("sys.stdout", output), \
                    patch.object(planner.urllib.request, "urlopen", side_effect=error):
                with self.assertRaises(ValueError):
                    planner.github_api(env, path)
            self.assertIn('"stage":"api_error"', output.getvalue())
            self.assertNotIn("private-token", output.getvalue())
            self.assertNotIn("private response body", output.getvalue())
            if isinstance(error, urllib.error.HTTPError):
                self.assertIn('"status":403', output.getvalue())
        response = io.BytesIO(b'{"id":20}'); response.status = 200
        with patch("sys.stdout", io.StringIO()) as output, \
                patch.object(planner.urllib.request, "urlopen", return_value=response):
            self.assertEqual(planner.github_api(env, path), {"id": 20})
        self.assertIn('"stage":"api_complete"', output.getvalue())

    def test_diagnosis_never_writes_release_plan_or_job_outputs(self):
        current = dict(self.current, event="push", head_branch="main",
                       repository={"full_name": "owner/repo"}, path=".github/workflows/ios-build.yml")
        output = io.StringIO()
        with patch.dict(os.environ, self.env), patch("sys.stdout", output), \
                patch.object(planner, "github_api", return_value=current), \
                patch.object(planner, "find_evidence", return_value=(10, self.sha)) as find:
            planner.diagnose_reuse(20, scope.FULL_SCOPE)
        self.assertEqual(find.call_args.args[0]["GITHUB_SHA"], self.sha)
        self.assertIn('"release_evidence":false', output.getvalue())
        self.assertNotIn("IOS_CI_PLAN_JSON", output.getvalue())
        with patch.dict(os.environ, self.env), \
                patch.object(planner, "github_api", return_value=dict(current, head_branch="codex/other")), \
                patch.object(planner, "find_evidence") as find:
            with self.assertRaises(ValueError):
                planner.diagnose_reuse(20, scope.FULL_SCOPE)
            find.assert_not_called()

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
                    if "/workflows/" in path and "head_sha=" in path:
                        return {"workflow_runs": []}
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
