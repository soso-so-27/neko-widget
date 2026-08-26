#!/usr/bin/env python3
"""Create or verify password-bound authentication for a signed artifact bundle."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import hmac
import json
import os
import re
import stat
import struct
from pathlib import Path


SCHEMA = "jp.nekowidget.signed-artifact-authentication.v2"
ALGORITHM = "PBKDF2-HMAC-SHA256-200000-RANDOM-SALT/HMAC-SHA256"
PASSWORD_ENVIRONMENT = "SIGNED_ARTIFACT_ENCRYPTION_PASSWORD"
KDF_SALT_DOMAIN = b"jp.nekowidget.signed-artifact-authentication.key.v2\0"
MESSAGE_DOMAIN = b"jp.nekowidget.signed-artifact-authentication.v2\0"
KDF_ITERATIONS = 200_000
KDF_RANDOM_SALT_BYTES = 32
LOWER_HEX_64 = re.compile(r"[0-9a-f]{64}")
BASE64URL_32 = re.compile(r"[A-Za-z0-9_-]{43}")


def fail(message: str) -> None:
    raise SystemExit(message)


def strict_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def regular_file(path: Path, label: str) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as error:
        fail(f"{label} is unavailable: {error}")
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size <= 0:
        fail(f"{label} must be a nonempty regular file.")
    return metadata


def password_key(random_salt: bytes) -> bytearray:
    password = os.environ.get(PASSWORD_ENVIRONMENT)
    if password is None or len(password) < 20:
        fail(f"{PASSWORD_ENVIRONMENT} must contain at least 20 characters.")
    return bytearray(
        hashlib.pbkdf2_hmac(
            "sha256",
            password.encode("utf-8"),
            KDF_SALT_DOMAIN + random_salt,
            KDF_ITERATIONS,
            dklen=32,
        )
    )


def digest_and_authenticate(
    ciphertext_path: Path,
    metadata_path: Path,
    random_salt: bytes,
) -> tuple[int, str, int, str, str]:
    ciphertext_stat = regular_file(ciphertext_path, "Encrypted artifact bundle")
    metadata_stat = regular_file(metadata_path, "Release metadata")
    if len(random_salt) != KDF_RANDOM_SALT_BYTES:
        fail("Artifact authentication KDF salt is invalid.")
    key = password_key(random_salt)
    authenticator = hmac.new(key, digestmod=hashlib.sha256)
    ciphertext_digest = hashlib.sha256()
    metadata_digest = hashlib.sha256()
    try:
        authenticator.update(MESSAGE_DOMAIN)
        authenticator.update(struct.pack(">Q", ciphertext_stat.st_size))
        with ciphertext_path.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                ciphertext_digest.update(chunk)
                authenticator.update(chunk)
        authenticator.update(struct.pack(">Q", metadata_stat.st_size))
        with metadata_path.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                metadata_digest.update(chunk)
                authenticator.update(chunk)
    finally:
        key[:] = b"\0" * len(key)
    return (
        ciphertext_stat.st_size,
        ciphertext_digest.hexdigest(),
        metadata_stat.st_size,
        metadata_digest.hexdigest(),
        authenticator.hexdigest(),
    )


def create_manifest(ciphertext: Path, metadata: Path, output: Path) -> None:
    random_salt = os.urandom(KDF_RANDOM_SALT_BYTES)
    cipher_size, cipher_hash, metadata_size, metadata_hash, tag = (
        digest_and_authenticate(ciphertext, metadata, random_salt)
    )
    value = {
        "schema": SCHEMA,
        "algorithm": ALGORITHM,
        "kdfSalt": base64.urlsafe_b64encode(random_salt).decode("ascii").rstrip("="),
        "ciphertextFileName": ciphertext.name,
        "ciphertextSize": cipher_size,
        "ciphertextSha256": cipher_hash,
        "releaseMetadataFileName": metadata.name,
        "releaseMetadataSize": metadata_size,
        "releaseMetadataSha256": metadata_hash,
        "authenticationTag": tag,
    }
    try:
        with output.open("x", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, ensure_ascii=True, indent=2, sort_keys=True)
            stream.write("\n")
    except OSError as error:
        fail(f"Could not create artifact authentication manifest: {error}")


def verify_manifest(ciphertext: Path, metadata: Path, authentication: Path) -> None:
    regular_file(authentication, "Artifact authentication manifest")
    try:
        value = json.loads(
            authentication.read_text(encoding="utf-8"),
            object_pairs_hook=strict_object,
        )
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
        fail(f"Artifact authentication manifest is invalid: {error}")
    expected_fields = {
        "schema",
        "algorithm",
        "kdfSalt",
        "ciphertextFileName",
        "ciphertextSize",
        "ciphertextSha256",
        "releaseMetadataFileName",
        "releaseMetadataSize",
        "releaseMetadataSha256",
        "authenticationTag",
    }
    if not isinstance(value, dict) or set(value) != expected_fields:
        fail("Artifact authentication manifest has unexpected or missing fields.")
    if value["schema"] != SCHEMA or value["algorithm"] != ALGORITHM:
        fail("Artifact authentication manifest schema or algorithm is unsupported.")
    encoded_salt = value["kdfSalt"]
    if not isinstance(encoded_salt, str) or BASE64URL_32.fullmatch(encoded_salt) is None:
        fail("Artifact authentication kdfSalt is invalid.")
    try:
        random_salt = base64.b64decode(
            encoded_salt.replace("-", "+").replace("_", "/") + "=",
            validate=True,
        )
    except binascii.Error as error:
        fail(f"Artifact authentication kdfSalt is invalid: {error}")
    if (
        len(random_salt) != KDF_RANDOM_SALT_BYTES
        or base64.urlsafe_b64encode(random_salt).decode("ascii").rstrip("=")
        != encoded_salt
    ):
        fail("Artifact authentication kdfSalt is invalid.")
    if value["ciphertextFileName"] != ciphertext.name:
        fail("Encrypted artifact filename does not match authentication manifest.")
    if value["releaseMetadataFileName"] != metadata.name:
        fail("Release metadata filename does not match authentication manifest.")
    for field in ("ciphertextSize", "releaseMetadataSize"):
        item = value[field]
        if isinstance(item, bool) or not isinstance(item, int) or item <= 0:
            fail(f"Artifact authentication {field} is invalid.")
    for field in ("ciphertextSha256", "releaseMetadataSha256", "authenticationTag"):
        item = value[field]
        if not isinstance(item, str) or LOWER_HEX_64.fullmatch(item) is None:
            fail(f"Artifact authentication {field} is invalid.")

    cipher_size, cipher_hash, metadata_size, metadata_hash, tag = (
        digest_and_authenticate(ciphertext, metadata, random_salt)
    )
    checks = (
        (value["ciphertextSize"] == cipher_size, "encrypted artifact size"),
        (hmac.compare_digest(value["ciphertextSha256"], cipher_hash), "encrypted artifact SHA-256"),
        (value["releaseMetadataSize"] == metadata_size, "release metadata size"),
        (hmac.compare_digest(value["releaseMetadataSha256"], metadata_hash), "release metadata SHA-256"),
        (hmac.compare_digest(value["authenticationTag"], tag), "authentication tag"),
    )
    for matches, label in checks:
        if not matches:
            fail(f"Artifact authentication failed: {label} mismatch.")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="operation", required=True)
    create = subparsers.add_parser("create")
    create.add_argument("--ciphertext", required=True, type=Path)
    create.add_argument("--metadata", required=True, type=Path)
    create.add_argument("--output", required=True, type=Path)
    verify = subparsers.add_parser("verify")
    verify.add_argument("--ciphertext", required=True, type=Path)
    verify.add_argument("--metadata", required=True, type=Path)
    verify.add_argument("--authentication", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_arguments()
    if args.operation == "create":
        create_manifest(args.ciphertext, args.metadata, args.output)
    else:
        verify_manifest(args.ciphertext, args.metadata, args.authentication)
    print("PASS signed artifact authentication")


if __name__ == "__main__":
    main()
