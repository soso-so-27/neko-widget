#!/usr/bin/env python3
"""Re-bind the exact IPA about to be uploaded to authenticated release metadata.

This is a local consistency check, not a signature verifier. Callers must first
verify the signed-artifact authentication manifest in the same step.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
from pathlib import Path


METADATA_SCHEMA = "jp.nekowidget.moderation-release-metadata.v2"
EXPECTED_METADATA_FILENAME = "moderation-release-metadata.json"
LOWER_HEX_40 = re.compile(r"[0-9a-f]{40}")
LOWER_HEX_64 = re.compile(r"[0-9a-f]{64}")
POSITIVE_DECIMAL = re.compile(r"[1-9][0-9]*")
EXPECTED_FIELDS = {
    "schema",
    "releaseEnvironment",
    "sourceCommit",
    "releaseMode",
    "version",
    "buildNumber",
    "githubRunId",
    "githubRunAttempt",
    "moderationKeyId",
    "moderationPublicKey",
    "moderationPublicKeySha256",
    "moderationTrustManifestRevision",
    "moderationTrustManifestSha256",
    "moderationRolloutPolicyRevision",
    "moderationRolloutPolicySha256",
    "archiveDigestAlgorithm",
    "archiveSha256",
    "ipaSha256",
}


def fail(message: str) -> None:
    raise SystemExit(message)


def strict_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def regular_file(path: Path, label: str) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as error:
        fail(f"{label} is unavailable: {error}")
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size <= 0:
        fail(f"{label} must be a nonempty regular file.")
    return metadata


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        fail(f"Could not hash upload payload: {error}")
    return digest.hexdigest()


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--expected-source-commit", required=True)
    parser.add_argument("--expected-build-number", required=True)
    parser.add_argument("--expected-github-run-id", required=True)
    parser.add_argument("--expected-github-run-attempt", required=True)
    parser.add_argument("--expected-release-mode", required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_arguments()
    if args.metadata.name != EXPECTED_METADATA_FILENAME:
        fail("Release metadata filename is not canonical.")
    regular_file(args.metadata, "Release metadata")
    regular_file(args.ipa, "Release IPA")
    try:
        metadata = json.loads(
            args.metadata.read_text(encoding="utf-8"),
            object_pairs_hook=strict_object,
        )
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
        fail(f"Release metadata is invalid: {error}")
    if not isinstance(metadata, dict) or set(metadata) != EXPECTED_FIELDS:
        fail("Release metadata has unexpected or missing fields.")
    if metadata["schema"] != METADATA_SCHEMA:
        fail("Release metadata schema is unsupported.")
    if metadata["releaseEnvironment"] != "testflight":
        fail("Release metadata environment must be exactly testflight.")
    if LOWER_HEX_40.fullmatch(args.expected_source_commit) is None:
        fail("Expected source commit is malformed.")
    for value, label in (
        (args.expected_build_number, "build number"),
        (args.expected_github_run_id, "GitHub run ID"),
        (args.expected_github_run_attempt, "GitHub run attempt"),
    ):
        if POSITIVE_DECIMAL.fullmatch(value) is None:
            fail(f"Expected {label} is malformed.")
    expected_values = {
        "sourceCommit": args.expected_source_commit,
        "buildNumber": args.expected_build_number,
        "githubRunId": args.expected_github_run_id,
        "githubRunAttempt": int(args.expected_github_run_attempt),
        "releaseMode": args.expected_release_mode,
    }
    for field, expected in expected_values.items():
        if metadata[field] != expected:
            fail(f"Release metadata {field} does not match the upload context.")
    recorded_digest = metadata["ipaSha256"]
    if not isinstance(recorded_digest, str) or LOWER_HEX_64.fullmatch(recorded_digest) is None:
        fail("Release metadata IPA SHA-256 is malformed.")
    if recorded_digest != sha256_file(args.ipa):
        fail("Release IPA SHA-256 does not match authenticated release metadata.")
    print("PASS moderation upload payload binding")


if __name__ == "__main__":
    main()
