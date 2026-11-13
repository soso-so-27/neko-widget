#!/usr/bin/env python3
"""Turn ReviewScreenshotUITests attachments into named PNGs and an index.

Usage:
  collect-review-screenshots.py collect --set light --output DIR BUNDLE.xcresult [...]
  collect-review-screenshots.py index DIR

`collect` exports the attachments of each result bundle (later bundles win,
so a retried test replaces the first try), copies every
`review-shot__<name>__end` to `<set>/<name>.png`, the screen at a miss to
`<set>/missing/<name>.png`, and writes `index-<set>.txt`. Every expected
name that has no capture is listed as MISSING with its reason.
`index` joins the per-set parts into `index.txt` and removes the parts.
Nothing else from the runner (logs, hierarchies, result bundles) is copied.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

# Every screen ReviewScreenshotUITests captures, in review order.
FULL_SCREENS = (
    "01_photos_top", "01_photos_scrolled", "02_photo_detail", "03_memo_editor",
    "04_windows_list", "05_window_feed_top", "05_window_feed_bottom", "06_window_send",
    "07_album_shelf_plus", "08_album_nonmember", "08b_album_nonmember_work_gate", "09_album_work_open",
    "10_cat_home", "10b_cat_home_second_cat", "10c_cat_home_no_cat", "10d_cat_home_no_photo",
    "10e_cat_home_records",
    "11_cat_care_top", "11_cat_care_bottom", "11b_cat_care_text_page",
    "12_vet_top", "12_vet_bottom", "12b_vet_row_page", "13_vet_read",
    "14_lost_top", "14_lost_bottom", "14b_lost_photo_page", "15_lost_preview",
    "16_care_top", "16_care_bottom", "17_care_done",
    "18_evac_top", "18_evac_bottom", "19_evac_now", "20_evac_packing", "21_evac_memo", "22_showcase",
    "23_plus_offer_top", "23_plus_offer_bottom", "23b_plus_offer_from_work", "23c_plus_offer_onboarding",
    "24_settings_top", "24_settings_bottom", "25_settings_photos", "26_autosave", "27_family_notebook",
    "28_onboarding_1", "28_onboarding_2", "28_onboarding_2b_photos_prompt", "28_onboarding_3_scan_found", "28_onboarding_4_scan_zero",
    "28_onboarding_5_widget_guide",
    "29_widget_guide_1", "29_widget_guide_2", "29_widget_guide_3", "29_widget_guide_4", "29_widget_guide_5",
    "90_error_vet_field_page", "90_error_vet_row", "91_error_plus_product_unavailable",
)
SE_SCREENS = (
    "10_cat_home", "10b_cat_home_second_cat", "10c_cat_home_no_cat", "10d_cat_home_no_photo",
    "10e_cat_home_records",
    "11_cat_care_top", "12_vet_bottom", "14_lost_bottom", "16_care_bottom",
    "23_plus_offer_top", "23_plus_offer_bottom", "24_settings_top", "28_onboarding_1",
)
EXPECTED = {"light": FULL_SCREENS, "dark": FULL_SCREENS, "se": SE_SCREENS}
MARKER = re.compile(r"review-(shot|missing|debug)__([A-Za-z0-9_]+?)__end")
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def png_size(path: Path) -> tuple[int, int] | None:
    data = path.read_bytes()[:24]
    if len(data) < 24 or not data.startswith(PNG_SIGNATURE):
        return None
    return struct.unpack(">II", data[16:24])


def records(node):
    """Every dict in the manifest that names one exported file."""
    if isinstance(node, dict):
        if "exportedFileName" in node:
            yield node
        for value in node.values():
            yield from records(value)
    elif isinstance(node, list):
        for value in node:
            yield from records(value)


def attachments(export_directory: Path):
    for manifest in export_directory.rglob("manifest.json"):
        for record in records(json.loads(manifest.read_text(encoding="utf-8"))):
            exported = manifest.parent / str(record["exportedFileName"])
            text = " ".join(str(value) for value in record.values() if isinstance(value, str))
            match = MARKER.search(text)
            if match and exported.is_file():
                yield match.group(1), match.group(2), exported


def collect(review_set: str, output: Path, bundles: list[Path]) -> int:
    expected = EXPECTED[review_set]
    shots: dict[str, Path] = {}
    debug: dict[str, Path] = {}
    reasons: dict[str, str] = {}
    with tempfile.TemporaryDirectory() as temporary:
        for index, bundle in enumerate(bundles):
            if not bundle.is_dir():
                continue
            export = Path(temporary) / f"bundle-{index}"
            export.mkdir()
            result = subprocess.run(
                ["xcrun", "xcresulttool", "export", "attachments",
                 "--path", str(bundle), "--output-path", str(export)],
                capture_output=True, text=True)
            if result.returncode != 0:
                print(f"Could not export {bundle.name}: {result.stderr.strip()[:300]}", file=sys.stderr)
                continue
            found: dict[str, Path] = {}
            for kind, name, path in attachments(export):
                if kind == "shot" and png_size(path):
                    found[name] = path
                elif kind == "debug" and png_size(path):
                    debug[name] = path
                elif kind == "missing":
                    reasons[name] = path.read_text(encoding="utf-8", errors="replace").splitlines()[0][:200]
            # A later bundle (a retry) replaces the earlier capture of a name.
            shots.update(found)
            for name in found:
                reasons.pop(name, None)
            # Copy now: the temporary export disappears with this block.
            destination = output / review_set
            destination.mkdir(parents=True, exist_ok=True)
            for name, path in found.items():
                shutil.copyfile(path, destination / f"{name}.png")
            for name, path in list(debug.items()):
                if name in shots:
                    continue
                (destination / "missing").mkdir(exist_ok=True)
                shutil.copyfile(path, destination / "missing" / f"{name}.png")
            debug.clear()

    destination = output / review_set
    destination.mkdir(parents=True, exist_ok=True)
    for name in shots:
        stale = destination / "missing" / f"{name}.png"
        if stale.exists():
            stale.unlink()
    missing_directory = destination / "missing"
    if missing_directory.is_dir() and not any(missing_directory.iterdir()):
        missing_directory.rmdir()

    lines = []
    for name in expected:
        png = destination / f"{name}.png"
        if png.is_file():
            width, height = png_size(png) or (0, 0)
            lines.append(f"captured  {review_set}/{name}.png  {width}x{height}")
        else:
            reason = reasons.get(name, "not attempted (the test stopped before this screen)")
            lines.append(f"MISSING   {review_set}/{name}  {reason}")
    for name in sorted(shots):
        if name not in expected:
            lines.append(f"extra     {review_set}/{name}.png")
    if missing_directory.is_dir():
        for path in sorted(missing_directory.glob("*.png")):
            lines.append(f"debug     {review_set}/missing/{path.name}  (screen at the miss)")
    (output / f"index-{review_set}.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    captured = sum(1 for line in lines if line.startswith("captured"))
    print(f"{review_set}: {captured} of {len(expected)} captured")
    return captured


def build_index(directory: Path) -> None:
    parts = sorted(directory.glob("index-*.txt"))
    body = []
    captured = missing = 0
    for part in parts:
        text = part.read_text(encoding="utf-8")
        captured += sum(1 for line in text.splitlines() if line.startswith("captured"))
        missing += sum(1 for line in text.splitlines() if line.startswith("MISSING"))
        body.append(text.rstrip("\n"))
        part.unlink()
    sets = ", ".join(part.stem.removeprefix("index-") for part in parts) or "(none)"
    header = [
        "ねこのまど review screenshots (synthetic fixtures only)",
        f"sets: {sets}",
        f"captured: {captured}  MISSING: {missing}",
        "",
    ]
    (directory / "index.txt").write_text("\n".join(header + body) + "\n", encoding="utf-8")
    for path in directory.rglob("*"):
        if path.is_file() and path.name != "index.txt" and path.suffix.lower() != ".png":
            path.unlink()
    print("\n".join(header))


def main() -> int:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    collect_command = commands.add_parser("collect")
    collect_command.add_argument("--set", required=True, choices=sorted(EXPECTED))
    collect_command.add_argument("--output", required=True, type=Path)
    collect_command.add_argument("bundles", nargs="+", type=Path)
    index_command = commands.add_parser("index")
    index_command.add_argument("directory", type=Path)
    arguments = parser.parse_args()
    if arguments.command == "collect":
        collect(arguments.set, arguments.output, arguments.bundles)
    else:
        build_index(arguments.directory)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
