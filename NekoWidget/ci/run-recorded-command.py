#!/usr/bin/env python3
"""Record actual stage durations; bound evidence export without accepting timeouts."""

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def run(command, record, timeout=None):
    started = dt.datetime.now(dt.timezone.utc).isoformat()
    clock = time.monotonic()
    timed_out = False
    process = subprocess.Popen(command, start_new_session=os.name == "posix")
    try:
        status = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        if os.name == "posix":
            os.killpg(process.pid, signal.SIGKILL)
        else:
            process.kill()
        process.wait()
        status = 124
    status = status if status >= 0 else 128 - status
    Path(record).write_text(json.dumps({
        "schemaVersion": 1,
        "startedAt": started,
        "completedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "elapsedSeconds": round(time.monotonic() - clock, 3),
        "exitCode": status,
        "timedOut": timed_out,
        "sourceSHA": os.environ.get("GITHUB_SHA"),
        "runID": os.environ.get("GITHUB_RUN_ID"),
        "runAttempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
    }, indent=2) + "\n", encoding="utf-8")
    return status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record", required=True)
    parser.add_argument("--timeout", type=float)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.timeout is not None and args.timeout <= 0:
        parser.error("timeout must be positive")
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("command required")
    return run(command, args.record, args.timeout)


if __name__ == "__main__":
    raise SystemExit(main())
