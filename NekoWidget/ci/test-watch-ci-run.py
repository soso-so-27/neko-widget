#!/usr/bin/env python3
"""Small metadata-only fixtures; no network, real waits, or GitHub mutations."""

import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("watch_ci", Path(__file__).with_name("watch-ci-run.py"))
watcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watcher)


def fixture(status="in_progress", conclusion=None):
    return {
        "databaseId": 42, "headSha": "a" * 40, "attempt": 1,
        "status": status, "conclusion": conclusion,
        "createdAt": "2026-09-19T00:00:00Z", "startedAt": "2026-09-19T00:01:00Z",
        "updatedAt": "2026-09-19T00:05:00Z",
        "jobs": [{"databaseId": 101, "name": "Build", "status": status,
                  "conclusion": conclusion, "startedAt": "2026-09-19T00:01:00Z",
                  "completedAt": "2026-09-19T00:03:00Z" if status == "completed" else None,
                  "steps": [{"name": "not retained", "status": "in_progress"}]}],
    }


class WatchTests(unittest.TestCase):
    def run_watch(self, responses):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "result.json"
            args = watcher.parse_arguments(["42", "--expected-sha", "a" * 40, "--output", str(output)])
            stream = io.StringIO()
            with patch.object(watcher, "read_run", side_effect=responses) as read, \
                    patch.object(watcher, "sleep_chunked") as sleep, contextlib.redirect_stdout(stream):
                code = watcher.watch(args)
            document = json.loads(output.read_text(encoding="utf-8"))
            messages = [json.loads(line) for line in stream.getvalue().splitlines()]
            return code, document, messages, read.call_count, [call.args[0] for call in sleep.call_args_list]

    def test_quiet_steps_backoff_and_final_metrics(self):
        initial = fixture()
        step_changed = copy.deepcopy(initial)
        step_changed["jobs"][0]["steps"][0]["status"] = "completed"
        step_changed["updatedAt"] = "2026-09-19T00:02:00Z"
        final = fixture("completed", "success")
        second = copy.deepcopy(final["jobs"][0])
        second.update(databaseId=102, name="Other job")
        final["jobs"].append(second)
        code, result, messages, calls, sleeps = self.run_watch([initial, step_changed, step_changed, step_changed, final])
        self.assertEqual(code, 0)
        self.assertEqual(sleeps, [60, 90, 135, 180])
        self.assertEqual([m["event"] for m in messages], ["start", "jobs_completed", "final"])
        self.assertEqual(result["summary"]["runner_minutes"], 4)
        self.assertEqual(result["summary"]["total_seconds"], 300)
        self.assertTrue(result["summary"]["runner_minutes_complete"])
        self.assertNotIn("steps", json.dumps(result))
        self.assertNotIn("not retained", json.dumps(result))
        self.assertEqual(calls, 5)

    def test_job_failure_reported_once_then_wait_for_run(self):
        initial = fixture()
        failing = fixture()
        failing["jobs"][0].update(status="completed", conclusion="failure", completedAt="2026-09-19T00:03:00Z")
        final = fixture("completed", "failure")
        code, _, messages, calls, _ = self.run_watch([initial, failing, failing, final])
        self.assertEqual(code, 1)
        completions = [m for m in messages if m["event"] == "jobs_completed"]
        self.assertEqual(len(completions), 1)
        self.assertEqual(completions[0]["jobs"][0]["conclusion"], "failure")
        self.assertEqual(calls, 4)
        # A failure already present when attaching must also be visible once.
        code, _, messages, _, _ = self.run_watch([failing, failing, final])
        self.assertEqual(code, 1)
        self.assertEqual(len([m for m in messages if m["event"] == "jobs_completed"]), 1)

    def test_identity_and_unknown_state_stop_without_retry(self):
        for change, reason in [
            ({"databaseId": 43}, "run_id_mismatch"),
            ({"headSha": "b" * 40}, "sha_mismatch"),
            ({"status": "mystery"}, "unknown_state"),
            ({"status": ["in_progress"]}, "unknown_state"),
            ({"conclusion": {"private": "invalid metadata"}}, "unknown_state"),
        ]:
            with self.subTest(reason=reason):
                response = fixture()
                response.update(change)
                code, result, _, calls, sleeps = self.run_watch([response])
                self.assertEqual((code, calls, sleeps), (2, 1, []))
                self.assertEqual(result["summary"]["reason"], reason)
                self.assertIsNone(result["run"])
        rerun = fixture()
        rerun["attempt"] = 2
        code, result, _, calls, _ = self.run_watch([fixture(), rerun])
        self.assertEqual((code, calls), (2, 2))
        self.assertEqual(result["summary"]["reason"], "run_identity_changed")

    def test_waiting_stops_for_human_without_approval(self):
        code, result, messages, calls, sleeps = self.run_watch([fixture("waiting")])
        self.assertEqual((code, calls, sleeps), (3, 1, []))
        self.assertEqual(messages[-1]["outcome"], "attention_required")
        self.assertFalse(result["summary"]["runner_minutes_complete"])

    def test_network_retry_budget_and_auth_failure(self):
        transient = watcher.WatchError("network_unavailable", retryable=True)
        code, result, messages, calls, sleeps = self.run_watch([transient, transient, transient])
        self.assertEqual((code, calls, sleeps), (2, 3, [60, 120]))
        self.assertEqual(result["summary"]["reason"], "network_retry_limit")
        self.assertEqual(len(messages), 2)
        code, _, _, calls, sleeps = self.run_watch([watcher.WatchError("authentication_or_access_required")])
        self.assertEqual((code, calls, sleeps), (2, 1, []))
        code, result, _, calls, sleeps = self.run_watch([transient, fixture("completed", "success")])
        self.assertEqual((code, calls, sleeps), (0, 2, [60]))
        self.assertEqual(result["summary"]["network_failures"], 1)

    def test_gh_is_metadata_only_and_errors_are_redacted(self):
        with patch.object(watcher.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps(fixture()), "")) as run:
            watcher.read_run(42, watcher.REPOSITORY)
        command = run.call_args.args[0]
        self.assertEqual(command[:4], ["gh", "run", "view", "42"])
        self.assertNotIn("--log", command)
        self.assertNotIn("--log-failed", command)
        self.assertIn("--jq", command)
        for status, stderr, reason, retryable in [
            (4, "private credential text", "authentication_or_access_required", False),
            (1, "HTTP 403 secret", "authentication_or_access_required", False),
            (1, "HTTP 503 private server detail", "network_unavailable", True),
            (1, "unexpected private response", "gh_request_failed", False),
        ]:
            with self.subTest(reason=reason), patch.object(watcher.subprocess, "run", return_value=subprocess.CompletedProcess([], status, "", stderr)):
                with self.assertRaises(watcher.WatchError) as error:
                    watcher.read_run(42, watcher.REPOSITORY)
                self.assertEqual(str(error.exception), reason)
                self.assertEqual(error.exception.retryable, retryable)

    def test_sleep_is_chunked_and_missing_duration_is_not_claimed_complete(self):
        with patch.object(watcher.time, "sleep") as sleep:
            watcher.sleep_chunked(180)
        self.assertEqual([call.args[0] for call in sleep.call_args_list], [60, 60, 60])
        response = fixture("completed", "success")
        response["jobs"][0]["completedAt"] = None
        _, result, _, _, _ = self.run_watch([response])
        self.assertFalse(result["summary"]["runner_minutes_complete"])


if __name__ == "__main__":
    unittest.main()
