#!/usr/bin/env python3
"""Budget decisions do not waive release checks; helpers cannot certify iOS."""

import importlib.util
import copy
import contextlib
import io
import json
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


class ModerationResolutionDiagnosticBackendRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.head, self.source, self.old = "b" * 40, "a" * 40, "c" * 40
        self.now = dt.datetime(2026, 10, 9, 11, 15, tzinfo=dt.timezone.utc)
        self.result = {"scope": planner.MODERATION_RESOLUTION_SCOPE, "head": self.head, "ready": False,
                       "target_minutes": 50, "required_jobs": list(planner.required_jobs_from_scope(planner.MODERATION_RESOLUTION_SCOPE)),
                       "cost": {"status": "unmeasured", "samples": []}}
        self.branch = "diagnostic/moderation-resolution-20261009"
        self.identity = {"id": 3, "state": "active", "path": planner.BILLING_WORKFLOW}
        self.success = {"id": 20, "run_number": 2, "workflow_id": 3, "head_sha": self.source, "head_branch": self.branch,
            "path": planner.BILLING_WORKFLOW, "event": "push", "status": "completed", "conclusion": "success", "run_attempt": 1,
            "repository": {"full_name": preflight.REPOSITORY}, "head_repository": {"full_name": preflight.REPOSITORY},
            "created_at": "2026-10-09T11:05:00Z", "run_started_at": "2026-10-09T11:05:00Z", "updated_at": "2026-10-09T11:10:00Z"}
        self.failure = self.success | {"id": 10, "run_number": 1, "head_sha": self.old, "conclusion": "failure",
            "created_at": "2026-10-09T11:00:00Z", "updated_at": "2026-10-09T11:01:00Z"}
        self.runs = [self.failure, self.success]
        steps = [["Run python NekoWidget/ci/plan-ios-ci.py"],
            ["Verify Apple transaction service boundary", "Verify durable nonce and capability credential boundaries",
             "Build nonroot Node image and private Worker without publishing"],
            ["Parse and exercise Windows path, volume, and ACL policy"],
            ["Run Worker, D1, staging, moderation, and key ceremony tests", "Build deployment bundle without publishing"]]
        self.jobs = [{"id": 100 + i, "name": name, "run_id": 20, "run_attempt": 1, "head_sha": self.source,
            "status": "completed", "conclusion": "success", "started_at": "2026-10-09T11:06:00Z", "completed_at": "2026-10-09T11:09:00Z",
            "steps": [{"name": step, "status": "completed", "conclusion": "success"} for step in steps[i]]}
            for i, name in enumerate(planner.PRESERVATION_EXPORT_BACKEND_JOBS["sharing-service.yml"])]
        prefix = f"repos/{preflight.REPOSITORY}/actions"
        self.jobs_path = prefix + "/runs/20/jobs?filter=latest&per_page=100&page=1"
        self.responses = {prefix + "/workflows/sharing-service.yml": self.identity,
            prefix + "/runs/20": self.success, self.jobs_path: {"total_count": 4, "jobs": self.jobs}}
        self.git_changes = {}

    def git(self, *args):
        if args in self.git_changes: return self.git_changes[args]
        if args[0] == "branch": return "codex/moderation-resolution-20261009"
        if args[0] == "merge-base": return ""
        if args[0] == "diff": return ""
        if args[0] == "ls-tree":
            path = args[-1]
            if "-r" in args: return f"100644 blob {'d' * 40}\t{path}/file.ts\0"
            if path.endswith(".yml"):
                return f"100644 blob {planner.MODERATION_RESOLUTION_IMMUTABLE_BLOBS[path]}\t{path}"
            return f"040000 tree {'e' * 40}\t{path}"
        raise AssertionError(args)

    def prove(self, result=None, runs=None):
        with patch.object(planner, "git", side_effect=self.git), patch.object(preflight, "github", side_effect=self.responses.__getitem__):
            return preflight.moderation_resolution_diagnostic_backend_recovery(
                self.result if result is None else result, self.runs if runs is None else runs, self.now)

    def test_corrected_backend_diagnostic_preserves_failure_time_and_all_native_gates(self):
        proof = self.prove()
        self.assertEqual(proof["failed_run_ids"], [10]); self.assertEqual(proof["source_sha"], self.source)
        self.assertEqual(proof["candidate_sha"], self.head); self.assertEqual(len(proof["jobs"]), 4)
        self.assertEqual(len(proof["verified_inputs"]), 5)
        self.assertFalse(proof["native_evidence"]); self.assertFalse(proof["release_evidence"])
        gate = lambda runs, **kw: preflight.apply_task_gate(copy.deepcopy(self.result), runs, self.now,
                                                          measure_baseline=True, diagnostic_backend_recovery=proof, **kw)
        result = gate(self.runs)
        self.assertTrue(result["ready"]); self.assertTrue(result["task"]["first_baseline_measurement"])
        self.assertEqual(result["task"]["diagnostic_backend_recovery"], proof)
        self.assertEqual(result["task"]["failed_runs"], [10]); self.assertEqual(result["task"]["runs"], 2)
        self.assertEqual(result["task"]["minutes_since_first_ci"], 15)
        self.assertIsNone(result["task"]["projected_total_minutes"])
        self.assertEqual(result["cost"], {"status": "unmeasured", "samples": []})
        ui = self.failure | {"id": 30, "path": preflight.DIAGNOSTIC_WORKFLOW, "event": "workflow_dispatch"}
        for update in ({"status": "in_progress", "conclusion": None}, {"failed_tests": ["testMissing"]},
                       {"unsupported_failed_tests": ["Other/testMissing"]}):
            self.assertFalse(gate(self.runs + [ui | update])["ready"])
        normal = self.success | {"id": 40, "path": preflight.IOS_WORKFLOW, "head_branch": "codex/moderation-resolution-20261009"}
        self.assertFalse(gate(self.runs + [normal])["task"]["first_baseline_measurement"])
        self.assertFalse(preflight.apply_task_gate(copy.deepcopy(self.result), self.runs, self.now, measure_baseline=True)["ready"])
        with self.assertRaises(ValueError):
            preflight.apply_task_gate(copy.deepcopy(self.result), self.runs, self.now, measure_baseline=True,
                                     diagnostic_backend_recovery=proof | {"candidate_sha": self.old})

    def test_other_scopes_observed_cost_normal_candidates_and_latest_non_success_do_not_qualify(self):
        for changes in ({"scope": planner.MODERATION_OWNER_FLOW_SCOPE}, {"required_jobs": [planner.BUILD]},
                        {"cost": {"status": "observed", "with_upload_minutes": [20, 20]}}):
            self.assertIsNone(self.prove(result=self.result | changes))
        for state, outcome in (("completed", "failure"), ("in_progress", None), ("completed", "skipped")):
            self.assertIsNone(self.prove(runs=[self.failure, self.success | {"status": state, "conclusion": outcome}]))
        for path in (planner.BILLING_WORKFLOW, planner.PRESERVATION_WORKFLOW, preflight.IOS_WORKFLOW):
            self.assertIsNone(self.prove(runs=self.runs + [self.success | {"id": 40, "path": path, "head_branch": "codex/moderation-resolution-20261009"}]))
        self.assertIsNone(self.prove(runs=[self.success]))

    def test_identity_attempt_freshness_and_later_failure_are_not_hidden(self):
        for field, value in (("workflow_id", 8), ("repository", {"full_name": "other/repo"}),
                             ("head_repository", {"full_name": "other/repo"}), ("run_number", None)):
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.prove(runs=[self.failure, self.success | {field: value}])
        original = copy.deepcopy(self.success)
        for field, value in (("head_sha", self.old), ("run_attempt", 0), ("updated_at", "2020-01-01T00:00:00Z")):
            self.success[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError): self.prove()
            self.success.clear(); self.success.update(original)
        for field, value in (("event", "workflow_dispatch"), ("head_branch", "diagnostic/other")):
            self.assertIsNone(self.prove(runs=[self.failure, self.success | {field: value}]))
        with self.assertRaises(ValueError): self.prove(runs=[self.failure, self.success, self.success])
        with self.assertRaises(ValueError): self.prove(runs=[self.failure | {"updated_at": "2026-10-09T11:12:00Z"}, self.success])
        with patch.object(planner, "git", side_effect=subprocess.CalledProcessError(1, "git")):
            with self.assertRaises(subprocess.CalledProcessError):
                preflight.moderation_resolution_diagnostic_backend_recovery(self.result, self.runs, self.now)

    def test_all_backend_tree_content_modes_and_both_workflows_match_candidate(self):
        paths = ("NekoWidget/SharingService", "NekoWidget/PreservationService", "NekoWidget/BillingVerificationService",
                 planner.BILLING_WORKFLOW, planner.PRESERVATION_WORKFLOW)
        for path in paths:
            for ref in (self.source, self.head):
                key = ("ls-tree", ref, "--", path)
                self.git_changes[key] = "120000 blob " + "f" * 40 + "\t" + path
                with self.subTest(path=path, ref=ref), self.assertRaises(ValueError): self.prove()
                self.git_changes.clear()
        self.git_changes[("ls-tree", "-r", "-z", self.head, "--", paths[0])] = "different-child-mode"
        with self.assertRaises(ValueError): self.prove()

    def test_entire_external_input_closure_only_allows_exact_fixture_and_approved_controls(self):
        diff = ("diff", "--raw", "--no-renames", "--no-abbrev", "-z", self.source, self.head)
        fixture = "NekoWidget/NekoWidget/Services/SharingRuntimeSelfTest.swift"
        approved = f":100644 100644 fcb6e70b66160587052876f61022039adef433a7 8a54062ac6254b0a4232bd0264e00ddedf887126 M\0{fixture}\0"
        self.git_changes[diff] = approved
        self.assertEqual(self.prove()["whole_tracked_delta"][0]["kind"], "exact-reviewed-debug-fixture")
        for invalid in (approved.replace("8a54062ac6254b0a4232bd0264e00ddedf887126", "a" * 40),
                        approved.replace(":100644", ":100755"), approved + approved):
            self.git_changes[diff] = invalid
            with self.assertRaises(ValueError): self.prove()
        for path in ("NekoWidget/PreservationImageValidator/src/runtime-budget.mjs", "NekoWidget/ci/fixtures/sharing-protocol-v1.json",
                     "NekoWidget/Shared/Sharing/MomentSharingCore.swift", ".github/workflows/sharing-staging-monitor.yml",
                     ".gitattributes", "NekoWidget/NekoWidget/Views/FamilyWindowView.swift", "NekoWidget/ci/unknown.py"):
            self.git_changes[diff] = f":100644 100644 {'d' * 40} {'e' * 40} M\0{path}\0"
            with self.subTest(path=path), self.assertRaises(ValueError): self.prove()
        path = "NekoWidget/ci/ios_ci_scope.py"
        self.git_changes[diff] = f":100644 100644 {'d' * 40} {'e' * 40} M\0{path}\0"
        with self.assertRaises(ValueError): self.prove()
        self.git_changes[("ls-tree", "origin/main", "--", path)] = f"100644 blob {'e' * 40}\t{path}"
        self.assertEqual(self.prove()["whole_tracked_delta"][0]["kind"], "approved-main-control")
        self.git_changes[diff] = f":000000 100644 {'0' * 40} {'e' * 40} A\0handoffs/resolution.md\0"
        self.assertEqual(self.prove()["whole_tracked_delta"][0]["kind"], "handoff")
        self.git_changes[diff] = self.git_changes[diff].replace(" 100644 ", " 120000 ")
        with self.assertRaises(ValueError): self.prove()

    def test_every_required_job_and_owning_step_must_really_succeed(self):
        original = copy.deepcopy(self.jobs)
        for index in range(4):
            for field, value in (("conclusion", "skipped"), ("head_sha", self.head), ("run_id", 1),
                                 ("run_attempt", 2), ("started_at", "2026-10-09T10:00:00Z"), ("steps", [])):
                self.jobs[index][field] = value
                with self.subTest(job=index, field=field), self.assertRaises(ValueError): self.prove()
                self.jobs[:] = copy.deepcopy(original)
            for n in range(len(self.jobs[index]["steps"])):
                self.jobs[index]["steps"][n]["conclusion"] = "skipped"
                with self.subTest(job=index, step=n), self.assertRaises(ValueError): self.prove()
                self.jobs[:] = copy.deepcopy(original)
        self.responses[self.jobs_path]["total_count"] = 5
        with self.assertRaises(ValueError): self.prove()
        self.responses[self.jobs_path]["total_count"] = 4
        self.jobs[1] = copy.deepcopy(self.jobs[0])
        with self.assertRaises(ValueError): self.prove()


class ModerationResolutionBudgetTests(unittest.TestCase):
    def test_new_combined_scope_is_unmeasured_and_retains_failure_active_time_gates(self):
        selected = planner.MODERATION_RESOLUTION_SCOPE
        history = {"upload_minutes": 9, "observations": [{"scope": scope.FAMILY_WINDOW_UI_SCOPE,
                    "candidate_minutes": 28, "run_id": 1, "outcome": "success"}]}
        cost = preflight.observe_cost(selected, history, True)
        self.assertEqual(cost, {"status": "unmeasured", "samples": []})
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, False, True)
        result = {"scope": selected, "head": "a" * 40, "ready": False, "target_minutes": 50,
                  "required_jobs": list(planner.required_jobs_from_scope(selected)), "cost": cost}
        self.assertFalse(preflight.apply_task_gate(result, [])["ready"])
        self.assertTrue(preflight.apply_task_gate(result, [], measure_baseline=True)["ready"])
        now = dt.datetime.now(dt.timezone.utc)
        for path in (planner.BILLING_WORKFLOW, planner.PRESERVATION_WORKFLOW, ".github/workflows/ios-build.yml"):
            for status, conclusion in (("in_progress", None), ("completed", "failure"), ("completed", "success")):
                run = {"id": 8, "path": path, "status": status, "conclusion": conclusion,
                       "created_at": (now - dt.timedelta(minutes=8)).isoformat()}
                gated = preflight.apply_task_gate(result, [run], now, measure_baseline=True)
                self.assertFalse(gated["ready"])
                self.assertFalse(gated["task"]["first_baseline_measurement"])
                self.assertEqual(gated["task"]["minutes_since_first_ci"], 8)
                self.assertEqual(gated["task"]["failed_runs"], [8] if conclusion == "failure" else [])
                self.assertEqual(gated["task"]["active_runs"], [8] if status != "completed" else [])

    def test_candidate_plan_declares_native_graph_and_separate_same_sha_backend_contract(self):
        head, selected = "a" * 40, planner.MODERATION_RESOLUTION_SCOPE
        with patch.object(planner, "git", side_effect=["", head, "b" * 40]), \
                patch.object(planner, "comparison_base", return_value="b" * 40), \
                patch.object(planner, "changed_paths", return_value=list(planner.MODERATION_RESOLUTION_PATHS)), \
                patch.object(planner, "runtime_scope", return_value=selected):
            result = preflight.candidate_plan("origin/main", 50, True, {"upload_minutes": 9, "observations": []})
        self.assertEqual(result["required_jobs"], list(planner.required_jobs_from_scope(selected)))
        self.assertEqual(result["required_backend_runs"], planner.moderation_resolution_requirements(head))
        self.assertEqual(result["unmapped_files"], [])
        self.assertFalse(result["ready"])
        self.assertIn("both runtime OS", result["reason"])
        self.assertIn("direct Apple feedback", result["reason"])


