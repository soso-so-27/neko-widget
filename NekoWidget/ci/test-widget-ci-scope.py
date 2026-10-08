#!/usr/bin/env python3
"""Widget-specific test selection and evidence boundaries; no network or CI run."""

import copy
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import ios_ci_scope as scope


spec = importlib.util.spec_from_file_location("widget_scope_planner", Path(__file__).with_name("plan-ios-ci.py"))
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)

ROOT = Path(__file__).resolve().parents[2]


class MembershipStateNativeBoundaryTests(unittest.TestCase):
    def test_exact_owning_operations_keep_build_photos_and_both_os_runtime(self):
        selected = scope.REVIEWED_MEMBERSHIP_STATE_SCOPE
        self.assertIn(selected, scope.SCOPES)
        expected = tuple("NekoWidgetUITests/SoloMemoriesUITests/" + method for method in (
            "testMembershipOfferPreviewReturnsToPurpose",
            "testMembershipOfferPreviewWaitingAndRestore",
            "testMembershipOfferExplainsExpiryWithoutChangingThePlan",
            "testMembershipAccessPreservesExistingMemoAndDistinguishesUnknown",
        )) + ("NekoWidgetUITests/MomentDeliveryComposerUITests/"
              "testWindowSupportResumeRequiresApprovalAndKeepsUnknownSeparate",)
        self.assertEqual(scope.native_tests(selected), expected)
        self.assertEqual(scope.lane_tests(selected, "app-ui"), expected)
        self.assertEqual(scope.lanes(selected), ("runtime", "app-ui"))
        self.assertEqual(scope.matrix_lanes(selected), ("runtime",))
        self.assertEqual(scope.app_ui_lanes(selected), ("app-ui",))
        self.assertEqual(scope.smoke_tests(selected), (
            "NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",
            "NekoWidgetUITests/PhotoPermissionUITests/testMainlineAcceptanceScreensWithAuthorizedLibrary",
        ))
        required = planner.required_jobs_from_scope(selected)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE,
            scope.lane_job(selected, "runtime"), scope.lane_job(selected, "app-ui")))
        # The unchanged runtime lane still executes the existing two-OS matrix.
        self.assertEqual(scope.SHARING_JOB_PREFIX, "Sharing runtime self-test (iOS 18.5 / 26.2)")
        source = (ROOT / scope.MEMORY_TEST_PATH).read_text(encoding="utf-8")
        self.assertTrue(scope.memory_tests_available(source, expected))
        for lane in ("gallery-normal", "gallery-variants", "app-ui-solo-1", "app-ui-other"):
            with self.assertRaises(ValueError): scope.lane_tests(selected, lane)

    def test_exact_paths_reject_partial_or_shared_and_keep_old_scope_inventory(self):
        selected = scope.REVIEWED_MEMBERSHIP_STATE_SCOPE
        self.assertEqual(scope.MEMBERSHIP_STATE_PATHS, frozenset({
            "NekoWidget/NekoWidget/App/NekoWidgetApp.swift",
            "NekoWidget/NekoWidget/Services/PlusPurchaseStore.swift",
            "NekoWidget/NekoWidget/Services/MembershipOfferModel.swift",
            "NekoWidget/NekoWidget/Views/MembershipOfferView.swift",
            "NekoWidget/NekoWidget/Views/WindowSupportResumeView.swift",
            "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift",
            "NekoWidget/ci/test-plus-purchase-foundation.py",
        }))
        paths = scope.MEMBERSHIP_STATE_PATHS | scope.MEMBERSHIP_STATE_COMPANIONS
        self.assertTrue(scope.accepts_paths(selected, paths))
        self.assertTrue(scope.accepts_paths(selected, scope.MEMBERSHIP_STATE_PATHS))
        self.assertTrue(scope.accepts_paths(selected, paths | {"handoffs/member.md"}))
        for path in paths:
            self.assertFalse(scope.accepts_paths(selected, paths - {path}), path)
            self.assertEqual(planner.required_jobs(sorted(paths - {path}), selected), planner.FULL)
        for extra in ("NekoWidget/Shared/MembershipAccessPolicy.swift", "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                      "NekoWidget/NekoWidget.xcodeproj/project.pbxproj", scope.CI_WORKFLOW):
            self.assertFalse(scope.accepts_paths(selected, paths | {extra}))
            self.assertEqual(planner.required_jobs(sorted(paths | {extra}), selected), planner.FULL)
        self.assertFalse(scope.accepts_paths(selected, None))
        self.assertFalse(scope.accepts_paths(selected, []))
        self.assertEqual(len(scope.native_tests(scope.BILLING_LOCAL_PREPARATION_SCOPE)), 3)
        self.assertEqual(scope.lanes(scope.REVIEWED_MEMBERSHIP_OFFER_SCOPE), ("runtime", "app-ui"))
        self.assertNotIn(scope.GALLERY_TEST, scope.native_tests(selected))

    def test_release_evidence_requires_all_four_successful_same_sha_jobs(self):
        selected, sha = scope.REVIEWED_MEMBERSHIP_STATE_SCOPE, "a" * 40
        required = planner.required_jobs_from_scope(selected)
        jobs = [{"name": name, "head_sha": sha, "status": "completed", "conclusion": "success"} for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, sha))
        self.assertFalse(planner.covers_jobs(jobs, planner.FULL, sha))
        self.assertFalse(planner.covers_jobs(jobs, required, "b" * 40))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, sha))
            for conclusion in ("failure", "skipped", "cancelled", None):
                changed = copy.deepcopy(jobs); changed[index]["conclusion"] = conclusion
                self.assertFalse(planner.covers_jobs(changed, required, sha), (index, conclusion))
        old = planner.required_jobs_from_scope(scope.REVIEWED_MEMBERSHIP_OFFER_SCOPE)
        old_jobs = [{"name": name, "head_sha": sha, "status": "completed", "conclusion": "success"} for name in old]
        self.assertFalse(planner.covers_jobs(old_jobs, required, sha))


