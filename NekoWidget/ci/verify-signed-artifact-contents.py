#!/usr/bin/env python3
"""Verify authenticated plaintext bundle contents without extracting paths."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import struct
import tarfile
from pathlib import Path, PurePosixPath


METADATA_NAME = "moderation-release-metadata.json"
TRUST_MANIFEST_NAME = "moderation-key-trust-manifest.json"
MAXIMUM_JSON_BYTES = 1_000_000
ARCHIVE_DIGEST_ALGORITHM = "sha256-tree-v2"
ARCHIVE_DIGEST_DOMAIN = b"jp.nekowidget.xcarchive-content.v2\0"


def update_field(digest: object, field: bytes) -> None:
    digest.update(struct.pack(">Q", len(field)))  # type: ignore[attr-defined]
    digest.update(field)  # type: ignore[attr-defined]


def embedded_archive_sha256(
    archive: tarfile.TarFile,
    members: list[tarfile.TarInfo],
) -> str:
    prefix = "NekoWidget.xcarchive/"
    entries = [member for member in members if member.name.startswith(prefix)]
    if not entries:
        fail("Decrypted signed artifact bundle is missing xcarchive entries.")
    entries.sort(key=lambda member: member.name.removeprefix(prefix))
    digest = hashlib.sha256(ARCHIVE_DIGEST_DOMAIN)
    for member in entries:
        relative_text = member.name.removeprefix(prefix)
        if not relative_text:
            continue
        update_field(digest, relative_text.encode("utf-8"))
        digest.update(struct.pack(">I", member.mode & 0o7777))
        if member.isdir():
            digest.update(b"D")
        elif member.isfile():
            digest.update(b"F")
            digest.update(struct.pack(">Q", member.size))
            stream = archive.extractfile(member)
            if stream is None:
                fail(f"Embedded archive file is unreadable: {relative_text}")
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
        elif member.issym():
            digest.update(b"L")
            update_field(digest, member.linkname.encode("utf-8"))
        else:
            fail(f"Embedded archive contains unsupported entry type: {relative_text}")
    return digest.hexdigest()


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


def sha256_stream(stream: object) -> str:
    digest = hashlib.sha256()
    while chunk := stream.read(1024 * 1024):  # type: ignore[attr-defined]
        digest.update(chunk)
    return digest.hexdigest()


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--external-metadata", type=Path, required=True)
    parser.add_argument("--external-ipa", type=Path, required=True)
    parser.add_argument("--release-mode", required=True)
    parser.add_argument("--external-trust-manifest", type=Path)
    parser.add_argument("--expected-trust-manifest-sha256", default="")
    return parser.parse_args()


def main() -> None:
    args = parse_arguments()
    regular_file(args.bundle, "Decrypted signed artifact bundle")
    metadata_stat = regular_file(args.external_metadata, "External release metadata")
    ipa_stat = regular_file(args.external_ipa, "External release IPA")
    if args.external_metadata.name != METADATA_NAME:
        fail("External release metadata filename is not canonical.")
    if args.release_mode == "media-staging":
        if args.external_trust_manifest is None:
            fail("Media-staging evidence requires the canonical trust manifest preimage.")
        trust_stat = regular_file(
            args.external_trust_manifest,
            "External moderation trust manifest",
        )
        if args.external_trust_manifest.name != TRUST_MANIFEST_NAME:
            fail("External moderation trust manifest filename is not canonical.")
        if trust_stat.st_size > MAXIMUM_JSON_BYTES:
            fail("External moderation trust manifest is too large.")
        if len(args.expected_trust_manifest_sha256) != 64:
            fail("Expected moderation trust manifest SHA-256 is malformed.")
    else:
        if args.external_trust_manifest is not None or args.expected_trust_manifest_sha256:
            fail("Non-media evidence must not provide a moderation trust manifest.")

    try:
        archive = tarfile.open(args.bundle, mode="r:gz")
    except (OSError, tarfile.TarError) as error:
        fail(f"Decrypted signed artifact bundle is invalid: {error}")
    with archive:
        members = archive.getmembers()
        names = [member.name for member in members]
        if len(names) != len(set(names)):
            fail("Decrypted signed artifact bundle contains duplicate paths.")
        for name in names:
            path = PurePosixPath(name)
            if (
                not name
                or "\\" in name
                or path.is_absolute()
                or ".." in path.parts
                or "\0" in name
            ):
                fail("Decrypted signed artifact bundle contains an unsafe path.")
        if not any(
            name == "NekoWidget.xcarchive" or name.startswith("NekoWidget.xcarchive/")
            for name in names
        ):
            fail("Decrypted signed artifact bundle is missing the signed xcarchive.")

        required_names = {METADATA_NAME, args.external_ipa.name}
        if args.release_mode == "media-staging":
            required_names.add(TRUST_MANIFEST_NAME)
        elif TRUST_MANIFEST_NAME in names:
            fail("Non-media signed artifact unexpectedly contains a trust manifest.")
        for name in required_names:
            matches = [member for member in members if member.name == name]
            if len(matches) != 1 or not matches[0].isfile():
                fail(f"Signed artifact member {name} must be one regular file.")

        metadata_member = archive.getmember(METADATA_NAME)
        if metadata_member.size != metadata_stat.st_size or metadata_member.size > MAXIMUM_JSON_BYTES:
            fail("Embedded release metadata size does not match the authenticated file.")
        metadata_stream = archive.extractfile(metadata_member)
        if metadata_stream is None:
            fail("Embedded release metadata is unreadable.")
        metadata_bytes = metadata_stream.read()
        if metadata_bytes != args.external_metadata.read_bytes():
            fail("Embedded release metadata does not match the authenticated file.")
        try:
            release_metadata = json.loads(
                metadata_bytes.decode("utf-8"),
                object_pairs_hook=strict_object,
            )
        except (UnicodeError, ValueError, json.JSONDecodeError) as error:
            fail(f"Embedded release metadata is invalid: {error}")
        if not isinstance(release_metadata, dict):
            fail("Embedded release metadata root must be an object.")
        if release_metadata.get("archiveDigestAlgorithm") != ARCHIVE_DIGEST_ALGORITHM:
            fail("Embedded release metadata archive digest algorithm is unsupported.")
        if release_metadata.get("archiveSha256") != embedded_archive_sha256(
            archive, members
        ):
            fail("Embedded xcarchive SHA-256 does not match authenticated release metadata.")

        ipa_member = archive.getmember(args.external_ipa.name)
        if ipa_member.size != ipa_stat.st_size:
            fail("Embedded IPA size does not match the upload payload.")
        ipa_stream = archive.extractfile(ipa_member)
        if ipa_stream is None:
            fail("Embedded IPA is unreadable.")
        with args.external_ipa.open("rb") as external_ipa:
            external_ipa_sha256 = sha256_stream(external_ipa)
        if sha256_stream(ipa_stream) != external_ipa_sha256:
            fail("Embedded IPA SHA-256 does not match the upload payload.")

        if args.release_mode == "media-staging":
            trust_member = archive.getmember(TRUST_MANIFEST_NAME)
            if trust_member.size > MAXIMUM_JSON_BYTES:
                fail("Embedded moderation trust manifest is too large.")
            trust_stream = archive.extractfile(trust_member)
            if trust_stream is None:
                fail("Embedded moderation trust manifest is unreadable.")
            trust_bytes = trust_stream.read()
            assert args.external_trust_manifest is not None
            if trust_bytes != args.external_trust_manifest.read_bytes():
                fail("Embedded moderation trust manifest does not match its evidence preimage.")
            try:
                trust_value = json.loads(
                    trust_bytes.decode("ascii"),
                    object_pairs_hook=strict_object,
                )
                canonical = json.dumps(
                    trust_value,
                    ensure_ascii=True,
                    separators=(",", ":"),
                    sort_keys=True,
                ).encode("ascii")
            except (UnicodeError, ValueError, json.JSONDecodeError) as error:
                fail(f"Embedded moderation trust manifest is invalid: {error}")
            if trust_bytes != canonical + b"\n":
                fail("Embedded moderation trust manifest is not canonical JSON.")
            if hashlib.sha256(canonical).hexdigest() != args.expected_trust_manifest_sha256:
                fail("Embedded moderation trust manifest SHA-256 does not match release metadata.")
    print("PASS signed artifact content binding")


if __name__ == "__main__":
    main()