class PreservationProviderStreamBudgetTests(unittest.TestCase):
    def test_two_job_scope_is_unmeasured_and_cannot_use_native_upload_or_old_timings(self):
        selected = planner.PRESERVATION_PROVIDER_SCOPE
        history = {"upload_minutes": 9, "observations": [
            {"scope": previous, "candidate_minutes": 1.1, "run_id": index, "outcome": "success"}
            for index, previous in enumerate((planner.PRESERVATION_SCOPE, planner.PRESERVATION_UPLOAD_SCOPE, planner.JPEG_SCOPE))]}
        cost = preflight.observe_cost(selected, history, False)
        self.assertEqual(cost["status"], "unmeasured")
        self.assertEqual(cost["samples"], [])
        self.assertEqual(cost["measurement_job_timeouts_minutes"],
                         {planner.PRESERVATION_WORKFLOW: 5, planner.JPEG_WORKFLOW: 10})
        self.assertNotIn("with_upload_minutes", cost)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, True)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, False, True)
        result = {"scope": selected, "head": "a" * 40, "ready": False, "target_minutes": 30,
                  "required_jobs": [planner.PRESERVATION_JOB, planner.JPEG_JOB], "cost": cost}
        self.assertFalse(preflight.apply_task_gate(result, [])["ready"])
        self.assertTrue(preflight.apply_task_gate(result, [], measure_baseline=True)["ready"])
        now = dt.datetime.now(dt.timezone.utc)
        for workflow in (planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW):
            for state, conclusion in (("in_progress", None), ("completed", "failure"), ("completed", "success")):
                run = {"id": 8, "path": workflow, "status": state, "conclusion": conclusion,
                       "created_at": (now - dt.timedelta(minutes=8)).isoformat()}
                gated = preflight.apply_task_gate(result, [run], now, measure_baseline=True)
                self.assertFalse(gated["ready"])
                self.assertFalse(gated["task"]["first_baseline_measurement"])
                self.assertEqual(gated["task"]["minutes_since_first_ci"], 8)
                self.assertEqual(gated["task"]["failed_runs"], [8] if conclusion == "failure" else [])
                self.assertEqual(gated["task"]["active_runs"], [8] if state != "completed" else [])

    def test_candidate_plan_binds_both_workflow_jobs_to_one_head(self):
        head = "a" * 40
        with patch.object(planner, "git", side_effect=["", head, "b" * 40]), \
                patch.object(planner, "comparison_base", return_value="b" * 40), \
                patch.object(planner, "changed_paths", return_value=list(planner.PRESERVATION_PROVIDER_PATHS)), \
                patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_PROVIDER_SCOPE):
            result = preflight.candidate_plan("origin/main", 30, False, {"upload_minutes": 9, "observations": []})
        self.assertEqual(result["head"], head)
        self.assertEqual(result["required_jobs"], [planner.PRESERVATION_JOB, planner.JPEG_JOB])
        self.assertEqual({row["workflow"] for row in result["required_backend_runs"]},
                         {planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW})
        self.assertTrue(all(row["head_sha"] == head and row["success_required"]
                            for row in result["required_backend_runs"]))
        self.assertEqual(result["unmapped_files"], [])
        self.assertFalse(result["ready"])
        self.assertIn("both same-SHA", result["reason"])
        self.assertIn("no native, live-cloud or release evidence", result["reason"])

    def test_task_history_collects_both_backend_workflows_before_gating(self):
        runs = [{"id": index, "path": workflow, "status": "in_progress", "conclusion": None}
                for index, workflow in enumerate((planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW), 1)]
        with patch.object(planner, "git", return_value="codex/provider-stream"), \
                patch.object(preflight, "github", return_value={"total_count": 2, "workflow_runs": runs}):
            result = preflight.read_task_runs("a" * 40)
        self.assertEqual({row["path"] for row in result}, {planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW})
        self.assertEqual({row["id"] for row in result}, {1, 2})


class ModerationAIDurableBudgetTests(unittest.TestCase):
    def test_unmeasured_scope_keeps_both_workflow_history_and_disallows_old_timings_or_upload(self):
        selected = planner.MODERATION_AI_DURABLE_SCOPE
        history = {"upload_minutes": 9, "observations": [
            {"scope": previous, "candidate_minutes": 1.1, "run_id": index, "outcome": "success"}
            for index, previous in enumerate((planner.MODERATION_AI_TRANSPORT_SCOPE, planner.MODERATION_AI_SCOPE, planner.MODERATION_ENROLLMENT_SCOPE, planner.PRESERVATION_SCOPE,
                                               planner.PRESERVATION_RECOVERY_READ_SCOPE, planner.BILLING_AUTHORITY_SCOPE))]}
        cost = preflight.observe_cost(selected, history, False)
        self.assertEqual(cost["status"], "unmeasured")
        self.assertEqual(cost["samples"], [])
        self.assertEqual(cost["measurement_job_timeouts_minutes"], planner.MODERATION_AI_DURABLE_JOB_TIMEOUTS)
        self.assertNotIn("with_upload_minutes", cost)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, True)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, False, True)
        result = {"scope": selected, "head": "a" * 40, "ready": False, "target_minutes": 30, "cost": cost}
        self.assertFalse(preflight.apply_task_gate(result, [])["ready"])
        self.assertTrue(preflight.apply_task_gate(result, [], measure_baseline=True)["ready"])
        now = dt.datetime.now(dt.timezone.utc)
        for workflow in (planner.MODERATION_AI_DURABLE_WORKFLOW, planner.PRESERVATION_WORKFLOW):
            for state, conclusion in (("in_progress", None), ("completed", "failure"), ("completed", "success")):
                run = {"id": 8, "path": workflow, "status": state, "conclusion": conclusion,
                       "created_at": (now - dt.timedelta(minutes=8)).isoformat()}
                gated = preflight.apply_task_gate(result, [run], now, measure_baseline=True)
                self.assertFalse(gated["ready"])
                self.assertFalse(gated["task"]["first_baseline_measurement"])
                self.assertEqual(gated["task"]["minutes_since_first_ci"], 8)
                self.assertEqual(gated["task"]["failed_runs"], [8] if conclusion == "failure" else [])
                self.assertEqual(gated["task"]["active_runs"], [8] if state != "completed" else [])

    def test_candidate_plan_requires_all_five_owning_push_jobs_on_the_same_head(self):
        head = "a" * 40
        with patch.object(planner, "git", side_effect=["", head, "b" * 40]), \
                patch.object(planner, "comparison_base", return_value="b" * 40), \
                patch.object(planner, "changed_paths", return_value=list(planner.MODERATION_AI_DURABLE_PATHS)), \
                patch.object(planner, "runtime_scope", return_value=planner.MODERATION_AI_DURABLE_SCOPE):
            result = preflight.candidate_plan("origin/main", 30, False, {"upload_minutes": 9, "observations": []})
        self.assertEqual(result["head"], head)
        self.assertEqual(result["required_jobs"], list(planner.MODERATION_AI_DURABLE_JOBS))
        self.assertEqual(result["required_backend_runs"], [
            {"workflow": planner.MODERATION_AI_DURABLE_WORKFLOW, "job": job,
             "head_sha": head, "event": "push", "success_required": True}
            for job in planner.MODERATION_AI_DURABLE_JOBS[:-1]] + [
            {"workflow": planner.PRESERVATION_WORKFLOW, "job": planner.PRESERVATION_JOB,
             "head_sha": head, "event": "push", "success_required": True}])
        self.assertEqual(result["unmapped_files"], [])
        self.assertFalse(result["ready"])
        self.assertIn("all four same-SHA Sharing workflow jobs", result["reason"])
        self.assertIn("automatically triggered Preservation job", result["reason"])
        self.assertIn("full local D1 migration chain", result["reason"])
        self.assertIn("no native, live-cloud or release evidence", result["reason"])

    def test_task_history_keeps_failures_and_active_runs_from_both_workflows(self):
        now = dt.datetime.now(dt.timezone.utc)
        runs = [{"id": i, "path": workflow, "status": status, "conclusion": conclusion,
                 "created_at": (now - dt.timedelta(minutes=12 - i)).isoformat()}
                for i, workflow, status, conclusion in (
                    (1, planner.MODERATION_AI_DURABLE_WORKFLOW, "completed", "failure"),
                    (2, planner.MODERATION_AI_DURABLE_WORKFLOW, "in_progress", None),
                    (3, planner.PRESERVATION_WORKFLOW, "completed", "failure"),
                    (4, planner.PRESERVATION_WORKFLOW, "in_progress", None))]
        with patch.object(planner, "git", return_value="codex/moderation-ai-durable"), \
                patch.object(preflight, "github", return_value={"total_count": 4, "workflow_runs": runs}):
            history = preflight.read_task_runs("a" * 40)
        self.assertEqual({row["id"] for row in history}, {1, 2, 3, 4})
        self.assertEqual({row["path"] for row in history}, {planner.MODERATION_AI_DURABLE_WORKFLOW, planner.PRESERVATION_WORKFLOW})
        result = {"scope": planner.MODERATION_AI_DURABLE_SCOPE, "head": "a" * 40, "ready": False,
                  "target_minutes": 30, "cost": {"status": "unmeasured", "samples": []}}
        gated = preflight.apply_task_gate(result, history, now, measure_baseline=True)
        self.assertFalse(gated["ready"])
        self.assertFalse(gated["task"]["first_baseline_measurement"])
        self.assertEqual(gated["task"]["minutes_since_first_ci"], 11)
        self.assertEqual(set(gated["task"]["failed_runs"]), {1, 3})
        self.assertEqual(set(gated["task"]["active_runs"]), {2, 4})


class ModerationOwnerFlowBudgetTests(unittest.TestCase):
    def test_unmeasured_scope_keeps_both_workflow_history_and_disallows_old_timings_or_upload(self):
        selected = planner.MODERATION_OWNER_FLOW_SCOPE
        history = {"upload_minutes": 9, "observations": [
            {"scope": previous, "candidate_minutes": 1.1, "run_id": index, "outcome": "success"}
            for index, previous in enumerate((planner.MODERATION_REVIEW_EVIDENCE_SCOPE, planner.MODERATION_CONSOLE_SCOPE, planner.MODERATION_AI_DURABLE_SCOPE, planner.MODERATION_AI_TRANSPORT_SCOPE, planner.MODERATION_AI_SCOPE, planner.MODERATION_ENROLLMENT_SCOPE, planner.PRESERVATION_SCOPE,
                                               planner.PRESERVATION_RECOVERY_READ_SCOPE, planner.BILLING_AUTHORITY_SCOPE))]}
        cost = preflight.observe_cost(selected, history, False)
        self.assertEqual(cost["status"], "unmeasured")
        self.assertEqual(cost["samples"], [])
        self.assertEqual(cost["measurement_job_timeouts_minutes"], planner.MODERATION_OWNER_FLOW_JOB_TIMEOUTS)
        self.assertNotIn("with_upload_minutes", cost)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, True)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, False, True)
        result = {"scope": selected, "head": "a" * 40, "ready": False, "target_minutes": 30, "cost": cost}
        self.assertFalse(preflight.apply_task_gate(result, [])["ready"])
        self.assertTrue(preflight.apply_task_gate(result, [], measure_baseline=True)["ready"])
        now = dt.datetime.now(dt.timezone.utc)
        for workflow in (planner.MODERATION_OWNER_FLOW_WORKFLOW, planner.PRESERVATION_WORKFLOW):
            for state, conclusion in (("in_progress", None), ("completed", "failure"), ("completed", "success")):
                run = {"id": 8, "path": workflow, "status": state, "conclusion": conclusion,
                       "created_at": (now - dt.timedelta(minutes=8)).isoformat()}
                gated = preflight.apply_task_gate(result, [run], now, measure_baseline=True)
                self.assertFalse(gated["ready"])
                self.assertFalse(gated["task"]["first_baseline_measurement"])
                self.assertEqual(gated["task"]["minutes_since_first_ci"], 8)
                self.assertEqual(gated["task"]["failed_runs"], [8] if conclusion == "failure" else [])
                self.assertEqual(gated["task"]["active_runs"], [8] if state != "completed" else [])

    def test_candidate_plan_requires_all_five_owning_push_jobs_on_the_same_head(self):
        head = "a" * 40
        with patch.object(planner, "git", side_effect=["", head, "b" * 40]), \
                patch.object(planner, "comparison_base", return_value="b" * 40), \
                patch.object(planner, "changed_paths", return_value=list(planner.MODERATION_OWNER_FLOW_PATHS)), \
                patch.object(planner, "runtime_scope", return_value=planner.MODERATION_OWNER_FLOW_SCOPE):
            result = preflight.candidate_plan("origin/main", 30, False, {"upload_minutes": 9, "observations": []})
        self.assertEqual(result["head"], head)
        self.assertEqual(result["required_jobs"], list(planner.MODERATION_OWNER_FLOW_JOBS))
        self.assertEqual(result["required_backend_runs"], [
            {"workflow": planner.MODERATION_OWNER_FLOW_WORKFLOW, "job": job,
             "head_sha": head, "event": "push", "success_required": True}
            for job in planner.MODERATION_OWNER_FLOW_JOBS[:-1]] + [
            {"workflow": planner.PRESERVATION_WORKFLOW, "job": planner.PRESERVATION_JOB,
             "head_sha": head, "event": "push", "success_required": True}])
        self.assertEqual(result["unmapped_files"], [])
        self.assertFalse(result["ready"])
        self.assertIn("all four same-SHA Sharing workflow jobs", result["reason"])
        self.assertIn("automatically triggered Preservation job", result["reason"])
        self.assertIn("no native, live-cloud or release evidence", result["reason"])

    def test_task_history_keeps_failures_and_active_runs_from_both_workflows(self):
        now = dt.datetime.now(dt.timezone.utc)
        runs = [{"id": i, "path": workflow, "status": status, "conclusion": conclusion,
                 "created_at": (now - dt.timedelta(minutes=12 - i)).isoformat()}
                for i, workflow, status, conclusion in (
                    (1, planner.MODERATION_OWNER_FLOW_WORKFLOW, "completed", "failure"),
                    (2, planner.MODERATION_OWNER_FLOW_WORKFLOW, "in_progress", None),
                    (3, planner.PRESERVATION_WORKFLOW, "completed", "failure"),
                    (4, planner.PRESERVATION_WORKFLOW, "in_progress", None))]
        with patch.object(planner, "git", return_value="codex/moderation-owner-flow"), \
                patch.object(preflight, "github", return_value={"total_count": 4, "workflow_runs": runs}):
            history = preflight.read_task_runs("a" * 40)
        self.assertEqual({row["id"] for row in history}, {1, 2, 3, 4})
        self.assertEqual({row["path"] for row in history}, {planner.MODERATION_OWNER_FLOW_WORKFLOW, planner.PRESERVATION_WORKFLOW})
        result = {"scope": planner.MODERATION_OWNER_FLOW_SCOPE, "head": "a" * 40, "ready": False,
                  "target_minutes": 30, "cost": {"status": "unmeasured", "samples": []}}
        gated = preflight.apply_task_gate(result, history, now, measure_baseline=True)
        self.assertFalse(gated["ready"])
        self.assertFalse(gated["task"]["first_baseline_measurement"])
        self.assertEqual(gated["task"]["minutes_since_first_ci"], 11)
        self.assertEqual(set(gated["task"]["failed_runs"]), {1, 3})
        self.assertEqual(set(gated["task"]["active_runs"]), {2, 4})




