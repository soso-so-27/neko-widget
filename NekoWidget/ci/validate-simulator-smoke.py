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


def entry_timestamp(entry: dict[str, Any]) -> float | None:
    try:
        return float(entry.get("timestamp"))
    except (TypeError, ValueError):
        return None


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
    if len(sys.argv) != 5:
        print(
            "usage: validate-simulator-smoke.py "
            "<app-group-container> <fixture-count> "
            "<baseline-snapshot> <report-path>",
            file=sys.stderr,
        )
        return 2

    group_container = Path(sys.argv[1])
    fixture_count = int(sys.argv[2])
    baseline_snapshot_path = Path(sys.argv[3])
    report_path = Path(sys.argv[4])
    log_directory = group_container / "diagnostic-logs"
    failures: list[str] = []
    malformed_lines: list[str] = []
    incomplete_tail_lines: list[str] = []
    entries: list[dict[str, Any]] = []

    log_files = sorted(log_directory.glob("*.jsonl"))
    if not log_files:
        failures.append("No SharedLog JSONL files were found in the App Group.")

    for path in log_files:
        stem = path.name[: -len(".jsonl")]
        base, separator, rotation = stem.rpartition(".")
        log_session = base if separator and rotation.isdigit() else stem
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
                value["_logSession"] = log_session
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
    if vision_entries and not all(
        entry.get("metadata", {}).get("thumbnailTargetPixels") == "1024x1024"
        for entry in vision_entries
    ):
        failures.append("Vision thumbnail target was not consistently 1024x1024.")

    thumbnail_load_entries = matching(
        "Photo thumbnail loaded (sampled)", "image-load"
    )
    if len(thumbnail_load_entries) < fixture_count:
        failures.append(
            f"Only {len(thumbnail_load_entries)} sampled thumbnail load(s) "
            f"were recorded; expected at least {fixture_count}."
        )
    if any(
        entry.get("metadata", {}).get("targetPixels") != "1024x1024"
        or "x" not in entry.get("metadata", {}).get("outputPixels", "")
        for entry in thumbnail_load_entries
    ):
        failures.append("Thumbnail load diagnostics contain invalid pixel metadata.")

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

    # A fresh Simulator runtime includes old sample-library records whose image
    # resources are not actually present. Compare the live snapshot with the
    # permission bootstrap snapshot so only assets added by `simctl addmedia`
    # are treated as fixtures. Unrelated seed records may remain deferred or
    # failed while network access is deliberately disabled.
    baseline_snapshot: dict[str, Any] = {}
    if not baseline_snapshot_path.is_file():
        failures.append("The permission bootstrap baseline snapshot is missing.")
    else:
        try:
            baseline_snapshot = json.loads(
                baseline_snapshot_path.read_text(encoding="utf-8-sig")
            )
        except (json.JSONDecodeError, OSError) as error:
            failures.append(f"Baseline snapshot is invalid: {error}")

    baseline_raw_assets = (
        baseline_snapshot.get("assets", [])
        if isinstance(baseline_snapshot, dict)
        else []
    )
    baseline_identifiers = {
        asset.get("localIdentifier")
        for asset in baseline_raw_assets
        if isinstance(asset, dict) and isinstance(asset.get("localIdentifier"), str)
    }
    raw_assets = snapshot.get("assets", []) if isinstance(snapshot, dict) else []
    snapshot_assets = [asset for asset in raw_assets if isinstance(asset, dict)]
    fixture_assets = [
        asset
        for asset in snapshot_assets
        if asset.get("localIdentifier") not in baseline_identifiers
    ]
    fixture_asset_statuses = [
        str(asset.get("analysisStatus", "missing")) for asset in fixture_assets
    ]
    if len(fixture_assets) < fixture_count:
        failures.append(
            f"Snapshot contains only {len(fixture_assets)} imported fixture "
            f"record(s); expected {fixture_count}."
        )
    nonclassified_fixture_statuses = [
        status
        for status in fixture_asset_statuses
        if status not in {"detected", "noCat"}
    ]
    if nonclassified_fixture_statuses:
        failures.append(
            "Imported synthetic fixture records were not classified by Vision: "
            + ", ".join(nonclassified_fixture_statuses)
        )
    if fixture_assets and not any(
        asset.get("analysisStatus") == "detected" for asset in fixture_assets
    ):
        failures.append("Vision did not detect a cat among the imported fixture records.")

    if not matching("Album synchronization finished", "album"):
        failures.append("The generated PhotoKit album was not synchronized.")
    final_entries = [
        entry
        for entry in matching("Final scan result applied", "scan")
        if entry.get("process") == "app" and entry_timestamp(entry) is not None
    ]
    cache_entries = [
        entry
        for entry in matching("Widget cache build completed", "widget-cache")
        if entry.get("process") == "app" and entry_timestamp(entry) is not None
    ]
    reload_entries = [
        entry
        for entry in matching("Widget timeline reload requested", "widget-cache")
        if entry.get("process") == "app" and entry_timestamp(entry) is not None
    ]
    if not cache_entries:
        failures.append("The widget image cache was not built.")
    if not reload_entries:
        failures.append("The widget timeline reload was not requested.")

    final_widget_event_order: dict[str, float | str] = {}
    if final_entries:
        latest_final_entry = max(
            final_entries,
            key=lambda entry: entry_timestamp(entry) or float("-inf"),
        )
        final_time = entry_timestamp(latest_final_entry)
        final_session = latest_final_entry.get("_logSession")
        assert final_time is not None
        cache_times = sorted(
            value
            for entry in cache_entries
            if (value := entry_timestamp(entry)) is not None and value > final_time
            and entry.get("_logSession") == final_session
        )
        reload_times: list[float] = []
        if cache_times:
            reload_times = sorted(
                value
                for entry in reload_entries
                if (value := entry_timestamp(entry)) is not None
                and value > cache_times[0]
                and entry.get("_logSession") == final_session
            )
        if not cache_times or not reload_times:
            failures.append(
                "Widget output events are not ordered after the final scan "
                "(final < cache build < timeline reload)."
            )
        else:
            final_widget_event_order = {
                "finalScan": final_time,
                "cacheBuild": cache_times[0],
                "timelineReload": reload_times[0],
                "session": str(final_session),
            }

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
            f"Widget manifest contains {len(manifest_items)} entries; expected 15-20."
        )

    cache_directory = group_container / "widget-cache"
    referenced_cache_files: set[Path] = set()
    cache_files_by_variant: dict[str, set[Path]] = {
        "small": set(),
        "medium": set(),
        "large": set(),
    }
    expected_cache_dimensions = {
        "small": (400, 400),
        "medium": (800, 374),
        "large": (400, 420),
    }
    for item in manifest_items:
        legacy_filename = item.get("cacheFilename")
        filenames = item.get("cacheFilenames")
        if not isinstance(filenames, dict):
            failures.append("Widget manifest has no family-specific cache filenames.")
            continue

        variant_filenames: dict[str, str] = {}
        for variant in expected_cache_dimensions:
            filename = filenames.get(variant)
            if (
                not isinstance(filename, str)
                or Path(filename).name != filename
                or Path(filename).suffix.lower() not in {".jpg", ".jpeg"}
            ):
                failures.append(
                    f"Widget manifest contains an unsafe {variant} cache filename."
                )
                continue
            variant_filenames[variant] = filename
            file_path = cache_directory / filename
            cache_files_by_variant[variant].add(file_path)
            referenced_cache_files.add(file_path)

        if len(set(variant_filenames.values())) != len(expected_cache_dimensions):
            failures.append(
                "Widget manifest does not reference three distinct family images."
            )
        if variant_filenames.get("small") != legacy_filename:
            failures.append(
                "Legacy widget cacheFilename does not match the small image."
            )
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
    invalid_cache_dimensions: list[str] = []
    cache_dimensions_by_variant: dict[str, dict[str, tuple[int, int] | None]] = {}
    cache_bytes_by_variant: dict[str, dict[str, int]] = {}
    for variant, paths in cache_files_by_variant.items():
        dimensions = {
            path.name: cache_dimensions.get(path.name)
            for path in sorted(paths)
            if path.is_file()
        }
        byte_counts = {
            path.name: path.stat().st_size
            for path in sorted(paths)
            if path.is_file()
        }
        cache_dimensions_by_variant[variant] = dimensions
        cache_bytes_by_variant[variant] = byte_counts
        invalid_cache_dimensions.extend(
            f"{variant}:{filename}"
            for filename, actual_dimensions in dimensions.items()
            if actual_dimensions != expected_cache_dimensions[variant]
        )
    if invalid_cache_dimensions:
        failures.append(
            "Widget cache files do not match their family dimensions: "
            + ", ".join(invalid_cache_dimensions)
        )

    history_path = group_container / "widget-cache-history.json"
    history_current_generation_files: list[str] = []
    if not history_path.is_file():
        failures.append("widget-cache-history.json was not written to the App Group.")
    else:
        try:
            history = json.loads(history_path.read_text(encoding="utf-8-sig"))
            generations = history.get("generations", [])
            if isinstance(generations, list) and generations:
                first_generation = generations[0]
                if isinstance(first_generation, dict):
                    raw_filenames = first_generation.get("filenames", [])
                    if isinstance(raw_filenames, list):
                        history_current_generation_files = [
                            value for value in raw_filenames if isinstance(value, str)
                        ]
            if not referenced_cache_files:
                failures.append("Widget manifest does not reference cache files.")
            elif not {
                path.name for path in referenced_cache_files
            }.issubset(set(history_current_generation_files)):
                failures.append(
                    "Latest widget cache history generation does not retain every "
                    "family-specific image."
                )
        except (json.JSONDecodeError, OSError) as error:
            failures.append(f"widget-cache-history.json is invalid: {error}")
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
        "sampledThumbnailLoads": len(thumbnail_load_entries),
        "baselineAssetCount": len(baseline_identifiers),
        "importedFixtureAssetCount": len(fixture_assets),
        "snapshotTotalAssets": int(scan_state.get("totalAssets", 0) or 0),
        "snapshotCatAssets": int(scan_state.get("catAssets", 0) or 0),
        "importedFixtureStatuses": fixture_asset_statuses,
        "manifestEntryCount": len(manifest_items),
        "finalWidgetEventOrder": final_widget_event_order,
        "uniqueCacheFileCount": len(referenced_cache_files),
        "uniqueCacheFileCountByVariant": {
            variant: len(paths) for variant, paths in cache_files_by_variant.items()
        },
        "cacheBytesMinimum": min(cache_byte_counts, default=0),
        "cacheBytesMaximum": max(cache_byte_counts, default=0),
        "cacheDimensions": cache_dimensions,
        "cacheDimensionsByVariant": cache_dimensions_by_variant,
        "cacheBytesByVariant": cache_bytes_by_variant,
        "historyCurrentGenerationFileCount": len(history_current_generation_files),
        "oversizedCacheFiles": oversized_cache_files,
        "failures": failures,
        "notes": [
            "Deferred or failed baseline assets are allowed "
            "because the hosted Simulator ships old sample records without "
            "local image resources.",
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
