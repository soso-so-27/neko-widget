#!/usr/bin/env bash

set -Eeuo pipefail

if (( $# != 2 )); then
    echo "Usage: $0 <test-result.xcresult> <new-output-directory>" >&2
    exit 2
fi

RESULT_BUNDLE="$1"
OUTPUT_DIRECTORY="$2"

if [[ ! -d "$RESULT_BUNDLE" ]]; then
    echo "Result bundle does not exist: $RESULT_BUNDLE" >&2
    exit 1
fi
if [[ -e "$OUTPUT_DIRECTORY" ]]; then
    echo "Refusing to overwrite an existing output path: $OUTPUT_DIRECTORY" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIRECTORY"
RAW_DIRECTORY="$OUTPUT_DIRECTORY/raw-attachments"
mkdir -p "$RAW_DIRECTORY"

xcrun xcresulttool export attachments \
    --path "$RESULT_BUNDLE" \
    --output-path "$RAW_DIRECTORY" \
    | tee "$OUTPUT_DIRECTORY/xcresulttool-export.log"

python3 - "$RAW_DIRECTORY" "$OUTPUT_DIRECTORY" <<'PY'
import hashlib
import json
import shutil
import struct
import sys
from pathlib import Path

raw_directory = Path(sys.argv[1]).resolve()
output_directory = Path(sys.argv[2]).resolve()

targets = [
    "onboarding-widget-step-1",
    "onboarding-widget-step-2-ios18",
    "onboarding-widget-step-3",
    "onboarding-widget-step-4",
]

png_files = [path for path in raw_directory.rglob("*") if path.is_file() and path.suffix.lower() == ".png"]
json_files = [path for path in raw_directory.rglob("*.json") if path.is_file()]


def all_strings(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for key, value in node.items():
            yield str(key)
            yield from all_strings(value)
    elif isinstance(node, list):
        for value in node:
            yield from all_strings(value)


def all_dicts(node):
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from all_dicts(value)
    elif isinstance(node, list):
        for value in node:
            yield from all_dicts(value)


manifests = []
for path in json_files:
    try:
        manifests.append((path, json.loads(path.read_text(encoding="utf-8"))))
    except (UnicodeDecodeError, json.JSONDecodeError):
        continue


def resolve_png_reference(reference, manifest_path):
    reference_path = Path(reference)
    direct_candidates = [
        raw_directory / reference_path,
        manifest_path.parent / reference_path,
    ]
    for candidate in direct_candidates:
        try:
            resolved = candidate.resolve()
            resolved.relative_to(raw_directory)
        except (OSError, ValueError):
            continue
        if resolved.is_file() and resolved.suffix.lower() == ".png":
            return resolved

    basename_matches = [path for path in png_files if path.name == reference_path.name]
    return basename_matches[0] if len(basename_matches) == 1 else None


def find_source(target):
    # Current xcresulttool versions normally preserve the attachment's human
    # readable name in the exported filename.
    filename_matches = [path for path in png_files if target in path.stem]
    if len(filename_matches) == 1:
        return filename_matches[0]
    if len(filename_matches) > 1:
        raise SystemExit(f"Multiple exported PNGs matched {target}: {filename_matches}")

    # If the payload filename is opaque, pair it through the smallest manifest
    # dictionary that contains both the attachment name and one PNG reference.
    manifest_matches = []
    for manifest_path, manifest in manifests:
        for record in all_dicts(manifest):
            strings = list(all_strings(record))
            if not any(target in value for value in strings):
                continue
            references = [value for value in strings if value.lower().endswith(".png")]
            resolved = {
                source
                for reference in references
                if (source := resolve_png_reference(reference, manifest_path)) is not None
            }
            if len(resolved) == 1:
                manifest_matches.extend(resolved)

    unique_matches = sorted(set(manifest_matches))
    if len(unique_matches) == 1:
        return unique_matches[0]
    if len(unique_matches) > 1:
        raise SystemExit(f"Manifest mapping for {target} was ambiguous: {unique_matches}")
    return None


def png_dimensions(path):
    with path.open("rb") as stream:
        signature = stream.read(8)
        if signature != b"\x89PNG\r\n\x1a\n":
            raise SystemExit(f"Not a PNG payload: {path}")
        chunk_length = struct.unpack(">I", stream.read(4))[0]
        chunk_type = stream.read(4)
        if chunk_type != b"IHDR" or chunk_length < 8:
            raise SystemExit(f"PNG has no valid IHDR: {path}")
        width, height = struct.unpack(">II", stream.read(8))
    return width, height


report = {"schemaVersion": 1, "screenshots": []}
for target in targets:
    source = find_source(target)
    if source is None:
        available = "\n".join(str(path.relative_to(raw_directory)) for path in png_files)
        raise SystemExit(
            f"Could not map XCTest attachment {target}. Exported PNGs:\n{available or '(none)'}"
        )

    width, height = png_dimensions(source)
    if width < 300 or height < 600 or height <= width:
        raise SystemExit(
            f"Unexpected Simulator screenshot dimensions for {target}: {width}x{height}"
        )

    destination = output_directory / f"{target}.png"
    shutil.copy2(source, destination)
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    report["screenshots"].append(
        {
            "attachmentName": target,
            "file": destination.name,
            "height": height,
            "sha256": digest,
            "source": str(source.relative_to(raw_directory)),
            "width": width,
        }
    )

(output_directory / "widget-guide-screenshot-manifest.json").write_text(
    json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)

print("Exported four real Simulator screenshots:")
for item in report["screenshots"]:
    print(f"- {item['file']}: {item['width']}x{item['height']} sha256={item['sha256'][:12]}")
PY