class ModerationReviewEvidenceBudgetTests(unittest.TestCase):
    def test_unmeasured_scope_keeps_both_workflow_history_and_disallows_old_timings_or_upload(self):
        selected = planner.MODERATION_REVIEW_EVIDENCE_SCOPE
        history = {"upload_minutes": 9, "observations": [
            {"scope": previous, "candidate_minutes": 1.1, "run_id": index, "outcome": "success"}
            for index, previous in enumerate((planner.MODERATION_CONSOLE_SCOPE, planner.MODERATION_AI_DURABLE_SCOPE, planner.MODERATION_AI_TRANSPORT_SCOPE, planner.MODERATION_AI_SCOPE, planner.MODERATION_ENROLLMENT_SCOPE, planner.PRESERVATION_SCOPE,
                                               planner.PRESERVATION_RECOVERY_READ_SCOPE, planner.BILLING_AUTHORITY_SCOPE))]}
        cost = preflight.observe_cost(selected, history, False)
        self.assertEqual(cost["status"], "unmeasured")
        self.assertEqual(cost["samples"], [])
        self.assertEqual(cost["measurement_job_timeouts_minutes"], planner.MODERATION_REVIEW_EVIDENCE_JOB_TIMEOUTS)
        self.assertNotIn("with_upload_minutes", cost)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, True)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, False, True)
        result = {"scope": selected, "head": "a" * 40, "ready": False, "target_minutes": 30, "cost": cost}
        self.assertFalse(preflight.apply_task_gate(result, [])["ready"])
        self.assertTrue(preflight.apply_task_gate(result, [], measure_baseline=True)["ready"])
        now = dt.datetime.now(dt.timezone.utc)
        for workflow in (planner.MODERATION_REVIEW_EVIDENCE_WORKFLOW, planner.PRESERVATION_WORKFLOW):
            for state, conclusion in (("in_progress", None), ("completed", "failure"), ("completed", "success")):
                run = {"id": 8, "path": workflow, "status": state, "conclusion": conclusion,
                       "created_at": (now - dt.timedelta(minutes=8)).isoformat()}
                gated = preflight.apply_task_gate(result, [run], now, measure_baseline=True)
                self.assertFalse(gated["ready"])
                self.assertFalse(gated["task"]["first_baseline_measurement"])
                self.assertEqual(gated["task"]["minutes_since_first_ci"], 8)
                self.assertEqual(gated["task"]["failed_runs"], [8] if conclusion == "failure" else [])
                self.assertEqual(gated["task"]["active_runs"], [8] if state != "completed" else [])

    def test_candidate_plan_requires_all_five_owning_push_jobs_on_the_same_head(self):
        head = "a" * 40
        with patch.object(planner, "git", side_effect=["", head, "b" * 40]), \
                patch.object(planner, "comparison_base", return_value="b" * 40), \
                patch.object(planner, "changed_paths", return_value=list(planner.MODERATION_REVIEW_EVIDENCE_PATHS)), \
                patch.object(planner, "runtime_scope", return_value=planner.MODERATION_REVIEW_EVIDENCE_SCOPE):
            result = preflight.candidate_plan("origin/main", 30, False, {"upload_minutes": 9, "observations": []})
        self.assertEqual(result["head"], head)
        self.assertEqual(result["required_jobs"], list(planner.MODERATION_REVIEW_EVIDENCE_JOBS))
        self.assertEqual(result["required_backend_runs"], [
            {"workflow": planner.MODERATION_REVIEW_EVIDENCE_WORKFLOW, "job": job,
             "head_sha": head, "event": "push", "success_required": True}
            for job in planner.MODERATION_REVIEW_EVIDENCE_JOBS[:-1]] + [
            {"workflow": planner.PRESERVATION_WORKFLOW, "job": planner.PRESERVATION_JOB,
             "head_sha": head, "event": "push", "success_required": True}])
        self.assertEqual(result["unmapped_files"], [])
        self.assertFalse(result["ready"])
        self.assertIn("all four same-SHA Sharing workflow jobs", result["reason"])
        self.assertIn("automatically triggered Preservation job", result["reason"])
        self.assertIn("no native, live-cloud or release evidence", result["reason"])

    def test_task_history_keeps_failures_and_active_runs_from_both_workflows(self):
        now = dt.datetime.now(dt.timezone.utc)
        runs = [{"id": i, "path": workflow, "status": status, "conclusion": conclusion,
                 "created_at": (now - dt.timedelta(minutes=12 - i)).isoformat()}
                for i, workflow, status, conclusion in (
                    (1, planner.MODERATION_REVIEW_EVIDENCE_WORKFLOW, "completed", "failure"),
                    (2, planner.MODERATION_REVIEW_EVIDENCE_WORKFLOW, "in_progress", None),
                    (3, planner.PRESERVATION_WORKFLOW, "completed", "failure"),
                    (4, planner.PRESERVATION_WORKFLOW, "in_progress", None))]
        with patch.object(planner, "git", return_value="codex/moderation-review-evidence"), \
                patch.object(preflight, "github", return_value={"total_count": 4, "workflow_runs": runs}):
            history = preflight.read_task_runs("a" * 40)
        self.assertEqual({row["id"] for row in history}, {1, 2, 3, 4})
        self.assertEqual({row["path"] for row in history}, {planner.MODERATION_REVIEW_EVIDENCE_WORKFLOW, planner.PRESERVATION_WORKFLOW})
        result = {"scope": planner.MODERATION_REVIEW_EVIDENCE_SCOPE, "head": "a" * 40, "ready": False,
                  "target_minutes": 30, "cost": {"status": "unmeasured", "samples": []}}
        gated = preflight.apply_task_gate(result, history, now, measure_baseline=True)
        self.assertFalse(gated["ready"])
        self.assertFalse(gated["task"]["first_baseline_measurement"])
        self.assertEqual(gated["task"]["minutes_since_first_ci"], 11)
        self.assertEqual(set(gated["task"]["failed_runs"]), {1, 3})
        self.assertEqual(set(gated["task"]["active_runs"]), {2, 4})




class ModerationConsoleBudgetTests(unittest.TestCase):
    def test_unmeasured_scope_keeps_both_workflow_history_and_disallows_old_timings_or_upload(self):
        selected = planner.MODERATION_CONSOLE_SCOPE
        history = {"upload_minutes": 9, "observations": [
            {"scope": previous, "candidate_minutes": 1.1, "run_id": index, "outcome": "success"}
            for index, previous in enumerate((planner.MODERATION_AI_DURABLE_SCOPE, planner.MODERATION_AI_TRANSPORT_SCOPE, planner.MODERATION_AI_SCOPE, planner.MODERATION_ENROLLMENT_SCOPE, planner.PRESERVATION_SCOPE,
                                               planner.PRESERVATION_RECOVERY_READ_SCOPE, planner.BILLING_AUTHORITY_SCOPE))]}
        cost = preflight.observe_cost(selected, history, False)
        self.assertEqual(cost["status"], "unmeasured")
        self.assertEqual(cost["samples"], [])
        self.assertEqual(cost["measurement_job_timeouts_minutes"], planner.MODERATION_CONSOLE_JOB_TIMEOUTS)
        self.assertNotIn("with_upload_minutes", cost)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, True)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, False, True)
        result = {"scope": selected, "head": "a" * 40, "ready": False, "target_minutes": 30, "cost": cost}
        self.assertFalse(preflight.apply_task_gate(result, [])["ready"])
        self.assertTrue(preflight.apply_task_gate(result, [], measure_baseline=True)["ready"])
        now = dt.datetime.now(dt.timezone.utc)
        for workflow in (planner.MODERATION_CONSOLE_WORKFLOW, planner.PRESERVATION_WORKFLOW):
            for state, conclusion in (("in_progress", None), ("completed", "failure"), ("completed", "success")):
                run = {"id": 8, "path": workflow, "status": state, "conclusion": conclusion,
                       "created_at": (now - dt.timedelta(minutes=8)).isoformat()}
                gated = preflight.apply_task_gate(result, [run], now, measure_baseline=True)
                self.assertFalse(gated["ready"])
                self.assertFalse(gated["task"]["first_baseline_measurement"])
                self.assertEqual(gated["task"]["minutes_since_first_ci"], 8)
                self.assertEqual(gated["task"]["failed_runs"], [8] if conclusion == "failure" else [])
                self.assertEqual(gated["task"]["active_runs"], [8] if state != "completed" else [])

    def test_candidate_plan_requires_all_five_owning_push_jobs_on_the_same_head(self):
        head = "a" * 40
        with patch.object(planner, "git", side_effect=["", head, "b" * 40]), \
                patch.object(planner, "comparison_base", return_value="b" * 40), \
                patch.object(planner, "changed_paths", return_value=list(planner.MODERATION_CONSOLE_PATHS)), \
                patch.object(planner, "runtime_scope", return_value=planner.MODERATION_CONSOLE_SCOPE):
            result = preflight.candidate_plan("origin/main", 30, False, {"upload_minutes": 9, "observations": []})
        self.assertEqual(result["head"], head)
        self.assertEqual(result["required_jobs"], list(planner.MODERATION_CONSOLE_JOBS))
        self.assertEqual(result["required_backend_runs"], [
            {"workflow": planner.MODERATION_CONSOLE_WORKFLOW, "job": job,
             "head_sha": head, "event": "push", "success_required": True}
            for job in planner.MODERATION_CONSOLE_JOBS[:-1]] + [
            {"workflow": planner.PRESERVATION_WORKFLOW, "job": planner.PRESERVATION_JOB,
             "head_sha": head, "event": "push", "success_required": True}])
        self.assertEqual(result["unmapped_files"], [])
        self.assertFalse(result["ready"])
        self.assertIn("all four same-SHA Sharing workflow jobs", result["reason"])
        self.assertIn("automatically triggered Preservation job", result["reason"])
        self.assertIn("no native, live-cloud or release evidence", result["reason"])

    def test_task_history_keeps_failures_and_active_runs_from_both_workflows(self):
        now = dt.datetime.now(dt.timezone.utc)
        runs = [{"id": i, "path": workflow, "status": status, "conclusion": conclusion,
                 "created_at": (now - dt.timedelta(minutes=12 - i)).isoformat()}
                for i, workflow, status, conclusion in (
                    (1, planner.MODERATION_CONSOLE_WORKFLOW, "completed", "failure"),
                    (2, planner.MODERATION_CONSOLE_WORKFLOW, "in_progress", None),
                    (3, planner.PRESERVATION_WORKFLOW, "completed", "failure"),
                    (4, planner.PRESERVATION_WORKFLOW, "in_progress", None))]
        with patch.object(planner, "git", return_value="codex/moderation-console"), \
                patch.object(preflight, "github", return_value={"total_count": 4, "workflow_runs": runs}):
            history = preflight.read_task_runs("a" * 40)
        self.assertEqual({row["id"] for row in history}, {1, 2, 3, 4})
        self.assertEqual({row["path"] for row in history}, {planner.MODERATION_CONSOLE_WORKFLOW, planner.PRESERVATION_WORKFLOW})
        result = {"scope": planner.MODERATION_CONSOLE_SCOPE, "head": "a" * 40, "ready": False,
                  "target_minutes": 30, "cost": {"status": "unmeasured", "samples": []}}
        gated = preflight.apply_task_gate(result, history, now, measure_baseline=True)
        self.assertFalse(gated["ready"])
        self.assertFalse(gated["task"]["first_baseline_measurement"])
        self.assertEqual(gated["task"]["minutes_since_first_ci"], 11)
        self.assertEqual(set(gated["task"]["failed_runs"]), {1, 3})
        self.assertEqual(set(gated["task"]["active_runs"]), {2, 4})



