#!/usr/bin/env python3
"""Budget decisions do not waive release checks; helpers cannot certify iOS."""

import importlib.util
import contextlib
import io
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

    def test_over_target_requires_decision_but_cannot_waive_checks(self):
        blocked = self.report()
        decided = self.report(decision="CI redesign validation requires one full baseline")
        self.assertFalse(blocked["ready"])
        self.assertTrue(decided["ready"])
        self.assertEqual(blocked["required_jobs"], list(planner.FULL))
        self.assertEqual(blocked["required_jobs"], decided["required_jobs"])
        self.assertEqual(len(blocked["unmapped_files"]), 1)
        self.assertFalse(self.report(decision=" ")["ready"])

    def test_unknown_history_does_not_assume_a_short_runtime(self):
        result = self.report(scope.REVIEWED_MEMORY_SCOPE)
        self.assertFalse(result["ready"])
        self.assertEqual(result["cost"]["status"], "unmeasured")

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
                with patch.object(preflight, "candidate_plan", return_value={"ready": True}) as plan, \
                        contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(preflight.main([]), 0)
                    self.assertEqual(Path.cwd(), preflight.CI.parents[1])
                    plan.assert_called_once()
        finally:
            os.chdir(previous)

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
