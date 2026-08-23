#!/usr/bin/env python3
"""Fail-closed validator for the clean-Simulator Photos permission bootstrap."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any


PHOTOS_SERVICE = "kTCCServicePhotos"
REQUEST_STARTED = "Photo authorization request started"
REQUEST_FINISHED = "Photo authorization request finished"
INT64_MIN = -(2**63)
INT64_MAX = 2**63 - 1
INT32_MIN = -(2**31)
INT32_MAX = 2**31 - 1


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"Unreadable JSON: {path.name}: {type(error).__name__}") from error


def _bounded_integer(value: str, minimum: int, maximum: int) -> bool:
    try:
        number = int(value)
    except ValueError:
        return False
    return minimum <= number <= maximum


def _recognized_app_log(path: Path) -> bool:
    name = path.name
    if not name.endswith(".jsonl"):
        return False
    stem = name[: -len(".jsonl")]
    base, separator, rotation = stem.rpartition(".")
    if separator and _bounded_integer(rotation, INT64_MIN, INT64_MAX):
        stem = base
    pieces = stem.split("-")
    return (
        len(pieces) == 4
        and pieces[0] == "app"
        and _bounded_integer(pieces[1], INT64_MIN, INT64_MAX)
        and _bounded_integer(pieces[2], INT32_MIN, INT32_MAX)
        and len(pieces[3]) == 12
    )


def _read_log_entries(log_directory: Path) -> list[dict[str, Any]]:
    if not log_directory.is_dir():
        raise ValueError("The diagnostic log directory is missing.")

    entries: list[dict[str, Any]] = []
    paths = sorted(path for path in log_directory.glob("*.jsonl") if _recognized_app_log(path))
    if not paths:
        raise ValueError("No recognized app diagnostic JSONL files were found.")
    for path in paths:
        try:
            contents = path.read_text(encoding="utf-8-sig")
        except (OSError, UnicodeError) as error:
            raise ValueError(f"Unreadable diagnostic log: {path.name}") from error
        lines = contents.splitlines()
        for line_number, line in enumerate(lines, start=1):
            if not line.strip():
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError as error:
                if line_number == len(lines) and not contents.endswith("\n"):
                    # SharedLog readers tolerate one append interrupted by
                    # immediate process termination, but never a complete or
                    # middle-file malformed record.
                    continue
                raise ValueError(
                    f"Malformed diagnostic JSONL: {path.name}:{line_number}"
                ) from error
            if not isinstance(entry, dict):
                raise ValueError(
                    f"Diagnostic entry is not an object: {path.name}:{line_number}"
                )
            entries.append(entry)
    return entries


def validate_permission_bootstrap(
    tcc_report_path: Path,
    log_directory: Path,
    bundle_identifier: str,
) -> dict[str, Any]:
    report = _read_json(tcc_report_path)
    if not isinstance(report, dict) or report.get("error") is not None:
        raise ValueError("The TCC report is missing or contains a capture error.")
    if report.get("bundleIdentifier") != bundle_identifier:
        raise ValueError("The TCC report belongs to another bundle identifier.")

    rows = report.get("rows")
    if not isinstance(rows, list):
        raise ValueError("The TCC report has no row list.")
    photo_rows = [
        row
        for row in rows
        if isinstance(row, dict)
        and row.get("client") == bundle_identifier
        and row.get("service") == PHOTOS_SERVICE
    ]
    if len(photo_rows) != 1:
        raise ValueError("Expected exactly one read/write Photos TCC row.")
    auth_value = photo_rows[0].get("auth_value")
    if isinstance(auth_value, bool) or auth_value != 2:
        raise ValueError("Photos access was not granted as full read/write access.")

    entries = _read_log_entries(log_directory)
    permission_entries = [
        entry
        for entry in entries
        if entry.get("process") == "app" and entry.get("category") == "permission"
    ]
    starts = [entry for entry in permission_entries if entry.get("message") == REQUEST_STARTED]
    finishes = [entry for entry in permission_entries if entry.get("message") == REQUEST_FINISHED]
    if len(starts) != 1:
        raise ValueError("Expected exactly one Photos authorization request start event.")
    if len(finishes) != 1:
        raise ValueError("Expected exactly one Photos authorization request finish event.")
    metadata = finishes[0].get("metadata")
    if not isinstance(metadata, dict) or metadata.get("status") != "authorized":
        raise ValueError("The Photos authorization request did not finish as authorized.")

    started_at = starts[0].get("timestamp")
    finished_at = finishes[0].get("timestamp")
    if (
        isinstance(started_at, bool)
        or isinstance(finished_at, bool)
        or not isinstance(started_at, (int, float))
        or not isinstance(finished_at, (int, float))
        or not math.isfinite(started_at)
        or not math.isfinite(finished_at)
        or finished_at < started_at
    ):
        raise ValueError("The Photos authorization event order is invalid.")

    return {
        "bundleIdentifier": bundle_identifier,
        "photosAuthValue": auth_value,
        "requestFinishedStatus": "authorized",
        "requestStartCount": len(starts),
        "requestFinishCount": len(finishes),
    }


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tcc-report", type=Path, required=True)
    parser.add_argument("--log-directory", type=Path, required=True)
    parser.add_argument("--bundle-identifier", required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        summary = validate_permission_bootstrap(
            arguments.tcc_report,
            arguments.log_directory,
            arguments.bundle_identifier,
        )
    except ValueError as error:
        print(f"FAIL Photos permission bootstrap: {error}")
        return 1
    print("PASS Photos permission bootstrap: " + json.dumps(summary, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
