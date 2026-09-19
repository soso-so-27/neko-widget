#!/usr/bin/env python3
"""Ensure split jobs conserve checks and cannot reuse partial/legacy evidence."""

import copy
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

import ios_ci_scope as scope

CI = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("planner", CI / "plan-ios-ci.py")
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)


def workflow_jobs():
    workflow = (CI.parents[1] / ".github/workflows/ios-build.yml").read_text(encoding="utf-8")
    return dict(re.findall(r"^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)",
                           workflow.split("\njobs:\n", 1)[1], re.M | re.S))


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
        for selected in (scope.PHOTO_SCOPE, scope.OFFICIAL_SCOPE, scope.COMBINED_SCOPE):
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
        jobs = workflow_jobs()
        matrix = jobs["sharing-runtime-matrix"]
        self.assertIn("fail-fast: false", matrix)
        self.assertIn("lane: ${{ fromJSON(needs.plan.outputs.matrix_lanes) }}", matrix)
        self.assertIn("NEKO_IOS_RUNTIME_LANE: ${{ matrix.lane }}", matrix)
        self.assertIn("${{ matrix.lane }}-${{ needs.plan.outputs.runtime_scope }}-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}", matrix)
        for identifier in ("sharing-app-ui", "sharing-runtime-matrix"):
            body = jobs[identifier]
            self.assertNotIn("download-artifact", body)
            self.assertNotIn("continue-on-error", body)
            expected_timeout = 75 if identifier == "sharing-app-ui" else 60
            self.assertIn(f"timeout-minutes: {expected_timeout}", body)
            # Scheduling must not change checkout isolation, commands, flags,
            # artifact provenance or whether a failure is propagated.
            steps = body.split("    steps:\n", 1)[1]
            if identifier == "sharing-app-ui":
                steps = steps.replace("NEKO_IOS_RUNTIME_LANE: app-ui", "NEKO_IOS_RUNTIME_LANE: ${{ matrix.lane }}")
                steps = steps.replace("ios-sharing-app-ui-", "ios-sharing-${{ matrix.lane }}-")
            self.assertEqual(steps.strip(), matrix.split("    steps:\n", 1)[1].strip())

    def test_actual_workflow_keeps_app_ui_in_first_five_without_losing_evidence(self):
        jobs = workflow_jobs()
        for selected in scope.SCOPES:
            with self.subTest(scope=selected):
                remaining = scope.matrix_lanes(selected)
                has_app_ui = "app-ui" in scope.lanes(selected)
                partition = (("app-ui",) if has_app_ui else ()) + remaining
                self.assertCountEqual(partition, scope.lanes(selected))
                self.assertEqual(len(partition), len(set(partition)))
                outputs = {"lanes": scope.lanes(selected), "matrix_lanes": remaining}
                parallelism = 3 if selected == scope.WIDGET_STYLE_SCOPE else 2
                maximum_running = 0
                names = []
                for identifier, body in jobs.items():
                    if "    runs-on: macos-15\n" not in body:
                        continue
                    if selected == scope.ICON_SCOPE and identifier != "build-without-signing":
                        continue
                    if identifier == "sharing-app-ui" and not has_app_ui:
                        self.assertIn("if: needs.plan.outputs.app_ui == 'true'", body)
                        continue
                    matrix = re.search(r"lane: \$\{\{ fromJSON\(needs.plan.outputs.(\w+)\) \}\}", body)
                    expansion = outputs[matrix[1]] if matrix else (None,)
                    limit = parallelism if matrix else len(expansion)
                    if matrix:
                        self.assertIn("max-parallel: ${{ fromJSON(needs.plan.outputs.matrix_parallelism) }}", body)
                    maximum_running += min(len(expansion), limit)
                    # Every Mac check depends only on the planner. A failed
                    # sibling neither blocks another check nor forces its rerun.
                    self.assertIn("    needs: plan\n", body)
                    self.assertNotIn("continue-on-error", body)
                    name = re.search(r"^    name: (.+)$", body, re.M)[1]
                    for lane in expansion:
                        expanded_name = name.replace("${{ needs.plan.outputs.runtime_scope }}", selected)
                        expanded_name = expanded_name.replace("${{ needs.plan.outputs.build_name }}",
                            planner.ICON_BUILD if selected == scope.ICON_SCOPE else planner.BUILD)
                        expanded_name = expanded_name.replace("${{ needs.plan.outputs.smoke_name }}", planner.smoke_job(selected))
                        if lane:
                            expanded_name = expanded_name.replace("${{ matrix.lane }}", lane)
                        names.append(expanded_name)
                self.assertCountEqual(names, planner.required_jobs_from_scope(selected))
                self.assertEqual(len(names), len(set(names)))
                if has_app_ui:
                    self.assertIn("    name: " + scope.lane_job(selected, "app-ui").replace(selected,
                        "${{ needs.plan.outputs.runtime_scope }}"), jobs["sharing-app-ui"])
                self.assertNotIn("    strategy:", jobs["sharing-app-ui"])
                self.assertLessEqual(maximum_running, 5)
                self.assertEqual(maximum_running, 1 if selected == scope.ICON_SCOPE else
                    4 if selected in (scope.PHOTO_SCOPE, scope.OFFICIAL_SCOPE, scope.COMBINED_SCOPE, scope.REVIEWED_APP_SCOPE, scope.ARCHIVE_PICKER_SCOPE) else 5)
                if selected in (scope.PHOTO_SCOPE, scope.OFFICIAL_SCOPE, scope.COMBINED_SCOPE, scope.REVIEWED_APP_SCOPE):
                    self.assertEqual(remaining, ("runtime",))
        with self.assertRaises(ValueError):
            scope.matrix_lanes("unknown")

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
