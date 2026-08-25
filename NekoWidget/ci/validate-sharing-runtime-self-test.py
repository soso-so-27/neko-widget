#!/usr/bin/env python3
"""Validate the privacy-safe DEBUG sharing runtime self-test marker."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


MAXIMUM_REPORT_BYTES = 32 * 1024
REQUIRED_CASES = {
    "canonical-local-only-privacy-budget",
    "daily-store-cas-highwater-anchor",
    "day-boundary-convergence",
    "diagnostic-persistence-privacy",
    "disabled-upgrade-purge",
    "lease-heartbeat",
    "legacy-widget-cache-migration",
    "moment-report-only-terminal-gate",
    "moment-saved-memory-boundary",
    "moment-sent-delivery-receipt-boundary",
    "moment-paw-reaction-boundary",
    "moment-empty-cursor-normalization",
    "moment-expired-delivery-advances",
    "moment-install-bound-handoff",
    "moment-inbound-moderation-retry-policy",
    "moment-inbound-moderation-flow",
    "moment-commit-ack-metadata",
    "moment-outbox-bounds-and-expiry",
    "moment-outcome-ledger-migration",
    "moment-process-serialized-refresh",
    "moment-report-outbox-bounds-and-recovery",
    "moment-terminal-authorization-classification",
    "normalizer-orientation-scale-parity",
    "own-source-local-promotion",
    "partial-download-resume-tamper",
    "pairing-bootstrap-transient-preservation",
    "peer-revoke-terminal-purge",
    "retry-independent-deadline",
    "secure-file-attributes",
}


def fail(message: str) -> None:
    raise ValueError(message)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    parser.add_argument("--renderer-version", required=True)
    parser.add_argument(
        "--safe-copy",
        type=Path,
        help="Write a normalized privacy-safe copy after schema validation.",
    )
    args = parser.parse_args()

    try:
        raw = args.report.read_bytes()
        if not raw or len(raw) > MAXIMUM_REPORT_BYTES:
            fail("runtime self-test report size is invalid")
        value = json.loads(raw)
        if not isinstance(value, dict) or set(value) != {
            "schemaVersion",
            "rendererVersion",
            "status",
            "cases",
        }:
            fail("runtime self-test report has an unexpected top-level schema")
        if value["schemaVersion"] != 1:
            fail("runtime self-test schema version is unsupported")
        if value["rendererVersion"] != args.renderer_version:
            fail("runtime self-test used a different production renderer version")
        if value["status"] not in {"passed", "failed"}:
            fail("runtime self-test has an invalid overall status")
        cases = value["cases"]
        if not isinstance(cases, list):
            fail("runtime self-test cases are not an array")
        by_id: dict[str, str] = {}
        for item in cases:
            # Keep the artifact deliberately free of paths, PhotoKit local IDs,
            # image bytes, invite codes, keys, and arbitrary diagnostic text.
            if not isinstance(item, dict) or set(item) != {"id", "status"}:
                fail("runtime self-test case has an unexpected schema")
            identifier = item["id"]
            status = item["status"]
            if not isinstance(identifier, str) or identifier not in REQUIRED_CASES:
                fail("runtime self-test contains an unknown case")
            if identifier in by_id:
                fail(f"runtime self-test case is duplicated: {identifier}")
            if status not in {"passed", "failed"}:
                fail(f"runtime self-test case has an invalid status: {identifier}")
            by_id[identifier] = status
        missing = REQUIRED_CASES - by_id.keys()
        if missing:
            fail(f"runtime self-test is missing cases: {', '.join(sorted(missing))}")
        failed = sorted(identifier for identifier, status in by_id.items() if status != "passed")
        if args.safe_copy is not None:
            # Re-encode only the already-whitelisted schema. A failing case is
            # useful CI evidence, but arbitrary app diagnostics must never be
            # copied into an uploaded artifact.
            normalized = json.dumps(
                value,
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            ) + "\n"
            args.safe_copy.write_text(normalized, encoding="utf-8")
        if value["status"] != "passed":
            fail("runtime self-test did not pass")
        if failed:
            fail(f"runtime self-test cases failed: {', '.join(failed)}")
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        print(f"sharing runtime self-test: FAIL: {error}", file=sys.stderr)
        return 1

    print(f"sharing runtime self-test: PASS ({len(REQUIRED_CASES)} cases)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
