#!/usr/bin/env python3
"""Fast local/CI entry point: reject orchestration mistakes before Mac jobs."""

import argparse
import os
from pathlib import Path
import subprocess
import sys
import time

CI = Path(__file__).resolve().parent
CHECKS = (
    "test-release-flow.py",
    "test-plan-ios-ci.py",
    "test-ci-lanes.py",
    "test-widget-ci-scope.py",
    "test-ci-smoke-scope.py",
    "test-runtime-preparation.py",
    "test-app-store-screenshot-workflow.py",
    "test-release-testflight.py",
    "test-testflight-release-evidence-workflow.py",
    "test-app-icon-ci.py",
    "test-watch-ci-run.py",
    "test-preflight-ci.py",
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checks-only", action="store_true", help="Local unit checks; does not approve a candidate push")
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--decision", help="Planning note only; does not override preflight gates")
    parser.add_argument("--include-upload", action="store_true")
    parser.add_argument("--output", help="Preflight JSON outside the checkout")
    args = parser.parse_args()
    start = time.monotonic()
    for name in CHECKS:
        check_start = time.monotonic()
        result = subprocess.run([sys.executable, str(CI / name)], cwd=CI.parents[1],
                                capture_output=True, text=True, encoding="utf-8", errors="replace")
        if result.returncode:
            sys.stdout.write(result.stdout)
            sys.stderr.write(result.stderr)
            print(f"STOP: {name} failed. Do not start the candidate CI.", flush=True)
            return result.returncode
        print(f"PASS: {name} ({time.monotonic() - check_start:.1f}s)", flush=True)
    print(f"Development-flow checks passed in {time.monotonic() - start:.1f}s.", flush=True)
    if not args.checks_only and os.environ.get("GITHUB_ACTIONS") != "true":
        command = [sys.executable, str(CI / "preflight-ci.py"), "--base", args.base]
        if args.decision:
            command += ["--decision", args.decision]
        if args.include_upload:
            command.append("--include-upload")
        if args.output:
            command += ["--output", args.output]
        return subprocess.run(command, cwd=CI.parents[1]).returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
