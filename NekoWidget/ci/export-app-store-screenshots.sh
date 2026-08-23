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
if [[ ! -x /usr/bin/sips ]]; then
    echo "macOS sips is required to remove alpha and emit App Store JPEGs." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIRECTORY"
RAW_DIRECTORY="$OUTPUT_DIRECTORY/raw-attachments"
mkdir -p "$RAW_DIRECTORY"

xcrun xcresulttool export attachments \
    --path "$RESULT_BUNDLE" \
    --output-path "$RAW_DIRECTORY" \
    > "$OUTPUT_DIRECTORY/xcresulttool-export.log"

python3 - "$RAW_DIRECTORY" "$OUTPUT_DIRECTORY" <<'PY'
import hashlib
import json
import struct
import subprocess
import sys
from pathlib import Path

raw_directory = Path(sys.argv[1]).resolve()
output_directory = Path(sys.argv[2]).resolve()

targets = [
    "01-local-cat-widget",
    "02-local-photo-window",
    "03-organized-memories",
    "04-liked-photos",
    "05-on-device-photo-privacy",
]
accepted_portrait_sizes = {
    (1260, 2736),
    (1290, 2796),
    (1320, 2868),
}

png_files = [
    path
    for path in raw_directory.rglob("*")
    if path.is_file() and path.suffix.lower() == ".png"
]
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
    for candidate in (
        raw_directory / reference_path,
        manifest_path.parent / reference_path,
    ):
        try:
            resolved = candidate.resolve()
            resolved.relative_to(raw_directory)
        except (OSError, ValueError):
            continue
        if resolved.is_file() and resolved.suffix.lower() == ".png":
            return resolved

    matches = [path for path in png_files if path.name == reference_path.name]
    return matches[0] if len(matches) == 1 else None


def find_source(target):
    filename_matches = [path for path in png_files if target in path.stem]
    if len(filename_matches) == 1:
        return filename_matches[0]
    if len(filename_matches) > 1:
        raise SystemExit(f"Multiple exported PNGs matched {target}: {filename_matches}")

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


def jpeg_dimensions_and_app1(path):
    data = path.read_bytes()
    if not data.startswith(b"\xff\xd8"):
        raise SystemExit(f"Not a JPEG payload: {path}")

    offset = 2
    has_app1 = False
    dimensions = None
    while offset + 4 <= len(data):
        if data[offset] != 0xFF:
            offset += 1
            continue
        marker = data[offset + 1]
        offset += 2
        if marker in {0xD8, 0xD9}:
            continue
        if marker == 0xDA:
            break
        if marker == 0xE1:
            has_app1 = True
        length = struct.unpack(">H", data[offset:offset + 2])[0]
        if length < 2 or offset + length > len(data):
            raise SystemExit(f"Malformed JPEG segment in {path}")
        if marker in {
            0xC0, 0xC1, 0xC2, 0xC3,
            0xC5, 0xC6, 0xC7,
            0xC9, 0xCA, 0xCB,
            0xCD, 0xCE, 0xCF,
        }:
            height, width = struct.unpack(">HH", data[offset + 3:offset + 7])
            dimensions = (width, height)
        offset += length
    if dimensions is None:
        raise SystemExit(f"JPEG dimensions were not found: {path}")
    return dimensions[0], dimensions[1], has_app1


report = {
    "schemaVersion": 1,
    "releaseBoundary": "local-only-disabled",
    "fixture": {
        "kind": "code-generated-vector-cat-illustration",
        "externalSourceImages": 0,
        "personalPhotos": 0,
        "containsAccountOrLocationData": False,
    },
    "releaseArchiveVerification": "not-performed-by-debug-capture-workflow",
    "screenshots": [],
    "userReviewRequiredBeforeUpload": True,
}

for target in targets:
    source = find_source(target)
    if source is None:
        available = "\n".join(str(path.relative_to(raw_directory)) for path in png_files)
        raise SystemExit(
            f"Could not map XCTest attachment {target}. Exported PNGs:\n"
            f"{available or '(none)'}"
        )

    destination = output_directory / f"{target}.jpg"
    conversion = subprocess.run(
        [
            "/usr/bin/sips",
            "-s", "format", "jpeg",
            "-s", "formatOptions", "95",
            str(source),
            "--out", str(destination),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if conversion.returncode != 0:
        raise SystemExit(
            f"sips failed for {target}:\n{conversion.stdout}\n{conversion.stderr}"
        )

    width, height, has_app1 = jpeg_dimensions_and_app1(destination)
    if (width, height) not in accepted_portrait_sizes:
        raise SystemExit(
            f"{target} is {width}x{height}; expected an accepted 6.9-inch "
            f"portrait size: {sorted(accepted_portrait_sizes)}"
        )
    if has_app1:
        raise SystemExit(
            f"{target} contains a JPEG APP1 metadata segment; EXIF/XMP is forbidden."
        )

    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    report["screenshots"].append(
        {
            "attachmentName": target,
            "file": destination.name,
            "format": "jpeg",
            "height": height,
            "metadataApp1": False,
            "sha256": digest,
            "width": width,
        }
    )

(output_directory / "app-store-screenshot-manifest.json").write_text(
    json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)

print("Exported five metadata-free App Store JPEGs:")
for item in report["screenshots"]:
    print(
        f"- {item['file']}: {item['width']}x{item['height']} "
        f"sha256={item['sha256'][:12]}"
    )
PY

# Raw XCTest attachments are useful only for conversion and may include
# framework diagnostics. Keep the final artifact limited to the JPEGs and the
# machine-readable manifest.
rm -rf "$RAW_DIRECTORY"
rm -f "$OUTPUT_DIRECTORY/xcresulttool-export.log"