class PrivateAppDataGalleryBoundaryTests(unittest.TestCase):
    """Replay the shipped incident, with no Xcode, CI, network or new release."""

    @classmethod
    def setUpClass(cls):
        cls.base = "58ce6d9688c160384607d03d8ff3d357cdc45216"
        cls.head = "a06d30432900e8b27709046d0a6c53250d2cc736"
        cls.paths = [path for path in planner.git("diff", "--name-only", "--no-renames", "-z", cls.base, cls.head).split("\0") if path]
        cls.raw = planner.git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", cls.base, cls.head)
        records = cls.raw.split("\0")
        cls.added = {records[i + 1] for i in range(0, len(records) - 1, 2) if records[i].split()[4] == "A"}
        cls.changes = {path: ("" if path in cls.added else planner.git("show", f"{cls.base}:{path}"),
                              planner.git("show", f"{cls.head}:{path}"))
                       for path in cls.paths if not scope.is_handoff(path)}
        cls.project = cls.changes[scope.APP_DATA_PROJECT][1]

    def replay(self, raw=None):
        original_git = planner.git
        def git(*args):
            return raw if args[0] == "diff" and raw is not None else original_git(*args)
        with patch.object(planner, "comparison_base", return_value=self.base), patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(self.paths, {}, {"GITHUB_SHA": self.head})

    def test_actual_weight_and_veterinary_batch_omits_only_gallery(self):
        self.assertEqual(self.replay(), scope.APP_DATA_SCOPE)
        self.assertEqual(scope.select_scope(self.changes), scope.APP_DATA_SCOPE)
        required = planner.required_jobs(self.paths, scope.APP_DATA_SCOPE)
        self.assertEqual(len(required), 6)
        self.assertEqual(required[:2], (planner.BUILD, planner.SMOKE))
        self.assertEqual(scope.lanes(scope.APP_DATA_SCOPE),
                         ("runtime", "app-ui-solo-1", "app-ui-solo-2", "app-ui-other"))
        self.assertEqual(scope.native_tests(scope.APP_DATA_SCOPE),
                         tuple(test for test in scope.native_tests(scope.FULL_SCOPE) if test != scope.GALLERY_TEST))
        self.assertEqual(scope.smoke_tests(scope.APP_DATA_SCOPE), scope.smoke_tests(scope.FULL_SCOPE))
        for lane in scope.LANES[2:]:
            with self.assertRaises(ValueError):
                scope.lane_tests(scope.APP_DATA_SCOPE, lane)

    def test_billing_local_preparation_requires_exact_review_and_project_proof(self):
        expected_products = {
            "NekoWidget/NekoWidget/Services/BillingFreshAccountAuthorization.swift",
            "NekoWidget/NekoWidget/Services/BillingKeychainStore.swift",
            "NekoWidget/NekoWidget/Services/MembershipOfferModel.swift",
        }
        self.assertEqual(scope.BILLING_LOCAL_PREPARATION_PRODUCTS, expected_products)
        self.assertEqual(set(scope.BILLING_LOCAL_PREPARATION_DIGESTS), expected_products | {
            scope.MEMORY_TEST_PATH, "NekoWidget/ci/test-billing-client-foundation.py"})
        changes = {path: ("old " + path, "new " + path)
                   for path in scope.BILLING_LOCAL_PREPARATION_DIGESTS}
        self.assertFalse(scope.app_data_changes(changes, project_source=self.project))
        digests = {path: tuple(map(scope.source_digest, pair)) for path, pair in changes.items()}
        with patch.object(scope, "BILLING_LOCAL_PREPARATION_DIGESTS", digests):
            self.assertFalse(scope.app_data_changes(changes))
            self.assertTrue(scope.app_data_changes(changes, project_source=self.project))
            for path in changes:
                modified = dict(changes)
                modified[path] = (modified[path][0], modified[path][1] + " unreviewed")
                self.assertFalse(scope.app_data_changes(modified, project_source=self.project))
                missing = {key: value for key, value in changes.items() if key != path}
                self.assertFalse(scope.app_data_changes(missing, project_source=self.project))
            for path in ("NekoWidget/Shared/MembershipAccessPolicy.swift",
                         "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                         "NekoWidget/NekoWidget/Services/ManagedPreservationClient.swift"):
                self.assertFalse(scope.app_data_changes(changes | {path: ("old", "new")}, project_source=self.project))
        # Existing app-data jobs still retain all product boundary checks;
        # this change does not alter tests, execution commands or release gates.
        required = planner.required_jobs_from_scope(scope.APP_DATA_SCOPE)
        self.assertIn(planner.BUILD, required)
        self.assertIn(planner.SMOKE, required)
        self.assertEqual(scope.lanes(scope.APP_DATA_SCOPE),
                         ("runtime", "app-ui-solo-1", "app-ui-solo-2", "app-ui-other"))

    def test_exact_billing_preparation_requires_all_three_owning_operations(self):
        selected = scope.BILLING_LOCAL_PREPARATION_SCOPE
        self.assertIn(selected, scope.SCOPES)
        self.assertEqual(scope.lanes(selected), ("runtime", "app-ui"))
        self.assertEqual(scope.native_tests(selected), (
            "NekoWidgetUITests/SoloMemoriesUITests/testMembershipOfferPreviewReturnsToPurpose",
            "NekoWidgetUITests/SoloMemoriesUITests/testMembershipOfferPreviewWaitingAndRestore",
            "NekoWidgetUITests/SoloMemoriesUITests/testMembershipOfferExplainsExpiryWithoutChangingThePlan",
        ))
        required = planner.required_jobs_from_scope(selected)
        self.assertEqual(set(required), {planner.BUILD, planner.BOOTSTRAP_SMOKE,
            scope.lane_job(selected, "runtime"), scope.lane_job(selected, "app-ui")})
        self.assertEqual(scope.smoke_tests(selected), scope.smoke_tests(scope.REVIEWED_MEMBERSHIP_OFFER_SCOPE))
        paths = set(scope.BILLING_LOCAL_PREPARATION_DIGESTS)
        self.assertTrue(scope.accepts_paths(selected, paths))
        for path in paths:
            self.assertFalse(scope.accepts_paths(selected, paths - {path}))
        self.assertFalse(scope.accepts_paths(selected, paths | {"NekoWidget/Shared/MembershipAccessPolicy.swift"}))
        for lane in ("app-ui-solo-1", "app-ui-other", "gallery", "gallery-variants", "gallery-normal"):
            with self.assertRaises(ValueError):
                scope.lane_tests(selected, lane)

    def test_later_private_store_edit_needs_project_proof_not_frozen_product_hashes(self):
        path = "NekoWidget/NekoWidget/Services/PhotoMemoryNoteStore.swift"
        changes = {path: (self.changes[path][1], self.changes[path][1] + "\n// private storage change\n")}
        self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
        self.assertEqual(scope.select_scope(changes, project_source=self.project), scope.APP_DATA_SCOPE)
        self.assertFalse(scope.app_data_changes(changes, project_source="unparseable project"))

    def test_render_cache_shared_model_startup_and_unknown_inputs_cannot_borrow_exclusion(self):
        for path in (
            "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
            "NekoWidget/Shared/Models/WidgetRenderPlan.swift",
            "NekoWidget/Shared/Storage/PersonalRediscoveryStore.swift",
            "NekoWidget/NekoWidget/Services/CanonicalPreviewBuilder.swift",
            "NekoWidget/NekoWidget/Services/WidgetCacheBuilder.swift",
            "NekoWidget/NekoWidget/Services/PersonalWidgetBackgroundRefresh.swift",
            "NekoWidget/NekoWidget/App/NekoWidgetApp.swift",
            "NekoWidget/NekoWidget/Services/AppStoreScreenshotFixture.swift",
            "NekoWidget/NekoWidget/Services/NewPrivateStore.swift",
            "NekoWidget/NekoWidgetUITests/WidgetPlacementScreenshotUITests.swift",
            "NekoWidget/ci/run-sharing-runtime-matrix.sh", ".github/workflows/testflight.yml",
        ):
            with self.subTest(path=path):
                self.assertEqual(scope.select_scope(self.changes | {path: ("before", "after")}), scope.FULL_SCOPE)

    def test_app_registration_does_not_allow_widget_settings_aliases_or_framework_changes(self):
        before, after = self.changes[scope.APP_DATA_PROJECT]
        self.assertTrue(scope.app_data_project_unchanged(before, after))
        for changed in (
            after.replace('SWIFT_VERSION = 5.0', 'SWIFT_VERSION = 6.0', 1),
            after.replace('isa = PBXFrameworksBuildPhase', 'isa = ChangedFrameworksBuildPhase', 1),
            after.replace('fileRef = F00000000000000000000314', 'fileRef = D02609300000000000000002', 1),
            after.replace('path = VeterinaryVisitView.swift', 'path = NekoWidgetView.swift', 1),
            after.replace('A00000000000000000000025 /* Sources */ = {',
                          'A00000000000000000000025 /* Sources */ = {\n// unreviewed registration'),
        ):
            self.assertNotEqual(after, changed)
            self.assertFalse(scope.app_data_project_unchanged(before, changed))
            changes = self.changes | {scope.APP_DATA_PROJECT: (before, changed)}
            self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)

    def test_widget_membership_is_resolved_from_ids_not_filename_comments(self):
        path = "NekoWidget/NekoWidget/Services/PhotoMemoryNoteStore.swift"
        changes = {path: self.changes[path]}
        # Keep the misleading Widget-view comment, point the build entry at a
        # private store. Gallery must run even when the comment was not edited.
        changed = self.project.replace('fileRef = F00000000000000000000314',
                                       'fileRef = D02609300000000000000002', 1)
        self.assertNotEqual(self.project, changed)
        self.assertEqual(scope.select_scope(changes, project_source=changed), scope.FULL_SCOPE)

    def test_workflow_exception_is_additive_model_check_only(self):
        before, after = self.changes[scope.CI_WORKFLOW]
        for changed in (after.replace('contents: read', 'contents: write', 1),
                        after.replace('ci/verify-photo-memory-notes.swift', 'ci/unreviewed.swift', 1),
                        after.replace(scope.APP_DATA_MODEL_CHECK, ''),
                        after + '\n# other workflow change\n'):
            self.assertFalse(scope.app_data_changes(self.changes | {scope.CI_WORKFLOW: (before, changed)}))
        diagnostic = self.changes[scope.APP_DATA_DIAGNOSTIC][1]
        self.assertFalse(scope.app_data_changes(self.changes | {scope.APP_DATA_DIAGNOSTIC: ('', diagnostic + '\n# changed\n')}))

    def test_raw_modes_additions_deletions_and_hidden_extra_files_fail_closed(self):
        records = self.raw.split("\0")
        for i in range(0, len(records) - 1, 2):
            path = records[i + 1]
            if scope.is_handoff(path):
                continue
            for modes, status in ((":100644 100755", "M"), (":100644 120000", "T"),
                                  (":100644 000000", "D"), (":100644 100644", "R100")):
                changed = list(records)
                fields = changed[i].split()
                changed[i] = f"{modes} {fields[2]} {fields[3]} {status}"
                with self.subTest(path=path, modes=modes, status=status):
                    self.assertEqual(self.replay("\0".join(changed)), scope.FULL_SCOPE)
        extra = f":100644 100644 {'c' * 40} {'d' * 40} M\0unreported.swift\0"
        self.assertEqual(self.replay(self.raw + extra), scope.FULL_SCOPE)

    def test_limited_success_does_not_cover_full_or_skipped_storage_build_checks(self):
        required = planner.required_jobs_from_scope(scope.APP_DATA_SCOPE)
        jobs = [dict(name=name, head_sha=self.head, status="completed", conclusion="success") for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, self.head))
        self.assertFalse(planner.covers_jobs(jobs, planner.FULL, self.head))
        for index in range(len(jobs)):
            for conclusion in ("skipped", "failure", "cancelled"):
                changed = copy.deepcopy(jobs); changed[index]["conclusion"] = conclusion
                self.assertFalse(planner.covers_jobs(changed, required, self.head))


