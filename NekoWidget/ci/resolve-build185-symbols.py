#!/usr/bin/env python3
"""One-off Build 185 diagnosis; no raw crash, signed app, or symbols leave temp."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path, PurePosixPath


CI = Path(__file__).resolve().parent
RUN_ID = 35357759789
ARTIFACT_ID = 10553770172
SOURCE_COMMIT = "2fd468a956238fec74ae543ef9253c5182c16a67"
APP_UUID = "e803afbf-f0d4-3feb-a6b0-db20e0944ebd"
PASSWORD_ENV = "SIGNED_ARTIFACT_ENCRYPTION_PASSWORD"
CIPHERTEXT = "NekoWidget-signed-artifacts.tar.gz.enc"
METADATA = "moderation-release-metadata.json"
AUTHENTICATION = "signed-artifact-authentication.json"
DWARF_MEMBER = "NekoWidget.xcarchive/dSYMs/NekoWidget.app.dSYM/Contents/Resources/DWARF/NekoWidget"
MAXIMUM_FILE_BYTES = 1024 * 1024 * 1024

# Only app-image offsets and frame indices from the two supplied main threads.
# No incident IDs, device data, runtime addresses, or raw .ips files are retained.
CRASH_FRAMES = {
    "2": ((1, 193948), (2, 996604), (3, 990400), (4, 879464), (5, 879140),
          (6, 3723532), (7, 3719880), (8, 8504596), (9, 8388976), (10, 8387120),
          (12, 8382272), (14, 8377464), (54, 1553800)),
    "3": ((0, 3737484), (1, 1004388), (2, 996932), (3, 990400), (4, 879464),
          (5, 879140), (6, 3723532), (7, 3719880), (8, 8504596), (9, 8388976),
          (10, 8387120), (12, 8382272), (14, 8377464), (54, 1553800)),
}


class DiagnosticError(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise DiagnosticError(message)


def strict_object(pairs: list[tuple[str, object]]) -> dict:
    value: dict = {}
    for key, item in pairs:
        require(key not in value, "Duplicate JSON key.")
        value[key] = item
    return value


def read_object(path: Path) -> dict:
    require(path.stat().st_size <= 256 * 1024, "Metadata is too large.")
    value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=strict_object)
    require(isinstance(value, dict), "Metadata must be an object.")
    return value


def validate_provenance(run: dict, artifact: dict) -> None:
    expected = {
        "id": RUN_ID, "run_attempt": 1, "head_sha": SOURCE_COMMIT,
        "head_branch": "main", "event": "workflow_dispatch", "status": "completed",
        "conclusion": "success", "path": ".github/workflows/testflight.yml",
    }
    require(all(run.get(key) == value for key, value in expected.items()),
            "The source run does not match the fixed successful release.")
    require(run.get("repository", {}).get("full_name") == "soso-so-27/neko-widget",
            "Unexpected source repository.")
    require(artifact.get("id") == ARTIFACT_ID
            and artifact.get("name") == f"nekowidget-signed-artifacts-{RUN_ID}-1"
            and artifact.get("expired") is False
            and artifact.get("workflow_run", {}).get("id") == RUN_ID
            and artifact.get("workflow_run", {}).get("head_sha") == SOURCE_COMMIT,
            "The encrypted artifact does not match the fixed release.")


def validate_release(metadata: dict) -> None:
    expected = {
        "schema": "jp.nekowidget.moderation-release-metadata.v2",
        "sourceCommit": SOURCE_COMMIT, "buildNumber": "185", "githubRunId": str(RUN_ID),
        "githubRunAttempt": 1, "releaseEnvironment": "testflight", "releaseMode": "media-staging",
        "archiveDigestAlgorithm": "sha256-tree-v2",
        "archiveSha256": "d6f3e4f4764e980335f75e80db9fc45c8973faeb7b22aa4d991770632791a511",
    }
    require(all(metadata.get(key) == value for key, value in expected.items()),
            "Authenticated metadata is not the fixed Build 185 release.")


def unpack_encrypted_files(artifact_zip: Path, directory: Path) -> None:
    expected = {CIPHERTEXT, METADATA, AUTHENTICATION}
    with zipfile.ZipFile(artifact_zip) as archive:
        members = archive.infolist()
        require(len(members) == len(expected) and {item.filename for item in members} == expected,
                "Artifact ZIP must contain exactly the three expected files.")
        for item in members:
            kind = stat.S_IFMT(item.external_attr >> 16)
            limit = MAXIMUM_FILE_BYTES if item.filename == CIPHERTEXT else 256 * 1024
            require(not item.is_dir() and kind in (0, stat.S_IFREG)
                    and 0 < item.file_size <= limit, "Invalid encrypted artifact member.")
            with archive.open(item) as source, (directory / item.filename).open("xb") as target:
                shutil.copyfileobj(source, target)


def command(arguments: list[str], *, stage: str, password: bool = False) -> str:
    environment = {key: value for key, value in os.environ.items()
                   if key not in ("GH_TOKEN", "GITHUB_TOKEN", PASSWORD_ENV)}
    if password:
        require(bool(os.environ.get(PASSWORD_ENV)), "Artifact password is unavailable.")
        environment[PASSWORD_ENV] = os.environ[PASSWORD_ENV]
    try:
        result = subprocess.run(arguments, capture_output=True, text=True, check=False,
                                env=environment, timeout=180)
    except (OSError, subprocess.TimeoutExpired):
        raise DiagnosticError(f"{stage} could not complete; private tool output was suppressed.") from None
    # Never replay tool stderr, which can contain paths or decrypted content.
    require(result.returncode == 0, f"{stage} failed; private tool output was suppressed.")
    return result.stdout


def extract_dwarf(bundle: Path, directory: Path, metadata: dict) -> Path:
    spec = importlib.util.spec_from_file_location("signed_contents", CI / "verify-signed-artifact-contents.py")
    assert spec is not None and spec.loader is not None
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    with tarfile.open(bundle, "r:gz") as archive:
        members = archive.getmembers()
        names = [item.name for item in members]
        require(len(names) == len(set(names)), "Duplicate bundle paths.")
        require(all(name and not PurePosixPath(name).is_absolute()
                    and ".." not in PurePosixPath(name).parts and "\\" not in name and "\0" not in name
                    for name in names), "Unsafe bundle path.")
        try:
            digest = verifier.embedded_archive_sha256(archive, members)
        except SystemExit:
            raise DiagnosticError("The archive content digest could not be verified.") from None
        require(digest == metadata["archiveSha256"], "Archive content digest mismatch.")
        require(DWARF_MEMBER in names, "The app DWARF is missing.")
        member = archive.getmember(DWARF_MEMBER)
        require(member.isfile() and 0 < member.size <= MAXIMUM_FILE_BYTES,
                "The app DWARF must be a bounded regular file.")
        # Read only this exact regular member; never extract archive paths or links.
        dwarf = directory / "NekoWidget.dwarf"
        with archive.extractfile(member) as source, dwarf.open("xb") as target:
            shutil.copyfileobj(source, target)
    return dwarf


def verify_uuid(output: str) -> None:
    matches = re.findall(r"^UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\) .+$", output, re.MULTILINE)
    require(matches == [(APP_UUID.upper(), "arm64")] or matches == [(APP_UUID, "arm64")],
            "The DWARF UUID or architecture does not match both crash reports.")


def preferred_text_address(output: str) -> tuple[int, int]:
    segments = []
    for block in re.split(r"^Load command \d+\s*$", output, flags=re.MULTILINE):
        if re.search(r"^\s*cmd LC_SEGMENT_64\s*$", block, re.MULTILINE) and re.search(
                r"^\s*segname __TEXT\s*$", block, re.MULTILINE):
            address = re.findall(r"^\s*vmaddr (0x[0-9a-fA-F]+)\s*$", block, re.MULTILINE)
            size = re.findall(r"^\s*vmsize (0x[0-9a-fA-F]+)\s*$", block, re.MULTILINE)
            require(len(address) == len(size) == 1, "Ambiguous DWARF text segment.")
            segments.append((int(address[0], 16), int(size[0], 16)))
    require(len(segments) == 1, "The DWARF must have one preferred text segment.")
    base, size = segments[0]
    require(base > 0 and base % 4096 == 0 and 0 < size < MAXIMUM_FILE_BYTES,
            "Invalid preferred text address or size.")
    require(all(0 <= offset < size for frames in CRASH_FRAMES.values() for _, offset in frames),
            "A crash offset is outside the app text segment.")
    return base, size


def symbol_lines(output: str) -> list[str]:
    lines = output.strip().splitlines()
    require(0 < len(lines) <= 64, "Unexpected inline symbol count.")
    symbols = []
    for line in lines:
        match = re.fullmatch(r"(.+?) \(in NekoWidget\)(?: \((.+)\))?", line.strip())
        require(match is not None and not re.match(r"^(?:0x[0-9a-fA-F]+|\?\?\?)(?:\s|$)", match[1]),
                "An app frame could not be resolved.")
        location = match[2]
        symbols.append(match[1] + (f" ({location.rsplit('/', 1)[-1]})" if location else ""))
    return symbols


def resolve(input_directory: Path) -> list[str]:
    validate_provenance(read_object(input_directory / "run.json"),
                        read_object(input_directory / "artifact.json"))
    # Python cleanup also runs on a tool failure/interruption; the workflow owns
    # a second EXIT trap for the whole input directory on success or cancellation.
    with tempfile.TemporaryDirectory(prefix="private-", dir=input_directory) as temporary:
        directory = Path(temporary)
        unpack_encrypted_files(input_directory / "artifact.zip", directory)
        command([sys.executable, str(CI / "signed-artifact-authentication.py"), "verify",
                 "--ciphertext", str(directory / CIPHERTEXT), "--metadata", str(directory / METADATA),
                 "--authentication", str(directory / AUTHENTICATION)], stage="Authentication", password=True)
        metadata = read_object(directory / METADATA)
        validate_release(metadata)
        bundle = directory / "private.tar.gz"
        command(["openssl", "enc", "-d", "-aes-256-cbc", "-pbkdf2", "-iter", "200000",
                 "-pass", f"env:{PASSWORD_ENV}", "-in", str(directory / CIPHERTEXT),
                 "-out", str(bundle)], stage="Decryption", password=True)
        dwarf = extract_dwarf(bundle, directory, metadata)
        verify_uuid(command(["xcrun", "dwarfdump", "--uuid", str(dwarf)], stage="UUID inspection"))
        base, _ = preferred_text_address(command(
            ["xcrun", "otool", "-arch", "arm64", "-l", str(dwarf)], stage="Preferred address inspection"))
        offsets = sorted({offset for frames in CRASH_FRAMES.values() for _, offset in frames})
        # Use the verified unslid __TEXT address for both -l and the constructed
        # addresses. ASLR bases and all other incident details stay out of CI.
        resolved = {}
        for offset in offsets:
            # One offset per invocation keeps its inline stack unambiguous.
            output = command(["xcrun", "atos", "-arch", "arm64", "-o", str(dwarf), "-l", hex(base),
                              "-i", hex(base + offset)], stage="Symbolication")
            resolved[offset] = symbol_lines(output)
        lines = [f"Report {report}, frame {frame}: {symbol}"
                 for report, frames in CRASH_FRAMES.items() for frame, offset in frames
                 for symbol in resolved[offset]]
        require(len(lines) <= 256, "Unexpected total inline symbol count.")
        return lines


def interrupted(_signum: int, _frame: object) -> None:
    raise DiagnosticError("Diagnostic interrupted; temporary files are being removed.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-directory", required=True, type=Path)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    os.umask(0o077)
    try:
        lines = resolve(args.input_directory)
    except DiagnosticError as error:
        print(f"STOP: {error}", file=sys.stderr)
        return 1
    except Exception:
        print("STOP: Invalid diagnostic input or tool failure; no private output was retained.", file=sys.stderr)
        return 1
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
