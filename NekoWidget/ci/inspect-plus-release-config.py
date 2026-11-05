"""Read only public Plus configuration from the fixed 325/328 signed artifacts.

No build, Apple upload, provisioning, or configuration mutation. Authentication
precedes decryption; temporary plaintext is removed on success and failure.
"""
import argparse
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import signal
import sys
import tarfile
import tempfile
import zipfile

CI = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("diagnostic", CI / "resolve-build185-symbols.py")
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)
PUBLIC_KEYS = (
    "CFBundleIdentifier", "CFBundleVersion", "PlusStorefrontEnabled",
    "PlusMonthlyProductID", "PlusAnnualProductID", "PlusBillingClientEnabled",
    "PlusBillingAPIBaseURL", "PlusBillingRecoveryEnabled", "AppPrivacyURL",
)
RELEASES = {
    "325": (41319182447, 13088873181, "b6a2009e7eada182b69542fc192ac7fdbe92bbd0"),
    "328": (41829816288, 13323237995, "665ce2cfcd592b79c5f1b3c1b84891e06957c80d"),
}
# A dispatched workflow can select an earlier, CI-qualified release SHA.
# Bind the workflow run and signed product independently, never conflate them.
WORKFLOW_HEADS = {
    "325": "9d08cf03b36d1b6044cff2812cb769a8a232de67",
    "328": "665ce2cfcd592b79c5f1b3c1b84891e06957c80d",
}


def public_configuration(info, build):
    d.require(str(info.get("CFBundleVersion")) == build, "Unexpected application build")
    result = {key: info.get(key) for key in PUBLIC_KEYS}
    d.require(all(value is None or isinstance(value, (str, bool)) for value in result.values()), "Unexpected public setting type")
    d.require(all(not isinstance(value, str) or len(value) <= 512 for value in result.values()), "Public setting too long")
    return result


def validate_provenance(build, run, artifact):
    run_id, artifact_id, _source = RELEASES[build]
    workflow_head = WORKFLOW_HEADS[build]
    d.require(all(run.get(k) == v for k, v in {
        "id": run_id, "run_attempt": 1, "head_sha": workflow_head, "head_branch": "main",
        "event": "workflow_dispatch", "status": "completed", "conclusion": "success",
        "path": ".github/workflows/testflight.yml",
    }.items()) and run.get("repository", {}).get("full_name") == "soso-so-27/neko-widget", "Unexpected source run")
    prefix = "production-candidate" if build == "328" else "nekowidget-signed-artifacts"
    d.require(artifact.get("id") == artifact_id and artifact.get("expired") is False
              and artifact.get("name") == f"{prefix}-{run_id}-1"
              and artifact.get("workflow_run", {}).get("id") == run_id
              and artifact.get("workflow_run", {}).get("head_sha") == workflow_head, "Unexpected source artifact")


def inspect(root, build):
    run_id, _artifact_id, source = RELEASES[build]
    validate_provenance(build, d.read_object(root / "run.json"), d.read_object(root / "artifact.json"))
    if build == "328":
        d.CIPHERTEXT, d.METADATA, d.AUTHENTICATION = (
            "production-candidate.tar.gz.enc", "production-owner-metadata.json", "production-owner-authentication.json")
    with tempfile.TemporaryDirectory(prefix="private-", dir=root) as temporary:
        private = Path(temporary)
        d.unpack_encrypted_files(root / "artifact.zip", private)
        d.command([sys.executable, str(CI / "signed-artifact-authentication.py"), "verify",
                   "--ciphertext", str(private / d.CIPHERTEXT), "--metadata", str(private / d.METADATA),
                   "--authentication", str(private / d.AUTHENTICATION)], stage="Authentication", password=True)
        metadata = d.read_object(private / d.METADATA)
        expected = ({"schema": "jp.nekowidget.production-owner-artifact.v1", "source": source,
                     "build": build, "run": str(run_id), "attempt": "1", "internalOnly": True,
                     "profile": "app-store-candidate"} if build == "328" else
                    {"sourceCommit": source, "buildNumber": build, "githubRunId": str(run_id),
                     "githubRunAttempt": 1, "archiveDigestAlgorithm": "sha256-tree-v2"})
        d.require(all(metadata.get(k) == v for k, v in expected.items()), "Unexpected authenticated release")
        bundle = private / "private.tar.gz"
        d.command(["openssl", "enc", "-d", "-aes-256-cbc", "-pbkdf2", "-iter", "200000",
                   "-pass", f"env:{d.PASSWORD_ENV}", "-in", str(private / d.CIPHERTEXT), "-out", str(bundle)],
                  stage="Decryption", password=True)
        with tarfile.open(bundle, "r:gz") as archive:
            members = archive.getmembers()
            names = [m.name for m in members]
            d.require(len(names) == len(set(names)), "Duplicate archive members")
            # Read exact regular members in memory; never extract member paths.
            def read(name, limit):
                member = archive.getmember(name)
                d.require(member.isfile() and 0 < member.size <= limit, "Invalid fixed archive member")
                return archive.extractfile(member).read()
            app = public_configuration(plistlib.loads(read(
                "NekoWidget.xcarchive/Products/Applications/NekoWidget.app/Info.plist", 1024 * 1024)), build)
            if build == "328":
                ipas = [m.name for m in members if m.name.startswith("Export/") and m.name.endswith(".ipa")]
                d.require(len(ipas) == 1, "Expected one exported IPA")
                ipa = read(ipas[0], d.MAXIMUM_FILE_BYTES)
                d.require(hashlib.sha256(ipa).hexdigest() == metadata.get("ipaSHA256"), "IPA digest differs")
                with zipfile.ZipFile(io.BytesIO(ipa)) as exported:
                    name = "Payload/NekoWidget.app/Info.plist"
                    d.require(exported.namelist().count(name) == 1 and exported.getinfo(name).file_size <= 1024 * 1024, "Invalid exported plist")
                    d.require(public_configuration(plistlib.loads(exported.read(name)), build) == app, "Archive and IPA settings differ")
            else:
                spec = importlib.util.spec_from_file_location("contents", CI / "verify-signed-artifact-contents.py")
                verifier = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(verifier)
                d.require(verifier.embedded_archive_sha256(archive, members) == metadata.get("archiveSha256"), "Archive digest differs")
        return {"build": build, "authenticated": True, "publicConfiguration": app}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-directory", type=Path, required=True)
    parser.add_argument("--build", choices=tuple(RELEASES), required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, d.interrupted)
    signal.signal(signal.SIGINT, d.interrupted)
    try:
        print(json.dumps(inspect(args.input_directory, args.build), sort_keys=True))
    except d.DiagnosticError as error:
        # DiagnosticError messages are fixed in this module/helper. They never
        # interpolate private tool output or decrypted values.
        print("FAIL: " + str(error), file=sys.stderr)
        return 1
    except (Exception, SystemExit):
        print("FAIL: authenticated configuration inspection did not complete; private details suppressed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
