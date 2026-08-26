#!/usr/bin/env python3
"""Write build-bound moderation release evidence after IPA export.

The archive digest is a deterministic SHA-256 over entry type, relative path,
permission bits, symlink target, and regular-file content. It deliberately does
not follow symlinks or depend on filesystem timestamps.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
import plistlib
import re
import stat
import struct
from pathlib import Path


METADATA_SCHEMA = "jp.nekowidget.moderation-release-metadata.v2"
ROLLOUT_POLICY_SCHEMA = "jp.nekowidget.moderation-client-rollout-policy.v1"
SUPPORTED_MODERATION_KEY_IDS = {"moderation-v1", "moderation-v2"}
ARCHIVE_DIGEST_ALGORITHM = "sha256-tree-v2"
ARCHIVE_DIGEST_DOMAIN = b"jp.nekowidget.xcarchive-content.v2\0"
LOWER_HEX_64 = re.compile(r"[0-9a-f]{64}")
POSITIVE_DECIMAL = re.compile(r"[1-9][0-9]*")
EXPECTED_MODE_FLAGS = {
    "disabled": (False, False, False, False, False),
    "review-preview": (False, False, False, False, True),
    "pairing-only": (True, False, False, False, False),
    "media-staging": (True, True, True, False, False),
}
APP_INFO_RELATIVE_PATH = Path("Products/Applications/NekoWidget.app/Info.plist")
SHARE_INFO_RELATIVE_PATH = Path(
    "Products/Applications/NekoWidget.app/PlugIns/"
    "NekoWidgetShareExtension.appex/Info.plist"
)
WIDGET_INFO_RELATIVE_PATH = Path(
    "Products/Applications/NekoWidget.app/PlugIns/"
    "NekoWidgetWidgetExtension.appex/Info.plist"
)

# X25519 small-order Montgomery u-coordinates, normalized by clearing the
# unused high bit as required by RFC 7748. Keep this evidence writer aligned
# with the release validator and runtime self-test.
X25519_SMALL_ORDER_PUBLIC_KEYS = {
    bytes.fromhex("00" * 32),
    bytes.fromhex("01" + ("00" * 31)),
    bytes.fromhex("e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800"),
    bytes.fromhex("5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157"),
    bytes.fromhex("ec" + ("ff" * 30) + "7f"),
    bytes.fromhex("ed" + ("ff" * 30) + "7f"),
    bytes.fromhex("ee" + ("ff" * 30) + "7f"),
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


def canonical_json(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("ascii")


def load_dictionary_plist(path: Path, label: str) -> dict[str, object]:
    try:
        with path.open("rb") as stream:
            value = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"{label} is unavailable or invalid: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must contain a dictionary plist.")
    return value


def explicit_flag(info: dict[str, object], key: str, label: str) -> bool:
    if key not in info:
        fail(f"{label} {key} is missing.")
    value = info[key]
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return value != 0
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"1", "true", "yes"}:
            return True
        if normalized in {"0", "false", "no"}:
            return False
    fail(f"{label} {key} is not an explicit YES/NO value.")


def archived_release_info(
    archive: Path,
    supplied_app_info: Path,
    release_mode: str,
    moderation_key_id: str,
    moderation_public_key: str,
) -> dict[str, object]:
    try:
        archive_stat = archive.lstat()
    except OSError as error:
        fail(f"Release archive is unavailable: {error}")
    if not stat.S_ISDIR(archive_stat.st_mode) or stat.S_ISLNK(archive_stat.st_mode):
        fail("Release archive must be a real directory.")

    app_path = archive / APP_INFO_RELATIVE_PATH
    share_path = archive / SHARE_INFO_RELATIVE_PATH
    widget_path = archive / WIDGET_INFO_RELATIVE_PATH
    try:
        if not supplied_app_info.samefile(app_path):
            fail("Release metadata Info.plist must be the fixed archived app Info.plist.")
    except OSError as error:
        fail(f"Archive app Info.plist is unavailable: {error}")

    app_info = load_dictionary_plist(app_path, "Archive app Info.plist")
    share_info = load_dictionary_plist(
        share_path,
        "Archive Share Extension Info.plist",
    )
    widget_info = load_dictionary_plist(
        widget_path,
        "Archive Widget Extension Info.plist",
    )
    for label, info in (
        ("App", app_info),
        ("Share Extension", share_info),
        ("Widget Extension", widget_info),
    ):
        if info.get("SharingReleaseMode") != release_mode:
            fail(f"{label} SharingReleaseMode does not match release metadata.")

    expected = EXPECTED_MODE_FLAGS[release_mode]
    app_flag_keys = (
        "SharingFeatureEnabled",
        "SharingMediaEnabled",
        "SharingShareExtensionHandoffEnabled",
        "SharingShareExtensionSendEnabled",
        "SharingReviewPreviewEnabled",
    )
    app_flags = tuple(
        explicit_flag(app_info, key, "App")
        for key in app_flag_keys
    )
    if app_flags != expected:
        fail("Archive app sharing feature flags do not match release mode.")

    share_flag_keys = app_flag_keys
    share_flags = tuple(
        explicit_flag(share_info, key, "Share Extension")
        for key in share_flag_keys
    )
    if share_flags != (*expected[:4], False):
        fail("Archive Share Extension sharing feature flags do not match release mode.")

    widget_flags = (
        explicit_flag(widget_info, "SharingFeatureEnabled", "Widget Extension"),
        explicit_flag(widget_info, "SharingMediaEnabled", "Widget Extension"),
    )
    if widget_flags != expected[:2]:
        fail("Archive Widget Extension sharing feature flags do not match release mode.")

    expected_key_id = moderation_key_id if release_mode == "media-staging" else ""
    expected_public_key = moderation_public_key if release_mode == "media-staging" else ""
    for key, expected_value in (
        ("SharingModerationKeyID", expected_key_id),
        ("SharingModerationPublicKey", expected_public_key),
    ):
        value = app_info.get(key, "")
        if not isinstance(value, str) or value != expected_value:
            fail(f"Archive app {key} does not match release metadata.")
        for label, info in (
            ("Share Extension", share_info),
            ("Widget Extension", widget_info),
        ):
            extension_value = info.get(key, "")
            if not isinstance(extension_value, str) or extension_value:
                fail(f"Archive {label} must not contain {key}.")
    return app_info


def is_x25519_small_order_public_key(value: bytes) -> bool:
    if len(value) != 32:
        return True
    normalized = bytearray(value)
    normalized[31] &= 0x7F
    return bytes(normalized) in X25519_SMALL_ORDER_PUBLIC_KEYS


def load_rollout_policy(path: Path) -> tuple[dict[str, object], str]:
    try:
        raw = path.read_text(encoding="utf-8")
        value = json.loads(raw, object_pairs_hook=strict_object)
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
        fail(f"Moderation rollout policy is unavailable or invalid: {error}")
    if not isinstance(value, dict) or set(value) != {
        "schema",
        "environment",
        "revision",
        "clientKeyId",
        "clientPublicKeySha256",
        "trustManifestRevision",
        "trustManifestSha256",
        "v2ClientReleaseAllowed",
    }:
        fail("Moderation rollout policy has unexpected or missing fields.")
    if value["schema"] != ROLLOUT_POLICY_SCHEMA:
        fail("Moderation rollout policy schema is unsupported.")
    if value["environment"] != "testflight":
        fail("Moderation rollout policy environment must be exactly testflight.")
    for field in ("revision", "trustManifestRevision"):
        item = value[field]
        if isinstance(item, bool) or not isinstance(item, int) or item <= 0:
            fail(f"Moderation rollout policy {field} must be a positive integer.")
    if value["clientKeyId"] not in SUPPORTED_MODERATION_KEY_IDS:
        fail("Moderation rollout policy clientKeyId is unsupported.")
    for field in ("clientPublicKeySha256", "trustManifestSha256"):
        item = value[field]
        if not isinstance(item, str) or LOWER_HEX_64.fullmatch(item) is None:
            fail(f"Moderation rollout policy {field} must be lowercase SHA-256.")
    if not isinstance(value["v2ClientReleaseAllowed"], bool):
        fail("Moderation rollout policy v2ClientReleaseAllowed must be boolean.")
    if value["v2ClientReleaseAllowed"]:
        fail(
            "Moderation rollout policy cannot allow v2 because machine-verifiable "
            "server and drill readiness evidence is not implemented."
        )
    if value["clientKeyId"] == "moderation-v2":
        fail(
            "Moderation rollout policy cannot select v2 because machine-verifiable "
            "server and drill readiness evidence is not implemented."
        )
    return value, hashlib.sha256(canonical_json(value)).hexdigest()


def update_field(digest: "hashlib._Hash", field: bytes) -> None:
    digest.update(struct.pack(">Q", len(field)))
    digest.update(field)


def archive_content_sha256(root: Path) -> str:
    try:
        root_stat = root.lstat()
    except OSError as error:
        fail(f"Release archive is unavailable: {error}")
    if not stat.S_ISDIR(root_stat.st_mode) or stat.S_ISLNK(root_stat.st_mode):
        fail("Release archive must be a real directory.")

    try:
        entries = sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix())
    except OSError as error:
        fail(f"Could not enumerate release archive: {error}")
    if not entries:
        fail("Release archive is empty.")

    digest = hashlib.sha256(ARCHIVE_DIGEST_DOMAIN)
    for path in entries:
        relative = path.relative_to(root).as_posix().encode("utf-8")
        try:
            metadata = path.lstat()
        except OSError as error:
            fail(f"Could not stat archive entry {path}: {error}")
        update_field(digest, relative)
        digest.update(struct.pack(">I", stat.S_IMODE(metadata.st_mode)))
        if stat.S_ISDIR(metadata.st_mode):
            digest.update(b"D")
        elif stat.S_ISREG(metadata.st_mode):
            digest.update(b"F")
            digest.update(struct.pack(">Q", metadata.st_size))
            try:
                with path.open("rb") as stream:
                    while chunk := stream.read(1024 * 1024):
                        digest.update(chunk)
            except OSError as error:
                fail(f"Could not read archive entry {path}: {error}")
        elif stat.S_ISLNK(metadata.st_mode):
            digest.update(b"L")
            try:
                target = os.readlink(path).encode("utf-8")
            except (OSError, UnicodeError) as error:
                fail(f"Could not read archive symlink {path}: {error}")
            update_field(digest, target)
        else:
            fail(f"Release archive contains an unsupported entry type: {path}")
    return digest.hexdigest()


def regular_file_sha256(path: Path, label: str) -> str:
    try:
        metadata = path.lstat()
    except OSError as error:
        fail(f"{label} is unavailable: {error}")
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size <= 0:
        fail(f"{label} must be a nonempty regular file.")
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        fail(f"Could not read {label}: {error}")
    return digest.hexdigest()


def decode_public_key(value: str) -> bytes:
    if re.fullmatch(r"[A-Za-z0-9_-]{43}", value) is None:
        fail("Release metadata moderation public key is malformed.")
    try:
        decoded = base64.b64decode(
            value.replace("-", "+").replace("_", "/") + "=",
            validate=True,
        )
    except binascii.Error as error:
        fail(f"Release metadata moderation public key is malformed: {error}")
    if (
        len(decoded) != 32
        or base64.urlsafe_b64encode(decoded).decode("ascii").rstrip("=") != value
    ):
        fail("Release metadata moderation public key is malformed.")
    return decoded


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--info-plist", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--ipa", required=True, type=Path)
    parser.add_argument("--rollout-policy", required=True, type=Path)
    parser.add_argument("--release-environment", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--release-mode", required=True)
    parser.add_argument("--moderation-key-id", default="")
    parser.add_argument("--moderation-public-key", default="")
    parser.add_argument("--moderation-public-key-sha256", default="")
    parser.add_argument("--moderation-trust-manifest-revision", default="")
    parser.add_argument("--moderation-trust-manifest-sha256", default="")
    parser.add_argument("--expected-rollout-policy-revision", required=True)
    parser.add_argument("--expected-rollout-policy-sha256", required=True)
    parser.add_argument("--expected-build-number", required=True)
    parser.add_argument("--github-run-id", required=True)
    parser.add_argument("--github-run-attempt", required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_arguments()
    policy, policy_sha256 = load_rollout_policy(args.rollout_policy)
    if str(policy["revision"]) != args.expected_rollout_policy_revision:
        fail("Release metadata rollout policy revision mismatch.")
    if (
        LOWER_HEX_64.fullmatch(args.expected_rollout_policy_sha256) is None
        or policy_sha256 != args.expected_rollout_policy_sha256
    ):
        fail("Release metadata rollout policy SHA-256 mismatch.")
    if args.release_environment != "testflight":
        fail("Release metadata environment must be exactly testflight.")
    if re.fullmatch(r"[0-9a-f]{40}", args.source_commit) is None:
        fail("Release metadata source commit is malformed.")
    if args.release_mode not in {"disabled", "review-preview", "pairing-only", "media-staging"}:
        fail("Release metadata mode is unsupported.")
    if POSITIVE_DECIMAL.fullmatch(args.expected_build_number) is None:
        fail("Release metadata expected build number is malformed.")
    if POSITIVE_DECIMAL.fullmatch(args.github_run_id) is None:
        fail("Release metadata GitHub run ID is malformed.")
    if POSITIVE_DECIMAL.fullmatch(args.github_run_attempt) is None:
        fail("Release metadata GitHub run attempt is malformed.")

    info = archived_release_info(
        args.archive,
        args.info_plist,
        args.release_mode,
        args.moderation_key_id,
        args.moderation_public_key,
    )
    version = info.get("CFBundleShortVersionString")
    build_number = info.get("CFBundleVersion")
    if not isinstance(version, str) or not version or version != version.strip():
        fail("Archive marketing version is missing or malformed.")
    if build_number != args.expected_build_number:
        fail("Archive build number does not match the selected release build.")

    if args.release_mode == "media-staging":
        if args.moderation_key_id not in SUPPORTED_MODERATION_KEY_IDS:
            fail("Release metadata moderation key ID is unsupported.")
        if args.moderation_key_id != policy["clientKeyId"]:
            fail("Release metadata moderation key ID does not match rollout policy.")
        if info.get("SharingModerationKeyID") != args.moderation_key_id:
            fail("Archive moderation key ID does not match release metadata.")
        if info.get("SharingModerationPublicKey") != args.moderation_public_key:
            fail("Archive moderation public key does not match release metadata.")
        decoded_key = decode_public_key(args.moderation_public_key)
        if is_x25519_small_order_public_key(decoded_key):
            fail("Release metadata moderation public key is a small-order X25519 point.")
        if (
            LOWER_HEX_64.fullmatch(args.moderation_public_key_sha256) is None
            or hashlib.sha256(decoded_key).hexdigest()
            != args.moderation_public_key_sha256
        ):
            fail("Release metadata moderation fingerprint mismatch.")
        if args.moderation_public_key_sha256 != policy["clientPublicKeySha256"]:
            fail("Release metadata moderation fingerprint does not match rollout policy.")
        if (
            POSITIVE_DECIMAL.fullmatch(args.moderation_trust_manifest_revision) is None
            or int(args.moderation_trust_manifest_revision)
            != policy["trustManifestRevision"]
        ):
            fail("Release metadata trust manifest revision mismatch.")
        if (
            LOWER_HEX_64.fullmatch(args.moderation_trust_manifest_sha256) is None
            or args.moderation_trust_manifest_sha256 != policy["trustManifestSha256"]
        ):
            fail("Release metadata trust manifest SHA-256 mismatch.")
        metadata_manifest_revision: int | None = int(
            args.moderation_trust_manifest_revision
        )
        metadata_manifest_sha256: str | None = args.moderation_trust_manifest_sha256
    else:
        if any((
            args.moderation_key_id,
            args.moderation_public_key,
            args.moderation_public_key_sha256,
            args.moderation_trust_manifest_revision,
            args.moderation_trust_manifest_sha256,
        )):
            fail("Non-media release must not contain moderation key metadata.")
        metadata_manifest_revision = None
        metadata_manifest_sha256 = None

    metadata = {
        "schema": METADATA_SCHEMA,
        "releaseEnvironment": args.release_environment,
        "sourceCommit": args.source_commit,
        "releaseMode": args.release_mode,
        "version": version,
        "buildNumber": build_number,
        "githubRunId": args.github_run_id,
        "githubRunAttempt": int(args.github_run_attempt),
        "moderationKeyId": args.moderation_key_id,
        "moderationPublicKey": args.moderation_public_key,
        "moderationPublicKeySha256": args.moderation_public_key_sha256,
        "moderationTrustManifestRevision": metadata_manifest_revision,
        "moderationTrustManifestSha256": metadata_manifest_sha256,
        "moderationRolloutPolicyRevision": policy["revision"],
        "moderationRolloutPolicySha256": policy_sha256,
        "archiveDigestAlgorithm": ARCHIVE_DIGEST_ALGORITHM,
        "archiveSha256": archive_content_sha256(args.archive),
        "ipaSha256": regular_file_sha256(args.ipa, "Release IPA"),
    }
    try:
        with args.output.open("x", encoding="utf-8", newline="\n") as stream:
            json.dump(metadata, stream, ensure_ascii=True, indent=2, sort_keys=True)
            stream.write("\n")
    except OSError as error:
        fail(f"Could not create release metadata: {error}")


if __name__ == "__main__":
    main()
