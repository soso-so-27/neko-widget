#!/usr/bin/env python3
"""Release preflight/dispatch boundaries. All GitHub operations are mocks."""

import contextlib
import copy
import datetime as dt
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("release", Path(__file__).with_name("release-testflight.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class FakeGitHub:
    def __init__(self, values, logs):
        self.values, self.logs = values, logs
        self.requests, self.dispatches = [], []

    def get(self, path):
        self.requests.append(("GET", path))
        return copy.deepcopy(self.values[path])

    def log(self, run_id, job_id=None):
        self.requests.append(("LOG", run_id, job_id))
        return self.logs[(run_id, job_id)]

    def dispatch(self, inputs):
        self.dispatches.append(copy.deepcopy(inputs))


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.sha = "a" * 40
        self.now = dt.datetime.now(dt.timezone.utc)
        anchor = patch.object(release, "BASELINE", {
            "run_id": 29, "sha": "c" * 40, "build": 160, "created_at": "2026-09-13T05:42:24Z",
        })
        anchor.start()
        self.addCleanup(anchor.stop)
        self.repo = {"full_name": release.REPOSITORY}
        self.run = {
            "id": 20, "workflow_id": 5, "head_sha": self.sha, "head_branch": "main", "event": "push",
            "status": "completed", "conclusion": "success", "repository": self.repo, "head_repository": self.repo,
            "updated_at": self.now.isoformat(),
            "created_at": "2026-09-13T06:00:00Z",
        }
        self.plan_job = {"id": 201, "name": release.PLAN_JOB, "head_sha": self.sha,
                         "status": "completed", "conclusion": "success", "completed_at": self.now.isoformat()}
        self.plan = {"schema_version": 1, "repository": release.REPOSITORY, "head_sha": self.sha,
                     "scope": release.planner.FULL_SCOPE, "required_jobs": list(release.planner.FULL),
                     "evidence_run_id": None, "evidence_sha": None}
        self.previous = dict(self.run, id=30, workflow_id=6, event="workflow_dispatch", run_number=12,
                             display_title=f"TestFlight build 164 @ {self.sha}")
        self.gh = FakeGitHub({
            "git/ref/heads/main": {"object": {"type": "commit", "sha": self.sha}},
            "actions/workflows/ios-build.yml": {"id": 5, "path": ".github/workflows/ios-build.yml", "state": "active"},
            "actions/workflows/testflight.yml": {"id": 6, "path": ".github/workflows/testflight.yml", "state": "active"},
            "actions/runs/20": self.run,
            "actions/runs/29": dict(self.previous, id=29, head_sha="c" * 40, created_at=release.BASELINE["created_at"]),
            release.recent_runs_path(1): {"total_count": 1, "workflow_runs": [self.previous]},
        }, {(29, None): "REQUESTED_BUILD_NUMBER: 160\nRELEASE_BUILD_NUMBER: 160"})
        self.set_plan()
        self.set_export_backends()
        self.git_values = {
            ("remote", "get-url", "origin"): f"https://github.com/{release.REPOSITORY}.git",
            ("rev-parse", "HEAD"): self.sha,
            ("status", "--porcelain=v1", "--untracked-files=no", "--ignore-submodules=none"): "",
        }
        mock_git = patch.object(release, "git", side_effect=lambda *args: self.git_values[args])
        mock_git.start()
        self.addCleanup(mock_git.stop)

    def set_plan(self):
        self.gh.logs[(20, 201)] = "plan\tSelect checks\t2026-09-13T00:00:00Z " + release.PLAN_MARKER + json.dumps(self.plan)
        jobs = [self.plan_job] + [
            {"id": 202 + index, "name": name, "head_sha": self.sha, "status": "completed",
             "conclusion": "success", "completed_at": self.now.isoformat()}
            for index, name in enumerate(self.plan["required_jobs"])
        ]
        self.gh.values["actions/runs/20/jobs?filter=latest&per_page=100&page=1"] = {"total_count": len(jobs), "jobs": jobs}

    def set_export_backends(self):
        self.backend_indexes = []
        self.backend_job_indexes = []
        for index, (workflow, required) in enumerate(release.planner.PRESERVATION_EXPORT_BACKEND_JOBS.items()):
            run_id = 500 + index
            identity = {"id": 700 + index, "path": ".github/workflows/" + workflow, "state": "active"}
            self.gh.values[f"actions/workflows/{workflow}"] = identity
            key = f"actions/workflows/{workflow}/runs?head_sha={self.sha}&event=push&per_page=100"
            run = dict(self.run, id=run_id, run_number=10, workflow_id=identity["id"],
                       path=identity["path"], head_branch="codex/export", run_attempt=1)
            self.gh.values[key] = {"total_count": 1, "workflow_runs": [run]}
            self.gh.values[key.replace("event=push", "event=workflow_dispatch")] = {"total_count": 0, "workflow_runs": []}
            jobs_key = f"actions/runs/{run_id}/jobs?filter=latest&per_page=100&page=1"
            jobs = [dict(self.plan_job, id=run_id * 100 + n, name=name) for n, name in enumerate(required)]
            self.gh.values[jobs_key] = {"total_count": len(jobs), "jobs": jobs}
            self.backend_indexes.append(key); self.backend_job_indexes.append(jobs_key)

    def export_plan(self):
        selected = release.planner.PRESERVATION_EXPORT_SCOPE
        self.plan.update(scope=selected, required_jobs=list(release.planner.required_jobs_from_scope(selected)))
        self.set_plan()

    def test_export_requires_both_same_sha_backends_and_keeps_release_flags(self):
        self.export_plan()
        result = self.prepare()
        self.assertEqual(set(result["ci"]["backend_evidence"]), {"preservation-service.yml", "sharing-service.yml"})
        self.assertNotIn("preservation_pilot", result["inputs"])
        self.assertNotIn("billing_sandbox", result["inputs"])
        self.assertEqual(self.gh.dispatches, [])
        self.candidate()
        self.assertEqual(self.prepare()["ci"]["backend_evidence"]["preservation-service.yml"]["sha"], self.sha)

    def test_export_sharing_dispatch_requires_absent_push_and_exact_executed_candidate(self):
        self.export_plan()
        key = self.backend_indexes[1]
        push = copy.deepcopy(self.gh.values[key])
        dispatch_key = key.replace("event=push", "event=workflow_dispatch")
        dispatched = copy.deepcopy(push)
        dispatched["workflow_runs"][0]["event"] = "workflow_dispatch"
        self.gh.values[key] = {"total_count": 0, "workflow_runs": []}
        self.gh.values[dispatch_key] = dispatched
        self.assertEqual(self.prepare()["ci"]["backend_evidence"]["sharing-service.yml"]["event"], "workflow_dispatch")
        for field, value in (("head_sha", "b" * 40), ("head_branch", "main"),
                             ("head_branch", "diagnostic/export"), ("event", "pull_request"),
                             ("workflow_id", 999), ("repository", {"full_name": "other/repo"}),
                             ("status", "in_progress"), ("conclusion", "failure")):
            invalid = copy.deepcopy(dispatched); invalid["workflow_runs"][0][field] = value
            self.gh.values[dispatch_key] = invalid
            with self.subTest(field=field, value=value), self.assertRaises(release.Blocked): self.prepare()
        self.gh.values[dispatch_key] = dispatched
        for changes in ({"status": "in_progress", "conclusion": None}, {"conclusion": "failure"}, {"head_branch": "main"}):
            invalid = copy.deepcopy(push); invalid["workflow_runs"][0].update(changes)
            self.gh.values[key] = invalid
            with self.subTest(push=changes), self.assertRaises(release.Blocked): self.prepare()
        self.gh.values[key] = {"total_count": 1, "workflow_runs": []}
        with self.assertRaises(release.Blocked): self.prepare()
        for invalid_count in (False, 0.0):
            self.gh.values[key] = {"total_count": invalid_count, "workflow_runs": []}
            with self.subTest(total_count=invalid_count), self.assertRaises(release.Blocked): self.prepare()
        self.gh.values[key] = {"total_count": 0, "workflow_runs": []}
        latest = dict(dispatched["workflow_runs"][0], id=999, run_number=11, conclusion="failure")
        self.gh.values[dispatch_key] = {"total_count": 2, "workflow_runs": dispatched["workflow_runs"]+[latest]}
        with self.assertRaises(release.Blocked): self.prepare()
        self.gh.values[dispatch_key] = dispatched
        jobs = self.gh.values[self.backend_job_indexes[1]]["jobs"]
        for job in jobs:
            job["conclusion"] = "skipped"
            with self.assertRaises(release.Blocked): self.prepare()
            job["conclusion"] = "success"
        self.gh.values[self.backend_indexes[0]] = {"total_count": 0, "workflow_runs": []}
        with self.assertRaises(release.Blocked): self.prepare()

    def test_export_preserves_candidate_proof_when_separate_main_backend_is_pending_or_failed(self):
        self.export_plan()
        for conclusion, status in ((None, "in_progress"), ("failure", "completed"), ("success", "completed")):
            self.set_export_backends()
            for key in self.backend_indexes:
                value = self.gh.values[key]
                value["workflow_runs"].append(dict(value["workflow_runs"][0], id=999,
                    run_number=11, head_branch="main", status=status, conclusion=conclusion))
                value["total_count"] = 2
            # Real main-reuse lookup must connect to the same candidate backend
            # proof, never to the independently executing main backend run.
            self.candidate()
            candidate = self.gh.values["actions/runs/10"]
            def api(path):
                prefix = f"/repos/{release.REPOSITORY}/"
                self.assertTrue(path.startswith(prefix))
                local = path[len(prefix):]
                if local.startswith("actions/workflows/ios-build.yml/runs?"):
                    return {"workflow_runs": [candidate]}
                return self.gh.get(local)
            env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/main", "GITHUB_SHA": self.sha,
                   "GITHUB_REPOSITORY": release.REPOSITORY, "GITHUB_RUN_ID": "20"}
            with patch.object(release.planner, "git", return_value=self.sha):
                self.assertEqual(release.planner.find_evidence(env, tuple(self.plan["required_jobs"]), api, self.now), (10, self.sha))
            result = self.prepare()
            self.assertEqual(result["ci"]["backend_evidence"]["preservation-service.yml"]["run_id"], 500)
            # Restore executed native jobs before preparing the next main event.
            self.plan.update(evidence_run_id=None, evidence_sha=None); self.set_plan()
        # Main alone cannot certify the release candidate.
        for key in self.backend_indexes:
            self.gh.values[key]["workflow_runs"].pop(0); self.gh.values[key]["total_count"] = 1
        with self.assertRaises(release.Blocked): self.prepare()

    def test_export_rejects_absent_wrong_identity_and_newer_unsuccessful_backends(self):
        self.export_plan()
        for key in self.backend_indexes:
            valid = copy.deepcopy(self.gh.values[key])
            cases = [{"total_count": 0, "workflow_runs": []},
                     {"total_count": 2, "workflow_runs": valid["workflow_runs"]}]
            for field, value in (("head_sha", "b" * 40), ("event", "workflow_dispatch"),
                    ("workflow_id", 999), ("path", ".github/workflows/other.yml"),
                    ("head_branch", "diagnostic/export"), ("repository", {"full_name": "other/repo"}),
                    ("head_repository", {"full_name": "other/repo"}), ("status", "in_progress"),
                    ("conclusion", "failure")):
                changed = copy.deepcopy(valid); changed["workflow_runs"][0][field] = value; cases.append(changed)
            newest = dict(valid["workflow_runs"][0], id=900, run_number=11, status="completed", conclusion="failure")
            cases.append({"total_count": 2, "workflow_runs": valid["workflow_runs"] + [newest]})
            cases.append({"total_count": 2, "workflow_runs": valid["workflow_runs"] * 2})
            for invalid in cases:
                self.gh.values[key] = invalid
                with self.subTest(key=key, invalid=invalid), self.assertRaises(release.Blocked): self.prepare()
            self.gh.values[key] = valid

    def test_export_rejects_every_missing_skipped_foreign_stale_or_duplicate_backend_job(self):
        self.export_plan()
        for key in self.backend_job_indexes:
            valid = copy.deepcopy(self.gh.values[key])
            for index in range(len(valid["jobs"])):
                cases = []
                jobs = copy.deepcopy(valid["jobs"]); jobs.pop(index); cases.append({"total_count": len(jobs), "jobs": jobs})
                for field, value in (("status", "queued"), ("conclusion", "skipped"), ("conclusion", "failure"),
                        ("head_sha", "b" * 40), ("completed_at", (self.now - dt.timedelta(hours=25)).isoformat()),
                        ("completed_at", (self.now + dt.timedelta(minutes=1)).isoformat())):
                    changed = copy.deepcopy(valid); changed["jobs"][index][field] = value; cases.append(changed)
                jobs = copy.deepcopy(valid["jobs"]); jobs.append(jobs[index]); cases.append({"total_count": len(jobs), "jobs": jobs})
                for invalid in cases:
                    self.gh.values[key] = invalid
                    with self.subTest(key=key, index=index, invalid=invalid), self.assertRaises(release.Blocked): self.prepare()
            self.gh.values[key] = valid

    def prepare(self, build="165", sha=None):
        return release.prepare(self.gh, sha or self.sha, build, 20, self.now, {})

    def candidate(self):
        self.plan.update(evidence_run_id=10, evidence_sha=self.sha)
        self.set_plan()
        self.gh.values["actions/runs/10"] = dict(self.run, id=10, head_branch="codex/candidate")
        self.gh.values["actions/runs/10/jobs?filter=latest&per_page=100&page=1"] = copy.deepcopy(
            self.gh.values["actions/runs/20/jobs?filter=latest&per_page=100&page=1"])
        for job in self.gh.values["actions/runs/20/jobs?filter=latest&per_page=100&page=1"]["jobs"][1:]:
            job["conclusion"] = "skipped"

    def test_fixed_inputs_and_full_plan_are_verified_without_dispatch(self):
        result = self.prepare()
        self.assertEqual(result["inputs"], {
            "expected_main_sha": self.sha, "build_number": "165", "release_mode": "media-staging",
            "official_window_feed_url": release.release_config.PREVIEW_FEED_URL,
            "upload_to_testflight": "true", "retain_signed_artifacts": "true",
        })
        self.assertEqual(result["ci"]["required_jobs"], list(release.planner.FULL))
        self.assertEqual(self.gh.dispatches, [])

    def test_every_current_scope_including_movie_only_is_supported(self):
        for scope in (*release.planner.SCOPES, "movie-screen-only"):
            with self.subTest(scope=scope):
                self.plan.update(scope=scope, required_jobs=list(release.planner.required_jobs_from_scope(scope)))
                if scope == release.planner.MODERATION_RESOLUTION_SCOPE:
                    self.plan["required_backend_runs"] = release.planner.moderation_resolution_requirements(self.sha)
                self.set_plan()
                with patch.object(release.planner, "moderation_resolution_backend_evidence", return_value={"verified": True}):
                    self.assertEqual(self.prepare()["ci"]["scope"], scope)

    def test_resolution_release_calls_owning_backend_verifier_and_propagates_rejection(self):
        selected = release.planner.MODERATION_RESOLUTION_SCOPE
        self.plan.update(scope=selected, required_jobs=list(release.planner.required_jobs_from_scope(selected)),
                         required_backend_runs=release.planner.moderation_resolution_requirements(self.sha))
        self.set_plan()
        with patch.object(release.planner, "moderation_resolution_backend_evidence", return_value={"verified": True}) as verify:
            self.assertEqual(self.prepare()["ci"]["backend_evidence"], {"verified": True})
            self.assertEqual(verify.call_args.args[:2], (self.sha, release.REPOSITORY))
            self.assertEqual(verify.call_args.kwargs, {"branch": None})
        for failure in (ValueError("missing push"), KeyError("incomplete"), OSError("API unavailable")):
            with patch.object(release.planner, "moderation_resolution_backend_evidence", side_effect=failure), self.assertRaises(release.Blocked):
                self.prepare()
        self.assertEqual(self.gh.dispatches, [])

    def test_resolution_release_rejects_absent_partial_or_wrong_sha_backend_declaration(self):
        selected = release.planner.MODERATION_RESOLUTION_SCOPE
        self.plan.update(scope=selected, required_jobs=list(release.planner.required_jobs_from_scope(selected)))
        for required in (None, [], release.planner.moderation_resolution_requirements("b" * 40),
                         release.planner.moderation_resolution_requirements(self.sha)[:-1]):
            self.plan["required_backend_runs"] = required; self.set_plan()
            with patch.object(release.planner, "moderation_resolution_backend_evidence") as verify, self.assertRaises(release.Blocked):
                self.prepare()
            verify.assert_not_called()

    def test_internal_preservation_flag_is_explicit_and_normal_release_is_unchanged(self):
        self.assertNotIn("preservation_pilot", self.prepare()["inputs"])
        result = release.prepare(self.gh, self.sha, "165", 20, self.now, {}, preservation_pilot=True)
        self.assertEqual(result["inputs"]["preservation_pilot"], "true")
        self.assertEqual(result["inputs"]["release_mode"], "media-staging")
        self.assertEqual(self.gh.dispatches, [])
        for value in ("true", 1, None):
            with self.assertRaises(release.Blocked):
                release.prepare(self.gh, self.sha, "165", 20, self.now, {}, preservation_pilot=value)

    def test_billing_sandbox_is_explicit_requires_pilot_and_does_not_dispatch(self):
        self.assertNotIn("billing_sandbox", self.prepare()["inputs"])
        result = release.prepare(self.gh, self.sha, "165", 20, self.now, {},
                                 preservation_pilot=True, billing_sandbox=True)
        self.assertEqual(result["inputs"]["billing_sandbox"], "true")
        self.assertEqual(result["inputs"]["preservation_pilot"], "true")
        self.assertEqual(self.gh.dispatches, [])
        for pilot, requested in ((False, True), (True, "true"), (True, 1), (True, None)):
            with self.subTest(pilot=pilot, requested=requested), self.assertRaises(release.Blocked):
                release.prepare(self.gh, self.sha, "165", 20, self.now, {},
                                preservation_pilot=pilot, billing_sandbox=requested)

    def test_skipped_main_jobs_require_real_referenced_candidate_jobs(self):
        self.candidate()
        self.assertEqual(self.prepare()["ci"]["tested_run"], 10)
        self.gh.values["actions/runs/10/jobs?filter=latest&per_page=100&page=1"]["jobs"][1]["conclusion"] = "skipped"
        with self.assertRaises(release.Blocked):
            self.prepare()

    def test_managed_pilot_correction_requires_old_native_jobs_and_new_ui(self):
        self.test_lost_cat_test_correction_requires_old_three_jobs_and_new_app_ui(release.planner.REVIEWED_MANAGED_PRESERVATION_SCOPE)

    def test_vet_correction_requires_old_native_jobs_and_new_ui(self):
        self.test_lost_cat_test_correction_requires_old_three_jobs_and_new_app_ui(release.planner.VET_SAVED_CAT_SCOPE)

    def test_photo_correction_release_and_main_require_four_reused_and_three_rerun_jobs(self):
        self.test_album_release_rechecks_old_six_jobs_exact_graph_and_new_solo(photo=True)

    def test_album_release_rechecks_old_six_jobs_exact_graph_and_new_solo(self, photo=False):
        planner = release.planner
        required = planner.ALBUM_CORRECTION_REQUIRED
        source_sha = planner.PHOTO_SMOKE_CORRECTION_SOURCE if photo else planner.ALBUM_CORRECTION_SOURCE
        source_id = planner.PHOTO_SMOKE_CORRECTION_RUN if photo else planner.ALBUM_CORRECTION_RUN
        owning = planner.correction_owning_jobs(planner.FULL_SCOPE, source_sha)
        self.run["head_branch"] = planner.PHOTO_SMOKE_CORRECTION_BRANCH if photo else planner.ALBUM_CORRECTION_BRANCH
        old_jobs = [dict(self.plan_job, id=301, head_sha=source_sha)] + [
            {"id": 302 + index, "name": name, "head_sha": source_sha, "status": "completed",
             "conclusion": "failure" if name in owning else "success", "completed_at": self.now.isoformat()}
            for index, name in enumerate(required)]
        solo_log = None
        if photo:
            solo = next(job for job in old_jobs[1:] if job["name"] == planner.PHOTO_SMOKE_CORRECTION_SOLO_JOB)
            solo.update(id=planner.PHOTO_SMOKE_CORRECTION_SOLO_JOB_ID, conclusion="cancelled", steps=[
                {"name": "Run sharing runtime matrix", "status": "completed", "conclusion": "cancelled"},
                {"name": "Upload sharing runtime matrix artifacts", "status": "completed", "conclusion": "failure"},
            ])
            solo_log = (
                "Test Suite 'SoloMemoriesUITests' passed at 2026-10-05 01:13:21.029.\n"
                + "Executed 46 tests, with 0 failures (0 unexpected) in 3676.850 (3676.913) seconds\n" * 3
                + "** TEST SUCCEEDED **\n"
                + "Sharing checks [app-ui-solo; scope full-v1]\tUpload sharing runtime matrix artifacts\n"
                + "Error: ENOENT: no such file or directory, open '/Users/runner/work/_temp/MomentComposer.xcresult/Staging/1_Test/Diagnostics/session.log'\n"
                + "Error: An error has occurred during zip creation for the artifact\n"
            )
        evidence = {"run_id": source_id, "sha": source_sha,
                    "jobs": [{"name": job["name"], "job_id": job["id"]} for job in old_jobs[1:] if job["name"] not in owning]}
        self.plan.update(required_jobs=list(required), test_correction_evidence=evidence)
        self.set_plan()
        current = self.gh.values["actions/runs/20/jobs?filter=latest&per_page=100&page=1"]["jobs"]
        for job in current[1:]:
            if job["name"] not in owning: job["conclusion"] = "skipped"
        self.gh.values[f"actions/runs/{source_id}"] = dict(self.run, id=source_id, head_sha=source_sha, conclusion="failure")
        self.gh.values[f"actions/runs/{source_id}/jobs?filter=latest&per_page=100&page=1"] = {"total_count": len(old_jobs), "jobs": old_jobs}
        old_plan = {"schema_version": 1, "repository": release.REPOSITORY, "head_sha": source_sha,
                    "scope": planner.FULL_SCOPE, "required_jobs": list(required), "evidence_run_id": None, "evidence_sha": None}
        self.gh.logs[(source_id, 301)] = release.PLAN_MARKER + json.dumps(old_plan)
        if photo:
            failure_log = "\n".join("Test Case '-[NekoWidgetUITests." + case.replace("/", " ") + "]' failed"
                                    for case in sorted(planner.PHOTO_SMOKE_CORRECTION_CASES))
            for job in old_jobs[1:]:
                if job["name"] in (planner.SMOKE, planner.lane_job(planner.FULL_SCOPE, "app-ui-other")):
                    self.gh.logs[(source_id, job["id"])] = failure_log
                elif job["name"] == planner.PHOTO_SMOKE_CORRECTION_SOLO_JOB:
                    self.gh.logs[(source_id, job["id"])] = solo_log
        with patch.object(planner, "test_correction_inputs", return_value=True), \
                patch.object(planner, "sharing_jobs", side_effect=lambda selected: tuple(required[2:]) if selected == planner.FULL_SCOPE else ()):
            self.assertEqual(release.check_ci(self.gh, self.sha, 20, self.now)["reused_run"], source_id)
            for job in old_jobs[1:]:
                if job["name"] in owning: continue
                job["conclusion"] = "skipped"
                with self.assertRaises(release.Blocked): release.check_ci(self.gh, self.sha, 20, self.now)
                job["conclusion"] = "success"
            for new_ui in (job for job in current if job["name"] in owning):
                for outcome in ("skipped", "failure"):
                    new_ui["conclusion"] = outcome
                    with self.assertRaises(release.Blocked): release.check_ci(self.gh, self.sha, 20, self.now)
                new_ui["conclusion"] = "success"
            self.gh.logs[(source_id, 301)] = release.PLAN_MARKER + json.dumps({**old_plan, "required_jobs": list(required[:-1])})
            with self.assertRaises(release.Blocked): release.check_ci(self.gh, self.sha, 20, self.now)
            self.gh.logs[(source_id, 301)] = release.PLAN_MARKER + json.dumps(old_plan)
            if photo:
                main = dict(self.run, id=21, head_branch="main")
                main_plan = {**self.plan, "test_correction_evidence": None,
                             "evidence_run_id": 20, "evidence_sha": self.sha}
                main_jobs = [dict(self.plan_job, id=501)]
                self.gh.values["actions/runs/21"] = main
                self.gh.values["actions/runs/21/jobs?filter=latest&per_page=100&page=1"] = {"total_count": 1, "jobs": main_jobs}
                self.gh.logs[(21, 501)] = release.PLAN_MARKER + json.dumps(main_plan)
                for job in [self.plan_job, *old_jobs]:
                    self.gh.values[f"actions/jobs/{job['id']}"] = {"run_id": 20 if job["id"] == 201 else source_id}
                result = release.check_ci(self.gh, self.sha, 21, self.now)
                self.assertEqual((result["tested_run"], result["tested_sha"]), (20, self.sha))
                for new_ui in (job for job in current if job["name"] in owning):
                    new_ui["conclusion"] = "skipped"
                    with self.assertRaises(release.Blocked): release.check_ci(self.gh, self.sha, 21, self.now)
                    new_ui["conclusion"] = "success"

    def test_lost_cat_test_correction_requires_old_three_jobs_and_new_app_ui(self, selected_scope=release.planner.LOST_CAT_UX_SCOPE):
        required = release.planner.required_jobs_from_scope(selected_scope)
        self.run["head_branch"] = "codex/lost-cat"
        self.plan.update(scope=selected_scope, required_jobs=list(required))
        source_sha = "b" * 40
        evidence = {"run_id": 10, "sha": source_sha,
                    "jobs": [{"name": name, "job_id": 302 + index}
                             for index, name in enumerate(required[:3])]}
        self.plan["test_correction_evidence"] = evidence
        self.set_plan()
        current = self.gh.values["actions/runs/20/jobs?filter=latest&per_page=100&page=1"]["jobs"]
        for job in current[1:4]:
            job["conclusion"] = "skipped"
        source = dict(self.run, id=10, head_sha=source_sha, conclusion="failure")
        self.gh.values["actions/runs/10"] = source
        old_jobs = [dict(self.plan_job, id=301, head_sha=source_sha)] + [
            {"id": 302 + index, "name": name, "head_sha": source_sha,
             "status": "completed", "conclusion": "failure" if index == 3 else "success",
             "completed_at": self.now.isoformat()}
            for index, name in enumerate(required)]
        self.gh.values["actions/runs/10/jobs?filter=latest&per_page=100&page=1"] = {
            "total_count": len(old_jobs), "jobs": old_jobs}
        old_plan = {"schema_version": 1, "repository": release.REPOSITORY, "head_sha": source_sha,
                    "scope": selected_scope, "required_jobs": list(required),
                    "evidence_run_id": None, "evidence_sha": None}
        self.gh.logs[(10, 301)] = release.PLAN_MARKER + json.dumps(old_plan)
        with patch.object(release.planner, "test_correction_inputs", return_value=True):
            result = release.check_ci(self.gh, self.sha, 20, self.now)
            self.assertEqual(result["reused_run"], 10)
            for index in range(1, 4):
                old_jobs[index]["conclusion"] = "skipped"
                with self.assertRaises(release.Blocked):
                    release.check_ci(self.gh, self.sha, 20, self.now)
                old_jobs[index]["conclusion"] = "success"
            current[-1]["conclusion"] = "failure"
            with self.assertRaises(release.Blocked):
                release.check_ci(self.gh, self.sha, 20, self.now)

    def test_reused_main_accepts_duplicate_skipped_matrix_placeholders(self):
        self.candidate()
        result = self.gh.values["actions/runs/20/jobs?filter=latest&per_page=100&page=1"]
        placeholder = "Sharing checks [${{ matrix.lane }}; scope ${{ needs.plan.outputs.runtime_scope }}]"
        result["jobs"].extend({
            "id": 400 + index, "name": placeholder, "head_sha": self.sha,
            "status": "completed", "conclusion": "skipped",
            "completed_at": self.now.isoformat(),
        } for index in range(2))
        result["total_count"] = len(result["jobs"])
        self.assertEqual(self.prepare()["ci"]["tested_run"], 10)
        self.assertEqual(self.prepare()["ci"]["required_jobs"], list(release.planner.FULL))

    def test_candidate_must_be_fresh_matching_push_workflow_and_repository(self):
        self.candidate()
        baseline = copy.deepcopy(self.gh.values["actions/runs/10"])
        for key, value in [
            ("head_sha", "b" * 40), ("event", "workflow_dispatch"), ("workflow_id", 8),
            ("repository", {"full_name": "other/repo"}), ("head_repository", {"full_name": "other/repo"}),
            ("updated_at", (self.now - dt.timedelta(hours=25)).isoformat()), ("conclusion", "failure"),
        ]:
            with self.subTest(key=key):
                self.gh.values["actions/runs/10"] = dict(baseline, **{key: value})
                with self.assertRaises(release.Blocked):
                    self.prepare()

    def test_main_run_identity_must_match_target(self):
        baseline = copy.deepcopy(self.run)
        for key, value in [("head_sha", "b" * 40), ("head_branch", "unreviewed/candidate"),
                           ("event", "workflow_dispatch"), ("conclusion", "failure"),
                           ("workflow_id", 8), ("repository", {"full_name": "other/repo"})]:
            with self.subTest(key=key):
                self.gh.values["actions/runs/20"] = dict(baseline, **{key: value})
                with self.assertRaises(release.Blocked):
                    self.prepare()

    def test_plan_identity_scope_and_exact_required_jobs_are_checked(self):
        baseline = copy.deepcopy(self.plan)
        for key, value in [("schema_version", 2), ("schema_version", True), ("head_sha", "b" * 40),
                           ("repository", "other/repo"), ("scope", "unknown-v1"),
                           ("required_jobs", [release.planner.BUILD]), ("evidence_sha", self.sha)]:
            with self.subTest(key=key):
                self.plan = dict(baseline, **{key: value})
                self.set_plan()
                with self.assertRaises((release.Blocked, ValueError)):
                    self.prepare()

    def test_missing_duplicate_or_failed_plan_is_rejected(self):
        original = self.gh.logs[(20, 201)]
        for text in ("No plan metadata", original + "\n" + original):
            self.gh.logs[(20, 201)] = text
            with self.assertRaises(release.Blocked):
                self.prepare()
        self.set_plan()
        self.plan_job["conclusion"] = "failure"
        with self.assertRaises(release.Blocked):
            self.prepare()

    def test_other_repository_fixture_plan_does_not_shadow_real_plan(self):
        fixture = dict(self.plan, repository="owner/repo")
        self.gh.logs[(20, 201)] += "\n" + release.PLAN_MARKER + json.dumps(fixture)
        self.assertEqual(self.prepare()["ci"]["main_ci_run"], 20)

    def test_missing_failed_duplicate_wrong_sha_or_truncated_jobs_reject(self):
        for kind in ("missing", "failed", "duplicate", "wrong-sha", "truncated"):
            self.set_plan()
            result = self.gh.values["actions/runs/20/jobs?filter=latest&per_page=100&page=1"]
            if kind == "missing":
                result["jobs"].pop()
            elif kind == "failed":
                result["jobs"][-1]["conclusion"] = "failure"
            elif kind == "duplicate":
                result["jobs"].append(copy.deepcopy(result["jobs"][-1]))
            elif kind == "wrong-sha":
                result["jobs"][-1]["head_sha"] = "b" * 40
            result["total_count"] = len(result["jobs"]) + (1 if kind == "truncated" else 0)
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                self.prepare()

    def test_partial_candidate_retry_keeps_siblings_and_requires_latest_success(self):
        self.candidate()
        self.gh.values["actions/runs/10"]["run_attempt"] = 2
        jobs = copy.deepcopy(self.gh.values["actions/runs/10/jobs?filter=latest&per_page=100&page=1"]["jobs"])
        for job in jobs:
            job.update(run_id=10, run_attempt=1)
        retried = dict(jobs[-1], id=900, run_attempt=2)
        jobs[-1]["conclusion"] = "failure"
        jobs.append(retried)
        self.gh.values["actions/runs/10/jobs?filter=all&per_page=100&page=1"] = {
            "total_count": len(jobs), "jobs": jobs,
        }
        self.assertEqual(self.prepare()["ci"]["tested_run"], 10)
        retried["conclusion"] = "skipped"
        with self.assertRaises(release.Blocked):
            self.prepare()

    def test_partial_main_retry_uses_successful_plan_from_earlier_attempt(self):
        self.run["run_attempt"] = 2
        jobs = copy.deepcopy(self.gh.values["actions/runs/20/jobs?filter=latest&per_page=100&page=1"]["jobs"])
        for job in jobs:
            job.update(run_id=20, run_attempt=1)
        jobs.append(dict(jobs[-1], id=900, run_attempt=2))
        self.gh.values["actions/runs/20/jobs?filter=all&per_page=100&page=1"] = {
            "total_count": len(jobs), "jobs": jobs,
        }
        self.assertEqual(self.prepare()["ci"]["main_ci_run"], 20)

    def test_today_retry_cannot_refresh_a_two_day_old_successful_sibling(self):
        self.candidate()
        self.gh.values["actions/runs/10"]["run_attempt"] = 2
        jobs = copy.deepcopy(self.gh.values["actions/runs/10/jobs?filter=latest&per_page=100&page=1"]["jobs"])
        for job in jobs:
            job.update(run_id=10, run_attempt=1)
        jobs[1]["completed_at"] = (self.now - dt.timedelta(days=2)).isoformat()
        jobs.append(dict(jobs[-1], id=900, run_attempt=2, completed_at=self.now.isoformat()))
        self.gh.values["actions/runs/10/jobs?filter=all&per_page=100&page=1"] = {
            "total_count": len(jobs), "jobs": jobs,
        }
        # run.updated_at and the retried job are fresh; the untouched required
        # sibling must independently satisfy the same 24-hour evidence bound.
        with self.assertRaises(release.Blocked):
            self.prepare()

    def test_explicit_build_sha_and_clean_tracked_checkout_are_required(self):
        for build in ("", "0", "-1", "01", "1.2", "165\n", "$(upload)", "165;other"):
            with self.subTest(build=build), self.assertRaises(release.Blocked):
                self.prepare(build=build)
        for sha in ("main", "abcdef", "A" * 40):
            with self.subTest(sha=sha), self.assertRaises(release.Blocked):
                self.prepare(sha=sha)
        for key, value in [
            (("rev-parse", "HEAD"), "b" * 40),
            (("status", "--porcelain=v1", "--untracked-files=no", "--ignore-submodules=none"), " M tracked.swift"),
            (("remote", "get-url", "origin"), "https://github.com/other/repo.git"),
        ]:
            old = self.git_values[key]
            self.git_values[key] = value
            with self.assertRaises(release.Blocked):
                self.prepare()
            self.git_values[key] = old
        self.gh.values["git/ref/heads/main"]["object"]["sha"] = "b" * 40
        self.gh.values[f"compare/{self.sha}...{'b' * 40}"] = {
            "status": "diverged", "merge_base_commit": {"sha": "c" * 40}}
        with self.assertRaises(release.Blocked):
            self.prepare()

    def test_pinned_candidate_ci_remains_valid_when_main_advances(self):
        tip = "b" * 40
        self.gh.values["git/ref/heads/main"]["object"]["sha"] = tip
        comparison = {"status": "ahead", "merge_base_commit": {"sha": self.sha}}
        self.gh.values[f"compare/{self.sha}...{tip}"] = comparison
        self.run["head_branch"] = "codex/release-candidate"
        self.assertEqual(self.prepare()["sha"], self.sha)
        comparison["status"] = "behind"
        with self.assertRaises(release.Blocked):
            self.prepare()
        comparison.update(status="ahead", merge_base_commit={"sha": "c" * 40})
        with self.assertRaises(release.Blocked):
            self.prepare()

    def test_external_source_checkout_requires_absolute_path_and_merged_clean_tool(self):
        with tempfile.TemporaryDirectory() as directory:
            selected = Path(directory).resolve()
            self.assertEqual(release.verified_candidate_root(self.gh, selected), selected)
            for invalid in (Path("relative-checkout"), selected / "missing"):
                with self.assertRaises(release.Blocked):
                    release.verified_candidate_root(self.gh, invalid)
            self.git_values[("status", "--porcelain=v1", "--untracked-files=no", "--ignore-submodules=none")] = " M release-testflight.py"
            with self.assertRaises(release.Blocked):
                release.verified_candidate_root(self.gh, selected)

    def test_external_cli_still_checks_tool_and_source_then_defaults_to_dry_run(self):
        previous_root = release.ROOT
        roots = []
        original = release.check_checkout
        def checked(gh, sha):
            roots.append(release.ROOT)
            return original(gh, sha)
        with tempfile.TemporaryDirectory() as directory:
            selected = Path(directory).resolve()
            args = ["--sha", self.sha, "--build-number", "165", "--ci-run", "20", "--checkout", str(selected)]
            with patch.object(release, "GitHub", return_value=self.gh), patch.object(release, "check_checkout", side_effect=checked), \
                    patch.object(release.os, "chdir"), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(release.main(args), 0)
            self.assertEqual(roots, [previous_root, selected])
            self.assertEqual(self.gh.dispatches, [])
            self.assertEqual(release.ROOT, previous_root)

    def test_external_cli_rejects_dirty_or_other_sha_source_before_dispatch(self):
        previous_root = release.ROOT
        original_git = release.git
        with tempfile.TemporaryDirectory() as directory:
            selected = Path(directory).resolve()
            args = ["--sha", self.sha, "--build-number", "165", "--ci-run", "20", "--checkout", str(selected), "--dispatch"]
            for bad_args, value in (
                (("rev-parse", "HEAD"), "b" * 40),
                (("status", "--porcelain=v1", "--untracked-files=no", "--ignore-submodules=none"), " M source.swift"),
            ):
                def checked_git(*command):
                    if release.ROOT == selected and command == bad_args:
                        return value
                    return original_git(*command)
                with patch.object(release, "GitHub", return_value=self.gh), patch.object(release, "git", side_effect=checked_git), \
                        patch.object(release.os, "chdir"), contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(release.main(args), 1)
                self.assertEqual(self.gh.dispatches, [])
                self.assertEqual(release.ROOT, previous_root)

    def test_duplicate_lower_and_any_active_release_are_blocked(self):
        for build in ("164", "100"):
            with self.assertRaises(release.Blocked):
                self.prepare(build=build)
        for status in ("queued", "in_progress", "waiting", "pending", None):
            self.previous["status"] = status
            with self.subTest(status=status), self.assertRaises(release.Blocked):
                self.prepare()

    def test_successful_legacy_builds_use_logs_and_default_run_number(self):
        self.previous["display_title"] = "Archive and upload to TestFlight"
        self.gh.logs[(30, None)] = "env:\n  REQUESTED_BUILD_NUMBER: 164\n  RELEASE_BUILD_NUMBER: 164\n"
        self.assertEqual(self.prepare()["previous_reserved_build"], 164)
        with self.assertRaises(release.Blocked):
            self.prepare(build="164")
        self.gh.logs[(30, None)] = "REQUESTED_BUILD_NUMBER: \nRELEASE_BUILD_NUMBER: 12\n"
        self.assertEqual(self.prepare()["previous_reserved_build"], 160)

    def test_legacy_unknown_or_conflicting_numbers_fail_closed(self):
        for log in ("no evidence", "REQUESTED_BUILD_NUMBER: 164\nRELEASE_BUILD_NUMBER: 165",
                    "REQUESTED_BUILD_NUMBER: 164\nREQUESTED_BUILD_NUMBER: 166",
                    "RELEASE_BUILD_NUMBER: ", "RELEASE_BUILD_NUMBER: 0164"):
            with self.subTest(log=log), self.assertRaises(release.Blocked):
                release.legacy_build_number(log, 12)

    def test_pinned_source_title_reserves_build_even_when_workflow_main_moves(self):
        self.previous["display_title"] = "TestFlight build 164 @ " + "b" * 40
        self.assertEqual(self.prepare()["previous_reserved_build"], 164)
        with self.assertRaises(release.Blocked):
            self.prepare(build="164")

    def test_legacy_failure_is_not_proof_of_no_upload(self):
        self.previous.update(display_title="old title", conclusion="failure")
        step = {"name": "Validate and upload IPA to TestFlight", "status": "completed", "conclusion": "failure"}
        self.gh.values["actions/runs/30/jobs?filter=latest&per_page=100&page=1"] = {
            "total_count": 1, "jobs": [{"steps": [step]}],
        }
        with self.assertRaises(release.Blocked):
            self.prepare()
        step["conclusion"] = "skipped"
        self.assertEqual(self.prepare()["previous_reserved_build"], 160)

    def test_release_history_truncation_and_identity_fail_closed(self):
        history = self.gh.values[release.recent_runs_path(1)]
        for total in (2, 1001):
            history["total_count"] = total
            with self.assertRaises(release.Blocked):
                self.prepare()
        history["total_count"] = 1
        self.previous["workflow_id"] = 100
        with self.assertRaises(release.Blocked):
            self.prepare()

    def test_cli_defaults_to_dry_run_and_explicit_dispatch_posts_once(self):
        args = ["--sha", self.sha, "--build-number", "165", "--main-ci-run", "20"]
        with patch.object(release, "GitHub", return_value=self.gh), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(release.main(args), 0)
            self.assertEqual(self.gh.dispatches, [])
            self.assertEqual(release.main(args + ["--dispatch"]), 0)
        self.assertEqual(len(self.gh.dispatches), 1)
        self.assertEqual(self.gh.dispatches[0]["retain_signed_artifacts"], "true")
        self.assertEqual(self.gh.dispatches[0]["expected_main_sha"], self.sha)

    def test_audited_baseline_is_verified_and_older_runs_are_not_fetched(self):
        self.prepare()
        self.assertIn("%3E%3D2026-09-13T05%3A42%3A24Z", release.recent_runs_path(1))
        self.assertEqual([item for item in self.gh.requests if item[0] == "LOG" and item[2] is None],
                         [("LOG", 29, None)])
        self.gh.logs[(29, None)] = "RELEASE_BUILD_NUMBER: 159"
        with self.assertRaises(release.Blocked):
            self.prepare()
        self.gh.logs[(29, None)] = "RELEASE_BUILD_NUMBER: 160"
        self.gh.values["actions/runs/29"]["conclusion"] = "failure"
        with self.assertRaises(release.Blocked):
            self.prepare()

    def test_baseline_log_is_read_once_per_invocation_and_index_is_rechecked(self):
        cache = {}
        release.check_duplicates(self.gh, "165", cache)
        release.check_duplicates(self.gh, "165", cache)
        self.assertEqual(self.gh.requests.count(("LOG", 29, None)), 1)
        self.assertEqual(self.gh.requests.count(("GET", release.recent_runs_path(1))), 2)

    def test_dispatch_rechecks_main_and_duplicate_index(self):
        args = ["--sha", self.sha, "--build-number", "165", "--main-ci-run", "20", "--dispatch"]
        for guard in ("check_checkout", "check_duplicates"):
            original = getattr(release, guard)
            calls = 0

            def race(*values):
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise release.Blocked("State changed before dispatch")
                return original(*values)

            with patch.object(release, "GitHub", return_value=self.gh), patch.object(release, guard, side_effect=race), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(release.main(args), 1)
            self.assertEqual(self.gh.dispatches, [])

    def test_dispatch_transport_is_one_structured_post_and_never_retries(self):
        with patch.object(release, "command", return_value="") as command:
            release.GitHub().dispatch({"expected_main_sha": self.sha, "build_number": "165"})
        self.assertEqual(command.call_count, 1)
        argv = command.call_args.args[0]
        self.assertIn("POST", argv)
        self.assertEqual(json.loads(command.call_args.kwargs["input_text"])["ref"], "main")
        self.assertNotIn("--rerun", argv)
        with patch.object(release, "command", side_effect=release.Blocked("Lost response")) as command:
            with self.assertRaises(release.Blocked):
                release.GitHub().dispatch({})
        self.assertEqual(command.call_count, 1)

    @unittest.skipUnless(shutil.which("gh"), "GitHub CLI is not installed")
    def test_log_arguments_are_accepted_by_the_installed_cli_without_network(self):
        for job in (None, 2):
            with patch.object(release, "command", return_value="") as capture:
                release.GitHub().log(1, job)
            # --help parses the actual command flags without fetching any run.
            result = subprocess.run(capture.call_args.args[0] + ["--help"],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_command_errors_do_not_echo_private_payloads(self):
        failed = subprocess.CompletedProcess(["gh"], 1, stdout="PRIVATE DATA", stderr="SECRET TOKEN")
        with patch.object(release.subprocess, "run", return_value=failed):
            with self.assertRaises(release.Blocked) as error:
                release.command(["gh", "api"])
        self.assertNotIn("PRIVATE", str(error.exception))
        self.assertNotIn("SECRET", str(error.exception))

    def test_workflow_checks_expected_commit_before_signing_and_names_build(self):
        source = (release.ROOT / ".github/workflows/testflight.yml").read_text(encoding="utf-8")
        self.assertIn('run-name: "TestFlight build ' + '$' + '{{ inputs.build_number || github.run_number }} @ '
                      + '$' + '{{ inputs.expected_main_sha || github.sha }}"', source)
        self.assertIn("EXPECTED_MAIN_SHA: " + "$" + "{{ inputs.expected_main_sha }}", source)
        self.assertIn('ref: ${{ inputs.expected_main_sha || github.sha }}', source)
        self.assertIn('git merge-base --is-ancestor "$EXPECTED_MAIN_SHA" origin/main', source)
        self.assertIn('[[ "$(git rev-parse HEAD)" != "$EXPECTED_MAIN_SHA" ]]', source)
        self.assertNotIn('--source-commit "$GITHUB_SHA"', source)
        self.assertIn('--source-commit "$RELEASE_SOURCE_SHA"', source)
        self.assertLess(source.index("Verify the requested main commit"), source.index("Install distribution certificate"))


class ModerationProductionUIRecoveryReleaseTests(unittest.TestCase):
    def test_full_native_release_requires_explicit_shipping_proof_and_original_backend_sha(self):
        fixture = ReleaseTests(); fixture.setUp(); self.addCleanup(fixture.doCleanups)
        planner = release.planner
        fixture.run.update(head_branch=planner.MODERATION_BUILD_CORRECTION_BRANCH, path=".github/workflows/ios-build.yml", run_attempt=1)
        fixture.plan.update(scope=planner.MODERATION_RESOLUTION_SCOPE,
            required_jobs=list(planner.required_jobs_from_scope(planner.MODERATION_RESOLUTION_SCOPE)),
            required_backend_runs=planner.moderation_resolution_requirements(planner.MODERATION_BUILD_CORRECTION_SOURCE))
        fixture.set_plan()
        proof = {"kind": "moderation-production-ui-recovery-v1", "native_success_reused": False,
                 "backend_evidence": {"source_sha": planner.MODERATION_BUILD_CORRECTION_SOURCE}}
        with patch.object(planner, "moderation_ui_recovery_inputs", return_value=True), \
                patch.object(planner, "covers_moderation_ui_recovery", return_value=True) as verify, \
                patch.object(planner, "moderation_ui_recovery_evidence", return_value=proof), \
                patch.object(planner, "moderation_resolution_backend_evidence", side_effect=AssertionError("must use bounded source proof")):
            result = release.check_ci(fixture.gh, fixture.sha, 20, fixture.now)
            self.assertEqual(result["production_ui_recovery"], proof)
            self.assertEqual(result["tested_sha"], fixture.sha)
            self.assertEqual(verify.call_args.args[1], fixture.sha)
        with patch.object(planner, "moderation_ui_recovery_inputs", return_value=True), \
                patch.object(planner, "covers_moderation_ui_recovery", return_value=False), self.assertRaises(release.Blocked):
            release.check_ci(fixture.gh, fixture.sha, 20, fixture.now)
        key = "actions/runs/20/jobs?filter=latest&per_page=100&page=1"
        fixture.gh.values[key]["jobs"][1]["conclusion"] = "skipped"
        with self.assertRaises(release.Blocked): release.check_ci(fixture.gh, fixture.sha, 20, fixture.now)
        self.assertEqual(fixture.gh.dispatches, [])


class ModerationBuildCorrectionReleaseTests(unittest.TestCase):
    def test_direct_release_requires_fixed_full_build_graph_and_reports_original_backend_sha(self):
        fixture = ReleaseTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        planner = release.planner
        fixture.run.update(head_branch=planner.MODERATION_BUILD_CORRECTION_BRANCH,
                           path=".github/workflows/ios-build.yml", run_attempt=1)
        fixture.plan.update(scope=planner.MODERATION_RESOLUTION_SCOPE,
            required_jobs=list(planner.required_jobs_from_scope(planner.MODERATION_RESOLUTION_SCOPE)),
            required_backend_runs=planner.moderation_resolution_requirements(planner.MODERATION_BUILD_CORRECTION_SOURCE),
            test_correction_evidence={"run_id": planner.MODERATION_BUILD_CORRECTION_RUN,
                "sha": planner.MODERATION_BUILD_CORRECTION_SOURCE,
                "backend_evidence": {"source_sha": planner.MODERATION_BUILD_CORRECTION_SOURCE}})
        fixture.set_plan()
        with patch.object(planner, "covers_moderation_build_correction", return_value=True) as verify:
            result = release.check_ci(fixture.gh, fixture.sha, 20, fixture.now)
            self.assertEqual(result["tested_sha"], fixture.sha)
            self.assertEqual(result["reused_sha"], planner.MODERATION_BUILD_CORRECTION_SOURCE)
            self.assertEqual(result["backend_evidence"]["source_sha"], planner.MODERATION_BUILD_CORRECTION_SOURCE)
            self.assertEqual(verify.call_args.args[1], fixture.sha)
        for value in (False, None):
            with patch.object(planner, "covers_moderation_build_correction", return_value=value), self.assertRaises(release.Blocked):
                release.check_ci(fixture.gh, fixture.sha, 20, fixture.now)
        with patch.object(planner, "covers_moderation_build_correction", side_effect=planner.CorrectionEvidenceUnavailable()), self.assertRaises(release.Blocked):
            release.check_ci(fixture.gh, fixture.sha, 20, fixture.now)
        self.assertEqual(fixture.gh.dispatches, [])


class PreservationExportCorrectionTests(unittest.TestCase):
    set_plan = ReleaseTests.set_plan
    set_export_backends = ReleaseTests.set_export_backends
    export_plan = ReleaseTests.export_plan
    prepare = ReleaseTests.prepare

    def transcript(self, failures=frozenset()):
        lines = []
        for test in release.planner.PRESERVATION_EXPORT_TESTS:
            case = test.removeprefix("NekoWidgetUITests/")
            label = "NekoWidgetUITests." + case.replace("/", " ")
            lines += [f"Test Case '-[{label}]' started.",
                      f"Test Case '-[{label}]' {'failed' if case in failures else 'passed'} (1 seconds)."]
        return "\n".join(lines)

    def setUp(self):
        ReleaseTests.setUp(self)
        planner = release.planner
        self.export_plan()
        self.run.update(head_branch=planner.PRESERVATION_EXPORT_CORRECTION_BRANCH,
                        path=".github/workflows/ios-build.yml", run_attempt=1)
        self.source = dict(self.run, id=planner.PRESERVATION_EXPORT_CORRECTION_RUN,
                           head_sha=planner.PRESERVATION_EXPORT_CORRECTION_SOURCE, conclusion="failure")
        self.source_sha, self.source_id = self.source["head_sha"], self.source["id"]
        self.required = tuple(self.plan["required_jobs"])
        self.ui_name = planner.lane_job(planner.PRESERVATION_EXPORT_SCOPE, "app-ui")
        self.ui_id = planner.PRESERVATION_EXPORT_SOURCE_JOB_IDS[self.ui_name]
        self.source_jobs = []
        for name, job_id in planner.PRESERVATION_EXPORT_SOURCE_JOB_IDS.items():
            job = dict(self.plan_job, id=job_id, name=name, run_id=self.source_id,
                       run_attempt=1, head_sha=self.source_sha, steps=[])
            if name == self.ui_name:
                job.update(conclusion="failure", steps=[{"name": "Run sharing runtime matrix",
                            "status": "completed", "conclusion": "failure"}])
            self.source_jobs.append(job)
        self.source_jobs += [dict(self.plan_job, id=job_id, name=planner.UNEXPANDED_SHARING_JOB,
            run_id=self.source_id, run_attempt=1, head_sha=self.source_sha, conclusion="skipped", steps=[])
            for job_id in planner.PRESERVATION_EXPORT_SKIPPED_JOB_IDS]
        self.source_jobs_key = f"actions/runs/{self.source_id}/jobs?filter=latest&per_page=100&page=1"
        self.gh.values[f"actions/runs/{self.source_id}"] = self.source
        self.gh.values[self.source_jobs_key] = {"total_count": len(self.source_jobs), "jobs": self.source_jobs}
        self.source_plan_id = planner.PRESERVATION_EXPORT_SOURCE_JOB_IDS[planner.PLAN_JOB]
        self.gh.logs[(self.source_id, self.source_plan_id)] = release.PLAN_MARKER + json.dumps(self.plan | {"head_sha": self.source_sha})
        self.gh.logs[(self.source_id, self.ui_id)] = self.transcript(planner.PRESERVATION_EXPORT_CORRECTION_CASES)
        for job in self.source_jobs:
            self.gh.values[f"actions/jobs/{job['id']}"] = job
        # Preserve actual same-source backend proof, including the reviewed
        # Sharing dispatch when its push index is entirely absent.
        self.source_backend_keys = []
        for index, key in enumerate(self.backend_indexes):
            target = key.replace(self.sha, self.source_sha)
            value = copy.deepcopy(self.gh.values[key])
            value["workflow_runs"][0]["head_sha"] = self.source_sha
            if index == 1:
                self.gh.values[target] = {"total_count": 0, "workflow_runs": []}
                target = target.replace("event=push", "event=workflow_dispatch")
                value["workflow_runs"][0]["event"] = "workflow_dispatch"
            self.gh.values[target] = value
            self.source_backend_keys.append(target)
            for job in self.gh.values[self.backend_job_indexes[index]]["jobs"]:
                job["head_sha"] = self.source_sha
        inputs = patch.object(planner, "preservation_export_correction_inputs", return_value=True)
        inputs.start(); self.addCleanup(inputs.stop)
        self.correction = planner.correction_source(self.source, self.sha, self.run["head_branch"],
            release.REPOSITORY, 5, self.required, self.api, self.now)
        self.assertIsNotNone(self.correction)
        self.plan["test_correction_evidence"] = self.correction
        self.set_plan()
        self.current_jobs_key = "actions/runs/20/jobs?filter=latest&per_page=100&page=1"
        # Names and seven-job shape observed on corrected run 37772225394:
        # plan + app-ui execute; Build, Photos and three matrices are skips.
        current_jobs = [job for job in self.gh.values[self.current_jobs_key]["jobs"]
                        if job["name"] in {planner.PLAN_JOB, self.ui_name}]
        current_jobs += [dict(self.plan_job, id=job_id, name=name, conclusion="skipped") for job_id, name in (
            (113294537928, "needs.plan.outputs.build_name"),
            (113294538165, "needs.plan.outputs.smoke_name"),
            (113294538596, planner.UNEXPANDED_SHARING_JOB),
            (113294538768, planner.UNEXPANDED_SHARING_JOB),
            (113294539255, planner.UNEXPANDED_SHARING_JOB),
        )]
        self.gh.values[self.current_jobs_key] = {"total_count": 7, "jobs": current_jobs}
        for job in current_jobs:
            job.update(run_id=20, run_attempt=1, steps=[])
            self.gh.values[f"actions/jobs/{job['id']}"] = job
            if job["name"] == self.ui_name:
                self.current_ui_id = job["id"]
                self.gh.logs[(20, job["id"])] = self.transcript()

    def api(self, path):
        prefix = f"/repos/{release.REPOSITORY}/"
        self.assertTrue(path.startswith(prefix))
        local = path[len(prefix):]
        if local.endswith("/logs"):
            job_id = int(local.split("/")[-2])
            return self.gh.log(self.gh.get(f"actions/jobs/{job_id}")["run_id"], job_id)
        return self.gh.get(local)

    def test_candidate_release_and_main_reuse_preserve_original_three_jobs_and_backends(self):
        result = self.prepare()["ci"]
        self.assertEqual(result["reused_sha"], self.source_sha)
        self.assertEqual(result["tested_sha"], self.sha)
        self.assertEqual(result["backend_evidence"]["sharing-service.yml"]["sha"], self.source_sha)
        self.assertEqual(result["backend_evidence"]["sharing-service.yml"]["event"], "workflow_dispatch")
        main = dict(self.run, id=21, head_branch="main")
        self.gh.values["actions/runs/21"] = main
        plan_job = dict(self.plan_job, id=301, run_id=21, run_attempt=1)
        self.gh.values["actions/runs/21/jobs?filter=latest&per_page=100&page=1"] = {"total_count": 1, "jobs": [plan_job]}
        main_plan = self.plan | {"test_correction_evidence": None, "evidence_run_id": 20, "evidence_sha": self.sha}
        self.gh.logs[(21, 301)] = release.PLAN_MARKER + json.dumps(main_plan)
        def api(path):
            if "/workflows/ios-build.yml/runs?" in path:
                return {"workflow_runs": [self.run]}
            return self.api(path)
        env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/main", "GITHUB_SHA": self.sha,
               "GITHUB_REPOSITORY": release.REPOSITORY, "GITHUB_RUN_ID": "21"}
        with patch.object(release.planner, "git", return_value=self.sha):
            self.assertEqual(release.planner.find_evidence(env, self.required, api, self.now), (20, self.sha))
        result = release.check_ci(self.gh, self.sha, 21, self.now)
        self.assertEqual(result["tested_run"], 20)
        self.assertEqual(result["backend_evidence"]["preservation-service.yml"]["sha"], self.source_sha)
        self.assertEqual(self.gh.dispatches, [])

    def test_candidate_planner_executes_only_the_complete_owning_ui_lane(self):
        from ios_ci_scope import lane_tests
        planner = release.planner
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "event.json").write_text("{}")
            env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/" + self.run["head_branch"],
                   "GITHUB_SHA": self.sha, "GITHUB_REPOSITORY": release.REPOSITORY, "GITHUB_RUN_ID": "20",
                   "GITHUB_WORKFLOW": "iOS build check", "GITHUB_SERVER_URL": "https://github.com",
                   "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                   "GITHUB_STEP_SUMMARY": str(root / "summary")}
            output = io.StringIO()
            with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                    patch.object(planner, "changed_paths", return_value=list(planner.PRESERVATION_EXPORT_PATHS)), \
                    patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_EXPORT_SCOPE), \
                    patch.object(planner, "github_api", side_effect=lambda env, path: self.api(path)):
                planner.main()
            flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
            self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")],
                             ["false", "false", "false", "true"])
            self.assertEqual(flags["app_ui_lanes"], '["app-ui"]')
            record = planner.preservation_export_plan(output.getvalue(), self.sha, self.required)
            self.assertEqual(record["test_correction_evidence"], self.correction)
            self.assertEqual(lane_tests(planner.PRESERVATION_EXPORT_SCOPE, "app-ui"),
                             planner.PRESERVATION_EXPORT_TESTS)

    def test_source_identity_full_graph_only_known_failures_and_fresh_successes_are_required(self):
        planner = release.planner
        for key, value in (("id", 99), ("head_sha", "b" * 40), ("head_branch", "codex/other"),
                           ("event", "workflow_dispatch"), ("path", ".github/workflows/other.yml"),
                           ("run_attempt", 2), ("conclusion", "success"), ("workflow_id", 9),
                           ("repository", {"full_name": "other/repo"}),
                           ("head_repository", {"full_name": "other/repo"})):
            with self.subTest(field=key):
                self.gh.values[f"actions/runs/{self.source_id}"] = self.source | {key: value}
                with self.assertRaises(release.Blocked): self.prepare()
        self.gh.values[f"actions/runs/{self.source_id}"] = self.source
        original = copy.deepcopy(self.source_jobs)
        for index, job in enumerate(original):
            mutations = [{"head_sha": "b" * 40}, {"id": 1}, {"conclusion": "skipped"}]
            if job["conclusion"] == "success":
                mutations += [{"completed_at": (self.now-dt.timedelta(hours=25)).isoformat()}]
            for mutation in mutations:
                changed = copy.deepcopy(original); changed[index].update(mutation)
                if changed == original: continue
                self.gh.values[self.source_jobs_key] = {"total_count": len(changed), "jobs": changed}
                with self.subTest(job=job["id"], mutation=mutation), self.assertRaises(release.Blocked): self.prepare()
        self.gh.values[self.source_jobs_key] = {"total_count": len(original), "jobs": original}
        self.gh.values[self.source_jobs_key] = {"total_count": len(original), "jobs": original[:-1]}
        with self.assertRaises(release.Blocked): self.prepare()
        self.gh.values[self.source_jobs_key] = {"total_count": len(original), "jobs": original}
        plan_key = (self.source_id, self.source_plan_id)
        saved = self.gh.logs[plan_key]
        for invalid in (self.plan | {"head_sha": self.source_sha, "required_jobs": [planner.BUILD]},
                        self.plan | {"head_sha": self.source_sha, "evidence_run_id": 99}):
            self.gh.logs[plan_key] = release.PLAN_MARKER + json.dumps(invalid)
            with self.assertRaises(release.Blocked): self.prepare()
        self.gh.logs[plan_key] = saved
        saved = self.gh.logs[(self.source_id, self.ui_id)]
        for log in (saved + "\nTest Case '-[NekoWidgetUITests.SoloMemoriesUITests testUnknown]' failed (1 seconds).",
                    self.transcript(), saved.replace("failed", "skipped"), saved + saved):
            self.gh.logs[(self.source_id, self.ui_id)] = log
            with self.assertRaises(release.Blocked): self.prepare()
        self.gh.logs[(self.source_id, self.ui_id)] = saved
        for key in self.source_backend_keys:
            saved = self.gh.values[key]
            self.gh.values[key] = {"total_count": 0, "workflow_runs": []}
            with self.assertRaises(release.Blocked): self.prepare()
            self.gh.values[key] = saved
        with patch.object(planner, "preservation_export_correction_inputs", return_value=False):
            with self.assertRaises(release.Blocked): self.prepare()

    def test_corrected_ui_must_execute_all_four_and_never_replace_skips_or_failures(self):
        key = (20, self.current_ui_id)
        saved = self.gh.logs[key]
        for log in ("", saved.replace("passed", "skipped", 1), saved.replace("passed", "failed", 1),
                    "\n".join(saved.splitlines()[2:]), saved + saved):
            self.gh.logs[key] = log
            with self.assertRaises(release.Blocked): self.prepare()
        self.gh.logs[key] = saved
        original = copy.deepcopy(self.gh.values[self.current_jobs_key])
        for index in range(len(original["jobs"])):
            changed = copy.deepcopy(original)
            changed["jobs"][index]["conclusion"] = "failure"
            self.gh.values[self.current_jobs_key] = changed
            with self.assertRaises(release.Blocked): self.prepare()
        self.gh.values[self.current_jobs_key] = original

    def test_unexpanded_workflow_names_are_only_empty_skips_and_never_success_evidence(self):
        original = copy.deepcopy(self.gh.values[self.current_jobs_key])
        self.assertEqual(original["total_count"], 7)
        self.assertEqual(sum(job["conclusion"] == "skipped" for job in original["jobs"]), 5)
        self.prepare()
        for index, job in enumerate(original["jobs"]):
            if job["conclusion"] != "skipped": continue
            for mutation in ({"conclusion": "success"}, {"conclusion": "failure"}, {"conclusion": "cancelled"},
                             {"status": "in_progress"}, {"steps": [{"conclusion": "success"}]}, {"steps": None},
                             {"name": "needs.plan.outputs.other_name"}):
                changed = copy.deepcopy(original); changed["jobs"][index].update(mutation)
                self.gh.values[self.current_jobs_key] = changed
                with self.subTest(job=job["id"], mutation=mutation), self.assertRaises(release.Blocked):
                    self.prepare()
        self.gh.values[self.current_jobs_key] = original
        # A placeholder cannot stand in for actual successful source Build.
        source = copy.deepcopy(self.gh.values[self.source_jobs_key])
        next(job for job in source["jobs"] if job["name"] == release.planner.BUILD).update(
            name="needs.plan.outputs.build_name", conclusion="skipped", steps=[])
        self.gh.values[self.source_jobs_key] = source
        with self.assertRaises(release.Blocked): self.prepare()


if __name__ == "__main__":
    unittest.main()
