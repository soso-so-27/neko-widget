#!/usr/bin/env python3
"""Budget decisions do not waive release checks; helpers cannot certify iOS."""

import importlib.util
import contextlib
import io
import datetime as dt
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("preflight", Path(__file__).with_name("preflight-ci.py"))
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)
planner = preflight.planner
scope = preflight.scope


class PreflightTests(unittest.TestCase):
    history = {"upload_minutes": 9, "observations": [
        {"scope": "full-v1", "candidate_minutes": 64, "run_id": 1, "outcome": "failure"},
        {"scope": "full-v1", "candidate_minutes": 98, "run_id": 2, "outcome": "success-after-retry"}]}

    def test_preservation_cost_is_scope_specific_and_first_measurement_only(self):
        history = {**self.history, "observations": self.history["observations"] + [
            {"scope": planner.JPEG_SCOPE, "candidate_minutes": 0.8, "run_id": 3, "outcome": "success"},
            {"scope": "preservation-service-v1", "candidate_minutes": 0.65, "run_id": 4, "outcome": "success"},
            {"scope": "preservation-service-v2", "candidate_minutes": 0.75, "run_id": 5, "outcome": "success"}]}
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v13")
        cost = preflight.observe_cost(planner.PRESERVATION_SCOPE, history, False)
        self.assertEqual(cost["status"], "unmeasured")
        self.assertEqual(cost["samples"], [])
        self.assertEqual(cost["measurement_job_timeout_minutes"], 5)
        self.assertNotIn("with_upload_minutes", cost)
        self.assertIn("not an observed duration", cost["note"])
        for extra in ({"include_upload": True}, {"include_upload": False, "use_full_baseline": True}):
            with self.assertRaises(ValueError):
                preflight.observe_cost(planner.PRESERVATION_SCOPE, history, **extra)
        plan = {"ready": False, "head": "a" * 40, "scope": planner.PRESERVATION_SCOPE,
                "target_minutes": 5, "cost": cost}
        self.assertFalse(preflight.apply_task_gate(dict(plan), [])["ready"])
        first = preflight.apply_task_gate(dict(plan), [], measure_baseline=True)
        self.assertTrue(first["ready"])
        self.assertIsNone(first["task"]["projected_total_minutes"])
        for state, conclusion in (("in_progress", None), ("completed", "failure"), ("completed", "success")):
            run = {"id": 1, "created_at": "2026-09-22T11:00:00Z", "status": state,
                   "conclusion": conclusion, "path": planner.PRESERVATION_WORKFLOW}
            result = preflight.apply_task_gate(dict(plan), [run], measure_baseline=True)
            self.assertFalse(result["ready"])
            self.assertFalse(result["task"]["first_baseline_measurement"])
            self.assertEqual(result["task"]["failed_runs"], [1] if conclusion == "failure" else [])
            self.assertEqual(result["task"]["active_runs"], [1] if state == "in_progress" else [])

    def test_preservation_candidate_and_history_require_its_job_without_hiding_other_task_runs(self):
        paths = ["NekoWidget/PreservationService/src/index.ts", planner.PRESERVATION_WORKFLOW,
                 "NekoWidget/PreservationService/migrations/0004_upload_owner_index.sql"]
        with patch.object(planner, "git", side_effect=["", "a" * 40, "b" * 40]), \
                patch.object(planner, "comparison_base", return_value="b" * 40), \
                patch.object(planner, "changed_paths", return_value=paths), \
                patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_SCOPE):
            result = preflight.candidate_plan("origin/main", 5, False, self.history)
        self.assertEqual(result["required_jobs"], [planner.PRESERVATION_JOB])
        self.assertEqual(result["unmapped_files"], [])
        self.assertFalse(result["ready"])
        self.assertTrue(result["cost_review_required"])
        self.assertIn("no native, live-cloud or release evidence", result["reason"])
        self.assertIn("reviewed tree", result["reason"])
        runs = [{"id": 9, "path": planner.PRESERVATION_WORKFLOW, "conclusion": "failure"},
                {"id": 10, "path": planner.JPEG_WORKFLOW, "conclusion": "success"},
                {"id": 11, "path": ".github/workflows/other.yml", "conclusion": "success"}]
        with patch.object(planner, "git", return_value="codex/custody"), \
                patch.object(preflight, "github", return_value={"total_count": 3, "workflow_runs": runs}) as api:
            history = preflight.read_task_runs()
        self.assertEqual({item["id"] for item in history}, {9, 10})
        self.assertEqual(api.call_count, 2)
        self.assertTrue(any("branch=diagnostic%2Fcustody" in call.args[0] for call in api.call_args_list))
        self.assertTrue(all(item["failed_tests"] == [] for item in history))

    def test_jpeg_first_measurement_is_not_a_ten_minute_observation_or_upload_evidence(self):
        cost = preflight.observe_cost(planner.JPEG_SCOPE, self.history, False)
        self.assertEqual(cost["status"], "unmeasured")
        self.assertEqual(cost["samples"], [])
        self.assertEqual(cost["measurement_job_timeout_minutes"], 10)
        self.assertNotIn("with_upload_minutes", cost)
        self.assertIn("not an observed duration", cost["note"])
        for extra in ({"include_upload": True}, {"include_upload": False, "use_full_baseline": True}):
            with self.assertRaises(ValueError):
                preflight.observe_cost(planner.JPEG_SCOPE, self.history, **extra)
        plan = {"ready": False, "head": "a" * 40, "scope": planner.JPEG_SCOPE, "target_minutes": 5, "cost": cost}
        self.assertFalse(preflight.apply_task_gate(dict(plan), [])["ready"])
        first = preflight.apply_task_gate(dict(plan), [], measure_baseline=True)
        self.assertTrue(first["ready"])
        self.assertIsNone(first["task"]["projected_total_minutes"])
        for state, conclusion in (("in_progress", None), ("completed", "failure"), ("completed", "success")):
            run = {"id": 1, "created_at": "2026-09-22T11:00:00Z", "status": state,
                   "conclusion": conclusion, "path": planner.JPEG_WORKFLOW}
            result = preflight.apply_task_gate(dict(plan), [run], measure_baseline=True)
            self.assertFalse(result["ready"])
            self.assertFalse(result["task"]["first_baseline_measurement"])
            self.assertEqual(result["task"]["failed_runs"], [1] if conclusion == "failure" else [])
            self.assertEqual(result["task"]["active_runs"], [1] if state == "in_progress" else [])

    def test_jpeg_candidate_reports_the_dedicated_job_and_unmeasured_cost(self):
        paths = ["NekoWidget/PreservationImageValidator/src/provider.ts", planner.JPEG_WORKFLOW]
        with patch.object(planner, "git", side_effect=["", "a" * 40, "b" * 40]), \
                patch.object(planner, "comparison_base", return_value="b" * 40), \
                patch.object(planner, "changed_paths", return_value=paths), \
                patch.object(planner, "runtime_scope", return_value=planner.JPEG_SCOPE):
            result = preflight.candidate_plan("origin/main", 5, False, self.history)
        self.assertEqual(result["required_jobs"], [planner.JPEG_JOB])
        self.assertIn("Container", result["reason"])
        self.assertEqual(result["unmapped_files"], [])
        self.assertFalse(result["ready"])
        self.assertTrue(result["cost_review_required"])
        self.assertIn("no deployment or release evidence", result["reason"])

    def test_jpeg_workflow_history_is_counted_for_both_task_branches(self):
        run = {"id": 9, "path": planner.JPEG_WORKFLOW, "conclusion": "failure"}
        unrelated = {"id": 10, "path": ".github/workflows/other.yml", "conclusion": "success"}
        page = {"total_count": 2, "workflow_runs": [run, unrelated]}
        with patch.object(planner, "git", return_value="codex/jpeg"), \
                patch.object(preflight, "github", return_value=page) as api:
            result = preflight.read_task_runs()
        self.assertEqual([item["id"] for item in result], [9])
        self.assertEqual(api.call_count, 2)
        self.assertTrue(any("branch=diagnostic%2Fjpeg" in call.args[0] for call in api.call_args_list))
        self.assertEqual(result[0]["failed_tests"], [])

    @staticmethod
    def diagnostic_run_evidence(run):
        if run.get("path") != preflight.DIAGNOSTIC_WORKFLOW:
            return run
        names = preflight.diagnostic_title_tests(run.get("display_title", ""))
        status = "passed" if run.get("conclusion") == "success" else "failed"
        log = "".join(f"Test Case '-[NekoWidgetUITests.{name.replace('/', ' ')}]' {event}.\n"
                      for name in names for event in ("started", status))
        return {**run, "run_attempt": 1, "diagnostic_evidence": {
            "head": run["head_sha"], "source_sha": run["head_sha"], "run_attempt": 1, "job_id": 91,
            "started_at": run["created_at"], "results": preflight.diagnostic_case_results(names, log)}}

    def report(self, selected="full-v1", decision=None):
        paths = ["NekoWidget/NekoWidget/Services/UnknownStore.swift"]
        with patch.object(planner, "git", side_effect=["", "a" * 40, "b" * 40]), \
                patch.object(planner, "comparison_base", return_value="b" * 40), \
                patch.object(planner, "changed_paths", return_value=paths), \
                patch.object(planner, "runtime_scope", return_value=selected):
            return preflight.candidate_plan("origin/main", 30, True, self.history, decision)

    def test_historical_range_keeps_failed_retried_runs_and_upload_separate(self):
        result = preflight.observe_cost("full-v1", self.history, True)
        self.assertEqual(result["ci_minutes"], [64, 98])
        self.assertEqual(result["with_upload_minutes"], [73, 107])
        self.assertFalse(result["includes_future_rework"])
        self.assertEqual(preflight.observe_cost("unmeasured-v1", self.history, False)["status"], "unmeasured")

    def test_prose_decision_cannot_override_over_target_or_waive_checks(self):
        blocked = self.report()
        decided = self.report(decision="CI redesign validation requires one full baseline")
        self.assertFalse(blocked["ready"])
        self.assertFalse(decided["ready"])
        self.assertEqual(blocked["required_jobs"], list(planner.FULL))
        self.assertEqual(blocked["required_jobs"], decided["required_jobs"])
        self.assertEqual(len(blocked["unmapped_files"]), 1)
        self.assertFalse(self.report(decision=" ")["ready"])

    def test_unknown_history_does_not_assume_a_short_runtime(self):
        result = self.report(scope.REVIEWED_MEMORY_SCOPE)
        self.assertFalse(result["ready"])
        self.assertEqual(result["cost"]["status"], "unmeasured")

    def test_unmeasured_reviewed_profiles_can_reference_full_maximum_without_claiming_observation(self):
        for selected in (scope.REVIEWED_MEMORY_FAMILY_SCOPE, scope.REVIEWED_MEMBERSHIP_ACCESS_SCOPE,
                         scope.REVIEWED_MANAGED_PRESERVATION_SCOPE):
            cost = preflight.observe_cost(selected, self.history, True, use_full_baseline=True)
            self.assertEqual(cost["status"], "reference")
            self.assertTrue(cost["scope_unmeasured"])
            self.assertEqual(cost["reference_scope"], "full-v1")
            self.assertEqual(cost["reference_upper_minutes"], 107)
            self.assertEqual(cost["with_upload_minutes"], [107, 107])
            self.assertEqual(cost["samples"], [])
            self.assertEqual(cost["reference_samples"], self.history["observations"])
            for other in (scope.FULL_SCOPE, scope.REVIEWED_MEMORY_SCOPE, "unknown-v9"):
                with self.assertRaises(ValueError):
                    preflight.observe_cost(other, self.history, True, use_full_baseline=True)
            with self.assertRaises(ValueError):
                preflight.observe_cost(selected, {"observations": []}, True, use_full_baseline=True)
            with patch.object(scope, "lanes", side_effect=lambda value: ("new-job",) if value == selected else ("runtime", "app-ui")):
                with self.assertRaises(ValueError):
                    preflight.observe_cost(selected, self.history, True, use_full_baseline=True)
            with patch.object(planner, "required_jobs_from_scope", return_value=(planner.BUILD,)):
                with self.assertRaises(ValueError):
                    preflight.observe_cost(selected, self.history, True, use_full_baseline=True)
            original_tests = scope.native_tests
            for invalid in ((), ('NekoWidgetUITests/NewUntestedSuite/testNewRoute',)):
                with patch.object(scope, "native_tests", side_effect=lambda value: invalid if value == selected else original_tests(value)):
                    with self.assertRaises(ValueError):
                        preflight.observe_cost(selected, self.history, True, use_full_baseline=True)
            measured = {**self.history, "observations": self.history["observations"] + [
                {"scope": selected, "candidate_minutes": 40, "run_id": 3, "outcome": "success"}]}
            self.assertEqual(preflight.observe_cost(selected, measured, True, use_full_baseline=True)["status"], "observed")
        v1 = {**self.history, "observations": self.history['observations'] + [
            {"scope": "reviewed-managed-preservation-app-v1", "candidate_minutes": 14.783, "run_id": 4, "outcome": "success"}]}
        self.assertEqual(preflight.observe_cost(scope.REVIEWED_MANAGED_PRESERVATION_SCOPE, v1, False)['status'], 'unmeasured')
        reference = preflight.observe_cost(scope.REVIEWED_MANAGED_PRESERVATION_SCOPE, v1, False, use_full_baseline=True)
        self.assertEqual(reference['ci_minutes'], [98, 98])
        self.assertEqual(reference['samples'], [])
        self.assertTrue(reference['scope_unmeasured'])

    def test_full_reference_keeps_cumulative_budget_active_and_failed_test_gates(self):
        for selected in (scope.REVIEWED_MEMORY_FAMILY_SCOPE, scope.REVIEWED_MEMBERSHIP_ACCESS_SCOPE,
                         scope.REVIEWED_MANAGED_PRESERVATION_SCOPE):
            cost = preflight.observe_cost(selected, self.history, True, use_full_baseline=True)
            now = dt.datetime(2026, 9, 20, 12, tzinfo=dt.timezone.utc)
            failed = {"id": 1, "created_at": "2026-09-20T11:00:00Z", "status": "completed", "conclusion": "failure",
                      "path": ".github/workflows/ios-build.yml", "failed_tests": ["SoloMemoriesUITests/testNavigation"]}
            diagnostic = {"id": 2, "created_at": "2026-09-20T11:58:00Z", "status": "completed", "conclusion": "success",
                          "event": "workflow_dispatch", "head_sha": "a" * 40, "head_branch": "diagnostic/task",
                          "path": preflight.DIAGNOSTIC_WORKFLOW, "display_title": "UI diagnosis: SoloMemoriesUITests/testNavigation"}
            def check(target, runs):
                return preflight.apply_task_gate({"ready": target >= 107, "head": "a" * 40,
                       "target_minutes": target, "cost": cost}, [self.diagnostic_run_evidence(run) for run in runs], now)
            rejected = check(30, [failed, diagnostic])
            self.assertFalse(rejected["ready"])
            self.assertEqual(rejected["task"]["projected_total_minutes"], 167)
            self.assertTrue(check(180, [failed, diagnostic])["ready"])
            self.assertFalse(check(180, [failed])["ready"])
            self.assertFalse(check(180, [failed, {**diagnostic, "head_sha": "b" * 40}])["ready"])
            self.assertFalse(check(180, [failed, diagnostic, {**failed, "id": 3, "status": "in_progress", "conclusion": None}])["ready"])
            # A compile failure before any UI operation needs no unrelated diagnosis.
            self.assertTrue(check(180, [{**failed, "failed_tests": []}])["ready"])

    def test_dirty_candidate_cannot_be_described_as_the_committed_candidate(self):
        with patch.object(planner, "git", return_value=" M Source.swift"):
            with self.assertRaisesRegex(ValueError, "dirty"):
                preflight.candidate_plan("origin/main", 30, False, self.history)

    def test_helper_scope_requires_existing_regular_files_and_no_product_changes(self):
        path = "NekoWidget/ci/watch-ci-run.py"
        for old, new, status, expected in (("100644", "100644", "M", True),
                ("100644", "120000", "T", False), ("100644", "000000", "D", False),
                ("000000", "100644", "A", False)):
            raw = f":{old} {new} {'a' * 40} {'b' * 40} {status}\0{path}\0"
            with patch.object(planner, "git", return_value=raw):
                self.assertEqual(planner.development_tools_only([path], "base", "head"), expected)
        for unsafe in (".github/workflows/ios-build.yml", "NekoWidget/ci/plan-ios-ci.py",
                       "NekoWidget/ci/check-development-flow.py", "NekoWidget/ci/release-testflight.py",
                       "NekoWidget/NekoWidget/Services/PhotoMemoryNoteStore.swift"):
            self.assertFalse(planner.development_tools_only([path, unsafe], "base", "head"))

    def test_helper_success_cannot_be_used_as_testflight_evidence(self):
        with self.assertRaises(ValueError):
            planner.required_jobs_from_scope(planner.DEVELOPMENT_SCOPE)
        self.assertEqual(planner.required_jobs(["NekoWidget/ci/watch-ci-run.py"], planner.DEVELOPMENT_SCOPE),
                         (planner.PLAN_JOB,))
        self.assertEqual(planner.required_jobs(["Unknown.swift"], planner.DEVELOPMENT_SCOPE), planner.FULL)

    def test_nonfinite_budget_or_history_is_rejected(self):
        for value in ("nan", "inf", "-inf", "0"):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                preflight.main(["--target-minutes=" + value])
        for value in (float("nan"), float("inf"), -1):
            history = {"upload_minutes": value, "observations": self.history["observations"]}
            with self.assertRaises(ValueError):
                preflight.observe_cost("full-v1", history, True)
            history = {"upload_minutes": 9, "observations": [{"scope": "full-v1", "candidate_minutes": value}]}
            with self.assertRaises(ValueError):
                preflight.observe_cost("full-v1", history, False)

    def test_direct_invocation_uses_its_own_checkout(self):
        previous = Path.cwd()
        try:
            with tempfile.TemporaryDirectory() as directory:
                os.chdir(directory)
                with patch.object(preflight, "candidate_plan", return_value={"ready": True, "scope": "no-change"}) as plan, \
                        contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(preflight.main([]), 0)
                    self.assertEqual(Path.cwd(), preflight.CI.parents[1])
                    plan.assert_called_once()
        finally:
            os.chdir(previous)

    def test_task_gate_counts_elapsed_time_and_rejects_active_work(self):
        now = dt.datetime(2026, 9, 20, 12, tzinfo=dt.timezone.utc)
        plan = {"ready": True, "head": "a" * 40, "target_minutes": 30,
                "cost": {"status": "observed", "with_upload_minutes": [10, 20]}}
        run = {"id": 1, "created_at": "2026-09-20T11:45:00Z", "status": "in_progress",
               "conclusion": None, "path": ".github/workflows/ios-build.yml"}
        result = preflight.apply_task_gate(plan, [run], now)
        self.assertFalse(result["ready"])
        self.assertEqual(result["task"]["projected_total_minutes"], 35)
        self.assertEqual(result["task"]["blockers"], ["ci_already_running", "cumulative_cost_requires_replanning"])

    def test_ui_failure_requires_diagnostic_success_for_current_sha_only(self):
        now = dt.datetime(2026, 9, 20, 12, tzinfo=dt.timezone.utc)
        failed = {"id": 1, "created_at": "2026-09-20T11:55:00Z", "status": "completed",
                  "conclusion": "failure", "failed_tests": ["testNavigation"], "path": ".github/workflows/ios-build.yml"}
        diagnostic = {"id": 2, "created_at": "2026-09-20T11:58:00Z", "status": "completed",
                      "conclusion": "success", "event": "workflow_dispatch", "head_sha": "a" * 40,
                      "path": preflight.DIAGNOSTIC_WORKFLOW, "head_branch": "diagnostic/task", "display_title": "UI diagnosis: testNavigation"}
        def check(runs):
            return preflight.apply_task_gate({"ready": True, "head": "a" * 40, "target_minutes": 30,
                   "cost": {"status": "observed", "with_upload_minutes": [10, 20]}}, [self.diagnostic_run_evidence(run) for run in runs], now)
        self.assertFalse(check([failed])["ready"])
        self.assertTrue(check([failed, diagnostic])["ready"])
        for change in ({"head_sha": "b" * 40}, {"conclusion": "failure"}, {"event": "push"},
                       {"path": ".github/workflows/unrelated.yml"}, {"display_title": "UI diagnosis: testOther"}):
            self.assertFalse(check([failed, {**diagnostic, **change}])["ready"])
        # A Python/build failure does not force an unrelated UI test.
        self.assertTrue(check([{**failed, "failed_tests": []}])["ready"])

    def test_unmeasured_baseline_is_explicit_and_first_attempt_only(self):
        plan = {"ready": False, "head": "a" * 40, "target_minutes": 30, "cost": {"status": "unmeasured"}}
        self.assertFalse(preflight.apply_task_gate(dict(plan), [])["ready"])
        first = preflight.apply_task_gate(dict(plan), [], measure_baseline=True)
        self.assertTrue(first["ready"])
        self.assertIsNone(first["task"]["projected_total_minutes"])
        run = {"id": 1, "created_at": "2026-09-20T11:00:00Z", "status": "completed",
               "conclusion": "failure", "path": ".github/workflows/ios-build.yml"}
        self.assertFalse(preflight.apply_task_gate(dict(plan), [run], measure_baseline=True)["ready"])

    def test_history_queries_both_branch_routes_and_extracts_only_failed_methods(self):
        run = {"id": 1, "path": ".github/workflows/ios-build.yml", "conclusion": "failure"}
        page = {"total_count": 1, "workflow_runs": [run]}
        jobs = {"total_count": 1, "jobs": [{"id": 9, "name": "Native checks [app-ui; scope test]", "conclusion": "failure"}]}
        log = "Test Case '-[NekoWidgetUITests.MomentDeliveryComposerUITests testNavigation]' failed (2 seconds)."
        with patch.object(planner, "git", return_value="diagnostic/task"), \
                patch.object(preflight, "github", side_effect=[page, page, jobs, log]) as api:
            result = preflight.read_task_runs()
        self.assertEqual(result[0]["failed_tests"], ["MomentDeliveryComposerUITests/testNavigation"])
        queries = [call.args[0] for call in api.call_args_list[:2]]
        self.assertTrue(any("branch=codex%2Ftask" in query for query in queries))
        self.assertTrue(any("branch=diagnostic%2Ftask" in query for query in queries))

    def test_cancelled_run_retains_other_classes_instead_of_claiming_environment_failure(self):
        run = {"id": 1, "path": ".github/workflows/ios-build.yml", "conclusion": "cancelled",
               "status": "completed", "created_at": "2026-09-20T11:55:00Z"}
        page = {"total_count": 1, "workflow_runs": [run]}
        jobs = {"total_count": 1, "jobs": [{"id": 9, "name": "Sharing [app-ui; scope full-v1]", "conclusion": "failure"}]}
        log = "Test Case '-[NekoWidgetUITests.OtherTests testNavigation]' failed (2 seconds)."
        with patch.object(planner, "git", return_value="diagnostic/task"), \
                patch.object(preflight, "github", side_effect=[page, page, jobs, log]):
            runs = preflight.read_task_runs()
        self.assertEqual(runs[0]["unsupported_failed_tests"], ["NekoWidgetUITests.OtherTests/testNavigation"])
        result = preflight.apply_task_gate({"ready": True, "head": "a" * 40, "target_minutes": 30,
                 "cost": {"status": "observed", "with_upload_minutes": [10, 20]}}, runs,
                 now=dt.datetime(2026, 9, 20, 12, tzinfo=dt.timezone.utc))
        self.assertFalse(result["ready"])
        self.assertIn("failed_test_needs_a_supported_focused_diagnostic_route", result["task"]["blockers"])

    def test_three_solo_failures_require_same_sha_class_and_all_methods(self):
        names = ["testAlbumRelatedPhotoRoutesPreserveScopeAndReturnToOrigin",
                 "testAlbumRootUpdatesAndPreservesFavoritesAndReflectionDestinations",
                 "testPersonalArchiveRestoresPhotoAndTextAndExplicitlySavesNewText"]
        run = {"id": 1, "path": ".github/workflows/ios-build.yml", "conclusion": "failure",
               "status": "completed", "created_at": "2026-09-20T11:55:00Z"}
        page = {"total_count": 1, "workflow_runs": [run]}
        jobs = {"total_count": 1, "jobs": [{"id": 9, "name": "Sharing [app-ui; scope full-v1]", "conclusion": "failure"}]}
        log = "\n".join(f"Test Case '-[NekoWidgetUITests.SoloMemoriesUITests {name}]' failed (2 seconds)." for name in names)
        with patch.object(planner, "git", return_value="diagnostic/task"), \
                patch.object(preflight, "github", side_effect=[page, page, jobs, log]):
            failed = preflight.read_task_runs()
        self.assertEqual(set(failed[0]["failed_tests"]), {"SoloMemoriesUITests/" + name for name in names})
        self.assertFalse(failed[0]["unsupported_failed_tests"])
        diagnostic = dict(run, id=2, path=preflight.DIAGNOSTIC_WORKFLOW, conclusion="success",
                          event="workflow_dispatch", head_sha="a" * 40, head_branch="diagnostic/task",
                          display_title="UI diagnosis: SoloMemoriesUITests/" + ",".join(names))
        def check(extra):
            return preflight.apply_task_gate({"ready": True, "head": "a" * 40, "target_minutes": 30,
                "cost": {"status": "observed", "with_upload_minutes": [10, 20]}}, failed + [self.diagnostic_run_evidence(run) for run in extra],
                now=dt.datetime(2026, 9, 20, 12, tzinfo=dt.timezone.utc))
        self.assertTrue(check([diagnostic])["ready"])
        for change in ({"head_sha": "b" * 40}, {"head_branch": "codex/task"},
                       {"display_title": "UI diagnosis: SoloMemoriesUITests/" + names[0]},
                       {"display_title": "UI diagnosis: MomentDeliveryComposerUITests/" + ",".join(names)},
                       {"display_title": "UI diagnosis: " + ",".join(names)},
                       {"conclusion": "failure"}):
            self.assertFalse(check([{**diagnostic, **change}])["ready"], change)
        self.assertTrue(check([{**diagnostic, "id": i + 10,
                               "display_title": "UI diagnosis: SoloMemoriesUITests/" + name}
                              for i, name in enumerate(names)])["ready"])

    @staticmethod
    def diagnostic_fixture():
        run = {"id": 12, "path": preflight.DIAGNOSTIC_WORKFLOW, "head_sha": "a" * 40,
               "event": "workflow_dispatch", "head_branch": "diagnostic/task", "run_attempt": 2,
               "status": "completed", "conclusion": "failure", "created_at": "2026-09-20T11:55:00Z",
               "display_title": "UI diagnosis: SoloMemoriesUITests/testArchive,testRelated,testRoot"}
        job = {"id": 91, "run_id": 12, "run_attempt": 2, "head_sha": "a" * 40,
               "name": "Diagnostic only - up to three native UI tests (not release evidence)",
               "status": "completed", "conclusion": "failure",
               "started_at": "2026-09-20T11:56:00Z", "completed_at": "2026-09-20T11:59:00Z"}
        log = "".join(f"Test Case '-[NekoWidgetUITests.SoloMemoriesUITests {name}]' {event}.\n"
                      for name in ("testArchive", "testRelated", "testRoot")
                      for event in ("started", "failed" if name == "testRoot" else "passed"))
        return run, job, log

    def test_failed_diagnostic_reads_only_exact_completed_job_attempt_and_retains_two_passes(self):
        run, job, log = self.diagnostic_fixture()
        jobs = {"total_count": 1, "jobs": [job]}
        with patch.object(preflight, "github", side_effect=[jobs, log]) as api:
            evidence = preflight.read_diagnostic_evidence(run, run["head_sha"])
        self.assertIn("/runs/12/attempts/2/jobs?", api.call_args_list[0].args[0])
        self.assertEqual(api.call_args_list[1].args, (f"repos/{preflight.REPOSITORY}/actions/jobs/91/logs",))
        self.assertTrue(api.call_args_list[1].kwargs["raw"])
        self.assertEqual(evidence["results"], {"SoloMemoriesUITests/testArchive": "passed",
            "SoloMemoriesUITests/testRelated": "passed", "SoloMemoriesUITests/testRoot": "failed"})
        for change in ({"run_id": 13}, {"run_attempt": 1}, {"head_sha": "b" * 40},
                       {"name": "Unrelated job"}, {"status": "in_progress"}, {"completed_at": None}):
            with patch.object(preflight, "github", return_value={"total_count": 1, "jobs": [{**job, **change}]}) as api:
                with self.assertRaises(ValueError):
                    preflight.read_diagnostic_evidence(run, run["head_sha"])
                self.assertEqual(api.call_count, 1)
        with patch.object(preflight, "github", return_value={"total_count": 2, "jobs": [job, job]}):
            with self.assertRaises(ValueError):
                preflight.read_diagnostic_evidence(run, run["head_sha"])
        with patch.object(preflight, "github", side_effect=[jobs, ValueError("logs unavailable")]):
            with self.assertRaises(ValueError):
                preflight.read_diagnostic_evidence(run, run["head_sha"])

    def test_cancelled_before_steps_is_incomplete_without_logs_and_later_pass_supersedes_it(self):
        run, job, _ = self.diagnostic_fixture()
        run = {**run, "conclusion": "cancelled"}
        job = {**job, "conclusion": "cancelled", "steps": []}
        with patch.object(preflight, "github", return_value={"total_count": 1, "jobs": [job]}) as api:
            run["diagnostic_evidence"] = preflight.read_diagnostic_evidence(run, run["head_sha"])
        self.assertEqual(api.call_count, 1)  # No nonexistent job log requested.
        self.assertEqual(set(run["diagnostic_evidence"]["results"].values()), {"incomplete"})
        self.assertEqual(len(run["diagnostic_evidence"]["results"]), 3)
        for change in ({"run_attempt": 1}, {"head_sha": "b" * 40}, {"status": "in_progress"}):
            with patch.object(preflight, "github", return_value={"total_count": 1, "jobs": [{**job, **change}]}):
                with self.assertRaises(ValueError):
                    preflight.read_diagnostic_evidence(run, run["head_sha"])
        def check(runs):
            return preflight.apply_task_gate({"ready": True, "head": run["head_sha"], "target_minutes": 30,
                "cost": {"status": "observed", "with_upload_minutes": [10, 20]}}, runs,
                now=dt.datetime(2026, 9, 20, 12, tzinfo=dt.timezone.utc))
        self.assertFalse(check([run])["ready"])
        repaired = self.diagnostic_run_evidence({**run, "id": 13, "conclusion": "success",
                                               "created_at": "2026-09-20T11:59:00Z"})
        self.assertTrue(check([repaired, run])["ready"])
        later_cancelled = {**run, "id": 14, "diagnostic_evidence": {
            **run["diagnostic_evidence"], "started_at": "2026-09-20T11:59:30Z"}}
        self.assertFalse(check([repaired, run, later_cancelled])["ready"])

    def test_missing_or_nonempty_steps_and_non_cancelled_job_still_require_logs(self):
        run, job, _ = self.diagnostic_fixture()
        for change in ({"conclusion": "cancelled"},
                       {"conclusion": "cancelled", "steps": None},
                       {"conclusion": "cancelled", "steps": [{"name": "Set up job", "status": "completed"}]},
                       {"conclusion": "failure", "steps": []},
                       {"conclusion": "success", "steps": []}):
            with self.subTest(change=change), patch.object(preflight, "github", side_effect=[
                    {"total_count": 1, "jobs": [{**job, **change}]}, ValueError("logs unavailable")]) as api:
                with self.assertRaisesRegex(ValueError, "logs unavailable"):
                    preflight.read_diagnostic_evidence(run, run["head_sha"])
                self.assertEqual(api.call_count, 2)
                self.assertTrue(api.call_args.kwargs["raw"])

    def test_diagnostic_transcript_rejects_duplicates_extras_skips_and_incomplete_cases(self):
        run, _, log = self.diagnostic_fixture()
        declared = preflight.diagnostic_title_tests(run["display_title"])
        good_line = "Test Case '-[NekoWidgetUITests.SoloMemoriesUITests testArchive]' passed.\n"
        for bad in (log + good_line, log + good_line.replace("testArchive", "testOther"),
                    log.replace("testArchive]' started", "testArchive]' passed")):
            self.assertEqual(set(preflight.diagnostic_case_results(declared, bad).values()), {"invalid"})
        skipped = preflight.diagnostic_case_results(declared, log.replace("testRoot]' failed", "testRoot]' skipped"))
        self.assertEqual(skipped["SoloMemoriesUITests/testRoot"], "skipped")
        self.assertEqual(skipped["SoloMemoriesUITests/testArchive"], "passed")
        partial = preflight.diagnostic_case_results(declared, log.replace("Test Case '-[NekoWidgetUITests.SoloMemoriesUITests testRoot]' failed.\n", ""))
        self.assertEqual(partial["SoloMemoriesUITests/testRoot"], "incomplete")
        self.assertEqual(set(preflight.diagnostic_case_results(declared, "").values()), {"incomplete"})

    def test_latest_per_case_results_join_without_hiding_newer_failure(self):
        run, job, log = self.diagnostic_fixture()
        with patch.object(preflight, "github", side_effect=[{"total_count": 1, "jobs": [job]}, log]):
            run["diagnostic_evidence"] = preflight.read_diagnostic_evidence(run, run["head_sha"])
        repaired = self.diagnostic_run_evidence({**run, "id": 13, "created_at": "2026-09-20T11:59:00Z",
            "conclusion": "success", "display_title": "UI diagnosis: SoloMemoriesUITests/testRoot"})
        def check(runs):
            return preflight.apply_task_gate({"ready": True, "head": "a" * 40, "target_minutes": 30,
                "cost": {"status": "observed", "with_upload_minutes": [10, 20]}}, runs,
                now=dt.datetime(2026, 9, 20, 12, tzinfo=dt.timezone.utc))
        self.assertFalse(check([run])["ready"])
        result = check([repaired, run])  # API order must not affect newest results.
        self.assertTrue(result["ready"])
        self.assertEqual(len(result["task"]["diagnostic_cases"]), 3)
        self.assertEqual(result["task"]["diagnostic_cases"]["SoloMemoriesUITests/testArchive"]["run_id"], 12)
        for outcome in ("failed", "skipped", "incomplete", "invalid"):
            later = self.diagnostic_run_evidence({**repaired, "id": 14, "created_at": "2026-09-20T11:59:30Z"})
            later["diagnostic_evidence"]["results"]["SoloMemoriesUITests/testRoot"] = outcome
            self.assertFalse(check([later, run, repaired])["ready"], outcome)
        # A rerun has the old run's created_at/id, but its new attempt started
        # later. It must invalidate an intervening pass, not be sorted as old.
        rerun = {**run, "run_attempt": 3, "diagnostic_evidence": {
            **run["diagnostic_evidence"], "run_attempt": 3, "job_id": 92,
            "started_at": "2026-09-20T11:59:40Z"}}
        self.assertFalse(check([rerun, repaired])["ready"])
        active = {**repaired, "id": 15, "status": "in_progress", "conclusion": None}
        self.assertFalse(check([run, repaired, active])["ready"])
        # A success title without downloaded/validated case evidence never counts.
        no_log = {key: value for key, value in repaired.items() if key != "diagnostic_evidence"}
        self.assertFalse(check([run, no_log])["ready"])

    def test_history_loads_diagnostic_evidence_only_after_product_identity_proof(self):
        run, job, log = self.diagnostic_fixture()
        page = {"total_count": 1, "workflow_runs": [run]}
        with patch.object(planner, "git", return_value="diagnostic/task"), \
                patch.object(preflight, "diagnostic_source_matches", return_value=True) as proof, \
                patch.object(preflight, "github", side_effect=[page, page, {"total_count": 1, "jobs": [job]}, log]):
            runs = preflight.read_task_runs("b" * 40)
        proof.assert_called_once_with("a" * 40, "b" * 40)
        self.assertEqual(runs[0]["diagnostic_evidence"]["head"], "b" * 40)
        clean = {key: value for key, value in run.items() if key != "diagnostic_evidence"}
        with patch.object(planner, "git", return_value="diagnostic/task"), \
                patch.object(preflight, "diagnostic_source_matches", return_value=False), \
                patch.object(preflight, "github", return_value={"total_count": 1, "workflow_runs": [clean]}) as api:
            runs = preflight.read_task_runs("c" * 40)
        self.assertNotIn("diagnostic_evidence", runs[0])
        self.assertEqual(api.call_count, 2)

    def test_diagnostic_source_allows_only_ancestor_and_existing_normal_helper_modifications(self):
        source, head = "a" * 40, "b" * 40
        path = "NekoWidget/ci/preflight-ci.py"
        good = f":100644 100644 {'c' * 40} {'d' * 40} M\0{path}\0"
        allowed = (path, "NekoWidget/ci/test-preflight-ci.py", "NekoWidget/ci/verify-app-icon.py")
        self.assertEqual(preflight.DIAGNOSTIC_HELPER_PATHS, frozenset(allowed))
        for helper in allowed:
            with patch.object(planner, "git", side_effect=["", good.replace(path, helper)]) as git:
                self.assertTrue(preflight.diagnostic_source_matches(source, head), helper)
                self.assertEqual(git.call_args_list[0].args, ("merge-base", "--is-ancestor", source, head))
                self.assertEqual(git.call_args_list[1].args, ("diff", "--raw", "--no-renames", "--no-abbrev", "-z", source, head))
        for extra in ("NekoWidget/ci/watch-ci-run.py", "handoffs/note.md", "NekoWidget/ci/ios_ci_scope.py",
                      ".github/workflows/ios-ui-diagnostic.yml", "NekoWidget/ci/run-sharing-runtime-matrix.sh",
                      "NekoWidget/ci/prepare-simulator-and-build.sh", "NekoWidget/ci/app_icon_ci.py",
                      "NekoWidget/NekoWidget.xcodeproj/project.pbxproj",
                      "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift", "App.swift"):
            with patch.object(planner, "git", side_effect=["", good + good.replace(path, extra)]):
                self.assertFalse(preflight.diagnostic_source_matches(source, head), extra)
        for raw in (good.replace(":100644", ":000000"), good.replace("100644 ", "120000 ", 1),
                    good.replace(" 100644 ", " 100755 "), good.replace(" M\0", " D\0"),
                    good.replace(" M\0", " R100\0"), good + good, "incomplete"):
            with patch.object(planner, "git", side_effect=["", raw]):
                self.assertFalse(preflight.diagnostic_source_matches(source, head), raw)
        with patch.object(planner, "git", side_effect=subprocess.CalledProcessError(1, "git")):
            self.assertFalse(preflight.diagnostic_source_matches(source, head))
        with patch.object(planner, "git") as git:
            self.assertTrue(preflight.diagnostic_source_matches(head, head))
            self.assertFalse(preflight.diagnostic_source_matches("main", head))
            git.assert_not_called()

    def test_raw_logs_are_captured_with_escape_sequences_but_not_printed(self):
        response = subprocess.CompletedProcess([], 0, stdout="\x1b[31mfailed\x1b[0m", stderr="")
        with patch.object(preflight.subprocess, "run", return_value=response) as invoke, \
                contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(preflight.github("repos/test/actions/jobs/1/logs", raw=True), response.stdout)
        self.assertIn("--allow-escape-sequences", invoke.call_args.args[0])
        self.assertEqual(out.getvalue(), "")

    def test_real_git_helper_only_rejects_stale_main_and_mixed_product(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args], text=True,
                                               encoding="utf-8", stderr=subprocess.PIPE).rstrip("\n")
            def commit():
                git("add", ".")
                git("-c", "user.name=CI", "-c", "user.email=ci@example.invalid", "commit", "-qm", "fixture")
                return git("rev-parse", "HEAD")
            git("init", "-q")
            helper = root / "NekoWidget/ci/watch-ci-run.py"
            helper.parent.mkdir(parents=True)
            helper.write_text("before\n")
            base = commit()
            git("update-ref", "refs/remotes/origin/main", base)
            helper.write_text("after\n")
            head = commit()
            env = {"GITHUB_SHA": head, "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/codex/test"}
            with patch.object(planner, "git", side_effect=git):
                paths = planner.changed_paths({}, env)
                self.assertEqual(planner.runtime_scope(paths, {}, env), planner.DEVELOPMENT_SCOPE)
                git("checkout", "--detach", "-q", base)
                (root / "product.swift").write_text("new main product\n")
                newer_main = commit()
                git("update-ref", "refs/remotes/origin/main", newer_main)
                git("checkout", "--detach", "-q", head)
                self.assertEqual(planner.runtime_scope(paths, {}, env), scope.FULL_SCOPE)
                git("update-ref", "refs/remotes/origin/main", base)
                (root / "product.swift").write_text("mixed product\n")
                env["GITHUB_SHA"] = commit()
                self.assertEqual(planner.runtime_scope(planner.changed_paths({}, env), {}, env), scope.FULL_SCOPE)


if __name__ == "__main__":
    unittest.main()
