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


class Interrupted(Exception):
    def __init__(self, signum):
        self.signum = signum


def interrupt(signum, _frame):
    raise Interrupted(signum)


def stop(process):
    if process.poll() is not None:
        return
    if os.name == "posix":
        os.killpg(process.pid, signal.SIGTERM)
    else:
        process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        if os.name == "posix":
            os.killpg(process.pid, signal.SIGKILL)
        else:
            process.kill()
        process.wait()


def run(command, record, timeout=None):
    started = dt.datetime.now(dt.timezone.utc).isoformat()
    clock = time.monotonic()
    timed_out = False
    status, interrupted, process = None, None, None
    path = Path(record)
    path.parent.mkdir(parents=True, exist_ok=True)
    metadata = {"schemaVersion": 1, "startedAt": started,
                "sourceSHA": os.environ.get("GITHUB_SHA"),
                "runID": os.environ.get("GITHUB_RUN_ID"),
                "runAttempt": os.environ.get("GITHUB_RUN_ATTEMPT")}
    # A hard runner kill cannot execute finally. Keep an explicitly incomplete
    # start record in that case, never a fabricated successful completion.
    path.write_text(json.dumps(dict(metadata, state="running", exitCode=None)) + "\n", encoding="utf-8")
    handlers = {sig: signal.signal(sig, interrupt) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        process = subprocess.Popen(command, start_new_session=os.name == "posix")
        status = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        status = 124
    except Interrupted as error:
        interrupted = error.signum
        status = 128 + interrupted
    except OSError:
        status = 127
    finally:
        # Ignore repeat shutdown signals only during bounded child cleanup.
        for sig in handlers:
            signal.signal(sig, signal.SIG_IGN)
        try:
            if process is not None and (timed_out or interrupted is not None):
                stop(process)
        finally:
            if status is not None and status < 0:
                status = 128 - status
            path.write_text(json.dumps(dict(metadata,
                state="completed" if status is not None else "incomplete",
                completedAt=dt.datetime.now(dt.timezone.utc).isoformat(),
                elapsedSeconds=round(time.monotonic() - clock, 3),
                exitCode=status, timedOut=timed_out, interruptedSignal=interrupted,
            ), indent=2) + "\n", encoding="utf-8")
            for sig, handler in handlers.items():
                signal.signal(sig, handler)
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
