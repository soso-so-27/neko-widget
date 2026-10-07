"""Offline pinned-input seeding and bounded synthetic-output collection.

Does not invoke the exporter, grant Photos access, launch CI or delete files.
The native receipt proves only export/cleanup; external MP4 checks remain separate.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

MANIFEST_SHA256 = "643f16febdb4088c28a1aea1d6d25032be324296dd3f2955d0f94ce93f100e82"
FIXED_INPUTS = Path(__file__).parent / "fixed-inputs"
INPUT_NAMES = {f"still-{number}.png" for number in range(1, 7)} | {
    "source-video.mp4", "source-audio-997hz.wav"}
OUTPUT_NAMES = {"receipt.json", "exported-on.mp4", "exported-off.mp4", "opening.png"}
RECEIPT_KEYS = {"syntheticOnly", "shippingExporterInvoked", "exportAttempts",
    "fixtureManifestSHA256", "buildSourceSHA", "exports", "photoBaselineRestored",
    "managedCleanupSucceeded", "returnedManagedExportsCleaned",
    "remainingNewManagedDirectories", "result", "visualInspection", "listening"}
UUID = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def regular_bytes(path, cap):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > cap:
        raise ValueError("Expected bounded regular synthetic file")
    return path.read_bytes()


def pinned_inputs(directory=FIXED_INPUTS):
    directory = Path(directory)
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("Expected regular fixed-input directory")
    manifest_data = regular_bytes(directory / "fixture.json", 64 * 1024)
    if digest(manifest_data) != MANIFEST_SHA256:
        raise ValueError("Fixed manifest hash differs")
    manifest = json.loads(manifest_data)
    if set(manifest["sha256"]) != INPUT_NAMES:
        raise ValueError("Unexpected fixed-input names")
    result = {"fixture.json": manifest_data}
    for name, expected in manifest["sha256"].items():
        data = regular_bytes(directory / name, 1024 * 1024)
        if digest(data) != expected:
            raise ValueError("Fixed input hash differs: " + name)
        result[name] = data
    return result


def seed(app_tmp, directory=FIXED_INPUTS):
    data = pinned_inputs(directory)  # Validate everything before creating output.
    app_tmp = Path(app_tmp)
    if app_tmp.is_symlink() or not app_tmp.is_dir():
        raise ValueError("Expected disposable app tmp directory")
    destination = app_tmp / "movie-synthetic-inputs"
    destination.mkdir(exist_ok=False)
    for name, content in data.items():
        with (destination / name).open("xb") as stream:
            stream.write(content)
    if pinned_inputs(destination) != data:
        raise ValueError("Seeded inputs changed")
    return {name: digest(content) for name, content in data.items()}


def validated_receipt(data):
    receipt = json.loads(data)
    if not isinstance(receipt, dict) or set(receipt) != RECEIPT_KEYS:
        raise ValueError("Unexpected native receipt fields")
    if (receipt["syntheticOnly"] is not True
            or receipt["fixtureManifestSHA256"] != MANIFEST_SHA256
            or type(receipt["exportAttempts"]) is not int
            or not 0 <= receipt["exportAttempts"] <= 2
            or receipt["result"] not in {"failed", "exported; external inspection pending"}
            or receipt["visualInspection"] != "not performed"
            or receipt["listening"] != "not performed"):
        raise ValueError("Receipt is not the pinned synthetic route")
    source = receipt["buildSourceSHA"]
    if not isinstance(source, str) or (source != "not supplied" and re.fullmatch(r"[0-9a-f]{40}", source) is None):
        raise ValueError("Unexpected advisory build source")
    for name in ["shippingExporterInvoked", "photoBaselineRestored",
                 "managedCleanupSucceeded", "returnedManagedExportsCleaned"]:
        if type(receipt[name]) is not bool:
            raise ValueError("Receipt flag is not boolean")
    remaining = receipt["remainingNewManagedDirectories"]
    if remaining is not None and (not isinstance(remaining, list) or any(
            not isinstance(name, str) or re.fullmatch(UUID, name) is None for name in remaining)):
        raise ValueError("Unexpected managed directory evidence")
    exports = receipt["exports"]
    if not isinstance(exports, list) or len(exports) > 2:
        raise ValueError("Unexpected export evidence")
    names = set()
    for entry in exports:
        if (not isinstance(entry, dict) or set(entry) != {"file", "soundEnabled", "duration", "sha256"}
                or entry["file"] not in {"exported-on.mp4", "exported-off.mp4"}
                or entry["file"] in names
                or type(entry["soundEnabled"]) is not bool
                or entry["soundEnabled"] != (entry["file"] == "exported-on.mp4")
                or type(entry["duration"]) not in {int, float}
                or not 0 < entry["duration"] <= 60
                or not isinstance(entry["sha256"], str)
                or re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]) is None):
            raise ValueError("Unexpected exported file evidence")
        names.add(entry["file"])
    return receipt


def collect(documents, destination, source_sha):
    if re.fullmatch(r"[0-9a-f]{40}", source_sha) is None:
        raise ValueError("Fixed source SHA is required")
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=False)
    report = {"schemaVersion": 1, "syntheticOnly": True, "sourceSHA": source_sha,
        "fixtureManifestSHA256": MANIFEST_SHA256, "copied": [], "errors": [],
        "externalMP4Inspection": "pending", "visualInspection": "not performed", "listening": "not performed"}
    try:
        documents = Path(documents)
        if documents.is_symlink() or not documents.is_dir():
            raise ValueError("Expected disposable app Documents directory")
        candidates = [path for path in documents.iterdir() if
            re.fullmatch("MovieSyntheticAcceptance-" + UUID, path.name)]
        if len(candidates) != 1:
            raise ValueError("Expected exactly one synthetic output directory")
        output = candidates[0]
        if output.is_symlink() or not output.is_dir():
            raise ValueError("Synthetic output directory is not regular")
        receipt_data = regular_bytes(output / "receipt.json", 64 * 1024)
        receipt = validated_receipt(receipt_data)
        # Preserve the verified bounded receipt even when a later output hash
        # fails; arbitrary/malformed receipts never reach this copy.
        with (destination / "receipt.json").open("xb") as stream:
            stream.write(receipt_data)
        report["copied"].append({"file": "receipt.json", "bytes": len(receipt_data),
            "sha256": digest(receipt_data), "nativeHashVerified": False})
        if receipt["buildSourceSHA"] != source_sha:
            report["errors"].append("Native receipt source SHA differs from fixed diagnostic SHA")
        # Reject unexpected children; never copy an app's entire Documents tree.
        if any(path.name not in OUTPUT_NAMES for path in output.iterdir()):
            raise ValueError("Unexpected synthetic output child")
        export_hashes = {entry["file"]: entry["sha256"] for entry in receipt["exports"]}
        for name in sorted(OUTPUT_NAMES - {"receipt.json"}):
            path = output / name
            if not path.exists() and not path.is_symlink():
                continue
            try:
                data = regular_bytes(path, 100 * 1024 * 1024 if name.endswith(".mp4") else 8 * 1024 * 1024)
                actual_hash = digest(data)
                if name in export_hashes and actual_hash != export_hashes[name]:
                    raise ValueError("Export differs from native receipt")
                with (destination / name).open("xb") as stream:
                    stream.write(data)
                report["copied"].append({"file": name, "bytes": len(data), "sha256": actual_hash,
                    "nativeHashVerified": name in export_hashes})
            except (OSError, ValueError) as error:
                report["errors"].append(name + ": " + type(error).__name__ + ": synthetic file unavailable or invalid")
        present = {entry["file"] for entry in report["copied"]}
        if (receipt["result"] != "exported; external inspection pending"
                or receipt["exportAttempts"] != 2 or not receipt["shippingExporterInvoked"]
                or not receipt["photoBaselineRestored"] or not receipt["managedCleanupSucceeded"]
                or not receipt["returnedManagedExportsCleaned"]
                or receipt["remainingNewManagedDirectories"] != []
                or set(export_hashes) != {"exported-on.mp4", "exported-off.mp4"}
                or present != OUTPUT_NAMES):
            report["errors"].append("Native export or cleanup did not complete; partial evidence retained")
    except (OSError, ValueError, TypeError, KeyError) as error:
        # Avoid exposing container paths or arbitrary receipt values in uploads.
        report["errors"].append(type(error).__name__ + ": synthetic evidence unavailable or invalid")
    report["collectionCheck"] = "failed" if report["errors"] else "passed"
    (destination / "collection.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("verify")
    seed_parser = commands.add_parser("seed")
    seed_parser.add_argument("app_tmp", type=Path)
    collect_parser = commands.add_parser("collect")
    collect_parser.add_argument("documents", type=Path)
    collect_parser.add_argument("destination", type=Path)
    collect_parser.add_argument("--source-sha", required=True)
    arguments = parser.parse_args()
    if arguments.command == "verify":
        print(json.dumps({name: digest(data) for name, data in pinned_inputs().items()}, indent=2))
    elif arguments.command == "seed":
        print(json.dumps(seed(arguments.app_tmp), indent=2))
    else:
        result = collect(arguments.documents, arguments.destination, arguments.source_sha)
        print(json.dumps(result, indent=2))
        raise SystemExit(bool(result["errors"]))
