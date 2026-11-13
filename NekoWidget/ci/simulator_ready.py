#!/usr/bin/env python3
"""Require two promptly answered no-op requests from a synthetic Simulator."""
import subprocess
import sys
import time


def wait_ready(device, run=subprocess.run, clock=time.monotonic, sleep=time.sleep):
    deadline = clock() + 55
    consecutive = 0
    while clock() < deadline:
        start = clock()
        try:
            result = run(["xcrun", "simctl", "spawn", device, "/usr/bin/true"],
                         timeout=min(5, max(0.1, deadline - start)),
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            elapsed = clock() - start
            fast = result.returncode == 0 and elapsed <= 3
            print(f"Simulator no-op: exit={result.returncode}, {elapsed:.1f}s, fast={fast}", flush=True)
        except subprocess.TimeoutExpired:
            fast = False
            print(f"Simulator no-op: timeout, {clock() - start:.1f}s", flush=True)
        consecutive = consecutive + 1 if fast else 0
        if consecutive == 2:
            return 0
        sleep(1)
    print("Simulator no-op did not settle; install was not attempted.", file=sys.stderr)
    return 124


if __name__ == "__main__":
    sys.exit(wait_ready(sys.argv[1]))
