#!/usr/bin/env python3
"""Validate the deterministic output of the iOS Simulator smoke test."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


def integer_metadata(entry: dict[str, Any], key: str) -> int:
    value = entry.get("metadata", {}).get(key, "0")
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def jpeg_dimensions(path: Path) -> tuple[int, int] | None:
    """Read JPEG SOF dimensions without a third-party image dependency."""
    data = path.read_bytes()
    if not data.startswith(b"\xff\xd8"):
        return None

    start_of_frame_markers = {
        0xC0,
        0xC1,
        0xC2,
        0xC3,
        0xC5,
        0xC6,
        0xC7,
        0xC9,
        0xCA,
        0xCB,
        0xCD,
        0xCE,
        0xCF,
    }
    offset = 2
    while offset < len(data):
        if data[offset] != 0xFF:
            offset += 1
            continue
        while offset < len(data) and data[offset] == 0xFF:
            offset += 1
        if offset >= len(data):
            return None

        marker = data[offset]
        offset += 1
        if marker in {0x01, 0xD8, 0xD9} or 0xD0 <= marker <= 0xD7:
            continue
        if offset + 2 > len(data):
            return None
        segment_length = int.from_bytes(data[offset : offset + 2], "big")
        if segment_length < 2 or offset + segment_length > len(data):
            return None
        if marker in start_of_frame_markers:
            if segment_length < 7:
                return None
            height = int.from_bytes(data[offset + 3 : offset + 5], "big")
            width = int.from_bytes(data[offset + 5 : offset + 7], "big")
            return width, height
        offset += segment_length
    return None


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: validate-simulator-smoke.py "
            "<app-group-container> <fixture-count> <report-path>",
            file=sys.stderr,
        )
        return 2

    group_container = Path(sys.argv[1])
    fixture_count = int(sys.argv[2])
    report_path = Path(sys.argv[3])
    log_directory = group_container / "diagnostic-logs"
    failures: list[str] = []
    malformed_lines: list[str] = []
    incomplete_tail_lines: list[str] = []
    entries: list[dict[str, Any]] = []

    log_files = sorted(log_directory.glob("*.jsonl"))
    if not log_files:
        failures.append("No SharedLog JSONL files were found in the App Group.")

    for path in log_files:
        contents = path.read_text(encoding="utf-8-sig")
        lines = contents.splitlines()
        for line_number, raw_line in enumerate(lines, start=1):
            if not raw_line.strip():
                continue
            try:
                value = json.loads(raw_line)
            except json.JSONDecodeError as error:
                description = f"{path.name}:{line_number}: {error}"
                if line_number == len(lines) and not contents.endswith("\n"):
                    # The app remains alive while CI reads the shared stream.
                    # Match the in-app reader's tolerance for one interrupted
                    # final append, but continue to reject malformed complete
                    # lines and corruption in the middle of a file.
                    incomplete_tail_lines.append(description)
                else:
                    malformed_lines.append(description)
                continue
            if isinstance(value, dict):
                entries.append(value)
            else:
                malformed_lines.append(
                    f"{path.name}:{line_number}: entry is not a JSON object"
                )

    if malformed_lines:
        failures.append(
            f"SharedLog contains {len(malformed_lines)} malformed JSONL line(s)."
        )

    def matching(message: str, category: str | None = None) -> list[dict[str, Any]]:
        return [
            entry
            for entry in entries
            if entry.get("message") == message
            and (category is None or entry.get("category") == category)
        ]

    required_messages = [
        ("Application model initialized", "lifecycle"),
        ("Application startup began", "lifecycle"),
        ("Shared snapshot store initialized", "storage"),
        ("Snapshot loaded", "storage"),
        ("Photo library scan completed", "scan"),
        ("Final scan result applied", "scan"),
    ]
    for message, category in required_messages:
        if not matching(message, category):
            failures.append(f"Missing SharedLog event: {category}/{message}")

    permission_entries = matching("Photo authorization checked", "permission")
    if not any(
        entry.get("metadata", {}).get("status") == "authorized"
        for entry in permission_entries
    ):
        failures.append("Photo authorization was not pre-granted as authorized.")

    fetch_entries = matching("Photo library fetch completed", "scan")
    fetched_assets = max(
        (integer_metadata(entry, "assets") for entry in fetch_entries), default=0
    )
    if fetched_assets < fixture_count:
        failures.append(
            f"PhotoKit fetched {fetched_assets} asset(s); expected at least "
            f"{fixture_count}."
        )

    vision_entries = matching("Vision phase summary", "vision")
    newly_analyzed = sum(
        integer_metadata(entry, "newlyAnalyzed") for entry in vision_entries
    )
    detected_cats = sum(integer_metadata(entry, "cats") for entry in vision_entries)
    vision_failures = sum(
        integer_metadata(entry, "failed") for entry in vision_entries
    )
    deferred_assets = sum(
        integer_metadata(entry, "deferred") for entry in vision_entries
    )
    if newly_analyzed < fixture_count:
        failures.append(
            f"Vision analyzed {newly_analyzed} new asset(s); expected at least "
            f"{fixture_count}."
        )
    if detected_cats < 1:
        failures.append("Vision did not detect a cat in the synthetic fixtures.")
    if vision_failures:
        failures.append(f"Vision reported {vision_failures} failed asset(s).")
    if deferred_assets:
        failures.append(
            f"Vision deferred {deferred_assets} local simulator asset(s)."
        )
    if vision_entries and not all(
        entry.get("metadata", {}).get("thumbnailTargetPixels") == "1024x1024"
        for entry in vision_entries
    ):
        failures.append("Vision thumbnail target was not consistently 1024x1024.")

    error_entries = [entry for entry in entries if entry.get("level") == "error"]
    if error_entries:
        summaries = [
            f"{entry.get('category', 'unknown')}/{entry.get('message', 'unknown')}"
            for entry in error_entries[:10]
        ]
        failures.append("SharedLog error entries: " + ", ".join(summaries))

    snapshot_path = group_container / "library-snapshot.json"
    snapshot: dict[str, Any] = {}
    if not snapshot_path.is_file():
        failures.append("library-snapshot.json was not written to the App Group.")
    else:
        try:
            snapshot = json.loads(snapshot_path.read_text(encoding="utf-8-sig"))
        except (json.JSONDecodeError, OSError) as error:
            failures.append(f"library-snapshot.json is invalid: {error}")

    scan_state = snapshot.get("scanState", {}) if isinstance(snapshot, dict) else {}
    if scan_state.get("phase") != "completed":
        failures.append("Persisted scanState.phase is not completed.")
    if scan_state.get("resultKind") != "final":
        failures.append("Persisted scanState.resultKind is not final.")
    if int(scan_state.get("totalAssets", 0) or 0) < fixture_count:
        failures.append("Persisted scan total does not include every fixture.")
    if int(scan_state.get("catAssets", 0) or 0) < 1:
        failures.append("Persisted scan state contains no detected cat assets.")

    if not matching("Album synchronization finished", "album"):
        failures.append("The generated PhotoKit album was not synchronized.")
    if not matching("Widget cache build completed", "widget-cache"):
        failures.append("The widget image cache was not built.")
    if not matching("Widget timeline reload requested", "widget-cache"):
        failures.append("The widget timeline reload was not requested.")

    manifest_path = group_container / "widget-manifest.json"
    manifest: dict[str, Any] = {}
    manifest_items: list[dict[str, Any]] = []
    if not manifest_path.is_file():
        failures.append("widget-manifest.json was not written to the App Group.")
    else:
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
            raw_items = manifest.get("items", [])
            if isinstance(raw_items, list):
                manifest_items = [item for item in raw_items if isinstance(item, dict)]
        except (json.JSONDecodeError, OSError) as error:
            failures.append(f"widget-manifest.json is invalid: {error}")

    if not 15 <= len(manifest_items) <= 20:
        failures.append(
            f"Widget manifest contains {len(manifest_items)} entries; expected 15–20."
        )

    cache_directory = group_container / "widget-cache"
    referenced_cache_files: set[Path] = set()
    for item in manifest_items:
        filename = item.get("cacheFilename")
        if not isinstance(filename, str) or Path(filename).name != filename:
            failures.append("Widget manifest contains an unsafe cache filename.")
            continue
        referenced_cache_files.add(cache_directory / filename)
    missing_cache_files = [
        path.name for path in sorted(referenced_cache_files) if not path.is_file()
    ]
    if missing_cache_files:
        failures.append(
            "Widget manifest references missing cache files: "
            + ", ".join(missing_cache_files)
        )

    cache_byte_counts = [
        path.stat().st_size for path in referenced_cache_files if path.is_file()
    ]
    oversized_cache_files = [
        path.name
        for path in referenced_cache_files
        if path.is_file() and path.stat().st_size > 50 * 1_024
    ]
    if oversized_cache_files:
        failures.append(
            "Widget cache files exceed 50 KiB: "
            + ", ".join(sorted(oversized_cache_files))
        )
    cache_dimensions = {
        path.name: jpeg_dimensions(path)
        for path in sorted(referenced_cache_files)
        if path.is_file()
    }
    invalid_cache_dimensions = [
        filename
        for filename, dimensions in cache_dimensions.items()
        if dimensions != (400, 400)
    ]
    if invalid_cache_dimensions:
        failures.append(
            "Widget cache files are not valid 400x400 JPEGs: "
            + ", ".join(invalid_cache_dimensions)
        )
    widget_log_files = [path.name for path in log_files if path.name.startswith("widget-")]
    report = {
        "status": "pass" if not failures else "fail",
        "fixtureCount": fixture_count,
        "logFiles": [path.name for path in log_files],
        "widgetLogFiles": widget_log_files,
        "entryCount": len(entries),
        "malformedLines": malformed_lines,
        "incompleteTailLines": incomplete_tail_lines,
        "errorEntryCount": len(error_entries),
        "photoKitFetchedAssets": fetched_assets,
        "visionNewlyAnalyzed": newly_analyzed,
        "visionDetectedCats": detected_cats,
        "visionFailures": vision_failures,
        "visionDeferredAssets": deferred_assets,
        "snapshotTotalAssets": int(scan_state.get("totalAssets", 0) or 0),
        "snapshotCatAssets": int(scan_state.get("catAssets", 0) or 0),
        "manifestEntryCount": len(manifest_items),
        "uniqueCacheFileCount": len(referenced_cache_files),
        "cacheBytesMinimum": min(cache_byte_counts, default=0),
        "cacheBytesMaximum": max(cache_byte_counts, default=0),
        "cacheDimensions": cache_dimensions,
        "oversizedCacheFiles": oversized_cache_files,
        "failures": failures,
        "notes": [
            "Widget JSONL is optional because adding a widget to the simulated "
            "Home Screen is outside this headless smoke test."
        ],
    }
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))

    if failures:
        print("Simulator smoke validation failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
