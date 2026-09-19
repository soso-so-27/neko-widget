#!/usr/bin/env python3
"""Fast local/CI entry point: reject orchestration mistakes before Mac jobs."""

from pathlib import Path
import subprocess
import sys
import time

CI = Path(__file__).resolve().parent
CHECKS = (
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
)


def main() -> int:
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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