class DiagnosticRouteBoundaryTests(unittest.TestCase):
    def test_window_diagnostic_selects_only_existing_requested_methods(self):
        source = (ROOT / "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift").read_text(encoding="utf-8")
        methods = ("testMixedWindowsKeepAdditionAndScopedRecoveryReachable",
                   "testDiscoverReceiveGuideAndStopUpdatesWindowList",
                   "testWindowListLargeTextKeepsDiscoveryAndPhotoReachable")
        self.assertEqual(scope.diagnostic_tests("OfficialWindowUITests", ",".join(methods), source),
                         tuple("NekoWidgetUITests/OfficialWindowUITests/" + name for name in methods))
        for names in ("testUnknownWindowMethod", ",".join(methods + (methods[0],)), methods[0] + ";exit 0"):
            with self.assertRaises(ValueError):
                scope.diagnostic_tests("OfficialWindowUITests", names, source)

    def test_exact_diagnostic_addition_preserves_regular_commands(self):
        path = scope.CI_DIAGNOSTIC_MATRIX
        current = (ROOT / path).read_text(encoding="utf-8")
        pattern = r"(?m)^# BEGIN DIAGNOSTIC-ONLY [^\n]+\n[\s\S]*?^# END DIAGNOSTIC-ONLY [^\n]+\n"
        previous = re.sub(pattern, "", current)
        self.assertNotEqual(previous, current)
        self.assertTrue(scope.ci_selection_only({path: (previous, current)}))
        for changed in (current.replace('!= "workflow_dispatch"', '== "workflow_dispatch"'),
                        current.replace('CODE_SIGN_IDENTITY=-', 'CODE_SIGN_IDENTITY=modified')):
            self.assertNotEqual(current, changed)
            self.assertFalse(scope.ci_selection_only({path: (previous, changed)}))

    def test_diagnostic_workflow_is_exact_and_never_release_evidence(self):
        path = scope.CI_DIAGNOSTIC_WORKFLOW
        current = (ROOT / path).read_text(encoding="utf-8")
        self.assertTrue(scope.ci_selection_only({path: ("", current)}))
        self.assertFalse(scope.ci_selection_only({path: ("", current.replace('contents: read', 'contents: write'))}))
        with self.assertRaises(ValueError):
            planner.required_jobs_from_scope("diagnostic")

    def test_only_diagnostic_push_exclusion_is_normalized(self):
        current = (ROOT / scope.CI_WORKFLOW).read_text(encoding="utf-8")
        previous = current.replace('    # Manual diagnostic runs use a separate workflow and are not release evidence.\n'
                                   '    branches-ignore:\n      - "diagnostic/**"\n', '')
        self.assertNotEqual(current, previous)
        self.assertEqual(scope.workflow_execution(previous), scope.workflow_execution(current))
        self.assertNotEqual(scope.workflow_execution(previous), scope.workflow_execution(current.replace('"diagnostic/**"', '"**"')))

