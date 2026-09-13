#!/usr/bin/env python3
"""Ensure split jobs conserve checks and cannot reuse partial/legacy evidence."""

import copy
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import ios_ci_scope as scope

CI = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("planner", CI / "plan-ios-ci.py")
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)


class LaneTests(unittest.TestCase):
    def test_full_partition_preserves_all_app_suites_and_three_gallery_conditions(self):
        self.assertEqual(scope.lanes(scope.FULL_SCOPE),
                         ("runtime", "app-ui", "gallery-normal", "gallery-white", "gallery-no-caption"))
        self.assertEqual(scope.lane_tests(scope.FULL_SCOPE, "runtime"), ())
        app = scope.lane_tests(scope.FULL_SCOPE, "app-ui")
        self.assertEqual(set(app), set(scope.native_tests(scope.FULL_SCOPE)) - {scope.GALLERY_TEST})
        self.assertEqual(len(app), len(set(app)))
        self.assertEqual(scope.lane_tests(scope.FULL_SCOPE, "gallery-normal"), (scope.GALLERY_TEST,))
        self.assertEqual(scope.lane_tests(scope.FULL_SCOPE, "gallery-no-caption"), (scope.GALLERY_TEST,))
        self.assertIn("WhiteBackground", scope.lane_tests(scope.FULL_SCOPE, "gallery-white")[0])
        self.assertIn("NO_CAPTION", scope.GALLERY_CONDITIONS["gallery-no-caption"])
        self.assertIn("LONG_CAPTION", scope.GALLERY_CONDITIONS["gallery-white"])
        self.assertIn("LARGE_TEXT", scope.GALLERY_CONDITIONS["gallery-white"])

    def test_mapped_scope_keeps_runtime_and_its_existing_ui_suites(self):
        for selected in scope.SCOPES[1:]:
            self.assertEqual(scope.lanes(selected), ("runtime", "app-ui"))
            self.assertEqual(scope.lane_tests(selected, "app-ui"), scope.native_tests(selected))
            with self.assertRaises(ValueError):
                scope.lane_tests(selected, "gallery-normal")
        for selected, lane in (("unknown", "runtime"), (scope.FULL_SCOPE, "unknown")):
            with self.assertRaises(ValueError):
                scope.lane_tests(selected, lane)

    def test_each_missing_failed_skipped_duplicate_or_wrong_sha_lane_prevents_reuse(self):
        sha = "a" * 40
        jobs = [dict(name=name, status="completed", conclusion="success", head_sha=sha)
                for name in planner.FULL]
        self.assertTrue(planner.covers_jobs(jobs, planner.FULL, sha))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], planner.FULL, sha))
            self.assertFalse(planner.covers_jobs(jobs + [jobs[index]], planner.FULL, sha))
            for key, value in (("conclusion", "failure"), ("conclusion", "skipped"),
                               ("conclusion", "cancelled"), ("head_sha", "b" * 40)):
                altered = copy.deepcopy(jobs)
                altered[index][key] = value
                self.assertFalse(planner.covers_jobs(altered, planner.FULL, sha))
        legacy = jobs[:2] + [dict(jobs[2], name=scope.sharing_job(scope.FULL_SCOPE))]
        self.assertFalse(planner.covers_jobs(legacy, planner.FULL, sha))

    def test_lane_metadata_reports_only_executed_os_and_exact_test_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for lane in scope.LANES:
                result = subprocess.run([sys.executable, str(CI / "ios_ci_scope.py"),
                    "--scope", scope.FULL_SCOPE, "--lane", lane, "--metadata", str(root / "meta.json"),
                    "--tests", str(root / "tests.txt")], env=dict(os.environ, GITHUB_SHA="a" * 40),
                    capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                meta = json.loads((root / "meta.json").read_text())
                self.assertEqual(meta["lane"], lane)
                self.assertEqual(meta["commit"], "a" * 40)
                self.assertEqual(meta["sharingRuntime"], ["ios-18-5", "ios-26-2"] if lane == "runtime" else ["ios-26-2"])
                self.assertEqual(meta["nativeTests"], list(scope.lane_tests(scope.FULL_SCOPE, lane)))
                self.assertEqual((root / "tests.txt").read_text().splitlines(),
                                 ["-only-testing:" + test for test in meta["nativeTests"]])

    def test_workflow_isolates_products_and_preserves_independent_failures(self):
        workflow = (CI.parents[1] / ".github/workflows/ios-build.yml").read_text(encoding="utf-8")
        body = workflow.split("\n  sharing-runtime-matrix:", 1)[1]
        self.assertIn("fail-fast: false", body)
        self.assertIn("lane: ${{ fromJSON(needs.plan.outputs.lanes) }}", body)
        self.assertIn("NEKO_IOS_RUNTIME_LANE: ${{ matrix.lane }}", body)
        self.assertIn("${{ matrix.lane }}-${{ needs.plan.outputs.runtime_scope }}-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}", body)
        self.assertNotIn("download-artifact", body)
        self.assertNotIn("continue-on-error", body)

    def test_partial_rerun_keeps_passed_siblings_and_uses_only_latest_result(self):
        run = dict(id=42, head_sha="a" * 40, run_attempt=2)
        first = [dict(id=index + 1, run_id=42, run_attempt=1, name=name,
                      status="completed", conclusion="success", head_sha=run["head_sha"])
                 for index, name in enumerate(planner.FULL)]
        first[-1]["conclusion"] = "failure"
        retry = dict(first[-1], id=20, run_attempt=2, conclusion="success")
        def select(records):
            return planner.executed_jobs(run, "owner/repo", lambda path: {
                "jobs": records, "total_count": len(records)})
        self.assertTrue(planner.covers_jobs(select(first + [retry]), planner.FULL, run["head_sha"]))
        for value in ("failure", "skipped", "cancelled"):
            self.assertFalse(planner.covers_jobs(select(first + [dict(retry, conclusion=value)]),
                                                planner.FULL, run["head_sha"]))
        for records in (first + [retry, dict(retry, id=21)], first + [dict(retry, head_sha="b" * 40)],
                        first + [dict(retry, run_id=43)], first + [dict(retry, run_attempt=3)]):
            with self.assertRaises(ValueError):
                select(records)
        with self.assertRaises(ValueError):
            planner.executed_jobs(run, "owner/repo", lambda path: {"jobs": first, "total_count": 101})

    def test_rerun_cannot_refresh_stale_sibling_evidence(self):
        now = dt.datetime(2026, 9, 13, 6, tzinfo=dt.timezone.utc)
        jobs = [dict(name=name, head_sha="a" * 40, status="completed", conclusion="success",
                     completed_at="2026-09-13T05:00:00Z") for name in planner.FULL]
        self.assertTrue(planner.covers_jobs(jobs, planner.FULL, "a" * 40, now))
        for stale in ("2026-09-11T05:00:00Z", "2026-09-14T05:00:00Z", "invalid", None):
            changed = copy.deepcopy(jobs)
            changed[0]["completed_at"] = stale
            self.assertFalse(planner.covers_jobs(changed, planner.FULL, "a" * 40, now))


if __name__ == "__main__":
    unittest.main()
