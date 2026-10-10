#!/usr/bin/env python3
"""Behavioral coverage for selecting and reusing iOS checks (no network)."""

import copy
import contextlib
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


class ModerationBuildCorrectionTests(unittest.TestCase):
    def setUp(self):
        self.source, self.head = planner.MODERATION_BUILD_CORRECTION_SOURCE, planner.MODERATION_BUILD_CORRECTION_PRODUCT
        self.now = dt.datetime(2026, 10, 9, 16, tzinfo=dt.timezone.utc)
        self.repo = "soso-so-27/neko-widget"
        self.required = planner.required_jobs_from_scope(planner.MODERATION_RESOLUTION_SCOPE)
        self.run = {"id": planner.MODERATION_BUILD_CORRECTION_RUN, "head_sha": self.source,
            "head_branch": planner.MODERATION_BUILD_CORRECTION_BRANCH, "workflow_id": 335014238,
            "path": ".github/workflows/ios-build.yml", "event": "push", "run_attempt": 1,
            "repository": {"full_name": self.repo}, "head_repository": {"full_name": self.repo},
            "status": "completed", "conclusion": "failure", "updated_at": self.now.isoformat()}
        self.build_steps = ("Check out repository", "Verify Xcode installation", "Verify sharing release privacy gates",
                            planner.MODERATION_BUILD_FAILED_STEP, "Verify Swift pairing protocol vectors",
                            "Build disabled app and extensions for iOS Simulator")
        self.jobs = []
        for name, job_id in planner.MODERATION_BUILD_SOURCE_JOBS.items():
            names = self.build_steps if name == planner.BUILD else ("Select checks",) if name == planner.PLAN_JOB else ("Run Simulator smoke test",) if name == planner.BOOTSTRAP_SMOKE else ("Run sharing runtime matrix",)
            steps = [{"name": step, "status": "completed", "conclusion": "success"} for step in names]
            if name == planner.BUILD:
                for n in range(3, len(steps)): steps[n]["conclusion"] = "failure" if n == 3 else "skipped"
            self.jobs.append({"id": job_id, "name": name, "head_sha": self.source,
                "run_id": self.run["id"], "run_attempt": 1, "status": "completed",
                "conclusion": "failure" if name == planner.BUILD else "success",
                "completed_at": self.now.isoformat(), "steps": steps})
        self.record = {"repository": self.repo, "schema_version": 1, "head_sha": self.source,
            "scope": planner.MODERATION_RESOLUTION_SCOPE, "required_jobs": list(self.required),
            "required_backend_runs": planner.moderation_resolution_requirements(self.source),
            "evidence_run_id": None, "evidence_sha": None, "test_correction_evidence": None}
        self.failure = ("FAIL: test_source_does_not_advance_expiry_boundary (__main__.WindowPresentation.test_source_does_not_advance_expiry_boundary)\n"
            "AssertionError: 'func isVisible(at now: Date) -> Bool { now < displayUntil }' not found\nRan 9 tests in 4.217s\nFAILED (failures=1)")
        self.backends = {name: {"run_id": identifier, "sha": self.source} for name, identifier in
            (("sharing-service.yml", 37944559756), ("preservation-service.yml", 37944559715))}

    def api(self, path):
        if path.endswith(f"/{self.run['id']}"): return self.run
        if "/jobs?" in path: return {"total_count": len(self.jobs), "jobs": self.jobs}
        if path.endswith(f"/{planner.MODERATION_BUILD_SOURCE_JOBS[planner.PLAN_JOB]}/logs"):
            return "IOS_CI_PLAN_JSON=" + json.dumps(self.record)
        if path.endswith(f"/{planner.MODERATION_BUILD_SOURCE_JOBS[planner.BUILD]}/logs"): return self.failure
        raise AssertionError(path)

    def verify(self, run=None):
        with patch.object(planner, "moderation_build_correction_inputs", return_value=True), \
                patch.object(planner, "moderation_build_steps", return_value=self.build_steps), \
                patch.object(planner, "moderation_resolution_backend_evidence", return_value=self.backends), \
                patch.object(planner, "moderation_build_candidate_backend_gate"):
            return planner.moderation_build_correction_source(run or self.run, self.head, self.run["head_branch"],
                self.repo, 335014238, self.required, self.api, self.now)

    def test_source_requires_actual_three_native_successes_and_only_known_build_failure(self):
        proof = self.verify()
        self.assertEqual(len(proof["jobs"]), 3)
        self.assertEqual(proof["owning_jobs_to_execute"], [planner.BUILD])
        self.assertEqual(planner.correction_owning_jobs(planner.MODERATION_RESOLUTION_SCOPE, self.source), (planner.BUILD,))
        for field, value in (("status", "in_progress"), ("conclusion", "success"), ("event", "workflow_dispatch"),
                ("head_sha", "f" * 40), ("run_attempt", 2), ("head_branch", "main"), ("workflow_id", 2),
                ("updated_at", "2020-01-01T00:00:00Z"), ("head_repository", {"full_name": "other/repo"})):
            with self.subTest(field=field): self.assertIsNone(self.verify(self.run | {field: value}))
        original = copy.deepcopy(self.jobs)
        for index, job in enumerate(original):
            for field, value in (("status", "in_progress"), ("conclusion", "skipped"), ("head_sha", "e" * 40),
                                 ("run_attempt", 2), ("id", 2), ("completed_at", "2020-01-01T00:00:00Z")):
                if job["name"] == planner.BUILD and field == "completed_at": continue
                self.jobs = copy.deepcopy(original); self.jobs[index][field] = value
                with self.subTest(job=job["name"], field=field): self.assertIsNone(self.verify())
            self.jobs = copy.deepcopy(original); self.jobs[index]["steps"] = []
            self.assertIsNone(self.verify())
        self.jobs = original + [copy.deepcopy(original[0])]; self.assertIsNone(self.verify())
        self.jobs = original
        failure = self.failure
        for invalid in (failure + "\nERROR: another", failure.replace("failures=1", "failures=2"), "", failure.replace("test_source_does_not", "test_other")):
            self.failure = invalid; self.assertIsNone(self.verify())
        self.failure = failure
        self.record["test_correction_evidence"] = {"run_id": 1}; self.assertIsNone(self.verify())

    def test_input_closure_fixed_pair_approved_controls_and_normal_handoffs_only(self):
        before, after = planner.MODERATION_BUILD_CORRECTION_BLOBS
        row = f":100644 100644 {before} {after} M\0{planner.MODERATION_RESOLUTION_BUILD_TEST}\0"
        def check(raw=row, *, unapproved=None, registered=True, ancestor=True):
            def git(*args):
                if args[0] == "diff": return raw
                if args[:2] == ("merge-base", "--is-ancestor") and not ancestor: raise subprocess.CalledProcessError(1, "git")
                if args[0] == "merge-base": return "a" * 40
                if args[0] == "show": return f'MODERATION_BUILD_CORRECTION_SOURCE = "{self.source}"' if registered else "old"
                if args[0] == "ls-tree":
                    return f"100644 blob {'d' * 40 if args[1] == self.head and args[3] == unapproved else 'c' * 40}\t{args[3]}"
                raise AssertionError(args)
            with patch.object(planner, "git", side_effect=git): return planner.moderation_build_correction_inputs(self.source, self.head)
        self.assertTrue(check())
        for path in planner.MODERATION_BUILD_CORRECTION_CONTROLS:
            self.assertTrue(check(row + f":100644 100644 {'b' * 40} {'c' * 40} M\0{path}\0"))
            self.assertFalse(check(unapproved=path))
        self.assertTrue(check(row + f":000000 100644 {'0' * 40} {'c' * 40} A\0handoffs/review.md\0"))
        for invalid in ("", row + row, row.replace(before, "d" * 40), row.replace(after, "c" * 40),
                row.replace("100644", "100755"), row.replace("100644", "120000"), row.replace(" M\0", " D\0"),
                row + f":100644 100644 {'b' * 40} {'c' * 40} M\0.gitattributes\0",
                row + f":100644 100644 {'b' * 40} {'c' * 40} M\0.github/workflows/ios-build.yml\0"):
            self.assertFalse(check(invalid), invalid)
        self.assertFalse(check(registered=False)); self.assertFalse(check(ancestor=False))

    def test_candidate_backend_absence_allowed_failure_active_and_wrong_identity_block(self):
        identity = {"id": 8, "state": "active", "path": ".github/workflows/sharing-service.yml"}
        candidate = self.run | {"id": 88, "head_sha": self.head, "conclusion": "success", "workflow_id": 8, "path": identity["path"]}
        def check(rows, count=None):
            def api(path):
                workflow = path.split("/workflows/", 1)[1].split("/", 1)[0]
                if "/runs?" not in path: return identity | {"path": ".github/workflows/" + workflow}
                return {"total_count": len(rows) if count is None else count,
                        "workflow_runs": [run | {"path": ".github/workflows/" + workflow} for run in rows]}
            return planner.moderation_build_candidate_backend_gate(self.head, self.repo, api, self.now)
        check([]); check([candidate])
        for field, value in (("status", "in_progress"), ("conclusion", "failure"), ("head_sha", self.source),
                             ("head_branch", "codex/other"), ("run_attempt", 2), ("workflow_id", 9)):
            with self.subTest(field=field), self.assertRaises(ValueError): check([candidate | {field: value}])
        with self.assertRaises(ValueError): check([], 1)
        with self.assertRaises(ValueError): check([candidate, candidate])

    def test_corrected_graph_requires_complete_new_build_and_revalidates_source(self):
        proof = self.verify()
        candidate = self.run | {"id": 123, "head_sha": self.head, "conclusion": "success"}
        jobs = [copy.deepcopy(job) for job in self.jobs if job["name"] in {planner.PLAN_JOB, planner.BUILD}]
        for job in jobs:
            job.update(id=job["id"] + 1000, head_sha=self.head, run_id=123, conclusion="success")
            for step in job["steps"]: step["conclusion"] = "success"
        record = self.record | {"head_sha": self.head, "test_correction_evidence": proof}
        def check(values=jobs, verified=proof):
            with patch.object(planner, "moderation_build_correction_inputs", return_value=True), \
                    patch.object(planner, "moderation_build_steps", return_value=self.build_steps), \
                    patch.object(planner, "moderation_build_correction_source", return_value=verified):
                return planner.covers_moderation_build_correction(candidate, self.head, self.required,
                    lambda path: "IOS_CI_PLAN_JSON=" + json.dumps(record) if path.endswith("/logs") else self.run, self.now, values)
        self.assertTrue(check())
        self.assertFalse(check(verified=None))
        for index, job in enumerate(jobs):
            for field, value in (("conclusion", "skipped"), ("steps", []), ("run_attempt", 2), ("head_sha", self.source)):
                invalid = copy.deepcopy(jobs); invalid[index][field] = value
                self.assertFalse(check(invalid))
            for n in range(len(job["steps"])):
                invalid = copy.deepcopy(jobs); invalid[index]["steps"][n]["conclusion"] = "skipped"
                self.assertFalse(check(invalid))
        self.assertFalse(check(jobs + [copy.deepcopy(jobs[0])]))
        skipped = jobs[0] | {"id": 1, "name": planner.UNEXPANDED_SHARING_JOB, "conclusion": "skipped", "steps": []}
        self.assertTrue(check(jobs + [skipped, skipped | {"id": 2}]))
        self.assertFalse(check(jobs + [skipped | {"conclusion": "failure"}]))

    def test_planner_runs_full_build_only_and_declares_original_backend_sha(self):
        proof = self.verify()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / "event").write_text("{}")
            env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/" + self.run["head_branch"],
                "GITHUB_SHA": self.head, "GITHUB_REPOSITORY": self.repo, "GITHUB_RUN_ID": "123",
                "GITHUB_WORKFLOW": "iOS build check", "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_EVENT_PATH": str(root / "event"), "GITHUB_OUTPUT": str(root / "output"), "GITHUB_STEP_SUMMARY": str(root / "summary")}
            output = io.StringIO()
            with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                    patch.object(planner, "changed_paths", return_value=list(scope.MODERATION_RESOLUTION_PATHS | {scope.MODERATION_RESOLUTION_BUILD_TEST})), \
                    patch.object(planner, "runtime_scope", return_value=scope.MODERATION_RESOLUTION_SCOPE), \
                    patch.object(planner, "find_evidence", return_value=None), \
                    patch.object(planner, "find_test_correction_evidence", return_value=proof), \
                    patch.object(planner, "moderation_build_correction_inputs", return_value=True):
                planner.main()
            flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
            self.assertEqual([flags[key] for key in ("build", "smoke", "sharing", "app_ui")], ["true", "false", "false", "false"])
            self.assertEqual(planner.moderation_build_plan(output.getvalue(), self.head, self.required)["test_correction_evidence"], proof)


class ModerationProductionUIRecoveryTests(unittest.TestCase):
    # Bounded lines from run37944559850, job113867584091: the earlier nine-test
    # success is real. Omit unrelated successful output and the huge Swift dump
    # after the exact AssertionError prefix; preserve the owning group/command.
    build_failure_slice = """2026-10-09T14:30:40.4139140Z Ran 9 tests in 0.037s
2026-10-09T14:30:40.4140680Z OK
2026-10-09T14:30:57.7451720Z ##[group]Run set -euo pipefail
2026-10-09T14:30:57.7452090Z \x1b[36;1mset -euo pipefail\x1b[0m
2026-10-09T14:30:57.7453130Z \x1b[36;1mcommand -v swift > /dev/null\x1b[0m
2026-10-09T14:30:57.7453580Z \x1b[36;1mpython3 ci/test-window-entry-and-cover-presentation.py\x1b[0m
2026-10-09T14:30:57.7567620Z shell: /bin/bash --noprofile --norc -e -o pipefail {0}
2026-10-09T14:30:57.7568270Z env:
2026-10-09T14:30:57.7568980Z   DEVELOPER_DIR: /Applications/Xcode_26.3.app/Contents/Developer
2026-10-09T14:30:57.7569480Z ##[endgroup]
2026-10-09T14:31:02.0904120Z FAIL: test_source_does_not_advance_expiry_boundary (__main__.WindowPresentation.test_source_does_not_advance_expiry_boundary)
2026-10-09T14:31:02.0960050Z AssertionError: 'func isVisible(at now: Date) -> Bool { now < displayUntil }' not found
2026-10-09T14:31:02.1001590Z Ran 9 tests in 4.217s
2026-10-09T14:31:02.1002360Z FAILED (failures=1)
2026-10-09T14:31:02.1102050Z ##[error]Process completed with exit code 1.
2026-10-09T14:31:02.1526510Z ##[group]Run actions/upload-artifact@b7c566a772e6b6bfb58ed0dc250532a479d7789f
"""

    def setUp(self):
        ModerationBuildCorrectionTests.setUp(self)
        self.failure = self.build_failure_slice
        self.head = planner.MODERATION_UI_RECOVERY_PRODUCT
        self.ui_name = planner.lane_job(planner.MODERATION_RESOLUTION_SCOPE, "app-ui")
        for job in self.jobs:
            if job["name"] == self.ui_name:
                job["conclusion"] = "failure"; job["steps"][0]["conclusion"] = "failure"
        self.jobs += [self.jobs[0] | {"id": job_id, "name": planner.UNEXPANDED_SHARING_JOB,
            "conclusion": "skipped", "steps": []} for job_id in planner.MODERATION_UI_SOURCE_SKIPS]
        self.ui_log = self.transcript({planner.MODERATION_UI_RECOVERY_CASE}) + '\n"header.closeButton" Button\nXCTAssertTrue failed'
        self.candidate_index = {"total_count": 0, "workflow_runs": []}

    def transcript(self, failures=frozenset()):
        lines = []
        for case in planner.MODERATION_RESOLUTION_TESTS:
            name = case.removeprefix("NekoWidgetUITests/"); label = "NekoWidgetUITests." + name.replace("/", " ")
            lines += [f"Test Case '-[{label}]' started.", f"Test Case '-[{label}]' {'failed' if name in failures else 'passed'} (1 seconds)."]
        return "\n".join(lines)

    def api(self, path):
        if path.endswith("/workflows/ios-build.yml"):
            return {"id": 335014238, "path": ".github/workflows/ios-build.yml", "state": "active"}
        if "/runs?head_sha=" + self.head in path: return self.candidate_index
        if path.endswith(f"/{planner.MODERATION_BUILD_SOURCE_JOBS[self.ui_name]}/logs"): return self.ui_log
        return ModerationBuildCorrectionTests.api(self, path)

    def prove(self):
        with patch.object(planner, "moderation_ui_recovery_inputs", return_value=True), \
                patch.object(planner, "moderation_build_steps", return_value=self.build_steps), \
                patch.object(planner, "moderation_resolution_backend_evidence", return_value=self.backends):
            return planner.moderation_ui_recovery_evidence(self.head, self.repo, self.api, self.now)

    def test_shipping_recovery_never_reuses_native_and_requires_both_specific_failures(self):
        proof = self.prove()
        self.assertFalse(proof["native_success_reused"])
        self.assertEqual(proof["required_native_jobs"], list(self.required))
        self.assertEqual(len(proof["historical_native_success_job_ids"]), 2)
        self.assertEqual(json.loads(json.dumps(proof)), proof)
        original = copy.deepcopy(self.jobs)
        for n, job in enumerate(original):
            for field, value in (("conclusion", "cancelled"), ("status", "in_progress"), ("head_sha", "f" * 40),
                    ("run_attempt", 2), ("id", 1), ("steps", [])):
                if field == "steps" and job["id"] in planner.MODERATION_UI_SOURCE_SKIPS: continue
                self.jobs = copy.deepcopy(original); self.jobs[n][field] = value
                with self.subTest(job=job["name"], field=field), self.assertRaises(ValueError): self.prove()
        self.jobs = original
        self.ui_log = self.transcript()
        with self.assertRaises(ValueError): self.prove()
        self.ui_log = self.transcript({planner.MODERATION_UI_RECOVERY_CASE, "OfficialWindowUITests/testWidgetURLsColdOpenPhotoBeforeSourceResolvesAndCloseOnce"})
        with self.assertRaises(ValueError): self.prove()

    def test_no_candidate_backend_push_may_be_hidden_even_success_or_incomplete_index(self):
        self.prove()
        for index in ({"total_count": 1, "workflow_runs": []}, {"total_count": 0, "workflow_runs": [{}]},
                {"total_count": 1, "workflow_runs": [{"conclusion": "success"}]},
                {"total_count": 1, "workflow_runs": [{"status": "in_progress"}]},
                {"total_count": 1, "workflow_runs": [{"conclusion": "failure"}]}):
            self.candidate_index = index
            with self.assertRaises(ValueError): self.prove()

    def test_build_failure_is_bounded_to_owning_command_and_rejects_unknown_or_ambiguous_output(self):
        log = self.build_failure_slice
        self.assertTrue(planner.moderation_ui_build_failure(log))
        self.assertEqual(len(re.findall(r"Ran 9 tests in", log)), 2)
        mutants = [log + "FAIL: another_failure\n", log + "ERROR: another_error\n",
            log + "FAILED (failures=2)\n", log + "##[error]Another error\n",
            log.replace("Ran 9 tests in 4.217s", "Ran 8 tests in 4.217s"),
            log.replace("Ran 9 tests in 4.217s", "Ran 9 tests in 4.217s\nRan 9 tests in 0.1s"),
            log.replace("##[group]Run set -euo pipefail", "Run set -euo pipefail"),
            log.replace("##[endgroup]", ""),
            log.replace("python3 ci/test-window-entry-and-cover-presentation.py", "python3 ci/another.py"),
            log.replace("python3 ci/test-window-entry-and-cover-presentation.py", "python3 ci/test-window-entry-and-cover-presentation.py\npython3 ci/another.py"),
            log.replace("##[group]Run actions/upload-artifact", "Run actions/upload-artifact"),
            log.replace("FAIL: test_source", "FAIL: unknown_source"),
            log.replace("FAILED (failures=1)", "OK"),
            log.replace("Ran 9 tests in 4.217s", "##[group]other\nRan 9 tests in 4.217s"),
            log + log]
        for invalid in mutants:
            with self.subTest(log=invalid[-150:]): self.assertFalse(planner.moderation_ui_build_failure(invalid))
        self.failure = mutants[4]
        with self.assertRaises(ValueError): self.prove()

    def test_exact_two_product_pairs_controls_modes_handoffs_and_registration(self):
        rows = {path: [":100644", "100644", *pair, "M"] for path, pair in planner.MODERATION_UI_RECOVERY_BLOBS.items()}
        def check(values=rows, *, unapproved=False, registered=True, ancestor=True):
            def git(*args):
                if args[0] == "diff": return "".join(" ".join(value) + "\0" + path + "\0" for path, value in values.items())
                if args[:2] == ("merge-base", "--is-ancestor") and not ancestor: raise subprocess.CalledProcessError(1, "git")
                if args[0] == "merge-base": return "a" * 40
                if args[0] == "show": return f'MODERATION_UI_RECOVERY_PRODUCT = "{self.head}"' if registered else "old"
                if args[0] == "ls-tree": return f"100644 blob {'c' * 40 if unapproved and args[1] == self.head else 'b' * 40}\t{args[3]}"
                raise AssertionError(args)
            with patch.object(planner, "git", side_effect=git): return planner.moderation_ui_recovery_inputs(self.head)
        self.assertTrue(check()); self.assertFalse(check(unapproved=True)); self.assertFalse(check(registered=False)); self.assertFalse(check(ancestor=False))
        for path in rows:
            self.assertFalse(check({k: v for k, v in rows.items() if k != path}))
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D")):
                invalid = copy.deepcopy(rows); invalid[path][index] = value; self.assertFalse(check(invalid))
        self.assertTrue(check(rows | {"handoffs/review.md": [":000000", "100644", "0" * 40, "b" * 40, "A"]}))
        self.assertFalse(check(rows | {"NekoWidget/Shared/Sharing/MomentSharingCore.swift": [":100644", "100644", "a" * 40, "b" * 40, "M"]}))

    def test_all_new_native_jobs_steps_and_all_eleven_ui_must_execute(self):
        proof = self.prove()
        run = self.run | {"id": 700, "head_sha": self.head, "conclusion": "success"}
        jobs = copy.deepcopy(self.jobs)
        for job in jobs:
            job.update(id=job["id"] + 1000, head_sha=self.head, run_id=700)
            if job["name"] != planner.UNEXPANDED_SHARING_JOB:
                job["conclusion"] = "success"
                for step in job["steps"]: step["conclusion"] = "success"
        record = self.record | {"head_sha": self.head, "production_ui_recovery": proof}
        def check(values=jobs, ui_log=None):
            def api(path):
                if path.endswith(f"/{planner.MODERATION_BUILD_SOURCE_JOBS[planner.PLAN_JOB] + 1000}/logs"):
                    return "IOS_CI_PLAN_JSON=" + json.dumps(record)
                return self.transcript() if ui_log is None else ui_log
            with patch.object(planner, "moderation_ui_recovery_inputs", return_value=True), \
                    patch.object(planner, "moderation_build_steps", return_value=self.build_steps), \
                    patch.object(planner, "moderation_ui_recovery_evidence", return_value=proof):
                return planner.covers_moderation_ui_recovery(run, self.head, self.required, api, self.now, values)
        self.assertTrue(check())
        for n, job in enumerate(jobs):
            if job["name"] == planner.UNEXPANDED_SHARING_JOB: continue
            for field, value in (("conclusion", "skipped"), ("steps", []), ("run_attempt", 2)):
                invalid = copy.deepcopy(jobs); invalid[n][field] = value; self.assertFalse(check(invalid))
            for step in range(len(job["steps"])):
                invalid = copy.deepcopy(jobs); invalid[n]["steps"][step]["conclusion"] = "skipped"; self.assertFalse(check(invalid))
        self.assertFalse(check(jobs + [jobs[0]])); self.assertFalse(check(ui_log=self.transcript({planner.MODERATION_UI_RECOVERY_CASE})))
        self.assertFalse(check(ui_log=self.transcript().replace(" passed ", " skipped ", 1)))

    def test_main_planner_runs_four_native_and_is_not_test_only_correction(self):
        proof = self.prove()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / "event").write_text("{}")
            env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/" + self.run["head_branch"],
                "GITHUB_SHA": self.head, "GITHUB_REPOSITORY": self.repo, "GITHUB_RUN_ID": "123",
                "GITHUB_WORKFLOW": "iOS build check", "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_EVENT_PATH": str(root / "event"), "GITHUB_OUTPUT": str(root / "output"), "GITHUB_STEP_SUMMARY": str(root / "summary")}
            output = io.StringIO()
            with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                    patch.object(planner, "changed_paths", return_value=list(scope.MODERATION_RESOLUTION_PATHS | set(planner.MODERATION_UI_RECOVERY_BLOBS))), \
                    patch.object(planner, "runtime_scope", return_value=scope.MODERATION_RESOLUTION_SCOPE), \
                    patch.object(planner, "find_evidence", return_value=None), \
                    patch.object(planner, "find_test_correction_evidence", side_effect=AssertionError("shipping change cannot use test-only route")), \
                    patch.object(planner, "moderation_ui_recovery_inputs", return_value=True), \
                    patch.object(planner, "moderation_ui_recovery_evidence", return_value=proof): planner.main()
            flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
            self.assertEqual([flags[key] for key in ("build", "smoke", "sharing", "app_ui")], ["true"] * 4)
            record = planner.moderation_build_plan(output.getvalue(), self.head, self.required)
            self.assertIsNone(record["test_correction_evidence"]); self.assertEqual(record["production_ui_recovery"], proof)


class ModerationChainedBuildRecoveryTests(unittest.TestCase):
    # Actual owning step from 37954929706/113903266969, including its prior
    # successful suites. No external artifact or network is needed for tests.
    failure_slice = '2026-10-09T15:55:12.0350720Z ##[group]Run set -euo pipefail\n2026-10-09T15:55:12.0351150Z \x1b[36;1mset -euo pipefail\x1b[0m\n2026-10-09T15:55:12.0351420Z \x1b[36;1mxcrun --sdk macosx swiftc \\\x1b[0m\n2026-10-09T15:55:12.0351780Z \x1b[36;1m  -parse-as-library \\\x1b[0m\n2026-10-09T15:55:12.0352120Z \x1b[36;1m  Shared/Routing/DeepLink.swift \\\x1b[0m\n2026-10-09T15:55:12.0352470Z \x1b[36;1m  NekoWidget/Views/MomentSharingPresentation.swift \\\x1b[0m\n2026-10-09T15:55:12.0352930Z \x1b[36;1m  ci/verify-moment-sharing-presentation.swift \\\x1b[0m\n2026-10-09T15:55:12.0353510Z \x1b[36;1m  -o "$RUNNER_TEMP/verify-moment-sharing-presentation"\x1b[0m\n2026-10-09T15:55:12.0354030Z \x1b[36;1m"$RUNNER_TEMP/verify-moment-sharing-presentation"\x1b[0m\n2026-10-09T15:55:12.0354630Z \x1b[36;1mxcrun --sdk macosx swiftc \\\x1b[0m\n2026-10-09T15:55:12.0355020Z \x1b[36;1m  -parse-as-library \\\x1b[0m\n2026-10-09T15:55:12.0355350Z \x1b[36;1m  Shared/Sharing/PairingCore.swift \\\x1b[0m\n2026-10-09T15:55:12.0355690Z \x1b[36;1m  NekoWidget/Views/PairingPresentation.swift \\\x1b[0m\n2026-10-09T15:55:12.0356240Z \x1b[36;1m  ci/verify-pairing-presentation.swift \\\x1b[0m\n2026-10-09T15:55:12.0356700Z \x1b[36;1m  -o "$RUNNER_TEMP/verify-pairing-presentation"\x1b[0m\n2026-10-09T15:55:12.0357140Z \x1b[36;1m"$RUNNER_TEMP/verify-pairing-presentation"\x1b[0m\n2026-10-09T15:55:12.0357470Z \x1b[36;1mxcrun --sdk macosx swiftc \\\x1b[0m\n2026-10-09T15:55:12.0357810Z \x1b[36;1m  -parse-as-library \\\x1b[0m\n2026-10-09T15:55:12.0358090Z \x1b[36;1m  Shared/Models/WidgetManifest.swift \\\x1b[0m\n2026-10-09T15:55:12.0358470Z \x1b[36;1m  Shared/Models/WidgetRenderPlan.swift \\\x1b[0m\n2026-10-09T15:55:12.0358910Z \x1b[36;1m  ci/verify-private-window-display-name.swift \\\x1b[0m\n2026-10-09T15:55:12.0359300Z \x1b[36;1m  -o "$RUNNER_TEMP/verify-private-window-display-name"\x1b[0m\n2026-10-09T15:55:12.0359800Z \x1b[36;1m"$RUNNER_TEMP/verify-private-window-display-name"\x1b[0m\n2026-10-09T15:55:12.0360220Z \x1b[36;1mpython3 ci/test-inactive-window-name-sync.py\x1b[0m\n2026-10-09T15:55:12.0360680Z \x1b[36;1mpython3 ci/test-family-window-widget-boundaries.py\x1b[0m\n2026-10-09T15:55:12.0361040Z \x1b[36;1mpython3 ci/test-private-window-cover.py\x1b[0m\n2026-10-09T15:55:12.0361490Z \x1b[36;1mgrep -Fq \'MomentSharingPresentation.swift in Sources\' \\\x1b[0m\n2026-10-09T15:55:12.0361860Z \x1b[36;1m  NekoWidget.xcodeproj/project.pbxproj\x1b[0m\n2026-10-09T15:55:12.0410260Z shell: /bin/bash --noprofile --norc -e -o pipefail {0}\n2026-10-09T15:55:12.0410660Z env:\n2026-10-09T15:55:12.0411220Z   DEVELOPER_DIR: /Applications/Xcode_26.3.app/Contents/Developer\n2026-10-09T15:55:12.0411680Z ##[endgroup]\n2026-10-09T15:55:14.9341660Z Moment sharing presentation verifier passed\n2026-10-09T15:55:19.7006860Z Private window display name verifier passed\n2026-10-09T15:55:19.7628310Z .......\n2026-10-09T15:55:19.7628920Z ----------------------------------------------------------------------\n2026-10-09T15:55:19.7629340Z Ran 7 tests in 0.004s\n2026-10-09T15:55:19.7629540Z \n2026-10-09T15:55:19.7630220Z OK\n2026-10-09T15:55:20.4475140Z ...............................................................\n2026-10-09T15:55:20.4479100Z ----------------------------------------------------------------------\n2026-10-09T15:55:20.4481110Z Ran 63 tests in 0.606s\n2026-10-09T15:55:20.4481430Z \n2026-10-09T15:55:20.4481560Z OK\n2026-10-09T15:55:20.4489770Z sent-thumbnail-private-alias: legacy-comparisons-reproduced, creation-readable, symlinks-rejected\n2026-10-09T15:57:20.6471780Z ..E\n2026-10-09T15:57:20.6480670Z ======================================================================\n2026-10-09T15:57:20.6482910Z ERROR: test_shipping_reader_with_two_window_histories (__main__.PrivateWindowCoverTests.test_shipping_reader_with_two_window_histories)\n2026-10-09T15:57:20.6500840Z ----------------------------------------------------------------------\n2026-10-09T15:57:20.6502040Z Traceback (most recent call last):\n2026-10-09T15:57:20.6503770Z   File "/Users/runner/work/neko-widget/neko-widget/NekoWidget/ci/test-private-window-cover.py", line 274, in test_shipping_reader_with_two_window_histories\n2026-10-09T15:57:20.6505700Z     subprocess.run(["swiftc", str(script), "-o", str(executable)], check=True, timeout=120)\n2026-10-09T15:57:20.6512330Z     ~~~~~~~~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^\n2026-10-09T15:57:20.6514240Z   File "/opt/homebrew/Cellar/python@3.14/3.14.7/Frameworks/Python.framework/Versions/3.14/lib/python3.14/subprocess.py", line 557, in run\n2026-10-09T15:57:20.6515840Z     stdout, stderr = process.communicate(input, timeout=timeout)\n2026-10-09T15:57:20.6516930Z                      ~~~~~~~~~~~~~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^\n2026-10-09T15:57:20.6518450Z   File "/opt/homebrew/Cellar/python@3.14/3.14.7/Frameworks/Python.framework/Versions/3.14/lib/python3.14/subprocess.py", line 1221, in communicate\n2026-10-09T15:57:20.6520370Z     stdout, stderr = self._communicate(input, endtime, timeout)\n2026-10-09T15:57:20.6521320Z                      ~~~~~~~~~~~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^^\n2026-10-09T15:57:20.6522760Z   File "/opt/homebrew/Cellar/python@3.14/3.14.7/Frameworks/Python.framework/Versions/3.14/lib/python3.14/subprocess.py", line 2179, in _communicate\n2026-10-09T15:57:20.6524340Z     self.wait(timeout=self._remaining_time(endtime))\n2026-10-09T15:57:20.6525120Z     ~~~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^\n2026-10-09T15:57:20.6526600Z   File "/opt/homebrew/Cellar/python@3.14/3.14.7/Frameworks/Python.framework/Versions/3.14/lib/python3.14/subprocess.py", line 1279, in wait\n2026-10-09T15:57:20.6527970Z     return self._wait(timeout=timeout)\n2026-10-09T15:57:20.6528710Z            ~~~~~~~~~~^^^^^^^^^^^^^^^^^\n2026-10-09T15:57:20.6530150Z   File "/opt/homebrew/Cellar/python@3.14/3.14.7/Frameworks/Python.framework/Versions/3.14/lib/python3.14/subprocess.py", line 2076, in _wait\n2026-10-09T15:57:20.6531580Z     raise TimeoutExpired(self.args, timeout)\n2026-10-09T15:57:20.6534200Z subprocess.TimeoutExpired: Command \'[\'swiftc\', \'/var/folders/nj/vtw8zd2j31d1gdrtntc5y4600000gn/T/private-window-cover-_9h6_49m/main.swift\', \'-o\', \'/var/folders/nj/vtw8zd2j31d1gdrtntc5y4600000gn/T/private-window-cover-_9h6_49m/verify-cover\']\' timed out after 120 seconds\n2026-10-09T15:57:20.6541550Z \n2026-10-09T15:57:20.6541720Z ----------------------------------------------------------------------\n2026-10-09T15:57:20.6542150Z Ran 3 tests in 120.125s\n2026-10-09T15:57:20.6542340Z \n2026-10-09T15:57:20.6542400Z FAILED (errors=1)\n2026-10-09T15:57:20.6742840Z ##[error]Process completed with exit code 1.\n2026-10-09T15:57:20.7234630Z ##[group]Run actions/upload-artifact@b7c566a772e6b6bfb58ed0dc250532a479d7789f\n'

    def setUp(self):
        old = ModerationProductionUIRecoveryTests(); old.setUp()
        self.previous = old.prove() | {"candidate_sha": planner.MODERATION_CHAIN_SOURCE}
        self.source, self.head = planner.MODERATION_CHAIN_SOURCE, planner.MODERATION_CHAIN_PRODUCT
        self.repo, self.now, self.required = old.repo, old.now, old.required
        self.run = old.run | {"id": planner.MODERATION_CHAIN_RUN, "head_sha": self.source}
        self.build_steps = planner.moderation_build_steps()
        self.workflow = planner.git("show", f"{self.source}:.github/workflows/ios-build.yml")
        self.jobs = []
        for name, job_id in planner.MODERATION_CHAIN_JOBS.items():
            names = self.build_steps if name == planner.BUILD else ("Check out repository", "Test CI selection and evidence boundaries", "Select checks") if name == planner.PLAN_JOB else ("Check out repository", "Run Simulator smoke test", "Upload Simulator smoke-test artifacts") if name == planner.BOOTSTRAP_SMOKE else ("Check out repository", "Run sharing runtime matrix", "Upload sharing runtime matrix artifacts")
            steps = [{"name": step, "number": i+2, "status": "completed", "conclusion": "success"} for i, step in enumerate(names)]
            if name == planner.BUILD:
                failure = names.index(planner.MODERATION_CHAIN_FAILED_STEP)
                for i in range(failure, len(steps)): steps[i]["conclusion"] = "failure" if i == failure else "skipped"
                steps[failure]["number"] = 13
            self.jobs.append({"id": job_id, "name": name, "head_sha": self.source, "run_id": self.run["id"],
                "run_attempt": 1, "status": "completed", "conclusion": "failure" if name == planner.BUILD else "success",
                "completed_at": self.now.isoformat(), "steps": steps})
        self.record = old.record | {"head_sha": self.source, "production_ui_recovery": self.previous}
        self.failure = self.failure_slice; self.ui_log = old.transcript()
        self.photos_failure = "fixed synthetic Photos snapshot failure\n"
        self.photos_digest = planner.hashlib.sha256(self.photos_failure.strip("\n").encode()).hexdigest()
        self.photos_success = ("Test Case '-[NekoWidgetUITests.PhotoPermissionUITests testGrantFullPhotoLibraryAccess]' started.\n"
            "Test Case '-[NekoWidgetUITests.PhotoPermissionUITests testGrantFullPhotoLibraryAccess]' passed (22.857 seconds).\n"
            "Test Case '-[NekoWidgetUITests.PhotoPermissionUITests testMainlineAcceptanceScreensWithAuthorizedLibrary]' started.\n"
            "Test Case '-[NekoWidgetUITests.PhotoPermissionUITests testMainlineAcceptanceScreensWithAuthorizedLibrary]' passed (109.435 seconds).\n"
            "Simulator smoke test passed at 2026-10-09T16:00:00Z")
        photo = next(job for job in self.jobs if job["name"] == planner.BOOTSTRAP_SMOKE)
        photo["conclusion"] = "failure"; photo["steps"][1].update(conclusion="failure", number=3)
        self.jobs += [self.jobs[0] | {"id": identifier, "name": planner.UNEXPANDED_SHARING_JOB,
            "conclusion": "skipped", "steps": []} for identifier in planner.MODERATION_CHAIN_SKIPS]
        self.index = {"total_count": 0, "workflow_runs": []}

    def api(self, path):
        if path.endswith(f"/runs/{self.run['id']}"): return self.run
        if "/jobs?" in path: return {"total_count": len(self.jobs), "jobs": self.jobs}
        if path.endswith(f"/{planner.MODERATION_CHAIN_JOBS[planner.PLAN_JOB]}/logs"): return "IOS_CI_PLAN_JSON=" + json.dumps(self.record)
        if path.endswith(f"/{planner.MODERATION_CHAIN_JOBS[planner.BUILD]}/logs"): return self.failure
        if path.endswith(f"/{planner.MODERATION_CHAIN_JOBS[planner.BOOTSTRAP_SMOKE]}/logs"): return self.photos_failure
        if path.endswith(f"/{planner.MODERATION_CHAIN_JOBS[planner.lane_job(planner.MODERATION_RESOLUTION_SCOPE, 'app-ui')]}/logs"): return self.ui_log
        if "/runs?head_sha=" + self.head in path: return self.index
        raise AssertionError(path)

    def prove(self):
        with patch.object(planner, "moderation_chained_inputs", return_value=True), \
                patch.object(planner, "moderation_ui_recovery_evidence", return_value=self.previous) as old, \
                patch.object(planner, "moderation_build_steps", return_value=self.build_steps), \
                patch.object(planner, "git", return_value=self.workflow), \
                patch.object(planner, "MODERATION_CHAIN_PHOTOS_LOG_SHA256", self.photos_digest):
            result = planner.moderation_chained_evidence(self.head, self.repo, self.api, self.now)
            old.assert_called_once_with(self.source, self.repo, self.api, self.now)
            return result

    def test_source_identity_pending_failure_skip_step_and_all_eleven_cases_are_strict(self):
        proof = self.prove()
        self.assertEqual(len(proof["native_jobs_reused"]), 2)
        self.assertEqual(proof["owning_jobs_to_execute"], list(planner.MODERATION_CHAIN_OWNING))
        self.assertEqual(proof["backend_evidence"], self.previous["backend_evidence"])
        run = self.run.copy()
        for field, value in (("status", "in_progress"), ("conclusion", "success"), ("head_sha", "a"*40),
                ("event", "workflow_dispatch"), ("head_branch", "main"), ("run_attempt", 2), ("workflow_id", 7),
                ("repository", {"full_name": "other/repo"}), ("head_repository", {"full_name": "other/repo"}),
                ("updated_at", "2026-10-08T15:00:00Z")):
            self.run = run | {field: value}
            with self.subTest(field=field), self.assertRaises(ValueError): self.prove()
        self.run = run; original = copy.deepcopy(self.jobs)
        for n, job in enumerate(original):
            for field, value in (("conclusion", "skipped"), ("status", "in_progress"), ("head_sha", "a"*40),
                    ("run_attempt", 2), ("id", 1), ("steps", []), ("run_id", 2)):
                if job["id"] in planner.MODERATION_CHAIN_SKIPS and (field, value) in (("conclusion", "skipped"), ("steps", [])): continue
                self.jobs = copy.deepcopy(original); self.jobs[n][field] = value
                with self.subTest(job=job["name"], field=field), self.assertRaises(ValueError): self.prove()
            if job["name"] not in {planner.BUILD, planner.UNEXPANDED_SHARING_JOB}:
                for step in range(len(job["steps"])):
                    self.jobs = copy.deepcopy(original); self.jobs[n]["steps"][step]["conclusion"] = "skipped"
                    with self.assertRaises(ValueError): self.prove()
        self.jobs = original
        for bad in (self.ui_log.replace("passed", "failed", 1), self.ui_log.replace("passed", "skipped", 1), self.ui_log.splitlines()[0], self.ui_log+self.ui_log):
            saved = self.ui_log; self.ui_log = bad
            with self.assertRaises(ValueError): self.prove()
            self.ui_log = saved
        self.jobs += [copy.deepcopy(original[0])]
        with self.assertRaises(ValueError): self.prove()

    def test_timeout_parser_requires_owning_command_and_only_actual_failure(self):
        with patch.object(planner, "git", return_value=self.workflow):
            self.assertTrue(planner.moderation_chained_build_failure(self.failure))
            mutants = [self.failure.replace("120 seconds", "121 seconds"), self.failure.replace("Ran 3 tests", "Ran 4 tests"),
                self.failure.replace("errors=1", "errors=2"), self.failure.replace("'swiftc'", "'swift'"),
                self.failure.replace("python3 ci/test-private-window-cover.py", "python3 ci/other.py"),
                self.failure.replace("##[group]Run set -euo pipefail", "Run set -euo pipefail"),
                self.failure+self.failure, self.failure+"\nFAIL: extra", self.failure+"\nERROR: extra",
                self.failure+"\nFAILED (failures=1)", self.failure+"\n##[error]another failure",
                self.failure.replace("Process completed with exit code 1.", "Process completed with exit code 2."),
                self.failure.replace("main.swift", "unrelated.swift")]
            for bad in mutants:
                self.assertFalse(planner.moderation_chained_build_failure(bad))

    def test_photos_failure_is_an_exact_transcript_and_new_success_includes_permission_and_scan(self):
        with patch.object(planner, "MODERATION_CHAIN_PHOTOS_LOG_SHA256", self.photos_digest):
            self.assertTrue(planner.moderation_chained_photos_failure(self.photos_failure))
            self.assertTrue(planner.moderation_chained_photos_failure(self.photos_failure.replace("\n", "\r\n")))
            for changed in (self.photos_failure+"extra", "", self.photos_failure.replace("failure", "pass")):
                self.assertFalse(planner.moderation_chained_photos_failure(changed))
        self.assertTrue(planner.moderation_chained_photos_success(self.photos_success))
        for changed in (self.photos_success.replace("passed (", "failed ("), self.photos_success.replace("passed at", "unfinished at"),
                        self.photos_success+self.photos_success, self.photos_success+"\n##[error]extra", self.photos_success.replace("testGrantFullPhotoLibraryAccess", "testOther")):
            self.assertFalse(planner.moderation_chained_photos_success(changed))

    def test_photos_success_requires_both_ordered_cases_and_rejects_any_extra_or_incomplete_event(self):
        lines = self.photos_success.splitlines()
        for index in range(4):
            with self.subTest(missing=index):
                self.assertFalse(planner.moderation_chained_photos_success("\n".join(lines[:index]+lines[index+1:])))
            with self.subTest(duplicate=index):
                self.assertFalse(planner.moderation_chained_photos_success("\n".join(lines[:index]+[lines[index]]+lines[index:])))
        for order in ((2,3,0,1,4),(0,2,1,3,4),(1,0,2,3,4),(0,1,3,2,4),(4,0,1,2,3)):
            self.assertFalse(planner.moderation_chained_photos_success("\n".join(lines[i] for i in order)))
        for method in ("testGrantFullPhotoLibraryAccess", "testMainlineAcceptanceScreensWithAuthorizedLibrary"):
            for status in ("failed", "skipped", "aborted"):
                text=self.photos_success.replace(f"{method}]' passed",f"{method}]' {status}")
                self.assertFalse(planner.moderation_chained_photos_success(text))
        for extra in ("Test Case '-[NekoWidgetUITests.OtherTests testUnknown]' started.",
                      "Test Case '-[NekoWidgetUITests.PhotoPermissionUITests unknownMethod]' passed.",
                      "Test Case '-[malformed", "ERROR: extra", "FAIL: extra", ": error: extra", "** TEST FAILED **"):
            self.assertFalse(planner.moderation_chained_photos_success(self.photos_success+"\n"+extra))
        self.assertFalse(planner.moderation_chained_photos_success("\n".join(lines[:2]+lines[-1:])))

    def test_candidate_backend_presence_and_old_proof_failure_cannot_be_hidden(self):
        for bad in ({"total_count": 1, "workflow_runs": []}, {"total_count": False, "workflow_runs": []},
                {"total_count": 0, "workflow_runs": [{}]}, {"total_count": 1, "workflow_runs": [{"conclusion": "success"}]},
                {"total_count": 1, "workflow_runs": [{"conclusion": "failure"}]}, {"total_count": 1, "workflow_runs": [{"status": "in_progress"}]}):
            self.index = bad
            with self.assertRaises(ValueError): self.prove()
        with patch.object(planner, "moderation_chained_inputs", return_value=True), \
                patch.object(planner, "moderation_ui_recovery_evidence", side_effect=ValueError("old source incomplete")), self.assertRaises(ValueError):
            planner.moderation_chained_evidence(self.head, self.repo, self.api, self.now)

    def test_three_fixed_pairs_all_tracked_closure_modes_approval_and_missing_are_strict(self):
        rows = [f":100644 100644 {a} {b} M\0{path}\0" for path,(a,b) in planner.MODERATION_CHAIN_BLOBS.items()]
        raw = "".join(rows)
        def check(value=raw, registered=True, mismatch=None):
            def git(*args):
                if args[0] == "diff": return value
                if args[0] == "merge-base": return "a"*40
                if args[0] == "show": return f'MODERATION_CHAIN_PRODUCT = "{self.head}"' if registered else "old"
                if args[0] == "ls-tree": return f"100644 blob {'d'*40 if args[1] == self.head and args[3] == mismatch else 'c'*40}\t{args[3]}"
                raise AssertionError(args)
            with patch.object(planner, "git", side_effect=git): return planner.moderation_chained_inputs(self.head)
        self.assertTrue(check())
        self.assertTrue(check(raw+f":000000 100644 {'0'*40} {'c'*40} A\0handoffs/fixed.md\0"))
        for path in planner.MODERATION_BUILD_CORRECTION_CONTROLS: self.assertFalse(check(mismatch=path))
        for bad in ("", raw+rows[0], raw.replace("100644", "100755"), raw.replace("100644", "120000"), raw.replace(" M\0", " D\0"),
                raw.replace(planner.MODERATION_CHAIN_BLOBS[scope.MODERATION_RESOLUTION_PRIVATE_COVER_TEST][1], "b"*40),
                *(raw.replace(row, "") for row in rows),
                *(raw+f":100644 100644 {'b'*40} {'c'*40} M\0{path}\0" for path in (".gitattributes", ".github/workflows/ios-build.yml", "NekoWidget/Shared/Sharing/MomentSharingCore.swift"))):
            self.assertFalse(check(bad))
        self.assertFalse(check(registered=False))
        self.assertTrue(scope.accepts_paths(scope.MODERATION_RESOLUTION_SCOPE, scope.MODERATION_RESOLUTION_PATHS | set(planner.MODERATION_CHAIN_BLOBS)))
        self.assertFalse(scope.accepts_paths(scope.MODERATION_RESOLUTION_SCOPE, scope.MODERATION_RESOLUTION_PATHS | {scope.MODERATION_RESOLUTION_PRIVATE_COVER_TEST}))

    def test_final_full_build_and_main_reuse_revalidate_the_same_chain(self):
        proof = self.prove(); run = self.run | {"id": 123, "head_sha": self.head, "conclusion": "success"}
        jobs = [copy.deepcopy(j) for j in self.jobs if j["name"] in {planner.BUILD, planner.BOOTSTRAP_SMOKE, planner.PLAN_JOB}]
        for job in jobs:
            job.update(id=job["id"]+100, head_sha=self.head, run_id=123, conclusion="success")
            for step in job["steps"]: step["conclusion"] = "success"
        record = self.record | {"head_sha": self.head, "production_ui_recovery": None, "chained_build_recovery": proof}
        def check(values=jobs, proof_value=proof, main=False):
            with patch.object(planner, "moderation_chained_inputs", return_value=True), \
                    patch.object(planner, "moderation_build_steps", return_value=self.build_steps), \
                    patch.object(planner, "moderation_chained_evidence", return_value=proof_value) as verify:
                fn = planner.covers_corrected_full_graph if main else planner.covers_moderation_chained_recovery
                def api(path):
                    if path.endswith(f"/{planner.MODERATION_CHAIN_JOBS[planner.BOOTSTRAP_SMOKE]+100}/logs"): return self.photos_success
                    return "IOS_CI_PLAN_JSON="+json.dumps(record)
                result = fn(run, "f"*40, self.required, api, self.now, values)
                if result: verify.assert_called_once_with(self.head, self.repo, unittest.mock.ANY, self.now)
                return result
        self.assertTrue(check()); self.assertTrue(check(main=True)); self.assertFalse(check(proof_value={}))
        for index, job in enumerate(jobs):
            for n in range(len(job["steps"])):
                bad=copy.deepcopy(jobs); bad[index]["steps"][n]["conclusion"]="skipped"; self.assertFalse(check(bad))
            for field,value in (("steps",[]),("run_attempt",2),("head_sha",self.source),("conclusion","failure")):
                bad=copy.deepcopy(jobs);bad[index][field]=value;self.assertFalse(check(bad))
        self.assertFalse(check(jobs+[jobs[0]]))
        skipped=jobs[0]|{"id":1,"name":planner.UNEXPANDED_SHARING_JOB,"conclusion":"skipped","steps":[]}
        self.assertTrue(check(jobs+[skipped]));self.assertFalse(check(jobs+[skipped|{"conclusion":"failure"}]))
        record["production_ui_recovery"]={};self.assertFalse(check())

    def test_planner_executes_build_and_photos_without_test_only_or_all_native_fallback(self):
        proof=self.prove()
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/"event").write_text("{}")
            env={"GITHUB_EVENT_NAME":"push","GITHUB_REF":"refs/heads/"+self.run["head_branch"],"GITHUB_SHA":self.head,
                "GITHUB_REPOSITORY":self.repo,"GITHUB_RUN_ID":"123","GITHUB_WORKFLOW":"iOS build check","GITHUB_SERVER_URL":"https://github.com",
                "GITHUB_EVENT_PATH":str(root/"event"),"GITHUB_OUTPUT":str(root/"output"),"GITHUB_STEP_SUMMARY":str(root/"summary")}
            output=io.StringIO()
            with patch.dict(os.environ,env),contextlib.redirect_stdout(output), \
                    patch.object(planner,"changed_paths",return_value=list(scope.MODERATION_RESOLUTION_PATHS|set(planner.MODERATION_CHAIN_BLOBS))), \
                    patch.object(planner,"runtime_scope",return_value=scope.MODERATION_RESOLUTION_SCOPE), \
                    patch.object(planner,"find_evidence",return_value=None),patch.object(planner,"moderation_chained_inputs",return_value=True), \
                    patch.object(planner,"moderation_chained_evidence",return_value=proof), \
                    patch.object(planner,"find_test_correction_evidence",side_effect=AssertionError("old route")), \
                    patch.object(planner,"moderation_ui_recovery_evidence",side_effect=AssertionError("all-native route")):
                planner.main()
            flags=dict(line.split("=",1) for line in (root/"output").read_text().splitlines())
            self.assertEqual([flags[k] for k in ("build","smoke","sharing","app_ui")],["true","true","false","false"])
            record=planner.moderation_build_plan(output.getvalue(),self.head,self.required)
            self.assertEqual(record["chained_build_recovery"],proof);self.assertIsNone(record["test_correction_evidence"])
            self.assertEqual(record["required_backend_runs"],planner.moderation_resolution_requirements(planner.MODERATION_BUILD_CORRECTION_SOURCE))


class ModerationResolutionScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644", before, after,
                       "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.MODERATION_RESOLUTION_BLOBS.items()}

    def test_fixed_build_test_correction_variant_requires_approved_complete_inputs(self):
        rows = self.rows()
        before, after = planner.MODERATION_BUILD_CORRECTION_BLOBS
        rows[planner.MODERATION_RESOLUTION_BUILD_TEST] = [":100644", "100644", before, after, "M"]
        with patch.object(planner, "moderation_build_correction_inputs", return_value=True):
            self.assertEqual(self.select(rows), planner.MODERATION_RESOLUTION_SCOPE)
            for n, value in ((0, ":100755"), (1, "120000"), (2, "d" * 40), (3, "e" * 40), (4, "D")):
                invalid = copy.deepcopy(rows); invalid[planner.MODERATION_RESOLUTION_BUILD_TEST][n] = value
                self.assertEqual(self.select(invalid), scope.FULL_SCOPE)
        with patch.object(planner, "moderation_build_correction_inputs", return_value=False):
            self.assertEqual(self.select(rows), scope.FULL_SCOPE)

    def test_shipping_ui_recovery_variant_keeps_complete_four_job_scope(self):
        rows = self.rows() | {path: [":100644", "100644", *pair, "M"] for path, pair in planner.MODERATION_UI_RECOVERY_BLOBS.items()}
        with patch.object(planner, "moderation_ui_recovery_inputs", return_value=True):
            self.assertEqual(self.select(rows), planner.MODERATION_RESOLUTION_SCOPE)
            invalid = copy.deepcopy(rows); invalid[planner.MODERATION_RESOLUTION_EXPORT_VIEW][3] = "f" * 40
            self.assertEqual(self.select(invalid), scope.FULL_SCOPE)
        with patch.object(planner, "moderation_ui_recovery_inputs", return_value=False):
            self.assertEqual(self.select(rows), scope.FULL_SCOPE)

    def select(self, rows=None, *, paths=None, raw=None, immutable=None, methods=True):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base": return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0" for path, fields in rows.items())
            if args[0] == "ls-tree":
                ref, path = args[1], args[3]
                return (immutable or {}).get((ref, path), f"100644 blob {planner.MODERATION_RESOLUTION_IMMUTABLE_BLOBS.get(path, 'missing')}\t{path}")
            if args[0] == "rev-parse": return self.head
            if args[0] == "show": return "synthetic owning methods"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git), patch.object(planner, "memory_tests_available", return_value=methods):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": "push",
                                                    "GITHUB_REF": "refs/heads/codex/resolution"})

    def test_complete_batch_selects_four_native_classes_and_five_backends(self):
        self.assertEqual(len(self.rows()), 42)
        self.assertEqual(sum(row[-1] == "A" for row in self.rows().values()), 4)
        selected = planner.MODERATION_RESOLUTION_SCOPE
        self.assertEqual(self.select(), selected)
        self.assertIn(selected, scope.SCOPES)
        expected = (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(selected)
        self.assertEqual(planner.required_jobs(list(self.rows()), selected), expected)
        self.assertEqual(len(expected), 4)
        self.assertEqual(scope.lanes(selected), ("runtime", "app-ui"))
        self.assertEqual(scope.matrix_lanes(selected), ("runtime",))
        self.assertEqual(scope.native_tests(selected), scope.native_tests(scope.FAMILY_WINDOW_UI_SCOPE) + scope.MODERATION_RESOLUTION_TESTS[-3:])
        self.assertEqual(len(scope.native_tests(selected)), 11)
        self.assertEqual(scope.smoke_tests(selected), scope.smoke_tests(scope.FAMILY_WINDOW_UI_SCOPE))
        required = planner.moderation_resolution_requirements(self.head)
        self.assertEqual(len(required), 5)
        self.assertEqual({item["workflow"] for item in required}, {planner.BILLING_WORKFLOW, planner.PRESERVATION_WORKFLOW})
        self.assertTrue(all(item["head_sha"] == self.head and item["event"] == "push" and item["success_required"] for item in required))

    def test_incomplete_unknown_duplicate_control_modes_and_changed_blobs_fail_closed(self):
        rows = self.rows()
        for path, row in rows.items():
            with self.subTest(missing=path):
                self.assertEqual(self.select({p: r for p, r in rows.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":120000"), (1, "100755"), (2, "c" * 40), (3, "d" * 40), (4, "D")):
                altered = copy.deepcopy(rows); altered[path][index] = value
                with self.subTest(path=path, field=index): self.assertEqual(self.select(altered), scope.FULL_SCOPE)
        for path in ("unknown.swift", "NekoWidget/ci/plan-ios-ci.py", "NekoWidget/SharingService/src/unreviewed.ts"):
            self.assertEqual(self.select(rows | {path: [":000000", "100644", "0" * 40, "c" * 40, "A"]}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(rows) + [next(iter(rows))]), scope.FULL_SCOPE)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in rows.items())
        self.assertEqual(self.select(raw=raw + raw.split("\0", 2)[0] + "\0" + next(iter(rows)) + "\0"), scope.FULL_SCOPE)
        self.assertEqual(self.select(methods=False), scope.FULL_SCOPE)

    def test_pending_or_malformed_registration_cannot_select_the_new_scope(self):
        rows, original = self.rows(), planner.MODERATION_RESOLUTION_BLOBS
        path = next(iter(original))
        for invalid in ({}, {key: pair for key, pair in original.items() if key != path},
                        original | {path: (original[path][0], "0" * 40)},
                        original | {path: (original[path][0], original[path][0])},
                        original | {path: ("bad", "a" * 40)}, original | {path: ("a" * 40,)}):
            with patch.object(planner, "MODERATION_RESOLUTION_BLOBS", invalid):
                self.assertEqual(self.select(rows), scope.FULL_SCOPE)
        with patch.object(planner, "MODERATION_RESOLUTION_IMMUTABLE_BLOBS", {}):
            self.assertEqual(self.select(rows), scope.FULL_SCOPE)

    def test_plan_outputs_native_graph_and_backend_main_does_not_wait_for_itself(self):
        selected = planner.MODERATION_RESOLUTION_SCOPE
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / "event").write_text("{}")
            env = {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/codex/resolution",
                   "GITHUB_REPOSITORY": "soso-so-27/neko-widget", "GITHUB_WORKFLOW": "iOS build check",
                   "GITHUB_EVENT_PATH": str(root / "event"), "GITHUB_OUTPUT": str(root / "output"),
                   "GITHUB_STEP_SUMMARY": str(root / "summary")}
            for backend in (False, True):
                output = io.StringIO()
                with patch.dict(os.environ, env | ({"GITHUB_REF": "refs/heads/main", "GITHUB_WORKFLOW": "Sharing service check"} if backend else {})), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=selected), \
                        patch.object(planner, "preservation_sharing_plan", return_value=backend), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("must not await self") if backend else None, return_value=None), \
                        patch.object(planner, "find_test_correction_evidence", return_value=None), contextlib.redirect_stdout(output):
                    planner.main()
                values = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual(values["runtime_scope"], selected)
                self.assertTrue(all(values[key] == str(not backend).lower() for key in ("build", "smoke", "sharing", "app_ui")))
                if not backend:
                    marker = "IOS_CI_PLAN_JSON="
                    plan = json.loads(next(line[len(marker):] for line in output.getvalue().splitlines() if line.startswith(marker)))
                    self.assertEqual(plan["required_backend_runs"], planner.moderation_resolution_requirements(self.head))
                    self.assertEqual(json.loads(values["matrix_lanes"]), ["runtime"])
                    self.assertEqual(json.loads(values["app_ui_lanes"]), ["app-ui"])

    def test_ordinary_handoffs_only_and_both_endpoint_immutable_modes(self):
        for row in ([":000000", "100644", "0" * 40, "e" * 40, "A"], [":100644", "100644", "d" * 40, "e" * 40, "M"]):
            self.assertEqual(self.select(self.rows() | {"handoffs/resolution.md": row}), planner.MODERATION_RESOLUTION_SCOPE)
        for row in ([":100644", "000000", "d" * 40, "0" * 40, "D"], [":000000", "120000", "0" * 40, "e" * 40, "A"]):
            self.assertEqual(self.select(self.rows() | {"handoffs/resolution.md": row}), scope.FULL_SCOPE)
        for path in planner.MODERATION_RESOLUTION_IMMUTABLE_BLOBS:
            for ref in (self.base, self.head):
                for value in ("", f"100755 blob {'d' * 40}\t{path}", f"100644 blob {'d' * 40}\t{path}"):
                    with self.subTest(path=path, ref=ref):
                        self.assertEqual(self.select(immutable={(ref, path): value}), scope.FULL_SCOPE)


class ModerationResolutionBackendEvidenceTests(unittest.TestCase):
    def setUp(self):
        # Reuse only the synthetic API fixture shape; no fixed durable reuse is invoked.
        self.fixture = ModerationAIDurableBackendReuseTests()
        self.fixture.setUp()
        f = self.fixture
        self.sha, self.now, self.responses = f.candidate, f.now, copy.deepcopy(f.responses)
        old = self.responses.pop(f.index("preservation-service.yml", f.source))
        self.responses[f.index("preservation-service.yml", self.sha)] = old
        for response in self.responses.values():
            if "workflow_runs" in response:
                for run in response["workflow_runs"]: run["head_sha"] = self.sha
            if "jobs" in response:
                for job in response["jobs"]: job["head_sha"] = self.sha
        self.indexes = [f.index(w, self.sha) for w in ("preservation-service.yml", "sharing-service.yml")]
        self.job_keys = [f.jobs_path(r) for r in (37911654217, 37913531637)]

    def prove(self):
        return planner.moderation_resolution_backend_evidence(self.sha, self.fixture.repo, self.responses.__getitem__, self.now,
                                                              branch="codex/moderation-ai-durable-20261009")

    def test_same_sha_push_and_all_executed_owning_steps_required(self):
        result = self.prove()
        self.assertEqual(sum(len(row["job_ids"]) for row in result.values()), 5)
        self.assertTrue(all(row["sha"] == self.sha and row["event"] == "push" for row in result.values()))
        for key in self.job_keys:
            original = copy.deepcopy(self.responses[key])
            for n, job in enumerate(original["jobs"]):
                for field, value in (("head_sha", "d" * 40), ("conclusion", "skipped"), ("status", "in_progress"), ("run_id", 4)):
                    self.responses[key] = copy.deepcopy(original); self.responses[key]["jobs"][n][field] = value
                    with self.subTest(job=job["name"], field=field), self.assertRaises(ValueError): self.prove()
                for step in range(len(job["steps"])):
                    if job["steps"][step]["name"] in ("Check out repository", "Set up Node.js", "Install locked dependencies without lifecycle scripts"): continue
                    self.responses[key] = copy.deepcopy(original); self.responses[key]["jobs"][n]["steps"][step]["conclusion"] = "skipped"
                    with self.subTest(job=job["name"], step=step), self.assertRaises(ValueError): self.prove()
            self.responses[key] = original
            self.responses[key]["jobs"].append(copy.deepcopy(original["jobs"][0])); self.responses[key]["total_count"] += 1
            with self.assertRaises(ValueError): self.prove()
            self.responses[key] = original

    def test_absent_dispatch_pr_wrong_owner_stale_newer_failure_and_incomplete_fail_closed(self):
        for key in self.indexes:
            original = copy.deepcopy(self.responses[key])
            for field, value in (("head_sha", "d" * 40), ("event", "workflow_dispatch"), ("event", "pull_request"),
                    ("head_branch", "main"), ("head_branch", "diagnostic/resolution"), ("workflow_id", 88),
                    ("path", ".github/workflows/other.yml"), ("head_repository", {"full_name": "other/repo"}),
                    ("updated_at", "2020-01-01T00:00:00Z"), ("status", "in_progress"), ("conclusion", "failure")):
                self.responses[key] = copy.deepcopy(original); self.responses[key]["workflow_runs"][0][field] = value
                with self.subTest(key=key, field=field), self.assertRaises(ValueError): self.prove()
            for invalid in ({"total_count": 0, "workflow_runs": []}, {"total_count": 2, "workflow_runs": original["workflow_runs"]}):
                self.responses[key] = invalid
                with self.assertRaises(ValueError): self.prove()
            newer = copy.deepcopy(original["workflow_runs"][0]); newer.update(id=123456, run_number=2, conclusion="failure")
            self.responses[key] = {"total_count": 2, "workflow_runs": original["workflow_runs"] + [newer]}
            with self.assertRaises(ValueError): self.prove()
            self.responses[key] = original


class ModerationAIDurableBackendReuseTests(unittest.TestCase):
    def setUp(self):
        self.candidate = planner.MODERATION_AI_DURABLE_REUSE_CANDIDATE
        self.source = planner.MODERATION_AI_DURABLE_REUSE_SOURCE
        self.repo = "soso-so-27/neko-widget"
        self.now = dt.datetime(2026, 10, 9, 10, tzinfo=dt.timezone.utc)
        self.prefix = f"/repos/{self.repo}/actions"
        self.responses = {}
        self.git_changes = {}
        self.steps = {
            planner.PRESERVATION_JOB: ["Check out repository", "Set up Node.js",
                "Install locked dependencies without lifecycle scripts", "Typecheck the disabled service",
                "Verify local identity, custody and storage boundaries",
                "Verify legacy notice evidence migration with synthetic owners",
                "Bundle the private authority without deployment or provisioning",
                "Bundle the private owner deletion executor without deployment"],
            planner.MODERATION_AI_DURABLE_JOBS[0]: ["Run python NekoWidget/ci/plan-ios-ci.py"],
            planner.MODERATION_AI_DURABLE_JOBS[1]: ["Verify Apple transaction service boundary",
                "Verify durable nonce and capability credential boundaries",
                "Build nonroot Node image and private Worker without publishing"],
            planner.MODERATION_AI_DURABLE_JOBS[2]: ["Parse and exercise Windows path, volume, and ACL policy"],
            planner.MODERATION_AI_DURABLE_JOBS[3]: ["Run Worker, D1, staging, moderation, and key ceremony tests",
                "Build deployment bundle without publishing"],
            "Select iOS checks and verify reusable evidence": ["Test CI selection and evidence boundaries", "Select checks"],
        }
        self.specs = (("preservation-service.yml", self.source, 37911654217, (planner.PRESERVATION_JOB,)),
                      ("sharing-service.yml", self.candidate, 37913531637, planner.MODERATION_AI_DURABLE_JOBS[:-1]),
                      ("ios-build.yml", self.candidate, 37913531658, ("Select iOS checks and verify reusable evidence",)))
        self.responses[self.index("preservation-service.yml", self.candidate)] = {"total_count": 0, "workflow_runs": []}
        for number, (workflow, sha, run_id, required) in enumerate(self.specs, 1):
            identity = {"id": number, "path": ".github/workflows/" + workflow, "state": "active"}
            run = {"id": run_id, "workflow_id": number, "path": identity["path"],
                   "repository": {"full_name": self.repo}, "head_repository": {"full_name": self.repo},
                   "head_sha": sha, "head_branch": "codex/moderation-ai-durable-20261009", "event": "push",
                   "status": "completed", "conclusion": "success", "run_attempt": 1, "run_number": 1,
                   "run_started_at": "2026-10-09T09:00:00Z", "updated_at": "2026-10-09T09:05:00Z"}
            jobs = [{"id": run_id * 10 + i, "name": name, "run_id": run_id, "run_attempt": 1,
                     "head_sha": sha, "status": "completed", "conclusion": "success",
                     "started_at": "2026-10-09T09:01:00Z", "completed_at": "2026-10-09T09:04:00Z",
                     "steps": [{"name": step, "number": j, "status": "completed", "conclusion": "success"}
                               for j, step in enumerate(self.steps[name], 1)]}
                    for i, name in enumerate(required, 1)]
            self.responses[f"{self.prefix}/workflows/{workflow}"] = identity
            self.responses[self.index(workflow, sha)] = {"total_count": 1, "workflow_runs": [copy.deepcopy(run)]}
            self.responses[f"{self.prefix}/runs/{run_id}"] = run
            self.responses[self.jobs_path(run_id)] = {"total_count": len(jobs), "jobs": jobs}

    def index(self, workflow, sha):
        return f"{self.prefix}/workflows/{workflow}/runs?head_sha={sha}&event=push&per_page=100"

    def jobs_path(self, run_id):
        return f"{self.prefix}/runs/{run_id}/jobs?filter=latest&per_page=100&page=1"

    def git(self, *args):
        if args in self.git_changes:
            return self.git_changes[args]
        if args[0] == "rev-parse":
            return args[-1].removesuffix("^{commit}")
        if args[0] == "merge-base":
            return self.source
        if args[0] == "ls-tree":
            path = args[-1]
            if path.endswith(".yml"):
                blob = planner.MODERATION_AI_DURABLE_WORKFLOW_BLOBS[path]
                return f"100644 blob {blob}\t{path}"
            if "-r" in args:
                return f"100644 blob {'a' * 40}\t{path}/file.ts\0"
            return f"040000 tree {'b' * 40}\t{path}"
        raise AssertionError(args)

    def prove(self, **kwargs):
        params = {"candidate_sha": self.candidate, "repository": self.repo, "api": self.responses.__getitem__,
                  "now": self.now, "runtime_scope": planner.MODERATION_AI_DURABLE_SCOPE} | kwargs
        with patch.object(planner, "git", side_effect=self.git):
            return planner.moderation_ai_durable_backend_evidence(**params)

    def test_fixed_proof_keeps_source_distinct_and_candidate_jobs_on_candidate(self):
        result = self.prove()
        self.assertEqual(result["source_sha"], self.source)
        self.assertEqual(result["candidate_sha"], self.candidate)
        self.assertEqual(result["candidate_preservation_push_count"], 0)
        self.assertEqual([root["path"] for root in result["verified_roots"]], list(planner.MODERATION_AI_DURABLE_REUSE_ROOTS))
        for workflow, sha, run_id, required in self.specs:
            record = result["workflows"][workflow]
            self.assertEqual((record["head_sha"], record["run_id"]), (sha, run_id))
            self.assertEqual(record["same_candidate_sha"], workflow != "preservation-service.yml")
            self.assertEqual([job["name"] for job in record["jobs"]], list(required))
        self.assertFalse(result["main_integration_verified"])
        self.assertFalse(result["native_or_release_evidence"])

    def test_any_candidate_push_or_incomplete_index_prohibits_reuse(self):
        key = self.index("preservation-service.yml", self.candidate)
        invalid = [{}, {"total_count": False, "workflow_runs": []}, {"total_count": "0", "workflow_runs": []},
                   {"total_count": 0, "workflow_runs": [], "incomplete": True}, {"total_count": 1, "workflow_runs": []}]
        invalid += [{"total_count": 1, "workflow_runs": [{"status": status, "conclusion": conclusion}]}
                    for status, conclusion in (("completed", "success"), ("completed", "failure"),
                                               ("queued", None), ("in_progress", None))]
        for response in invalid:
            with self.subTest(response=response), patch.dict(self.responses, {key: response}), self.assertRaises(ValueError):
                self.prove()

    def test_other_candidate_repository_scope_or_clock_is_rejected(self):
        for values in ({"candidate_sha": self.source}, {"candidate_sha": "a" * 40}, {"repository": "other/repo"},
                       {"runtime_scope": planner.MODERATION_AI_TRANSPORT_SCOPE}, {"now": self.now.replace(tzinfo=None)}):
            with self.subTest(values=values), self.assertRaises(ValueError):
                self.prove(**values)

    def test_ancestry_content_mode_type_missing_and_recursive_difference_are_rejected(self):
        cases = [(('merge-base', self.source, self.candidate), "c" * 40),
                 (("rev-parse", "--verify", self.source + "^{commit}"), "c" * 40)]
        for path in planner.MODERATION_AI_DURABLE_REUSE_ROOTS:
            cases += [(("ls-tree", self.candidate, "--", path), value) for value in
                      ("", f"100755 blob {'b' * 40}\t{path}", f"120000 blob {'b' * 40}\t{path}",
                       f"040000 tree {'c' * 40}\t{path}")]
            cases.append((("ls-tree", "-r", "-z", self.candidate, "--", path), "changed-child-mode-or-content"))
        for args, value in cases:
            with self.subTest(args=args, value=value), patch.dict(self.git_changes, {args: value}), self.assertRaises(ValueError):
                self.prove()

    def test_wrong_workflow_and_run_identity_event_branch_or_attempt_rejected(self):
        for workflow, sha, run_id, _ in self.specs:
            key = f"{self.prefix}/workflows/{workflow}"
            for field, value in (("id", True), ("id", 0), ("state", "disabled_manually"), ("path", ".github/workflows/other.yml")):
                with patch.dict(self.responses, {key: self.responses[key] | {field: value}}), self.assertRaises(ValueError):
                    self.prove()
            for in_index in (True, False):
                key = self.index(workflow, sha) if in_index else f"{self.prefix}/runs/{run_id}"
                original = self.responses[key]
                run = original["workflow_runs"][0] if in_index else original
                mutations = (("id", 7), ("workflow_id", True), ("path", "wrong"), ("head_sha", "a" * 40),
                             ("head_branch", "main"), ("head_branch", "codex/other"), ("event", "pull_request"),
                             ("event", "workflow_dispatch"), ("run_attempt", 2), ("run_attempt", True),
                             ("repository", {"full_name": "other/repo"}), ("head_repository", {"full_name": "other/repo"}),
                             ("status", "in_progress"), ("conclusion", "failure"))
                for field, value in mutations:
                    changed = run | {field: value}
                    response = {"total_count": 1, "workflow_runs": [changed]} if in_index else changed
                    with self.subTest(workflow=workflow, index=in_index, field=field), \
                            patch.dict(self.responses, {key: response}), self.assertRaises(ValueError):
                        self.prove()

    def test_old_future_missing_or_inconsistent_timestamps_rejected(self):
        for workflow, sha, run_id, _ in self.specs:
            key = f"{self.prefix}/runs/{run_id}"
            for value in ("2026-10-08T09:00:00Z", "2026-10-09T10:00:01Z", "2026-10-09T09:00:00", None, "bad"):
                for field in ("updated_at", "run_started_at"):
                    with patch.dict(self.responses, {key: self.responses[key] | {field: value}}), self.assertRaises(ValueError):
                        self.prove()
            key = self.jobs_path(run_id)
            for field, value in (("completed_at", "2026-10-08T09:00:00Z"), ("completed_at", "2026-10-09T10:00:01Z"),
                                 ("completed_at", None), ("started_at", "2026-10-09T09:04:30Z"),
                                 ("started_at", "2026-10-09T08:59:00Z")):
                response = copy.deepcopy(self.responses[key]); response["jobs"][0][field] = value
                with patch.dict(self.responses, {key: response}), self.assertRaises(ValueError):
                    self.prove()

    def test_ambiguous_indexes_and_missing_duplicate_failed_skipped_or_wrong_sha_jobs_rejected(self):
        for workflow, sha, run_id, _ in self.specs:
            key = self.index(workflow, sha)
            for response in ({"total_count": 0, "workflow_runs": []}, {"total_count": 2, "workflow_runs": self.responses[key]["workflow_runs"] * 2}):
                with patch.dict(self.responses, {key: response}), self.assertRaises(ValueError):
                    self.prove()
            key = self.jobs_path(run_id)
            original = self.responses[key]
            cases = [{"total_count": len(original["jobs"]) + 1, "jobs": original["jobs"]},
                     {"total_count": 0, "jobs": []},
                     {"total_count": len(original["jobs"]) + 1, "jobs": original["jobs"] + [original["jobs"][0]]}]
            for field, value in (("run_id", 7), ("run_attempt", 2), ("head_sha", "a" * 40), ("name", "unknown"),
                                 ("conclusion", "skipped"), ("conclusion", "failure"), ("status", "in_progress"),
                                 ("steps", []), ("steps", [{"name": "Set up job", "status": "completed", "conclusion": "success"}])):
                response = copy.deepcopy(original); response["jobs"][0][field] = value; cases.append(response)
            for response in cases:
                with self.subTest(workflow=workflow), patch.dict(self.responses, {key: response}), self.assertRaises(ValueError):
                    self.prove()

    def test_validation_step_missing_duplicate_or_skipped_is_not_job_success(self):
        for _, _, run_id, required in self.specs:
            key = self.jobs_path(run_id)
            for job_index in range(len(required)):
                for action in ("missing", "duplicate", "skipped", "failure"):
                    response = copy.deepcopy(self.responses[key]); steps = response["jobs"][job_index]["steps"]
                    if action == "missing":
                        steps.pop()
                    elif action == "duplicate":
                        steps.append(copy.deepcopy(steps[-1]))
                    else:
                        steps[-1]["conclusion"] = action
                    with patch.dict(self.responses, {key: response}), self.assertRaises(ValueError):
                        self.prove()

    def test_push_appearing_during_collection_is_not_hidden(self):
        key = self.index("preservation-service.yml", self.candidate)
        calls = 0

        def api(path):
            nonlocal calls
            if path == key:
                calls += 1
                if calls > 1:
                    return {"total_count": 1, "workflow_runs": [{"status": "queued"}]}
            return self.responses[path]

        with self.assertRaises(ValueError):
            self.prove(api=api)

    def test_actual_unexpanded_skipped_ios_matrix_names_are_not_executed_jobs(self):
        key = self.jobs_path(37913531658)
        job = self.responses[key]["jobs"][0]
        placeholders = [job | {"id": job["id"] + i + 10,
                        "name": "Sharing checks [${{ matrix.lane }}; scope ${{ needs.plan.outputs.runtime_scope }}]",
                        "conclusion": "skipped", "steps": []} for i in range(4)]
        response = {"total_count": 5, "jobs": [job] + placeholders}
        with patch.dict(self.responses, {key: response}):
            result = self.prove()
        self.assertEqual(len(result["workflows"]["ios-build.yml"]["jobs"]), 1)
        for field, value in (("id", job["id"]), ("conclusion", "success"), ("conclusion", "failure"),
                             ("steps", [{"name": "unexpected execution"}]), ("name", job["name"]),
                             ("name", "unknown duplicate")):
            changed = copy.deepcopy(response)
            for item in changed["jobs"][1:]:
                item[field] = value
            with self.subTest(field=field, value=value), patch.dict(self.responses, {key: changed}), self.assertRaises(ValueError):
                self.prove()

    def test_fixed_contract_is_conditional_and_ordinary_contract_unchanged(self):
        ordinary = planner.moderation_ai_durable_requirements("a" * 40)
        self.assertTrue(all(set(row) == {"workflow", "job", "head_sha", "event", "success_required"} for row in ordinary))
        fixed = planner.moderation_ai_durable_requirements(self.candidate)
        self.assertTrue(all("absent_push_reuse" not in row for row in fixed[:-1]))
        alternate = fixed[-1]["absent_push_reuse"]
        self.assertEqual((alternate["source_sha"], alternate["source_run_id"]), (self.source, 37911654217))
        self.assertTrue(alternate["verification_required"])
        self.assertFalse(alternate["same_candidate_sha"])
        self.assertIn("exactly absent Preservation push", planner.moderation_ai_durable_reason(self.candidate))
        self.assertNotIn("older push", planner.moderation_ai_durable_reason("a" * 40))


class ModerationAIDurableScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.MODERATION_AI_DURABLE_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {(planner.MODERATION_AI_DURABLE_WORKFLOW_BLOBS | planner.MODERATION_AI_DURABLE_MIGRATION_INPUT_BLOBS).get(path, 'unregistered')}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/moderation-ai-durable"})

    def test_exact_three_additions_require_five_backend_jobs_without_native_evidence(self):
        self.assertEqual([row[4] for row in self.rows().values()], ["A", "A", "A"])
        self.assertEqual(self.select(), planner.MODERATION_AI_DURABLE_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.MODERATION_AI_DURABLE_SCOPE),
                         planner.MODERATION_AI_DURABLE_JOBS)
        self.assertNotIn(planner.MODERATION_AI_DURABLE_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.MODERATION_AI_DURABLE_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.moderation_ai_durable_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "T"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in (*planner.MODERATION_AI_TRANSPORT_PATHS, *planner.MODERATION_AI_DURABLE_MIGRATION_INPUT_BLOBS, *planner.MODERATION_AI_PATHS, "NekoWidget/SharingService/src/moderation-operator-router.ts", "NekoWidget/SharingService/package-lock.json",
                        "NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc", "NekoWidget/PreservationService/src/request-json.ts",
                        "NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/moderation-ai-durable.md",
                        planner.MODERATION_AI_DURABLE_WORKFLOW, planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_AI_DURABLE_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "MODERATION_AI_DURABLE_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c" * 40, "d" * 40),
                     ("c", "d" * 40), ("0" * 40, "invalid"), ("0" * 40, "d" * 40, "extra")):
            with patch.object(planner, "MODERATION_AI_DURABLE_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(original), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/moderation-ai-durable.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.MODERATION_AI_DURABLE_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_AI_DURABLE_SCOPE),
                             planner.MODERATION_AI_DURABLE_JOBS)
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in planner.MODERATION_AI_DURABLE_WORKFLOW_BLOBS.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        original = planner.MODERATION_AI_DURABLE_WORKFLOW_BLOBS
        for path in original:
            with patch.object(planner, "MODERATION_AI_DURABLE_WORKFLOW_BLOBS", original | {path: "0" * 40}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)
        for invalid in ({}, {planner.MODERATION_AI_DURABLE_WORKFLOW: original[planner.MODERATION_AI_DURABLE_WORKFLOW]},
                        original | {planner.JPEG_WORKFLOW: "c" * 40}):
            with patch.object(planner, "MODERATION_AI_DURABLE_WORKFLOW_BLOBS", invalid):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/moderation-ai-durable", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.MODERATION_AI_DURABLE_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], list(planner.MODERATION_AI_DURABLE_JOBS))
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW if job == planner.PRESERVATION_JOB else planner.MODERATION_AI_DURABLE_WORKFLOW, "job": job,
                     "head_sha": self.head, "event": "push", "success_required": True}
                    for job in planner.MODERATION_AI_DURABLE_JOBS])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.MODERATION_AI_DURABLE_WORKFLOW, summary)
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("All five jobs", summary)
                self.assertIn("full local D1 migration chain", summary)
                self.assertIn("does not certify their success", summary)


    def test_existing_graph_runs_four_sharing_jobs_and_preservation_for_this_source(self):
        workflow = (Path(__file__).resolve().parents[2] / planner.MODERATION_AI_DURABLE_WORKFLOW).read_text()
        blocks = dict(re.findall(r"(?ms)^  ([a-z][a-z0-9-]*):\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)", workflow))
        ids = ("plan", "billing-verifier-check", "moderation-keygen-windows-policy", "check")
        self.assertEqual(tuple(re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1)
                               for name in ids), planner.MODERATION_AI_DURABLE_JOBS[:-1])
        self.assertEqual({re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1):
                          int(re.search(r"(?m)^    timeout-minutes: (\d+)$", blocks[name]).group(1))
                          for name in ids}, {job: timeout for job, timeout in planner.MODERATION_AI_DURABLE_JOB_TIMEOUTS.items()
                                            if job != planner.PRESERVATION_JOB})
        for name in ids[1:]:
            condition = re.search(r"(?m)^    if: (.+)$", blocks[name]).group(1)
            self.assertEqual("    if: " + condition,
                             planner.SHARING_FULL_CHECK_CONDITION + planner.SHARING_OPERATOR_GUARD)
            excluded = re.findall(r"needs.plan.outputs.scope != '([^']+)'", condition)
            self.assertNotIn(planner.MODERATION_AI_DURABLE_SCOPE, excluded)
        self.assertNotIn(planner.MODERATION_AI_DURABLE_SCOPE, blocks["private-billing-caller"])
        preservation = (Path(__file__).resolve().parents[2] / planner.PRESERVATION_WORKFLOW).read_text()
        self.assertIn('      - "NekoWidget/SharingService/src/**"', preservation)
        self.assertIn("    name: " + planner.PRESERVATION_JOB, preservation)
        self.assertIn("    timeout-minutes: 5", preservation)
        self.assertNotIn("    if:", preservation)
        self.assertEqual(planner.MODERATION_AI_DURABLE_JOBS[-1], planner.PRESERVATION_JOB)


    def test_migration_runner_inputs_require_exact_blobs_and_modes_at_both_ends(self):
        original = planner.MODERATION_AI_DURABLE_MIGRATION_INPUT_BLOBS
        for path, blob in original.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.ts"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
            with patch.object(planner, "MODERATION_AI_DURABLE_MIGRATION_INPUT_BLOBS", original | {path: "0" * 40}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)
            with patch.object(planner, "MODERATION_AI_DURABLE_MIGRATION_INPUT_BLOBS",
                              {key: value for key, value in original.items() if key != path}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)
        with patch.object(planner, "MODERATION_AI_DURABLE_MIGRATION_INPUT_BLOBS", original | {"other.ts": "c" * 40}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_owning_worker_job_applies_all_local_migrations_before_discovered_tests(self):
        root = Path(__file__).resolve().parents[2]
        service = root / "NekoWidget/SharingService"
        package = json.loads((service / "package.json").read_text())
        self.assertTrue(package["scripts"]["check"].endswith(" && npm test"))
        self.assertEqual(package["scripts"]["test"], "vitest run")
        config = (service / "vitest.config.ts").read_text()
        self.assertIn('await readD1Migrations(path.join(import.meta.dirname, "migrations"))', config)
        self.assertIn('TEST_MIGRATIONS: migrations', config)
        self.assertIn('include: ["test/**/*.test.ts"]', config)
        self.assertIn('setupFiles: ["./test/setup.ts"]', config)
        setup = (service / "test/setup.ts").read_text()
        self.assertIn('await applyD1Migrations(testEnv.DB, testEnv.TEST_MIGRATIONS);', setup)
        workflow = (root / planner.MODERATION_AI_DURABLE_WORKFLOW).read_text()
        block = re.search(r"(?ms)^  check:\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)", workflow).group(1)
        self.assertIn('    name: Typecheck, test, and bundle Worker', block)
        self.assertIn('        working-directory: NekoWidget/SharingService\n        shell: bash\n        run: npm run check', block)
        self.assertIn('NekoWidget/SharingService/migrations/0030_moderation_advisory_jobs.sql',
                      planner.MODERATION_AI_DURABLE_PATHS)
        self.assertIn('NekoWidget/SharingService/test/moderation-ai-durable.test.ts',
                      planner.MODERATION_AI_DURABLE_PATHS)


    def corrected_rows(self):
        return self.rows() | {path: [":100644", "100644", before, after, "M"]
                              for path, (before, after) in planner.MODERATION_AI_DURABLE_FIXTURE_BLOBS.items()}

    def test_exact_fixture_correction_retains_original_shape_scope_and_five_jobs(self):
        original, corrected = self.rows(), self.corrected_rows()
        self.assertEqual([row[4] for row in corrected.values()], ["A", "A", "A", "M", "M", "M"])
        for rows in (original, corrected):
            self.assertEqual(self.select(rows), planner.MODERATION_AI_DURABLE_SCOPE)
            self.assertEqual(planner.required_jobs(list(rows), planner.MODERATION_AI_DURABLE_SCOPE),
                             planner.MODERATION_AI_DURABLE_JOBS)
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            self.assertEqual(self.select(corrected | {"handoffs/correction.md": fields}),
                             planner.MODERATION_AI_DURABLE_SCOPE)
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"]):
            self.assertEqual(self.select(corrected | {"handoffs/correction.md": fields}), scope.FULL_SCOPE)

    def test_fixture_only_partial_unknown_modes_and_blobs_cannot_borrow_correction(self):
        corrected = self.corrected_rows()
        fixtures = list(planner.MODERATION_AI_DURABLE_FIXTURE_BLOBS)
        for mask in range(1, 7):
            subset = {path: corrected[path] for index, path in enumerate(fixtures) if mask & (1 << index)}
            self.assertEqual(self.select(subset), scope.FULL_SCOPE)
            self.assertEqual(self.select(self.rows() | subset), scope.FULL_SCOPE)
            self.assertEqual(planner.required_jobs(list(self.rows() | subset), planner.MODERATION_AI_DURABLE_SCOPE), planner.FULL)
        for path in planner.MODERATION_AI_DURABLE_PATHS:
            incomplete = {key: value for key, value in corrected.items() if key != path}
            self.assertEqual(self.select(incomplete), scope.FULL_SCOPE)
            self.assertEqual(planner.required_jobs(list(incomplete), planner.MODERATION_AI_DURABLE_SCOPE), planner.FULL)
        for fixture in fixtures:
            for index, value in ((0, ":000000"), (0, ":100755"), (1, "120000"), (1, "100755"),
                                 (2, "0" * 40), (2, "c" * 40), (3, "d" * 40),
                                 (4, "A"), (4, "D"), (4, "T"), (4, "R100")):
                changed = copy.deepcopy(corrected); changed[fixture][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (fixture, index, value))
        for unknown in ("NekoWidget/SharingService/scripts/other.node-tests.mjs",
                        "NekoWidget/ci/plan-ios-ci.py", *planner.MODERATION_AI_TRANSPORT_PATHS):
            changed = corrected | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_AI_DURABLE_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in corrected.items())
        fixture = fixtures[0]
        fixture_raw = " ".join(corrected[fixture]) + "\0" + fixture + "\0"
        self.assertEqual(self.select(raw=raw + fixture_raw, rows=corrected), scope.FULL_SCOPE)
        self.assertEqual(self.select(corrected, paths=list(corrected) + [fixture]), scope.FULL_SCOPE)

    def test_correction_still_requires_original_ancestry_and_fixed_execution_inputs(self):
        corrected = self.corrected_rows()
        self.assertEqual(self.select(corrected, ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(corrected, event="workflow_dispatch"), scope.FULL_SCOPE)
        for path in planner.MODERATION_AI_DURABLE_WORKFLOW_BLOBS | planner.MODERATION_AI_DURABLE_MIGRATION_INPUT_BLOBS:
            for revision in (self.base, self.head):
                self.assertEqual(self.select(corrected, workflows={(revision, path): ""}), scope.FULL_SCOPE)

    def test_invalid_fixture_registration_fails_closed_without_disabling_original_shape(self):
        corrected = self.corrected_rows()
        original = planner.MODERATION_AI_DURABLE_FIXTURE_BLOBS
        invalid_maps = [{}, {"other.mjs": ("c" * 40, "d" * 40)}]
        for fixture in original:
            invalid_maps.append({path: pair for path, pair in original.items() if path != fixture})
            invalid_maps.extend(original | {fixture: pair} for pair in (
                ("0" * 40, "d" * 40), ("c" * 40, "0" * 40), ("c" * 40, "c" * 40),
                ("bad", "d" * 40), ("c" * 40, "d" * 40, "extra")))
        for invalid in invalid_maps:
            with patch.object(planner, "MODERATION_AI_DURABLE_FIXTURE_BLOBS", invalid):
                self.assertEqual(self.select(corrected), scope.FULL_SCOPE)
                self.assertEqual(self.select(), planner.MODERATION_AI_DURABLE_SCOPE)


class ModerationEnrollmentCeremonyScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.MODERATION_ENROLLMENT_CEREMONY_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {(planner.MODERATION_ENROLLMENT_CEREMONY_WORKFLOW_BLOBS | planner.MODERATION_ENROLLMENT_CEREMONY_INPUT_BLOBS).get(path, 'unregistered')}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/operator-enrollment"})

    def test_exact_enrollment_product_batch_require_five_backend_jobs_without_native_evidence(self):
        self.assertEqual(len(self.rows()), 8)
        self.assertEqual(sum(row[4] == "M" for row in self.rows().values()), 3)
        self.assertEqual(sum(row[4] == "A" for row in self.rows().values()), 5)
        self.assertEqual(self.select(), planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE),
                         planner.MODERATION_ENROLLMENT_CEREMONY_JOBS)
        self.assertNotIn(planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.moderation_enrollment_ceremony_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "T"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in (*planner.MODERATION_AI_PATHS, "NekoWidget/SharingService/src/moderation-operator-router.ts", "NekoWidget/SharingService/package-lock.json",
                        "NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc", "NekoWidget/PreservationService/src/request-json.ts",
                        "NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/operator-enrollment.md",
                        planner.MODERATION_ENROLLMENT_CEREMONY_WORKFLOW, planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "MODERATION_ENROLLMENT_CEREMONY_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c" * 40, "d" * 40),
                     ("c", "d" * 40), ("0" * 40, "invalid"), ("0" * 40, "d" * 40, "extra")):
            with patch.object(planner, "MODERATION_ENROLLMENT_CEREMONY_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(original), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/operator-enrollment.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE),
                             planner.MODERATION_ENROLLMENT_CEREMONY_JOBS)
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in planner.MODERATION_ENROLLMENT_CEREMONY_WORKFLOW_BLOBS.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        original = planner.MODERATION_ENROLLMENT_CEREMONY_WORKFLOW_BLOBS
        for path in original:
            with patch.object(planner, "MODERATION_ENROLLMENT_CEREMONY_WORKFLOW_BLOBS", original | {path: "0" * 40}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)
        for invalid in ({}, {planner.MODERATION_ENROLLMENT_CEREMONY_WORKFLOW: original[planner.MODERATION_ENROLLMENT_CEREMONY_WORKFLOW]},
                        original | {planner.JPEG_WORKFLOW: "c" * 40}):
            with patch.object(planner, "MODERATION_ENROLLMENT_CEREMONY_WORKFLOW_BLOBS", invalid):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/operator-enrollment", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], list(planner.MODERATION_ENROLLMENT_CEREMONY_JOBS))
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW if job == planner.PRESERVATION_JOB else planner.MODERATION_ENROLLMENT_CEREMONY_WORKFLOW, "job": job,
                     "head_sha": self.head, "event": "push", "success_required": True}
                    for job in planner.MODERATION_ENROLLMENT_CEREMONY_JOBS])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.MODERATION_ENROLLMENT_CEREMONY_WORKFLOW, summary)
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("All five jobs", summary)
                self.assertIn("does not certify their success", summary)


    def test_existing_graph_runs_four_sharing_jobs_and_preservation_for_this_source(self):
        workflow = (Path(__file__).resolve().parents[2] / planner.MODERATION_ENROLLMENT_CEREMONY_WORKFLOW).read_text()
        blocks = dict(re.findall(r"(?ms)^  ([a-z][a-z0-9-]*):\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)", workflow))
        ids = ("plan", "billing-verifier-check", "moderation-keygen-windows-policy", "check")
        self.assertEqual(tuple(re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1)
                               for name in ids), planner.MODERATION_ENROLLMENT_CEREMONY_JOBS[:-1])
        self.assertEqual({re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1):
                          int(re.search(r"(?m)^    timeout-minutes: (\d+)$", blocks[name]).group(1))
                          for name in ids}, {job: timeout for job, timeout in planner.MODERATION_ENROLLMENT_CEREMONY_JOB_TIMEOUTS.items()
                                            if job != planner.PRESERVATION_JOB})
        for name in ids[1:]:
            condition = re.search(r"(?m)^    if: (.+)$", blocks[name]).group(1)
            self.assertEqual("    if: " + condition,
                             planner.SHARING_FULL_CHECK_CONDITION + planner.SHARING_OPERATOR_GUARD)
            excluded = re.findall(r"needs.plan.outputs.scope != '([^']+)'", condition)
            self.assertNotIn(planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE, excluded)
        self.assertNotIn(planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE, blocks["private-billing-caller"])
        preservation = (Path(__file__).resolve().parents[2] / planner.PRESERVATION_WORKFLOW).read_text()
        self.assertIn('      - "NekoWidget/SharingService/src/**"', preservation)
        self.assertIn('      - "NekoWidget/SharingService/migrations/**"', preservation)
        self.assertIn("    name: " + planner.PRESERVATION_JOB, preservation)
        self.assertIn("    timeout-minutes: 5", preservation)
        self.assertNotIn("    if:", preservation)
        self.assertEqual(planner.MODERATION_ENROLLMENT_CEREMONY_JOBS[-1], planner.PRESERVATION_JOB)


    def test_crypto_public_disabled_entrypoints_and_test_inputs_are_fixed_at_both_ends(self):
        original = planner.MODERATION_ENROLLMENT_CEREMONY_INPUT_BLOBS
        for path, blob in original.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
            for replacement in ({key: value for key, value in original.items() if key != path},
                                original | {path: "0" * 40}, original | {"other.ts": "c" * 40}):
                with patch.object(planner, "MODERATION_ENROLLMENT_CEREMONY_INPUT_BLOBS", replacement):
                    self.assertEqual(self.select(), scope.FULL_SCOPE)


    def test_worker_and_windows_checks_cover_signature_migration_and_privacy_inputs(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / planner.MODERATION_ENROLLMENT_CEREMONY_WORKFLOW).read_text()
        self.assertIn("run: npm run check", workflow)
        self.assertIn("npm run check:moderation-tool", workflow)
        config = (root / "NekoWidget/SharingService/vitest.config.ts").read_text()
        setup = (root / "NekoWidget/SharingService/test/setup.ts").read_text()
        self.assertIn('readD1Migrations(path.join(import.meta.dirname, "migrations"))', config)
        self.assertIn('test/**/*.test.ts', config)
        self.assertIn('applyD1Migrations(testEnv.DB, testEnv.TEST_MIGRATIONS)', setup)
        for suffix in ("migrations/0033_moderation_operator_enrollment_ceremony.sql", "scripts/staging-config.node-tests.mjs",
                       "scripts/billing-sponsorship-local-drill.mjs", "test/billing-sponsorship-local-drill.node-tests.mjs",
                       "test/moderation-operator-enrollment-canonical.test.ts", "test/moderation-operator-enrollment-ceremony.test.ts"):
            self.assertIn("NekoWidget/SharingService/" + suffix, planner.MODERATION_ENROLLMENT_CEREMONY_PATHS)
        package = json.loads((root / "NekoWidget/SharingService/package.json").read_text())
        for command in ("npm run typecheck", "npm run check:moderation-operator-enrollment-trust",
                        "npm run check:moderation-operator-control-plane", "npm run check:moderation-operator-routes",
                        "npm run check:moderation-operator-webauthn-dependency", "npm run check:staging-config",
                        "npm run check:billing-sponsorship-local-drill", "npm test"):
            self.assertIn(command, package["scripts"]["check"])
        self.assertEqual(planner.moderation_enrollment_ceremony_requirements(planner.MODERATION_AI_DURABLE_REUSE_CANDIDATE), [
            {"workflow": planner.PRESERVATION_WORKFLOW if job == planner.PRESERVATION_JOB else planner.MODERATION_ENROLLMENT_CEREMONY_WORKFLOW,
             "job": job, "head_sha": planner.MODERATION_AI_DURABLE_REUSE_CANDIDATE, "event": "push", "success_required": True}
            for job in planner.MODERATION_ENROLLMENT_CEREMONY_JOBS])


class ModerationOperatorHostScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.MODERATION_OPERATOR_HOST_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {(planner.MODERATION_OPERATOR_HOST_WORKFLOW_BLOBS | planner.MODERATION_OPERATOR_HOST_INPUT_BLOBS).get(path, 'unregistered')}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/initial-admission"})


    def test_exact_host_shape_and_required_owning_jobs(self):
        self.assertEqual(len(self.rows()),3)
        self.assertEqual(sum(row[4]=='M' for row in self.rows().values()),1)
        self.assertEqual(self.select(),planner.MODERATION_OPERATOR_HOST_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()),planner.MODERATION_OPERATOR_HOST_SCOPE),planner.MODERATION_OPERATOR_HOST_JOBS)
        self.assertNotIn(planner.MODERATION_OPERATOR_HOST_SCOPE,scope.SCOPES)
        expected=[{'workflow':planner.PRESERVATION_WORKFLOW if job==planner.PRESERVATION_JOB else planner.MODERATION_OPERATOR_HOST_WORKFLOW,'job':job,'head_sha':self.head,'event':'push','success_required':True} for job in planner.MODERATION_OPERATOR_HOST_JOBS]
        self.assertEqual(planner.moderation_operator_host_requirements(self.head),expected)

    def test_partial_unknown_duplicate_and_product_control_mix_are_full(self):
        rows=self.rows()
        for path in rows:
            self.assertEqual(self.select({p:r for p,r in rows.items() if p!=path}), 'full-v1')
        for path in ('NekoWidget/NekoWidget/ContentView.swift','NekoWidget/ci/preflight-ci.py','NekoWidget/SharingService/src/index.ts'):
            self.assertEqual(self.select(rows|{path:[':100644','100644','c'*40,'d'*40,'M']}),'full-v1')
        self.assertEqual(self.select(paths=list(rows)+[next(iter(rows))]),'full-v1')

    def test_modes_types_before_after_blobs_and_ancestry_fail_closed(self):
        for path,row in self.rows().items():
            for index,value in ((0,':100755'),(1,'100755'),(1,'120000'),(2,'e'*40),(3,'f'*40),(4,'D')):
                changed=self.rows();changed[path]=row.copy();changed[path][index]=value
                self.assertEqual(self.select(changed),'full-v1')
        self.assertEqual(self.select(ancestor=False),'full-v1')

    def test_all_auth_public_migration_config_and_workflow_inputs_are_pinned(self):
        for path in planner.MODERATION_OPERATOR_HOST_INPUT_BLOBS|planner.MODERATION_OPERATOR_HOST_WORKFLOW_BLOBS:
            for revision in (self.base,self.head):
                drift={(revision,path):f'100644 blob {"f"*40}\t{path}'}
                self.assertEqual(self.select(workflows=drift),'full-v1')

    def test_raw_duplicate_malformed_and_handoff_boundaries(self):
        rows=self.rows();raw=''.join(' '.join(r)+'\0'+p+'\0' for p,r in rows.items())
        self.assertEqual(self.select(raw=raw+raw),'full-v1')
        self.assertEqual(self.select(raw=raw+'not a raw record\0'),'full-v1')
        for status in ('A','M'):
            changed=rows|{'handoffs/2026-10-10-local-operator-host.md':[':000000' if status=='A' else ':100644','100644','0'*40 if status=='A' else 'c'*40,'d'*40,status]}
            self.assertEqual(self.select(changed),planner.MODERATION_OPERATOR_HOST_SCOPE)


class ModerationOperatorStartupScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.MODERATION_OPERATOR_STARTUP_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {(planner.MODERATION_OPERATOR_STARTUP_WORKFLOW_BLOBS | planner.MODERATION_OPERATOR_STARTUP_INPUT_BLOBS).get(path, 'unregistered')}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/initial-admission"})


    def test_exact_host_shape_and_required_owning_jobs(self):
        self.assertEqual(len(self.rows()),5)
        self.assertEqual(sum(row[4]=='M' for row in self.rows().values()),1)
        self.assertEqual(self.select(),planner.MODERATION_OPERATOR_STARTUP_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()),planner.MODERATION_OPERATOR_STARTUP_SCOPE),planner.MODERATION_OPERATOR_STARTUP_JOBS)
        self.assertNotIn(planner.MODERATION_OPERATOR_STARTUP_SCOPE,scope.SCOPES)
        expected=[{'workflow':planner.PRESERVATION_WORKFLOW if job==planner.PRESERVATION_JOB else planner.MODERATION_OPERATOR_STARTUP_WORKFLOW,'job':job,'head_sha':self.head,'event':'push','success_required':True} for job in planner.MODERATION_OPERATOR_STARTUP_JOBS]
        self.assertEqual(planner.moderation_operator_startup_requirements(self.head),expected)

    def test_partial_unknown_duplicate_and_product_control_mix_are_full(self):
        rows=self.rows()
        for path in rows:
            self.assertEqual(self.select({p:r for p,r in rows.items() if p!=path}), 'full-v1')
        for path in ('NekoWidget/NekoWidget/ContentView.swift','NekoWidget/ci/preflight-ci.py','NekoWidget/SharingService/src/index.ts'):
            self.assertEqual(self.select(rows|{path:[':100644','100644','c'*40,'d'*40,'M']}),'full-v1')
        self.assertEqual(self.select(paths=list(rows)+[next(iter(rows))]),'full-v1')

    def test_modes_types_before_after_blobs_and_ancestry_fail_closed(self):
        for path,row in self.rows().items():
            for index,value in ((0,':100755'),(1,'100755'),(1,'120000'),(2,'e'*40),(3,'f'*40),(4,'D')):
                changed=self.rows();changed[path]=row.copy();changed[path][index]=value
                self.assertEqual(self.select(changed),'full-v1')
        self.assertEqual(self.select(ancestor=False),'full-v1')

    def test_all_auth_public_migration_config_and_workflow_inputs_are_pinned(self):
        for path in planner.MODERATION_OPERATOR_STARTUP_INPUT_BLOBS|planner.MODERATION_OPERATOR_STARTUP_WORKFLOW_BLOBS:
            for revision in (self.base,self.head):
                drift={(revision,path):f'100644 blob {"f"*40}\t{path}'}
                self.assertEqual(self.select(workflows=drift),'full-v1')

    def test_raw_duplicate_malformed_and_handoff_boundaries(self):
        rows=self.rows();raw=''.join(' '.join(r)+'\0'+p+'\0' for p,r in rows.items())
        self.assertEqual(self.select(raw=raw+raw),'full-v1')
        self.assertEqual(self.select(raw=raw+'not a raw record\0'),'full-v1')
        for status in ('A','M'):
            changed=rows|{'handoffs/2026-10-10-operator-local-startup.md':[':000000' if status=='A' else ':100644','100644','0'*40 if status=='A' else 'c'*40,'d'*40,status]}
            self.assertEqual(self.select(changed),planner.MODERATION_OPERATOR_STARTUP_SCOPE)


class ModerationInitialAdmissionScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.MODERATION_INITIAL_ADMISSION_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {(planner.MODERATION_INITIAL_ADMISSION_WORKFLOW_BLOBS | planner.MODERATION_INITIAL_ADMISSION_INPUT_BLOBS).get(path, 'unregistered')}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/initial-admission"})

    def test_exact_enrollment_product_batch_require_five_backend_jobs_without_native_evidence(self):
        self.assertEqual(len(self.rows()), 10)
        self.assertEqual(sum(row[4] == "M" for row in self.rows().values()), 3)
        self.assertEqual(sum(row[4] == "A" for row in self.rows().values()), 7)
        self.assertEqual(self.select(), planner.MODERATION_INITIAL_ADMISSION_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.MODERATION_INITIAL_ADMISSION_SCOPE),
                         planner.MODERATION_INITIAL_ADMISSION_JOBS)
        self.assertNotIn(planner.MODERATION_INITIAL_ADMISSION_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.MODERATION_INITIAL_ADMISSION_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.moderation_initial_admission_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "T"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in (*planner.MODERATION_AI_PATHS, "NekoWidget/SharingService/src/moderation-operator-router.ts", "NekoWidget/SharingService/package-lock.json",
                        "NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc", "NekoWidget/PreservationService/src/request-json.ts",
                        "NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/operator-enrollment.md",
                        planner.MODERATION_INITIAL_ADMISSION_WORKFLOW, planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_INITIAL_ADMISSION_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "MODERATION_INITIAL_ADMISSION_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c" * 40, "d" * 40),
                     ("c", "d" * 40), ("0" * 40, "invalid"), ("0" * 40, "d" * 40, "extra")):
            with patch.object(planner, "MODERATION_INITIAL_ADMISSION_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(original), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/operator-admission.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.MODERATION_INITIAL_ADMISSION_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_INITIAL_ADMISSION_SCOPE),
                             planner.MODERATION_INITIAL_ADMISSION_JOBS)
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in planner.MODERATION_INITIAL_ADMISSION_WORKFLOW_BLOBS.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        original = planner.MODERATION_INITIAL_ADMISSION_WORKFLOW_BLOBS
        for path in original:
            with patch.object(planner, "MODERATION_INITIAL_ADMISSION_WORKFLOW_BLOBS", original | {path: "0" * 40}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)
        for invalid in ({}, {planner.MODERATION_INITIAL_ADMISSION_WORKFLOW: original[planner.MODERATION_INITIAL_ADMISSION_WORKFLOW]},
                        original | {planner.JPEG_WORKFLOW: "c" * 40}):
            with patch.object(planner, "MODERATION_INITIAL_ADMISSION_WORKFLOW_BLOBS", invalid):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/initial-admission", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.MODERATION_INITIAL_ADMISSION_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], list(planner.MODERATION_INITIAL_ADMISSION_JOBS))
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW if job == planner.PRESERVATION_JOB else planner.MODERATION_INITIAL_ADMISSION_WORKFLOW, "job": job,
                     "head_sha": self.head, "event": "push", "success_required": True}
                    for job in planner.MODERATION_INITIAL_ADMISSION_JOBS])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.MODERATION_INITIAL_ADMISSION_WORKFLOW, summary)
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("All five jobs", summary)
                self.assertIn("does not certify their success", summary)


    def test_existing_graph_runs_four_sharing_jobs_and_preservation_for_this_source(self):
        workflow = (Path(__file__).resolve().parents[2] / planner.MODERATION_INITIAL_ADMISSION_WORKFLOW).read_text()
        blocks = dict(re.findall(r"(?ms)^  ([a-z][a-z0-9-]*):\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)", workflow))
        ids = ("plan", "billing-verifier-check", "moderation-keygen-windows-policy", "check")
        self.assertEqual(tuple(re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1)
                               for name in ids), planner.MODERATION_INITIAL_ADMISSION_JOBS[:-1])
        self.assertEqual({re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1):
                          int(re.search(r"(?m)^    timeout-minutes: (\d+)$", blocks[name]).group(1))
                          for name in ids}, {job: timeout for job, timeout in planner.MODERATION_INITIAL_ADMISSION_JOB_TIMEOUTS.items()
                                            if job != planner.PRESERVATION_JOB})
        for name in ids[1:]:
            condition = re.search(r"(?m)^    if: (.+)$", blocks[name]).group(1)
            self.assertEqual("    if: " + condition,
                             planner.SHARING_FULL_CHECK_CONDITION + planner.SHARING_OPERATOR_GUARD)
            excluded = re.findall(r"needs.plan.outputs.scope != '([^']+)'", condition)
            self.assertNotIn(planner.MODERATION_INITIAL_ADMISSION_SCOPE, excluded)
        self.assertNotIn(planner.MODERATION_INITIAL_ADMISSION_SCOPE, blocks["private-billing-caller"])
        preservation = (Path(__file__).resolve().parents[2] / planner.PRESERVATION_WORKFLOW).read_text()
        self.assertIn('      - "NekoWidget/SharingService/src/**"', preservation)
        self.assertIn('      - "NekoWidget/SharingService/migrations/**"', preservation)
        self.assertIn("    name: " + planner.PRESERVATION_JOB, preservation)
        self.assertIn("    timeout-minutes: 5", preservation)
        self.assertNotIn("    if:", preservation)
        self.assertEqual(planner.MODERATION_INITIAL_ADMISSION_JOBS[-1], planner.PRESERVATION_JOB)


    def test_crypto_public_disabled_entrypoints_and_test_inputs_are_fixed_at_both_ends(self):
        original = planner.MODERATION_INITIAL_ADMISSION_INPUT_BLOBS
        for path, blob in original.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
            for replacement in ({key: value for key, value in original.items() if key != path},
                                original | {path: "0" * 40}, original | {"other.ts": "c" * 40}):
                with patch.object(planner, "MODERATION_INITIAL_ADMISSION_INPUT_BLOBS", replacement):
                    self.assertEqual(self.select(), scope.FULL_SCOPE)


    def test_worker_and_windows_checks_cover_signature_migration_and_privacy_inputs(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / planner.MODERATION_INITIAL_ADMISSION_WORKFLOW).read_text()
        self.assertIn("run: npm run check", workflow)
        self.assertIn("npm run check:moderation-tool", workflow)
        config = (root / "NekoWidget/SharingService/vitest.config.ts").read_text()
        setup = (root / "NekoWidget/SharingService/test/setup.ts").read_text()
        self.assertIn('readD1Migrations(path.join(import.meta.dirname, "migrations"))', config)
        self.assertIn('test/**/*.test.ts', config)
        self.assertIn('applyD1Migrations(testEnv.DB, testEnv.TEST_MIGRATIONS)', setup)
        for suffix in ("migrations/0034_moderation_operator_initial_admission.sql", "scripts/staging-config.node-tests.mjs",
                       "scripts/billing-sponsorship-local-drill.mjs", "test/billing-sponsorship-local-drill.node-tests.mjs",
                       "test/moderation-operator-enrollment-admission.test.ts", "test/moderation-operator-enrollment-local.test.ts"):
            self.assertIn("NekoWidget/SharingService/" + suffix, planner.MODERATION_INITIAL_ADMISSION_PATHS)
        package = json.loads((root / "NekoWidget/SharingService/package.json").read_text())
        for command in ("npm run typecheck", "npm run check:moderation-operator-enrollment-trust",
                        "npm run check:moderation-operator-control-plane", "npm run check:moderation-operator-routes",
                        "npm run check:moderation-operator-webauthn-dependency", "npm run check:staging-config",
                        "npm run check:billing-sponsorship-local-drill", "npm test"):
            self.assertIn(command, package["scripts"]["check"])
        self.assertEqual(planner.moderation_initial_admission_requirements(planner.MODERATION_AI_DURABLE_REUSE_CANDIDATE), [
            {"workflow": planner.PRESERVATION_WORKFLOW if job == planner.PRESERVATION_JOB else planner.MODERATION_INITIAL_ADMISSION_WORKFLOW,
             "job": job, "head_sha": planner.MODERATION_AI_DURABLE_REUSE_CANDIDATE, "event": "push", "success_required": True}
            for job in planner.MODERATION_INITIAL_ADMISSION_JOBS])


class ModerationOwnerFlowScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.MODERATION_OWNER_FLOW_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {(planner.MODERATION_OWNER_FLOW_WORKFLOW_BLOBS | planner.MODERATION_OWNER_FLOW_INPUT_BLOBS).get(path, 'unregistered')}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/moderation-owner-flow"})

    def test_exact_owner_product_batch_require_five_backend_jobs_without_native_evidence(self):
        self.assertEqual(len(self.rows()), 18)
        self.assertEqual(sum(row[4] == "M" for row in self.rows().values()), 7)
        self.assertEqual(sum(row[4] == "A" for row in self.rows().values()), 11)
        self.assertEqual(self.select(), planner.MODERATION_OWNER_FLOW_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.MODERATION_OWNER_FLOW_SCOPE),
                         planner.MODERATION_OWNER_FLOW_JOBS)
        self.assertNotIn(planner.MODERATION_OWNER_FLOW_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.MODERATION_OWNER_FLOW_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.moderation_owner_flow_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "T"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in (*planner.MODERATION_AI_PATHS, "NekoWidget/SharingService/src/moderation-operator-router.ts", "NekoWidget/SharingService/package-lock.json",
                        "NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc", "NekoWidget/PreservationService/src/request-json.ts",
                        "NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/moderation-owner-flow.md",
                        planner.MODERATION_OWNER_FLOW_WORKFLOW, planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_OWNER_FLOW_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "MODERATION_OWNER_FLOW_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c" * 40, "d" * 40),
                     ("c", "d" * 40), ("0" * 40, "invalid"), ("0" * 40, "d" * 40, "extra")):
            with patch.object(planner, "MODERATION_OWNER_FLOW_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(original), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/moderation-owner-flow.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.MODERATION_OWNER_FLOW_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_OWNER_FLOW_SCOPE),
                             planner.MODERATION_OWNER_FLOW_JOBS)
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in planner.MODERATION_OWNER_FLOW_WORKFLOW_BLOBS.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        original = planner.MODERATION_OWNER_FLOW_WORKFLOW_BLOBS
        for path in original:
            with patch.object(planner, "MODERATION_OWNER_FLOW_WORKFLOW_BLOBS", original | {path: "0" * 40}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)
        for invalid in ({}, {planner.MODERATION_OWNER_FLOW_WORKFLOW: original[planner.MODERATION_OWNER_FLOW_WORKFLOW]},
                        original | {planner.JPEG_WORKFLOW: "c" * 40}):
            with patch.object(planner, "MODERATION_OWNER_FLOW_WORKFLOW_BLOBS", invalid):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/moderation-owner-flow", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.MODERATION_OWNER_FLOW_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], list(planner.MODERATION_OWNER_FLOW_JOBS))
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW if job == planner.PRESERVATION_JOB else planner.MODERATION_OWNER_FLOW_WORKFLOW, "job": job,
                     "head_sha": self.head, "event": "push", "success_required": True}
                    for job in planner.MODERATION_OWNER_FLOW_JOBS])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.MODERATION_OWNER_FLOW_WORKFLOW, summary)
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("All five jobs", summary)
                self.assertIn("does not certify their success", summary)


    def test_existing_graph_runs_four_sharing_jobs_and_preservation_for_this_source(self):
        workflow = (Path(__file__).resolve().parents[2] / planner.MODERATION_OWNER_FLOW_WORKFLOW).read_text()
        blocks = dict(re.findall(r"(?ms)^  ([a-z][a-z0-9-]*):\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)", workflow))
        ids = ("plan", "billing-verifier-check", "moderation-keygen-windows-policy", "check")
        self.assertEqual(tuple(re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1)
                               for name in ids), planner.MODERATION_OWNER_FLOW_JOBS[:-1])
        self.assertEqual({re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1):
                          int(re.search(r"(?m)^    timeout-minutes: (\d+)$", blocks[name]).group(1))
                          for name in ids}, {job: timeout for job, timeout in planner.MODERATION_OWNER_FLOW_JOB_TIMEOUTS.items()
                                            if job != planner.PRESERVATION_JOB})
        for name in ids[1:]:
            condition = re.search(r"(?m)^    if: (.+)$", blocks[name]).group(1)
            self.assertEqual("    if: " + condition,
                             planner.SHARING_FULL_CHECK_CONDITION + planner.SHARING_OPERATOR_GUARD)
            excluded = re.findall(r"needs.plan.outputs.scope != '([^']+)'", condition)
            self.assertNotIn(planner.MODERATION_OWNER_FLOW_SCOPE, excluded)
        self.assertNotIn(planner.MODERATION_OWNER_FLOW_SCOPE, blocks["private-billing-caller"])
        preservation = (Path(__file__).resolve().parents[2] / planner.PRESERVATION_WORKFLOW).read_text()
        self.assertIn('      - "NekoWidget/SharingService/src/**"', preservation)
        self.assertIn("    name: " + planner.PRESERVATION_JOB, preservation)
        self.assertIn("    timeout-minutes: 5", preservation)
        self.assertNotIn("    if:", preservation)
        self.assertEqual(planner.MODERATION_OWNER_FLOW_JOBS[-1], planner.PRESERVATION_JOB)


    def test_crypto_public_disabled_entrypoints_and_test_inputs_are_fixed_at_both_ends(self):
        original = planner.MODERATION_OWNER_FLOW_INPUT_BLOBS
        for path, blob in original.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
            for replacement in ({key: value for key, value in original.items() if key != path},
                                original | {path: "0" * 40}, original | {"other.ts": "c" * 40}):
                with patch.object(planner, "MODERATION_OWNER_FLOW_INPUT_BLOBS", replacement):
                    self.assertEqual(self.select(), scope.FULL_SCOPE)


    def test_worker_and_windows_checks_cover_migration_inventory_and_isolated_host(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / planner.MODERATION_OWNER_FLOW_WORKFLOW).read_text()
        self.assertIn("run: npm run check", workflow)
        self.assertIn("npm run check:moderation-tool", workflow)
        config = (root / "NekoWidget/SharingService/vitest.config.ts").read_text()
        setup = (root / "NekoWidget/SharingService/test/setup.ts").read_text()
        self.assertIn('readD1Migrations(path.join(import.meta.dirname, "migrations"))', config)
        self.assertIn('test/**/*.test.ts', config)
        self.assertIn('applyD1Migrations(testEnv.DB, testEnv.TEST_MIGRATIONS)', setup)
        for suffix in ("migrations/0031_moderation_owner_flow.sql", "scripts/staging-config.node-tests.mjs",
                       "scripts/billing-sponsorship-local-drill.mjs", "test/billing-sponsorship-local-drill.node-tests.mjs",
                       "test/moderation-owner-flow.test.ts", "test/moderation-owner.integration.test.ts",
                       "test/moderation-owner-review-host.node-tests.mjs"):
            self.assertIn("NekoWidget/SharingService/" + suffix, planner.MODERATION_OWNER_FLOW_PATHS)
        self.assertEqual(planner.moderation_owner_flow_requirements(planner.MODERATION_AI_DURABLE_REUSE_CANDIDATE), [
            {"workflow": planner.PRESERVATION_WORKFLOW if job == planner.PRESERVATION_JOB else planner.MODERATION_OWNER_FLOW_WORKFLOW,
             "job": job, "head_sha": planner.MODERATION_AI_DURABLE_REUSE_CANDIDATE, "event": "push", "success_required": True}
            for job in planner.MODERATION_OWNER_FLOW_JOBS])


class ModerationReviewEvidenceScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.MODERATION_REVIEW_EVIDENCE_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {(planner.MODERATION_REVIEW_EVIDENCE_WORKFLOW_BLOBS | planner.MODERATION_REVIEW_EVIDENCE_INPUT_BLOBS).get(path, 'unregistered')}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/moderation-review-evidence"})

    def test_exact_package_edit_and_four_additions_require_five_backend_jobs_without_native_evidence(self):
        self.assertEqual([row[4] for row in self.rows().values()], ["M", "A", "A", "A", "A"])
        self.assertEqual(self.select(), planner.MODERATION_REVIEW_EVIDENCE_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.MODERATION_REVIEW_EVIDENCE_SCOPE),
                         planner.MODERATION_REVIEW_EVIDENCE_JOBS)
        self.assertNotIn(planner.MODERATION_REVIEW_EVIDENCE_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.MODERATION_REVIEW_EVIDENCE_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.moderation_review_evidence_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "T"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in (*planner.MODERATION_AI_PATHS, "NekoWidget/SharingService/src/moderation-operator-router.ts", "NekoWidget/SharingService/package-lock.json",
                        "NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc", "NekoWidget/PreservationService/src/request-json.ts",
                        "NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/moderation-review-evidence.md",
                        planner.MODERATION_REVIEW_EVIDENCE_WORKFLOW, planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_REVIEW_EVIDENCE_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "MODERATION_REVIEW_EVIDENCE_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c" * 40, "d" * 40),
                     ("c", "d" * 40), ("0" * 40, "invalid"), ("0" * 40, "d" * 40, "extra")):
            with patch.object(planner, "MODERATION_REVIEW_EVIDENCE_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(original), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/moderation-review-evidence.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.MODERATION_REVIEW_EVIDENCE_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_REVIEW_EVIDENCE_SCOPE),
                             planner.MODERATION_REVIEW_EVIDENCE_JOBS)
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in planner.MODERATION_REVIEW_EVIDENCE_WORKFLOW_BLOBS.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        original = planner.MODERATION_REVIEW_EVIDENCE_WORKFLOW_BLOBS
        for path in original:
            with patch.object(planner, "MODERATION_REVIEW_EVIDENCE_WORKFLOW_BLOBS", original | {path: "0" * 40}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)
        for invalid in ({}, {planner.MODERATION_REVIEW_EVIDENCE_WORKFLOW: original[planner.MODERATION_REVIEW_EVIDENCE_WORKFLOW]},
                        original | {planner.JPEG_WORKFLOW: "c" * 40}):
            with patch.object(planner, "MODERATION_REVIEW_EVIDENCE_WORKFLOW_BLOBS", invalid):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/moderation-review-evidence", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.MODERATION_REVIEW_EVIDENCE_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], list(planner.MODERATION_REVIEW_EVIDENCE_JOBS))
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW if job == planner.PRESERVATION_JOB else planner.MODERATION_REVIEW_EVIDENCE_WORKFLOW, "job": job,
                     "head_sha": self.head, "event": "push", "success_required": True}
                    for job in planner.MODERATION_REVIEW_EVIDENCE_JOBS])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.MODERATION_REVIEW_EVIDENCE_WORKFLOW, summary)
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("All five jobs", summary)
                self.assertIn("does not certify their success", summary)


    def test_existing_graph_runs_four_sharing_jobs_and_preservation_for_this_source(self):
        workflow = (Path(__file__).resolve().parents[2] / planner.MODERATION_REVIEW_EVIDENCE_WORKFLOW).read_text()
        blocks = dict(re.findall(r"(?ms)^  ([a-z][a-z0-9-]*):\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)", workflow))
        ids = ("plan", "billing-verifier-check", "moderation-keygen-windows-policy", "check")
        self.assertEqual(tuple(re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1)
                               for name in ids), planner.MODERATION_REVIEW_EVIDENCE_JOBS[:-1])
        self.assertEqual({re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1):
                          int(re.search(r"(?m)^    timeout-minutes: (\d+)$", blocks[name]).group(1))
                          for name in ids}, {job: timeout for job, timeout in planner.MODERATION_REVIEW_EVIDENCE_JOB_TIMEOUTS.items()
                                            if job != planner.PRESERVATION_JOB})
        for name in ids[1:]:
            condition = re.search(r"(?m)^    if: (.+)$", blocks[name]).group(1)
            self.assertEqual("    if: " + condition,
                             planner.SHARING_FULL_CHECK_CONDITION + planner.SHARING_OPERATOR_GUARD)
            excluded = re.findall(r"needs.plan.outputs.scope != '([^']+)'", condition)
            self.assertNotIn(planner.MODERATION_REVIEW_EVIDENCE_SCOPE, excluded)
        self.assertNotIn(planner.MODERATION_REVIEW_EVIDENCE_SCOPE, blocks["private-billing-caller"])
        preservation = (Path(__file__).resolve().parents[2] / planner.PRESERVATION_WORKFLOW).read_text()
        self.assertIn('      - "NekoWidget/SharingService/src/**"', preservation)
        self.assertIn("    name: " + planner.PRESERVATION_JOB, preservation)
        self.assertIn("    timeout-minutes: 5", preservation)
        self.assertNotIn("    if:", preservation)
        self.assertEqual(planner.MODERATION_REVIEW_EVIDENCE_JOBS[-1], planner.PRESERVATION_JOB)


    def test_crypto_public_disabled_entrypoints_and_test_inputs_are_fixed_at_both_ends(self):
        original = planner.MODERATION_REVIEW_EVIDENCE_INPUT_BLOBS
        for path, blob in original.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
            for replacement in ({key: value for key, value in original.items() if key != path},
                                original | {path: "0" * 40}, original | {"other.ts": "c" * 40}):
                with patch.object(planner, "MODERATION_REVIEW_EVIDENCE_INPUT_BLOBS", replacement):
                    self.assertEqual(self.select(), scope.FULL_SCOPE)


class ModerationConsoleScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.MODERATION_CONSOLE_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {(planner.MODERATION_CONSOLE_WORKFLOW_BLOBS | planner.MODERATION_CONSOLE_INPUT_BLOBS).get(path, 'unregistered')}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/moderation-console"})

    def test_exact_addition_and_two_edits_require_five_backend_jobs_without_native_evidence(self):
        self.assertEqual([row[4] for row in self.rows().values()], ["A", "M", "M"])
        self.assertEqual(self.select(), planner.MODERATION_CONSOLE_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.MODERATION_CONSOLE_SCOPE),
                         planner.MODERATION_CONSOLE_JOBS)
        self.assertNotIn(planner.MODERATION_CONSOLE_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.MODERATION_CONSOLE_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.moderation_console_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "T"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in (*planner.MODERATION_AI_PATHS, "NekoWidget/SharingService/src/moderation-operator-router.ts", "NekoWidget/SharingService/package-lock.json",
                        "NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc", "NekoWidget/PreservationService/src/request-json.ts",
                        "NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/moderation-console.md",
                        planner.MODERATION_CONSOLE_WORKFLOW, planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_CONSOLE_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "MODERATION_CONSOLE_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c" * 40, "d" * 40),
                     ("c", "d" * 40), ("0" * 40, "invalid"), ("0" * 40, "d" * 40, "extra")):
            with patch.object(planner, "MODERATION_CONSOLE_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(original), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/moderation-console.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.MODERATION_CONSOLE_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_CONSOLE_SCOPE),
                             planner.MODERATION_CONSOLE_JOBS)
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in planner.MODERATION_CONSOLE_WORKFLOW_BLOBS.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        original = planner.MODERATION_CONSOLE_WORKFLOW_BLOBS
        for path in original:
            with patch.object(planner, "MODERATION_CONSOLE_WORKFLOW_BLOBS", original | {path: "0" * 40}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)
        for invalid in ({}, {planner.MODERATION_CONSOLE_WORKFLOW: original[planner.MODERATION_CONSOLE_WORKFLOW]},
                        original | {planner.JPEG_WORKFLOW: "c" * 40}):
            with patch.object(planner, "MODERATION_CONSOLE_WORKFLOW_BLOBS", invalid):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/moderation-console", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.MODERATION_CONSOLE_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], list(planner.MODERATION_CONSOLE_JOBS))
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW if job == planner.PRESERVATION_JOB else planner.MODERATION_CONSOLE_WORKFLOW, "job": job,
                     "head_sha": self.head, "event": "push", "success_required": True}
                    for job in planner.MODERATION_CONSOLE_JOBS])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.MODERATION_CONSOLE_WORKFLOW, summary)
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("All five jobs", summary)
                self.assertIn("does not certify their success", summary)


    def test_existing_graph_runs_four_sharing_jobs_and_preservation_for_this_source(self):
        workflow = (Path(__file__).resolve().parents[2] / planner.MODERATION_CONSOLE_WORKFLOW).read_text()
        blocks = dict(re.findall(r"(?ms)^  ([a-z][a-z0-9-]*):\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)", workflow))
        ids = ("plan", "billing-verifier-check", "moderation-keygen-windows-policy", "check")
        self.assertEqual(tuple(re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1)
                               for name in ids), planner.MODERATION_CONSOLE_JOBS[:-1])
        self.assertEqual({re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1):
                          int(re.search(r"(?m)^    timeout-minutes: (\d+)$", blocks[name]).group(1))
                          for name in ids}, {job: timeout for job, timeout in planner.MODERATION_CONSOLE_JOB_TIMEOUTS.items()
                                            if job != planner.PRESERVATION_JOB})
        for name in ids[1:]:
            condition = re.search(r"(?m)^    if: (.+)$", blocks[name]).group(1)
            self.assertEqual("    if: " + condition,
                             planner.SHARING_FULL_CHECK_CONDITION + planner.SHARING_OPERATOR_GUARD)
            excluded = re.findall(r"needs.plan.outputs.scope != '([^']+)'", condition)
            self.assertNotIn(planner.MODERATION_CONSOLE_SCOPE, excluded)
        self.assertNotIn(planner.MODERATION_CONSOLE_SCOPE, blocks["private-billing-caller"])
        preservation = (Path(__file__).resolve().parents[2] / planner.PRESERVATION_WORKFLOW).read_text()
        self.assertIn('      - "NekoWidget/SharingService/src/**"', preservation)
        self.assertIn("    name: " + planner.PRESERVATION_JOB, preservation)
        self.assertIn("    timeout-minutes: 5", preservation)
        self.assertNotIn("    if:", preservation)
        self.assertEqual(planner.MODERATION_CONSOLE_JOBS[-1], planner.PRESERVATION_JOB)


    def test_fixed_public_disabled_entrypoints_and_test_inputs_are_required_at_both_ends(self):
        original = planner.MODERATION_CONSOLE_INPUT_BLOBS
        for path, blob in original.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
            for replacement in ({key: value for key, value in original.items() if key != path},
                                original | {path: "0" * 40}, original | {"other.ts": "c" * 40}):
                with patch.object(planner, "MODERATION_CONSOLE_INPUT_BLOBS", replacement):
                    self.assertEqual(self.select(), scope.FULL_SCOPE)


class ModerationAITransportScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.MODERATION_AI_TRANSPORT_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {planner.MODERATION_AI_TRANSPORT_WORKFLOW_BLOBS.get(path, 'unregistered')}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/moderation-ai-transport"})

    def test_exact_two_additions_require_five_backend_jobs_without_native_evidence(self):
        self.assertEqual([row[4] for row in self.rows().values()], ["A", "A"])
        self.assertEqual(self.select(), planner.MODERATION_AI_TRANSPORT_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.MODERATION_AI_TRANSPORT_SCOPE),
                         planner.MODERATION_AI_TRANSPORT_JOBS)
        self.assertNotIn(planner.MODERATION_AI_TRANSPORT_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.MODERATION_AI_TRANSPORT_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.moderation_ai_transport_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "T"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in (*planner.MODERATION_AI_PATHS, "NekoWidget/SharingService/src/moderation-operator-router.ts", "NekoWidget/SharingService/package-lock.json",
                        "NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc", "NekoWidget/PreservationService/src/request-json.ts",
                        "NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/moderation-ai-transport.md",
                        planner.MODERATION_AI_TRANSPORT_WORKFLOW, planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_AI_TRANSPORT_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "MODERATION_AI_TRANSPORT_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c" * 40, "d" * 40),
                     ("c", "d" * 40), ("0" * 40, "invalid"), ("0" * 40, "d" * 40, "extra")):
            with patch.object(planner, "MODERATION_AI_TRANSPORT_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(original), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/moderation-ai-transport.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.MODERATION_AI_TRANSPORT_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_AI_TRANSPORT_SCOPE),
                             planner.MODERATION_AI_TRANSPORT_JOBS)
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in planner.MODERATION_AI_TRANSPORT_WORKFLOW_BLOBS.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        original = planner.MODERATION_AI_TRANSPORT_WORKFLOW_BLOBS
        for path in original:
            with patch.object(planner, "MODERATION_AI_TRANSPORT_WORKFLOW_BLOBS", original | {path: "0" * 40}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)
        for invalid in ({}, {planner.MODERATION_AI_TRANSPORT_WORKFLOW: original[planner.MODERATION_AI_TRANSPORT_WORKFLOW]},
                        original | {planner.JPEG_WORKFLOW: "c" * 40}):
            with patch.object(planner, "MODERATION_AI_TRANSPORT_WORKFLOW_BLOBS", invalid):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/moderation-ai-transport", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.MODERATION_AI_TRANSPORT_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], list(planner.MODERATION_AI_TRANSPORT_JOBS))
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW if job == planner.PRESERVATION_JOB else planner.MODERATION_AI_TRANSPORT_WORKFLOW, "job": job,
                     "head_sha": self.head, "event": "push", "success_required": True}
                    for job in planner.MODERATION_AI_TRANSPORT_JOBS])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.MODERATION_AI_TRANSPORT_WORKFLOW, summary)
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("All five jobs", summary)
                self.assertIn("does not certify their success", summary)


    def test_existing_graph_runs_four_sharing_jobs_and_preservation_for_this_source(self):
        workflow = (Path(__file__).resolve().parents[2] / planner.MODERATION_AI_TRANSPORT_WORKFLOW).read_text()
        blocks = dict(re.findall(r"(?ms)^  ([a-z][a-z0-9-]*):\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)", workflow))
        ids = ("plan", "billing-verifier-check", "moderation-keygen-windows-policy", "check")
        self.assertEqual(tuple(re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1)
                               for name in ids), planner.MODERATION_AI_TRANSPORT_JOBS[:-1])
        self.assertEqual({re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1):
                          int(re.search(r"(?m)^    timeout-minutes: (\d+)$", blocks[name]).group(1))
                          for name in ids}, {job: timeout for job, timeout in planner.MODERATION_AI_TRANSPORT_JOB_TIMEOUTS.items()
                                            if job != planner.PRESERVATION_JOB})
        for name in ids[1:]:
            condition = re.search(r"(?m)^    if: (.+)$", blocks[name]).group(1)
            self.assertEqual("    if: " + condition,
                             planner.SHARING_FULL_CHECK_CONDITION + planner.SHARING_OPERATOR_GUARD)
            excluded = re.findall(r"needs.plan.outputs.scope != '([^']+)'", condition)
            self.assertNotIn(planner.MODERATION_AI_TRANSPORT_SCOPE, excluded)
        self.assertNotIn(planner.MODERATION_AI_TRANSPORT_SCOPE, blocks["private-billing-caller"])
        preservation = (Path(__file__).resolve().parents[2] / planner.PRESERVATION_WORKFLOW).read_text()
        self.assertIn('      - "NekoWidget/SharingService/src/**"', preservation)
        self.assertIn("    name: " + planner.PRESERVATION_JOB, preservation)
        self.assertIn("    timeout-minutes: 5", preservation)
        self.assertNotIn("    if:", preservation)
        self.assertEqual(planner.MODERATION_AI_TRANSPORT_JOBS[-1], planner.PRESERVATION_JOB)


class ModerationAIAdvisoryScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.MODERATION_AI_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {planner.MODERATION_AI_WORKFLOW_BLOBS.get(path, 'unregistered')}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/moderation-ai-advisory"})

    def test_exact_two_additions_require_five_backend_jobs_without_native_evidence(self):
        self.assertEqual([row[4] for row in self.rows().values()], ["A", "A"])
        self.assertEqual(self.select(), planner.MODERATION_AI_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.MODERATION_AI_SCOPE),
                         planner.MODERATION_AI_JOBS)
        self.assertNotIn(planner.MODERATION_AI_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.MODERATION_AI_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.moderation_ai_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "T"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/SharingService/src/moderation-operator-router.ts", "NekoWidget/SharingService/package-lock.json",
                        "NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc", "NekoWidget/PreservationService/src/request-json.ts",
                        "NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/moderation-ai-advisory.md",
                        planner.MODERATION_AI_WORKFLOW, planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_AI_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "MODERATION_AI_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c" * 40, "d" * 40),
                     ("c", "d" * 40), ("0" * 40, "invalid"), ("0" * 40, "d" * 40, "extra")):
            with patch.object(planner, "MODERATION_AI_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(original), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/moderation-ai-advisory.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.MODERATION_AI_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_AI_SCOPE),
                             planner.MODERATION_AI_JOBS)
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in planner.MODERATION_AI_WORKFLOW_BLOBS.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        original = planner.MODERATION_AI_WORKFLOW_BLOBS
        for path in original:
            with patch.object(planner, "MODERATION_AI_WORKFLOW_BLOBS", original | {path: "0" * 40}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)
        for invalid in ({}, {planner.MODERATION_AI_WORKFLOW: original[planner.MODERATION_AI_WORKFLOW]},
                        original | {planner.JPEG_WORKFLOW: "c" * 40}):
            with patch.object(planner, "MODERATION_AI_WORKFLOW_BLOBS", invalid):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/moderation-ai-advisory", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.MODERATION_AI_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], list(planner.MODERATION_AI_JOBS))
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW if job == planner.PRESERVATION_JOB else planner.MODERATION_AI_WORKFLOW, "job": job,
                     "head_sha": self.head, "event": "push", "success_required": True}
                    for job in planner.MODERATION_AI_JOBS])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.MODERATION_AI_WORKFLOW, summary)
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("All five jobs", summary)
                self.assertIn("does not certify their success", summary)


    def test_existing_graph_runs_four_sharing_jobs_and_preservation_for_this_source(self):
        workflow = (Path(__file__).resolve().parents[2] / planner.MODERATION_AI_WORKFLOW).read_text()
        blocks = dict(re.findall(r"(?ms)^  ([a-z][a-z0-9-]*):\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)", workflow))
        ids = ("plan", "billing-verifier-check", "moderation-keygen-windows-policy", "check")
        self.assertEqual(tuple(re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1)
                               for name in ids), planner.MODERATION_AI_JOBS[:-1])
        self.assertEqual({re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1):
                          int(re.search(r"(?m)^    timeout-minutes: (\d+)$", blocks[name]).group(1))
                          for name in ids}, {job: timeout for job, timeout in planner.MODERATION_AI_JOB_TIMEOUTS.items()
                                            if job != planner.PRESERVATION_JOB})
        for name in ids[1:]:
            condition = re.search(r"(?m)^    if: (.+)$", blocks[name]).group(1)
            self.assertEqual("    if: " + condition,
                             planner.SHARING_FULL_CHECK_CONDITION + planner.SHARING_OPERATOR_GUARD)
            excluded = re.findall(r"needs.plan.outputs.scope != '([^']+)'", condition)
            self.assertNotIn(planner.MODERATION_AI_SCOPE, excluded)
        self.assertNotIn(planner.MODERATION_AI_SCOPE, blocks["private-billing-caller"])
        preservation = (Path(__file__).resolve().parents[2] / planner.PRESERVATION_WORKFLOW).read_text()
        self.assertIn('      - "NekoWidget/SharingService/src/**"', preservation)
        self.assertIn("    name: " + planner.PRESERVATION_JOB, preservation)
        self.assertIn("    timeout-minutes: 5", preservation)
        self.assertNotIn("    if:", preservation)
        self.assertEqual(planner.MODERATION_AI_JOBS[-1], planner.PRESERVATION_JOB)


class ModerationEnrollmentScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.MODERATION_ENROLLMENT_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {planner.MODERATION_ENROLLMENT_WORKFLOW_BLOB}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/moderation-enrollment"})

    def test_exact_three_paths_require_the_existing_backend_job_without_native_evidence(self):
        self.assertEqual([row[4] for row in self.rows().values()], ["M", "A", "M"])
        self.assertEqual(self.select(), planner.MODERATION_ENROLLMENT_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.MODERATION_ENROLLMENT_SCOPE),
                         planner.MODERATION_ENROLLMENT_JOBS)
        self.assertNotIn(planner.MODERATION_ENROLLMENT_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.MODERATION_ENROLLMENT_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.moderation_enrollment_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "T"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/SharingService/src/moderation-operator-router.ts", "NekoWidget/SharingService/package-lock.json",
                        "NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc", "NekoWidget/PreservationService/src/request-json.ts",
                        "NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/moderation-enrollment.md",
                        planner.MODERATION_ENROLLMENT_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_ENROLLMENT_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "MODERATION_ENROLLMENT_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("0" * 40, "d" * 40), ("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c" * 40, "d" * 40), ("c", "d" * 40)):
            with patch.object(planner, "MODERATION_ENROLLMENT_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/moderation-enrollment.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.MODERATION_ENROLLMENT_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_ENROLLMENT_SCOPE),
                             planner.MODERATION_ENROLLMENT_JOBS)
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in ((planner.MODERATION_ENROLLMENT_WORKFLOW, planner.MODERATION_ENROLLMENT_WORKFLOW_BLOB),):
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        with patch.object(planner, "MODERATION_ENROLLMENT_WORKFLOW_BLOB", "0" * 40):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/moderation-enrollment", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.MODERATION_ENROLLMENT_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], list(planner.MODERATION_ENROLLMENT_JOBS))
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.MODERATION_ENROLLMENT_WORKFLOW, "job": job,
                     "head_sha": self.head, "event": "push", "success_required": True}
                    for job in planner.MODERATION_ENROLLMENT_JOBS])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.MODERATION_ENROLLMENT_WORKFLOW, summary)
                self.assertIn("does not certify their success", summary)


    def test_existing_sharing_graph_runs_all_four_jobs_for_this_scope(self):
        workflow = (Path(__file__).resolve().parents[2] / planner.MODERATION_ENROLLMENT_WORKFLOW).read_text()
        blocks = dict(re.findall(r"(?ms)^  ([a-z][a-z0-9-]*):\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)", workflow))
        ids = ("plan", "billing-verifier-check", "moderation-keygen-windows-policy", "check")
        self.assertEqual(tuple(re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1)
                               for name in ids), planner.MODERATION_ENROLLMENT_JOBS)
        self.assertEqual({re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1):
                          int(re.search(r"(?m)^    timeout-minutes: (\d+)$", blocks[name]).group(1))
                          for name in ids}, planner.MODERATION_ENROLLMENT_JOB_TIMEOUTS)
        for name in ids[1:]:
            condition = re.search(r"(?m)^    if: (.+)$", blocks[name]).group(1)
            self.assertEqual("    if: " + condition,
                             planner.SHARING_FULL_CHECK_CONDITION + planner.SHARING_OPERATOR_GUARD)
            excluded = re.findall(r"needs.plan.outputs.scope != '([^']+)'", condition)
            self.assertNotIn(planner.MODERATION_ENROLLMENT_SCOPE, excluded)
        self.assertNotIn(planner.MODERATION_ENROLLMENT_SCOPE, blocks["private-billing-caller"])


class PreservationRecoveryReadScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.PRESERVATION_RECOVERY_READ_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {planner.PRESERVATION_RECOVERY_READ_WORKFLOW_BLOB}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/recovery-read"})

    def test_exact_two_paths_require_the_existing_backend_job_without_native_evidence(self):
        self.assertEqual([row[4] for row in self.rows().values()], ["M", "A"])
        self.assertEqual(self.select(), planner.PRESERVATION_RECOVERY_READ_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.PRESERVATION_RECOVERY_READ_SCOPE),
                         (planner.PRESERVATION_JOB,))
        self.assertNotIn(planner.PRESERVATION_RECOVERY_READ_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.PRESERVATION_RECOVERY_READ_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.preservation_recovery_read_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/PreservationService/src/bounded-body.ts", "NekoWidget/PreservationService/src/request-json.ts",
                        "NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/recovery-read.md",
                        planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_RECOVERY_READ_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_RECOVERY_READ_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("0" * 40, "d" * 40), ("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c" * 40, "d" * 40), ("c", "d" * 40)):
            with patch.object(planner, "PRESERVATION_RECOVERY_READ_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/recovery-read.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.PRESERVATION_RECOVERY_READ_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_RECOVERY_READ_SCOPE),
                             (planner.PRESERVATION_JOB,))
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in ((planner.PRESERVATION_WORKFLOW, planner.PRESERVATION_RECOVERY_READ_WORKFLOW_BLOB),):
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_RECOVERY_READ_WORKFLOW_BLOB", "0" * 40):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/recovery-read", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_RECOVERY_READ_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], [planner.PRESERVATION_JOB])
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW, "job": planner.PRESERVATION_JOB,
                     "head_sha": self.head, "success_required": True}])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("does not certify that job's success", summary)


class PreservationRequestBufferScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.PRESERVATION_REQUEST_BUFFER_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {planner.PRESERVATION_REQUEST_BUFFER_WORKFLOW_BLOB}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/request-buffer"})

    def test_exact_three_paths_require_the_existing_backend_job_without_native_evidence(self):
        self.assertEqual([row[4] for row in self.rows().values()], ["M", "A", "A"])
        self.assertEqual(self.select(), planner.PRESERVATION_REQUEST_BUFFER_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.PRESERVATION_REQUEST_BUFFER_SCOPE),
                         (planner.PRESERVATION_JOB,))
        self.assertNotIn(planner.PRESERVATION_REQUEST_BUFFER_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.PRESERVATION_REQUEST_BUFFER_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.preservation_request_buffer_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/PreservationService/src/bounded-body.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/request-buffer.md",
                        planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_REQUEST_BUFFER_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_REQUEST_BUFFER_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("0" * 40, "d" * 40), ("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c" * 40, "d" * 40), ("c", "d" * 40)):
            with patch.object(planner, "PRESERVATION_REQUEST_BUFFER_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/request-buffer.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.PRESERVATION_REQUEST_BUFFER_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_REQUEST_BUFFER_SCOPE),
                             (planner.PRESERVATION_JOB,))
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in ((planner.PRESERVATION_WORKFLOW, planner.PRESERVATION_REQUEST_BUFFER_WORKFLOW_BLOB),):
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_REQUEST_BUFFER_WORKFLOW_BLOB", "0" * 40):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/request-buffer", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_REQUEST_BUFFER_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], [planner.PRESERVATION_JOB])
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW, "job": planner.PRESERVATION_JOB,
                     "head_sha": self.head, "success_required": True}])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("does not certify that job's success", summary)


class PreservationR2ViewScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.PRESERVATION_R2_VIEW_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {planner.PRESERVATION_R2_VIEW_WORKFLOW_BLOB}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/r2-view"})

    def test_exact_two_paths_require_the_existing_backend_job_without_native_evidence(self):
        self.assertEqual(self.select(), planner.PRESERVATION_R2_VIEW_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.PRESERVATION_R2_VIEW_SCOPE),
                         (planner.PRESERVATION_JOB,))
        self.assertNotIn(planner.PRESERVATION_R2_VIEW_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.PRESERVATION_R2_VIEW_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.preservation_r2_view_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/r2-view.md",
                        planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_R2_VIEW_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_R2_VIEW_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("0" * 40, "d" * 40), ("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c", "d" * 40)):
            with patch.object(planner, "PRESERVATION_R2_VIEW_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/r2-view.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.PRESERVATION_R2_VIEW_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_R2_VIEW_SCOPE),
                             (planner.PRESERVATION_JOB,))
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in ((planner.PRESERVATION_WORKFLOW, planner.PRESERVATION_R2_VIEW_WORKFLOW_BLOB),):
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_R2_VIEW_WORKFLOW_BLOB", "0" * 40):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/r2-view", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_R2_VIEW_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], [planner.PRESERVATION_JOB])
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW, "job": planner.PRESERVATION_JOB,
                     "head_sha": self.head, "success_required": True}])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("does not certify that job's success", summary)


class PreservationProviderStreamScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.PRESERVATION_PROVIDER_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {planner.PRESERVATION_PROVIDER_WORKFLOWS[path]}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/provider-stream"})

    def test_exact_three_paths_require_both_existing_jobs_without_native_evidence(self):
        self.assertEqual(self.select(), planner.PRESERVATION_PROVIDER_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.PRESERVATION_PROVIDER_SCOPE),
                         (planner.PRESERVATION_JOB, planner.JPEG_JOB))
        self.assertNotIn(planner.PRESERVATION_PROVIDER_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.PRESERVATION_PROVIDER_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.preservation_provider_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/provider.md",
                        *planner.PRESERVATION_PROVIDER_WORKFLOWS, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_PROVIDER_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        for invalid in ("", raw + raw, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_PROVIDER_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/provider.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.PRESERVATION_PROVIDER_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_PROVIDER_SCOPE),
                             (planner.PRESERVATION_JOB, planner.JPEG_JOB))
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_both_workflows_require_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in planner.PRESERVATION_PROVIDER_WORKFLOWS.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_PROVIDER_WORKFLOWS", {planner.PRESERVATION_WORKFLOW: "b" * 40}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_both_same_sha_successes_and_never_claims_them(self):
        for ref in ("refs/heads/codex/provider-stream", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_PROVIDER_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], [planner.PRESERVATION_JOB, planner.JPEG_JOB])
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW, "job": planner.PRESERVATION_JOB,
                     "head_sha": self.head, "success_required": True},
                    {"workflow": planner.JPEG_WORKFLOW, "job": planner.JPEG_JOB,
                     "head_sha": self.head, "success_required": True}])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                for workflow in planner.PRESERVATION_PROVIDER_WORKFLOWS: self.assertIn(workflow, summary)
                self.assertIn("Both jobs must execute successfully", summary)
                self.assertIn("does not certify their success", summary)


class PreservationUploadMemoryScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.PRESERVATION_UPLOAD_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflow=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "rev-parse":
                if args[1] == "HEAD": return self.head
                if args[1].endswith(":" + planner.PRESERVATION_WORKFLOW):
                    return (workflow or {}).get(args[1].split(":", 1)[0], planner.PRESERVATION_UPLOAD_WORKFLOW_BLOB)
                return "0" * 40  # Never impersonate v26's frozen service tree.
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/upload-memory"})

    def test_exact_m_and_a_pair_selects_existing_node_job_without_native_release_evidence(self):
        paths = list(self.rows())
        self.assertEqual(self.select(), planner.PRESERVATION_UPLOAD_SCOPE)
        self.assertEqual(planner.required_jobs(paths, planner.PRESERVATION_UPLOAD_SCOPE), (planner.PRESERVATION_JOB,))
        self.assertNotIn(planner.PRESERVATION_UPLOAD_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.PRESERVATION_UPLOAD_SCOPE)
        self.assertFalse(planner.preservation_upload_paths_only(None))
        self.assertFalse(planner.preservation_upload_paths_only([]))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")

    def test_partial_unknown_mixed_modes_blobs_and_changed_workflow_fail_closed(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({key: row for key, row in original.items() if key != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/test/other.test.ts",
                        "NekoWidget/PreservationService/package.json", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/NekoWidget/Services/PhotoMemoryNoteExporter.swift", "handoffs/upload.md",
                        planner.PRESERVATION_WORKFLOW, ".github/workflows/ios-build.yml",
                        "NekoWidget/ci/plan-ios-ci.py", "NekoWidget/ci/preflight-ci.py",
                        "NekoWidget/ci/test-plan-ios-ci.py", "NekoWidget/ci/test-preflight-ci.py"):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_UPLOAD_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        for invalid in ("", raw + raw, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        for revision in (self.base, self.head):
            self.assertEqual(self.select(workflow={revision: "e" * 40}), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_UPLOAD_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_candidate_and_main_plan_only_schedule_the_separate_same_sha_node_workflow(self):
        for ref in ("refs/heads/codex/upload-memory", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_UPLOAD_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["head_sha"], self.head)
                self.assertEqual(record["required_jobs"], [planner.PRESERVATION_JOB])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("does not certify that job's success", summary)


class ImmediateBillingAuthorityScopeTests(unittest.TestCase):
    def candidate(self):
        return {path: ("reviewed before " + path, "reviewed after " + path)
                for path in planner.BILLING_AUTHORITY_PATHS}

    def select(self, changes, *, mutation=None, ancestor=True, workflow="owning workflow", companions=None):
        base, head = "b" * 40, "a" * 40
        pairs = {path: list(map(scope.source_digest, values)) for path, values in self.candidate().items()}
        def git(*args):
            if args[0] == "merge-base":
                if not ancestor: raise subprocess.CalledProcessError(1, args)
                return ""
            if args[0] == "diff":
                rows = []
                for path in changes:
                    modes, status = ":100644 100644", "M"
                    if mutation and path == mutation[0]: modes, status = mutation[1:]
                    rows.append(f"{modes} {'c'*40} {'d'*40} {status}\0{path}\0")
                return "".join(rows)
            if args[0] == "show":
                revision, path = args[1].split(":", 1)
                if path == planner.BILLING_WORKFLOW: return workflow
                return changes[path][revision == head]
            raise AssertionError(args)
        with patch.object(planner, "comparison_base", return_value=base), \
             patch.object(planner, "git", side_effect=git), \
             patch.object(planner, "BILLING_AUTHORITY_PRODUCTS", pairs), \
             patch.object(planner, "BILLING_AUTHORITY_WORKFLOW_DIGEST", scope.source_digest("owning workflow")), \
             patch.object(planner, "BILLING_AUTHORITY_COMPANION_DIGESTS", companions or {}):
            return planner.runtime_scope(list(changes), {}, {"GITHUB_SHA": head})

    def test_exact_batch_requires_existing_owning_backend_job(self):
        self.assertFalse(planner.billing_authority_paths_only(None))
        self.assertFalse(planner.billing_authority_paths_only([]))
        changes = self.candidate()
        self.assertFalse(planner.billing_authority_paths_only(list(changes) + [next(iter(changes))]))
        self.assertEqual(self.select(changes), planner.BILLING_AUTHORITY_SCOPE)
        self.assertEqual(planner.required_jobs(list(changes), planner.BILLING_AUTHORITY_SCOPE),
                         (planner.BILLING_AUTHORITY_JOB,))
        with self.assertRaises(ValueError):
            planner.required_jobs_from_scope(planner.BILLING_AUTHORITY_SCOPE)
        self.assertNotIn(planner.BILLING_AUTHORITY_SCOPE, scope.SCOPES)
        workflow = (Path(__file__).resolve().parents[2] / planner.BILLING_WORKFLOW).read_text(encoding="utf-8")
        check = workflow[workflow.index("  check:"):]
        self.assertIn("name: " + planner.BILLING_AUTHORITY_JOB, check)
        self.assertIn("run: npm run check", check)
        self.assertIn("--dry-run", check)
        self.assertNotIn(planner.BILLING_AUTHORITY_SCOPE, check)

    def test_unknown_partial_changed_or_unsafe_batch_is_full(self):
        original = self.candidate()
        for path in original:
            modified = dict(original); modified[path] = (modified[path][0], modified[path][1] + " unknown")
            self.assertEqual(self.select(modified), scope.FULL_SCOPE)
            removed = dict(original); del removed[path]
            self.assertEqual(self.select(removed), scope.FULL_SCOPE)
            for mode, status in ((":100644 100755", "M"), (":100644 120000", "T"),
                                 (":100644 000000", "D"), (":000000 100644", "A")):
                self.assertEqual(self.select(original, mutation=(path, mode, status)), scope.FULL_SCOPE)
        for path in ("NekoWidget/SharingService/src/env.ts", "NekoWidget/Shared/MembershipAccessPolicy.swift",
                     "NekoWidget/NekoWidget/Services/PlusPurchaseStore.swift", planner.BILLING_WORKFLOW):
            changed = original | {path: ("before", "after")}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.BILLING_AUTHORITY_SCOPE), planner.FULL)
        self.assertEqual(self.select(original, ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(original, workflow="changed workflow"), scope.FULL_SCOPE)

    def test_control_companions_require_full_exact_self_bound_batch(self):
        changes = self.candidate()
        companions = {path: ("control before " + path, "control after " + path)
                      for path in planner.BILLING_AUTHORITY_COMPANION_PATHS}
        bindings = {path: list(map(scope.source_digest, pair)) for path, pair in companions.items()}
        planner_path = "NekoWidget/ci/plan-ios-ci.py"
        companions[planner_path] = (companions[planner_path][0],
            companions[planner_path][1] + "\nBILLING_AUTHORITY_COMPANION_DIGESTS = {}\n")
        bindings[planner_path] = list(map(scope.source_digest, companions[planner_path]))
        assignment = "BILLING_AUTHORITY_COMPANION_DIGESTS = " + json.dumps(bindings, indent=4, sort_keys=True) + "\n"
        companions[planner_path] = (companions[planner_path][0], companions[planner_path][1].replace(
            "BILLING_AUTHORITY_COMPANION_DIGESTS = {}\n", assignment))
        self.assertEqual(self.select(changes | companions, companions=bindings), planner.BILLING_AUTHORITY_SCOPE)
        for path in companions:
            changed = dict(companions); del changed[path]
            self.assertEqual(self.select(changes | changed, companions=bindings), scope.FULL_SCOPE)
            changed = dict(companions); changed[path] = (changed[path][0], changed[path][1] + " drift")
            self.assertEqual(self.select(changes | changed, companions=bindings), scope.FULL_SCOPE)


class MembershipStateScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def candidate(self):
        products = {path: ("c" * 40, "d" * 40) for path in scope.MEMBERSHIP_STATE_PATHS}
        pairs = {path: ("before " + path, "after " + path) for path in scope.MEMBERSHIP_STATE_COMPANIONS}
        selector = "NekoWidget/ci/plan-ios-ci.py"
        empty = "MEMBERSHIP_STATE_COMPANION_DIGESTS = {}\n"
        pairs[selector] = (pairs[selector][0], empty + "# reviewed selector\n")
        bindings = {path: list(map(scope.source_digest, pair)) for path, pair in pairs.items()}
        literal = "MEMBERSHIP_STATE_COMPANION_DIGESTS = " + json.dumps(bindings, indent=4, sort_keys=True) + "\n"
        pairs[selector] = (pairs[selector][0], pairs[selector][1].replace(empty, literal))
        rows = {path: f":100644 100644 {before} {after} M" for path, (before, after) in products.items()}
        rows.update({path: f":100644 100644 {'e' * 40} {'f' * 40} M" for path in pairs})
        source = "final class SoloMemoriesUITests: XCTestCase {\n" + "".join(
            "    func " + test.rsplit("/", 1)[-1] + "() {}\n" for test in scope.MEMBERSHIP_STATE_TESTS[:4])
        source += "}\nfinal class MomentDeliveryComposerUITests: XCTestCase {\n    func "
        source += scope.MEMBERSHIP_STATE_TESTS[-1].rsplit("/", 1)[-1] + "() {}\n}\n"
        return products, pairs, bindings, rows, source

    def verify(self, rows, *, paths=None, mutated=None, extra="", source=None, workflow=None, runtime=False):
        products, pairs, bindings, _, valid_source = self.candidate()
        def git(*args):
            if args[0] == "diff":
                return "".join(header + "\0" + path + "\0" for path, header in rows.items()) + extra
            if args[0] == "show":
                ref, path = args[1].split(":", 1)
                if path == scope.MEMORY_TEST_PATH:
                    return valid_source if source is None else source
                return pairs[path][int(ref == self.head)] + ("# altered" if path == mutated else "")
            if args[0] == "rev-parse":
                return workflow or planner.MEMBERSHIP_STATE_WORKFLOW_BLOB
            if args[0] == "merge-base":
                return self.base
            raise AssertionError(args)
        candidate_paths = list(rows) if paths is None else paths
        with patch.object(planner, "git", side_effect=git), \
                patch.object(planner, "comparison_base", return_value=self.base), \
                patch.object(planner, "MEMBERSHIP_STATE_BLOBS", products), \
                patch.object(planner, "MEMBERSHIP_STATE_COMPANION_DIGESTS", bindings):
            if runtime:
                return planner.runtime_scope(candidate_paths, {}, {"GITHUB_SHA": self.head})
            return planner.membership_state_only(candidate_paths, self.base, self.head)

    def test_complete_products_and_self_bound_controls_select_only_this_scope(self):
        products, pairs, _, rows, _ = self.candidate()
        self.assertTrue(self.verify(rows))
        self.assertTrue(self.verify({path: rows[path] for path in products}))
        self.assertEqual(self.verify(rows, runtime=True), scope.REVIEWED_MEMBERSHIP_STATE_SCOPE)
        self.assertEqual(self.verify({path: rows[path] for path in products}, runtime=True), scope.REVIEWED_MEMBERSHIP_STATE_SCOPE)
        self.assertFalse(planner.membership_state_only([], self.base, self.head))
        # Before final product hash review, real pending values cannot select.
        if any("pending-review" in pair for pair in scope.MEMBERSHIP_STATE_BLOBS.values()):
            self.assertFalse(planner.membership_state_only(list(rows), self.base, self.head))

    def test_partial_mutated_mode_unknown_or_workflow_changes_fail_closed(self):
        products, pairs, _, rows, _ = self.candidate()
        for path in rows:
            with self.subTest(missing=path):
                missing = {key: value for key, value in rows.items() if key != path}
                self.assertFalse(self.verify(missing))
                self.assertEqual(self.verify(missing, runtime=True), scope.FULL_SCOPE)
            for mode in ("100755", "120000", "160000", "000000"):
                changed = dict(rows); changed[path] = changed[path].replace("100644", mode)
                self.assertFalse(self.verify(changed), (path, mode))
            for status in ("A", "D", "T", "R100", "C100"):
                changed = dict(rows); changed[path] = changed[path][:-1] + status
                self.assertFalse(self.verify(changed), (path, status))
        for path, pair in products.items():
            for blob in pair:
                changed = dict(rows); changed[path] = changed[path].replace(blob, "1" * 40)
                self.assertFalse(self.verify(changed), (path, blob))
                self.assertEqual(self.verify(changed, runtime=True), scope.FULL_SCOPE)
        for path in pairs:
            self.assertFalse(self.verify(rows, mutated=path), path)
            self.assertEqual(self.verify(rows, mutated=path, runtime=True), scope.FULL_SCOPE)
        for path in ("NekoWidget/Shared/MembershipAccessPolicy.swift", "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                     "NekoWidget/NekoWidget.xcodeproj/project.pbxproj", scope.CI_WORKFLOW,
                     "NekoWidget/ci/preflight-ci.py", "NekoWidget/NekoWidget/Services/NewStore.swift"):
            changed = rows | {path: f":100644 100644 {'c' * 40} {'d' * 40} M"}
            self.assertFalse(self.verify(changed), path)
            self.assertEqual(self.verify(changed, runtime=True), scope.FULL_SCOPE)
        self.assertFalse(self.verify(rows, workflow="1" * 40))
        self.assertEqual(self.verify(rows, workflow="1" * 40, runtime=True), scope.FULL_SCOPE)
        first = next(iter(rows))
        self.assertFalse(self.verify(rows, paths=list(rows) + [first]))
        self.assertFalse(self.verify(rows, extra=rows[first] + "\0" + first + "\0"))
        handoff = rows | {"handoffs/membership-state.md": f":000000 100644 {'0' * 40} {'d' * 40} A"}
        self.assertTrue(self.verify(handoff))
        handoff["handoffs/membership-state.md"] = handoff["handoffs/membership-state.md"].replace("100644", "120000")
        self.assertFalse(self.verify(handoff))

    def test_all_five_methods_and_available_git_evidence_are_required(self):
        _, _, _, rows, source = self.candidate()
        for test in scope.MEMBERSHIP_STATE_TESTS:
            method = test.rsplit("/", 1)[-1]
            self.assertFalse(self.verify(rows, source=source.replace("func " + method, "func missing")), test)
            self.assertEqual(self.verify(rows, source=source.replace("func " + method, "func missing"), runtime=True), scope.FULL_SCOPE)
        self.assertFalse(self.verify(rows, source=source.replace("MomentDeliveryComposerUITests", "OtherUITests")))
        self.assertFalse(self.verify(rows, source=source.replace("func testMembershipOfferPreviewReturnsToPurpose() {}",
            "/* func testMembershipOfferPreviewReturnsToPurpose() {} */")))
        with patch.object(planner, "comparison_base", return_value=self.base), \
                patch.object(planner, "git", side_effect=subprocess.CalledProcessError(1, "git")):
            self.assertEqual(planner.runtime_scope(sorted(scope.MEMBERSHIP_STATE_PATHS), {}, {"GITHUB_SHA": self.head}), scope.FULL_SCOPE)


class PurchaseCatalogScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def candidate(self):
        products = {path: ("c" * 40, "d" * 40) for path in scope.PURCHASE_CATALOG_PATHS}
        pairs = {path: ("before " + path, "after " + path) for path in scope.PURCHASE_CATALOG_COMPANIONS}
        selector = "NekoWidget/ci/plan-ios-ci.py"
        empty = "PURCHASE_CATALOG_COMPANION_DIGESTS = {}\n"
        pairs[selector] = (pairs[selector][0], empty + "# reviewed selector\n")
        bindings = {path: list(map(scope.source_digest, pair)) for path, pair in pairs.items()}
        literal = "PURCHASE_CATALOG_COMPANION_DIGESTS = " + json.dumps(bindings, indent=4, sort_keys=True) + "\n"
        pairs[selector] = (pairs[selector][0], pairs[selector][1].replace(empty, literal))
        rows = {path: f":100644 100644 {before} {after} M" for path, (before, after) in products.items()}
        rows.update({path: f":100644 100644 {'e' * 40} {'f' * 40} M" for path in pairs})
        source = "final class SoloMemoriesUITests: XCTestCase {\n" + "".join(
            "    func " + test.rsplit("/", 1)[-1] + "() {}\n" for test in scope.PURCHASE_CATALOG_TESTS[:4])
        source += "}\nfinal class MomentDeliveryComposerUITests: XCTestCase {\n    func "
        source += scope.PURCHASE_CATALOG_TESTS[-1].rsplit("/", 1)[-1] + "() {}\n}\n"
        return products, pairs, bindings, rows, source

    def verify(self, rows, *, paths=None, mutated=None, extra="", source=None, workflow=None, runtime=False):
        products, pairs, bindings, _, valid_source = self.candidate()
        def git(*args):
            if args[0] == "diff":
                return "".join(header + "\0" + path + "\0" for path, header in rows.items()) + extra
            if args[0] == "show":
                ref, path = args[1].split(":", 1)
                if path == scope.MEMORY_TEST_PATH:
                    return valid_source if source is None else source
                return pairs[path][int(ref == self.head)] + ("# altered" if path == mutated else "")
            if args[0] == "rev-parse":
                return workflow or planner.PURCHASE_CATALOG_WORKFLOW_BLOB
            if args[0] == "merge-base":
                return self.base
            raise AssertionError(args)
        candidate_paths = list(rows) if paths is None else paths
        with patch.object(planner, "git", side_effect=git), \
                patch.object(planner, "comparison_base", return_value=self.base), \
                patch.object(planner, "PURCHASE_CATALOG_BLOBS", products), \
                patch.object(planner, "PURCHASE_CATALOG_COMPANION_DIGESTS", bindings):
            if runtime:
                return planner.runtime_scope(candidate_paths, {}, {"GITHUB_SHA": self.head})
            return planner.purchase_catalog_only(candidate_paths, self.base, self.head)

    def test_complete_products_and_self_bound_controls_select_only_this_scope(self):
        products, pairs, _, rows, _ = self.candidate()
        self.assertTrue(self.verify(rows))
        self.assertTrue(self.verify({path: rows[path] for path in products}))
        self.assertEqual(self.verify(rows, runtime=True), scope.REVIEWED_PURCHASE_CATALOG_SCOPE)
        self.assertEqual(self.verify({path: rows[path] for path in products}, runtime=True), scope.REVIEWED_PURCHASE_CATALOG_SCOPE)
        self.assertFalse(planner.purchase_catalog_only([], self.base, self.head))
        # Before final product hash review, real pending values cannot select.
        if any("pending-review" in pair for pair in scope.PURCHASE_CATALOG_BLOBS.values()):
            self.assertFalse(planner.purchase_catalog_only(list(rows), self.base, self.head))

    def test_partial_mutated_mode_unknown_or_workflow_changes_fail_closed(self):
        products, pairs, _, rows, _ = self.candidate()
        for path in rows:
            with self.subTest(missing=path):
                missing = {key: value for key, value in rows.items() if key != path}
                self.assertFalse(self.verify(missing))
                self.assertEqual(self.verify(missing, runtime=True), scope.FULL_SCOPE)
            for mode in ("100755", "120000", "160000", "000000"):
                changed = dict(rows); changed[path] = changed[path].replace("100644", mode)
                self.assertFalse(self.verify(changed), (path, mode))
            for status in ("A", "D", "T", "R100", "C100"):
                changed = dict(rows); changed[path] = changed[path][:-1] + status
                self.assertFalse(self.verify(changed), (path, status))
        for path, pair in products.items():
            for blob in pair:
                changed = dict(rows); changed[path] = changed[path].replace(blob, "1" * 40)
                self.assertFalse(self.verify(changed), (path, blob))
                self.assertEqual(self.verify(changed, runtime=True), scope.FULL_SCOPE)
        for path in pairs:
            self.assertFalse(self.verify(rows, mutated=path), path)
            self.assertEqual(self.verify(rows, mutated=path, runtime=True), scope.FULL_SCOPE)
        for path in ("NekoWidget/Shared/MembershipAccessPolicy.swift", "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                     "NekoWidget/NekoWidget.xcodeproj/project.pbxproj", scope.CI_WORKFLOW,
                     "NekoWidget/ci/preflight-ci.py", "NekoWidget/NekoWidget/Services/NewStore.swift"):
            changed = rows | {path: f":100644 100644 {'c' * 40} {'d' * 40} M"}
            self.assertFalse(self.verify(changed), path)
            self.assertEqual(self.verify(changed, runtime=True), scope.FULL_SCOPE)
        self.assertFalse(self.verify(rows, workflow="1" * 40))
        self.assertEqual(self.verify(rows, workflow="1" * 40, runtime=True), scope.FULL_SCOPE)
        first = next(iter(rows))
        self.assertFalse(self.verify(rows, paths=list(rows) + [first]))
        self.assertFalse(self.verify(rows, extra=rows[first] + "\0" + first + "\0"))
        handoff = rows | {"handoffs/purchase-catalog.md": f":000000 100644 {'0' * 40} {'d' * 40} A"}
        self.assertTrue(self.verify(handoff))
        handoff["handoffs/purchase-catalog.md"] = handoff["handoffs/purchase-catalog.md"].replace("100644", "120000")
        self.assertFalse(self.verify(handoff))

    def test_all_five_methods_and_available_git_evidence_are_required(self):
        _, _, _, rows, source = self.candidate()
        for test in scope.PURCHASE_CATALOG_TESTS:
            method = test.rsplit("/", 1)[-1]
            self.assertFalse(self.verify(rows, source=source.replace("func " + method, "func missing")), test)
            self.assertEqual(self.verify(rows, source=source.replace("func " + method, "func missing"), runtime=True), scope.FULL_SCOPE)
        self.assertFalse(self.verify(rows, source=source.replace("MomentDeliveryComposerUITests", "OtherUITests")))
        self.assertFalse(self.verify(rows, source=source.replace("func testMembershipOfferPreviewReturnsToPurpose() {}",
            "/* func testMembershipOfferPreviewReturnsToPurpose() {} */")))
        with patch.object(planner, "comparison_base", return_value=self.base), \
                patch.object(planner, "git", side_effect=subprocess.CalledProcessError(1, "git")):
            self.assertEqual(planner.runtime_scope(sorted(scope.PURCHASE_CATALOG_PATHS), {}, {"GITHUB_SHA": self.head}), scope.FULL_SCOPE)


class PreservationExportScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def candidate(self):
        products = {path: ("0" * 40 if index % 2 else "c" * 40, "d" * 40)
                    for index, path in enumerate(sorted(scope.PRESERVATION_EXPORT_PATHS))}
        pairs = {path: ("before " + path, "after " + path) for path in scope.PRESERVATION_EXPORT_COMPANIONS}
        selector = "NekoWidget/ci/plan-ios-ci.py"
        empty = "PRESERVATION_EXPORT_COMPANION_DIGESTS = {}\n"
        pairs[selector] = (pairs[selector][0], empty + "# reviewed selector\n")
        bindings = {path: list(map(scope.source_digest, pair)) for path, pair in pairs.items()}
        literal = "PRESERVATION_EXPORT_COMPANION_DIGESTS = " + json.dumps(bindings, indent=4, sort_keys=True) + "\n"
        pairs[selector] = (pairs[selector][0], pairs[selector][1].replace(empty, literal))
        rows = {path: f":{'000000' if before == '0' * 40 else '100644'} 100644 {before} {after} {'A' if before == '0' * 40 else 'M'}"
                for path, (before, after) in products.items()}
        rows["handoffs/export.md"] = f":000000 100644 {'0' * 40} {'d' * 40} A"
        rows.update({path: f":100644 100644 {'e' * 40} {'f' * 40} M" for path in pairs})
        source = "final class SoloMemoriesUITests: XCTestCase {\n" + "".join(
            "    func " + test.rsplit("/", 1)[-1] + "() {}\n" for test in scope.PRESERVATION_EXPORT_TESTS[:3])
        source += "}\nfinal class MomentDeliveryComposerUITests: XCTestCase {\n    func "
        source += scope.PRESERVATION_EXPORT_TESTS[-1].rsplit("/", 1)[-1] + "() {}\n}\n"
        return products, pairs, bindings, rows, source

    def verify(self, rows, *, paths=None, mutated=None, extra="", source=None, workflow=None, runtime=False):
        products, pairs, bindings, _, valid_source = self.candidate()
        def git(*args):
            if args[0] == "diff":
                return "".join(header + "\0" + path + "\0" for path, header in rows.items()) + extra
            if args[0] == "show":
                ref, path = args[1].split(":", 1)
                if path == scope.MEMORY_TEST_PATH:
                    return valid_source if source is None else source
                return pairs[path][int(ref == self.head)] + ("# altered" if path == mutated else "")
            if args[0] == "rev-parse":
                return workflow or planner.PRESERVATION_EXPORT_WORKFLOWS[args[1].split(":", 1)[1]]
            if args[0] == "merge-base":
                return self.base
            raise AssertionError(args)
        candidate_paths = list(rows) if paths is None else paths
        with patch.object(planner, "git", side_effect=git), \
                patch.object(planner, "comparison_base", return_value=self.base), \
                patch.object(planner, "PRESERVATION_EXPORT_BLOBS", products), \
                patch.object(planner, "PRESERVATION_EXPORT_DOC_BLOBS", {"handoffs/export.md": ("0" * 40, "d" * 40)}), \
                patch.object(planner, "PRESERVATION_EXPORT_COMPANION_DIGESTS", bindings):
            if runtime:
                return planner.runtime_scope(candidate_paths, {}, {"GITHUB_SHA": self.head})
            return planner.preservation_export_only(candidate_paths, self.base, self.head)

    def test_complete_products_and_self_bound_controls_select_only_this_scope(self):
        products, pairs, _, rows, _ = self.candidate()
        self.assertTrue(self.verify(rows))
        self.assertTrue(self.verify({path: rows[path] for path in rows if path not in pairs}))
        self.assertEqual(self.verify(rows, runtime=True), scope.PRESERVATION_EXPORT_SCOPE)
        self.assertEqual(self.verify({path: rows[path] for path in rows if path not in pairs}, runtime=True), scope.PRESERVATION_EXPORT_SCOPE)
        self.assertFalse(planner.preservation_export_only([], self.base, self.head))
        # Before final product hash review, real pending values cannot select.
        if any("pending-review" in pair for pair in scope.PRESERVATION_EXPORT_BLOBS.values()):
            self.assertFalse(planner.preservation_export_only(list(rows), self.base, self.head))

    def test_partial_mutated_mode_unknown_or_workflow_changes_fail_closed(self):
        products, pairs, _, rows, _ = self.candidate()
        for path in rows:
            with self.subTest(missing=path):
                missing = {key: value for key, value in rows.items() if key != path}
                self.assertFalse(self.verify(missing))
                self.assertEqual(self.verify(missing, runtime=True), scope.FULL_SCOPE)
            for mode in ("100755", "120000", "160000", "000000"):
                changed = dict(rows); changed[path] = changed[path].replace("100644", mode)
                self.assertFalse(self.verify(changed), (path, mode))
            for status in ({"A", "M", "D", "T", "R100", "C100"} - {rows[path].split()[-1]}):
                changed = dict(rows); changed[path] = changed[path][:-1] + status
                self.assertFalse(self.verify(changed), (path, status))
        for path, pair in products.items():
            for blob in pair:
                changed = dict(rows); changed[path] = changed[path].replace(blob, "1" * 40)
                self.assertFalse(self.verify(changed), (path, blob))
                self.assertEqual(self.verify(changed, runtime=True), scope.FULL_SCOPE)
        for path in pairs:
            self.assertFalse(self.verify(rows, mutated=path), path)
            self.assertEqual(self.verify(rows, mutated=path, runtime=True), scope.FULL_SCOPE)
        for path in ("NekoWidget/Shared/MembershipAccessPolicy.swift", "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                     "NekoWidget/NekoWidget.xcodeproj/project.pbxproj", scope.CI_WORKFLOW,
                     "NekoWidget/ci/preflight-ci.py", "NekoWidget/NekoWidget/Services/NewStore.swift"):
            changed = rows | {path: f":100644 100644 {'c' * 40} {'d' * 40} M"}
            self.assertFalse(self.verify(changed), path)
            self.assertEqual(self.verify(changed, runtime=True), scope.FULL_SCOPE)
        self.assertFalse(self.verify(rows, workflow="1" * 40))
        self.assertEqual(self.verify(rows, workflow="1" * 40, runtime=True), scope.FULL_SCOPE)
        first = next(iter(rows))
        self.assertFalse(self.verify(rows, paths=list(rows) + [first]))
        self.assertFalse(self.verify(rows, extra=rows[first] + "\0" + first + "\0"))
        handoff = rows | {"handoffs/purchase-catalog.md": f":000000 100644 {'0' * 40} {'d' * 40} A"}
        self.assertFalse(self.verify(handoff))
        handoff["handoffs/purchase-catalog.md"] = handoff["handoffs/purchase-catalog.md"].replace("100644", "120000")
        self.assertFalse(self.verify(handoff))

    def test_all_four_methods_and_available_git_evidence_are_required(self):
        _, _, _, rows, source = self.candidate()
        for test in scope.PRESERVATION_EXPORT_TESTS:
            method = test.rsplit("/", 1)[-1]
            self.assertFalse(self.verify(rows, source=source.replace("func " + method, "func missing")), test)
            self.assertEqual(self.verify(rows, source=source.replace("func " + method, "func missing"), runtime=True), scope.FULL_SCOPE)
        self.assertFalse(self.verify(rows, source=source.replace("MomentDeliveryComposerUITests", "OtherUITests")))
        self.assertFalse(self.verify(rows, source=source.replace("func testManagedPreservationMembershipLinkConsentAndRetry() {}",
            "/* func testManagedPreservationMembershipLinkConsentAndRetry() {} */")))
        with patch.object(planner, "comparison_base", return_value=self.base), \
                patch.object(planner, "git", side_effect=subprocess.CalledProcessError(1, "git")):
            self.assertEqual(planner.runtime_scope(sorted(scope.PRESERVATION_EXPORT_PATHS), {}, {"GITHUB_SHA": self.head}), scope.FULL_SCOPE)


class PreservationExportCorrectionInputTests(unittest.TestCase):
    def test_only_frozen_test_blob_and_all_approved_controls_can_change(self):
        source, head = planner.PRESERVATION_EXPORT_CORRECTION_SOURCE, "a" * 40
        before, after = planner.PRESERVATION_EXPORT_CORRECTION_BLOBS
        path = planner.MEMORY_TEST_PATH
        row = f":100644 100644 {before} {after} M\0{path}\0"
        def verify(raw=row, *, unapproved=None, missing_source=False, registered=True):
            def git(*args):
                if args[0] == "diff": return raw
                if args[:2] == ("merge-base", "--is-ancestor") and missing_source:
                    raise subprocess.CalledProcessError(1, "git")
                if args[0] == "merge-base": return "b" * 40
                if args[0] == "show":
                    return f'PRESERVATION_EXPORT_CORRECTION_SOURCE = "{source}"' if registered else "old planner"
                if args[0] == "rev-parse":
                    return "d" * 40 if args[1] == head + ":" + str(unapproved) else "c" * 40
                raise AssertionError(args)
            with patch.object(planner, "git", side_effect=git):
                return planner.preservation_export_correction_inputs(source, head)
        self.assertTrue(verify())
        for control in planner.TEST_CORRECTION_CONTROL_PATHS:
            extra = f":100644 100644 {'e' * 40} {'c' * 40} M\0{control}\0"
            self.assertTrue(verify(row + extra), control)
            self.assertFalse(verify(row + extra, unapproved=control), control)
            self.assertFalse(verify(unapproved=control), control)
        for invalid in ("", row + row, row.replace(before, "c" * 40), row.replace(after, "d" * 40),
                        row.replace("100644", "100755"), row.replace(" M\0", " A\0")):
            self.assertFalse(verify(invalid))
        for unknown in ("NekoWidget/NekoWidget/Services/PhotoMemoryNoteExporter.swift",
                        ".github/workflows/ios-build.yml", "NekoWidget/ci/ios_ci_scope.py",
                        "NekoWidget/PreservationService/src/index.ts", "handoffs/extra.md"):
            self.assertFalse(verify(row + f":100644 100644 {'e' * 40} {'c' * 40} M\0{unknown}\0"))
        self.assertFalse(verify(missing_source=True))
        self.assertFalse(verify(registered=False))
        self.assertFalse(planner.preservation_export_correction_inputs(source, source))
        self.assertFalse(planner.preservation_export_correction_inputs("c" * 40, head))

    def test_corrected_selector_pins_all_original_products_and_new_test_blob(self):
        base, head = "b" * 40, "a" * 40
        products = dict(planner.PRESERVATION_EXPORT_BLOBS)
        before = products[planner.MEMORY_TEST_PATH][0]
        products[planner.MEMORY_TEST_PATH] = (before, planner.PRESERVATION_EXPORT_CORRECTION_BLOBS[1])
        blobs = products | planner.PRESERVATION_EXPORT_DOC_BLOBS
        raw = "".join(f":{'000000' if old == '0' * 40 else '100644'} 100644 {old} {new} {'A' if old == '0' * 40 else 'M'}\0{path}\0"
                      for path, (old, new) in blobs.items())
        def git(*args):
            if args[0] == "diff": return raw
            if args[0] == "rev-parse": return planner.PRESERVATION_EXPORT_WORKFLOWS[args[1].split(":", 1)[1]]
            if args[0] == "show": return "new test contents"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git), \
                patch.object(planner, "preservation_export_correction_inputs", return_value=True), \
                patch.object(planner, "memory_tests_available", return_value=True), \
                patch.object(planner, "comparison_base", return_value=base):
            self.assertTrue(planner.preservation_export_only(list(blobs), base, head))
            self.assertEqual(planner.runtime_scope(list(blobs), {}, {"GITHUB_SHA": head}), planner.PRESERVATION_EXPORT_SCOPE)
            self.assertEqual(planner.required_jobs(list(blobs), planner.PRESERVATION_EXPORT_SCOPE),
                             planner.required_jobs_from_scope(planner.PRESERVATION_EXPORT_SCOPE))
            with patch.object(planner, "preservation_export_correction_inputs", return_value=False):
                self.assertFalse(planner.preservation_export_only(list(blobs), base, head))


class PreservationSharingPlanTests(unittest.TestCase):
    def test_backend_plan_requires_actual_same_repo_workflow_and_never_uses_native_reuse(self):
        env = {"GITHUB_WORKFLOW": "Sharing service check", "GITHUB_EVENT_NAME": "push", "GITHUB_REPOSITORY": "soso-so-27/neko-widget",
               "GITHUB_SHA": "a" * 40, "GITHUB_RUN_ID": "7"}
        identity = {"id": 5, "path": ".github/workflows/sharing-service.yml", "state": "active"}
        run = {"id": 7, "workflow_id": 5, "path": identity["path"], "event": "push", "head_sha": env["GITHUB_SHA"],
               "repository": {"full_name": env["GITHUB_REPOSITORY"]},
               "head_repository": {"full_name": env["GITHUB_REPOSITORY"]}, "head_branch": "main"}
        def verify(value):
            with patch.object(planner, "github_api", side_effect=[identity, value]), \
                    patch.object(planner, "find_evidence", side_effect=AssertionError("backend cannot reuse native evidence")):
                return planner.preservation_sharing_plan(env)
        self.assertTrue(verify(run))
        self.assertTrue(verify(run | {"head_branch": "codex/export"}))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); event = root / "event.json"; event.write_text("{}")
            main_env = env | {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/main",
                "GITHUB_EVENT_PATH": str(event), "GITHUB_OUTPUT": str(root / "output"),
                "GITHUB_STEP_SUMMARY": str(root / "summary")}
            with patch.dict(os.environ, main_env), \
                    patch.object(planner, "changed_paths", return_value=list(scope.PRESERVATION_EXPORT_PATHS)), \
                    patch.object(planner, "runtime_scope", return_value=scope.PRESERVATION_EXPORT_SCOPE), \
                    patch.object(planner, "github_api", side_effect=[identity, run]), \
                    patch.object(planner, "find_evidence", side_effect=AssertionError("backend cannot wait for itself")):
                planner.main()
            output = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
            self.assertEqual(output["runtime_scope"], scope.PRESERVATION_EXPORT_SCOPE)
            self.assertTrue(all(output[flag] == "false" for flag in ("build", "smoke", "sharing", "app_ui")))
            # PR remains a supported backend selection event, but cannot be
            # treated as a successful candidate push or wait for native reuse.
            (root / "output").write_text("")
            event.write_text(json.dumps({"pull_request": {"head": {"repo": {"full_name": env["GITHUB_REPOSITORY"]}}}}))
            with patch.dict(os.environ, main_env | {"GITHUB_EVENT_NAME": "pull_request", "GITHUB_REF": "refs/pull/1/merge"}), \
                    patch.object(planner, "changed_paths", return_value=list(scope.PRESERVATION_EXPORT_PATHS)), \
                    patch.object(planner, "runtime_scope", return_value=scope.PRESERVATION_EXPORT_SCOPE), \
                    patch.object(planner, "github_api", side_effect=AssertionError("PR is not candidate evidence")):
                planner.main()
            pr_output = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
            self.assertEqual(pr_output["runtime_scope"], scope.PRESERVATION_EXPORT_SCOPE)
        for key, value in (("id", 8), ("workflow_id", 6), ("path", ".github/workflows/ios-build.yml"),
                ("event", "pull_request"), ("head_sha", "b" * 40), ("head_branch", "diagnostic/export"),
                ("repository", {"full_name": "other/repo"}), ("head_repository", {"full_name": "other/repo"})):
            with self.subTest(key=key), self.assertRaises(ValueError): verify(run | {key: value})
        with patch.object(planner, "github_api", side_effect=AssertionError("wrong audience")):
            self.assertFalse(planner.preservation_sharing_plan(env | {"GITHUB_WORKFLOW": "iOS build check"}))


class MembershipManagementScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def candidate(self):
        products = {path: ("c" * 40, "d" * 40) for path in scope.MEMBERSHIP_MANAGEMENT_PATHS}
        pairs = {path: ("before " + path, "after " + path) for path in scope.MEMBERSHIP_MANAGEMENT_COMPANIONS}
        selector = "NekoWidget/ci/plan-ios-ci.py"
        empty = "MEMBERSHIP_MANAGEMENT_COMPANION_DIGESTS = {}\n"
        pairs[selector] = (pairs[selector][0], empty + "# reviewed selector\n")
        bindings = {path: list(map(scope.source_digest, pair)) for path, pair in pairs.items()}
        literal = "MEMBERSHIP_MANAGEMENT_COMPANION_DIGESTS = " + json.dumps(bindings, indent=4, sort_keys=True) + "\n"
        pairs[selector] = (pairs[selector][0], pairs[selector][1].replace(empty, literal))
        rows = {path: f":100644 100644 {before} {after} M" for path, (before, after) in products.items()}
        rows.update({path: f":100644 100644 {'e' * 40} {'f' * 40} M" for path in pairs})
        source = "final class SoloMemoriesUITests: XCTestCase {\n" + "".join(
            "    func " + test.rsplit("/", 1)[-1] + "() {}\n" for test in scope.MEMBERSHIP_MANAGEMENT_TESTS[:4])
        source += "}\n"
        return products, pairs, bindings, rows, source

    def verify(self, rows, *, paths=None, mutated=None, extra="", source=None, workflow=None, runtime=False):
        products, pairs, bindings, _, valid_source = self.candidate()
        def git(*args):
            if args[0] == "diff":
                return "".join(header + "\0" + path + "\0" for path, header in rows.items()) + extra
            if args[0] == "show":
                ref, path = args[1].split(":", 1)
                if path == scope.MEMORY_TEST_PATH:
                    return valid_source if source is None else source
                return pairs[path][int(ref == self.head)] + ("# altered" if path == mutated else "")
            if args[0] == "rev-parse":
                return workflow or planner.MEMBERSHIP_MANAGEMENT_WORKFLOW_BLOB
            if args[0] == "merge-base":
                return self.base
            raise AssertionError(args)
        candidate_paths = list(rows) if paths is None else paths
        with patch.object(planner, "git", side_effect=git), \
                patch.object(planner, "comparison_base", return_value=self.base), \
                patch.object(planner, "MEMBERSHIP_MANAGEMENT_BLOBS", products), \
                patch.object(planner, "MEMBERSHIP_MANAGEMENT_COMPANION_DIGESTS", bindings):
            if runtime:
                return planner.runtime_scope(candidate_paths, {}, {"GITHUB_SHA": self.head})
            return planner.membership_management_only(candidate_paths, self.base, self.head)

    def test_complete_products_and_self_bound_controls_select_only_this_scope(self):
        products, pairs, _, rows, _ = self.candidate()
        self.assertTrue(self.verify(rows))
        self.assertTrue(self.verify({path: rows[path] for path in products}))
        self.assertEqual(self.verify(rows, runtime=True), scope.REVIEWED_MEMBERSHIP_MANAGEMENT_SCOPE)
        self.assertEqual(self.verify({path: rows[path] for path in products}, runtime=True), scope.REVIEWED_MEMBERSHIP_MANAGEMENT_SCOPE)
        self.assertFalse(planner.membership_management_only([], self.base, self.head))
        # Before final product hash review, real pending values cannot select.
        if any("pending-review" in pair for pair in scope.MEMBERSHIP_MANAGEMENT_BLOBS.values()):
            self.assertFalse(planner.membership_management_only(list(rows), self.base, self.head))

    def test_partial_mutated_mode_unknown_or_workflow_changes_fail_closed(self):
        products, pairs, _, rows, _ = self.candidate()
        for path in rows:
            with self.subTest(missing=path):
                missing = {key: value for key, value in rows.items() if key != path}
                self.assertFalse(self.verify(missing))
                self.assertEqual(self.verify(missing, runtime=True), scope.FULL_SCOPE)
            for mode in ("100755", "120000", "160000", "000000"):
                changed = dict(rows); changed[path] = changed[path].replace("100644", mode)
                self.assertFalse(self.verify(changed), (path, mode))
            for status in ("A", "D", "T", "R100", "C100"):
                changed = dict(rows); changed[path] = changed[path][:-1] + status
                self.assertFalse(self.verify(changed), (path, status))
        for path, pair in products.items():
            for blob in pair:
                changed = dict(rows); changed[path] = changed[path].replace(blob, "1" * 40)
                self.assertFalse(self.verify(changed), (path, blob))
                self.assertEqual(self.verify(changed, runtime=True), scope.FULL_SCOPE)
        for path in pairs:
            self.assertFalse(self.verify(rows, mutated=path), path)
            self.assertEqual(self.verify(rows, mutated=path, runtime=True), scope.FULL_SCOPE)
        for path in ("NekoWidget/Shared/MembershipAccessPolicy.swift", "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                     "NekoWidget/NekoWidget.xcodeproj/project.pbxproj", scope.CI_WORKFLOW,
                     "NekoWidget/ci/preflight-ci.py", "NekoWidget/NekoWidget/Services/NewStore.swift"):
            changed = rows | {path: f":100644 100644 {'c' * 40} {'d' * 40} M"}
            self.assertFalse(self.verify(changed), path)
            self.assertEqual(self.verify(changed, runtime=True), scope.FULL_SCOPE)
        self.assertFalse(self.verify(rows, workflow="1" * 40))
        self.assertEqual(self.verify(rows, workflow="1" * 40, runtime=True), scope.FULL_SCOPE)
        first = next(iter(rows))
        self.assertFalse(self.verify(rows, paths=list(rows) + [first]))
        self.assertFalse(self.verify(rows, extra=rows[first] + "\0" + first + "\0"))
        handoff = rows | {"handoffs/membership-management.md": f":000000 100644 {'0' * 40} {'d' * 40} A"}
        self.assertTrue(self.verify(handoff))
        handoff["handoffs/membership-management.md"] = handoff["handoffs/membership-management.md"].replace("100644", "120000")
        self.assertFalse(self.verify(handoff))

    def test_all_four_methods_and_available_git_evidence_are_required(self):
        _, _, _, rows, source = self.candidate()
        for test in scope.MEMBERSHIP_MANAGEMENT_TESTS:
            method = test.rsplit("/", 1)[-1]
            self.assertFalse(self.verify(rows, source=source.replace("func " + method, "func missing")), test)
            self.assertEqual(self.verify(rows, source=source.replace("func " + method, "func missing"), runtime=True), scope.FULL_SCOPE)
        self.assertFalse(self.verify(rows, source=source.replace("SoloMemoriesUITests", "OtherUITests")))
        self.assertFalse(self.verify(rows, source=source.replace("func testMembershipOfferPreviewReturnsToPurpose() {}",
            "/* func testMembershipOfferPreviewReturnsToPurpose() {} */")))
        with patch.object(planner, "comparison_base", return_value=self.base), \
                patch.object(planner, "git", side_effect=subprocess.CalledProcessError(1, "git")):
            self.assertEqual(planner.runtime_scope(sorted(scope.MEMBERSHIP_MANAGEMENT_PATHS), {}, {"GITHUB_SHA": self.head}), scope.FULL_SCOPE)


class PlanTests(unittest.TestCase):
    def test_billing_operator_scope_is_closed_and_requires_owning_tests(self):
        paths = sorted(planner.BILLING_OPERATOR_PATHS) + ["handoffs/operator.md"]
        def selected(changed=paths, *, altered=None, duplicate=False, wired=True):
            def git(*args):
                if args[0] == "diff":
                    rows = []
                    for path in ([changed[0]] * len(changed) if duplicate else changed):
                        modes, status = ((":000000 100644", "A") if path == planner.BILLING_OPERATOR_ENTRY
                                         else (":100644 100644", "M"))
                        if altered and path == altered[0]: modes, status = altered[1:]
                        rows.append(f"{modes} {'c' * 40} {'d' * 40} {status}\0{path}\0")
                    return "".join(rows)
                if args[0] == "show":
                    return (planner.BILLING_OPERATOR_WORKFLOW_STEP if "ios-build.yml" in args[1]
                            else planner.SHARING_OPERATOR_GUARD * 3) if wired else "unwired"
                return self.sha
            with patch.object(planner, "comparison_base", return_value="b" * 40), \
                    patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(changed, {}, self.env)
        self.assertEqual(selected(), planner.BILLING_OPERATOR_SCOPE)
        for path in planner.BILLING_OPERATOR_PATHS:
            self.assertEqual(selected([path]), planner.BILLING_OPERATOR_SCOPE)
            for mode, status in ((":100644 100755", "M"), (":100644 120000", "T"),
                                 (":100644 000000", "D"), (":100644 100644", "R100")):
                self.assertEqual(selected(altered=(path, mode, status)), scope.FULL_SCOPE)
            if path != planner.BILLING_OPERATOR_ENTRY:
                self.assertEqual(selected(altered=(path, ":000000 100644", "A")), scope.FULL_SCOPE)
        for extra in ("NekoWidget/SharingService/src/billing-gateway.ts", "NekoWidget/SharingService/package.json",
                      "NekoWidget/SharingService/scripts/unknown.mjs", "NekoWidget/Shared/Models/Photo.swift",
                      ".github/workflows/sharing-service.yml", "NekoWidget/ci/plan-ios-ci.py"):
            self.assertEqual(selected(paths + [extra]), scope.FULL_SCOPE, extra)
        self.assertEqual(selected(wired=False), scope.FULL_SCOPE)
        self.assertEqual(selected(duplicate=True), scope.FULL_SCOPE)
        self.assertEqual(selected(paths + [paths[0]]), scope.FULL_SCOPE)

    def test_billing_operator_owning_tests_run_without_native_or_release_evidence(self):
        paths = sorted(planner.BILLING_OPERATOR_PATHS)
        self.assertEqual(planner.required_jobs(paths, planner.BILLING_OPERATOR_SCOPE), (planner.PLAN_JOB,))
        self.assertEqual(planner.required_jobs(paths + ["unknown.swift"], planner.BILLING_OPERATOR_SCOPE), planner.FULL)
        self.assertNotIn(planner.BILLING_OPERATOR_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.BILLING_OPERATOR_SCOPE)
        root = Path(__file__).resolve().parents[2]
        self.assertEqual((root / ".github/workflows/ios-build.yml").read_text(encoding="utf-8")
                         .count(planner.BILLING_OPERATOR_WORKFLOW_STEP), 1)
        backend = (root / ".github/workflows/sharing-service.yml").read_text(encoding="utf-8")
        self.assertEqual(backend.count(planner.SHARING_OPERATOR_GUARD), 3)
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory); (temp / "event.json").write_text("{}")
            env = dict(self.env, GITHUB_EVENT_PATH=str(temp / "event.json"),
                       GITHUB_OUTPUT=str(temp / "output"), GITHUB_STEP_SUMMARY=str(temp / "summary"))
            with patch.dict(os.environ, env), patch.object(planner, "changed_paths", return_value=paths), \
                    patch.object(planner, "runtime_scope", return_value=planner.BILLING_OPERATOR_SCOPE), \
                    patch.object(planner, "find_evidence") as lookup:
                planner.main()
            lookup.assert_not_called()
            output = dict(line.split("=", 1) for line in (temp / "output").read_text().splitlines())
            self.assertTrue(all(output[name] == "false" for name in ("build", "smoke", "sharing", "app_ui")))
            self.assertEqual(output["matrix_lanes"], "[]")

    def test_backend_orchestration_exemption_preserves_all_backend_commands(self):
        path = ".github/workflows/sharing-service.yml"
        after = (Path(__file__).resolve().parents[2] / path).read_text(encoding="utf-8")
        before = after.replace(planner.SHARING_OPERATOR_GUARD, "")
        def matches(new):
            def git(*args):
                if args[0] == "show": return before if args[1].startswith("base:") else new
                return f":100644 100644 {'c' * 40} {'d' * 40} M\0{path}\0"
            with patch.object(planner, "git", side_effect=git):
                return planner.orchestration_only([path], "base", "head")
        self.assertTrue(matches(after))
        self.assertFalse(matches(after.replace(planner.SHARING_OPERATOR_GUARD, "", 1)))
        self.assertFalse(matches(after.replace("node-version: \"22\"", "node-version: \"24\"", 1)))
        self.assertFalse(matches(after.replace("npm run typecheck", "echo skipped", 1)))
        moved_guard = after.replace(planner.SHARING_OPERATOR_GUARD, "", 1)
        moved_guard = moved_guard.replace("npm run typecheck", "npm run typecheck" + planner.SHARING_OPERATOR_GUARD, 1)
        self.assertFalse(matches(moved_guard))
        self.assertFalse(matches(after.replace('"$GITHUB_SHA"', '"$RELEASE_SOURCE_SHA"'))
                         if '"$GITHUB_SHA"' in after else matches(after + '\n      run: "$RELEASE_SOURCE_SHA"\n'))
        self.assertFalse(matches(after.replace("needs.plan.outputs.scope == 'billing-private-service-v2'", "false")))
        self.assertFalse(matches(after + "\n  unreviewed-job:\n    run: deploy\n"))

    def test_policy_docs_require_closed_paths_modes_and_owning_workflow_check(self):
        paths = ["docs/privacy/index.html", "docs/support/index.html", "handoffs/policy.md"]
        def selected(changed=paths, *, mode=":100644 100644", status="M", wired=True, duplicate=False):
            def git(*args):
                if args[0] == "diff":
                    raw_paths = [changed[0]] * len(changed) if duplicate else changed
                    return "".join(f"{mode} {'c' * 40} {'d' * 40} {status}\0{path}\0" for path in raw_paths)
                if args[0] == "show":
                    return planner.POLICY_DOC_WORKFLOW_STEP if wired else "no HTML check"
                return self.sha
            with patch.object(planner, "comparison_base", return_value="b" * 40), \
                    patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(changed, {}, self.env)
        for path in planner.POLICY_DOC_PATHS:
            self.assertEqual(selected([path]), planner.POLICY_DOC_SCOPE)
        self.assertEqual(selected(), planner.POLICY_DOC_SCOPE)
        for extra in ("docs/unknown.html", "docs/privacy/script.js", "NekoWidget/ci/plan-ios-ci.py",
                      ".github/workflows/ios-build.yml", "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                      "NekoWidget/NekoWidget/Views/HomeView.swift", "NekoWidget/Config.xcconfig"):
            self.assertEqual(selected(paths + [extra]), scope.FULL_SCOPE, extra)
        for mode, status in ((":000000 100644", "A"), (":100644 000000", "D"),
                             (":100644 100755", "M"), (":100644 120000", "T"),
                             (":100644 100644", "R100")):
            self.assertEqual(selected(mode=mode, status=status), scope.FULL_SCOPE)
        self.assertEqual(selected(wired=False), scope.FULL_SCOPE)
        self.assertEqual(selected(duplicate=True), scope.FULL_SCOPE)
        self.assertEqual(selected(paths + [paths[0]]), scope.FULL_SCOPE)

    def test_policy_doc_success_cannot_become_native_release_evidence(self):
        paths = ["docs/privacy/index.html"]
        self.assertEqual(planner.required_jobs(paths, planner.POLICY_DOC_SCOPE), (planner.PLAN_JOB,))
        self.assertEqual(planner.required_jobs(paths + ["unknown.swift"], planner.POLICY_DOC_SCOPE), planner.FULL)
        self.assertNotIn(planner.POLICY_DOC_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError):
            planner.required_jobs_from_scope(planner.POLICY_DOC_SCOPE)
        workflow = Path(__file__).resolve().parents[2] / ".github/workflows/ios-build.yml"
        self.assertEqual(workflow.read_text(encoding="utf-8").count(planner.POLICY_DOC_WORKFLOW_STEP), 1)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / "event.json").write_text("{}")
            env = dict(self.env, GITHUB_EVENT_PATH=str(root / "event.json"),
                       GITHUB_OUTPUT=str(root / "output"), GITHUB_STEP_SUMMARY=str(root / "summary"))
            with patch.dict(os.environ, env), patch.object(planner, "changed_paths", return_value=paths), \
                    patch.object(planner, "runtime_scope", return_value=planner.POLICY_DOC_SCOPE), \
                    patch.object(planner, "find_evidence") as lookup:
                planner.main()
            lookup.assert_not_called()
            output = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
            self.assertTrue(all(output[name] == "false" for name in ("build", "smoke", "sharing", "app_ui")))
            self.assertEqual(output["matrix_lanes"], "[]")

    def test_daily_tool_membership_requires_exact_sources_and_owning_ui(self):
        paths = sorted(scope.MEMBERSHIP_TOOLS_PATHS)
        self.assertEqual(len(paths), 15)
        self.assertEqual(len(scope.MEMBERSHIP_TOOLS_TESTS), 5)
        changes = {path: ("before " + path, "after " + path) for path in paths}
        declarations = "final class SoloMemoriesUITests: XCTestCase {\n" + "".join(
            "    func " + name.rsplit("/", 1)[1] + "() {}\n" for name in scope.MEMBERSHIP_TOOLS_TESTS) + "}\n"
        changes[scope.MEMORY_TEST_PATH] = ("old tests", declarations)
        bindings = {path: list(map(scope.source_digest, pair)) for path, pair in changes.items()}
        with patch.object(scope, "MEMBERSHIP_TOOLS_DIGESTS", bindings):
            self.assertEqual(scope.select_scope(changes), scope.MEMBERSHIP_TOOLS_SCOPE)
            for path in paths:
                missing = dict(changes); del missing[path]
                self.assertNotEqual(scope.select_scope(missing), scope.MEMBERSHIP_TOOLS_SCOPE)
                for side in (0, 1):
                    changed = dict(changes); pair = list(changed[path]); pair[side] += " changed"
                    changed[path] = tuple(pair)
                    self.assertEqual(scope.select_scope(changed), scope.FULL_SCOPE, (path, side))
            for extra in ("NekoWidget/NekoWidget/Info.plist", ".github/workflows/ios-build.yml",
                          "NekoWidget/NekoWidget.xcodeproj/project.pbxproj", "NekoWidget/ci/ios_ci_scope.py",
                          "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift"):
                self.assertEqual(scope.select_scope(dict(changes, **{extra: ("old", "new")})), scope.FULL_SCOPE)
            for test in scope.MEMBERSHIP_TOOLS_TESTS:
                changed = copy.deepcopy(changes)
                changed[scope.MEMORY_TEST_PATH] = ("old tests", declarations.replace(
                    "    func " + test.rsplit("/", 1)[1], "    // func " + test.rsplit("/", 1)[1]))
                rebound = dict(bindings); rebound[scope.MEMORY_TEST_PATH] = list(map(scope.source_digest, changed[scope.MEMORY_TEST_PATH]))
                with patch.object(scope, "MEMBERSHIP_TOOLS_DIGESTS", rebound):
                    self.assertEqual(scope.select_scope(changed), scope.FULL_SCOPE)
            base = "b" * 40
            def selected(modes=None, status="M", extra_raw=""):
                modes = modes or {}
                def git(*args):
                    if args[0] == "diff":
                        return "".join(f"{modes.get(path, ':100644 100644')} {'c' * 40} {'d' * 40} {status}\0{path}\0"
                                       for path in paths) + extra_raw
                    if args[0] == "show":
                        ref, path = args[1].split(":", 1)
                        return changes[path][0 if ref == base else 1]
                    return self.sha
                with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                    return planner.runtime_scope(paths, {}, self.env)
            self.assertEqual(selected(), scope.MEMBERSHIP_TOOLS_SCOPE)
            for path in paths:
                for modes in (":100644 100755", ":100644 120000", ":000000 100644", ":100644 000000"):
                    self.assertEqual(selected({path: modes}), scope.FULL_SCOPE)
            for status in ("A", "D", "T", "R100", "C100"):
                self.assertEqual(selected(status=status), scope.FULL_SCOPE)
            self.assertEqual(selected(extra_raw=f":100644 100644 {'c' * 40} {'d' * 40} M\0{paths[0]}\0"), scope.FULL_SCOPE)
        expected = (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(scope.MEMBERSHIP_TOOLS_SCOPE)
        self.assertEqual(planner.required_jobs(paths, scope.MEMBERSHIP_TOOLS_SCOPE), expected)
        self.assertEqual(scope.lanes(scope.MEMBERSHIP_TOOLS_SCOPE), ("runtime", "app-ui"))
        self.assertEqual(scope.smoke_tests(scope.MEMBERSHIP_TOOLS_SCOPE),
                         ("NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",
                          "NekoWidgetUITests/PhotoPermissionUITests/testMainlineAcceptanceScreensWithAuthorizedLibrary"))
        self.assertEqual(scope.lane_tests(scope.MEMBERSHIP_TOOLS_SCOPE, "app-ui"), scope.MEMBERSHIP_TOOLS_TESTS)
        for gallery in scope.LANES[2:]:
            with self.assertRaises(ValueError): scope.lane_tests(scope.MEMBERSHIP_TOOLS_SCOPE, gallery)
        jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success"} for name in expected]
        self.assertTrue(planner.covers_jobs(jobs, expected, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, planner.FULL, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, expected, "d" * 40))

    def test_tool_cat_autofill_requires_complete_frozen_sources_and_six_real_tests(self):
        paths = sorted(scope.TOOL_CAT_AUTOFILL_PATHS)
        self.assertEqual(len(paths), 9)
        self.assertEqual(len(scope.TOOL_CAT_AUTOFILL_TESTS), 6)
        self.assertEqual(len(set(scope.TOOL_CAT_AUTOFILL_TESTS)), 6)
        changes = {path: ("before " + path, "after " + path) for path in paths}
        declarations = "final class SoloMemoriesUITests: XCTestCase {\n" + "".join(
            "    func " + name.rsplit("/", 1)[1] + "() {}\n" for name in scope.TOOL_CAT_AUTOFILL_TESTS) + "}\n"
        changes[scope.MEMORY_TEST_PATH] = ("old tests", declarations)
        bindings = {path: list(map(scope.source_digest, pair)) for path, pair in changes.items()}
        with patch.object(scope, "TOOL_CAT_AUTOFILL_DIGESTS", bindings):
            self.assertEqual(scope.select_scope(changes), scope.TOOL_CAT_AUTOFILL_SCOPE)
            for path in paths:
                missing = dict(changes); del missing[path]
                self.assertNotEqual(scope.select_scope(missing), scope.TOOL_CAT_AUTOFILL_SCOPE)
                for side in (0, 1):
                    changed = dict(changes); pair = list(changed[path]); pair[side] += " changed"
                    changed[path] = tuple(pair)
                    self.assertEqual(scope.select_scope(changed), scope.FULL_SCOPE, (path, side))
            for extra in ("NekoWidget/Shared/Storage/AtomicJSON.swift", ".github/workflows/ios-build.yml",
                          "NekoWidget/NekoWidget.xcodeproj/project.pbxproj", "NekoWidget/ci/ios_ci_scope.py"):
                self.assertEqual(scope.select_scope(dict(changes, **{extra: ("old", "new")})), scope.FULL_SCOPE)
            # A hash declaration cannot turn absent/commented tests into evidence.
            for test in scope.TOOL_CAT_AUTOFILL_TESTS:
                changed = copy.deepcopy(changes)
                changed[scope.MEMORY_TEST_PATH] = ("old tests", declarations.replace(
                    "    func " + test.rsplit("/", 1)[1], "    // func " + test.rsplit("/", 1)[1]))
                rebound = dict(bindings); rebound[scope.MEMORY_TEST_PATH] = list(map(scope.source_digest, changed[scope.MEMORY_TEST_PATH]))
                with patch.object(scope, "TOOL_CAT_AUTOFILL_DIGESTS", rebound):
                    self.assertEqual(scope.select_scope(changed), scope.FULL_SCOPE)
            base = "b" * 40
            def selected(modes=None, status="M", extras=""):
                modes = modes or {}
                def git(*args):
                    if args[0] == "diff":
                        return "".join(f"{modes.get(path, ':100644 100644')} {'c' * 40} {'d' * 40} {status}\0{path}\0"
                                       for path in paths) + extras
                    if args[0] == "show":
                        ref, path = args[1].split(":", 1)
                        return changes[path][0 if ref == base else 1]
                    return self.sha
                with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                    return planner.runtime_scope(paths, {}, self.env)
            self.assertEqual(selected(), scope.TOOL_CAT_AUTOFILL_SCOPE)
            for path in paths:
                for modes in (":100644 100755", ":100644 120000", ":000000 100644", ":100644 000000"):
                    self.assertEqual(selected({path: modes}), scope.FULL_SCOPE)
            for status in ("A", "D", "T", "R100", "C100"):
                self.assertEqual(selected(status=status), scope.FULL_SCOPE)
            self.assertEqual(selected(extras=f":100644 100644 {'c' * 40} {'d' * 40} M\0{paths[0]}\0"), scope.FULL_SCOPE)
        expected = (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(scope.TOOL_CAT_AUTOFILL_SCOPE)
        self.assertEqual(planner.required_jobs(paths, scope.TOOL_CAT_AUTOFILL_SCOPE), expected)
        self.assertEqual(scope.lanes(scope.TOOL_CAT_AUTOFILL_SCOPE), ("runtime", "app-ui"))
        self.assertEqual(scope.smoke_tests(scope.TOOL_CAT_AUTOFILL_SCOPE),
                         ("NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",
                          "NekoWidgetUITests/PhotoPermissionUITests/testMainlineAcceptanceScreensWithAuthorizedLibrary"))
        self.assertEqual(scope.lane_tests(scope.TOOL_CAT_AUTOFILL_SCOPE, "app-ui"), scope.TOOL_CAT_AUTOFILL_TESTS)
        for gallery in scope.LANES[2:]:
            with self.assertRaises(ValueError):
                scope.lane_tests(scope.TOOL_CAT_AUTOFILL_SCOPE, gallery)
        jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success"} for name in expected]
        self.assertTrue(planner.covers_jobs(jobs, expected, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, planner.FULL, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, expected, "d" * 40))
        for index in range(len(jobs)):
            for conclusion in ("failure", "skipped", "cancelled", None):
                wrong = copy.deepcopy(jobs); wrong[index]["conclusion"] = conclusion
                self.assertFalse(planner.covers_jobs(wrong, expected, self.sha))

    def test_window_hub_requires_frozen_product_and_complete_ci_boundary(self):
        product = dict(scope.WINDOW_HUB_BLOBS)
        pairs = {path: ("before " + path, "after " + path) for path in scope.WINDOW_HUB_COMPANIONS}
        selector = "NekoWidget/ci/plan-ios-ci.py"
        empty = "WINDOW_HUB_COMPANION_DIGESTS = {}\n"
        pairs[selector] = (pairs[selector][0], empty + "# reviewed selector\n")
        bindings = {path: list(map(scope.source_digest, pair)) for path, pair in pairs.items()}
        literal = "WINDOW_HUB_COMPANION_DIGESTS = " + json.dumps(bindings, indent=4, sort_keys=True) + "\n"
        pairs[selector] = (pairs[selector][0], pairs[selector][1].replace(empty, literal))
        rows = {path: f":100644 100644 {before} {after} M" for path, (before, after) in product.items()}
        rows.update({path: f":100644 100644 {'c' * 40} {'d' * 40} M" for path in pairs})

        def verify(candidate, paths=None, extra="", mutated=None):
            def git(*args):
                if args[0] == "diff":
                    return "".join(header + "\0" + path + "\0" for path, header in candidate.items()) + extra
                if args[0] == "show":
                    ref, path = args[1].split(":", 1)
                    return pairs[path][int(ref == self.sha)] + ("# changed" if path == mutated else "")
                raise AssertionError(args)
            with patch.object(planner, "git", side_effect=git), \
                    patch.object(planner, "WINDOW_HUB_COMPANION_DIGESTS", bindings):
                return planner.window_hub_only(list(candidate) if paths is None else paths, "b" * 40, self.sha)

        self.assertTrue(verify(rows))
        self.assertTrue(verify({path: rows[path] for path in product}))
        with patch.object(planner, "comparison_base", return_value="b" * 40), \
                patch.object(planner, "window_hub_only", return_value=True):
            self.assertEqual(planner.runtime_scope(list(rows), {}, self.env), scope.WINDOW_HUB_SCOPE)
        expected = (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(scope.WINDOW_HUB_SCOPE)
        self.assertEqual(planner.required_jobs(list(rows), scope.WINDOW_HUB_SCOPE), expected)
        self.assertEqual(scope.lanes(scope.WINDOW_HUB_SCOPE), ("runtime", "app-ui"))
        source = (Path(__file__).resolve().parents[2] / scope.MEMORY_TEST_PATH).read_text(encoding="utf-8")
        self.assertEqual(scope.native_tests(scope.WINDOW_HUB_SCOPE), scope.diagnostic_tests(
            "OfficialWindowUITests", ",".join(test.rsplit("/", 1)[-1] for test in scope.WINDOW_HUB_TESTS), source))
        self.assertEqual(len(scope.WINDOW_HUB_TESTS), 3)
        for path in rows:
            missing = dict(rows)
            del missing[path]
            self.assertFalse(verify(missing), path)
            for mode in ("100755", "120000", "160000"):
                changed = dict(rows)
                changed[path] = changed[path].replace("100644", mode)
                self.assertFalse(verify(changed), (path, mode))
        for path, (before, after) in product.items():
            for blob in (before, after):
                changed = dict(rows)
                changed[path] = changed[path].replace(blob, "e" * 40)
                self.assertFalse(verify(changed), path)
        for path in pairs:
            self.assertFalse(verify(rows, mutated=path), path)
        for unknown in ("NekoWidget/Shared/Models/Photo.swift", ".github/workflows/ios-build.yml",
                        "NekoWidget/NekoWidget.xcodeproj/project.pbxproj"):
            self.assertFalse(verify(dict(rows, **{unknown: f":000000 100644 {'0' * 40} {'e' * 40} A"})))
        first = next(iter(rows))
        self.assertFalse(verify(rows, paths=list(rows) + [first]))
        self.assertFalse(verify(rows, extra=rows[first] + "\0" + first + "\0"))
        handoff = dict(rows, **{"handoffs/window-hub.md": f":000000 100644 {'0' * 40} {'e' * 40} A"})
        self.assertTrue(verify(handoff))
        handoff["handoffs/window-hub.md"] = handoff["handoffs/window-hub.md"].replace("100644", "120000")
        self.assertFalse(verify(handoff))

    def test_tools_hub_requires_exact_pixels_sources_and_complete_companions(self):
        product = dict(scope.TOOLS_HUB_BLOBS)
        before_after = {path: ("before " + path, "after " + path)
                        for path in scope.TOOLS_HUB_COMPANIONS}
        selector = "NekoWidget/ci/plan-ios-ci.py"
        empty = "TOOLS_HUB_COMPANION_DIGESTS = {}\n"
        before_after[selector] = (before_after[selector][0], empty + "# reviewed logic\n")
        bindings = {path: list(map(scope.source_digest, pair)) for path, pair in before_after.items()}
        literal = "TOOLS_HUB_COMPANION_DIGESTS = " + json.dumps(bindings, indent=4, sort_keys=True) + "\n"
        before_after[selector] = (before_after[selector][0], before_after[selector][1].replace(empty, literal))
        def records(companions=False):
            rows = {}
            for path, (old, new) in product.items():
                modes, status = (":000000 100644", "A") if old == "0" * 40 else (":100644 100644", "M")
                rows[path] = f"{modes} {old} {new} {status}"
            if companions:
                rows.update({path: f":100644 100644 {'c' * 40} {'d' * 40} M" for path in before_after})
            return rows
        def select(rows, sources=None, raw_extra="", mutate_companion=False):
            def git(*args):
                if args[0] == "diff":
                    return "".join(header + "\0" + path + "\0" for path, header in rows.items()) + raw_extra
                if args[0] == "show":
                    ref, path = args[1].split(":", 1)
                    return before_after[path][int(ref == self.sha)] + ("# changed" if mutate_companion else "")
                raise AssertionError(args)
            with patch.object(planner, "comparison_base", return_value="b" * 40), \
                    patch.object(planner, "git", side_effect=git), \
                    patch.object(planner, "TOOLS_HUB_COMPANION_DIGESTS", bindings):
                return planner.runtime_scope(list(rows) if sources is None else sources, {}, self.env)
        self.assertEqual(select(records()), scope.TOOLS_HUB_SCOPE)
        self.assertEqual(select(records(True)), scope.TOOLS_HUB_SCOPE)
        expected = (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(scope.TOOLS_HUB_SCOPE)
        self.assertEqual(planner.required_jobs(list(records(True)), scope.TOOLS_HUB_SCOPE), expected)
        self.assertEqual(scope.lanes(scope.TOOLS_HUB_SCOPE), ("runtime", "app-ui"))
        self.assertEqual(len(scope.native_tests(scope.TOOLS_HUB_SCOPE)), 3)
        self.assertIn("NekoWidgetUITests/SoloMemoriesUITests/testToolsReplaceAlbumShowcaseEntryAtStandardAndLargeText",
                      scope.native_tests(scope.TOOLS_HUB_SCOPE))
        for path in product:
            changed = records()
            changed[path] = changed[path].replace(product[path][1], "e" * 40)
            self.assertEqual(select(changed), scope.FULL_SCOPE, path)
            missing = records()
            del missing[path]
            self.assertEqual(select(missing), scope.FULL_SCOPE, path)
        image = next(path for path in product if path.endswith(".png"))
        for mode in ("100755", "120000", "160000"):
            changed = records()
            changed[image] = changed[image].replace("100644", mode)
            self.assertEqual(select(changed), scope.FULL_SCOPE)
        for companion in before_after:
            changed = records(True)
            del changed[companion]
            self.assertEqual(select(changed), scope.FULL_SCOPE)
        self.assertEqual(select(records(True), mutate_companion=True), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/Shared/Models/Photo.swift", "NekoWidget/NekoWidget.xcodeproj/project.pbxproj",
                        ".github/workflows/ios.yml", "NekoWidget/NekoWidget/Assets.xcassets/Other.imageset/a.png"):
            changed = records()
            changed[unknown] = f":000000 100644 {'0' * 40} {'e' * 40} A"
            self.assertEqual(select(changed), scope.FULL_SCOPE)
        self.assertEqual(select(records(), sources=list(records()) + [image]), scope.FULL_SCOPE)
        self.assertEqual(select(records(), raw_extra=records()[image] + "\0" + image + "\0"), scope.FULL_SCOPE)
        handoff = records()
        handoff["handoffs/tools.md"] = f":000000 100644 {'0' * 40} {'d' * 40} A"
        self.assertEqual(select(handoff), scope.TOOLS_HUB_SCOPE)
        handoff["handoffs/tools.md"] = f":000000 120000 {'0' * 40} {'d' * 40} A"
        self.assertEqual(select(handoff), scope.FULL_SCOPE)

    @staticmethod
    def jpeg_changes(companions=True, profile="JPEG"):
        workflow = getattr(planner, profile + "_WORKFLOW")
        companion_paths = getattr(planner, profile + "_COMPANION_PATHS")
        product = ("NekoWidget/PreservationImageValidator/src/provider.ts" if profile == "JPEG"
                   else "NekoWidget/PreservationService/src/index.ts")
        changes = {product: ("", "reviewed provider"),
                   workflow: ("", "name: " + getattr(planner, profile + "_JOB") + "\ntimeout-minutes: 5\n")}
        if companions:
            changes.update({path: ("before " + path, "after " + path) for path in companion_paths})
            selector = "NekoWidget/ci/plan-ios-ci.py"
            empty = profile + "_COMPANION_DIGESTS = {}\n"
            changes[selector] = (changes[selector][0], empty + "# complete reviewed selector\n")
            bindings = {path: list(map(scope.source_digest, changes[path])) for path in companion_paths}
            literal = profile + "_COMPANION_DIGESTS = " + json.dumps(bindings, indent=4, sort_keys=True) + "\n"
            changes[selector] = (changes[selector][0], changes[selector][1].replace(empty, literal))
        else:
            bindings = {}
        return changes, bindings

    def test_private_billing_backend_requires_all_frozen_dependencies_and_workflows(self):
        path = next(iter(planner.BILLING_PATHS))
        changed = [path]
        self.assertEqual(planner.BILLING_SCOPE, "billing-private-service-v2")
        self.assertNotIn(planner.BILLING_JOB, planner.required_jobs(list(planner.BILLING_PATHS), planner.BILLING_SCOPE))
        snapshot = dict(planner.BILLING_REVIEWED_TREES)
        def frozen_git(*args):
            if args[0] == "rev-parse":
                return snapshot[args[1].split(":NekoWidget/", 1)[1]]
            if args[0] == "show":
                return "frozen preservation workflow"
            raise AssertionError(args)
        digest = scope.source_digest("frozen preservation workflow")
        with patch.object(planner, "git", side_effect=frozen_git), \
                patch.object(planner, "PRESERVATION_WORKFLOW_DIGEST", digest), \
                patch.object(planner, "backend_only", return_value=True) as boundary:
            self.assertTrue(planner.billing_backend_only(changed, "base", "head"))
            self.assertEqual(boundary.call_args.kwargs["binding_name"], "BILLING_COMPANION_DIGESTS")
            for dependency in planner.BILLING_REVIEWED_TREES:
                wrong = dict(planner.BILLING_REVIEWED_TREES); wrong[dependency] = "0" * 40
                with patch.object(planner, "BILLING_REVIEWED_TREES", wrong):
                    self.assertFalse(planner.billing_backend_only(changed, "base", "head"))
            with patch.object(planner, "PRESERVATION_WORKFLOW_DIGEST", "wrong"):
                self.assertFalse(planner.billing_backend_only(changed, "base", "head"))
        self.assertEqual(planner.required_jobs(changed, planner.BILLING_SCOPE),
                         (planner.BILLING_CALLER_JOB, planner.PRESERVATION_JOB))
        for unknown in ("NekoWidget/NekoWidget/Views/PhotoView.swift", "NekoWidget/Config.xcconfig",
                        "NekoWidget/BillingVerificationService/src/unknown.ts"):
            self.assertFalse(planner.billing_paths_only(changed + [unknown]))
            self.assertEqual(planner.required_jobs(changed + [unknown], planner.BILLING_SCOPE), planner.FULL)
        self.assertFalse(planner.billing_paths_only(changed + [next(iter(planner.BILLING_COMPANION_PATHS))]))
        with self.assertRaises(ValueError):
            planner.required_jobs_from_scope(planner.BILLING_SCOPE)

    def test_internal_release_preparation_is_frozen_and_never_native_evidence(self):
        changed = {path: ("before " + path, "after " + path)
                   for path in planner.RELEASE_PREP_PATHS}
        changed[planner.RELEASE_PREP_WORKFLOW] = ("old CI", "frozen plan CI")
        product_digests = {path: list(map(scope.source_digest, pair))
                           for path, pair in changed.items() if path in planner.RELEASE_PREP_PATHS}
        workflow_digest = scope.source_digest("frozen plan CI")
        def select(candidate, ancestor=True):
            def git(*args):
                if args[0] == "merge-base":
                    if not ancestor:
                        raise subprocess.CalledProcessError(1, "git")
                    return ""
                if args[0] == "show":
                    ref, path = args[1].split(":", 1)
                    return candidate[path][1 if ref == self.sha else 0]
                if args[0] == "diff":
                    return "".join(f":100644 100644 {'c' * 40} {'d' * 40} M\0{path}\0"
                                   for path in sorted(candidate))
                raise AssertionError(args)
            with patch.object(planner, "comparison_base", return_value="base"), \
                    patch.object(planner, "git", side_effect=git), \
                    patch.object(planner, "RELEASE_PREP_PRODUCTS", product_digests), \
                    patch.object(planner, "RELEASE_PREP_WORKFLOW_DIGEST", workflow_digest):
                return planner.runtime_scope(sorted(candidate), {}, self.env)
        self.assertEqual(select(changed), planner.RELEASE_PREP_SCOPE)
        self.assertEqual(planner.required_jobs(sorted(changed), planner.RELEASE_PREP_SCOPE),
                         (planner.PLAN_JOB, planner.RELEASE_PREP_BACKEND_PLAN_JOB))
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/sharing-service.yml").read_text(encoding="utf-8")
        guarded = "if: needs.plan.outputs.scope != 'billing-private-service-v2' && needs.plan.outputs.scope != 'internal-billing-release-prep-v1'"
        self.assertEqual(workflow.count(guarded), 3)
        for path in planner.RELEASE_PREP_PATHS | {planner.RELEASE_PREP_WORKFLOW}:
            mutated = dict(changed); mutated[path] = (mutated[path][0], mutated[path][1] + " drift")
            self.assertEqual(select(mutated), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/NekoWidget/Views/SettingsView.swift", "NekoWidget/Config.xcconfig",
                        "NekoWidget/Shared/Models/Photo.swift", "NekoWidget/NekoWidget/Info.plist"):
            mixed = dict(changed); mixed[unknown] = ("old", "new")
            self.assertEqual(select(mixed), scope.FULL_SCOPE)
        mixed = dict(changed); mixed[next(iter(planner.RELEASE_PREP_COMPANION_PATHS))] = ("old", "new")
        self.assertEqual(select(mixed), scope.FULL_SCOPE)
        self.assertEqual(select(changed, ancestor=False), scope.FULL_SCOPE)
        with self.assertRaises(ValueError):
            planner.required_jobs_from_scope(planner.RELEASE_PREP_SCOPE)

    def test_preservation_backend_requires_frozen_introduction_and_rejects_mixed_or_unsafe_inputs(self):
        original, bindings = self.jpeg_changes(profile="PRESERVATION")
        migration = "NekoWidget/PreservationService/migrations/0004_upload_owner_index.sql"
        original[migration] = ("", "CREATE INDEX pa_upload_owner_bytes ON pa_uploads(owner_id,reserved_bytes);\n")
        workflow_digest = scope.source_digest(original[planner.PRESERVATION_WORKFLOW][1])
        def select(changes, alter=lambda raw: raw, ancestor=True, tree_ok=True):
            def git(*args):
                if args[0] == "rev-parse" and args[1].endswith(":NekoWidget/PreservationService"):
                    return planner.PRESERVATION_REVIEWED_TREE if tree_ok else "0" * 40
                if args[0] == "merge-base":
                    if not ancestor:
                        raise subprocess.CalledProcessError(1, "git")
                    return ""
                if args[0] == "diff":
                    return alter("".join(f"{':100644 100644' if pair[0] else ':000000 100644'} "
                        f"{'c' * 40} {'d' * 40} {'M' if pair[0] else 'A'}\0{path}\0"
                        for path, pair in sorted(changes.items())))
                if args[0] == "show":
                    revision, path = args[1].split(":", 1)
                    return changes[path][1 if revision == self.sha else 0]
                raise AssertionError(args)
            with patch.object(planner, "comparison_base", return_value="b" * 40), \
                    patch.object(planner, "git", side_effect=git), \
                    patch.object(planner, "PRESERVATION_WORKFLOW_DIGEST", workflow_digest), \
                    patch.object(planner, "PRESERVATION_COMPANION_DIGESTS", bindings):
                return planner.runtime_scope(sorted(changes), {}, self.env)
        pilot_new_paths = (
            "migrations/0025_intake_control.sql", "migrations/0026_pilot_control.sql",
            "operations/pilot-plan.json", "scripts/estimate-pilot-budget.mjs",
            "src/intake-control.ts", "src/pilot-control.ts",
            "test/intake-control.test.ts", "test/pilot-control.test.ts", "test/pilot-wiring.test.ts",
        )
        self.assertEqual(len(planner.PRESERVATION_PATHS), 175)
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertIn("NekoWidget/PreservationService/migrations/0029_general_admission.sql", planner.PRESERVATION_PATHS)
        self.assertIn("NekoWidget/PreservationService/migrations/0030_general_cost_review.sql", planner.PRESERVATION_PATHS)
        self.assertTrue(all("NekoWidget/PreservationService/" + path in planner.PRESERVATION_PATHS
                            for path in pilot_new_paths))
        self.assertIn("NekoWidget/PreservationService/src/owner-deletion-worker.ts", planner.PRESERVATION_PATHS)
        self.assertEqual(select(original), planner.PRESERVATION_SCOPE)
        plain, _ = self.jpeg_changes(companions=False, profile="PRESERVATION")
        self.assertEqual(select({migration: original[migration],
                                 planner.PRESERVATION_WORKFLOW: plain[planner.PRESERVATION_WORKFLOW]}),
                         planner.PRESERVATION_SCOPE)
        self.assertEqual(select({**plain, "handoffs/custody.md": ("", "notes")}), planner.PRESERVATION_SCOPE)
        self.assertEqual(select({**plain, "NekoWidget/PreservationService/test/key-fixture.ts": ("", "synthetic helper")}),
                         planner.PRESERVATION_SCOPE)
        for path in ("src/billing-link-protocol.ts", "src/membership-links.ts", "src/billing-authority.ts",
                     "migrations/0003_membership_links.sql", "wrangler.billing.disabled.jsonc",
                     "test/membership-links.test.ts", "test/billing-authority.test.ts",
                     "src/aws-kms-key-wrapper.ts", "test/aws-kms-key-wrapper.test.ts", "wrangler.kms.disabled.jsonc",
                     "migrations/0005_retention_ledger.sql", "src/retention-ledger.ts", "test/retention-ledger.test.ts",
                     "migrations/0006_notice_contact.sql", "migrations/0007_notice_submissions.sql",
                     "src/notice-events.ts", "src/notice-submissions.ts",
                     "test/notice-events.test.ts", "test/notice-submissions.test.ts",
                     "migrations/0017_purge_execution_claims.sql", "migrations/0018_purge_claim_lease.sql", "src/owner-purge-abort.ts",
                     "test/owner-purge-abort.test.ts", "test/purge-execution-claims.test.ts",
                     "src/owner-snapshot-codec.ts", "test/owner-snapshot-codec.test.ts"):
            self.assertEqual(select({**plain, "NekoWidget/PreservationService/" + path: ("", "reviewed addition")}),
                             planner.PRESERVATION_SCOPE)
        for path in pilot_new_paths:
            self.assertEqual(select({**plain, "NekoWidget/PreservationService/" + path: ("", "reviewed addition")}),
                             planner.PRESERVATION_SCOPE)
        self.assertEqual(select({**plain, **{"NekoWidget/PreservationService/" + path: ("", "reviewed addition")
                                            for path in pilot_new_paths}}), planner.PRESERVATION_SCOPE)
        for path in ("migrations/0019_prepared_owner_fence.sql", "migrations/0024_purge_event_delete_guard.sql",
                     "src/owner-d1-erase.ts", "src/recovery-write-lease.ts", "src/owner-cloud-erase.ts",
                     "test/owner-d1-erase.test.ts", "test/s3-purge-manifest.test.ts"):
            self.assertEqual(select({**plain, "NekoWidget/PreservationService/" + path: ("", "reviewed addition")}),
                             planner.PRESERVATION_SCOPE)
        self.assertEqual(select(original, ancestor=False), scope.FULL_SCOPE)
        # Same filenames with any different service content (including an
        # in-place sender, Queue binding, or deletion) must not use v23.
        self.assertEqual(select(original, tree_ok=False), scope.FULL_SCOPE)
        for extra in ("NekoWidget/PreservationService/src/new.ts",
                      "NekoWidget/PreservationService/src/notice-sender.ts",
                      "NekoWidget/PreservationService/src/notice-queue.ts",
                      "NekoWidget/PreservationService/src/delete-worker.ts",
                      "NekoWidget/PreservationService/migrations/0008_unknown.sql",
                      "NekoWidget/PreservationService/migrations/0004_other.sql", "NekoWidget/SharingService/src/index.ts",
                      "NekoWidget/SharingService/src/billing-auth.ts", "NekoWidget/SharingService/src/billing-entitlement.ts",
                      "NekoWidget/SharingService/migrations/0019_billing_foundation.sql",
                      "NekoWidget/NekoWidget/Services/ManagedPreservationClient.swift", "NekoWidget/Config.xcconfig",
                      scope.CI_WORKFLOW, "NekoWidget/ci/ios_ci_scope.py", "NekoWidget/ci/check-development-flow.py",
                      "NekoWidget/PreservationImageValidator/src/provider.ts", planner.JPEG_WORKFLOW):
            mixed = {**original, extra: ("old", "new")}
            self.assertEqual(select(mixed), scope.FULL_SCOPE, extra)
            self.assertEqual(planner.required_jobs(list(mixed), planner.PRESERVATION_SCOPE), planner.FULL)
        for path in planner.PRESERVATION_COMPANION_PATHS:
            missing = dict(original); del missing[path]
            self.assertEqual(select(missing), scope.FULL_SCOPE)
            for side in (0, 1):
                pair = list(original[path]); pair[side] += " unreviewed"
                self.assertEqual(select({**original, path: tuple(pair)}), scope.FULL_SCOPE)
        selector = "NekoWidget/ci/plan-ios-ci.py"
        literal = "PRESERVATION_COMPANION_DIGESTS = " + json.dumps(bindings, indent=4, sort_keys=True) + "\n"
        for source in (original[selector][1] + literal,
                       original[selector][1].replace(literal, literal.replace(" = ", "=", 1)),
                       original[selector][1].replace(bindings[selector][0], "f" * 64)):
            self.assertEqual(select({**original, selector: (original[selector][0], source)}), scope.FULL_SCOPE)
        self.assertEqual(select({**original, planner.PRESERVATION_WORKFLOW: ("", "changed workflow")}), scope.FULL_SCOPE)
        migration_raw = f":000000 100644 {'c' * 40} {'d' * 40} A\0{migration}\0"
        for changed in (migration_raw.replace("100644", "100755"),
                        migration_raw.replace("100644", "120000"),
                        migration_raw.replace(" A\0", " D\0"),
                        migration_raw.replace(" A\0", " R100\0")):
            self.assertEqual(select(original, alter=lambda raw: raw.replace(migration_raw, changed)), scope.FULL_SCOPE)
        for transform in (lambda raw: raw.replace(":000000 100644", ":000000 100755", 1),
                          lambda raw: raw.replace(":000000 100644", ":100644 120000", 1),
                          lambda raw: raw.replace(" A\0", " D\0", 1),
                          lambda raw: raw.replace(" A\0", " R100\0", 1),
                          lambda raw: raw.replace(" M\0", " A\0", 1),
                          lambda raw: raw + raw):
            self.assertEqual(select(original, alter=transform), scope.FULL_SCOPE)

    def test_preservation_job_and_workflow_never_certify_native_or_reuse_success(self):
        changes, _ = self.jpeg_changes(profile="PRESERVATION")
        self.assertEqual(planner.required_jobs(list(changes), planner.PRESERVATION_SCOPE), (planner.PRESERVATION_JOB,))
        with patch.object(planner, "preservation_backend_only") as backend:
            self.assertEqual(planner.runtime_scope(list(changes), {},
                dict(self.env, GITHUB_EVENT_NAME="workflow_dispatch")), scope.FULL_SCOPE)
            backend.assert_not_called()
        self.assertNotIn(planner.PRESERVATION_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError):
            planner.required_jobs_from_scope(planner.PRESERVATION_SCOPE)
        job = dict(name=planner.PRESERVATION_JOB, head_sha=self.sha, status="completed", conclusion="success")
        self.assertFalse(planner.covers_jobs([job], planner.FULL, self.sha))
        self.assertFalse(planner.covers_jobs([job], (planner.JPEG_JOB,), self.sha))
        self.assertFalse(planner.covers_jobs(self.jobs, (planner.PRESERVATION_JOB,), self.sha))
        workflow = (Path(__file__).resolve().parents[2] / planner.PRESERVATION_WORKFLOW).read_text(encoding="utf-8")
        for required in ("name: " + planner.PRESERVATION_JOB, "runs-on: ubuntu-24.04", "timeout-minutes: 5",
                         'node-version: "22.17.0"', "npm ci --ignore-scripts --legacy-peer-deps",
                         "npm run typecheck", "npm test", "working-directory: NekoWidget/PreservationService"):
            self.assertIn(required, workflow)
        self.assertNotIn("secrets.", workflow)
        self.assertIn('"NekoWidget/SharingService/src/**"', workflow)
        self.assertIn('"NekoWidget/SharingService/migrations/**"', workflow)
        self.assertIn('wrangler deploy --dry-run --config wrangler.billing.disabled.jsonc', workflow)
        self.assertIn('--autoconfig=false --experimental-provision=false --experimental-auto-create=false', workflow)
        self.assertNotIn("--remote", workflow)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / "event.json").write_text("{}")
            env = dict(self.env, GITHUB_EVENT_PATH=str(root / "event.json"),
                       GITHUB_OUTPUT=str(root / "output"), GITHUB_STEP_SUMMARY=str(root / "summary"))
            with patch.dict(os.environ, env), patch.object(planner, "changed_paths", return_value=list(changes)), \
                    patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_SCOPE), \
                    patch.object(planner, "find_evidence") as lookup, patch("sys.stdout", new_callable=io.StringIO) as output:
                planner.main()
            lookup.assert_not_called()
            values = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
            self.assertTrue(all(values[name] == "false" for name in ("build", "smoke", "sharing", "app_ui")))
            self.assertEqual(values["matrix_lanes"], "[]")
            evidence = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
            self.assertEqual(evidence["required_jobs"], [planner.PRESERVATION_JOB])
            self.assertIsNone(evidence["evidence_run_id"])
            self.assertIn(planner.PRESERVATION_WORKFLOW, (root / "summary").read_text())

    def test_jpeg_backend_requires_exact_paths_modes_workflow_and_frozen_companions(self):
        self.assertEqual(planner.JPEG_SCOPE, "preservation-image-validator-v3")
        self.assertEqual(planner.JPEG_JOB_TIMEOUT_MINUTES, 10)
        self.assertEqual(len(planner.JPEG_PATHS), 25)
        original, bindings = self.jpeg_changes()
        workflow_digest = scope.source_digest(original[planner.JPEG_WORKFLOW][1])
        def select(changes, altered_raw=None, ancestor=True, base="b" * 40):
            paths = sorted(changes)
            raw = "".join(f"{':100644 100644' if pair[0] else ':000000 100644'} "
                          f"{'c' * 40} {'d' * 40} {'M' if pair[0] else 'A'}\0{path}\0"
                          for path, pair in sorted(changes.items()))
            def git(*args):
                if args[0] == "merge-base":
                    if not ancestor:
                        raise subprocess.CalledProcessError(1, "git")
                    return ""
                if args[0] == "diff":
                    return altered_raw(raw) if altered_raw else raw
                if args[0] == "show":
                    revision, path = args[1].split(":", 1)
                    return changes[path][1 if revision == self.sha else 0]
                raise AssertionError(args)
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git), \
                    patch.object(planner, "JPEG_WORKFLOW_DIGEST", workflow_digest), \
                    patch.object(planner, "JPEG_COMPANION_DIGESTS", bindings):
                return planner.runtime_scope(paths, {}, self.env)
        self.assertEqual(select(original), planner.JPEG_SCOPE)
        plain, _ = self.jpeg_changes(companions=False)
        self.assertEqual(select(plain), planner.JPEG_SCOPE)
        for name in ("Dockerfile", "wrangler.container.disabled.jsonc", "src/container-worker.mjs",
                     "src/http-server.ts", "src/start-server.ts", "test/http-server.test.mjs",
                     "test/container-probe.mjs", "src/runtime-budget.mjs", "test/runtime-budget.test.mjs"):
            addition = "NekoWidget/PreservationImageValidator/" + name
            self.assertEqual(select({**plain, addition: ("", "reviewed container addition")}), planner.JPEG_SCOPE)
        self.assertEqual(select({**plain, "handoffs/jpeg.md": ("", "read-only notes")}), planner.JPEG_SCOPE)
        self.assertEqual(select(original, ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(select(original, base=None), scope.FULL_SCOPE)  # manual iOS workflow
        selector = "NekoWidget/ci/plan-ios-ci.py"
        literal = "JPEG_COMPANION_DIGESTS = " + json.dumps(bindings, indent=4, sort_keys=True) + "\n"
        for source in (original[selector][1] + literal,
                       original[selector][1].replace(literal, literal.replace(" = ", "=", 1)),
                       original[selector][1].replace(bindings[selector][0], "f" * 64)):
            self.assertEqual(select({**original, selector: (original[selector][0], source)}), scope.FULL_SCOPE)
        for extra in ("NekoWidget/PreservationImageValidator/src/new.ts", "NekoWidget/PreservationService/src/index.ts",
                      "NekoWidget/NekoWidget/Views/SettingsView.swift", "NekoWidget/Config.xcconfig",
                      scope.CI_WORKFLOW, "NekoWidget/ci/ios_ci_scope.py", "NekoWidget/ci/check-development-flow.py"):
            mixed = {**original, extra: ("old", "new")}
            self.assertEqual(select(mixed), scope.FULL_SCOPE, extra)
            self.assertEqual(planner.required_jobs(list(mixed), planner.JPEG_SCOPE), planner.FULL)
        for path in planner.JPEG_COMPANION_PATHS | {planner.JPEG_WORKFLOW}:
            for side in (0, 1):
                if path == planner.JPEG_WORKFLOW and side == 0:
                    continue
                changed = list(original[path]); changed[side] += " unreviewed"
                self.assertEqual(select({**original, path: tuple(changed)}), scope.FULL_SCOPE, path)
        for path in planner.JPEG_COMPANION_PATHS:
            missing = dict(original); del missing[path]
            self.assertEqual(select(missing), scope.FULL_SCOPE)
        for transform in (lambda raw: raw.replace(":000000 100644", ":000000 100755", 1),
                          lambda raw: raw.replace(":000000 100644", ":100644 120000", 1),
                          lambda raw: raw.replace(" A\0", " D\0", 1),
                          lambda raw: raw.replace(" A\0", " R100\0", 1),
                          lambda raw: raw.replace(" M\0", " A\0", 1),
                          lambda raw: raw + raw.split("\0", 2)[0] + "\0" + raw.split("\0", 2)[1] + "\0"):
            self.assertEqual(select(original, altered_raw=transform), scope.FULL_SCOPE)

    def test_jpeg_job_is_required_but_never_ios_release_or_reused_evidence(self):
        changes, _ = self.jpeg_changes()
        self.assertEqual(planner.required_jobs(list(changes), planner.JPEG_SCOPE), (planner.JPEG_JOB,))
        with patch.object(planner, "jpeg_backend_only") as backend:
            self.assertEqual(planner.runtime_scope(list(changes), {},
                dict(self.env, GITHUB_EVENT_NAME="workflow_dispatch")), scope.FULL_SCOPE)
            backend.assert_not_called()
        self.assertNotIn(planner.JPEG_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError):
            planner.required_jobs_from_scope(planner.JPEG_SCOPE)
        node_job = dict(name=planner.JPEG_JOB, head_sha=self.sha, status="completed", conclusion="success")
        self.assertFalse(planner.covers_jobs([node_job], planner.FULL, self.sha))
        self.assertFalse(planner.covers_jobs(self.jobs, (planner.JPEG_JOB,), self.sha))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / "event.json").write_text("{}")
            env = dict(self.env, GITHUB_EVENT_PATH=str(root / "event.json"),
                       GITHUB_OUTPUT=str(root / "output"), GITHUB_STEP_SUMMARY=str(root / "summary"))
            with patch.dict(os.environ, env), patch.object(planner, "changed_paths", return_value=list(changes)), \
                    patch.object(planner, "runtime_scope", return_value=planner.JPEG_SCOPE), \
                    patch.object(planner, "find_evidence") as lookup, patch("sys.stdout", new_callable=io.StringIO) as output:
                planner.main()
            lookup.assert_not_called()
            values = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
            self.assertTrue(all(values[name] == "false" for name in ("build", "smoke", "sharing", "app_ui")))
            self.assertEqual(values["matrix_lanes"], "[]")
            evidence = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
            self.assertEqual(evidence["required_jobs"], [planner.JPEG_JOB])
            self.assertIsNone(evidence["evidence_run_id"])
            self.assertIn("does not certify", (root / "summary").read_text())

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
            self.assertEqual(selected(), planner.ORCHESTRATION_SCOPE)
            self.assertEqual(selected(ancestor=False), planner.ORCHESTRATION_SCOPE)
            for path in paths:
                for mode, status in ((":000000 100644", "A"), (":100644 000000", "D"),
                                     (":100644 100755", "M"), (":100644 120000", "T"),
                                     (":100644 100644", "R100"), (":100644 100644", "C100")):
                    expected = (planner.ORCHESTRATION_SCOPE if Path(path).name.startswith("test-")
                                and mode == ":000000 100644" and status == "A" else scope.FULL_SCOPE)
                    self.assertEqual(selected(path, mode, status), expected)

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
    def delivery_membership_changes(resuming=False, exporting=False, managed=False):
        prefix = "MANAGED_PRESERVATION" if managed else "RECORD_PORTABILITY" if exporting else "WINDOW_SUPPORT" if resuming else "DELIVERY_MEMBERSHIP"
        paths, new_paths = (getattr(scope, prefix + suffix) for suffix in ("_PATHS", "_NEW_PATHS"))
        companion_paths = getattr(scope, prefix + "_COMPANION_PATHS")
        selected = getattr(scope, "REVIEWED_" + prefix + "_SCOPE")
        native = getattr(scope, "REVIEWED_" + prefix + "_TESTS")
        classes = {}
        for identifier in native:
            _, owner, method = identifier.split("/")
            classes.setdefault(owner, []).append(f"    func {method}() {{}}")
        source = "\n".join(f"final class {owner}: XCTestCase {{\n" + "\n".join(methods) + "\n}"
                           for owner, methods in classes.items())
        changes = {path: ("" if path in new_paths else "before " + path,
                          source if path == scope.MEMORY_TEST_PATH else "after " + path)
                   for path in paths}
        if managed:
            for path, source in (
                ("NekoWidget/NekoWidget/Services/SharingRuntimeSelfTest.swift",
                 '\n'.join(f'runAsync("{case}") {{ boundary() }}' for case in scope.MANAGED_PRESERVATION_RUNTIME_CASES)),
                ("NekoWidget/ci/validate-sharing-runtime-self-test.py",
                 'REQUIRED_CASES = {' + ''.join(f'"{case}",' for case in scope.MANAGED_PRESERVATION_RUNTIME_CASES) + '}'),
            ):
                if path in changes:
                    changes[path] = (changes[path][0], source)
        project = "NekoWidget/NekoWidget.xcodeproj/project.pbxproj"
        if project in changes:
            frozen = "\t\tA00000000000000000000025 /* Sources */ = {\n\t\t\tfiles = (unchanged);\n\t\t};\n"
            frozen += "".join("/* Begin " + name + " section */\nfrozen\n/* End " + name + " section */\n"
                              for name in ("PBXNativeTarget", "XCBuildConfiguration", "XCConfigurationList",
                                           "PBXResourcesBuildPhase", "PBXFrameworksBuildPhase"))
            changes[project] = (frozen + "app before", frozen + "app after")
        product = {path: tuple(map(scope.source_digest, pair)) for path, pair in changes.items()}
        review = {"schemaVersion": 1, "scope": selected,
                  "purpose": "Reviewed explicit delivery support boundary", "visualReview": "native-ui-required",
                  "dataReview": getattr(scope, prefix + "_DATA_REVIEW"),
                  "files": {path: {"before": pair[0], "after": pair[1]} for path, pair in product.items()}}
        changes[scope.REVIEW_MANIFEST] = ("{}", json.dumps(review))
        changes.update({path: ("before " + path, "after " + path) for path in companion_paths})
        selector = "NekoWidget/ci/ios_ci_scope.py"
        empty = prefix + "_COMPANION_DIGESTS = {}\n"
        changes[selector] = ("old selector", empty + "# reviewed selector source\n")
        companions = {path: list(map(scope.source_digest, changes[path]))
                      for path in companion_paths | {scope.REVIEW_MANIFEST}}
        literal = prefix + "_COMPANION_DIGESTS = " + json.dumps(companions, indent=4, sort_keys=True) + "\n"
        changes[selector] = (changes[selector][0], changes[selector][1].replace(empty, literal))
        return changes, product, companions

    def test_managed_preservation_requires_frozen_integration_and_runtime_ui_cases(self):
        changes, product, companions = self.delivery_membership_changes(managed=True)
        with patch.object(scope, "MANAGED_PRESERVATION_DIGESTS", {}):
            self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
        with patch.object(scope, "MANAGED_PRESERVATION_DIGESTS", product), \
                patch.object(scope, "MANAGED_PRESERVATION_COMPANION_DIGESTS", companions):
            self.assertEqual(scope.select_scope(changes), scope.REVIEWED_MANAGED_PRESERVATION_SCOPE)
            for path in changes:
                missing = dict(changes); del missing[path]
                self.assertEqual(scope.select_scope(missing), scope.FULL_SCOPE)
                for side in (0, 1):
                    altered = list(changes[path]); altered[side] += " unreviewed change"
                    self.assertEqual(scope.select_scope(dict(changes, **{path: tuple(altered)})), scope.FULL_SCOPE)
            for extra in (scope.CI_WORKFLOW, scope.CI_DIAGNOSTIC_MATRIX,
                          "NekoWidget/ci/ci-timing-baseline.json",
                          "NekoWidget/NekoWidget/Views/FamilyRecordView.swift",
                          "NekoWidget/NekoWidget/Services/ManagedPreservationSessionStore.swift",
                          "NekoWidget/NekoWidget.xcodeproj/project.pbxproj",
                          "NekoWidget/NekoWidget/Services/PhotoMemoryNoteStore.swift",
                          "NekoWidget/NekoWidget/Services/PersonalArchiveStore.swift",
                          "NekoWidget/NekoWidget/Info.plist", "NekoWidget/Config.xcconfig",
                          "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                          "NekoWidget/Shared/Models/WidgetRenderPlan.swift",
                          "NekoWidget/PreservationService/src/index.ts"):
                if extra in scope.MANAGED_PRESERVATION_PATHS:
                    continue
                altered = dict(changes, **{extra: ("before", "after")})
                self.assertEqual(scope.select_scope(altered), scope.FULL_SCOPE)
                self.assertEqual(planner.required_jobs(list(altered), scope.REVIEWED_MANAGED_PRESERVATION_SCOPE), planner.FULL)
            tests = scope.REVIEWED_MANAGED_PRESERVATION_TESTS
            for incomplete in ((), tests[:1], tests[1:], (tests[0], tests[0]),
                               (tests[0], "NekoWidgetUITests/SoloMemoriesUITests/testMissingMembershipLink")):
                with patch.object(scope, "REVIEWED_MANAGED_PRESERVATION_TESTS", incomplete):
                    self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
            cases = scope.MANAGED_PRESERVATION_RUNTIME_CASES
            for incomplete in ((), cases[:1], cases[1:], (cases[0], cases[0]), (cases[0], 'missing-boundary')):
                with patch.object(scope, "MANAGED_PRESERVATION_RUNTIME_CASES", incomplete):
                    self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
            selector = "NekoWidget/ci/ios_ci_scope.py"
            source = changes[selector][1]
            self.assertEqual(scope.select_scope(dict(changes, **{selector: (changes[selector][0], source + source)})),
                             scope.FULL_SCOPE)
            # Changing the manifest to an old evidence namespace is not review.
            old_review = json.loads(changes[scope.REVIEW_MANIFEST][1]); old_review['scope'] = 'reviewed-managed-preservation-app-v2'
            self.assertEqual(scope.select_scope(dict(changes, **{scope.REVIEW_MANIFEST: ('{}', json.dumps(old_review))})), scope.FULL_SCOPE)
        tests = scope.native_tests(scope.REVIEWED_MANAGED_PRESERVATION_SCOPE)
        self.assertEqual(tests, (
            'NekoWidgetUITests/SoloMemoriesUITests/testManagedPreservationDisabledHidesEntries',
            'NekoWidgetUITests/SoloMemoriesUITests/testManagedPreservationLostCopyResultShowsConfirmationAndStoredState',
            'NekoWidgetUITests/SoloMemoriesUITests/testManagedPreservationMembershipLinkConsentAndRetry',
            'NekoWidgetUITests/SoloMemoriesUITests/testManagedPreservationAccountDeletionRetainsReceiptAndCompletes',
            'NekoWidgetUITests/SoloMemoriesUITests/testMembershipOfferExplainsExpiryWithoutChangingThePlan',
        ))
        self.assertEqual(scope.REVIEWED_MANAGED_PRESERVATION_SCOPE, 'reviewed-managed-preservation-app-v6')
        self.assertEqual(len(scope.MANAGED_PRESERVATION_PATHS), 9)
        self.assertFalse(scope.MANAGED_PRESERVATION_NEW_PATHS)
        self.assertNotIn("NekoWidget/NekoWidget/Services/BillingClientCore.swift", scope.MANAGED_PRESERVATION_PATHS)
        self.assertNotIn("NekoWidget/NekoWidget/NekoWidget.entitlements", scope.MANAGED_PRESERVATION_PATHS)
        self.assertIn("NekoWidget/NekoWidget/Views/FamilyRecordView.swift", scope.MANAGED_PRESERVATION_PATHS)
        self.assertEqual(len(scope.MANAGED_PRESERVATION_COMPANION_PATHS), 6)
        self.assertTrue(scope.memory_tests_available(scope.managed_validation_source(changes, scope.MEMORY_TEST_PATH), tests))
        with patch.object(scope, "managed_validation_source", return_value=""):
            with patch.object(scope, "MANAGED_PRESERVATION_DIGESTS", product), \
                 patch.object(scope, "MANAGED_PRESERVATION_COMPANION_DIGESTS", companions):
                self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)

    def test_managed_preservation_raw_modifications_and_four_safety_jobs(self):
        changes, product, companions = self.delivery_membership_changes(managed=True)
        base, paths = "b" * 40, sorted(changes)
        def selected(path=None, modes=":100644 100644", status="M", extra=False):
            raw = ""
            for item in paths:
                new = item in scope.MANAGED_PRESERVATION_NEW_PATHS
                raw += (f"{modes if item == path else ':000000 100644' if new else ':100644 100644'} "
                        f"{'c' * 40} {'d' * 40} {status if item == path else 'A' if new else 'M'}\0{item}\0")
            if extra:
                raw += f":100644 100644 {'c' * 40} {'d' * 40} M\0unreported.swift\0"
            def git(*args):
                if args[0] == "diff":
                    return raw
                if args[0] == "show":
                    revision, item = args[1].split(":", 1)
                    if revision == base and item in scope.MANAGED_PRESERVATION_NEW_PATHS:
                        raise AssertionError("A reviewed addition has no base blob")
                    return changes[item][0 if revision == base else 1]
                return self.sha
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(paths, {}, self.env)
        with patch.object(scope, "MANAGED_PRESERVATION_DIGESTS", product), \
                patch.object(scope, "MANAGED_PRESERVATION_COMPANION_DIGESTS", companions):
            self.assertEqual(selected(), scope.REVIEWED_MANAGED_PRESERVATION_SCOPE)
            self.assertEqual(selected(extra=True), scope.FULL_SCOPE)
            for path in paths:
                invalid = [(":100644 000000", "D"), (":100644 100755", "M"), (":100644 120000", "T"),
                           (":100644 100644", "R100"), (":100644 100644", "C100"),
                           (":000000 100755", "A"), (":000000 120000", "A")]
                invalid.append((":100644 100644", "M") if path in scope.MANAGED_PRESERVATION_NEW_PATHS else (":000000 100644", "A"))
                for modes, status in invalid:
                    self.assertEqual(selected(path, modes, status), scope.FULL_SCOPE)
        selected_scope = scope.REVIEWED_MANAGED_PRESERVATION_SCOPE
        required = planner.required_jobs(paths, selected_scope)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(selected_scope))
        self.assertEqual(len(required), 4)
        self.assertEqual(scope.lanes(selected_scope), ("runtime", "app-ui"))
        jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success"} for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, required, base))
        legacy_jobs = [dict(job, name=job['name'].replace('-app-v6]', '-app-v5]')) for job in jobs]
        self.assertFalse(planner.covers_jobs(legacy_jobs, required, self.sha))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, self.sha))
            for state in ("skipped", "failure", "cancelled"):
                altered = copy.deepcopy(jobs); altered[index]["conclusion"] = state
                self.assertFalse(planner.covers_jobs(altered, required, self.sha))

    def test_record_portability_requires_complete_frozen_sources_and_two_ui_operations(self):
        changes, product, companions = self.delivery_membership_changes(exporting=True)
        with patch.object(scope, "RECORD_PORTABILITY_DIGESTS", {}):
            self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
        with patch.object(scope, "RECORD_PORTABILITY_DIGESTS", product), \
                patch.object(scope, "RECORD_PORTABILITY_COMPANION_DIGESTS", companions):
            self.assertEqual(scope.select_scope(changes), scope.REVIEWED_RECORD_PORTABILITY_SCOPE)
            for path in changes:
                missing = dict(changes); del missing[path]
                self.assertEqual(scope.select_scope(missing), scope.FULL_SCOPE)
                for side in (0, 1):
                    altered = list(changes[path]); altered[side] += " unreviewed change"
                    self.assertEqual(scope.select_scope(dict(changes, **{path: tuple(altered)})), scope.FULL_SCOPE)
            for extra in (scope.CI_WORKFLOW, scope.CI_DIAGNOSTIC_MATRIX,
                          "NekoWidget/ci/plan-ios-ci.py", "NekoWidget/ci/preflight-ci.py",
                          "NekoWidget/NekoWidget.xcodeproj/project.pbxproj",
                          "NekoWidget/NekoWidget/Services/PhotoMemoryNoteStore.swift",
                          "NekoWidget/NekoWidget/Services/PersonalArchiveStore.swift",
                          "NekoWidget/NekoWidget/Services/PersonalArchiveCloudClient.swift",
                          "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                          "NekoWidget/Shared/Models/WidgetRenderPlan.swift",
                          "NekoWidget/SharingService/src/index.ts"):
                altered = dict(changes, **{extra: ("before", "after")})
                self.assertEqual(scope.select_scope(altered), scope.FULL_SCOPE)
                self.assertEqual(planner.required_jobs(list(altered), scope.REVIEWED_RECORD_PORTABILITY_SCOPE), planner.FULL)
            with patch.object(scope, "REVIEWED_RECORD_PORTABILITY_TESTS", ()):
                self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
            selector = "NekoWidget/ci/ios_ci_scope.py"
            source = changes[selector][1]
            self.assertEqual(scope.select_scope(dict(changes, **{selector: (changes[selector][0], source + source)})),
                             scope.FULL_SCOPE)
        tests = scope.native_tests(scope.REVIEWED_RECORD_PORTABILITY_SCOPE)
        self.assertEqual(len(set(tests)), 2)
        self.assertTrue(scope.memory_tests_available(changes[scope.MEMORY_TEST_PATH][1], tests))
        for identifier in tests:
            self.assertFalse(scope.memory_tests_available(changes[scope.MEMORY_TEST_PATH][1].replace(
                identifier.split("/")[-1], "absent"), tests))

    def test_record_portability_raw_modifications_and_four_safety_jobs(self):
        changes, product, companions = self.delivery_membership_changes(exporting=True)
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
        with patch.object(scope, "RECORD_PORTABILITY_DIGESTS", product), \
                patch.object(scope, "RECORD_PORTABILITY_COMPANION_DIGESTS", companions):
            self.assertEqual(selected(), scope.REVIEWED_RECORD_PORTABILITY_SCOPE)
            self.assertEqual(selected(extra=True), scope.FULL_SCOPE)
            for path in paths:
                for modes, status in ((":100644 000000", "D"), (":100644 100755", "M"),
                                      (":100644 120000", "T"), (":100644 100644", "R100"),
                                      (":100644 100644", "C100"), (":000000 100644", "A")):
                    self.assertEqual(selected(path, modes, status), scope.FULL_SCOPE)
        selected_scope = scope.REVIEWED_RECORD_PORTABILITY_SCOPE
        required = planner.required_jobs(paths, selected_scope)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(selected_scope))
        self.assertEqual(len(required), 4)
        self.assertEqual(scope.lanes(selected_scope), ("runtime", "app-ui"))
        jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success"} for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, required, base))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, self.sha))
            for state in ("skipped", "failure", "cancelled"):
                altered = copy.deepcopy(jobs); altered[index]["conclusion"] = state
                self.assertFalse(planner.covers_jobs(altered, required, self.sha))

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

    def test_window_support_resume_requires_closed_sources_and_both_ui_operations(self):
        changes, product, companions = self.delivery_membership_changes(resuming=True)
        with patch.object(scope, "WINDOW_SUPPORT_DIGESTS", {}):
            self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
        with patch.object(scope, "WINDOW_SUPPORT_DIGESTS", product), \
                patch.object(scope, "WINDOW_SUPPORT_COMPANION_DIGESTS", companions):
            self.assertEqual(scope.select_scope(changes), scope.REVIEWED_WINDOW_SUPPORT_SCOPE)
            for path in changes:
                partial = dict(changes); del partial[path]
                self.assertEqual(scope.select_scope(partial), scope.FULL_SCOPE)
                for side in (0, 1):
                    pair = list(changes[path]); pair[side] += " unreviewed change"
                    self.assertEqual(scope.select_scope(dict(changes, **{path: tuple(pair)})), scope.FULL_SCOPE)
            for extra in (scope.CI_WORKFLOW, scope.CI_DIAGNOSTIC_MATRIX,
                          "NekoWidget/ci/preflight-ci.py", "NekoWidget/ci/verify-app-icon.py",
                          "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                          "NekoWidget/Shared/PersonalWidgetMembershipStore.swift",
                          "NekoWidget/SharingService/src/unknown.ts",
                          "NekoWidget/SharingService/migrations/0029_unknown.sql",
                          ".github/workflows/sharing-service.yml"):
                self.assertEqual(scope.select_scope(dict(changes, **{extra: ("old", "new")})), scope.FULL_SCOPE)
            self.assertFalse(scope.reviewed_delivery_membership_changes(changes))
            with patch.object(scope, "REVIEWED_WINDOW_SUPPORT_TESTS", ()):
                self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
            selector = "NekoWidget/ci/ios_ci_scope.py"
            before, after = changes[selector]
            self.assertEqual(scope.select_scope(dict(changes, **{selector: (before, after + after)})), scope.FULL_SCOPE)
        tests = scope.native_tests(scope.REVIEWED_WINDOW_SUPPORT_SCOPE)
        self.assertEqual(len(tests), 2)
        self.assertEqual(len(set(tests)), 2)
        self.assertTrue(scope.memory_tests_available(changes[scope.MEMORY_TEST_PATH][1], tests))
        self.assertFalse(scope.memory_tests_available(changes[scope.MEMORY_TEST_PATH][1].replace(
            tests[0].split("/")[-1], "absent"), tests))

    def test_window_support_resume_raw_modes_and_four_safety_jobs(self):
        changes, product, companions = self.delivery_membership_changes(resuming=True)
        base, paths = "b" * 40, sorted(changes)
        def selected(altered_path=None, modes=":100644 100644", status="M", extra=False):
            records = []
            for path in paths:
                added = path in scope.WINDOW_SUPPORT_NEW_PATHS
                raw_modes, raw_status = (":000000 100644", "A") if added else (":100644 100644", "M")
                if path == altered_path: raw_modes, raw_status = modes, status
                records.extend([f"{raw_modes} {'c' * 40} {'d' * 40} {raw_status}", path])
            if extra: records.extend([f":100644 100644 {'c' * 40} {'d' * 40} M", "unreported.swift"])
            def git(*args):
                if args[0] == "diff": return "\0".join(records) + "\0"
                if args[0] == "show":
                    revision, path = args[1].split(":", 1)
                    if revision == base and path in scope.WINDOW_SUPPORT_NEW_PATHS:
                        raise AssertionError("Named additions have no base blob")
                    return changes[path][0 if revision == base else 1]
                return self.sha
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(paths, {}, self.env)
        with patch.object(scope, "WINDOW_SUPPORT_DIGESTS", product), \
                patch.object(scope, "WINDOW_SUPPORT_COMPANION_DIGESTS", companions):
            self.assertEqual(selected(), scope.REVIEWED_WINDOW_SUPPORT_SCOPE)
            self.assertEqual(selected(extra=True), scope.FULL_SCOPE)
            for path in paths:
                for modes, status in ((":100644 000000", "D"), (":100644 100755", "M"),
                                      (":100644 120000", "T"), (":100644 100644", "R100"),
                                      (":000000 100755", "A"), (":000000 120000", "A")):
                    self.assertEqual(selected(path, modes, status), scope.FULL_SCOPE)
                wrong = (":100644 100644", "M") if path in scope.WINDOW_SUPPORT_NEW_PATHS else (":000000 100644", "A")
                self.assertEqual(selected(path, *wrong), scope.FULL_SCOPE)
        required = planner.required_jobs(paths, scope.REVIEWED_WINDOW_SUPPORT_SCOPE)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(scope.REVIEWED_WINDOW_SUPPORT_SCOPE))
        self.assertEqual(len(required), 4)
        self.assertEqual(scope.lanes(scope.REVIEWED_WINDOW_SUPPORT_SCOPE), ("runtime", "app-ui"))
        jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success"} for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, self.sha))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, self.sha))
            for state in ("skipped", "failure", "cancelled"):
                incomplete = copy.deepcopy(jobs); incomplete[index]["conclusion"] = state
                self.assertFalse(planner.covers_jobs(incomplete, required, self.sha))

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
                         ("NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",
                          "NekoWidgetUITests/PhotoPermissionUITests/testMainlineAcceptanceScreensWithAuthorizedLibrary"))
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
                         ("NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",
                          "NekoWidgetUITests/PhotoPermissionUITests/testMainlineAcceptanceScreensWithAuthorizedLibrary"))
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
            ("NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",
                          "NekoWidgetUITests/PhotoPermissionUITests/testMainlineAcceptanceScreensWithAuthorizedLibrary"))
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
        # Without a visual-review manifest, app-only views retain every app UI
        # suite and smoke check, while Widget Gallery does not run.
        self.assertEqual(scope.select_scope({path: pair}), scope.APP_VIEW_SCOPE)
        for altered in (
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
            self.assertEqual(scope.select_scope(altered),
                             scope.APP_VIEW_SCOPE if missing == scope.REVIEW_MANIFEST else scope.FULL_SCOPE)
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

    def test_resolution_main_reuse_also_requires_same_candidate_backends(self):
        required = planner.required_jobs_from_scope(planner.MODERATION_RESOLUTION_SCOPE)
        self.jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success",
                      "completed_at": "2026-09-07T11:00:00Z"} for name in required]
        with patch.object(planner, "moderation_resolution_backend_evidence", return_value={}) as backend:
            self.assertEqual(planner.find_evidence(self.env, required, self.api, self.now), (10, self.sha))
            self.assertEqual(backend.call_args.args[:2], (self.sha, "owner/repo"))
            self.assertEqual(backend.call_args.kwargs, {"branch": "codex/movie"})
        with patch.object(planner, "moderation_resolution_backend_evidence", side_effect=ValueError("missing")), self.assertRaises(ValueError):
            planner.find_evidence(self.env, required, self.api, self.now)

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
                          planner.CorrectionEvidenceUnavailable,
                          subprocess.CalledProcessError(1, "git")):
                with self.subTest(error=error), patch.dict(os.environ, env), \
                        patch.object(planner, "changed_paths", side_effect=ValueError), \
                        patch.object(planner, "find_evidence", side_effect=error):
                    (root / "output").write_text("")
                    with self.assertRaises(SystemExit):
                        planner.main()
                    self.assertEqual((root / "output").read_text(), "")
            # Main must not silently restart the expensive candidate suite.
            with patch.dict(os.environ, env), \
                    patch.object(planner, "changed_paths", side_effect=ValueError), \
                    patch.object(planner, "find_evidence", return_value=None):
                with self.assertRaises(SystemExit):
                    planner.main()
                self.assertEqual((root / "output").read_text(), "")
            # The candidate branch still performs its required validation.
            with patch.dict(os.environ, dict(env, GITHUB_REF="refs/heads/codex/candidate")), \
                    patch.object(planner, "changed_paths", side_effect=ValueError), \
                    patch.object(planner, "find_evidence", return_value=None):
                planner.main()
                outputs = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual(outputs, {"build": "true", "build_name": planner.BUILD, "smoke": "true", "sharing": "true",
                    "smoke_name": planner.SMOKE, "app_ui": "true", "matrix_parallelism": "2",
                    "runtime_scope": scope.FULL_SCOPE,
                    "lanes": json.dumps(scope.lanes(scope.FULL_SCOPE), separators=(",", ":")),
                    "app_ui_lanes": json.dumps(scope.app_ui_lanes(scope.FULL_SCOPE), separators=(",", ":")),
                    "matrix_lanes": ('["runtime","gallery-normal","gallery-variants"]'
                                     if "gallery-variants" in scope.lanes(scope.FULL_SCOPE)
                                     else '["runtime","gallery-normal","gallery-white","gallery-no-caption"]')})

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
                expected = scope.APP_VIEW_SCOPE if extra in scope.APP_ONLY_VIEWS | scope.APP_VIEW_PATHS else scope.FULL_SCOPE
                self.assertEqual(scope.select_scope({home: change, extra: change}), expected)
                self.assertEqual(planner.required_jobs([home, extra], scope.PHOTO_SCOPE), planner.FULL)
        protected = '#if DEBUG\n#if targetEnvironment(simulator)\nText("fixture")\n#endif\n#else\nText("shipping")\n#endif\n'
        self.assertEqual(scope.select_scope({home: (protected + change[0], protected + change[1])}), scope.PHOTO_SCOPE)
        for after in (protected.replace('"fixture"', '"changed"'),
                      protected.replace('"shipping"', '"changed"'),
                      protected.replace("#if DEBUG", "#if NEW")):
            self.assertEqual(scope.select_scope({home: (protected, after)}), scope.APP_VIEW_SCOPE)
        for after in (protected + "#if DEBUG\n", protected + "#endif\n"):
            self.assertEqual(scope.select_scope({home: (protected, after)}), scope.FULL_SCOPE)
        for text in ('requestAuthorization()', 'hasPhotoPermission = true', 'consent = nil',
                     'privacyURL = changed', 'fixtureTitle = "x"', '"--new-launch-switch"'):
            self.assertEqual(scope.select_scope({home: (change[0], text)}), scope.APP_VIEW_SCOPE)

    def test_app_owned_stores_keep_app_checks_without_widget_gallery(self):
        main = "NekoWidget/NekoWidget/Views/MainTabView.swift"
        presentation = "NekoWidget/NekoWidget/Views/ShowcasePhotoView.swift"
        tests = "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift"
        pair = ("import Foundation\nstruct Before {}\n", "import Foundation\nstruct After {}\n")
        root = "NekoWidget/NekoWidget/App/AppRootView.swift"
        for store in ("NekoWidget/NekoWidget/Services/ShowcasePhotoStore.swift",
                      "NekoWidget/NekoWidget/Services/CatPreparednessStore.swift"):
            with self.subTest(store=store):
                changes = {path: pair for path in (root, store, main, presentation, tests)}
                self.assertEqual(scope.select_scope({store: pair}), scope.APP_VIEW_SCOPE)
                self.assertEqual(scope.select_scope(changes), scope.APP_VIEW_SCOPE)
                self.assertEqual(scope.lanes(scope.APP_VIEW_SCOPE),
                                 ("runtime", "app-ui-solo-1", "app-ui-solo-2", "app-ui-other"))
                self.assertTrue(any("Build disabled app" in job for job in
                                    planner.required_jobs(list(changes), scope.APP_VIEW_SCOPE)))
                self.assertFalse(any("gallery" in job.lower() for job in
                                     planner.required_jobs(list(changes), scope.APP_VIEW_SCOPE)))
                for unrelated in (
                    "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                    "NekoWidget/Shared/Storage/AtomicJSON.swift",
                    "NekoWidget/NekoWidget/Services/PhotoLibraryScanner.swift",
                    "NekoWidget/NekoWidget.xcodeproj/project.pbxproj",
                ):
                    self.assertEqual(scope.select_scope(dict(changes, **{unrelated: pair})), scope.FULL_SCOPE)

    def test_family_window_scope_keeps_owning_class_and_photo_links_without_widget_rendering(self):
        window = "NekoWidget/NekoWidget/Views/FamilyWindowView.swift"
        record = "NekoWidget/NekoWidget/Views/FamilyRecordView.swift"
        owned = sorted(scope.FAMILY_WINDOW_TEST_NAMES)
        source = ('import XCTest\n'
                  'final class OtherTests: XCTestCase {\n    func testOther() {}\n}\n'
                  'final class MomentDeliveryComposerUITests: XCTestCase {\n'
                  + ''.join(f'    func {name}() {{ print("before") }}\n' for name in owned)
                  + '    func testUnrelated() { print("unchanged") }\n}\n')
        changes = {window: ('let x = 1', 'let x = 2'),
                   record: ('#if DEBUG\nlet x = 1\n#endif', '#if DEBUG\nlet x = 2\n#endif'),
                   scope.MEMORY_TEST_PATH: (source, source.replace('"before"', '"after"')),
                   'handoffs/design.md': ('a', 'b')}
        self.assertEqual(scope.select_scope(changes), scope.FAMILY_WINDOW_UI_SCOPE)
        added_helper = (source.replace('    func ' + owned[0],
            '    @MainActor\n    private func exerciseCollection() { print("collection") }\n'
            '    func ' + owned[0], 1).replace('print("before")', 'exerciseCollection()', 1))
        self.assertEqual(scope.select_scope(dict(changes, **{
            scope.MEMORY_TEST_PATH: (source, added_helper)})), scope.FAMILY_WINDOW_UI_SCOPE)
        shadowed = source.replace('print("unchanged")', 'exerciseCollection()')
        shadowed_after = shadowed.replace('    func ' + owned[0],
            '    @MainActor\n    private func exerciseCollection() { print("collection") }\n'
            '    func ' + owned[0], 1).replace('print("before")', 'exerciseCollection()', 1)
        self.assertNotEqual(scope.select_scope(dict(changes, **{
            scope.MEMORY_TEST_PATH: (shadowed, shadowed_after)})), scope.FAMILY_WINDOW_UI_SCOPE)
        for invalid in (source.replace('print("unchanged")', 'print("changed")'),
                        source.replace('testUnrelated()', 'testRenamed()'),
                        source.replace('import XCTest', 'import UIKit'),
                        source + '\nprivate func outsideHelper() {}'):
            self.assertNotEqual(scope.select_scope(dict(changes, **{
                scope.MEMORY_TEST_PATH: (source, invalid)})), scope.FAMILY_WINDOW_UI_SCOPE)
        contract = ('import unittest\nclass Contract(unittest.TestCase):\n'
                    '    def test_family_window_combines_photos_without_exposing_report_only_sends(self) -> None:\n'
                    '        self.assertIn("old view", "view")\n\n'
                    '    def test_widget_boundary(self):\n        self.assertTrue(True)\n')
        revised = contract.replace('"old view"', '"new view"')
        companion = dict(changes, **{scope.FAMILY_WINDOW_CONTRACT_TEST: (contract, revised)})
        self.assertEqual(scope.select_scope(companion), scope.FAMILY_WINDOW_UI_SCOPE)
        self.assertTrue(scope.accepts_paths(scope.FAMILY_WINDOW_UI_SCOPE, companion))
        for invalid in (revised.replace('import unittest', 'import os'),
                        revised.replace('self.assertTrue(True)', 'pass'),
                        revised.replace('    def test_widget_boundary', '    @unittest.skip("no")\n    def test_widget_boundary'),
                        revised.replace('    def test_widget_boundary', '    skip = True\n    def test_widget_boundary'),
                        revised + '\nhelper = 1\n',
                        revised.replace('test_family_window_combines_photos_without_exposing_report_only_sends', 'test_other')):
            companion[scope.FAMILY_WINDOW_CONTRACT_TEST] = (contract, invalid)
            self.assertNotEqual(scope.select_scope(companion), scope.FAMILY_WINDOW_UI_SCOPE)
        for broken in ('#if DEBUG\n#else\n#else\n#endif',
                       '#if DEBUG\n#else\n#elseif MORE\n#endif', '#if\n#endif'):
            modified = dict(changes)
            modified[record] = ('let x = 1', broken)
            self.assertNotEqual(scope.select_scope(modified), scope.FAMILY_WINDOW_UI_SCOPE)
        self.assertTrue(scope.accepts_paths(scope.FAMILY_WINDOW_UI_SCOPE, changes))
        self.assertEqual(scope.lanes(scope.FAMILY_WINDOW_UI_SCOPE), ('runtime', 'app-ui'))
        tests = scope.native_tests(scope.FAMILY_WINDOW_UI_SCOPE)
        self.assertEqual(tests[:len(owned)], scope.FAMILY_WINDOW_NATIVE_TESTS)
        self.assertNotIn('NekoWidgetUITests/MomentDeliveryComposerUITests', tests)
        self.assertEqual(sum('OfficialWindowUITests/testWidgetURLs' in name for name in tests), 3)
        self.assertNotIn(scope.GALLERY_TEST, tests)
        self.assertEqual(scope.smoke_tests(scope.FAMILY_WINDOW_UI_SCOPE),
                         ('NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess',
                          'NekoWidgetUITests/PhotoPermissionUITests/testMainlineAcceptanceScreensWithAuthorizedLibrary'))
        for path in ('NekoWidget/Shared/Models/WidgetManifest.swift',
                     'NekoWidget/NekoWidgetWidget/NekoWidgetView.swift',
                     'NekoWidget/NekoWidget.xcodeproj/project.pbxproj',
                     '.github/workflows/ios-build.yml'):
            self.assertEqual(scope.select_scope(dict(changes, **{path: ('before', 'after')})), scope.FULL_SCOPE)
        for after in (source.replace('import XCTest', 'import UIKit'),
                      source.replace('testOther()', 'testOtherChanged()'),
                      source + '\nprivate func outsideHelper() {}',
                      source.replace('MomentDeliveryComposerUITests', 'DifferentTests'),
                      source + '#if DEBUG\n'):
            modified = dict(changes)
            modified[scope.MEMORY_TEST_PATH] = (source, after)
            self.assertNotEqual(scope.select_scope(modified), scope.FAMILY_WINDOW_UI_SCOPE)

    def test_app_only_record_export_keeps_sharing_runtime_without_widget_gallery(self):
        change = ('let before = 1\n', 'let after = 2\n')
        album = "NekoWidget/NekoWidget/Views/FamilyRecordView.swift"
        ui_test = "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift"
        changes = {path: change for path in scope.APP_ONLY_RECORD_EXPORT_PATHS}
        self.assertIn(album, changes)
        self.assertIn(ui_test, changes)
        digests = {path: tuple(map(scope.source_digest, pair)) for path, pair in changes.items()}
        with patch.object(scope, "APP_ONLY_RECORD_EXPORT_DIGESTS", digests):
            self.assertEqual(scope.select_scope(changes), scope.REVIEWED_FAMILY_EXPORT_SCOPE)
            self.assertTrue(scope.accepts_paths(scope.REVIEWED_FAMILY_EXPORT_SCOPE, changes))
            selected = planner.required_jobs(list(changes), scope.REVIEWED_FAMILY_EXPORT_SCOPE)
            self.assertEqual(selected, planner.required_jobs_from_scope(scope.REVIEWED_FAMILY_EXPORT_SCOPE))
            self.assertEqual(scope.lanes(scope.REVIEWED_FAMILY_EXPORT_SCOPE), ("runtime", "app-ui"))
            self.assertIn(scope.lane_job(scope.REVIEWED_FAMILY_EXPORT_SCOPE, "runtime"), selected)
            self.assertEqual(len(scope.native_tests(scope.REVIEWED_FAMILY_EXPORT_SCOPE)), 1)
            self.assertIn("testFamilyRecordKeepsOtherAuthorsWordsWhenPhotoIsWithdrawnAndRevokesAccess",
                          scope.native_tests(scope.REVIEWED_FAMILY_EXPORT_SCOPE)[0])
            self.assertNotIn(scope.GALLERY_TEST, scope.native_tests(scope.REVIEWED_FAMILY_EXPORT_SCOPE))
            for path in changes:
                with self.subTest(missing=path):
                    self.assertEqual(scope.select_scope({key: value for key, value in changes.items() if key != path}),
                                     scope.FULL_SCOPE)
                with self.subTest(tampered=path):
                    edited = dict(changes)
                    edited[path] = (change[0], change[1] + "unreviewed\n")
                    self.assertEqual(scope.select_scope(edited), scope.FULL_SCOPE)
            for unrelated in (
                "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                "NekoWidget/Shared/Models/WidgetManifest.swift",
                "NekoWidget/NekoWidget.xcodeproj/project.pbxproj",
                "NekoWidget/NekoWidget/Services/WidgetCacheBuilder.swift",
            ):
                with self.subTest(unrelated=unrelated):
                    self.assertEqual(scope.select_scope(changes | {unrelated: change}), scope.FULL_SCOPE)

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
                self.assertEqual(scope.select_scope({home: (before, after)}), scope.APP_VIEW_SCOPE)

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
                                   ("sharing-runtime-matrix", "sharing"),
                                   ("sharing-runtime-deferred", "sharing"),
                                   ("sharing-gallery-early", "sharing")):
            body = re.split(r"\n  (?=\S)", workflow.split("\n  " + identifier + ":", 1)[1], maxsplit=1)[0]
            if identifier == "sharing-gallery-early":
                self.assertIn("    needs: [plan, simulator-smoke-test]\n", body)
                self.assertIn("    if: always() && needs.plan.result == 'success' && needs.plan.outputs.sharing == 'true'", body)
                self.assertIn("needs.plan.outputs.runtime_scope == 'full-v1'", body)
                self.assertNotIn("needs.build-without-signing", body)
            elif identifier == "sharing-runtime-deferred":
                self.assertIn("    needs: [plan, build-without-signing, simulator-smoke-test]\n", body)
                self.assertIn("    if: always() && needs.plan.result == 'success' && needs.plan.outputs.sharing == 'true'", body)
            else:
                self.assertIn("    needs: plan\n", body)
                self.assertIn("    if: needs.plan.outputs." + output + " == 'true'", body)
            self.assertNotIn("continue-on-error:", body)
        # Parallel runtime success cannot stand in for a failed/skipped Release.
        for result in ("failure", "skipped", "cancelled"):
            jobs = copy.deepcopy(self.jobs)
            jobs[0]["conclusion"] = result
            self.assertFalse(planner.covers_jobs(jobs, planner.FULL, self.sha))

    def test_real_git_ui_test_and_release_note_select_app_view_without_widget_gallery(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ui_test = scope.MEMORY_TEST_PATH
            note = "NekoWidget/ci/release-candidates/2026-09-25-review.md"
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args], text=True,
                                               encoding="utf-8", stderr=subprocess.PIPE).rstrip("\n")
            def commit():
                git("add", ".")
                git("-c", "user.name=CI", "-c", "user.email=ci@example.invalid", "commit", "-qm", "fixture")
                return git("rev-parse", "HEAD")
            git("init", "-q")
            target = root / ui_test
            target.parent.mkdir(parents=True)
            target.write_text("before\n")
            base = commit()
            git("update-ref", "refs/remotes/origin/main", base)
            target.write_text("after\n")
            release_note = root / note
            release_note.parent.mkdir(parents=True)
            release_note.write_text("Reviewed release candidate.\n")
            head = commit()
            env = dict(self.env, GITHUB_REF="refs/heads/codex/ui-test", GITHUB_SHA=head)
            with patch.object(planner, "git", side_effect=git):
                paths = planner.changed_paths({}, env)
                self.assertEqual(set(paths), {ui_test, note})
                selected = planner.runtime_scope(paths, {}, env)
                self.assertEqual(selected, scope.APP_VIEW_SCOPE)
                self.assertEqual(planner.required_jobs(paths, selected),
                                 planner.required_jobs_from_scope(scope.APP_VIEW_SCOPE))

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
                git("update-index", "--chmod=-x", "handoffs/change.md")
                commit(stage=False)
                release_note = root / "NekoWidget/ci/release-candidates/2026-09-25-review.md"
                release_note.parent.mkdir(parents=True)
                release_note.write_text("Release evidence is reviewed separately.\n")
                commit()
                self.assertEqual(selected(), scope.PHOTO_SCOPE)
                git("update-index", "--chmod=+x", "NekoWidget/ci/release-candidates/2026-09-25-review.md")
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


class TestCorrectionReuseTests(unittest.TestCase):
    def test_split_full_graph_cannot_reuse_historical_pinned_correction(self):
        required = planner.required_jobs_from_scope(scope.FULL_SCOPE)
        self.assertNotEqual(required, planner.ALBUM_CORRECTION_REQUIRED)
        self.assertIsNone(planner.test_correction_scope(required))
        def forbidden_api(path):
            self.fail("Graph mismatch must be rejected before fetching evidence")
        self.assertIsNone(planner.correction_source({}, "a" * 40, planner.ALBUM_CORRECTION_BRANCH,
                          "soso-so-27/neko-widget", 1, required, forbidden_api,
                          dt.datetime.now(dt.timezone.utc)))
        self.assertFalse(planner.covers_corrected_full_graph({}, "a" * 40, required,
                         forbidden_api, dt.datetime.now(dt.timezone.utc), []))
        self.assertIn("Sharing checks [app-ui-solo; scope full-v1]", planner.ALBUM_CORRECTION_REQUIRED)
        self.assertNotIn("Sharing checks [app-ui-solo; scope full-v1]", required)

    def test_signed_log_redirect_strips_token_and_rejects_other_origins(self):
        request = urllib.request.Request("https://api.github.com/repos/o/r/actions/jobs/1/logs",
                                         headers={"Authorization": "Bearer private-test-token"})
        handler = planner.EvidenceLogRedirect()
        target = "https://productionresultssa13.blob.core.windows.net/log?sig=private-test-signature"
        redirected = handler.redirect_request(request, None, 302, "Found", {}, target)
        self.assertFalse(redirected.has_header("Authorization"))
        self.assertTrue(request.has_header("Authorization"))
        for url in ("http://api.github.com/repos/o/r/actions/jobs/1/logs",
                    "http://productionresultssa13.blob.core.windows.net/log", "https://example.invalid/log",
                    "https://productionresultssa13.blob.core.windows.net.example.invalid/log",
                    "https://user@productionresultssa13.blob.core.windows.net/log"):
            with self.assertRaises(planner.CorrectionEvidenceUnavailable):
                handler.redirect_request(request, None, 302, "Found", {}, url)

    def test_album_correction_pins_whole_test_file_and_merged_controls(self):
        head = "a" * 40
        source = planner.ALBUM_CORRECTION_SOURCE
        row = ":100644 100644 " + " ".join(planner.ALBUM_CORRECTION_BLOBS) + " M\0" + scope.MEMORY_TEST_PATH + "\0"
        def check(raw=row, *, approval=True, current=head):
            def git(*args):
                if args[0] == "rev-parse": return current
                if args[0] == "diff": return raw
                if args[0] == "merge-base": return "c" * 40
                if args[0] == "show":
                    return "approved" if approval or not args[1].startswith(head + ":") else "unmerged"
                raise AssertionError(args)
            with patch.object(planner, "git", side_effect=git):
                return planner.album_correction_inputs(source, head)
        self.assertTrue(check())
        self.assertFalse(check(approval=False))
        self.assertFalse(check(current="b" * 40))
        for raw in (row + row, "", row.replace("100644 100644", "100644 100755"),
                    row.replace(" M\0", " T\0"), row.replace(planner.ALBUM_CORRECTION_BLOBS[1], "d" * 40),
                    row + row.replace(scope.MEMORY_TEST_PATH, "NekoWidget/Shared/Models/Photo.swift"),
                    row + row.replace(scope.MEMORY_TEST_PATH, ".github/workflows/ios-build.yml"),
                    row + row.replace(scope.MEMORY_TEST_PATH, "NekoWidget/NekoWidget/Views/TestFixture.swift")):
            self.assertFalse(check(raw), raw)
        with patch.object(planner, "git", side_effect=OSError):
            self.assertFalse(planner.album_correction_inputs(source, head))
        self.assertFalse(planner.album_correction_inputs("b" * 40, head))

    def test_unrelated_full_branches_do_not_query_correction_history(self):
        api = unittest.mock.Mock(side_effect=AssertionError("unrelated history lookup"))
        for branch, repository in (("codex/other", "soso-so-27/neko-widget"),
                                    (planner.ALBUM_CORRECTION_BRANCH, "owner/repo")):
            self.assertIsNone(planner.find_test_correction_evidence("a" * 40, branch, repository,
                              planner.ALBUM_CORRECTION_REQUIRED, api, dt.datetime.now(dt.timezone.utc)))
        api.assert_not_called()

    def test_known_full_correction_missing_history_stops_instead_of_restarting_full(self):
        def api(path):
            return {"id": 5} if path.endswith("ios-build.yml") else {"workflow_runs": [], "total_count": 0}
        with patch.object(planner, "album_correction_inputs", return_value=True):
            with self.assertRaises(planner.CorrectionEvidenceUnavailable):
                planner.find_test_correction_evidence("a" * 40, planner.ALBUM_CORRECTION_BRANCH,
                    "soso-so-27/neko-widget", planner.ALBUM_CORRECTION_REQUIRED, api, dt.datetime.now(dt.timezone.utc))

    def test_album_source_requires_exact_graph_plan_identity_and_every_success(self):
        now = dt.datetime.now(dt.timezone.utc)
        repo, branch, source = "soso-so-27/neko-widget", planner.ALBUM_CORRECTION_BRANCH, planner.ALBUM_CORRECTION_SOURCE
        required = planner.ALBUM_CORRECTION_REQUIRED
        run = {"id": planner.ALBUM_CORRECTION_RUN, "workflow_id": 5, "head_sha": source,
               "head_branch": branch, "event": "push", "status": "completed", "conclusion": "failure",
               "updated_at": now.isoformat(), "repository": {"full_name": repo}, "head_repository": {"full_name": repo}}
        ui = planner.correction_ui_job(scope.FULL_SCOPE)
        jobs = [{"id": 100, "name": planner.PLAN_JOB, "head_sha": source, "status": "completed", "conclusion": "success"}]
        jobs += [{"id": 101 + index, "name": name, "head_sha": source, "status": "completed",
                  "conclusion": "failure" if name == ui else "success", "completed_at": now.isoformat()}
                 for index, name in enumerate(required)]
        record = {"schema_version": 1, "repository": repo, "head_sha": source, "scope": scope.FULL_SCOPE,
                  "required_jobs": list(required), "evidence_run_id": None, "evidence_sha": None}
        def check(*, selected_jobs=jobs, selected_run=run, selected_record=record, double=False, error=None, response="auto"):
            fixture = "IOS_CI_PLAN_JSON=" + json.dumps({**record, "repository": "owner/repo", "head_sha": "b" * 40})
            log = "IOS_CI_PLAN_JSON=" + json.dumps(selected_record)
            with patch.object(planner, "test_correction_inputs", return_value=True), \
                    patch.object(planner, "executed_jobs", return_value=selected_jobs):
                def api(_):
                    if error is not None: raise error
                    if response != "auto": return response
                    return fixture + "\n" + log + ("\n" + log if double else "")
                return planner.correction_source(selected_run, "a" * 40, branch, repo, 5, required,
                                                   api, now)
        self.assertEqual([entry["name"] for entry in check()["jobs"]], [name for name in required if name != ui])
        for index, job in enumerate(jobs):
            for status in ("skipped", "failure"):
                if job["name"] == ui and status == "failure": continue
                broken = copy.deepcopy(jobs); broken[index]["conclusion"] = status
                self.assertIsNone(check(selected_jobs=broken))
        self.assertIsNone(check(selected_jobs=jobs + [jobs[-1]]))
        for key, value in (("id", 1), ("head_sha", "b" * 40), ("event", "workflow_dispatch"),
                           ("run_attempt", 2),
                           ("updated_at", (now - dt.timedelta(hours=25)).isoformat()), ("head_branch", "codex/other")):
            self.assertIsNone(check(selected_run={**run, key: value}))
        for key, value in (("required_jobs", list(required[:-1])), ("scope", "app-view-ui-v1"),
                           ("head_sha", "b" * 40), ("evidence_run_id", 11), ("test_correction_evidence", {})):
            with self.assertRaises(planner.CorrectionEvidenceUnavailable):
                check(selected_record={**record, key: value})
        with self.assertRaises(planner.CorrectionEvidenceUnavailable): check(double=True)
        for error in (OSError("unavailable"), ValueError("unavailable")):
            with self.assertRaises(planner.CorrectionEvidenceUnavailable): check(error=error)
        for response in (None, b"invalid type", "", "IOS_CI_PLAN_JSON={broken"):
            with self.assertRaises(planner.CorrectionEvidenceUnavailable): check(response=response)

    def test_full_correction_runs_solo_only_while_retaining_seven_required_jobs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / "event.json").write_text("{}")
            env = {"GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "outputs"),
                   "GITHUB_STEP_SUMMARY": str(root / "summary"), "GITHUB_EVENT_NAME": "push",
                   "GITHUB_REF": "refs/heads/" + planner.ALBUM_CORRECTION_BRANCH, "GITHUB_SHA": "a" * 40,
                   "GITHUB_REPOSITORY": "soso-so-27/neko-widget", "GITHUB_SERVER_URL": "https://github.com"}
            with patch.dict(os.environ, env), patch.object(planner, "changed_paths", return_value=[]), \
                    patch.object(planner, "runtime_scope", return_value=scope.FULL_SCOPE), \
                    patch.object(planner, "required_jobs", return_value=planner.ALBUM_CORRECTION_REQUIRED), \
                    patch.object(planner, "find_evidence", return_value=None), \
                    patch.object(planner, "find_test_correction_evidence", return_value={"run_id": 1, "sha": "b" * 40, "jobs": [{}] * 6}), \
                    contextlib.redirect_stdout(io.StringIO()) as printed:
                planner.main()
            values = dict(line.split("=", 1) for line in (root / "outputs").read_text().splitlines())
            self.assertEqual(values["app_ui_lanes"], '["app-ui-solo"]')
            self.assertEqual((values["build"], values["smoke"], values["sharing"], values["app_ui"]), ("false", "false", "false", "true"))
            record = next(json.loads(line.split("IOS_CI_PLAN_JSON=", 1)[1]) for line in printed.getvalue().splitlines() if line.startswith("IOS_CI_PLAN_JSON="))
            self.assertEqual(record["required_jobs"], list(planner.ALBUM_CORRECTION_REQUIRED))

    def test_candidate_plan_runs_only_normal_app_ui_after_verified_correction(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            event = root / "event.json"
            event.write_text("{}", encoding="utf-8")
            output = root / "outputs"
            summary = root / "summary"
            head = "a" * 40
            env = {"GITHUB_EVENT_PATH": str(event), "GITHUB_OUTPUT": str(output),
                   "GITHUB_STEP_SUMMARY": str(summary), "GITHUB_EVENT_NAME": "push",
                   "GITHUB_REF": "refs/heads/codex/lost-cat", "GITHUB_SHA": head,
                   "GITHUB_REPOSITORY": "owner/repo", "GITHUB_SERVER_URL": "https://github.com"}
            correction = {"run_id": 10, "sha": "b" * 40, "jobs": []}
            printed = io.StringIO()
            with patch.dict(os.environ, env), patch.object(planner, "changed_paths", return_value=[scope.LOST_CAT_PHOTO_PATH]), \
                    patch.object(planner, "runtime_scope", return_value=planner.LOST_CAT_UX_SCOPE), \
                    patch.object(planner, "required_jobs", return_value=planner.required_jobs_from_scope(planner.LOST_CAT_UX_SCOPE)), \
                    patch.object(planner, "find_evidence", return_value=None), \
                    patch.object(planner, "find_test_correction_evidence", return_value=correction), \
                    contextlib.redirect_stdout(printed):
                planner.main()
            values = dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines())
            self.assertEqual((values["build"], values["smoke"], values["sharing"], values["app_ui"]),
                             ("false", "false", "false", "true"))
            self.assertEqual(values["app_ui_lanes"], '["app-ui"]')
            record = next(json.loads(line.split("IOS_CI_PLAN_JSON=", 1)[1]) for line in printed.getvalue().splitlines()
                          if line.startswith("IOS_CI_PLAN_JSON="))
            self.assertEqual(record["test_correction_evidence"], correction)
            self.assertEqual(record["required_jobs"], list(planner.required_jobs_from_scope(planner.LOST_CAT_UX_SCOPE)))

    def test_managed_pilot_correction_excludes_product_and_fixture_changes(self):
        self.test_only_existing_owned_test_bodies_and_ci_controls_may_change(scope.REVIEWED_MANAGED_PRESERVATION_SCOPE)

    def test_managed_deletion_correction_excludes_product_and_fixture_changes(self):
        self.test_only_existing_owned_test_bodies_and_ci_controls_may_change(
            scope.REVIEWED_MANAGED_PRESERVATION_SCOPE, "testManagedPreservationAccountDeletionRetainsReceiptAndCompletes")

    def test_vet_correction_excludes_product_fixture_other_methods_and_unmerged_controls(self):
        self.test_only_existing_owned_test_bodies_and_ci_controls_may_change(scope.VET_SAVED_CAT_SCOPE)

    def test_only_existing_owned_test_bodies_and_ci_controls_may_change(self, selected_scope=scope.LOST_CAT_UX_SCOPE, body_method=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args], text=True,
                                               encoding="utf-8", stderr=subprocess.PIPE).rstrip("\n")
            def write(path, value):
                target = root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(value, encoding="utf-8")
            def commit():
                git("add", ".")
                git("-c", "user.name=CI", "-c", "user.email=ci@example.invalid",
                    "commit", "-qm", "fixture")
                return git("rev-parse", "HEAD")
            git("init", "-q")
            names = (["testManagedPreservationLostCopyResultShowsConfirmationAndStoredState",
                      "testManagedPreservationAccountDeletionRetainsReceiptAndCompletes"]
                     if selected_scope == scope.REVIEWED_MANAGED_PRESERVATION_SCOPE else
                     ["testVeterinarySelectionIsExplicitAndRemovalKeepsSource"] if selected_scope == scope.VET_SAVED_CAT_SCOPE else
                     sorted(scope.LOST_CAT_PHOTO_TEST_NAMES))
            before = ("final class SoloMemoriesUITests: XCTestCase {\n"
                      + "".join(f"    func {name}() {{\n        XCTAssertTrue(true)\n    }}\n"
                                for name in names) + "}\n")
            needle = f"func {body_method or names[0]}() {{\n        XCTAssertTrue(true)"
            after = before.replace(needle, needle.replace("XCTAssertTrue(true)", "XCTAssertTrue(false)"), 1)
            test_path = scope.MEMORY_TEST_PATH
            control = "NekoWidget/ci/plan-ios-ci.py"
            product = "NekoWidget/NekoWidget/Views/CatPreparednessView.swift"
            workflow = ".github/workflows/ios-build.yml"
            for path, value in ((test_path, before), (control, "old\n"),
                                (product, "old\n"), (workflow, "old\n")):
                write(path, value)
            source = commit()
            with patch.object(planner, "git", side_effect=git):
                write(test_path, after)
                write(control, "new\n")
                head = commit()
                if selected_scope == scope.VET_SAVED_CAT_SCOPE:
                    git("update-ref", "refs/remotes/origin/main", head)
                self.assertTrue(planner.test_correction_inputs(source, head, selected_scope))
                if selected_scope == scope.VET_SAVED_CAT_SCOPE:
                    # A later already-main backend control registration does
                    # not revoke the candidate's prior merged control inputs.
                    write(control, "later main control\n")
                    later_main = commit()
                    git("update-ref", "refs/remotes/origin/main", later_main)
                    git("checkout", "--detach", "-q", head)
                    self.assertTrue(planner.test_correction_inputs(source, head, selected_scope))
                    write(control, "unmerged control\n")
                    self.assertFalse(planner.test_correction_inputs(source, commit(), selected_scope))
                    for replacement in (after.replace("\n}\n", "\n    func testUnrelated() {}\n}\n", 1),
                                        after.replace("\n}\n", "\n    private func helper() {}\n}\n", 1)):
                        git("checkout", "--detach", "-q", source)
                        write(test_path, replacement)
                        self.assertFalse(planner.test_correction_inputs(source, commit(), selected_scope))
                forbidden = (product, workflow) + (("NekoWidget/NekoWidget/Views/EvacuationFixtureView.swift",
                    "NekoWidget/NekoWidget/Views/VeterinaryVisitView.swift") if selected_scope == scope.VET_SAVED_CAT_SCOPE else ())
                for path in forbidden:
                    git("checkout", "--detach", "-q", source)
                    write(test_path, after)
                    write(path, "new\n")
                    self.assertFalse(planner.test_correction_inputs(source, commit(), selected_scope))
                git("checkout", "--detach", "-q", source)
                write(test_path, before.replace("final class", "public final class"))
                self.assertFalse(planner.test_correction_inputs(source, commit(), selected_scope))

    def test_managed_pilot_failed_source_requires_each_successful_native_job(self):
        self.test_failed_source_reuses_only_three_successful_jobs(scope.REVIEWED_MANAGED_PRESERVATION_SCOPE)

    def test_vet_failed_source_requires_each_successful_native_job(self):
        self.test_failed_source_reuses_only_three_successful_jobs(scope.VET_SAVED_CAT_SCOPE)

    def test_failed_source_reuses_only_three_successful_jobs(self, selected_scope=scope.LOST_CAT_UX_SCOPE):
        now = dt.datetime.now(dt.timezone.utc)
        head, source = "a" * 40, "b" * 40
        required = planner.required_jobs_from_scope(selected_scope)
        run = {"id": 10, "workflow_id": 5, "head_sha": source, "head_branch": "codex/lost-cat",
               "event": "push", "status": "completed", "conclusion": "failure",
               "updated_at": now.isoformat(), "repository": {"full_name": "owner/repo"},
               "head_repository": {"full_name": "owner/repo"}}
        jobs = [{"id": 100, "name": planner.PLAN_JOB, "head_sha": source,
                 "status": "completed", "conclusion": "success"}]
        jobs += [{"id": 101 + index, "name": name, "head_sha": source, "status": "completed",
                  "conclusion": "failure" if name == required[-1] else "success",
                  "completed_at": now.isoformat()} for index, name in enumerate(required)]
        with patch.object(planner, "test_correction_inputs", return_value=True), \
                patch.object(planner, "executed_jobs", return_value=jobs):
            evidence = planner.correction_source(run, head, "codex/lost-cat", "owner/repo", 5,
                                                 required, None, now)
            self.assertEqual([entry["name"] for entry in evidence["jobs"]], list(required[:3]))
            for index in range(1, 4):
                broken = copy.deepcopy(jobs)
                broken[index]["conclusion"] = "skipped"
                with patch.object(planner, "executed_jobs", return_value=broken):
                    self.assertIsNone(planner.correction_source(run, head, "codex/lost-cat", "owner/repo", 5,
                                                                 required, None, now))
            self.assertIsNone(planner.correction_source({**run, "head_branch": "codex/other"}, head,
                                                        "codex/lost-cat", "owner/repo", 5, required, None, now))


class PhotoSmokeCorrectionTests(unittest.TestCase):
    def setUp(self):
        self.now = dt.datetime.now(dt.timezone.utc)
        self.head = "a" * 40
        self.source = planner.PHOTO_SMOKE_CORRECTION_SOURCE
        self.required = planner.ALBUM_CORRECTION_REQUIRED
        self.solo_job = planner.PHOTO_SMOKE_CORRECTION_SOLO_JOB
        self.other_job = scope.lane_job(scope.FULL_SCOPE, "app-ui-other")
        self.owning = (planner.SMOKE, self.other_job, self.solo_job)
        self.run = {"id": planner.PHOTO_SMOKE_CORRECTION_RUN, "workflow_id": 5,
                    "head_sha": self.source, "head_branch": planner.PHOTO_SMOKE_CORRECTION_BRANCH,
                    "event": "push", "status": "completed", "conclusion": "failure", "run_attempt": 1,
                    "updated_at": self.now.isoformat(),
                    "repository": {"full_name": "soso-so-27/neko-widget"},
                    "head_repository": {"full_name": "soso-so-27/neko-widget"}}
        self.jobs = [{"id": 100, "name": planner.PLAN_JOB, "head_sha": self.source,
                      "status": "completed", "conclusion": "success"}]
        source_outcomes = {planner.SMOKE: "failure", self.other_job: "failure", self.solo_job: "cancelled"}
        for index, name in enumerate(self.required):
            job = {"id": 101 + index, "name": name, "head_sha": self.source, "status": "completed",
                   "conclusion": source_outcomes.get(name, "success"), "completed_at": self.now.isoformat()}
            if name == self.solo_job:
                job["id"] = planner.PHOTO_SMOKE_CORRECTION_SOLO_JOB_ID
                job["steps"] = [
                    {"name": "Run sharing runtime matrix", "status": "completed", "conclusion": "cancelled"},
                    {"name": "Upload sharing runtime matrix artifacts", "status": "completed", "conclusion": "failure"},
                ]
            self.jobs.append(job)
        self.plan = {"schema_version": 1, "repository": "soso-so-27/neko-widget", "head_sha": self.source,
                     "scope": scope.FULL_SCOPE, "required_jobs": list(self.required),
                     "evidence_run_id": None, "evidence_sha": None}
        self.failures = "\n".join("Test Case '-[NekoWidgetUITests." + case.replace("/", " ") + "]' failed"
                                  for case in sorted(planner.PHOTO_SMOKE_CORRECTION_CASES))
        self.solo_log = ("Test Suite 'SoloMemoriesUITests' passed at 2026-10-05 01:13:21.029.\n"
                         + "Executed 46 tests, with 0 failures (0 unexpected) in 3676.850 (3676.913) seconds\n" * 3
                         + "** TEST SUCCEEDED **\n"
                         + "Sharing checks [app-ui-solo; scope full-v1]\tUpload sharing runtime matrix artifacts\n"
                         + "Error: ENOENT: no such file or directory, open '/Users/runner/work/_temp/MomentComposer.xcresult/Staging/1_Test/Diagnostics/session.log'\n"
                         + "Error: An error has occurred during zip creation for the artifact\n")

    def source_check(self, jobs=None, run=None, failures=None, plan=None, solo_log=None):
        def api(path):
            if path.endswith("/jobs/100/logs"):
                return "IOS_CI_PLAN_JSON=" + json.dumps(self.plan if plan is None else plan)
            if path.endswith(f"/jobs/{planner.PHOTO_SMOKE_CORRECTION_SOLO_JOB_ID}/logs"):
                return self.solo_log if solo_log is None else solo_log
            return self.failures if failures is None else failures
        with patch.object(planner, "test_correction_inputs", return_value=True), \
                patch.object(planner, "executed_jobs", return_value=self.jobs if jobs is None else jobs):
            return planner.correction_source(self.run if run is None else run, self.head,
                planner.PHOTO_SMOKE_CORRECTION_BRANCH, "soso-so-27/neko-widget", 5,
                self.required, api, self.now)

    def test_pin_rejects_other_bodies_product_modes_and_unapproved_controls(self):
        workflow_before = ("  sharing-app-ui:\n" + planner.PHOTO_SMOKE_CORRECTION_OLD_BUDGET)
        workflow_after = workflow_before.replace(
            planner.PHOTO_SMOKE_CORRECTION_OLD_BUDGET, planner.PHOTO_SMOKE_CORRECTION_NEW_BUDGET, 1)
        memory_row = ":100644 100644 " + " ".join(planner.PHOTO_SMOKE_CORRECTION_BLOBS) + " M\0" + scope.MEMORY_TEST_PATH + "\0"
        workflow_row = ":100644 100644 " + "e" * 40 + " " + "f" * 40 + " M\0" + planner.PHOTO_SMOKE_CORRECTION_WORKFLOW_PATH + "\0"
        row = memory_row + workflow_row
        def check(raw=row, approval=True, source_workflow=workflow_before, candidate_workflow=workflow_after):
            def git(*args):
                if args[0] == "rev-parse": return self.head
                if args[0] == "diff": return raw
                if args[0] == "merge-base": return "c" * 40
                if args[0] == "show":
                    revision, path = args[1].split(":", 1)
                    if path == planner.PHOTO_SMOKE_CORRECTION_WORKFLOW_PATH:
                        if revision == self.source: return source_workflow
                        if revision == self.head: return candidate_workflow
                        return candidate_workflow if approval else "unmerged"
                    return "approved" if approval or not revision.startswith(self.head) else "unmerged"
                raise AssertionError(args)
            with patch.object(planner, "git", side_effect=git):
                return planner.photo_smoke_correction_inputs(self.source, self.head)
        self.assertTrue(check())
        self.assertFalse(check(approval=False))
        self.assertFalse(check(raw=memory_row))
        self.assertFalse(check(source_workflow=workflow_before.replace("timeout-minutes: 75", "timeout-minutes: 60")))
        self.assertFalse(check(candidate_workflow=workflow_after.replace("timeout-minutes: 90", "timeout-minutes: 95")))
        self.assertFalse(check(candidate_workflow=workflow_after + "extra\n"))
        for path in ("NekoWidget/ci/test-ci-lanes.py", "NekoWidget/ci/test-release-flow.py"):
            control_row = f":100644 100644 {'c' * 40} {'d' * 40} M\0{path}\0"
            self.assertTrue(check(raw=row + control_row))
            self.assertFalse(check(raw=row + control_row, approval=False))
        for raw in ("", row + row, row.replace("100644 100644", "100644 100755"),
                    row.replace(" M\0", " T\0"), row.replace(planner.PHOTO_SMOKE_CORRECTION_BLOBS[1], "d" * 40),
                    row + row.replace(scope.MEMORY_TEST_PATH, "NekoWidget/NekoWidget/Views/LikedPhotosView.swift"),
                    row + row.replace(scope.MEMORY_TEST_PATH, ".github/workflows/ios-build.yml")):
            self.assertFalse(check(raw), raw)

    def test_source_reuses_only_four_successes_and_reruns_every_failed_or_incomplete_lane(self):
        result = self.source_check()
        self.assertEqual({item["name"] for item in result["jobs"]}, set(self.required) - set(self.owning))
        self.assertEqual(len(result["jobs"]), 4)
        for index, job in enumerate(self.jobs):
            for conclusion in ("skipped", "failure", "success", "cancelled"):
                if conclusion == job["conclusion"]: continue
                broken = copy.deepcopy(self.jobs); broken[index]["conclusion"] = conclusion
                if job["name"] not in self.owning and conclusion == "success": continue
                self.assertIsNone(self.source_check(jobs=broken))
        self.assertIsNone(self.source_check(jobs=self.jobs + [self.jobs[-1]]))
        for failures in ("", self.failures.splitlines()[0], self.failures + "\n" + self.failures,
                         self.failures + "\nTest Case '-[NekoWidgetUITests.SoloMemoriesUITests testOther]' failed"):
            self.assertIsNone(self.source_check(failures=failures))
        for invalid_log in (self.solo_log.replace("Executed 46 tests, with 0 failures", "Executed 46 tests, with 1 failure", 1),
                            self.solo_log.replace("** TEST SUCCEEDED **", "** TEST FAILED **", 1),
                            self.solo_log.replace("ENOENT: no such file or directory", "EACCES: permission denied", 1),
                            self.solo_log.replace("Error: An error has occurred during zip creation for the artifact\n", "")):
            self.assertIsNone(self.source_check(solo_log=invalid_log))
        for key, value in (("id", 1), ("head_sha", "b" * 40), ("event", "workflow_dispatch"),
                           ("run_attempt", 2), ("head_branch", "codex/other"),
                           ("updated_at", (self.now - dt.timedelta(hours=25)).isoformat())):
            self.assertIsNone(self.source_check(run={**self.run, key: value}))
        for key, value in (("required_jobs", list(self.required[:-1])), ("head_sha", "b" * 40),
                           ("evidence_run_id", 4), ("test_correction_evidence", {})):
            with self.assertRaises(planner.CorrectionEvidenceUnavailable):
                self.source_check(plan={**self.plan, key: value})

    def test_new_candidate_selects_complete_smoke_and_both_ui_lanes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / "event.json").write_text("{}")
            env = {"GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                   "GITHUB_STEP_SUMMARY": str(root / "summary"), "GITHUB_EVENT_NAME": "push",
                   "GITHUB_REF": "refs/heads/" + planner.PHOTO_SMOKE_CORRECTION_BRANCH,
                   "GITHUB_SHA": self.head, "GITHUB_REPOSITORY": "soso-so-27/neko-widget",
                   "GITHUB_SERVER_URL": "https://github.com"}
            with patch.dict(os.environ, env), patch.object(planner, "changed_paths", return_value=[]), \
                    patch.object(planner, "runtime_scope", return_value=scope.FULL_SCOPE), \
                    patch.object(planner, "required_jobs", return_value=self.required), \
                    patch.object(planner, "find_evidence", return_value=None), \
                    patch.object(planner, "find_test_correction_evidence", return_value=self.source_check()), \
                    contextlib.redirect_stdout(io.StringIO()) as printed:
                planner.main()
            values = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
            self.assertEqual((values["build"], values["smoke"], values["sharing"], values["app_ui"]),
                             ("false", "true", "false", "true"))
            self.assertEqual(values["app_ui_lanes"], '["app-ui-other","app-ui-solo"]')
            record = next(json.loads(line.split("IOS_CI_PLAN_JSON=", 1)[1]) for line in printed.getvalue().splitlines()
                          if line.startswith("IOS_CI_PLAN_JSON="))
            self.assertEqual(record["required_jobs"], list(self.required))

    def test_main_and_release_qualify_new_three_and_revalidate_original_four(self):
        evidence = self.source_check()
        candidate = {**self.run, "id": 20, "head_sha": self.head, "conclusion": "success"}
        current_jobs = [{**job, "id": job["id"] + 100, "head_sha": self.head,
                         "conclusion": "success" if job["name"] in {planner.PLAN_JOB, *self.owning} else "skipped"}
                        for job in self.jobs]
        record = {**self.plan, "head_sha": self.head, "test_correction_evidence": evidence}
        def check(jobs=current_jobs, original=self.jobs, selected_record=record):
            def api(path):
                if path.endswith("/runs/" + str(self.run["id"])): return self.run
                if path.endswith("/jobs/200/logs"): return "IOS_CI_PLAN_JSON=" + json.dumps(selected_record)
                if path.endswith("/jobs/100/logs"): return "IOS_CI_PLAN_JSON=" + json.dumps(self.plan)
                if path.endswith(f"/jobs/{planner.PHOTO_SMOKE_CORRECTION_SOLO_JOB_ID}/logs"): return self.solo_log
                return self.failures
            with patch.object(planner, "test_correction_inputs", return_value=True), \
                    patch.object(planner, "executed_jobs", return_value=original):
                return planner.covers_corrected_full_graph(candidate, "c" * 40, self.required, api, self.now, jobs)
        self.assertTrue(check())
        for index, job in enumerate(current_jobs):
            if job["name"] not in self.owning: continue
            for outcome in ("skipped", "failure"):
                broken = copy.deepcopy(current_jobs); broken[index]["conclusion"] = outcome
                self.assertFalse(check(jobs=broken))
            self.assertFalse(check(jobs=current_jobs + [job]))
        for index, job in enumerate(self.jobs):
            if job["name"] in self.owning: continue
            broken = copy.deepcopy(self.jobs); broken[index]["conclusion"] = "skipped"
            self.assertFalse(check(original=broken))
        self.assertFalse(check(selected_record={**record, "head_sha": "b" * 40}))
        self.assertFalse(check(selected_record={**record, "evidence_run_id": 7}))
        self.assertFalse(check(selected_record={**record, "test_correction_evidence": {**evidence, "run_id": 7}}))


if __name__ == "__main__":
    unittest.main()
