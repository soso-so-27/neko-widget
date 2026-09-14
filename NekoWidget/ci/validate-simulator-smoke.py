#!/usr/bin/env python3
"""Validate the deterministic output of the iOS Simulator smoke test."""

from __future__ import annotations

import json
import math
import re
import sys
import uuid
from pathlib import Path
from typing import Any


PERSONAL_SOURCE_ID = "personal-library"
SWIFT_REFERENCE_EPOCH = 978_307_200
EXPECTED_CACHE_DIMENSIONS = {
    "small": (500, 500), "medium": (1050, 500), "large": (1050, 1100),
}
MAXIMUM_CACHE_BYTES = {
    "small": 100 * 1_024, "medium": 200 * 1_024, "large": 220 * 1_024,
}


def safe_cache_filename(value: Any) -> bool:
    return (
        isinstance(value, str) and len(value.encode("utf-8")) <= 255
        and ".." not in value
        and re.fullmatch(r"[A-Za-z0-9_.-]+\.jpg", value) is not None
    )


def finite_number(value: Any) -> bool:
    return type(value) in (int, float) and math.isfinite(value)


def valid_uuid(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    try:
        return str(uuid.UUID(value)) == value.lower()
    except ValueError:
        return False


def integer_metadata(entry: dict[str, Any], key: str) -> int:
    value = entry.get("metadata", {}).get(key, "0")
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def float_metadata(entry: dict[str, Any], key: str) -> float:
    value = entry.get("metadata", {}).get(key, "0")
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def entry_timestamp(entry: dict[str, Any]) -> float | None:
    try:
        return float(entry.get("timestamp"))
    except (TypeError, ValueError):
        return None


def aligned_byte_count(value: int, alignment: int) -> int:
    return ((value + alignment - 1) // alignment) * alignment


def jpeg_dimensions(path: Path) -> tuple[int, int] | None:
    """Read JPEG SOF dimensions without a third-party image dependency."""
    if path.is_symlink() or not path.is_file():
        return None
    if not 4 <= path.stat().st_size <= max(MAXIMUM_CACHE_BYTES.values()):
        return None
    data = path.read_bytes()
    if not data.startswith(b"\xff\xd8") or not data.endswith(b"\xff\xd9"):
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


def validate_personal_state(
    group_container: Path,
    expected_renderer: str,
    failures: list[str],
    *,
    observed_at: float | None = None,
    snapshot_photo_ids: set[str] | None = None,
    detected_fixture_ids: set[str] | None = None,
) -> tuple[dict[str, Any], list[dict[str, Any]], dict[str, set[Path]]]:
    """Validate the canonical pool and every live image dependency, not v1 history.

    Dates in this file use Swift Codable's 2001 epoch. `observed_at`, when
    supplied from SharedLog, is Unix time. Empty issues/grants are legitimate
    in headless smoke: a persisted, usable plan is still mandatory.
    """
    path = group_container / "personal-rediscovery.v1" / "state.json"
    cache = group_container / "widget-cache"
    report: dict[str, Any] = {
        "statePath": "personal-rediscovery.v1/state.json", "candidateCap": 100,
        "fileCap": 400, "candidateCount": 0, "liveReferenceCount": 0,
        "actualJPEGCount": 0, "actualJPEGBytes": 0, "cycleCount": 0,
        "issueCount": 0, "grantCount": 0,
    }
    files = {variant: set() for variant in EXPECTED_CACHE_DIMENSIONS}
    items: list[dict[str, Any]] = []
    if path.is_symlink() or path.parent.is_symlink() or not path.is_file():
        failures.append("Canonical personal-rediscovery.v1/state.json is missing or unsafe.")
        return report, items, files
    try:
        if not 1 <= path.stat().st_size <= 8 * 1_024 * 1_024:
            raise ValueError("state exceeds the 8 MiB production bound")
        state = json.loads(path.read_text(encoding="utf-8-sig"))
        if not isinstance(state, dict):
            raise ValueError("state is not an object")
    except (OSError, ValueError) as error:
        failures.append(f"Canonical personal state is invalid: {error}")
        return report, items, files

    def require(condition: bool, message: str) -> None:
        if not condition:
            failures.append("Personal rediscovery " + message)

    require(type(state.get("schemaVersion")) is int and state["schemaVersion"] == 1,
            "has an unsupported schemaVersion.")
    require(state.get("sourceID") == PERSONAL_SOURCE_ID, "has a nonpersonal sourceID.")
    require(valid_uuid(state.get("eligibilityRevision")), "has no valid authority revision.")
    require(state.get("isAuthorized") is True, "authority is not ready after the smoke scan.")
    require(isinstance(state.get("scopeIdentifier"), str) and bool(state["scopeIdentifier"]),
            "has no persisted source scope.")
    updated_at = state.get("updatedAt")
    require(finite_number(updated_at), "has no valid updatedAt.")
    now = updated_at if finite_number(updated_at) else 0.0
    if finite_number(observed_at):
        now = max(now, observed_at - SWIFT_REFERENCE_EPOCH)
    raw_eligible = state.get("eligiblePhotoIDs")
    eligible = set()
    if isinstance(raw_eligible, list) and all(isinstance(value, str) and value for value in raw_eligible):
        eligible = set(raw_eligible)
        require(len(eligible) == len(raw_eligible), "authority repeats photo IDs.")
    else:
        require(False, "has malformed eligiblePhotoIDs.")
    versions = state.get("modificationDates")
    if not isinstance(versions, dict) or not all(
        key in eligible and finite_number(value) for key, value in versions.items()
    ):
        require(False, "has invalid source modification dates.")
        versions = {}

    references: set[str] = set()
    candidate_ids: set[str] = set()
    filename_owners: dict[str, str] = {}

    def inspect_item(item: Any, label: str, *, live: bool) -> None:
        if not isinstance(item, dict):
            require(False, f"{label} has no manifest item.")
            return
        photo_id = item.get("localIdentifier")
        require(isinstance(photo_id, str) and bool(photo_id), f"{label} has no photo ID.")
        if not isinstance(photo_id, str) or not photo_id:
            return
        if live:
            require(photo_id in eligible, f"{label} is outside the current personal authority.")
            if snapshot_photo_ids is not None:
                require(photo_id in snapshot_photo_ids, f"{label} has no PhotoKit snapshot record.")
            if photo_id in versions:
                require(item.get("sourceModificationDate") == versions[photo_id],
                        f"{label} uses an obsolete photo revision.")
            require(item.get("rendererVersion") == expected_renderer,
                    f"{label} uses an unexpected renderer version.")
        require(finite_number(item.get("scheduledDate")), f"{label} has no scheduled date.")
        filenames = item.get("cacheFilenames")
        if not isinstance(filenames, dict):
            require(False, f"{label} has no three-size cache references.")
            return
        names = [filenames.get(variant) for variant in EXPECTED_CACHE_DIMENSIONS]
        safe = all(safe_cache_filename(name) for name in names)
        require(safe, f"{label} has an unsafe cache filename.")
        if not safe:
            return
        require(len(set(names)) == 3, f"{label} repeats a cache file across sizes.")
        require(item.get("cacheFilename") == filenames["small"], f"{label} legacy filename is not its small image.")
        if live:
            items.append(item)
            references.update(names)
            for variant, filename in zip(EXPECTED_CACHE_DIMENSIONS, names):
                require(filename not in filename_owners or filename_owners[filename] == photo_id,
                        f"{label} shares a cache filename with another photo.")
                filename_owners[filename] = photo_id
                files[variant].add(cache / filename)
            plans = item.get("renderPlans")
            require(isinstance(plans, dict) and all(
                isinstance(plans.get(variant), dict)
                and plans[variant].get("compositionMode") in (
                    "cat-full-bleed", "medium-upper-focus", "blurred-fit-fallback",
                ) for variant in EXPECTED_CACHE_DIMENSIONS
            ), f"{label} has no valid three-size render plans.")

    candidates = state.get("candidates")
    if not isinstance(candidates, list):
        require(False, "candidates is not an array.")
        candidates = []
    report["candidateCount"] = len(candidates)
    require(1 <= len(candidates) <= 100, f"contains {len(candidates)} candidates; expected 1-100.")
    for index, candidate in enumerate(candidates):
        if not isinstance(candidate, dict):
            require(False, f"candidate {index} is malformed.")
            continue
        item = candidate.get("item")
        inspect_item(item, f"candidate {index}", live=True)
        require(finite_number(candidate.get("preparedAt")), f"candidate {index} has no preparation date.")
        if isinstance(item, dict) and isinstance(item.get("localIdentifier"), str):
            identifier = item["localIdentifier"]
            require(identifier not in candidate_ids, "candidate pool repeats a photo ID.")
            candidate_ids.add(identifier)
    if detected_fixture_ids is not None:
        require(bool(candidate_ids.intersection(detected_fixture_ids)), "pool contains no detected imported fixture.")

    plan = state.get("plan")
    if not isinstance(plan, dict):
        require(False, "has no persisted rotation plan.")
    else:
        require(valid_uuid(plan.get("id")), "rotation plan has no valid ID.")
        require(finite_number(plan.get("anchor")), "rotation plan has no finite anchor.")
        require(finite_number(plan.get("interval")) and 60 <= plan["interval"] <= 86_400,
                "rotation interval is outside production bounds.")
        require(type(plan.get("seed")) is int and 0 <= plan["seed"] < 2**64,
                "rotation plan has no fixed UInt64 seed.")
        cycles = plan.get("cycles")
        if not isinstance(cycles, list):
            cycles = []
        report["cycleCount"] = len(cycles)
        require(1 <= len(cycles) <= 2, "rotation plan must retain one or two cycles.")
        previous_end = None
        previous_index = None
        for index, cycle in enumerate(cycles):
            if not isinstance(cycle, dict):
                require(False, f"cycle {index} is malformed.")
                continue
            start, ordinal, order = cycle.get("startSlot"), cycle.get("index"), cycle.get("order")
            valid_start = type(start) is int and start >= 0
            valid_index = type(ordinal) is int and ordinal >= 0
            require(valid_start and valid_index, f"cycle {index} has invalid indices.")
            valid_order = isinstance(order, list) and 1 <= len(order) <= 100 and all(isinstance(value, str) and value for value in order)
            require(valid_order, f"cycle {index} has no bounded photo order.")
            if valid_start and valid_index and valid_order:
                if previous_end is not None:
                    require(start >= previous_end and ordinal > previous_index, "cycles overlap or go backwards.")
                previous_end, previous_index = start + len(order), ordinal
                if finite_number(plan.get("anchor")) and finite_number(plan.get("interval")) and plan["interval"] > 0:
                    slot = max(0, int((now - plan["anchor"]) // plan["interval"]))
                    require(all(value in candidate_ids for offset, value in enumerate(order) if start + offset >= slot),
                            f"cycle {index} has a future slot outside the prepared pool.")

    issues = state.get("issues")
    if not isinstance(issues, list):
        require(False, "issues is not an array.")
        issues = []
    report["issueCount"] = len(issues)
    require(len(issues) <= 3_000, "issue journal exceeds 3,000 entries.")
    issue_keys: set[tuple[str, str]] = set()
    for index, issue in enumerate(issues):
        if not isinstance(issue, dict):
            require(False, f"issue {index} is malformed.")
            continue
        photo_id, slot_id = issue.get("photoID"), issue.get("slotID")
        require(isinstance(photo_id, str) and isinstance(slot_id, str) and bool(slot_id), f"issue {index} lacks identity.")
        if isinstance(photo_id, str) and isinstance(slot_id, str):
            require((slot_id, photo_id) not in issue_keys, "journal repeats an issued photo/slot.")
            issue_keys.add((slot_id, photo_id))
        dates_valid = all(finite_number(issue.get(key)) for key in ("scheduledAt", "issuedAt", "leaseUntil"))
        require(dates_valid, f"issue {index} has invalid dates.")
        names = issue.get("cacheFilenames")
        if not isinstance(names, list) or not names or not all(safe_cache_filename(name) for name in names):
            require(False, f"issue {index} has unsafe cache references.")
            continue
        if dates_valid:
            require(issue["leaseUntil"] >= issue["scheduledAt"], f"issue {index} lease expires before its slot.")
            # Canceled future selection usage can still have an outstanding file lease.
            if now < issue["leaseUntil"] and isinstance(photo_id, str) and photo_id in eligible:
                references.update(names)

    grants = state.get("grants")
    if not isinstance(grants, list):
        require(False, "grants is not an array.")
        grants = []
    report["grantCount"] = len(grants)
    grant_ids: set[str] = set()
    for index, grant in enumerate(grants):
        if not isinstance(grant, dict):
            require(False, f"grant {index} is malformed.")
            continue
        identifier = grant.get("id")
        require(valid_uuid(identifier) and identifier not in grant_ids, f"grant {index} has invalid/duplicate identity.")
        if isinstance(identifier, str):
            grant_ids.add(identifier)
        valid_dates = all(finite_number(grant.get(key)) for key in ("committedAt", "resultExpiresAt", "overrideUntil"))
        require(valid_dates, f"grant {index} has invalid dates.")
        if valid_dates:
            require(abs(grant["resultExpiresAt"] - grant["committedAt"] - 48 * 60 * 60) < 0.001,
                    f"grant {index} does not retain its result for 48 hours.")
            require(grant["committedAt"] < grant["overrideUntil"] <= grant["resultExpiresAt"],
                    f"grant {index} has an invalid manual override.")
        for item_key, id_key, invalidated_key in (
            ("resultItem", "photoID", "resultInvalidated"),
            ("previousItem", "previousPhotoID", "previousInvalidated"),
        ):
            item = grant.get(item_key)
            photo_id = grant.get(id_key)
            require(isinstance(item, dict) and item.get("localIdentifier") == photo_id,
                    f"grant {index} {item_key} does not match its bound photo ID.")
            require(type(grant.get(invalidated_key)) is bool, f"grant {index} lacks explicit invalidation state.")
            live = valid_dates and now < grant["resultExpiresAt"] and grant.get(invalidated_key) is False and isinstance(photo_id, str) and photo_id in eligible
            inspect_item(item, f"grant {index} {item_key}", live=live)
    operations = state.get("operations")
    require(isinstance(operations, list) and len(operations) <= 10_000, "operation journal is not bounded.")
    if isinstance(operations, list):
        operation_ids: set[str] = set()
        for operation in operations:
            valid = isinstance(operation, dict) and valid_uuid(operation.get("id")) and isinstance(operation.get("grantID"), str) and operation["grantID"] in grant_ids and finite_number(operation.get("createdAt"))
            require(valid, "operation has no valid committed result.")
            if valid:
                require(operation["id"] not in operation_ids, "operation ID was recorded twice.")
                operation_ids.add(operation["id"])
    if grants or state.get("nextAvailableAt") is not None:
        require(finite_number(state.get("nextAvailableAt")), "daily quota has no nextAvailableAt.")

    report["liveReferenceCount"] = len(references)
    require(len(references) <= 400, f"retains {len(references)} live JPEG references; cap is 400.")
    if cache.is_symlink() or not cache.is_dir():
        require(False, "cache directory is missing or unsafe.")
        return report, items, files
    actual_files: dict[str, Path] = {}
    for image_path in cache.iterdir():
        if image_path.is_symlink() or image_path.is_dir():
            require(False, "cache contains a symlink or nested directory.")
            continue
        if image_path.suffix.lower() in {".jpg", ".jpeg"}:
            actual_files[image_path.name] = image_path
    report["actualJPEGCount"] = len(actual_files)
    require(len(actual_files) <= 400, f"cache contains {len(actual_files)} JPEGs; cap is 400.")
    require(references.issubset(actual_files), "live references include missing JPEG files.")
    reverse_dimensions = {size: variant for variant, size in EXPECTED_CACHE_DIMENSIONS.items()}
    for filename, image_path in actual_files.items():
        try:
            size = image_path.stat().st_size
            report["actualJPEGBytes"] += size
            dimensions = jpeg_dimensions(image_path)
            variant = reverse_dimensions.get(dimensions)
            require(variant is not None, f"cache JPEG {filename} is unreadable or has an invalid canvas.")
            for bound_variant, bound_files in files.items():
                if image_path in bound_files:
                    require(dimensions == EXPECTED_CACHE_DIMENSIONS[bound_variant],
                            f"cache JPEG {filename} does not match its bound {bound_variant} canvas.")
            if variant is not None:
                require(4 <= size <= MAXIMUM_CACHE_BYTES[variant], f"cache JPEG {filename} exceeds its {variant} byte budget.")
                if filename in references:
                    files[variant].add(image_path)
        except OSError as error:
            require(False, f"cache JPEG {filename} is not readable: {error}")
    return report, items, files


def timeline_entry_limit(
    provider_source_path: Path, failures: list[str]
) -> tuple[int, dict[str, bool]]:
    """Read the provider's hard cap and prove that it bounds the returned schedule."""
    try:
        source = provider_source_path.read_text(encoding="utf-8")
    except OSError as error:
        failures.append(f"Timeline provider source could not be read: {error}")
        return 0, {
            "twoEntryPrefix": False,
            "manifestAnchorSchedule": False,
            "afterReloadPolicy": False,
        }

    declarations = re.findall(
        r"\bmaximumTimelineEntryCount\s*=\s*([0-9][0-9_]*)\b",
        source,
    )
    if len(declarations) != 1:
        failures.append(
            "Timeline provider must declare maximumTimelineEntryCount exactly once."
        )
        return 0, {
            "twoEntryPrefix": False,
            "manifestAnchorSchedule": False,
            "afterReloadPolicy": False,
        }

    limit = int(declarations[0].replace("_", ""))
    if limit != 2:
        failures.append(
            "Timeline provider returns an unsafe number of entries "
            f"({limit}); expected the two-entry hard cap."
        )

    bounded_prefix = re.search(
        r"\.prefix\(\s*Self\.maximumTimelineEntryCount\s*\)",
        source,
    )
    anchor_declaration = re.search(
        r"let\s+anchor\s*=\s*items\s*\[\s*0\s*\]\.scheduledDate",
        source,
    )
    anchor_elapsed = re.search(
        r"now\.timeIntervalSince\(\s*anchor\s*\)",
        source,
    )
    anchor_reload = re.search(
        r"let\s+reloadDate\s*=\s*anchor\.addingTimeInterval\(",
        source,
    )
    after_policy = re.search(
        r"Timeline\(\s*entries:\s*entries\s*,\s*policy:\s*\.after\(\s*reloadDate\s*\)\s*\)",
        source,
    )
    checks = {
        "twoEntryPrefix": bounded_prefix is not None,
        "manifestAnchorSchedule": all(
            value is not None
            for value in (anchor_declaration, anchor_elapsed, anchor_reload)
        ),
        "afterReloadPolicy": after_policy is not None,
        "personalPlanResolution": re.search(r"PersonalRediscoveryStore\.shared\.issueTimeline\(", source) is not None,
        "personalPlanTwoEntryPrefix": re.search(r"plan\.entries\.prefix\(\s*Self\.maximumTimelineEntryCount\s*\)", source) is not None,
        "personalPlanAfterPolicy": re.search(r"policy:\s*\.after\(\s*plan\.reloadDate\s*\)", source) is not None,
    }
    if not checks["twoEntryPrefix"]:
        failures.append(
            "Timeline provider does not apply its two-entry cap with prefix()."
        )
    if not checks["manifestAnchorSchedule"]:
        failures.append(
            "Timeline provider transition/reload dates are not anchored to the "
            "manifest schedule."
        )
    if not checks["afterReloadPolicy"]:
        failures.append(
            "Timeline provider does not request its bounded refill with an "
            "after(reloadDate) policy."
        )
    if not all(checks[key] for key in (
        "personalPlanResolution", "personalPlanTwoEntryPrefix", "personalPlanAfterPolicy",
    )):
        failures.append("Personal plan output must resolve the shared timeline, cap its entries at two, and use its persisted reload date.")
    return limit, checks


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
    provider_source_path = (
        Path(__file__).resolve().parent.parent
        / "NekoWidgetWidget"
        / "NekoWidgetTimelineProvider.swift"
    )
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

    permission_entries = matching("Photo permission checked", "permission")
    if not any(
        entry.get("metadata", {}).get("status") == "authorized"
        for entry in permission_entries
    ):
        failures.append("Photo permission was not recorded as authorized.")

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
    expected_thumbnail_targets = {
        "localRecovery512": "512x512",
        "primary1024": "1024x1024",
        "highResolution2048": "2048x2048",
    }
    primary_thumbnail_loads = [
        entry
        for entry in thumbnail_load_entries
        if entry.get("metadata", {}).get("deliveryMode") == "primary1024"
    ]
    if len(primary_thumbnail_loads) < fixture_count:
        failures.append(
            f"Only {len(primary_thumbnail_loads)} sampled primary thumbnail "
            f"load(s) were recorded; expected at least {fixture_count}."
        )
    invalid_thumbnail_metadata = False
    for entry in thumbnail_load_entries:
        metadata = entry.get("metadata", {})
        delivery_mode = metadata.get("deliveryMode")
        target_pixels = metadata.get("targetPixels")
        output_match = re.fullmatch(
            r"([1-9][0-9]*)x([1-9][0-9]*)",
            metadata.get("outputPixels", ""),
        )
        expected_target = expected_thumbnail_targets.get(delivery_mode)
        if expected_target is None or target_pixels != expected_target:
            invalid_thumbnail_metadata = True
            break
        target_width, target_height = (
            int(component) for component in expected_target.split("x")
        )
        if output_match is None or (
            int(output_match.group(1)) > target_width
            or int(output_match.group(2)) > target_height
        ):
            invalid_thumbnail_metadata = True
            break
    if invalid_thumbnail_metadata:
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
    expected_widget_cache_algorithm = "cat-aware-full-bleed-v6"
    widget_cache_algorithms = sorted(
        {
            str(entry.get("metadata", {}).get("algorithm"))
            for entry in cache_entries
            if entry.get("metadata", {}).get("algorithm") is not None
        }
    )
    if expected_widget_cache_algorithm not in widget_cache_algorithms:
        failures.append(
            "Widget cache did not use the expected cat-aware full-bleed "
            f"algorithm ({expected_widget_cache_algorithm})."
        )
    current_cache_entries = [
        entry
        for entry in cache_entries
        if entry.get("metadata", {}).get("algorithm")
        == expected_widget_cache_algorithm
    ]
    composition_metadata_keys = {
        "catFullBleed": "compositionGeneratedCatFullBleed",
        "mediumUpperFocus": "compositionGeneratedMediumUpperFocus",
        "blurredFitFallback": "compositionGeneratedBlurredFitFallback",
    }
    generated_compositions = {
        name: sum(integer_metadata(entry, metadata_key) for entry in current_cache_entries)
        for name, metadata_key in composition_metadata_keys.items()
    }
    if (
        generated_compositions["catFullBleed"]
        + generated_compositions["mediumUpperFocus"]
        < 1
    ):
        failures.append(
            "No sharp full-bleed Widget composition was generated for the fixtures."
        )
    margin_fallback_denominator = sum(
        integer_metadata(entry, "marginFallbackDenominator")
        for entry in current_cache_entries
    )
    current_8_fallback = sum(
        integer_metadata(entry, "current8Fallback") for entry in current_cache_entries
    )
    legacy_18_fallback = sum(
        integer_metadata(entry, "legacy18Fallback") for entry in current_cache_entries
    )
    if margin_fallback_denominator < 1:
        failures.append(
            "The 8% vs 18% Small/Large fallback comparison had no generated candidates."
        )
    if not (
        0 <= current_8_fallback <= legacy_18_fallback <= margin_fallback_denominator
    ):
        failures.append(
            "The same-candidate fallback counters are inconsistent "
            f"(8%={current_8_fallback}, 18%={legacy_18_fallback}, "
            f"denominator={margin_fallback_denominator})."
        )
    current_8_fallback_rate = (
        current_8_fallback / margin_fallback_denominator
        if margin_fallback_denominator
        else 0.0
    )
    legacy_18_fallback_rate = (
        legacy_18_fallback / margin_fallback_denominator
        if margin_fallback_denominator
        else 0.0
    )
    render_upscaled_by_variant = {
        variant: sum(
            integer_metadata(entry, f"renderUpscaled{variant.capitalize()}")
            for entry in current_cache_entries
        )
        for variant in ("small", "medium", "large")
    }
    source_pixel_ranges = sorted(
        {
            str(value)
            for entry in current_cache_entries
            if (value := entry.get("metadata", {}).get("inputPixelsMax"))
        }
    )
    maximum_render_scale = max(
        (float_metadata(entry, "renderScaleMax") for entry in current_cache_entries),
        default=0.0,
    )
    maximum_input_decoded_bytes = max(
        (
            integer_metadata(entry, "inputDecodedBytesMax")
            for entry in current_cache_entries
        ),
        default=0,
    )
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

    if not 1 <= len(manifest_items) <= 20:
        failures.append(
            f"Widget manifest contains {len(manifest_items)} entries; expected 1-20 unique photos."
        )
    photo_identifiers = [item.get("localIdentifier") for item in manifest_items]
    if not all(isinstance(value, str) and value for value in photo_identifiers):
        failures.append("Widget manifest contains a missing photo identifier.")
    elif len(set(photo_identifiers)) != len(photo_identifiers):
        failures.append("Widget manifest pads the rotation with duplicate photos.")

    cache_directory = group_container / "widget-cache"
    referenced_cache_files: set[Path] = set()
    cache_files_by_variant: dict[str, set[Path]] = {
        "small": set(),
        "medium": set(),
        "large": set(),
    }
    expected_cache_dimensions = EXPECTED_CACHE_DIMENSIONS
    maximum_cache_bytes = MAXIMUM_CACHE_BYTES
    personal_state_report, personal_items, personal_files = validate_personal_state(
        group_container, expected_widget_cache_algorithm, failures,
        observed_at=max((entry_timestamp(entry) or 0 for entry in entries), default=0),
        snapshot_photo_ids={asset["localIdentifier"] for asset in snapshot_assets
                            if isinstance(asset.get("localIdentifier"), str)},
        detected_fixture_ids={asset["localIdentifier"] for asset in fixture_assets
                              if isinstance(asset.get("localIdentifier"), str)
                              and asset.get("analysisStatus") == "detected"},
    )
    for variant, paths in personal_files.items():
        cache_files_by_variant[variant].update(paths)
        referenced_cache_files.update(paths)
    for item in manifest_items + personal_items:
        legacy_filename = item.get("cacheFilename")
        filenames = item.get("cacheFilenames")
        if not isinstance(filenames, dict):
            failures.append("Widget manifest has no family-specific cache filenames.")
            continue

        variant_filenames: dict[str, str] = {}
        for variant in expected_cache_dimensions:
            filename = filenames.get(variant)
            if (
                not safe_cache_filename(filename)
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
    oversized_cache_files: list[str] = []
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
        oversized_cache_files.extend(
            f"{variant}:{filename}"
            for filename, byte_count in byte_counts.items()
            if byte_count > maximum_cache_bytes[variant]
        )
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
    if oversized_cache_files:
        failures.append(
            "Widget cache files exceed their family byte budgets: "
            + ", ".join(sorted(oversized_cache_files))
        )

    decoded_row_alignment_bytes = 16
    decoded_row_bytes_by_variant = {
        variant: aligned_byte_count(width * 4, decoded_row_alignment_bytes)
        for variant, (width, _) in expected_cache_dimensions.items()
    }
    decoded_bytes_by_variant = {
        variant: decoded_row_bytes_by_variant[variant] * height
        for variant, (width, height) in expected_cache_dimensions.items()
    }
    maximum_widget_decode_bytes = max(decoded_bytes_by_variant.values())
    widget_decode_budget_bytes = 5 * 1_024 * 1_024
    if maximum_widget_decode_bytes > widget_decode_budget_bytes:
        failures.append(
            "A family canvas exceeds the one-image Widget decode budget "
            f"({maximum_widget_decode_bytes} > {widget_decode_budget_bytes})."
        )

    maximum_timeline_entry_count, timeline_provider_static_checks = timeline_entry_limit(
        provider_source_path,
        failures,
    )
    # Keep each family's decoded timeline payload below 10 MiB. The arithmetic
    # is deliberately conservative about row padding but remains only a static
    # estimate: headless CI does not place Widgets or measure extension RSS.
    observed_widget_process_guardrail_bytes = 30 * 1_024 * 1_024
    family_timeline_decode_budget_bytes = 10 * 1_024 * 1_024
    simultaneous_three_family_decode_budget_bytes = 20 * 1_024 * 1_024
    family_timeline_decoded_bytes = {
        variant: decoded_bytes * maximum_timeline_entry_count
        for variant, decoded_bytes in decoded_bytes_by_variant.items()
    }
    simultaneous_three_family_decoded_bytes = sum(
        family_timeline_decoded_bytes.values()
    )
    simultaneous_three_family_arithmetic_headroom_bytes = (
        observed_widget_process_guardrail_bytes
        - simultaneous_three_family_decoded_bytes
    )
    unsafe_family_timeline_decodes = {
        variant: decoded_bytes
        for variant, decoded_bytes in family_timeline_decoded_bytes.items()
        if decoded_bytes > family_timeline_decode_budget_bytes
    }
    if unsafe_family_timeline_decodes:
        description = ", ".join(
            f"{variant}={decoded_bytes}"
            for variant, decoded_bytes in sorted(
                unsafe_family_timeline_decodes.items()
            )
        )
        failures.append(
            "Family Timeline decoded-image estimates exceed the 10 MiB safety "
            f"budget: {description}."
        )
    if (
        simultaneous_three_family_decoded_bytes
        > simultaneous_three_family_decode_budget_bytes
    ):
        failures.append(
            "The simultaneous three-family decoded-image estimate exceeds the "
            "20 MiB static safety budget "
            f"({simultaneous_three_family_decoded_bytes} > "
            f"{simultaneous_three_family_decode_budget_bytes})."
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
        "sampledThumbnailLoads": len(thumbnail_load_entries),
        "baselineAssetCount": len(baseline_identifiers),
        "importedFixtureAssetCount": len(fixture_assets),
        "snapshotTotalAssets": int(scan_state.get("totalAssets", 0) or 0),
        "snapshotCatAssets": int(scan_state.get("catAssets", 0) or 0),
        "importedFixtureStatuses": fixture_asset_statuses,
        "manifestEntryCount": len(manifest_items),
        "widgetCacheAlgorithms": widget_cache_algorithms,
        "expectedWidgetCacheAlgorithm": expected_widget_cache_algorithm,
        "generatedWidgetCompositions": generated_compositions,
        "fallbackMarginComparison": {
            "scope": (
                "all generated Small/Large files in this CI smoke run; each 8%/18% "
                "pair uses the same source image, bounding box, and canvas"
            ),
            "denominator": margin_fallback_denominator,
            "current8Fallback": current_8_fallback,
            "current8Rate": current_8_fallback_rate,
            "legacy18Fallback": legacy_18_fallback,
            "legacy18Rate": legacy_18_fallback_rate,
            "absoluteRateChange": current_8_fallback_rate - legacy_18_fallback_rate,
        },
        "renderUpscaledByVariant": render_upscaled_by_variant,
        "sourcePixelRanges": source_pixel_ranges,
        "maximumRenderScale": maximum_render_scale,
        "maximumInputDecodedBytesEstimate": maximum_input_decoded_bytes,
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
        "maximumCacheBytesByVariant": maximum_cache_bytes,
        "decodedRowAlignmentBytes": decoded_row_alignment_bytes,
        "decodedRowBytesByVariant": decoded_row_bytes_by_variant,
        "decodedBytesEstimateByVariant": decoded_bytes_by_variant,
        "maximumWidgetDecodeBytesEstimate": maximum_widget_decode_bytes,
        "widgetDecodeBudgetBytes": widget_decode_budget_bytes,
        "timelineStaticBudget": {
            "providerSource": "NekoWidgetWidget/NekoWidgetTimelineProvider.swift",
            "maximumEntryCount": maximum_timeline_entry_count,
            "providerStaticChecks": timeline_provider_static_checks,
            "familyDecodedBytesEstimate": family_timeline_decoded_bytes,
            "familyDecodedBytesBudget": family_timeline_decode_budget_bytes,
            "simultaneousThreeFamilyDecodedBytesBudget": (
                simultaneous_three_family_decode_budget_bytes
            ),
            "observedWidgetProcessGuardrail": observed_widget_process_guardrail_bytes,
            "simultaneousThreeFamilyDecodedBytesEstimate": (
                simultaneous_three_family_decoded_bytes
            ),
            "simultaneousThreeFamilyArithmeticHeadroom": (
                simultaneous_three_family_arithmetic_headroom_bytes
            ),
            "unsafeFamilies": sorted(unsafe_family_timeline_decodes),
            "scope": (
                "static estimate from provider entry cap, generated family canvas "
                "dimensions, and 16-byte decoded row alignment; the three-family "
                "aggregate/headroom is not a WidgetKit runtime safety proof"
            ),
        },
        "personalRediscovery": personal_state_report,
        "retainedCacheWorstCaseBytes": 400 * 220 * 1_024,
        "oversizedCacheFiles": oversized_cache_files,
        "failures": failures,
        "notes": [
            "Deferred or failed baseline assets are allowed "
            "because the hosted Simulator ships old sample records without "
            "local image resources.",
            "Widget JSONL is optional because adding a widget to the simulated "
            "Home Screen is outside this headless smoke test.",
            "Timeline decoded-byte checks are static fail-fast estimates. The "
            "Simulator smoke test does not render an installed Widget timeline "
            "or enforce the iPhone Widget extension memory limit.",
            "The simultaneous three-family aggregate and arithmetic headroom "
            "exclude WidgetKit, SwiftUI, ImageIO transient copies, and other "
            "process memory; they are diagnostics, not a safety proof."
        ],
    }
    report_path.parent.mkdir(parents=True, exist_ok=True)
    timeline_budget_path = report_path.with_name("widget-timeline-budget.json")
    timeline_budget_path.write_text(
        json.dumps(
            report["timelineStaticBudget"],
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    summary_path = report_path.with_name("widget-composition-summary.md")
    summary_path.write_text(
        "\n".join(
            [
                "# Widget composition summary",
                "",
                "The fallback comparison covers generated Small/Large files in this CI "
                "smoke run. Each 8%/18% pair uses the same source, bounding box, and "
                "canvas. It is not an estimate for a real photo library.",
                "",
                "| Margin | Fallback | Evaluated | Rate |",
                "| --- | ---: | ---: | ---: |",
                f"| 8% (Build 8) | {current_8_fallback} | "
                f"{margin_fallback_denominator} | {current_8_fallback_rate:.1%} |",
                f"| 18% (shadow baseline) | {legacy_18_fallback} | "
                f"{margin_fallback_denominator} | {legacy_18_fallback_rate:.1%} |",
                "",
                f"Absolute change: {(current_8_fallback_rate - legacy_18_fallback_rate):.1%}",
                "",
                f"Loaded source pixel ranges: {', '.join(source_pixel_ranges) or 'cached-only'}",
                f"Maximum render scale: {maximum_render_scale:.4f}x",
                f"Maximum app-side source decode observed: "
                f"{maximum_input_decoded_bytes / (1024 * 1024):.2f} MiB",
                "",
                f"Provider Timeline entry cap: {maximum_timeline_entry_count}",
                f"Family Timeline decoded-image safety budget: "
                f"{family_timeline_decode_budget_bytes / (1024 * 1024):.2f} MiB",
                f"Three-family simultaneous decode estimate: "
                f"{simultaneous_three_family_decoded_bytes / (1024 * 1024):.2f} MiB",
                f"Three-family static decode safety budget: "
                f"{simultaneous_three_family_decode_budget_bytes / (1024 * 1024):.2f} MiB",
                f"Arithmetic headroom to 30 MiB: "
                f"{simultaneous_three_family_arithmetic_headroom_bytes / (1024 * 1024):.2f} MiB",
                "",
                "| Family | Canvas | 16-byte row | Max JPEG | One-image decode | "
                "Max-Timeline decode | Render-upscaled CI files |",
                "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
                *[
                    f"| {variant} | {width}x{height} | "
                    f"{decoded_row_bytes_by_variant[variant]} B | "
                    f"{maximum_cache_bytes[variant] / 1024:.0f} KiB | "
                    f"{decoded_bytes_by_variant[variant] / (1024 * 1024):.2f} MiB | "
                    f"{family_timeline_decoded_bytes[variant] / (1024 * 1024):.2f} MiB | "
                    f"{render_upscaled_by_variant[variant]} |"
                    for variant, (width, height) in expected_cache_dimensions.items()
                ],
                "",
                "> CI validates the provider cap and generated artifacts statically. It does "
                "not place the Widget on the simulated Home Screen, render a real photo "
                "timeline, or measure Widget extension RSS/jetsam behavior.",
                "> The three-family aggregate/headroom excludes WidgetKit, SwiftUI, "
                "ImageIO transient copies, and other process memory. It is not a runtime "
                "safety proof.",
                "",
            ]
        ),
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