class ModerationAITransportBudgetTests(unittest.TestCase):
    def test_unmeasured_scope_keeps_both_workflow_history_and_disallows_old_timings_or_upload(self):
        selected = planner.MODERATION_AI_TRANSPORT_SCOPE
        history = {"upload_minutes": 9, "observations": [
            {"scope": previous, "candidate_minutes": 1.1, "run_id": index, "outcome": "success"}
            for index, previous in enumerate((planner.MODERATION_AI_SCOPE, planner.MODERATION_ENROLLMENT_SCOPE, planner.PRESERVATION_SCOPE,
                                               planner.PRESERVATION_RECOVERY_READ_SCOPE, planner.BILLING_AUTHORITY_SCOPE))]}
        cost = preflight.observe_cost(selected, history, False)
        self.assertEqual(cost["status"], "unmeasured")
        self.assertEqual(cost["samples"], [])
        self.assertEqual(cost["measurement_job_timeouts_minutes"], planner.MODERATION_AI_TRANSPORT_JOB_TIMEOUTS)
        self.assertNotIn("with_upload_minutes", cost)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, True)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, False, True)
        result = {"scope": selected, "head": "a" * 40, "ready": False, "target_minutes": 30, "cost": cost}
        self.assertFalse(preflight.apply_task_gate(result, [])["ready"])
        self.assertTrue(preflight.apply_task_gate(result, [], measure_baseline=True)["ready"])
        now = dt.datetime.now(dt.timezone.utc)
        for workflow in (planner.MODERATION_AI_TRANSPORT_WORKFLOW, planner.PRESERVATION_WORKFLOW):
            for state, conclusion in (("in_progress", None), ("completed", "failure"), ("completed", "success")):
                run = {"id": 8, "path": workflow, "status": state, "conclusion": conclusion,
                       "created_at": (now - dt.timedelta(minutes=8)).isoformat()}
                gated = preflight.apply_task_gate(result, [run], now, measure_baseline=True)
                self.assertFalse(gated["ready"])
                self.assertFalse(gated["task"]["first_baseline_measurement"])
                self.assertEqual(gated["task"]["minutes_since_first_ci"], 8)
                self.assertEqual(gated["task"]["failed_runs"], [8] if conclusion == "failure" else [])
                self.assertEqual(gated["task"]["active_runs"], [8] if state != "completed" else [])

    def test_candidate_plan_requires_all_five_owning_push_jobs_on_the_same_head(self):
        head = "a" * 40
        with patch.object(planner, "git", side_effect=["", head, "b" * 40]), \
                patch.object(planner, "comparison_base", return_value="b" * 40), \
                patch.object(planner, "changed_paths", return_value=list(planner.MODERATION_AI_TRANSPORT_PATHS)), \
                patch.object(planner, "runtime_scope", return_value=planner.MODERATION_AI_TRANSPORT_SCOPE):
            result = preflight.candidate_plan("origin/main", 30, False, {"upload_minutes": 9, "observations": []})
        self.assertEqual(result["head"], head)
        self.assertEqual(result["required_jobs"], list(planner.MODERATION_AI_TRANSPORT_JOBS))
        self.assertEqual(result["required_backend_runs"], [
            {"workflow": planner.MODERATION_AI_TRANSPORT_WORKFLOW, "job": job,
             "head_sha": head, "event": "push", "success_required": True}
            for job in planner.MODERATION_AI_TRANSPORT_JOBS[:-1]] + [
            {"workflow": planner.PRESERVATION_WORKFLOW, "job": planner.PRESERVATION_JOB,
             "head_sha": head, "event": "push", "success_required": True}])
        self.assertEqual(result["unmapped_files"], [])
        self.assertFalse(result["ready"])
        self.assertIn("all four same-SHA Sharing workflow jobs", result["reason"])
        self.assertIn("automatically triggered Preservation job", result["reason"])
        self.assertIn("no native, live-cloud or release evidence", result["reason"])

    def test_task_history_keeps_failures_and_active_runs_from_both_workflows(self):
        now = dt.datetime.now(dt.timezone.utc)
        runs = [{"id": i, "path": workflow, "status": status, "conclusion": conclusion,
                 "created_at": (now - dt.timedelta(minutes=12 - i)).isoformat()}
                for i, workflow, status, conclusion in (
                    (1, planner.MODERATION_AI_TRANSPORT_WORKFLOW, "completed", "failure"),
                    (2, planner.MODERATION_AI_TRANSPORT_WORKFLOW, "in_progress", None),
                    (3, planner.PRESERVATION_WORKFLOW, "completed", "failure"),
                    (4, planner.PRESERVATION_WORKFLOW, "in_progress", None))]
        with patch.object(planner, "git", return_value="codex/moderation-ai-transport"), \
                patch.object(preflight, "github", return_value={"total_count": 4, "workflow_runs": runs}):
            history = preflight.read_task_runs("a" * 40)
        self.assertEqual({row["id"] for row in history}, {1, 2, 3, 4})
        self.assertEqual({row["path"] for row in history}, {planner.MODERATION_AI_TRANSPORT_WORKFLOW, planner.PRESERVATION_WORKFLOW})
        result = {"scope": planner.MODERATION_AI_TRANSPORT_SCOPE, "head": "a" * 40, "ready": False,
                  "target_minutes": 30, "cost": {"status": "unmeasured", "samples": []}}
        gated = preflight.apply_task_gate(result, history, now, measure_baseline=True)
        self.assertFalse(gated["ready"])
        self.assertFalse(gated["task"]["first_baseline_measurement"])
        self.assertEqual(gated["task"]["minutes_since_first_ci"], 11)
        self.assertEqual(set(gated["task"]["failed_runs"]), {1, 3})
        self.assertEqual(set(gated["task"]["active_runs"]), {2, 4})


class ModerationAIAdvisoryBudgetTests(unittest.TestCase):
    def test_unmeasured_scope_keeps_both_workflow_history_and_disallows_old_timings_or_upload(self):
        selected = planner.MODERATION_AI_SCOPE
        history = {"upload_minutes": 9, "observations": [
            {"scope": previous, "candidate_minutes": 1.1, "run_id": index, "outcome": "success"}
            for index, previous in enumerate((planner.MODERATION_ENROLLMENT_SCOPE, planner.PRESERVATION_SCOPE,
                                               planner.PRESERVATION_RECOVERY_READ_SCOPE, planner.BILLING_AUTHORITY_SCOPE))]}
        cost = preflight.observe_cost(selected, history, False)
        self.assertEqual(cost["status"], "unmeasured")
        self.assertEqual(cost["samples"], [])
        self.assertEqual(cost["measurement_job_timeouts_minutes"], planner.MODERATION_AI_JOB_TIMEOUTS)
        self.assertNotIn("with_upload_minutes", cost)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, True)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, False, True)
        result = {"scope": selected, "head": "a" * 40, "ready": False, "target_minutes": 30, "cost": cost}
        self.assertFalse(preflight.apply_task_gate(result, [])["ready"])
        self.assertTrue(preflight.apply_task_gate(result, [], measure_baseline=True)["ready"])
        now = dt.datetime.now(dt.timezone.utc)
        for workflow in (planner.MODERATION_AI_WORKFLOW, planner.PRESERVATION_WORKFLOW):
            for state, conclusion in (("in_progress", None), ("completed", "failure"), ("completed", "success")):
                run = {"id": 8, "path": workflow, "status": state, "conclusion": conclusion,
                       "created_at": (now - dt.timedelta(minutes=8)).isoformat()}
                gated = preflight.apply_task_gate(result, [run], now, measure_baseline=True)
                self.assertFalse(gated["ready"])
                self.assertFalse(gated["task"]["first_baseline_measurement"])
                self.assertEqual(gated["task"]["minutes_since_first_ci"], 8)
                self.assertEqual(gated["task"]["failed_runs"], [8] if conclusion == "failure" else [])
                self.assertEqual(gated["task"]["active_runs"], [8] if state != "completed" else [])

    def test_candidate_plan_requires_all_five_owning_push_jobs_on_the_same_head(self):
        head = "a" * 40
        with patch.object(planner, "git", side_effect=["", head, "b" * 40]), \
                patch.object(planner, "comparison_base", return_value="b" * 40), \
                patch.object(planner, "changed_paths", return_value=list(planner.MODERATION_AI_PATHS)), \
                patch.object(planner, "runtime_scope", return_value=planner.MODERATION_AI_SCOPE):
            result = preflight.candidate_plan("origin/main", 30, False, {"upload_minutes": 9, "observations": []})
        self.assertEqual(result["head"], head)
        self.assertEqual(result["required_jobs"], list(planner.MODERATION_AI_JOBS))
        self.assertEqual(result["required_backend_runs"], [
            {"workflow": planner.MODERATION_AI_WORKFLOW, "job": job,
             "head_sha": head, "event": "push", "success_required": True}
            for job in planner.MODERATION_AI_JOBS[:-1]] + [
            {"workflow": planner.PRESERVATION_WORKFLOW, "job": planner.PRESERVATION_JOB,
             "head_sha": head, "event": "push", "success_required": True}])
        self.assertEqual(result["unmapped_files"], [])
        self.assertFalse(result["ready"])
        self.assertIn("all four same-SHA Sharing workflow jobs", result["reason"])
        self.assertIn("automatically triggered Preservation job", result["reason"])
        self.assertIn("no native, live-cloud or release evidence", result["reason"])

    def test_task_history_keeps_failures_and_active_runs_from_both_workflows(self):
        now = dt.datetime.now(dt.timezone.utc)
        runs = [{"id": i, "path": workflow, "status": status, "conclusion": conclusion,
                 "created_at": (now - dt.timedelta(minutes=12 - i)).isoformat()}
                for i, workflow, status, conclusion in (
                    (1, planner.MODERATION_AI_WORKFLOW, "completed", "failure"),
                    (2, planner.MODERATION_AI_WORKFLOW, "in_progress", None),
                    (3, planner.PRESERVATION_WORKFLOW, "completed", "failure"),
                    (4, planner.PRESERVATION_WORKFLOW, "in_progress", None))]
        with patch.object(planner, "git", return_value="codex/moderation-ai-advisory"), \
                patch.object(preflight, "github", return_value={"total_count": 4, "workflow_runs": runs}):
            history = preflight.read_task_runs("a" * 40)
        self.assertEqual({row["id"] for row in history}, {1, 2, 3, 4})
        self.assertEqual({row["path"] for row in history}, {planner.MODERATION_AI_WORKFLOW, planner.PRESERVATION_WORKFLOW})
        result = {"scope": planner.MODERATION_AI_SCOPE, "head": "a" * 40, "ready": False,
                  "target_minutes": 30, "cost": {"status": "unmeasured", "samples": []}}
        gated = preflight.apply_task_gate(result, history, now, measure_baseline=True)
        self.assertFalse(gated["ready"])
        self.assertFalse(gated["task"]["first_baseline_measurement"])
        self.assertEqual(gated["task"]["minutes_since_first_ci"], 11)
        self.assertEqual(set(gated["task"]["failed_runs"]), {1, 3})
        self.assertEqual(set(gated["task"]["active_runs"]), {2, 4})


class ModerationEnrollmentBudgetTests(unittest.TestCase):
    def test_separate_unmeasured_scope_retains_first_run_history_and_upload_gates(self):
        selected = planner.MODERATION_ENROLLMENT_SCOPE
        history = {"upload_minutes": 9, "observations": [
            {"scope": previous, "candidate_minutes": 1.1, "run_id": index, "outcome": "success"}
            for index, previous in enumerate((planner.PRESERVATION_SCOPE, planner.PRESERVATION_UPLOAD_SCOPE, planner.PRESERVATION_PROVIDER_SCOPE, planner.PRESERVATION_R2_VIEW_SCOPE, planner.PRESERVATION_REQUEST_BUFFER_SCOPE, planner.BILLING_AUTHORITY_SCOPE))]}
        cost = preflight.observe_cost(selected, history, False)
        self.assertEqual(cost["status"], "unmeasured")
        self.assertEqual(cost["samples"], [])
        self.assertEqual(cost["measurement_job_timeouts_minutes"], planner.MODERATION_ENROLLMENT_JOB_TIMEOUTS)
        self.assertNotIn("with_upload_minutes", cost)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, True)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, False, True)
        result = {"scope": selected, "head": "a" * 40, "ready": False, "target_minutes": 30, "cost": cost}
        self.assertFalse(preflight.apply_task_gate(result, [])["ready"])
        self.assertTrue(preflight.apply_task_gate(result, [], measure_baseline=True)["ready"])
        now = dt.datetime.now(dt.timezone.utc)
        for state, conclusion in (("in_progress", None), ("completed", "failure"), ("completed", "success")):
            run = {"id": 8, "path": planner.MODERATION_ENROLLMENT_WORKFLOW, "status": state, "conclusion": conclusion,
                   "created_at": (now - dt.timedelta(minutes=8)).isoformat()}
            gated = preflight.apply_task_gate(result, [run], now, measure_baseline=True)
            self.assertFalse(gated["ready"])
            self.assertFalse(gated["task"]["first_baseline_measurement"])
            self.assertEqual(gated["task"]["minutes_since_first_ci"], 8)
            self.assertEqual(gated["task"]["failed_runs"], [8] if conclusion == "failure" else [])
            self.assertEqual(gated["task"]["active_runs"], [8] if state != "completed" else [])

    def test_candidate_plan_names_owning_node_job_on_the_fixed_head(self):
        head = "a" * 40
        with patch.object(planner, "git", side_effect=["", head, "b" * 40]), \
                patch.object(planner, "comparison_base", return_value="b" * 40), \
                patch.object(planner, "changed_paths", return_value=list(planner.MODERATION_ENROLLMENT_PATHS)), \
                patch.object(planner, "runtime_scope", return_value=planner.MODERATION_ENROLLMENT_SCOPE):
            result = preflight.candidate_plan("origin/main", 30, False, {"upload_minutes": 9, "observations": []})
        self.assertEqual(result["head"], head)
        self.assertEqual(result["required_jobs"], list(planner.MODERATION_ENROLLMENT_JOBS))
        self.assertEqual(result["required_backend_runs"], [{"workflow": planner.MODERATION_ENROLLMENT_WORKFLOW,
                         "job": job, "head_sha": head, "event": "push", "success_required": True}
                         for job in planner.MODERATION_ENROLLMENT_JOBS])
        self.assertEqual(result["unmapped_files"], [])
        self.assertFalse(result["ready"])
        self.assertIn("same-SHA Sharing workflow jobs", result["reason"])
        self.assertIn("no native, live-cloud or release evidence", result["reason"])


    def test_task_history_keeps_sharing_failures_and_active_runs(self):
        runs = [{"id": i, "path": planner.MODERATION_ENROLLMENT_WORKFLOW, "status": status,
                 "conclusion": conclusion} for i, status, conclusion in
                ((1, "completed", "failure"), (2, "in_progress", None))]
        with patch.object(planner, "git", return_value="codex/moderation-enrollment"), \
                patch.object(preflight, "github", return_value={"total_count": 2, "workflow_runs": runs}):
            result = preflight.read_task_runs("a" * 40)
        self.assertEqual({row["id"] for row in result}, {1, 2})
        self.assertEqual({row["path"] for row in result}, {planner.MODERATION_ENROLLMENT_WORKFLOW})