WIDGET = "NekoWidget/NekoWidgetWidget/"
BEHAVIOR_PATHS = frozenset(WIDGET + name for name in (
    "NekoWidgetEntry.swift", "NekoWidgetTimelineProvider.swift", "WidgetManifestReader.swift",
    "DailyPersonalPhotoIntent.swift", "ToggleWidgetLikeIntent.swift", "NekoWidgetConfigurationIntent.swift",
)) | {
    "NekoWidget/Shared/Storage/PersonalRediscoveryStore.swift",
    "NekoWidget/NekoWidget/Views/PersonalRediscoveryHistoryView.swift",
    "NekoWidget/NekoWidget/Services/PersonalWidgetBackgroundRefresh.swift",
}
LAYOUT_PATHS = frozenset(WIDGET + name for name in ("NekoWidgetView.swift", "WidgetCacheImageLoader.swift"))
UI_TESTS = frozenset("NekoWidgetUITests/" + identifier for identifier in (
    "OfficialWindowUITests/testWidgetURLsColdOpenPhotoBeforeSourceResolvesAndCloseOnce",
    "OfficialWindowUITests/testWidgetURLsActiveAppReplacesPhotosAndRestoresPresentations",
    "OfficialWindowUITests/testWidgetURLsMissingPhotoNeverSubstituteAvailableFixturePhoto",
    "PersonalRediscoveryUITests/testDailyTurnKeepsYesterdayAndPreviousPhotoWithExistingPhotoActions",
    "PersonalRediscoveryUITests/testOneCandidateShowsPhotoWithoutSpendingADailyTurn",
    "SoloMemoriesUITests/testWidgetPhotoOutsideCurrentScopeOffersAPathBack",
    "MomentDeliveryComposerUITests/testReceivedProductControlsBindRequestsAndPendingStateToTheVisiblePhoto",
))
CHANGE = ("return currentPhoto\n", "return nextPhoto\n")


