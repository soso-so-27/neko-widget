#!/usr/bin/env python3

"""Validate the bounded Simulator scale run and write durable evidence.

The hosted Simulator does not enforce an iPhone jetsam limit. This validator
therefore treats process continuity, the macOS host's physical-footprint high
water mark, large-photo windows, and crash diagnostics as regression signals;
it never labels a passing run as proof of device jetsam safety.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import sys
import traceback
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


MIB = 1024 * 1024
EXPECTED_LARGE_PIXELS = "8000x6000"
MAX_THUMBNAIL_EDGE = 1024
MAX_THUMBNAIL_DECODED_BYTES = 1024 * 1024 * 4
TERMINAL_IMPORTED_STATUSES = {"detected", "noCat"}
LARGE_TERMINAL_OUTCOMES = {"detected", "noCat"}
ACTIVE_MEMORY_STATUSES = {"start", "sample"}
ALLOWED_MEMORY_STATUSES = ACTIVE_MEMORY_STATUSES | {"stop"}


@dataclass(frozen=True)
class MemorySample:
    index: int
    timestamp_ns: int
    pid: int
    process_start: int
    process_exit: int
    resident: int
    footprint: int
    lifetime_peak: int
    status: str
    error_number: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-group-container", type=Path, required=True)
    parser.add_argument("--baseline-snapshot", type=Path, required=True)
    parser.add_argument("--fixture-manifest", type=Path, required=True)
    parser.add_argument("--memory-csv", type=Path, required=True)
    parser.add_argument("--expected-count", type=int, required=True)
    parser.add_argument("--expected-large-count", type=int, required=True)
    parser.add_argument("--scan-start-epoch-ns", type=int, required=True)
    parser.add_argument("--scan-end-epoch-ns", type=int, required=True)
    parser.add_argument("--app-pid", type=int, required=True)
    parser.add_argument("--sampler-exit-code", type=int, required=True)
    parser.add_argument("--authorization-failed", choices=("true", "false"), required=True)
    parser.add_argument("--process-exited-early", choices=("true", "false"), required=True)
    parser.add_argument("--scan-completed", choices=("true", "false"), required=True)
    parser.add_argument("--crash-directory", type=Path, required=True)
    parser.add_argument("--memory-termination-log", type=Path, required=True)
    parser.add_argument("--max-peak-mib", type=float, required=True)
    parser.add_argument("--max-large-delta-mib", type=float, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    return parser.parse_args()


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def integer(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def floating(value: Any, default: float = 0.0) -> float:
    try:
        result = float(value)
    except (TypeError, ValueError):
        return default
    return result if math.isfinite(result) else default


def bytes_to_mib(value: int) -> float:
    return round(value / MIB, 3)


def parse_dimensions(value: str) -> tuple[int, int] | None:
    match = re.fullmatch(r"(\d+)x(\d+)", value)
    if match is None:
        return None
    return int(match.group(1)), int(match.group(2))


def load_logs(directory: Path) -> tuple[list[dict[str, Any]], int, list[str]]:
    entries: list[dict[str, Any]] = []
    malformed = 0
    files: list[str] = []
    for path in sorted(directory.glob("*.jsonl")):
        files.append(path.name)
        for line_number, line in enumerate(
            path.read_text(encoding="utf-8-sig", errors="replace").splitlines(),
            start=1,
        ):
            if not line.strip():
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                malformed += 1
                continue
            if isinstance(value, dict):
                value["_sourceFile"] = path.name
                value["_sourceLine"] = line_number
                entries.append(value)
            else:
                malformed += 1
    entries.sort(key=lambda entry: floating(entry.get("timestamp")))
    return entries, malformed, files


def load_memory_samples(path: Path, failures: list[str]) -> list[MemorySample]:
    samples: list[MemorySample] = []
    try:
        with path.open(newline="", encoding="utf-8") as stream:
            reader = csv.DictReader(stream)
            expected_columns = {
                "sample_index",
                "timestamp_epoch_ns",
                "pid",
                "proc_start_abstime",
                "proc_exit_abstime",
                "resident_size_bytes",
                "phys_footprint_bytes",
                "lifetime_max_phys_footprint_bytes",
                "status",
                "error_number",
            }
            if reader.fieldnames is None or not expected_columns.issubset(reader.fieldnames):
                failures.append("memory CSV is missing required columns")
                return samples
            for row_number, row in enumerate(reader, start=2):
                try:
                    samples.append(
                        MemorySample(
                            index=int(row["sample_index"]),
                            timestamp_ns=int(row["timestamp_epoch_ns"]),
                            pid=int(row["pid"]),
                            process_start=int(row["proc_start_abstime"]),
                            process_exit=int(row["proc_exit_abstime"]),
                            resident=int(row["resident_size_bytes"]),
                            footprint=int(row["phys_footprint_bytes"]),
                            lifetime_peak=int(row["lifetime_max_phys_footprint_bytes"]),
                            status=row["status"],
                            error_number=int(row["error_number"]),
                        )
                    )
                except (KeyError, TypeError, ValueError):
                    failures.append(f"memory CSV row {row_number} is malformed")
    except OSError as error:
        failures.append(f"memory CSV could not be read: {error}")
    return samples


def entries_named(
    entries: Iterable[dict[str, Any]], category: str, message: str
) -> list[dict[str, Any]]:
    return [
        entry
        for entry in entries
        if entry.get("category") == category and entry.get("message") == message
    ]


def select_large_windows(
    entries: list[dict[str, Any]],
    expected_count: int,
    failures: list[str],
) -> list[dict[str, Any]]:
    starts = entries_named(entries, "image-load", "Large photo processing started")
    thumbnails = entries_named(entries, "image-load", "Large photo thumbnail resolved")
    finishes = entries_named(entries, "image-load", "Large photo processing finished")
    hashes = sorted(
        {
            str(entry.get("metadata", {}).get("asset", ""))
            for entry in starts
            if entry.get("metadata", {}).get("asset")
        }
    )
    if len(hashes) != expected_count:
        failures.append(
            f"large-photo logs cover {len(hashes)} distinct assets; expected {expected_count}"
        )

    windows: list[dict[str, Any]] = []
    for asset_hash in hashes:
        asset_starts = sorted(
            (
                entry
                for entry in starts
                if entry.get("metadata", {}).get("asset") == asset_hash
            ),
            key=lambda entry: floating(entry.get("timestamp")),
        )
        asset_finishes = sorted(
            (
                entry
                for entry in finishes
                if entry.get("metadata", {}).get("asset") == asset_hash
            ),
            key=lambda entry: floating(entry.get("timestamp")),
        )
        selected: tuple[dict[str, Any], dict[str, Any]] | None = None
        for start in asset_starts:
            start_time = floating(start.get("timestamp"))
            finish = next(
                (
                    candidate
                    for candidate in asset_finishes
                    if floating(candidate.get("timestamp")) >= start_time
                ),
                None,
            )
            if finish is not None:
                selected = start, finish
                break
        if selected is None:
            failures.append(f"large asset {asset_hash} has no complete start/finish pair")
            continue

        start, finish = selected
        start_time = floating(start.get("timestamp"))
        finish_time = floating(finish.get("timestamp"))
        thumbnail = next(
            (
                entry
                for entry in thumbnails
                if entry.get("metadata", {}).get("asset") == asset_hash
                and start_time <= floating(entry.get("timestamp")) <= finish_time
            ),
            None,
        )
        start_metadata = start.get("metadata", {})
        finish_metadata = finish.get("metadata", {})
        if start_metadata.get("sourcePixels") != EXPECTED_LARGE_PIXELS:
            failures.append(f"large asset {asset_hash} source dimensions are not 8000x6000")
        if integer(start_metadata.get("pixelCount")) != 48_000_000:
            failures.append(f"large asset {asset_hash} start pixel count is not 48 MP")
        if start_metadata.get("targetPixels") != "1024x1024":
            failures.append(f"large asset {asset_hash} start target is not 1024x1024")
        if finish_metadata.get("outcome") not in LARGE_TERMINAL_OUTCOMES:
            failures.append(
                f"large asset {asset_hash} finished as {finish_metadata.get('outcome')!r}"
            )
        if thumbnail is None:
            failures.append(f"large asset {asset_hash} has no thumbnail-resolution event")
            thumbnail_metadata: dict[str, Any] = {}
        else:
            thumbnail_metadata = thumbnail.get("metadata", {})
            if thumbnail_metadata.get("sourcePixels") != start_metadata.get("sourcePixels"):
                failures.append(
                    f"large asset {asset_hash} thumbnail source disagrees with its start"
                )
            if thumbnail_metadata.get("outcome") != "loaded":
                failures.append(
                    f"large asset {asset_hash} thumbnail outcome is "
                    f"{thumbnail_metadata.get('outcome')!r}"
                )
            output = parse_dimensions(str(thumbnail_metadata.get("outputPixels", "")))
            if (
                output is None
                or min(output) <= 0
                or max(output) > MAX_THUMBNAIL_EDGE
            ):
                failures.append(
                    f"large asset {asset_hash} thumbnail exceeds 1024px or is malformed"
                )
            decoded = integer(thumbnail_metadata.get("decodedBytesEstimate"), -1)
            expected_decoded = output[0] * output[1] * 4 if output is not None else -1
            if (
                decoded <= 0
                or decoded > MAX_THUMBNAIL_DECODED_BYTES
                or decoded != expected_decoded
            ):
                failures.append(
                    f"large asset {asset_hash} decoded thumbnail estimate is invalid"
                )
            for key in ("sourcePixels", "outputPixels", "decodedBytesEstimate"):
                if str(finish_metadata.get(key, "")) != str(
                    thumbnail_metadata.get(key, "")
                ):
                    failures.append(
                        f"large asset {asset_hash} finish metadata disagrees on {key}"
                    )

        windows.append(
            {
                "assetHash": asset_hash,
                "startEpochNs": int(start_time * 1_000_000_000),
                "finishEpochNs": int(finish_time * 1_000_000_000),
                "durationMs": floating(finish_metadata.get("durationMs")),
                "outcome": finish_metadata.get("outcome"),
                "sourcePixels": finish_metadata.get("sourcePixels"),
                "outputPixels": finish_metadata.get("outputPixels"),
                "decodedBytesEstimate": integer(
                    finish_metadata.get("decodedBytesEstimate"), 0
                ),
            }
        )
    return sorted(windows, key=lambda value: value["startEpochNs"])


def memory_window_metrics(
    samples: list[MemorySample],
    windows: list[dict[str, Any]],
    failures: list[str],
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    active = sorted(
        (sample for sample in samples if sample.status in ACTIVE_MEMORY_STATUSES),
        key=lambda sample: sample.timestamp_ns,
    )
    if not windows or not active:
        return [], {
            "baselineAvailable": False,
            "lifetimePeakIncreaseBytes": 0,
            "currentFootprintIncreaseBytes": 0,
        }

    first_start = min(window["startEpochNs"] for window in windows)
    last_finish = max(window["finishEpochNs"] for window in windows)
    before = [sample for sample in active if sample.timestamp_ns <= first_start]
    after = [sample for sample in active if sample.timestamp_ns >= last_finish]
    if not before:
        failures.append("memory sampler has no pre-large baseline sample")
    if not after:
        failures.append("memory sampler has no post-large sample")
    baseline = before[-1] if before else active[0]
    post = after[0] if after else active[-1]
    combined_samples = [
        sample
        for sample in active
        if baseline.timestamp_ns <= sample.timestamp_ns <= post.timestamp_ns
    ]
    combined_lifetime_peak = max(
        (sample.lifetime_peak for sample in combined_samples),
        default=post.lifetime_peak,
    )
    combined_current_peak = max(
        (sample.footprint for sample in combined_samples),
        default=post.footprint,
    )

    window_reports: list[dict[str, Any]] = []
    for window in windows:
        window_before = [
            sample for sample in active if sample.timestamp_ns <= window["startEpochNs"]
        ]
        window_after = [
            sample for sample in active if sample.timestamp_ns >= window["finishEpochNs"]
        ]
        pre = window_before[-1] if window_before else active[0]
        end = window_after[0] if window_after else active[-1]
        relevant = [
            sample
            for sample in active
            if pre.timestamp_ns <= sample.timestamp_ns <= end.timestamp_ns
        ]
        peak_lifetime = max(
            (sample.lifetime_peak for sample in relevant), default=end.lifetime_peak
        )
        peak_current = max(
            (sample.footprint for sample in relevant), default=end.footprint
        )
        window_reports.append(
            {
                **window,
                "sampleCount": len(relevant),
                "preFootprintBytes": pre.footprint,
                "peakFootprintBytes": peak_current,
                "currentFootprintIncreaseBytes": max(0, peak_current - pre.footprint),
                "lifetimePeakBeforeBytes": pre.lifetime_peak,
                "lifetimePeakThroughWindowBytes": peak_lifetime,
                "lifetimePeakIncreaseBytes": max(0, peak_lifetime - pre.lifetime_peak),
            }
        )

    combined = {
        "baselineAvailable": bool(before),
        "postSampleAvailable": bool(after),
        "startEpochNs": first_start,
        "finishEpochNs": last_finish,
        "preFootprintBytes": baseline.footprint,
        "peakFootprintBytes": combined_current_peak,
        "currentFootprintIncreaseBytes": max(
            0, combined_current_peak - baseline.footprint
        ),
        "lifetimePeakBeforeBytes": baseline.lifetime_peak,
        "lifetimePeakThroughWindowBytes": combined_lifetime_peak,
        "lifetimePeakIncreaseBytes": max(
            0, combined_lifetime_peak - baseline.lifetime_peak
        ),
        "sampleCount": len(combined_samples),
    }
    return window_reports, combined


def relevant_crash_evidence(
    directory: Path, memory_log: Path, app_pid: int
) -> tuple[list[str], list[str], list[str]]:
    all_files: list[str] = []
    relevant_files: list[str] = []
    if directory.is_dir():
        for path in sorted(value for value in directory.rglob("*") if value.is_file()):
            all_files.append(path.name)
            content = path.read_text(encoding="utf-8", errors="ignore").lower()
            name = path.name.lower()
            exact_pid = re.search(rf"(?<!\d){app_pid}(?!\d)", content) is not None
            if name.startswith("nekowidget") or (
                name.startswith("jetsamevent")
                and ("nekowidget" in content or exact_pid)
            ):
                relevant_files.append(path.name)

    relevant_log_lines: list[str] = []
    if memory_log.is_file():
        for line in memory_log.read_text(encoding="utf-8", errors="ignore").splitlines():
            folded = line.lower()
            identifies_app = "nekowidget" in folded or re.search(
                rf"(?<!\d){app_pid}(?!\d)", line
            ) is not None
            indicates_termination = any(
                marker in folded
                for marker in (
                    "jetsam",
                    "exc_resource",
                    "killed",
                    "killing",
                    "terminated",
                    "termination",
                    "exited due to memory",
                )
            )
            if identifies_app and indicates_termination:
                relevant_log_lines.append(line[:1000])
    return all_files, relevant_files, relevant_log_lines


def write_outputs(
    report_path: Path,
    summary_path: Path,
    report: dict[str, Any],
    failures: list[str],
) -> None:
    report["status"] = "pass" if not failures else "fail"
    report["failures"] = failures
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    memory = report.get("memory", {})
    imported = report.get("library", {})
    timing = report.get("timing", {})
    large = memory.get("largeCombinedWindow", {})
    lines = [
        "## iOS Simulator scale test",
        "",
        f"**Result: {'PASS' if not failures else 'FAIL'}**",
        "",
        "| Metric | Result |",
        "| --- | ---: |",
        f"| Requested/imported assets | {imported.get('expectedImportedCount', 0)} / {imported.get('importedAssetCount', 0)} |",
        f"| Completed final scan | {report.get('scan', {}).get('completedFinal', False)} |",
        f"| Fixture generation | {timing.get('fixtureGenerationSeconds', 0):.3f} s |",
        f"| Simulator photo import | {timing.get('photoImportSeconds', 0):.3f} s |",
        f"| Launch-to-final | {timing.get('launchToFinalSeconds', 0):.3f} s |",
        f"| SharedLog scan span | {timing.get('sharedLogScanSeconds', 0):.3f} s |",
        f"| App PID | {report.get('process', {}).get('appPid', 0)} |",
        f"| Peak physical footprint | {memory.get('lifetimePeakMiB', 0):.3f} MiB |",
        f"| Peak RSS | {memory.get('peakResidentMiB', 0):.3f} MiB |",
        f"| 48 MP combined lifetime-peak increase | {bytes_to_mib(integer(large.get('lifetimePeakIncreaseBytes'))):.3f} MiB |",
        f"| 48 MP completed windows | {len(memory.get('largeWindows', []))} |",
        f"| Relevant crash/jetsam evidence | {len(report.get('crashEvidence', {}).get('relevantFiles', [])) + len(report.get('crashEvidence', {}).get('relevantUnifiedLogLines', []))} |",
        "",
        "> Simulator does not enforce iPhone memory-warning or jetsam limits. "
        "This is a process-continuity and memory-regression test, not device-jetsam proof.",
    ]
    if failures:
        lines.extend(["", "### Failures", ""])
        lines.extend(f"- {failure}" for failure in failures)
    summary_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    failures: list[str] = []
    warnings: list[str] = []
    report: dict[str, Any] = {
        "schemaVersion": 1,
        "environment": {
            "measurementTarget": "iOS Simulator app process on macOS host",
            "deviceJetsamEnforced": False,
            "limitation": (
                "macOS does not issue iPhone memory warnings or out-of-memory "
                "terminations to Simulator apps; real-device jetsam remains unverified"
            ),
        },
        "thresholds": {
            "maximumLifetimePeakMiB": args.max_peak_mib,
            "maximumLargeWindowIncreaseMiB": args.max_large_delta_mib,
        },
    }

    if args.expected_count not in (1000, 2000, 3000):
        failures.append("expected imported count is not an allowed scale")
    if args.expected_large_count != 3:
        failures.append("expected large fixture count must be three")
    if args.scan_end_epoch_ns <= args.scan_start_epoch_ns:
        failures.append("scan observation timestamps are invalid")

    try:
        baseline = load_json(args.baseline_snapshot)
        final = load_json(args.app_group_container / "library-snapshot.json")
        manifest = load_json(args.fixture_manifest)
    except (OSError, json.JSONDecodeError) as error:
        failures.append(f"required JSON could not be loaded: {error}")
        write_outputs(args.report, args.summary, report, failures)
        return 1

    baseline_assets = baseline.get("assets", [])
    final_assets = final.get("assets", [])
    baseline_ids = {
        value.get("localIdentifier")
        for value in baseline_assets
        if value.get("localIdentifier")
    }
    final_by_id = {
        value.get("localIdentifier"): value
        for value in final_assets
        if value.get("localIdentifier")
    }
    imported_ids = set(final_by_id) - baseline_ids
    missing_baseline = baseline_ids - set(final_by_id)
    imported_statuses = Counter(
        str(final_by_id[identifier].get("analysisStatus"))
        for identifier in imported_ids
    )
    invalid_imported = sum(
        count
        for status, count in imported_statuses.items()
        if status not in TERMINAL_IMPORTED_STATUSES
    )
    if len(imported_ids) != args.expected_count:
        failures.append(
            f"final baseline delta is {len(imported_ids)} assets; expected {args.expected_count}"
        )
    if missing_baseline:
        failures.append(f"{len(missing_baseline)} baseline assets disappeared during the run")
    if invalid_imported:
        failures.append(
            f"{invalid_imported} imported assets did not finish as detected/noCat"
        )
    if imported_statuses.get("detected", 0) == 0:
        failures.append("Vision did not detect a cat in any imported scale fixture")

    state = final.get("scanState", {})
    completed_final = (
        state.get("phase") == "completed"
        and state.get("resultKind") == "final"
        and integer(state.get("scannedAssets")) == integer(state.get("totalAssets"))
    )
    if not completed_final or args.scan_completed != "true":
        failures.append("the full scan did not reach completed/final")
    if integer(state.get("totalAssets")) != len(final_assets):
        failures.append("final scan total does not match the persisted asset record count")

    outputs = manifest.get("outputs", [])
    manifest_large = [value for value in outputs if value.get("role") == "large"]
    if manifest.get("totalCount") != args.expected_count or len(outputs) != args.expected_count:
        failures.append("fixture manifest count does not match the requested scale")
    if len({value.get("sha256") for value in outputs}) != args.expected_count:
        failures.append("fixture manifest output hashes are not unique")
    if len(manifest_large) != args.expected_large_count or any(
        value.get("width") != 8000 or value.get("height") != 6000
        for value in manifest_large
    ):
        failures.append("fixture manifest does not contain three 8000x6000 images")

    logs_directory = args.app_group_container / "diagnostic-logs"
    entries, malformed_log_lines, log_files = load_logs(logs_directory)
    if malformed_log_lines:
        failures.append(f"SharedLog contains {malformed_log_lines} malformed JSONL lines")
    error_entries = [entry for entry in entries if entry.get("level") == "error"]
    if error_entries:
        failures.append(f"SharedLog contains {len(error_entries)} error entries")
    required_events = [
        ("scan", "Scan generation started"),
        ("scan", "Photo library scan completed"),
        ("scan", "Final scan result applied"),
    ]
    for category, message in required_events:
        if not entries_named(entries, category, message):
            failures.append(f"required SharedLog event is missing: {message}")

    app_log_pids: set[int] = set()
    for file_name in log_files:
        match = re.match(
            r"^app-\d+-(\d+)-[0-9a-f-]+(?:\.\d+)?\.jsonl$", file_name
        )
        if match:
            app_log_pids.add(int(match.group(1)))
    if app_log_pids != {args.app_pid}:
        failures.append(
            f"SharedLog app PID set is {sorted(app_log_pids)}; expected only {args.app_pid}"
        )

    large_windows = select_large_windows(entries, args.expected_large_count, failures)
    samples = load_memory_samples(args.memory_csv, failures)
    active_samples = [sample for sample in samples if sample.status in ACTIVE_MEMORY_STATUSES]
    if args.sampler_exit_code != 0:
        failures.append(f"memory sampler exited with code {args.sampler_exit_code}")
    if not active_samples:
        failures.append("memory sampler produced no active samples")
    if any(sample.pid != args.app_pid for sample in samples):
        failures.append("memory CSV contains a PID different from the launched app")
    invalid_memory_statuses = sorted(
        {sample.status for sample in samples if sample.status not in ALLOWED_MEMORY_STATUSES}
    )
    if invalid_memory_statuses:
        failures.append(
            f"memory sampler recorded terminal failure status: {invalid_memory_statuses}"
        )
    process_starts = {sample.process_start for sample in active_samples if sample.process_start}
    if len(process_starts) != 1:
        failures.append("memory sampler did not observe exactly one process lifetime")
    if any(sample.process_exit != 0 for sample in active_samples):
        failures.append("memory sampler observed process exit during the scan")
    if any(sample.error_number != 0 for sample in active_samples):
        failures.append("memory sampler recorded an error on an active sample")
    if not samples or samples[-1].status != "stop":
        failures.append("memory sampler did not stop through its clean sentinel")
    lifetime_values = [sample.lifetime_peak for sample in active_samples]
    if any(later < earlier for earlier, later in zip(lifetime_values, lifetime_values[1:])):
        failures.append("kernel lifetime physical-footprint high-water mark decreased")

    peak_footprint = max((sample.footprint for sample in active_samples), default=0)
    lifetime_peak = max(lifetime_values, default=0)
    peak_resident = max((sample.resident for sample in active_samples), default=0)
    if peak_footprint <= 0 or lifetime_peak <= 0 or peak_resident <= 0:
        failures.append("memory sampler returned an unavailable all-zero metric")
    if lifetime_peak < peak_footprint:
        failures.append("lifetime physical-footprint peak is below sampled current footprint")
    max_peak_bytes = int(args.max_peak_mib * MIB)
    if lifetime_peak > max_peak_bytes:
        failures.append(
            f"lifetime physical-footprint peak {bytes_to_mib(lifetime_peak):.3f} MiB "
            f"exceeds {args.max_peak_mib:.3f} MiB"
        )

    large_window_reports, large_combined = memory_window_metrics(
        samples, large_windows, failures
    )
    large_increase = integer(large_combined.get("lifetimePeakIncreaseBytes"))
    max_large_delta_bytes = int(args.max_large_delta_mib * MIB)
    if large_increase > max_large_delta_bytes:
        failures.append(
            f"48 MP window lifetime-peak increase {bytes_to_mib(large_increase):.3f} MiB "
            f"exceeds {args.max_large_delta_mib:.3f} MiB"
        )

    all_crash_files, relevant_crashes, relevant_memory_lines = relevant_crash_evidence(
        args.crash_directory, args.memory_termination_log, args.app_pid
    )
    if args.authorization_failed == "true":
        failures.append("PhotoKit authorization was not observed before scanning")
    if args.process_exited_early == "true":
        failures.append("the app process exited before scan completion")
    if relevant_crashes:
        failures.append(f"relevant crash/jetsam report found: {relevant_crashes}")
    if relevant_memory_lines:
        failures.append("unified log contains app-specific memory termination evidence")

    vision_summaries = entries_named(entries, "vision", "Vision phase summary")
    newly_analyzed = sum(
        integer(entry.get("metadata", {}).get("newlyAnalyzed"))
        for entry in vision_summaries
    )
    if newly_analyzed < args.expected_count:
        failures.append(
            f"Vision summaries report {newly_analyzed} newly analyzed; "
            f"expected at least {args.expected_count}"
        )
    if newly_analyzed > args.expected_count:
        warnings.append(
            "Vision summaries exceed the fixture count, indicating an additional scan generation"
        )

    launch_to_final_seconds = (
        args.scan_end_epoch_ns - args.scan_start_epoch_ns
    ) / 1_000_000_000
    setup_timings: dict[str, Any] = {}
    setup_timing_path = args.report.parent / "setup-timings.json"
    if setup_timing_path.is_file():
        try:
            value = load_json(setup_timing_path)
            if isinstance(value, dict):
                setup_timings = value
        except (OSError, json.JSONDecodeError) as error:
            warnings.append(f"setup timing artifact could not be parsed: {error}")
    scan_events = entries_named(entries, "scan", "Scan generation started")
    final_events = entries_named(entries, "scan", "Final scan result applied")
    shared_log_scan_seconds = 0.0
    if scan_events and final_events:
        shared_log_scan_seconds = max(0.0, floating(final_events[-1].get("timestamp")) - floating(scan_events[0].get("timestamp")))

    report.update(
        {
            "warnings": warnings,
            "process": {
                "appPid": args.app_pid,
                "sharedLogAppPids": sorted(app_log_pids),
                "authorizationFailed": args.authorization_failed == "true",
                "exitedEarly": args.process_exited_early == "true",
                "samplerExitCode": args.sampler_exit_code,
                "singleProcessLifetime": len(process_starts) == 1,
            },
            "library": {
                "baselineAssetCount": len(baseline_ids),
                "finalAssetCount": len(final_by_id),
                "expectedImportedCount": args.expected_count,
                "importedAssetCount": len(imported_ids),
                "missingBaselineAssetCount": len(missing_baseline),
                "importedStatusCounts": dict(sorted(imported_statuses.items())),
            },
            "scan": {
                "completedFinal": completed_final,
                "phase": state.get("phase"),
                "resultKind": state.get("resultKind"),
                "scannedAssets": integer(state.get("scannedAssets")),
                "totalAssets": integer(state.get("totalAssets")),
                "catAssets": integer(state.get("catAssets")),
                "deferredAssets": integer(state.get("deferredAssets")),
                "visionNewlyAnalyzed": newly_analyzed,
            },
            "timing": {
                "scanStartEpochNs": args.scan_start_epoch_ns,
                "scanEndEpochNs": args.scan_end_epoch_ns,
                "launchToFinalSeconds": launch_to_final_seconds,
                "sharedLogScanSeconds": shared_log_scan_seconds,
                "fixtureGenerationSeconds": floating(
                    setup_timings.get("fixtureGenerationSeconds")
                ),
                "photoImportSeconds": floating(
                    setup_timings.get("photoImportSeconds")
                ),
            },
            "memory": {
                "sampleCount": len(active_samples),
                "intervalTargetMilliseconds": 100,
                "peakPhysicalFootprintBytes": peak_footprint,
                "peakPhysicalFootprintMiB": bytes_to_mib(peak_footprint),
                "lifetimePeakBytes": lifetime_peak,
                "lifetimePeakMiB": bytes_to_mib(lifetime_peak),
                "peakResidentBytes": peak_resident,
                "peakResidentMiB": bytes_to_mib(peak_resident),
                "largeWindows": large_window_reports,
                "largeCombinedWindow": large_combined,
            },
            "logging": {
                "fileCount": len(log_files),
                "entryCount": len(entries),
                "malformedLineCount": malformed_log_lines,
                "errorEntryCount": len(error_entries),
            },
            "fixtures": {
                "manifestSchemaVersion": manifest.get("schemaVersion"),
                "totalCount": manifest.get("totalCount"),
                "largeCount": len(manifest_large),
                "uniqueHashCount": len({value.get("sha256") for value in outputs}),
                "totalBytes": integer(manifest.get("totalBytes")),
                "generatedImagesIncludedInArtifacts": False,
                "license": manifest.get("licenseLineage", {}).get(
                    "generatedOutputsLicense"
                ),
            },
            "crashEvidence": {
                "allCapturedFiles": all_crash_files,
                "relevantFiles": relevant_crashes,
                "relevantUnifiedLogLines": relevant_memory_lines,
            },
        }
    )
    write_outputs(args.report, args.summary, report, failures)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if not failures else 1


def guarded_main() -> int:
    try:
        return main()
    except Exception as error:  # Preserve diagnostics for unexpected CI/schema failures.
        def option_path(flag: str, fallback: str) -> Path:
            try:
                return Path(sys.argv[sys.argv.index(flag) + 1])
            except (ValueError, IndexError):
                return Path(fallback)

        report_path = option_path("--report", "scale-report.json")
        summary_path = option_path("--summary", "scale-summary.md")
        fatal = f"{type(error).__name__}: {error}"
        report = {
            "schemaVersion": 1,
            "fatalValidationError": fatal,
            "traceback": traceback.format_exc(),
            "environment": {
                "measurementTarget": "iOS Simulator app process on macOS host",
                "deviceJetsamEnforced": False,
            },
        }
        try:
            write_outputs(report_path, summary_path, report, [fatal])
        except Exception as write_error:
            print(
                f"Scale validator failed and could not write its report: "
                f"{fatal}; writer={write_error}",
                file=sys.stderr,
            )
        else:
            print(json.dumps(report, indent=2, sort_keys=True), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(guarded_main())