class PreservationRecoveryReadBudgetTests(unittest.TestCase):
    def test_separate_unmeasured_scope_retains_first_run_history_and_upload_gates(self):
        selected = planner.PRESERVATION_RECOVERY_READ_SCOPE
        history = {"upload_minutes": 9, "observations": [
            {"scope": previous, "candidate_minutes": 1.1, "run_id": index, "outcome": "success"}
            for index, previous in enumerate((planner.PRESERVATION_SCOPE, planner.PRESERVATION_UPLOAD_SCOPE, planner.PRESERVATION_PROVIDER_SCOPE, planner.PRESERVATION_R2_VIEW_SCOPE, planner.PRESERVATION_REQUEST_BUFFER_SCOPE))]}
        cost = preflight.observe_cost(selected, history, False)
        self.assertEqual(cost["status"], "unmeasured")
        self.assertEqual(cost["samples"], [])
        self.assertEqual(cost["measurement_job_timeout_minutes"], 5)
        self.assertNotIn("with_upload_minutes", cost)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, True)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, False, True)
        result = {"scope": selected, "head": "a" * 40, "ready": False, "target_minutes": 30, "cost": cost}
        self.assertFalse(preflight.apply_task_gate(result, [])["ready"])
        self.assertTrue(preflight.apply_task_gate(result, [], measure_baseline=True)["ready"])
        now = dt.datetime.now(dt.timezone.utc)
        for state, conclusion in (("in_progress", None), ("completed", "failure"), ("completed", "success")):
            run = {"id": 8, "path": planner.PRESERVATION_WORKFLOW, "status": state, "conclusion": conclusion,
                   "created_at": (now - dt.timedelta(minutes=8)).isoformat()}
            gated = preflight.apply_task_gate(result, [run], now, measure_baseline=True)
            self.assertFalse(gated["ready"])
            self.assertFalse(gated["task"]["first_baseline_measurement"])
            self.assertEqual(gated["task"]["minutes_since_first_ci"], 8)
            self.assertEqual(gated["task"]["failed_runs"], [8] if conclusion == "failure" else [])
            self.assertEqual(gated["task"]["active_runs"], [8] if state != "completed" else [])

    def test_candidate_plan_names_owning_node_job_on_the_fixed_head(self):
        head = "a" * 40
        with patch.object(planner, "git", side_effect=["", head, "b" * 40]), \
                patch.object(planner, "comparison_base", return_value="b" * 40), \
                patch.object(planner, "changed_paths", return_value=list(planner.PRESERVATION_RECOVERY_READ_PATHS)), \
                patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_RECOVERY_READ_SCOPE):
            result = preflight.candidate_plan("origin/main", 30, False, {"upload_minutes": 9, "observations": []})
        self.assertEqual(result["head"], head)
        self.assertEqual(result["required_jobs"], [planner.PRESERVATION_JOB])
        self.assertEqual(result["required_backend_runs"], [{"workflow": planner.PRESERVATION_WORKFLOW,
                         "job": planner.PRESERVATION_JOB, "head_sha": head, "success_required": True}])
        self.assertEqual(result["unmapped_files"], [])
        self.assertFalse(result["ready"])
        self.assertIn("same-SHA preservation Node job", result["reason"])
        self.assertIn("no native, live-cloud or release evidence", result["reason"])


class PreservationRequestBufferBudgetTests(unittest.TestCase):
    def test_separate_unmeasured_scope_retains_first_run_history_and_upload_gates(self):
        selected = planner.PRESERVATION_REQUEST_BUFFER_SCOPE
        history = {"upload_minutes": 9, "observations": [
            {"scope": previous, "candidate_minutes": 1.1, "run_id": index, "outcome": "success"}
            for index, previous in enumerate((planner.PRESERVATION_SCOPE, planner.PRESERVATION_UPLOAD_SCOPE, planner.PRESERVATION_PROVIDER_SCOPE, planner.PRESERVATION_R2_VIEW_SCOPE))]}
        cost = preflight.observe_cost(selected, history, False)
        self.assertEqual(cost["status"], "unmeasured")
        self.assertEqual(cost["samples"], [])
        self.assertEqual(cost["measurement_job_timeout_minutes"], 5)
        self.assertNotIn("with_upload_minutes", cost)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, True)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, False, True)
        result = {"scope": selected, "head": "a" * 40, "ready": False, "target_minutes": 30, "cost": cost}
        self.assertFalse(preflight.apply_task_gate(result, [])["ready"])
        self.assertTrue(preflight.apply_task_gate(result, [], measure_baseline=True)["ready"])
        now = dt.datetime.now(dt.timezone.utc)
        for state, conclusion in (("in_progress", None), ("completed", "failure"), ("completed", "success")):
            run = {"id": 8, "path": planner.PRESERVATION_WORKFLOW, "status": state, "conclusion": conclusion,
                   "created_at": (now - dt.timedelta(minutes=8)).isoformat()}
            gated = preflight.apply_task_gate(result, [run], now, measure_baseline=True)
            self.assertFalse(gated["ready"])
            self.assertFalse(gated["task"]["first_baseline_measurement"])
            self.assertEqual(gated["task"]["minutes_since_first_ci"], 8)
            self.assertEqual(gated["task"]["failed_runs"], [8] if conclusion == "failure" else [])
            self.assertEqual(gated["task"]["active_runs"], [8] if state != "completed" else [])

    def test_candidate_plan_names_owning_node_job_on_the_fixed_head(self):
        head = "a" * 40
        with patch.object(planner, "git", side_effect=["", head, "b" * 40]), \
                patch.object(planner, "comparison_base", return_value="b" * 40), \
                patch.object(planner, "changed_paths", return_value=list(planner.PRESERVATION_REQUEST_BUFFER_PATHS)), \
                patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_REQUEST_BUFFER_SCOPE):
            result = preflight.candidate_plan("origin/main", 30, False, {"upload_minutes": 9, "observations": []})
        self.assertEqual(result["head"], head)
        self.assertEqual(result["required_jobs"], [planner.PRESERVATION_JOB])
        self.assertEqual(result["required_backend_runs"], [{"workflow": planner.PRESERVATION_WORKFLOW,
                         "job": planner.PRESERVATION_JOB, "head_sha": head, "success_required": True}])
        self.assertEqual(result["unmapped_files"], [])
        self.assertFalse(result["ready"])
        self.assertIn("same-SHA preservation Node job", result["reason"])
        self.assertIn("no native, live-cloud or release evidence", result["reason"])


class PreservationR2ViewBudgetTests(unittest.TestCase):
    def test_separate_unmeasured_scope_retains_first_run_history_and_upload_gates(self):
        selected = planner.PRESERVATION_R2_VIEW_SCOPE
        history = {"upload_minutes": 9, "observations": [
            {"scope": previous, "candidate_minutes": 1.1, "run_id": index, "outcome": "success"}
            for index, previous in enumerate((planner.PRESERVATION_SCOPE, planner.PRESERVATION_UPLOAD_SCOPE, planner.PRESERVATION_PROVIDER_SCOPE))]}
        cost = preflight.observe_cost(selected, history, False)
        self.assertEqual(cost["status"], "unmeasured")
        self.assertEqual(cost["samples"], [])
        self.assertEqual(cost["measurement_job_timeout_minutes"], 5)
        self.assertNotIn("with_upload_minutes", cost)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, True)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, False, True)
        result = {"scope": selected, "head": "a" * 40, "ready": False, "target_minutes": 30, "cost": cost}
        self.assertFalse(preflight.apply_task_gate(result, [])["ready"])
        self.assertTrue(preflight.apply_task_gate(result, [], measure_baseline=True)["ready"])
        now = dt.datetime.now(dt.timezone.utc)
        for state, conclusion in (("in_progress", None), ("completed", "failure"), ("completed", "success")):
            run = {"id": 8, "path": planner.PRESERVATION_WORKFLOW, "status": state, "conclusion": conclusion,
                   "created_at": (now - dt.timedelta(minutes=8)).isoformat()}
            gated = preflight.apply_task_gate(result, [run], now, measure_baseline=True)
            self.assertFalse(gated["ready"])
            self.assertFalse(gated["task"]["first_baseline_measurement"])
            self.assertEqual(gated["task"]["minutes_since_first_ci"], 8)
            self.assertEqual(gated["task"]["failed_runs"], [8] if conclusion == "failure" else [])
            self.assertEqual(gated["task"]["active_runs"], [8] if state != "completed" else [])

    def test_candidate_plan_names_owning_node_job_on_the_fixed_head(self):
        head = "a" * 40
        with patch.object(planner, "git", side_effect=["", head, "b" * 40]), \
                patch.object(planner, "comparison_base", return_value="b" * 40), \
                patch.object(planner, "changed_paths", return_value=list(planner.PRESERVATION_R2_VIEW_PATHS)), \
                patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_R2_VIEW_SCOPE):
            result = preflight.candidate_plan("origin/main", 30, False, {"upload_minutes": 9, "observations": []})
        self.assertEqual(result["head"], head)
        self.assertEqual(result["required_jobs"], [planner.PRESERVATION_JOB])
        self.assertEqual(result["required_backend_runs"], [{"workflow": planner.PRESERVATION_WORKFLOW,
                         "job": planner.PRESERVATION_JOB, "head_sha": head, "success_required": True}])
        self.assertEqual(result["unmapped_files"], [])
        self.assertFalse(result["ready"])
        self.assertIn("same-SHA preservation Node job", result["reason"])
        self.assertIn("no native, live-cloud or release evidence", result["reason"])


class PreservationUploadMemoryBudgetTests(unittest.TestCase):
    def test_separate_unmeasured_scope_retains_first_run_history_and_upload_gates(self):
        selected = planner.PRESERVATION_UPLOAD_SCOPE
        history = {"upload_minutes": 9, "observations": [
            {"scope": planner.PRESERVATION_SCOPE, "candidate_minutes": 1.1, "run_id": 4, "outcome": "success"}]}
        cost = preflight.observe_cost(selected, history, False)
        self.assertEqual(cost["status"], "unmeasured")
        self.assertEqual(cost["samples"], [])
        self.assertEqual(cost["measurement_job_timeout_minutes"], 5)
        self.assertNotIn("with_upload_minutes", cost)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, True)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, False, True)
        result = {"scope": selected, "head": "a" * 40, "ready": False, "target_minutes": 30, "cost": cost}
        self.assertFalse(preflight.apply_task_gate(result, [])["ready"])
        self.assertTrue(preflight.apply_task_gate(result, [], measure_baseline=True)["ready"])
        now = dt.datetime.now(dt.timezone.utc)
        for state, conclusion in (("in_progress", None), ("completed", "failure"), ("completed", "success")):
            run = {"id": 8, "path": planner.PRESERVATION_WORKFLOW, "status": state, "conclusion": conclusion,
                   "created_at": (now - dt.timedelta(minutes=8)).isoformat()}
            gated = preflight.apply_task_gate(result, [run], now, measure_baseline=True)
            self.assertFalse(gated["ready"])
            self.assertFalse(gated["task"]["first_baseline_measurement"])
            self.assertEqual(gated["task"]["failed_runs"], [8] if conclusion == "failure" else [])
            self.assertEqual(gated["task"]["active_runs"], [8] if state != "completed" else [])

    def test_candidate_plan_names_owning_node_job_on_the_fixed_head(self):
        head = "a" * 40
        with patch.object(planner, "git", side_effect=["", head, "b" * 40]), \
                patch.object(planner, "comparison_base", return_value="b" * 40), \
                patch.object(planner, "changed_paths", return_value=list(planner.PRESERVATION_UPLOAD_PATHS)), \
                patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_UPLOAD_SCOPE):
            result = preflight.candidate_plan("origin/main", 30, False, {"upload_minutes": 9, "observations": []})
        self.assertEqual(result["head"], head)
        self.assertEqual(result["required_jobs"], [planner.PRESERVATION_JOB])
        self.assertEqual(result["unmapped_files"], [])
        self.assertFalse(result["ready"])
        self.assertIn("same-SHA preservation Node job", result["reason"])
        self.assertIn("no native, live-cloud or release evidence", result["reason"])


class ImmediateBillingAuthorityBudgetTests(unittest.TestCase):
    def test_backend_profile_is_unmeasured_and_cannot_authorize_upload(self):
        selected = planner.BILLING_AUTHORITY_SCOPE
        history = {"upload_minutes": 9, "observations": []}
        cost = preflight.observe_cost(selected, history, False)
        self.assertEqual(cost["status"], "unmeasured")
        self.assertEqual(cost["measurement_job_timeout_minutes"], 20)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, True)
        with self.assertRaises(ValueError): preflight.observe_cost(selected, history, False, True)
        result = {"scope": selected, "head": "a" * 40, "ready": False,
                  "target_minutes": 30, "cost": cost}
        gated = preflight.apply_task_gate(result, [], measure_baseline=True)
        self.assertTrue(gated["ready"])
        self.assertTrue(gated["task"]["first_baseline_measurement"])