class WidgetScopeTests(unittest.TestCase):
    @staticmethod
    def photo_source_check_blocks():
        pairs = (
            ('accessibilityIdentifier("albums-favorites")', 'accessibilityIdentifier("saved-memories-gallery")'),
            (r'accessibilityLabel("お気に入り、\(photos.count.formatted())枚")',
             r'accessibilityValue("お気に入り、\(photos.count.formatted())枚")'),
        )
        target = "            NekoWidget/Views/LikedPhotosView.swift\n"
        return [(old, new, f"\n          grep -Fq '{old}' \\\n" + target,
                 "\n          grep -Fq \\\n" + f"            -e '{old}' \\\n"
                 + f"            -e '{new}' \\\n" + target) for old, new in pairs]

    @classmethod
    def photo_source_check_workflow_fixture(cls):
        # Freeze the historical grep contract independently of the live workflow.
        # The new helper checker is a different execution change, tested below.
        return ("name: Historical photo source checks\n"
                "permissions:\n  contents: read\n"
                "jobs:\n  build:\n    steps:\n"
                "      - name: Check photo source\n        run: |\n"
                "          set -euo pipefail\n"
                + "".join(compatible for _, _, _, compatible in cls.photo_source_check_blocks())
                + "\n          grep -Fq 'LikedPhotoOrderingPolicy.comesBefore(' \\\n"
                  "            NekoWidget/App/AppRootView.swift\n")

    def test_exact_photo_source_check_upgrade_keeps_ci_selection_and_required_jobs(self):
        workflow = self.photo_source_check_workflow_fixture()
        legacy = workflow
        for _, _, old, compatible in self.photo_source_check_blocks():
            self.assertEqual(workflow.count(compatible), 1)
            legacy = legacy.replace(compatible, old)
        self.assertNotEqual(legacy, workflow)
        changes = {scope.CI_WORKFLOW: (legacy, workflow)}
        selected = scope.select_scope(changes)
        self.assertEqual(selected, scope.CI_SELECTION_SCOPE)
        self.assertEqual(planner.required_jobs(list(changes), selected),
                         planner.required_jobs_from_scope(scope.CI_SELECTION_SCOPE))
        self.assertEqual(scope.lanes(selected), ("runtime", "app-ui", "gallery-normal"))
        self.assertEqual(set(scope.lane_tests(selected, "app-ui")), UI_TESTS)
        self.assertIn(planner.BUILD, planner.required_jobs_from_scope(selected))
        self.assertIn(planner.BOOTSTRAP_SMOKE, planner.required_jobs_from_scope(selected))
        # A product change cannot borrow the CI-only exception.
        self.assertEqual(scope.select_scope(dict(changes, **{
            "NekoWidget/NekoWidget/Views/LikedPhotosView.swift": CHANGE})), scope.FULL_SCOPE)

    def test_photo_source_check_exception_rejects_removed_alternatives_and_unrelated_commands(self):
        workflow = self.photo_source_check_workflow_fixture()
        for old, new, legacy, compatible in self.photo_source_check_blocks():
            self.assertEqual(workflow.count(compatible), 1)
            variants = (
                legacy, legacy.replace(old, new),  # Neither one-sided rollback is equivalent.
                compatible.replace("Views/LikedPhotosView.swift", "Views/HomeView.swift"),
                compatible.replace("grep -Fq", "grep -Fqv"),
                compatible.replace(new, 'accessibilityIdentifier("unknown")'),
                compatible.rstrip("\n") + " || true\n",
                compatible + compatible,
                "\n",
            )
            for replacement in variants:
                with self.subTest(replacement=replacement):
                    changed = workflow.replace(compatible, replacement)
                    self.assertNotEqual(changed, workflow)
                    self.assertEqual(scope.select_scope({scope.CI_WORKFLOW: (workflow, changed)}),
                                     scope.FULL_SCOPE)
                    before = workflow.replace(compatible, legacy)
                    self.assertNotEqual(before, workflow)
                    # A different command/path may not hitchhike on an upgrade.
                    if replacement != legacy:
                        self.assertNotEqual(before, changed)
                        self.assertEqual(scope.select_scope({scope.CI_WORKFLOW: (before, changed)}),
                                         scope.FULL_SCOPE)
        changed = workflow.replace('grep -Fq', 'grep -Fqv', 1)
        self.assertNotEqual(changed, workflow)
        self.assertEqual(scope.select_scope({scope.CI_WORKFLOW: (workflow, changed)}), scope.FULL_SCOPE)

    def test_new_photo_source_helper_checker_requires_full_scope(self):
        workflow = (ROOT / scope.CI_WORKFLOW).read_text(encoding="utf-8")
        pattern = (r"(?m)\n          # Favorites accessibility normal/recovery contract\n"
                   r"          python3 - <<'PY'\n[\s\S]*?^          PY\n")
        checkers = re.findall(pattern, workflow)
        self.assertEqual(len(checkers), 1)
        compatible = self.photo_source_check_blocks()[1][3]
        self.assertNotIn(compatible, workflow)
        previous = workflow.replace(checkers[0], compatible, 1)
        self.assertNotEqual(previous, workflow)
        self.assertEqual(previous.count(compatible), 1)
        changes = {scope.CI_WORKFLOW: (previous, workflow)}
        self.assertFalse(scope.ci_selection_only(changes))
        self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
        self.assertEqual(planner.required_jobs(list(changes), scope.FULL_SCOPE), planner.FULL)

    def test_compatible_source_checks_accept_old_or_new_but_not_missing_values(self):
        git_bash = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe"
        bash = str(git_bash) if os.name == "nt" and git_bash.is_file() else shutil.which("bash")
        self.assertIsNotNone(bash)
        with tempfile.TemporaryDirectory(prefix="neko-photo-source-") as directory:
            target = Path(directory) / "NekoWidget/Views/LikedPhotosView.swift"
            target.parent.mkdir(parents=True)
            for old, new, _, compatible in self.photo_source_check_blocks():
                for value, expected in ((old, 0), (new, 0), ("unrelated", 1)):
                    with self.subTest(value=value):
                        target.write_text(value + "\n", encoding="utf-8")
                        result = subprocess.run([bash, "-c", compatible.strip()], cwd=directory,
                                                capture_output=True, timeout=10)
                        self.assertEqual(result.returncode, expected, result.stderr)

    def widget_scopes(self):
        return (scope.WIDGET_BEHAVIOR_SCOPE, scope.WIDGET_LAYOUT_SCOPE, scope.WIDGET_STYLE_SCOPE,
                scope.CI_SELECTION_SCOPE)

    def test_ci_selection_requires_unchanged_build_security_and_smoke_execution(self):
        workflow = (ROOT / scope.CI_WORKFLOW).read_text(encoding="utf-8")
        previous = workflow.replace(
            "      max-parallel: ${{ fromJSON(needs.plan.outputs.matrix_parallelism) }}",
            "      max-parallel: 2")
        self.assertEqual(scope.select_scope({scope.CI_WORKFLOW: (previous, workflow)}), scope.CI_SELECTION_SCOPE)
        for before, after in (("contents: read", "contents: write"),
                              ("CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_ALLOWED=YES"),
                              ("ci/verify-personal-rediscovery.swift", "ci/skip-check.swift")):
            self.assertIn(before, workflow)
            self.assertEqual(scope.select_scope({scope.CI_WORKFLOW: (workflow, workflow.replace(before, after))}),
                             scope.FULL_SCOPE)
        smoke = (ROOT / scope.CI_SMOKE_SCRIPT).read_text(encoding="utf-8")
        original = re.sub(r"# BEGIN CI_SMOKE_SELECTION[\s\S]*?# END CI_SMOKE_SELECTION", "", smoke)
        original = original.replace('    "${SMOKE_TEST_ARGUMENTS[@]}" \\',
            '    -only-testing:NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess \\\n'
            '    -only-testing:NekoWidgetUITests/OfficialWindowUITests \\\n'
            '    -only-testing:NekoWidgetUITests/PersonalRediscoveryUITests \\')
        self.assertEqual(scope.select_scope({scope.CI_SMOKE_SCRIPT: (original, smoke)}), scope.CI_SELECTION_SCOPE)
        altered = smoke.replace("PERMISSION_TEST_STATUS=0", "PERMISSION_TEST_STATUS=1")
        self.assertNotEqual(altered, smoke)
        self.assertEqual(scope.select_scope({scope.CI_SMOKE_SCRIPT: (smoke, altered)}), scope.FULL_SCOPE)
        self.assertEqual(scope.select_scope({scope.CI_WORKFLOW: (previous, workflow), WIDGET + "DailyPersonalPhotoIntent.swift": CHANGE}),
                         scope.FULL_SCOPE)

    def test_ci_python_regressions_need_no_native_checks_or_current_main_ancestor(self):
        sha = "a" * 40
        env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/codex/ci", "GITHUB_SHA": sha}
        new_test = "NekoWidget/ci/test-widget-ci-scope.py"
        def git(*args):
            if args[:1] == ("diff",):
                return f":000000 100644 {'0' * 40} {'b' * 40} A\0{new_test}\0"
            if args[:1] == ("show",):
                self.assertEqual(args[1], f"{sha}:{new_test}")
                return "# named selector regression test\n"
            return sha
        with patch.object(planner, "git", side_effect=git) as calls:
            self.assertEqual(planner.runtime_scope([new_test], {}, env), planner.ORCHESTRATION_SCOPE)
        def stale(*args):
            if args[:2] == ("merge-base", "--is-ancestor"):
                raise subprocess.CalledProcessError(1, "git")
            return git(*args)
        with patch.object(planner, "git", side_effect=stale):
            self.assertEqual(planner.runtime_scope([new_test], {}, env), planner.ORCHESTRATION_SCOPE)
        self.assertEqual(scope.select_scope({"NekoWidget/ci/unreviewed-new-test.py": ("", "new")}), scope.FULL_SCOPE)

    def jobs(self, names):
        return [{"name": name, "head_sha": "a" * 40, "status": "completed", "conclusion": "success",
                 "completed_at": "2026-09-14T01:00:00Z"} for name in names]

    def test_reviewed_paths_exist_and_behavior_changes_select_their_scope(self):
        # Exact sets make expansion of the trusted allowlist an explicit review.
        self.assertEqual(scope.WIDGET_BEHAVIOR_PATHS, BEHAVIOR_PATHS)
        self.assertEqual(scope.WIDGET_LAYOUT_PATHS, LAYOUT_PATHS)
        for paths, selected in ((BEHAVIOR_PATHS, scope.WIDGET_BEHAVIOR_SCOPE),
                                (LAYOUT_PATHS, scope.WIDGET_LAYOUT_SCOPE)):
            for path in paths:
                with self.subTest(path=path):
                    self.assertTrue((ROOT / path).is_file())
                    self.assertEqual(scope.select_scope({path: CHANGE}), selected)
                    self.assertEqual(planner.required_jobs([path], selected),
                                     planner.required_jobs_from_scope(selected))

    def test_literal_widget_style_does_not_include_interaction_or_fixture_changes(self):
        path = WIDGET + "NekoWidgetView.swift"
        for change in (("Text(\"Before\")", "Text(\"After\")"),
                       (".padding(.horizontal, 12)", ".padding(.horizontal, 16)")):
            with self.subTest(change=change):
                self.assertEqual(scope.select_scope({path: change}), scope.WIDGET_STYLE_SCOPE)
        for change in ((".disabled(true)", ".disabled(false)"),
                       ("Button(intent: previousIntent)", "Button(intent: nextIntent)")):
            self.assertEqual(scope.select_scope({path: change}), scope.WIDGET_LAYOUT_SCOPE)
        fixture = '#if DEBUG\nText("before")\n#endif\n'
        self.assertEqual(scope.select_scope({path: (fixture, fixture.replace("before", "after"))}),
                         scope.FULL_SCOPE)
        history = "NekoWidget/NekoWidget/Views/PersonalRediscoveryHistoryView.swift"
        self.assertEqual(scope.select_scope({history: ('Text("before")', 'Text("after")')}),
                         scope.WIDGET_BEHAVIOR_SCOPE)

    def test_common_unknown_ci_and_signing_paths_prevent_narrow_selection(self):
        widget = WIDGET + "DailyPersonalPhotoIntent.swift"
        for extra in (
            "NekoWidget/NekoWidget/App/AppViewModel.swift",
            "NekoWidget/NekoWidget/Views/MainTabView.swift",
            "NekoWidget/NekoWidget/Views/OnboardingView.swift",
            "NekoWidget/NekoWidget/Services/WidgetCacheBuilder.swift",
            "NekoWidget/NekoWidget/Services/MomentSharingCoordinator.swift",
            "NekoWidget/NekoWidget/Services/MomentSharingAPIClient.swift",
            "NekoWidget/Shared/Sharing/MomentSharingStore.swift",
            "NekoWidget/Shared/Storage/SharedLikeStore.swift",
            "NekoWidget/Shared/Models/WidgetRenderPlan.swift",
            "NekoWidget/Shared/Routing/DeepLink.swift",
            "NekoWidget/NekoWidget/Info.plist", "NekoWidget/NekoWidget/NekoWidget.entitlements",
            "NekoWidget/ci/ios_ci_scope.py", ".github/workflows/ios-build.yml", "unknown.swift",
        ):
            with self.subTest(extra=extra):
                changes = {widget: CHANGE, extra: CHANGE}
                self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
                self.assertEqual(planner.required_jobs(list(changes), scope.WIDGET_BEHAVIOR_SCOPE), planner.FULL)

    def test_attached_handoff_does_not_hide_source_or_create_its_own_scope(self):
        widget = WIDGET + "DailyPersonalPhotoIntent.swift"
        handoff = "handoffs/2026-09-14-widget-daily-heart.md"
        self.assertEqual(scope.select_scope({widget: CHANGE, handoff: ("before", "after")}),
                         scope.WIDGET_BEHAVIOR_SCOPE)
        self.assertEqual(scope.select_scope({handoff: ("before", "after")}), scope.FULL_SCOPE)
        self.assertEqual(scope.select_scope({widget: CHANGE, "docs/unknown.md": ("before", "after")}),
                         scope.FULL_SCOPE)

    def test_ui_selection_is_exact_and_methods_belong_to_real_test_classes(self):
        methods = {}
        for source in (ROOT / "NekoWidget/NekoWidgetUITests").glob("*.swift"):
            text = source.read_text(encoding="utf-8")
            classes = list(re.finditer(r"^\s*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase\b", text, re.MULTILINE))
            for index, match in enumerate(classes):
                end = classes[index + 1].start() if index + 1 < len(classes) else len(text)
                for method in re.findall(r"\bfunc\s+(test\w+)\s*\(", text[match.end():end]):
                    identifier = f"NekoWidgetUITests/{match.group(1)}/{method}"
                    methods[identifier] = methods.get(identifier, 0) + 1
        for selected in (scope.WIDGET_BEHAVIOR_SCOPE, scope.WIDGET_LAYOUT_SCOPE):
            selected_ui = scope.lane_tests(selected, "app-ui")
            self.assertEqual(len(selected_ui), 7)
            self.assertEqual(set(selected_ui), UI_TESTS)
            for identifier in selected_ui:
                self.assertEqual(methods.get(identifier), 1, identifier)
        # Full class selection must really include each limited method.
        full = tuple(test for lane in scope.app_ui_lanes(scope.FULL_SCOPE)
                     for test in scope.lane_tests(scope.FULL_SCOPE, lane))
        for identifier in UI_TESTS:
            self.assertTrue(any(identifier == item or identifier.startswith(item + "/") for item in full), identifier)

    def test_lane_selection_keeps_runtime_and_required_gallery_conditions(self):
        expected = {
            scope.WIDGET_BEHAVIOR_SCOPE: ("runtime", "app-ui", "gallery-normal"),
            scope.WIDGET_LAYOUT_SCOPE: ("runtime", "app-ui", "gallery-normal", "gallery-variants"),
            scope.WIDGET_STYLE_SCOPE: ("runtime", "gallery-normal", "gallery-variants"),
        }
        for selected, lanes in expected.items():
            with self.subTest(scope=selected):
                self.assertEqual(scope.lanes(selected), lanes)
                self.assertEqual(scope.matrix_lanes(selected), tuple(lane for lane in lanes if lane != "app-ui"))
                required = planner.required_jobs_from_scope(selected)
                self.assertIn(planner.BUILD, required)
                self.assertEqual(len(required), len(lanes) + 2)  # Build, real Photos smoke, and lanes.
                for lane in lanes:
                    self.assertIn(scope.lane_job(selected, lane), required)
                    if lane.startswith("gallery-"):
                        self.assertEqual(scope.lane_tests(selected, lane), scope.lane_tests(scope.FULL_SCOPE, lane))
        self.assertNotIn("app-ui", scope.lanes(scope.WIDGET_STYLE_SCOPE))

    def test_real_photos_smoke_remains_required_with_separate_execution_evidence(self):
        bootstrap = ("NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",
                     "NekoWidgetUITests/PhotoPermissionUITests/testMainlineAcceptanceScreensWithAuthorizedLibrary")
        sha = "a" * 40
        for selected in scope.SCOPES:
            required = planner.required_jobs_from_scope(selected)
            if selected == scope.ICON_SCOPE:
                self.assertEqual(required, (planner.ICON_BUILD,))
                continue
            self.assertIn(planner.smoke_job(selected), required)
            if selected not in (scope.FULL_SCOPE, scope.APP_VIEW_SCOPE, scope.APP_DATA_SCOPE):
                self.assertEqual(scope.smoke_tests(selected), bootstrap)
                self.assertEqual(planner.smoke_job(selected), planner.BOOTSTRAP_SMOKE)
        for selected in (scope.FULL_SCOPE, scope.APP_VIEW_SCOPE, scope.APP_DATA_SCOPE):
            self.assertEqual(scope.smoke_tests(selected),
                             bootstrap + scope.OFFICIAL_TESTS + ("NekoWidgetUITests/PersonalRediscoveryUITests",))
            self.assertEqual(planner.smoke_job(selected), planner.SMOKE)
        self.assertTrue(planner.covers_jobs(self.jobs([planner.SMOKE]), (planner.BOOTSTRAP_SMOKE,), sha))
        self.assertFalse(planner.covers_jobs(self.jobs([planner.BOOTSTRAP_SMOKE]), (planner.SMOKE,), sha))
        self.assertFalse(planner.covers_jobs(self.jobs([planner.SMOKE, planner.BOOTSTRAP_SMOKE]),
                                            (planner.BOOTSTRAP_SMOKE,), sha))

    def test_full_evidence_covers_only_the_corresponding_limited_lane(self):
        sha = "a" * 40
        full_jobs = self.jobs(planner.FULL)
        for selected in self.widget_scopes():
            required = planner.required_jobs_from_scope(selected)
            limited = self.jobs(required)
            self.assertTrue(planner.covers_jobs(limited, required, sha))
            self.assertTrue(planner.covers_jobs(full_jobs, required, sha))
            self.assertFalse(planner.covers_jobs(limited, planner.FULL, sha))
            for lane in scope.lanes(selected):
                with self.subTest(scope=selected, lane=lane):
                    limited_name = scope.lane_job(selected, lane)
                    full_names = ([scope.lane_job(scope.FULL_SCOPE, name)
                                   for name in scope.app_ui_lanes(scope.FULL_SCOPE)]
                                  if lane == "app-ui" else [scope.lane_job(scope.FULL_SCOPE, lane)])
                    self.assertTrue(planner.covers_jobs(self.jobs(full_names), (limited_name,), sha))
                    for other in scope.lanes(scope.FULL_SCOPE):
                        if scope.lane_job(scope.FULL_SCOPE, other) not in full_names:
                            wrong_lane = scope.lane_job(scope.FULL_SCOPE, other)
                            self.assertFalse(planner.covers_jobs(self.jobs([wrong_lane]), (limited_name,), sha))

    def test_failed_skipped_duplicate_or_missing_required_evidence_never_reuses(self):
        sha = "a" * 40
        for selected in self.widget_scopes():
            required = planner.required_jobs_from_scope(selected)
            jobs = self.jobs(required)
            for index, name in enumerate(required):
                with self.subTest(scope=selected, job=name):
                    for conclusion in ("failure", "skipped", "cancelled", None):
                        changed = copy.deepcopy(jobs)
                        changed[index]["conclusion"] = conclusion
                        self.assertFalse(planner.covers_jobs(changed, required, sha))
                    self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, sha))
                    self.assertFalse(planner.covers_jobs(jobs + [jobs[index]], required, sha))
            for lane in scope.lanes(selected):
                covering = (scope.app_ui_lanes(scope.FULL_SCOPE) if lane == "app-ui" else (lane,))
                duplicate_coverage = jobs + self.jobs([scope.lane_job(scope.FULL_SCOPE, name) for name in covering])
                self.assertFalse(planner.covers_jobs(duplicate_coverage, required, sha))
            self.assertFalse(planner.covers_jobs(jobs, required, "b" * 40))


class LostCatSavedInfoBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Exercise the structural fallback without importing historical commits.
        # Exact snapshot digest-gate logic is covered separately below; this
        # fixture does not claim to verify the original snapshot bytes.
        before = Path(__file__).with_name("fixtures").joinpath(
            "lost-cat-ux-legacy-store.swift").read_text(encoding="utf-8")
        method = ("    func removePhoto(_ role: CatPreparednessStore.PhotoRole,\n"
                  "                     draft: LostCatDraft, for key: String) throws -> LostCatDraft {\n"
                  "        var updated = draft\n"
                  "        if role == .face { updated.faceFileName = nil }\n"
                  "        else { updated.bodyFileName = nil }\n"
                  "        try save(updated, for: key)\n"
                  "        return updated\n"
                  "    }\n\n")
        after = before.replace("    func image(_ name:", method + "    func image(_ name:", 1)
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
}
"""
        after_tests = before_tests.replace(
            "\n}\n", "\n    @MainActor\n"
            "    func testLostCatPhotoTapSelectsOnlyTheTappedCandidate() {\n"
            "        XCTAssertTrue(true)\n    }\n}\n", 1)
        cls.changes = {
            scope.LOST_CAT_STORE_PATH: (before, after),
            scope.LOST_CAT_PHOTO_PATH: ("struct Before {}", "struct After {}"),
            scope.MEMORY_TEST_PATH: (before_tests, after_tests),
        }

    def test_exact_snapshot_digest_gate_requires_ordered_unchanged_pair(self):
        # Dedicated sentinel strings cannot pass structural validation. Map
        # their digests only within this test to cover the fixed-pair gate.
        before, after = "snapshot-before-sentinel", "snapshot-after-sentinel"
        self.assertFalse(scope.lost_cat_store_changes(before, after))
        digest = scope.source_digest
        digests = dict(zip((before, after), scope.LOST_CAT_SAVED_INFO_STORE_DIGESTS))
        with patch.object(scope, "source_digest", side_effect=lambda source:
                          digests.get(source, digest(source))):
            self.assertTrue(scope.lost_cat_store_changes(before, after))
            for pair in ((after, before), (before + " changed", after),
                         (before, after + " changed"), ("unknown-before", "unknown-after")):
                with self.subTest(pair=pair):
                    self.assertFalse(scope.lost_cat_store_changes(*pair))

    def test_reviewed_store_keeps_existing_lost_cat_checks_without_gallery(self):
        self.assertEqual(scope.select_scope(self.changes), scope.LOST_CAT_UX_SCOPE)
        self.assertEqual(set(self.changes), {scope.LOST_CAT_STORE_PATH, scope.LOST_CAT_PHOTO_PATH, scope.MEMORY_TEST_PATH})
        self.assertEqual(scope.native_tests(scope.LOST_CAT_UX_SCOPE), scope.LOST_CAT_PHOTO_TESTS)
        required = planner.required_jobs(list(self.changes), scope.LOST_CAT_UX_SCOPE)
        self.assertEqual(len(required), 4)
        self.assertEqual(required[:2], (planner.BUILD, planner.smoke_job(scope.LOST_CAT_UX_SCOPE)))
        self.assertEqual(scope.lanes(scope.LOST_CAT_UX_SCOPE), ("runtime", "app-ui"))
        self.assertFalse(any("gallery" in job for job in required))

    def test_unknown_store_input_or_mixed_companion_cannot_borrow_review(self):
        modified = dict(self.changes)
        before, after = modified[scope.LOST_CAT_STORE_PATH]
        modified[scope.LOST_CAT_STORE_PATH] = (before, after + "\nstruct ExtraStore {}\n")
        self.assertNotEqual(scope.select_scope(modified), scope.LOST_CAT_UX_SCOPE)
        for path in ("NekoWidget/NekoWidget/Services/EvacuationStore.swift",
                     "NekoWidget/ci/ios_ci_scope.py", "NekoWidget/NekoWidget.xcodeproj/project.pbxproj",
                     "NekoWidget/NekoWidgetWidget/NekoWidget.swift"):
            with self.subTest(path=path):
                mixed = dict(self.changes); mixed[path] = ("before", "after")
                self.assertNotEqual(scope.select_scope(mixed), scope.LOST_CAT_UX_SCOPE)
        self.assertIn("static let schemaVersion = 1", before)
        self.assertFalse(scope.lost_cat_store_changes(
            before.replace("static let schemaVersion = 1", "static let schemaVersion = 2"), after))


class VetSavedCatBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base = "59dad7942f6836d35a005c167bc94dae11757991"
        cls.head = "f888f590ff0afcd63523521496b7407d5dc3b2db"
        cls.paths = [path for path in planner.git("diff", "--name-only", "--no-renames", "-z", cls.base, cls.head).split("\0") if path]
        cls.changes = {path: (planner.git("show", f"{cls.base}:{path}"), planner.git("show", f"{cls.head}:{path}"))
                       for path in cls.paths if not scope.is_handoff(path)}

    def test_real_candidate_selects_only_vet_weight_cases_and_required_boundaries(self):
        self.assertEqual(set(self.changes), scope.VET_SAVED_CAT_PATHS)
        self.assertEqual(scope.select_scope(self.changes), scope.VET_SAVED_CAT_SCOPE)
        with patch.object(planner, "comparison_base", return_value=self.base):
            self.assertEqual(planner.runtime_scope(self.paths, {}, {"GITHUB_SHA": self.head}), scope.VET_SAVED_CAT_SCOPE)
        self.assertEqual(len(scope.VET_SAVED_CAT_TESTS), 3)
        self.assertEqual(scope.native_tests(scope.VET_SAVED_CAT_SCOPE), scope.VET_SAVED_CAT_TESTS)
        required = planner.required_jobs(self.paths, scope.VET_SAVED_CAT_SCOPE)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(scope.VET_SAVED_CAT_SCOPE))
        self.assertEqual(len(required), 4)
        self.assertEqual(scope.lanes(scope.VET_SAVED_CAT_SCOPE), ("runtime", "app-ui"))
        self.assertEqual(scope.smoke_tests(scope.VET_SAVED_CAT_SCOPE),
                         ("NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",
                          "NekoWidgetUITests/PhotoPermissionUITests/testMainlineAcceptanceScreensWithAuthorizedLibrary"))
        self.assertFalse(any("gallery" in job for job in required))

    def test_no_unknown_product_or_control_input_can_borrow_review(self):
        for path in self.changes:
            for side in (0, 1):
                altered = dict(self.changes); pair = list(altered[path]); pair[side] += "\n// unreviewed"
                altered[path] = tuple(pair)
                self.assertNotEqual(scope.select_scope(altered), scope.VET_SAVED_CAT_SCOPE)
            incomplete = dict(self.changes); del incomplete[path]
            self.assertNotEqual(scope.select_scope(incomplete), scope.VET_SAVED_CAT_SCOPE)
        for path in ("NekoWidget/NekoWidget/Services/CareHandoffStore.swift", "NekoWidget/Shared/Storage/AtomicJSON.swift",
                     "NekoWidget/ci/ios_ci_scope.py", ".github/workflows/ios-build.yml",
                     "NekoWidget/NekoWidget.xcodeproj/project.pbxproj", "NekoWidget/NekoWidgetWidget/NekoWidget.swift"):
            altered = dict(self.changes); altered[path] = ("before", "after")
            self.assertNotEqual(scope.select_scope(altered), scope.VET_SAVED_CAT_SCOPE)
        # Required jobs remain same-SHA, actually executed evidence, not skips.
        required = planner.required_jobs(self.paths, scope.VET_SAVED_CAT_SCOPE)
        jobs = [{"name": name, "head_sha": self.head, "status": "completed", "conclusion": "success"} for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, self.head))
        self.assertFalse(planner.covers_jobs(jobs, required, self.base))
        self.assertFalse(planner.covers_jobs(jobs, planner.FULL, self.head))
        for index in range(len(jobs)):
            for result in ("failure", "skipped", "cancelled", None):
                changed = copy.deepcopy(jobs); changed[index]["conclusion"] = result
                self.assertFalse(planner.covers_jobs(changed, required, self.head))


if __name__ == "__main__":
    unittest.main()
