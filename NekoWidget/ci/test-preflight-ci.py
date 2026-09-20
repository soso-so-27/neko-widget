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

    def test_unmeasured_v3_can_reference_full_maximum_without_claiming_observation(self):
        selected = scope.REVIEWED_MEMORY_FAMILY_SCOPE
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
        measured = {**self.history, "observations": self.history["observations"] + [
            {"scope": selected, "candidate_minutes": 40, "run_id": 3, "outcome": "success"}]}
        self.assertEqual(preflight.observe_cost(selected, measured, True, use_full_baseline=True)["status"], "observed")

    def test_full_reference_keeps_cumulative_budget_active_and_failed_test_gates(self):
        cost = preflight.observe_cost(scope.REVIEWED_MEMORY_FAMILY_SCOPE, self.history, True, use_full_baseline=True)
        now = dt.datetime(2026, 9, 20, 12, tzinfo=dt.timezone.utc)
        failed = {"id": 1, "created_at": "2026-09-20T11:00:00Z", "status": "completed", "conclusion": "failure",
                  "path": ".github/workflows/ios-build.yml", "failed_tests": ["SoloMemoriesUITests/testNavigation"]}
        diagnostic = {"id": 2, "created_at": "2026-09-20T11:58:00Z", "status": "completed", "conclusion": "success",
                      "event": "workflow_dispatch", "head_sha": "a" * 40, "head_branch": "diagnostic/task",
                      "path": preflight.DIAGNOSTIC_WORKFLOW, "display_title": "UI diagnosis: SoloMemoriesUITests/testNavigation"}
        def check(target, runs):
            return preflight.apply_task_gate({"ready": target >= 107, "head": "a" * 40,
                   "target_minutes": target, "cost": cost}, runs, now)
        rejected = check(30, [failed, diagnostic])
        self.assertFalse(rejected["ready"])
        self.assertEqual(rejected["task"]["projected_total_minutes"], 167)
        self.assertTrue(check(180, [failed, diagnostic])["ready"])
        self.assertFalse(check(180, [failed])["ready"])
        self.assertFalse(check(180, [failed, {**diagnostic, "head_sha": "b" * 40}])["ready"])
        self.assertFalse(check(180, [failed, diagnostic, {**failed, "id": 3, "status": "in_progress", "conclusion": None}])["ready"])

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
                   "cost": {"status": "observed", "with_upload_minutes": [10, 20]}}, runs, now)
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
                "cost": {"status": "observed", "with_upload_minutes": [10, 20]}}, failed + extra,
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
