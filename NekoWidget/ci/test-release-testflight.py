#!/usr/bin/env python3
"""Release preflight/dispatch boundaries. All GitHub operations are mocks."""

import contextlib
import copy
import datetime as dt
import importlib.util
import io
import json
from pathlib import Path
import subprocess
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
        self.gh.values["actions/runs/20/jobs?filter=latest&per_page=100"] = {"total_count": len(jobs), "jobs": jobs}

    def prepare(self, build="165", sha=None):
        return release.prepare(self.gh, sha or self.sha, build, 20, self.now, {})

    def candidate(self):
        self.plan.update(evidence_run_id=10, evidence_sha=self.sha)
        self.set_plan()
        self.gh.values["actions/runs/10"] = dict(self.run, id=10, head_branch="codex/candidate")
        self.gh.values["actions/runs/10/jobs?filter=latest&per_page=100"] = copy.deepcopy(
            self.gh.values["actions/runs/20/jobs?filter=latest&per_page=100"])
        for job in self.gh.values["actions/runs/20/jobs?filter=latest&per_page=100"]["jobs"][1:]:
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
                self.set_plan()
                self.assertEqual(self.prepare()["ci"]["scope"], scope)

    def test_skipped_main_jobs_require_real_referenced_candidate_jobs(self):
        self.candidate()
        self.assertEqual(self.prepare()["ci"]["tested_run"], 10)
        self.gh.values["actions/runs/10/jobs?filter=latest&per_page=100"]["jobs"][1]["conclusion"] = "skipped"
        with self.assertRaises(release.Blocked):
            self.prepare()

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
        for key, value in [("head_sha", "b" * 40), ("head_branch", "codex/candidate"),
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
            result = self.gh.values["actions/runs/20/jobs?filter=latest&per_page=100"]
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
        jobs = copy.deepcopy(self.gh.values["actions/runs/10/jobs?filter=latest&per_page=100"]["jobs"])
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
        jobs = copy.deepcopy(self.gh.values["actions/runs/20/jobs?filter=latest&per_page=100"]["jobs"])
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
        jobs = copy.deepcopy(self.gh.values["actions/runs/10/jobs?filter=latest&per_page=100"]["jobs"])
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
        with self.assertRaises(release.Blocked):
            self.prepare()

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

    def test_title_sha_must_match_run(self):
        self.previous["display_title"] = "TestFlight build 164 @ " + "b" * 40
        with self.assertRaises(release.Blocked):
            self.prepare()

    def test_legacy_failure_is_not_proof_of_no_upload(self):
        self.previous.update(display_title="old title", conclusion="failure")
        step = {"name": "Validate and upload IPA to TestFlight", "status": "completed", "conclusion": "failure"}
        self.gh.values["actions/runs/30/jobs?filter=latest&per_page=100"] = {
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
                      + '$' + '{{ github.sha }}"', source)
        self.assertIn("EXPECTED_MAIN_SHA: " + "$" + "{{ inputs.expected_main_sha }}", source)
        self.assertIn('[[ "$GITHUB_SHA" != "$EXPECTED_MAIN_SHA" ]]', source)
        self.assertIn('[[ "$(git rev-parse HEAD)" != "$EXPECTED_MAIN_SHA" ]]', source)
        self.assertLess(source.index("Verify the requested main commit"), source.index("Install distribution certificate"))


if __name__ == "__main__":
    unittest.main()
