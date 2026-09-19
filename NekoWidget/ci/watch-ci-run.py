#!/usr/bin/env python3
"""Watch one GitHub run quietly using the existing gh login (read-only).

Print start, newly completed jobs, and a final JSON summary. Step changes and
unchanged polls stay silent. The local result contains only selected metadata,
never logs, steps, credentials, or raw gh errors. Exit: 0 success, 1 unsuccessful
run, 2 unverified/error, 3 approval/action required, 130 interrupted.

runner_minutes is the sum of reported job execution durations, not billed
minutes or an OS-weighted estimate. Missing timestamps make it incomplete.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time


REPOSITORY = "soso-so-27/neko-widget"
STATES = {"queued", "requested", "pending", "waiting", "in_progress", "completed", "action_required"}
CONCLUSIONS = {"success", "failure", "neutral", "cancelled", "skipped", "timed_out", "action_required", "stale", "startup_failure"}
FIELDS = "databaseId,headSha,attempt,status,conclusion,createdAt,startedAt,updatedAt,jobs"
SELECT_METADATA = "{databaseId,headSha,attempt,status,conclusion,createdAt,startedAt,updatedAt,jobs:[.jobs[]|{databaseId,name,status,conclusion,startedAt,completedAt}]}"


class WatchError(Exception):
    def __init__(self, reason: str, *, retryable: bool = False):
        super().__init__(reason)
        self.reason = reason
        self.retryable = retryable


def read_run(run_id: int, repository: str) -> dict:
    env = {**os.environ, "GH_PROMPT_DISABLED": "1", "NO_COLOR": "1", "GH_DEBUG": ""}
    try:
        result = subprocess.run(
            ["gh", "run", "view", str(run_id), "--repo", f"github.com/{repository}",
             "--json", FIELDS, "--jq", SELECT_METADATA],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            timeout=45, check=False, env=env,
        )
    except subprocess.TimeoutExpired as error:
        raise WatchError("network_timeout", retryable=True) from error
    except OSError as error:
        raise WatchError("gh_unavailable") from error
    if result.returncode:
        # Inspect only for classification; never print or persist stderr.
        message = result.stderr.lower()
        if result.returncode == 4 or re.search(r"http (401|403)\b", message) or any(
            marker in message for marker in ("gh auth login", "not logged", "authentication", "bad credentials")
        ):
            raise WatchError("authentication_or_access_required")
        if re.search(r"http (429|5\d\d)\b", message) or any(
            marker in message for marker in (
                "error connecting to", "failed to connect", "connection reset", "connection refused",
                "connection timed out", "i/o timeout", "tls handshake timeout", "no such host",
                "temporary failure in name resolution", "unexpected eof",
            )
        ):
            raise WatchError("network_unavailable", retryable=True)
        raise WatchError("gh_request_failed")
    if len(result.stdout.encode("utf-8")) > 1024 * 1024:
        raise WatchError("metadata_too_large")
    try:
        value = json.loads(result.stdout)
    except (ValueError, TypeError) as error:
        raise WatchError("invalid_metadata") from error
    if not isinstance(value, dict):
        raise WatchError("invalid_metadata")
    return value


def timestamp(value):
    if value in (None, "", "0001-01-01T00:00:00Z"):
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError("Timezone missing")
        return parsed
    except (AttributeError, TypeError, ValueError) as error:
        raise WatchError("invalid_timestamp") from error


def normalize(raw: dict, run_id: int, expected_sha: str | None, identity=None) -> dict:
    if type(raw.get("databaseId")) is not int or raw["databaseId"] != run_id:
        raise WatchError("run_id_mismatch")
    sha = raw.get("headSha")
    if not isinstance(sha, str) or re.fullmatch(r"[0-9a-f]{40}", sha) is None:
        raise WatchError("invalid_head_sha")
    if expected_sha and sha != expected_sha:
        raise WatchError("sha_mismatch")
    attempt = raw.get("attempt")
    if type(attempt) is not int or attempt < 1:
        raise WatchError("invalid_attempt")
    if identity is not None and (sha, attempt) != identity:
        raise WatchError("run_identity_changed")

    def state(item):
        status, conclusion = item.get("status"), item.get("conclusion")
        if not isinstance(status, str) or status not in STATES:
            raise WatchError("unknown_state")
        if conclusion is not None and (not isinstance(conclusion, str) or conclusion not in CONCLUSIONS | {""}):
            raise WatchError("unknown_state")
        conclusion = conclusion or None
        if status == "completed" and conclusion is None:
            raise WatchError("missing_conclusion")
        if status != "completed" and conclusion is not None:
            raise WatchError("inconsistent_state")
        return status, conclusion

    status, conclusion = state(raw)
    for key in ("createdAt", "startedAt", "updatedAt"):
        timestamp(raw.get(key))
    if timestamp(raw.get("createdAt")) is None:
        raise WatchError("missing_creation_time")
    jobs = raw.get("jobs")
    if not isinstance(jobs, list):
        raise WatchError("invalid_jobs")
    selected, ids = [], set()
    for job in jobs:
        if not isinstance(job, dict):
            raise WatchError("invalid_job")
        job_id = job.get("databaseId")
        if type(job_id) is not int or job_id <= 0 or job_id in ids:
            raise WatchError("invalid_job_id")
        ids.add(job_id)
        job_status, job_conclusion = state(job)
        if not isinstance(job.get("name"), str):
            raise WatchError("invalid_job_name")
        for key in ("startedAt", "completedAt"):
            timestamp(job.get(key))
        selected.append({
            "id": job_id, "name": "".join(c if c.isprintable() else " " for c in job["name"])[:120],
            "status": job_status, "conclusion": job_conclusion,
            "started_at": job.get("startedAt"), "completed_at": job.get("completedAt"),
        })
    return {
        "run_id": run_id, "head_sha": sha, "attempt": attempt, "status": status,
        "conclusion": conclusion, "created_at": raw.get("createdAt"),
        "started_at": raw.get("startedAt"), "updated_at": raw.get("updatedAt"),
        "jobs": sorted(selected, key=lambda job: job["id"]),
    }


def fingerprint(run):
    return (run["status"], run["conclusion"], tuple(
        (job["id"], job["status"], job["conclusion"]) for job in run["jobs"]
    ))


def duration_metrics(run, observed_at):
    if run is None:
        return {"total_seconds": None, "runner_minutes": None, "runner_minutes_complete": False}
    completed = run["status"] == "completed"
    end = timestamp(run["updated_at"]) if completed else observed_at
    total = max(0, (end - timestamp(run["created_at"])).total_seconds()) if end else None
    seconds, complete = 0.0, completed
    for job in run["jobs"]:
        start, finish = timestamp(job["started_at"]), timestamp(job["completed_at"])
        if job["conclusion"] == "skipped":
            continue
        if job["status"] in {"queued", "requested", "pending", "waiting", "action_required"}:
            complete = False
            continue
        if start is None:
            complete = False
            continue
        if finish is None:
            if job["status"] == "completed":
                complete = False
                continue
            finish = observed_at
        elapsed = (finish - start).total_seconds()
        if elapsed < 0:
            complete = False
            continue
        seconds += elapsed
    return {"total_seconds": round(total, 1) if total is not None else None,
            "runner_minutes": round(seconds / 60, 3), "runner_minutes_complete": complete}


def sleep_chunked(seconds):
    while seconds > 0:
        chunk = min(60, seconds)
        time.sleep(chunk)
        seconds -= chunk


def write_result(path: Path, value: dict):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def emit(value):
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")), flush=True)


def watch(args) -> int:
    started = time.monotonic()
    latest, identity = None, None
    events, failures = [], 0
    delay = args.poll_seconds
    output = args.output.resolve()
    emit({"event": "start", "run_id": args.run_id, "result_file": str(output)})

    def record(outcome, exit_code=None, reason=None):
        now = dt.datetime.now(dt.timezone.utc)
        summary = {
            "event": "final" if exit_code is not None else "snapshot", "run_id": args.run_id,
            "outcome": outcome, "status": latest["status"] if latest else None,
            "conclusion": latest["conclusion"] if latest else None,
            "watch_seconds": round(time.monotonic() - started, 1),
            **duration_metrics(latest, now), "network_failures": failures,
            "result_file": str(output),
        }
        if exit_code is not None:
            summary["exit_code"] = exit_code
        if reason:
            summary["reason"] = reason
        document = {
            "schema_version": 1, "repository": args.repo, "observed_at": now.isoformat(),
            "runner_minutes_definition": "Sum of reported job execution durations; not billed or OS-weighted minutes.",
            "summary": summary, "run": latest, "events": events,
        }
        try:
            write_result(output, document)
        except OSError:
            summary.update(event="final", outcome="stopped", reason="result_write_failed", exit_code=2)
            emit(summary)
            return 2
        if exit_code is not None:
            emit(summary)
        return exit_code

    try:
        while True:
            try:
                raw = read_run(args.run_id, args.repo)
            except WatchError as error:
                if not error.retryable:
                    raise
                failures += 1
                if failures >= args.max_network_failures:
                    raise WatchError("network_retry_limit") from error
                sleep_chunked(min(args.max_poll_seconds, args.poll_seconds * 2 ** (failures - 1)))
                continue
            current = normalize(raw, args.run_id, args.expected_sha, identity)
            if identity is None:
                identity = (current["head_sha"], current["attempt"])
            prior_jobs = {job["id"]: job for job in latest["jobs"]} if latest else {}
            changed_jobs = [job for job in current["jobs"] if job["status"] == "completed"
                            and (job["id"] not in prior_jobs or
                            prior_jobs[job["id"]]["conclusion"] != job["conclusion"])]
            changed = latest is None or fingerprint(current) != fingerprint(latest)
            latest = current
            if changed_jobs:
                event = {"event": "jobs_completed", "jobs": [
                    {key: job[key] for key in ("id", "name", "conclusion")} for job in changed_jobs
                ]}
                events.append(event)
                emit({**event, "jobs": event["jobs"][:6], "count": len(changed_jobs)})
            attention = current["status"] in {"waiting", "action_required"} or current["conclusion"] == "action_required" or any(
                job["status"] in {"waiting", "action_required"} or job["conclusion"] == "action_required"
                for job in current["jobs"]
            )
            if attention:
                return record("attention_required", 3, "approval_or_action_required")
            if current["status"] == "completed":
                return record("completed", 0 if current["conclusion"] == "success" else 1)
            result = record("watching")
            if result is not None:
                return result
            delay = args.poll_seconds if changed else min(args.max_poll_seconds, delay * 1.5)
            sleep_chunked(delay)
    except WatchError as error:
        return record("stopped", 2, error.reason)
    except KeyboardInterrupt:
        return record("interrupted", 130)


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("run_id", type=int)
    parser.add_argument("--expected-sha", help="Require this full 40-character commit on every poll")
    parser.add_argument("--repo", default=REPOSITORY, help="GitHub OWNER/REPO (default: %(default)s)")
    parser.add_argument("--output", type=Path, help="Local JSON result; default: OS temp/neko-ci-watch/<repo>-<run>.json")
    parser.add_argument("--poll-seconds", type=float, default=60)
    parser.add_argument("--max-poll-seconds", type=float, default=180)
    parser.add_argument("--max-network-failures", type=int, default=3, help="Total failed requests allowed before stopping")
    args = parser.parse_args(argv)
    if args.run_id <= 0:
        parser.error("run_id must be positive")
    if args.expected_sha and re.fullmatch(r"[0-9a-f]{40}", args.expected_sha) is None:
        parser.error("--expected-sha must be a full lowercase 40-character commit")
    if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo) is None:
        parser.error("--repo must be OWNER/REPO on github.com")
    if not 1 <= args.poll_seconds <= args.max_poll_seconds <= 3600:
        parser.error("poll intervals must satisfy 1 <= poll <= max-poll <= 3600")
    if not 1 <= args.max_network_failures <= 10:
        parser.error("--max-network-failures must be between 1 and 10")
    if args.output is None:
        args.output = Path(tempfile.gettempdir()) / "neko-ci-watch" / f"{args.repo.replace('/', '-')}-{args.run_id}.json"
    return args


if __name__ == "__main__":
    sys.exit(watch(parse_arguments()))