class StalledRunRecoveryTests(unittest.TestCase):
    now = dt.datetime.fromisoformat("2026-10-08T00:00:00+00:00")
    head = "a" * 40

    def source(self, **changes):
        return {"id": 71, "head_sha": self.head, "head_branch": "codex/owner-prep",
                "workflow_id": 5, "path": preflight.IOS_WORKFLOW, "event": "push",
                "repository": {"full_name": preflight.REPOSITORY},
                "head_repository": {"full_name": preflight.REPOSITORY},
                "status": "queued", "conclusion": None, "run_attempt": 1,
                "created_at": "2026-10-07T18:00:00Z", "updated_at": "2026-10-07T18:00:00Z", **changes}

    def admission(self, *, source=None, jobs=None, refs=None, replacements=None, head=None, branch=None, existing=False, refresh=False):
        replies = [self.source() if source is None else source,
                   {"id": 5, "path": preflight.IOS_WORKFLOW},
                   {"total_count": 0, "jobs": []} if jobs is None else jobs,
                   [] if refs is None else refs,
                   {"total_count": 0, "workflow_runs": []} if replacements is None else replacements]
        with patch.object(preflight, "github", side_effect=replies):
            return preflight.recovery_source(71, head or self.head, branch or "codex/owner-prep", self.now, existing=existing, refresh=refresh)

    def test_refresh_requires_exact_unstarted_ref_and_preserves_source_and_clock(self):
        arguments = {"refresh": True, "head": "b" * 40,
                     "refs": [{"ref": "refs/heads/codex/recovery-71", "object": {"sha": self.head}}]}
        with patch.object(preflight, "verify_recovery_merge", return_value="c" * 40):
            proof = self.admission(**arguments)
            self.assertEqual(proof["source_sha"], self.head)
            self.assertEqual(proof["candidate_sha"], "b" * 40)
            plan = {"ready": True, "head": "b" * 40, "target_minutes": 500,
                    "cost": {"status": "reference", "with_upload_minutes": [100, 100]}}
            result = preflight.apply_task_gate(plan, [self.source()], self.now, recovery=proof)
            self.assertTrue(result["ready"])
            self.assertEqual(result["task"]["minutes_since_first_ci"], 360)
            for changes in ({"refs": []}, {"refs": [{"ref": "refs/heads/codex/recovery-71", "object": {"sha": "c" * 40}}]},
                            {"replacements": {"total_count": 1, "workflow_runs": [self.source()]}},
                            {"replacements": {}}, {"jobs": {"total_count": 1, "jobs": [{"id": 1}]}}):
                with self.subTest(changes=changes), self.assertRaises(ValueError):
                    self.admission(**{**arguments, **changes})

    def test_refresh_rejects_empty_native_mode_or_non_main_changes(self):
        path = "NekoWidget/ci/preflight-ci.py"
        row = f":100644 100644 {'d'*40} {'e'*40} M\t{path}"
        def git(*args):
            if args[0] == "show": return self.head + " " + "c" * 40
            if args[0] == "diff": return row
            if args[0] == "ls-tree": return "100644 blob " + "e" * 40 + "\t" + path
            return ""
        with patch.object(planner, "git", side_effect=git):
            self.assertEqual(preflight.verify_recovery_merge(self.head, "b" * 40), "c" * 40)
        for bad in ("", row.replace(path, "NekoWidget/NekoWidgetApp/Views/MembershipOfferView.swift"),
                    row.replace(":100644", ":100755"), row.replace("100644 100644", "100644 120000"),
                    row.replace("100644 100644", "000000 100644").replace(" M\t", " A\t")):
            with self.subTest(bad=bad), patch.object(planner, "git", side_effect=lambda *a: bad if a[0] == "diff" else git(*a)), self.assertRaises(ValueError):
                preflight.verify_recovery_merge(self.head, "b" * 40)
        for failure in ("parents", "main", "blob"):
            def broken(*a):
                if failure == "parents" and a[0] == "show": return "c" * 40 + " " + self.head
                if failure == "main" and a[0] == "merge-base": raise subprocess.CalledProcessError(1, a)
                if failure == "blob" and a[0] == "ls-tree" and a[1] == "b" * 40: return "different"
                return git(*a)
            with self.subTest(failure=failure), patch.object(planner, "git", side_effect=broken), self.assertRaises((ValueError, subprocess.CalledProcessError)):
                preflight.verify_recovery_merge(self.head, "b" * 40)

    def test_refresh_records_request_and_updates_only_the_expected_original_ref(self):
        proof = {**self.admission(), "refresh": True, "candidate_sha": "b" * 40, "approved_main": "c" * 40}
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "receipt.json"
            def git(*args):
                if args[0] == "rev-parse": return "b" * 40
                if args[0] == "remote": return "https://github.com/" + preflight.REPOSITORY + ".git"
                return ""
            def push(command, **kwargs):
                self.assertEqual(json.loads(output.read_text())["dispatch"]["state"], "update_requested")
                self.assertIn("--force-with-lease=refs/heads/codex/recovery-71:" + self.head, command)
                self.assertEqual(command[-1], "b" * 40 + ":refs/heads/codex/recovery-71")
                return subprocess.CompletedProcess(command, 0, "updated")
            result = {"ready": True, "head": "b" * 40, "task": {"recovery": proof}}
            with patch.object(planner, "git", side_effect=git), patch.object(preflight, "recovery_source", return_value=proof), \
                    patch.object(preflight.subprocess, "run", side_effect=push), \
                    patch.object(preflight, "github", return_value={"ref": "refs/heads/codex/recovery-71", "object": {"sha": "b" * 40}}):
                preflight.dispatch_recovery(result, proof, output)
            self.assertEqual(result["dispatch"]["state"], "updated")

    def test_only_exact_aged_unstarted_source_has_one_deterministic_replacement(self):
        proof = self.admission()
        self.assertEqual(proof["recovery_branch"], "codex/recovery-71")
        self.assertEqual(proof["source_sha"], self.head)
        self.assertTrue(proof["original_run_retained"])
        self.assertFalse(proof["release_evidence"])
        self.assertEqual(proof["verified_jobs"], 0)

    def test_identity_progress_and_attempts_cannot_be_waived(self):
        for mutation in ({"id": 72}, {"head_sha": "b" * 40}, {"head_branch": "codex/other"},
                         {"workflow_id": 6}, {"path": preflight.DIAGNOSTIC_WORKFLOW},
                         {"event": "workflow_dispatch"}, {"repository": {"full_name": "other/repo"}},
                         {"head_repository": {"full_name": "other/repo"}}, {"status": "in_progress"},
                         {"status": "waiting"}, {"conclusion": "failure"}, {"run_attempt": 2},
                         {"run_attempt": True}, {"updated_at": "2026-10-07T19:00:00Z"},
                         {"created_at": "2026-10-07T23:59:00Z", "updated_at": "2026-10-07T23:59:00Z"}):
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                self.admission(source=self.source(**mutation))
        with self.assertRaises(ValueError):
            self.admission(source=self.source(head_branch="codex/recovery-70"), branch="codex/recovery-70")

    def test_incomplete_jobs_existing_ref_or_any_replacement_history_blocks(self):
        for jobs in ({}, {"total_count": 0}, {"total_count": 1, "jobs": []},
                     {"total_count": 0, "jobs": [{"conclusion": "skipped"}]},
                     {"total_count": False, "jobs": []}):
            with self.subTest(jobs=jobs), self.assertRaises(ValueError): self.admission(jobs=jobs)
        for arguments in ({"refs": [{"ref": "refs/heads/codex/recovery-71"}]},
                          {"replacements": {"total_count": 1, "workflow_runs": []}},
                          {"replacements": {"total_count": 0, "workflow_runs": [{"id": 72}]}},
                          {"replacements": {}}):
            with self.subTest(arguments=arguments), self.assertRaises(ValueError): self.admission(**arguments)
        with patch.object(preflight, "github", side_effect=ValueError("unavailable")), self.assertRaises(ValueError):
            preflight.recovery_source(71, self.head, "codex/owner-prep", self.now)

    def test_recovery_branch_imports_original_candidate_and_diagnostic_history(self):
        original = self.source()
        replacement = {**original, "id": 72, "head_branch": "codex/recovery-71"}
        diagnostic = {"id": 70, "path": preflight.DIAGNOSTIC_WORKFLOW, "conclusion": None, "status": "queued"}
        queried = []
        def api(path):
            queried.append(path)
            if path.endswith("/actions/runs/71"): return original
            runs = [replacement] if "branch=codex%2Frecovery-71" in path else (
                [diagnostic] if "branch=diagnostic%2Fowner-prep" in path else [original])
            return {"total_count": len(runs), "workflow_runs": runs}
        with patch.object(planner, "git", return_value="codex/recovery-71"), patch.object(preflight, "github", side_effect=api):
            runs = preflight.read_task_runs(self.head)
        self.assertEqual({run["id"] for run in runs}, {70, 71, 72})
        self.assertTrue(any("branch=diagnostic%2Fowner-prep" in path for path in queried))

    def test_subsequent_inspection_exempts_only_original_and_retains_replacement(self):
        replacement = self.source(id=72, head_branch="codex/recovery-71")
        arguments = {"existing": True, "refs": [{"ref": "refs/heads/codex/recovery-71", "object": {"sha": self.head}}],
                     "replacements": {"total_count": 1, "workflow_runs": [replacement]}}
        proof = self.admission(**arguments)
        plan = {"ready": True, "head": self.head, "target_minutes": 500,
                "cost": {"status": "observed", "with_upload_minutes": [30, 30]}}
        result = preflight.apply_task_gate(dict(plan), [self.source(), replacement], self.now, recovery=proof)
        self.assertEqual(result["task"]["active_runs"], [72])
        self.assertFalse(result["ready"])
        completed = {**replacement, "status": "completed", "conclusion": "success"}
        result = preflight.apply_task_gate(dict(plan), [self.source(), completed], self.now, recovery=proof)
        self.assertTrue(result["ready"])
        self.assertEqual(result["task"]["runs"], 2)
        for changes in ({"refs": []}, {"refs": [{"ref": "refs/heads/codex/recovery-71", "object": {"sha": "b" * 40}}]},
                        {"replacements": {"total_count": 2, "workflow_runs": [replacement, replacement]}},
                        {"replacements": {"total_count": 1, "workflow_runs": [{**replacement, "head_sha": "b" * 40}]}}):
            with self.subTest(changes=changes), self.assertRaises(ValueError): self.admission(**{**arguments, **changes})

    def test_only_original_active_block_is_exempt_and_clock_is_not_reset(self):
        proof = self.admission()
        plan = {"ready": True, "head": self.head, "target_minutes": 500,
                "cost": {"status": "reference", "with_upload_minutes": [100, 100]}}
        run = self.source()
        result = preflight.apply_task_gate(dict(plan), [run], self.now, recovery=proof)
        self.assertTrue(result["ready"])
        self.assertEqual(result["task"]["minutes_since_first_ci"], 360)
        self.assertEqual(result["task"]["projected_total_minutes"], 460)
        self.assertEqual(result["task"]["runs"], 1)
        self.assertFalse(result["task"]["first_baseline_measurement"])
        for extra in ({**run, "id": 73},
                      {**run, "id": 74, "status": "completed", "conclusion": "failure",
                       "failed_tests": ["SoloMemoriesUITests/testOther"]}):
            result = preflight.apply_task_gate(dict(plan), [run, extra], self.now, recovery=proof)
            self.assertFalse(result["ready"])
        result = preflight.apply_task_gate({**plan, "target_minutes": 120}, [run], self.now, recovery=proof)
        self.assertFalse(result["ready"])
        with self.assertRaises(ValueError):
            preflight.apply_task_gate(dict(plan), [], self.now, recovery=proof)

    def test_billing_recovery_uses_observed_full_reference_without_claiming_speedup(self):
        history = {"upload_minutes": 9, "observations": [
            {"scope": "full-v1", "candidate_minutes": 98, "run_id": 1, "outcome": "success"}]}
        cost = preflight.observe_cost(scope.BILLING_LOCAL_PREPARATION_SCOPE, history, True, True)
        self.assertEqual(cost["status"], "reference")
        self.assertTrue(cost["scope_unmeasured"])
        self.assertEqual(cost["with_upload_minutes"], [107, 107])
        self.assertEqual(planner.required_jobs_from_scope(scope.BILLING_LOCAL_PREPARATION_SCOPE),
                         (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(scope.BILLING_LOCAL_PREPARATION_SCOPE))

    def test_recovery_flags_do_not_enable_diagnostic_or_measurement_bypass(self):
        for args in (["--dispatch-recovery"], ["--refresh-recovery"], ["--recover-run", "0"],
                     ["--recover-run", "71", "--measure-baseline"],
                     ["--feedback", "--checkout", "."]):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit): preflight.main(args)

    def test_external_candidate_requires_clean_merged_tooling_and_identical_selector(self):
        def git(*args):
            command = args[2:]
            if command[0] == "status": return ""
            if command[0] == "merge-base": return ""
            if command[0] == "remote": return "https://github.com/" + preflight.REPOSITORY + ".git"
            return self.head
        with patch.object(planner, "git", side_effect=git):
            self.assertEqual(preflight.approved_recovery_checkout(Path("candidate")), self.head)
        for failure in ("dirty", "unmerged", "remote", "selector"):
            def broken(*args):
                command = args[2:]
                if failure == "dirty" and command[0] == "status": return " M preflight-ci.py"
                if failure == "unmerged" and command[0] == "merge-base": raise subprocess.CalledProcessError(1, ["git"])
                if failure == "remote" and command[0] == "remote": return "https://github.com/other/repo.git"
                if failure == "selector" and args[1] == "candidate" and command[-1].endswith("plan-ios-ci.py"): return "b" * 40
                return git(*args)
            with self.subTest(failure=failure), patch.object(planner, "git", side_effect=broken), \
                    self.assertRaises((ValueError, subprocess.CalledProcessError)):
                preflight.approved_recovery_checkout(Path("candidate"))

    def test_dispatch_records_request_before_atomic_create_and_does_not_retry_unknown_outcome(self):
        proof = self.admission()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "receipt.json"
            def create(command, **options):
                receipt = json.loads(output.read_text(encoding="utf-8"))
                self.assertEqual(receipt["dispatch"]["state"], "creation_requested")
                self.assertEqual(command, ["git", "push", "--porcelain", "--force-with-lease=refs/heads/codex/recovery-71:",
                                           "origin", self.head + ":refs/heads/codex/recovery-71"])
                return subprocess.CompletedProcess(command, 0, "created")
            for succeeds in (True, False):
                result = {"ready": True, "head": self.head, "task": {"recovery": proof}}
                response = create if succeeds else subprocess.TimeoutExpired(["gh"], 45)
                with patch.object(planner, "git", side_effect=[self.head, "", "https://github.com/" + preflight.REPOSITORY + ".git"]), \
                        patch.object(preflight, "recovery_source", return_value=proof), \
                        patch.object(preflight, "github", return_value={"ref": "refs/heads/codex/recovery-71", "object": {"sha": self.head}}), \
                        patch.object(subprocess, "run", side_effect=response) as mutation:
                    if succeeds:
                        preflight.dispatch_recovery(result, proof, output)
                        self.assertEqual(result["dispatch"]["state"], "created")
                    else:
                        with self.assertRaises(subprocess.TimeoutExpired): preflight.dispatch_recovery(result, proof, output)
                        self.assertEqual(json.loads(output.read_text(encoding="utf-8"))["dispatch"]["state"], "creation_requested")
                    self.assertEqual(mutation.call_count, 1)
            with patch.object(planner, "git", side_effect=[self.head, "", "https://github.com/" + preflight.REPOSITORY + ".git"]), \
                    patch.object(preflight, "recovery_source", side_effect=ValueError("replacement appeared")), \
                    patch.object(subprocess, "run") as mutation, self.assertRaises(ValueError):
                preflight.dispatch_recovery(result, proof, output)
            mutation.assert_not_called()

    def test_alternate_or_multiple_push_destinations_are_rejected_before_mutation(self):
        proof = self.admission()
        result = {"ready": True, "head": self.head, "task": {"recovery": proof}}
        allowed = "https://github.com/" + preflight.REPOSITORY + ".git"
        for destination in ("https://github.com/other/repo.git", allowed + "\n" + allowed, ""):
            with self.subTest(destination=destination), \
                    patch.object(planner, "git", side_effect=[self.head, "", destination]), \
                    patch.object(subprocess, "run") as mutation, self.assertRaises(ValueError):
                preflight.dispatch_recovery(result, proof, Path("unused.json"))
            mutation.assert_not_called()

    def test_git_recovery_push_creates_once_and_cannot_update_an_existing_ref(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            remote, local = root / "remote.git", root / "local"
            def git(*args):
                return subprocess.check_output(["git", *args], text=True, encoding="utf-8", stderr=subprocess.DEVNULL).strip()
            git("init", "--bare", str(remote))
            git("init", str(local))
            git("-C", str(local), "remote", "add", "origin", str(remote))
            (local / "file.txt").write_text("first", encoding="utf-8")
            git("-C", str(local), "add", "file.txt")
            git("-C", str(local), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "first")
            first = git("-C", str(local), "rev-parse", "HEAD")
            ref = "refs/heads/codex/recovery-71"
            git("-C", str(local), "push", "--porcelain", "--force-with-lease=" + ref + ":", "origin", first + ":" + ref)
            (local / "file.txt").write_text("second", encoding="utf-8")
            git("-C", str(local), "add", "file.txt")
            git("-C", str(local), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "second")
            with self.assertRaises(subprocess.CalledProcessError):
                git("-C", str(local), "push", "--porcelain", "--force-with-lease=" + ref + ":", "origin", "HEAD:" + ref)
            self.assertEqual(git("--git-dir=" + str(remote), "rev-parse", ref), first)


class FeedbackRoutingTests(unittest.TestCase):
    method = "testPhotosOpenEachCatsPhotosDirectlyAndKeepManagementInSettings"

    def plan(self, *, branch="codex/feedback", dirty="", runs=(), methods=None):
        with patch.object(planner, "git", side_effect=[dirty, "a" * 40, branch]), \
                patch.object(preflight, "read_task_runs", return_value=list(runs)), \
                patch.object(preflight, "read_other_active_ios_runs", return_value=[]):
            return preflight.feedback_plan("SoloMemoriesUITests", methods or self.method)

    def test_feedback_commands_use_exact_sha_and_diagnostic_branch(self):
        for branch in ("codex/feedback", "diagnostic/feedback"):
            result = self.plan(branch=branch)
            self.assertTrue(result["ready"])
            self.assertFalse(result["release_evidence"])
            self.assertTrue(result["diagnostic_only"])
            self.assertEqual(result["commands"][0],
                             ["git", "push", "origin", "a" * 40 + ":refs/heads/diagnostic/feedback"])
            dispatch = result["commands"][1]
            self.assertIn("diagnostic/feedback", dispatch)
            self.assertIn("source_ref=" + "a" * 40, dispatch)
            self.assertEqual(result["native_tests"],
                             ["NekoWidgetUITests/SoloMemoriesUITests/" + self.method])

    def test_feedback_requires_committed_task_and_existing_distinct_methods(self):
        for arguments in ({"dirty": " M changed.swift"}, {"branch": "main"}, {"branch": ""},
                          {"methods": "testNotPresentInThisClass"},
                          {"methods": self.method + "," + self.method},
                          {"methods": "testA,testB,testC,testD"}):
            with self.subTest(arguments=arguments), self.assertRaises(ValueError):
                self.plan(**arguments)

    def test_active_task_blocks_commands_but_other_tasks_are_only_advisory(self):
        result = self.plan(runs=[{"id": 17, "status": "in_progress"}])
        self.assertFalse(result["ready"])
        self.assertEqual(result["commands"], [])
        self.assertEqual(result["active_task_runs"], [17])
        result = self.plan(runs=[{"id": 18, "status": "completed"}])
        self.assertTrue(result["ready"])

    def test_contention_deduplicates_and_excludes_both_own_branches(self):
        def run(identifier, branch, status="queued"):
            return {"id": identifier, "head_branch": branch, "status": status,
                    "created_at": "2026-10-04T01:00:00Z"}
        runs = [run(1, "codex/feedback"), run(2, "diagnostic/feedback"),
                run(3, "codex/other"), run(4, "codex/finished", "completed")]
        with patch.object(preflight, "github", return_value={"total_count": 4, "workflow_runs": runs}) as api:
            result = preflight.read_other_active_ios_runs("codex/feedback")
        self.assertEqual([run["id"] for run in result], [3])
        self.assertEqual(api.call_count, 5)
        self.assertTrue(all("/actions/workflows/ios-build.yml/runs?" in call.args[0]
                            for call in api.call_args_list))

    def test_incomplete_contention_history_stops_instead_of_assuming_idle(self):
        for page in ({"total_count": 1, "workflow_runs": []},
                     {"total_count": 100, "workflow_runs": []}):
            with patch.object(preflight, "github", return_value=page), self.assertRaises(ValueError):
                preflight.read_other_active_ios_runs("codex/feedback")

    def test_feedback_cannot_authorize_upload_or_silently_change_candidate_route(self):
        for arguments in (["--feedback"], ["--test-class", "SoloMemoriesUITests"],
                          ["--feedback", "--test-class", "SoloMemoriesUITests", "--test-method",
                           self.method, "--include-upload"]):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                preflight.main(arguments)
            self.assertEqual(error.exception.code, 2)


class PreflightTests(unittest.TestCase):
    history = {"upload_minutes": 9, "observations": [
        {"scope": "full-v1", "candidate_minutes": 64, "run_id": 1, "outcome": "failure"},
        {"scope": "full-v1", "candidate_minutes": 98, "run_id": 2, "outcome": "success-after-retry"}]}

    def test_operator_tools_preflight_cannot_authorize_upload(self):
        for include_upload in (False, True):
            with patch.object(planner, "git", side_effect=["", "a" * 40, "b" * 40]), \
                    patch.object(planner, "comparison_base", return_value="b" * 40), \
                    patch.object(planner, "changed_paths", return_value=sorted(planner.BILLING_OPERATOR_PATHS)), \
                    patch.object(planner, "runtime_scope", return_value=planner.BILLING_OPERATOR_SCOPE):
                result = preflight.candidate_plan("origin/main", 30, include_upload, self.history)
            self.assertEqual(result["required_jobs"], [planner.PLAN_JOB])
            self.assertFalse(result["release_evidence"])
            self.assertEqual(result["ready"], not include_upload)
        with self.assertRaises(ValueError): preflight.observe_cost(planner.BILLING_OPERATOR_SCOPE, self.history, True)

    def test_policy_docs_plan_cannot_authorize_upload(self):
        for include_upload in (False, True):
            with patch.object(planner, "git", side_effect=["", "a" * 40, "b" * 40]), \
                    patch.object(planner, "comparison_base", return_value="b" * 40), \
                    patch.object(planner, "changed_paths", return_value=["docs/privacy/index.html"]), \
                    patch.object(planner, "runtime_scope", return_value=planner.POLICY_DOC_SCOPE):
                result = preflight.candidate_plan("origin/main", 30, include_upload, self.history)
            self.assertEqual(result["required_jobs"], [planner.PLAN_JOB])
            self.assertFalse(result["release_evidence"])
            self.assertEqual(result["ready"], not include_upload)
        with self.assertRaises(ValueError):
            preflight.observe_cost(planner.POLICY_DOC_SCOPE, self.history, True)

    def test_deletion_diagnosis_admits_only_fixed_footer_and_keeps_new_failures(self):
        method = "SoloMemoriesUITests/testManagedPreservationAccountDeletionRetainsReceiptAndCompletes"
        fixed = "778da52e3218feb467988d3d3c627df3943f024b"
        source = "53ece8f24da61baee7b27902aef4c153927f3313"
        view = "NekoWidget/NekoWidget/Views/ManagedPreservationView.swift"
        old = "保管記録や会員契約は削除・解約されません。別の本人として使う前に解除してください。"
        new = "ログインを解除しても保管記録は残ります。アカウントを削除すると、サービスに保管したコピーはすべて消えます。定期購読は別途Appleで解約してください。"
        run = {"id": 36893711423, "head_sha": source, "status": "completed", "conclusion": "failure",
               "event": "push", "path": ".github/workflows/ios-build.yml", "failed_tests": [method],
               "created_at": "2026-10-01T16:40:07Z"}
        result = {"scope": scope.REVIEWED_MANAGED_PRESERVATION_SCOPE, "head": "a" * 40,
                  "cost": {"status": "observed", "with_upload_minutes": [38, 38]},
                  "target_minutes": 95, "ready": True}
        def diagnosis(responses, runs=None):
            with patch.object(planner, "git", side_effect=responses):
                return preflight.known_deletion_test_diagnosis(result, runs or [run])
        proof = diagnosis([fixed, view, old, new, "same test", "same test"])
        self.assertIsNotNone(proof)
        self.assertFalse(proof["reuses_successful_jobs"])
        for responses in (["b" * 40], [fixed, view + "\nunknown.swift"],
                          [fixed, view, old, new + "product change"],
                          [fixed, view, old, new, "same test", "changed test"]):
            self.assertIsNone(diagnosis(responses))
        for mutation in ({"head_sha": "b" * 40}, {"failed_tests": [method, "SoloMemoriesUITests/testOther"]},
                         {"conclusion": "cancelled"}, {"unsupported_failed_tests": ["Other/testUnknown"]}):
            self.assertIsNone(diagnosis([], [{**run, **mutation}]))
        now = dt.datetime.fromisoformat("2026-10-01T17:25:00+00:00")
        admitted = preflight.apply_task_gate(dict(result), [run], now=now, diagnosed_failure=proof)
        self.assertTrue(admitted["ready"])
        self.assertIsNone(admitted["task"]["test_correction_evidence"])
        later = {**run, "id": 36899999999, "created_at": "2026-10-01T17:20:00Z"}
        rejected = preflight.apply_task_gate(dict(result), [run, later], now=now, diagnosed_failure=proof)
        self.assertFalse(rejected["ready"])
        self.assertEqual(rejected["task"]["missing_diagnostic_tests"], [method])

    def test_internal_release_preparation_plan_cannot_authorize_upload(self):
        paths = sorted(planner.RELEASE_PREP_PATHS)
        for upload in (False, True):
            with patch.object(planner, "git", side_effect=["", "a" * 40, "b" * 40]), \
                    patch.object(planner, "comparison_base", return_value="b" * 40), \
                    patch.object(planner, "changed_paths", return_value=paths), \
                    patch.object(planner, "runtime_scope", return_value=planner.RELEASE_PREP_SCOPE):
                result = preflight.candidate_plan("origin/main", 30, upload, self.history)
            self.assertEqual(result["required_jobs"], [planner.PLAN_JOB, planner.RELEASE_PREP_BACKEND_PLAN_JOB])
            self.assertEqual(result["ready"], not upload)
            self.assertFalse(result["release_evidence"])
            self.assertIn("no Mac/archive/upload evidence", result["reason"])
            with patch.object(preflight, "candidate_plan", return_value=result), \
                    patch.object(preflight, "read_task_runs", side_effect=AssertionError("No native cost gate")), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(preflight.main([]), 3 if upload else 0)
        with self.assertRaises(ValueError):
            preflight.observe_cost(planner.RELEASE_PREP_SCOPE, self.history, True)

    def test_private_data_exclusion_explains_kept_checks_without_claiming_unmeasured_speed(self):
        paths = ["NekoWidget/NekoWidget/Services/PhotoMemoryNoteStore.swift"]
        with patch.object(planner, "git", side_effect=["", "a" * 40, "b" * 40]), \
                patch.object(planner, "comparison_base", return_value="b" * 40), \
                patch.object(planner, "changed_paths", return_value=paths), \
                patch.object(planner, "runtime_scope", return_value=scope.APP_DATA_SCOPE):
            result = preflight.candidate_plan("origin/main", 30, True, self.history)
        self.assertEqual(len(result["required_jobs"]), 6)
        self.assertFalse(any("gallery" in name for name in result["required_jobs"]))
        self.assertIn("storage/privacy/migration", result["reason"])
        self.assertIn("Widget source membership/render inputs unchanged", result["reason"])
        self.assertEqual(result["cost"]["status"], "unmeasured")
        self.assertFalse(result["ready"])

    def test_ui_test_and_release_note_plan_keeps_full_app_checks_without_widget_gallery(self):
        paths = [scope.MEMORY_TEST_PATH, "NekoWidget/ci/release-candidates/2026-09-25-showcase-ia.md"]
        history = {**self.history, "observations": self.history["observations"] + [
            {"scope": scope.APP_VIEW_SCOPE, "candidate_minutes": 54, "run_id": 3, "outcome": "success"}]}
        with patch.object(planner, "git", side_effect=["", "a" * 40, "b" * 40]), \
                patch.object(planner, "comparison_base", return_value="b" * 40), \
                patch.object(planner, "changed_paths", return_value=paths), \
                patch.object(planner, "runtime_scope", return_value=scope.APP_VIEW_SCOPE):
            result = preflight.candidate_plan("origin/main", 90, True, history)
        self.assertEqual(result["scope"], scope.APP_VIEW_SCOPE)
        self.assertEqual(result["required_jobs"], list(planner.required_jobs_from_scope(scope.APP_VIEW_SCOPE)))
        self.assertEqual(len(result["required_jobs"]), 6)
        self.assertFalse(any("gallery" in name for name in result["required_jobs"]))
        self.assertEqual(result["unmapped_files"], [])
        self.assertTrue(result["ready"])

    def test_private_billing_backend_cannot_authorize_native_upload(self):
        cost = preflight.observe_cost(planner.BILLING_SCOPE, self.history, False)
        self.assertEqual(cost["status"], "unmeasured")
        self.assertEqual(cost["measurement_job_timeout_minutes"], 5)
        for options in ({"include_upload": True}, {"include_upload": False, "use_full_baseline": True}):
            with self.assertRaises(ValueError):
                preflight.observe_cost(planner.BILLING_SCOPE, self.history, **options)

    def test_preservation_cost_is_scope_specific_and_first_measurement_only(self):
        history = {**self.history, "observations": self.history["observations"] + [
            {"scope": planner.JPEG_SCOPE, "candidate_minutes": 0.8, "run_id": 3, "outcome": "success"},
            {"scope": "preservation-service-v1", "candidate_minutes": 0.65, "run_id": 4, "outcome": "success"},
            {"scope": "preservation-service-v2", "candidate_minutes": 0.75, "run_id": 5, "outcome": "success"}]}
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
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
        self.assertIn("persistent runtime admission budget", result["reason"])
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
        for selected in (scope.FAMILY_WINDOW_UI_SCOPE, scope.REVIEWED_MEMORY_FAMILY_SCOPE, scope.REVIEWED_FAMILY_EXPORT_SCOPE,
                         scope.REVIEWED_MEMBERSHIP_ACCESS_SCOPE,
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
        for selected in (scope.FAMILY_WINDOW_UI_SCOPE, scope.REVIEWED_MEMORY_FAMILY_SCOPE, scope.REVIEWED_FAMILY_EXPORT_SCOPE,
                         scope.REVIEWED_MEMBERSHIP_ACCESS_SCOPE,
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

    def test_managed_pilot_test_correction_preserves_elapsed_and_failed_case_gates(self):
        self.test_proven_lost_cat_test_correction_runs_normal_ui_without_duplicate_diagnosis(scope.REVIEWED_MANAGED_PRESERVATION_SCOPE)

    def test_managed_deletion_test_correction_preserves_elapsed_and_failed_case_gates(self):
        self.test_proven_lost_cat_test_correction_runs_normal_ui_without_duplicate_diagnosis(
            scope.REVIEWED_MANAGED_PRESERVATION_SCOPE,
            "SoloMemoriesUITests/testManagedPreservationAccountDeletionRetainsReceiptAndCompletes")

    def test_vet_test_correction_preserves_elapsed_and_failed_case_gates(self):
        self.test_proven_lost_cat_test_correction_runs_normal_ui_without_duplicate_diagnosis(scope.VET_SAVED_CAT_SCOPE)

    def test_album_correction_preserves_time_unknown_and_subsequent_failure_gates(self):
        self.test_proven_lost_cat_test_correction_runs_normal_ui_without_duplicate_diagnosis(
            scope.FULL_SCOPE, planner.ALBUM_CORRECTION_CASE)

    def test_proven_lost_cat_test_correction_runs_normal_ui_without_duplicate_diagnosis(self, selected_scope=scope.LOST_CAT_UX_SCOPE, requested_case=None):
        now = dt.datetime(2026, 9, 20, 12, tzinfo=dt.timezone.utc)
        case = requested_case or ("SoloMemoriesUITests/testManagedPreservationLostCopyResultShowsConfirmationAndStoredState"
                if selected_scope == scope.REVIEWED_MANAGED_PRESERVATION_SCOPE else
                "SoloMemoriesUITests/testVeterinarySelectionIsExplicitAndRemovalKeepsSource"
                if selected_scope == scope.VET_SAVED_CAT_SCOPE else
                "SoloMemoriesUITests/testLostCatDraftOffersThisCatsPhotosBeforeEntireLibrary")
        plan = {"ready": True, "head": "a" * 40, "scope": selected_scope,
                "target_minutes": 30, "cost": {"status": "observed", "with_upload_minutes": [10, 20]}}
        failed = {"id": 10, "created_at": "2026-09-20T11:55:00Z", "status": "completed",
                  "conclusion": "failure", "failed_tests": [case],
                  "path": ".github/workflows/ios-build.yml"}
        evidence = {"run_id": 10, "sha": "b" * 40, "jobs": []}
        self.assertTrue(preflight.apply_task_gate(dict(plan), [failed], now,
                        correction_evidence=evidence)["ready"])
        self.assertFalse(preflight.apply_task_gate(dict(plan), [failed], now)["ready"])
        self.assertFalse(preflight.apply_task_gate(dict(plan), [{**failed, "failed_tests": ["SoloMemoriesUITests/testOther"]}],
                         now, correction_evidence=evidence)["ready"])
        self.assertFalse(preflight.apply_task_gate(dict(plan), [failed], now,
                         correction_evidence={**evidence, "run_id": 11})["ready"])
        later = {**failed, "id": 12, "head_sha": plan["head"], "created_at": "2026-09-20T11:59:00Z"}
        self.assertFalse(preflight.apply_task_gate(dict(plan), [failed, later], now,
                         correction_evidence=evidence)["ready"])
        diagnostic = self.diagnostic_run_evidence({**later, "path": preflight.DIAGNOSTIC_WORKFLOW,
            "event": "workflow_dispatch", "head_branch": "diagnostic/task",
            "display_title": "UI diagnosis: " + case})
        self.assertFalse(preflight.apply_task_gate(dict(plan), [failed, diagnostic], now,
                         correction_evidence=evidence)["ready"])

    def test_unmeasured_baseline_is_explicit_and_first_attempt_only(self):
        plan = {"ready": False, "head": "a" * 40, "target_minutes": 30, "cost": {"status": "unmeasured"}}
        self.assertFalse(preflight.apply_task_gate(dict(plan), [])["ready"])
        first = preflight.apply_task_gate(dict(plan), [], measure_baseline=True)
        self.assertTrue(first["ready"])
        self.assertIsNone(first["task"]["projected_total_minutes"])
        run = {"id": 1, "created_at": "2026-09-20T11:00:00Z", "status": "completed",
               "conclusion": "failure", "path": ".github/workflows/ios-build.yml"}
        self.assertFalse(preflight.apply_task_gate(dict(plan), [run], measure_baseline=True)["ready"])

        now = dt.datetime(2026, 9, 20, 11, 15, tzinfo=dt.timezone.utc)
        diagnostic = {**run, "path": preflight.DIAGNOSTIC_WORKFLOW, "conclusion": "success"}
        measured = preflight.apply_task_gate(dict(plan), [diagnostic], now, measure_baseline=True)
        self.assertTrue(measured["ready"])
        self.assertEqual(measured["task"]["minutes_since_first_ci"], 15)
        self.assertIsNone(measured["task"]["projected_total_minutes"])
        for blocked in (
            {**diagnostic, "status": "in_progress", "conclusion": None},
            {**diagnostic, "conclusion": "failure", "failed_tests": ["testNavigation"]},
            {**diagnostic, "conclusion": "failure", "unsupported_failed_tests": ["Other/testNavigation"]},
        ):
            self.assertFalse(preflight.apply_task_gate(dict(plan), [blocked], now, measure_baseline=True)["ready"])
        self.assertFalse(preflight.apply_task_gate(dict(plan), [diagnostic, run], now, measure_baseline=True)["ready"])

    def test_successful_backend_on_diagnostic_ref_is_not_a_native_baseline(self):
        plan = {"ready": False, "head": "a" * 40, "target_minutes": 30,
                "required_jobs": [planner.BUILD], "cost": {"status": "unmeasured"}}
        run = {"id": 9, "created_at": "2026-09-20T11:00:00Z", "status": "completed",
               "conclusion": "success", "path": planner.BILLING_WORKFLOW,
               "event": "push", "head_branch": "diagnostic/task"}
        now = dt.datetime(2026, 9, 20, 11, 15, tzinfo=dt.timezone.utc)
        result = preflight.apply_task_gate(dict(plan), [run], now, measure_baseline=True)
        self.assertTrue(result["ready"])
        self.assertTrue(result["task"]["first_baseline_measurement"])
        self.assertEqual(result["task"]["runs"], 1)
        self.assertEqual(result["task"]["minutes_since_first_ci"], 15)
        self.assertIsNone(result["task"]["projected_total_minutes"])
        for changes in ({"status": "in_progress", "conclusion": None},
                        {"conclusion": "failure"}, {"conclusion": "skipped"},
                        {"head_branch": "codex/task"}, {"head_branch": ""},
                        {"event": "workflow_dispatch"}, {"event": "pull_request"},
                        {"path": preflight.IOS_WORKFLOW}, {"path": "unknown.yml"}):
            with self.subTest(changes=changes):
                blocked = preflight.apply_task_gate(dict(plan), [{**run, **changes}], now, measure_baseline=True)
                self.assertFalse(blocked["ready"])
        native = {**run, "id": 10, "path": preflight.IOS_WORKFLOW, "head_branch": "codex/task"}
        self.assertFalse(preflight.apply_task_gate(dict(plan), [run, native], now, measure_baseline=True)["ready"])
        self.assertFalse(preflight.apply_task_gate({**plan, "required_jobs": []}, [run], now, measure_baseline=True)["ready"])
        self.assertFalse(preflight.apply_task_gate(dict(plan), [run], now)["ready"])
        observed = {**plan, "cost": {"status": "observed", "with_upload_minutes": [20, 20]}}
        self.assertFalse(preflight.apply_task_gate(observed, [run], now, measure_baseline=True)["ready"])

    def test_fixed_export_correction_preserves_later_failure_active_and_cost_gates(self):
        now = dt.datetime(2026, 10, 8, 12, tzinfo=dt.timezone.utc)
        plan = {"ready": True, "head": "a" * 40, "target_minutes": 60,
                "scope": planner.PRESERVATION_EXPORT_SCOPE,
                "cost": {"status": "observed", "with_upload_minutes": [23, 23]}}
        run = {"id": planner.PRESERVATION_EXPORT_CORRECTION_RUN,
               "head_sha": planner.PRESERVATION_EXPORT_CORRECTION_SOURCE,
               "path": preflight.IOS_WORKFLOW, "event": "push", "head_branch": planner.PRESERVATION_EXPORT_CORRECTION_BRANCH,
               "created_at": "2026-10-08T11:50:00Z", "status": "completed", "conclusion": "failure",
               "failed_tests": list(planner.PRESERVATION_EXPORT_CORRECTION_CASES)}
        evidence = {"run_id": run["id"], "sha": run["head_sha"]}
        def verify(runs, selected=plan, correction=evidence):
            return preflight.apply_task_gate(dict(selected), runs, now, correction_evidence=correction)
        result = verify([run])
        self.assertTrue(result["ready"])
        self.assertEqual(result["task"]["failed_runs"], [run["id"]])
        self.assertEqual(result["task"]["minutes_since_first_ci"], 10)
        self.assertEqual(result["task"]["projected_total_minutes"], 33)
        self.assertFalse(verify([run], correction=None)["ready"])
        self.assertFalse(verify([run], correction=evidence | {"sha": "b" * 40})["ready"])
        self.assertFalse(verify([run | {"failed_tests": run["failed_tests"] + ["SoloMemoriesUITests/testUnknown"]}])["ready"])
        self.assertFalse(verify([run, run | {"id": 9}])["ready"])
        self.assertFalse(verify([run, run | {"id": 9, "status": "in_progress", "conclusion": None}])["ready"])
        self.assertFalse(verify([run], selected=plan | {"target_minutes": 30})["ready"])

    def test_skipped_same_repo_pr_does_not_consume_first_baseline_attempt(self):
        plan = {"ready": False, "head": "a" * 40, "target_minutes": 30,
                "cost": {"status": "unmeasured"}}
        skipped_pr = {"id": 2, "created_at": "2026-09-20T11:00:00Z",
                      "status": "completed", "conclusion": "skipped",
                      "event": "pull_request", "path": ".github/workflows/ios-build.yml"}
        result = preflight.apply_task_gate(dict(plan), [skipped_pr], measure_baseline=True)
        self.assertTrue(result["ready"])
        self.assertTrue(result["task"]["first_baseline_measurement"])
        self.assertEqual(result["task"]["failed_runs"], [])

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


class PhotoCorrectionBudgetTests(unittest.TestCase):
    def test_only_registered_source_failures_are_diagnosed_and_clock_is_retained(self):
        now = dt.datetime(2026, 10, 5, 1, tzinfo=dt.timezone.utc)
        case = sorted(planner.PHOTO_SMOKE_CORRECTION_CASES)[0]
        plan = {"ready": True, "head": "a" * 40, "scope": scope.FULL_SCOPE, "target_minutes": 210,
                "cost": {"status": "reference", "with_upload_minutes": [76, 76]}}
        failed = {"id": planner.PHOTO_SMOKE_CORRECTION_RUN, "created_at": "2026-10-04T23:58:28Z",
                  "status": "completed", "conclusion": "failure", "path": ".github/workflows/ios-build.yml",
                  "failed_tests": [], "unsupported_failed_tests": ["NekoWidgetUITests." + case]}
        evidence = {"run_id": planner.PHOTO_SMOKE_CORRECTION_RUN,
                    "sha": planner.PHOTO_SMOKE_CORRECTION_SOURCE, "jobs": []}
        result = preflight.apply_task_gate(dict(plan), [failed], now, correction_evidence=evidence)
        self.assertTrue(result["ready"])
        self.assertGreater(result["task"]["minutes_since_first_ci"], 61)
        for change in ({"id": 10}, {"unsupported_failed_tests": ["NekoWidgetUITests.PersonalRediscoveryUITests/testUnknown"]}):
            self.assertFalse(preflight.apply_task_gate(dict(plan), [{**failed, **change}], now,
                             correction_evidence=evidence)["ready"])
        self.assertFalse(preflight.apply_task_gate(dict(plan), [failed], now,
                         correction_evidence={**evidence, "sha": "b" * 40})["ready"])
        self.assertFalse(preflight.apply_task_gate(dict(plan), [failed, {**failed, "id": 11, "status": "in_progress"}],
                         now, correction_evidence=evidence)["ready"])

    def test_cost_reserves_the_retry_timeout_and_keeps_cancelled_run_out_of_success_evidence(self):
        plan = {"ready": True, "scope": scope.FULL_SCOPE, "target_minutes": 210,
                "cost": {"status": "observed", "with_upload_minutes": [100, 110]}}
        evidence = {"run_id": planner.PHOTO_SMOKE_CORRECTION_RUN, "sha": planner.PHOTO_SMOKE_CORRECTION_SOURCE}
        references = {
            111435105247: (planner.SMOKE, "2026-10-04T12:50:45Z"),
            111435105277: (scope.lane_job(scope.FULL_SCOPE, "app-ui-other"), "2026-10-04T13:26:12Z"),
            planner.PHOTO_SMOKE_CORRECTION_SOLO_JOB_ID: (planner.PHOTO_SMOKE_CORRECTION_SOLO_JOB, "2026-10-05T01:14:55Z"),
        }
        def github(path):
            job_id = int(path.split("/")[-1]); name, end = references[job_id]
            return {"id": job_id, "run_id": planner.ALBUM_CORRECTION_RUN,
                    "head_sha": planner.ALBUM_CORRECTION_SOURCE, "name": name,
                    "status": "completed", "conclusion": "success", "started_at": "2026-10-04T12:22:45Z",
                    "completed_at": end}
        def source_aware_github(path):
            job_id = int(path.split("/")[-1])
            job = github(path)
            if job_id == planner.PHOTO_SMOKE_CORRECTION_SOLO_JOB_ID:
                job.update({"run_id": planner.PHOTO_SMOKE_CORRECTION_RUN,
                            "head_sha": planner.PHOTO_SMOKE_CORRECTION_SOURCE,
                            "conclusion": "cancelled", "started_at": "2026-10-04T23:59:03Z"})
            return job
        with patch.object(preflight, "github", side_effect=source_aware_github):
            result = preflight.photo_correction_replay_cost(plan, evidence, True, {"upload_minutes": 12})
        self.assertEqual(result["cost"]["with_upload_minutes"], [102.0, 102.0])
        self.assertEqual(result["cost"]["ci_minutes"], [90.0, 90.0])
        self.assertEqual(result["cost"]["source_app_ui_solo_incomplete_minutes"], 75.87)
        self.assertEqual(result["full_cost_before_correction"], plan["cost"])
        self.assertIs(preflight.photo_correction_replay_cost(plan, {**evidence, "sha": "b" * 40}, True, {}), plan)
        for changes in ({"conclusion": "failure"}, {"run_id": 1}, {"head_sha": "a" * 40},
                        {"completed_at": "2026-10-04T12:00:00Z"}):
            with patch.object(preflight, "github", side_effect=lambda path: {**source_aware_github(path), **changes}), \
                    self.assertRaises(ValueError):
                preflight.photo_correction_replay_cost(plan, evidence, True, {"upload_minutes": 12})


if __name__ == "__main__":
    unittest.main()
