#!/usr/bin/env python3
"""Widget-specific test selection and evidence boundaries; no network or CI run."""

import copy
import importlib.util
from pathlib import Path
import re
import subprocess
import unittest
from unittest.mock import patch

import ios_ci_scope as scope


spec = importlib.util.spec_from_file_location("widget_scope_planner", Path(__file__).with_name("plan-ios-ci.py"))
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)

ROOT = Path(__file__).resolve().parents[2]
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

    def test_ci_raw_diff_allows_only_named_new_tests_and_current_main_ancestor(self):
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
            self.assertEqual(planner.runtime_scope([new_test], {}, env), scope.CI_SELECTION_SCOPE)
            calls.assert_any_call("merge-base", "--is-ancestor", "refs/remotes/origin/main", sha)
        def stale(*args):
            if args[:2] == ("merge-base", "--is-ancestor"):
                raise subprocess.CalledProcessError(1, "git")
            return git(*args)
        with patch.object(planner, "git", side_effect=stale):
            self.assertEqual(planner.runtime_scope([new_test], {}, env), scope.FULL_SCOPE)
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
        full = scope.lane_tests(scope.FULL_SCOPE, "app-ui")
        for identifier in UI_TESTS:
            self.assertTrue(any(identifier == item or identifier.startswith(item + "/") for item in full), identifier)

    def test_lane_selection_keeps_runtime_and_required_gallery_conditions(self):
        expected = {
            scope.WIDGET_BEHAVIOR_SCOPE: ("runtime", "app-ui", "gallery-normal"),
            scope.WIDGET_LAYOUT_SCOPE: ("runtime", "app-ui", "gallery-normal", "gallery-white", "gallery-no-caption"),
            scope.WIDGET_STYLE_SCOPE: ("runtime", "gallery-normal", "gallery-white", "gallery-no-caption"),
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
        bootstrap = ("NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",)
        sha = "a" * 40
        for selected in scope.SCOPES:
            required = planner.required_jobs_from_scope(selected)
            if selected == scope.ICON_SCOPE:
                self.assertEqual(required, (planner.ICON_BUILD,))
                continue
            self.assertIn(planner.smoke_job(selected), required)
            if selected != scope.FULL_SCOPE:
                self.assertEqual(scope.smoke_tests(selected), bootstrap)
                self.assertEqual(planner.smoke_job(selected), planner.BOOTSTRAP_SMOKE)
        self.assertEqual(scope.smoke_tests(scope.FULL_SCOPE),
                         bootstrap + scope.OFFICIAL_TESTS + ("NekoWidgetUITests/PersonalRediscoveryUITests",))
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
                    full_name = scope.lane_job(scope.FULL_SCOPE, lane)
                    self.assertTrue(planner.covers_jobs(self.jobs([full_name]), (limited_name,), sha))
                    for other in scope.LANES:
                        if other != lane:
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
                duplicate_coverage = jobs + self.jobs([scope.lane_job(scope.FULL_SCOPE, lane)])
                self.assertFalse(planner.covers_jobs(duplicate_coverage, required, sha))
            self.assertFalse(planner.covers_jobs(jobs, required, "b" * 40))


if __name__ == "__main__":
    unittest.main()
