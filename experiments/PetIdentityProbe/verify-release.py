"""Fail-closed signing and delivery checks for the isolated, internal-only probe."""
import argparse
import ast
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shlex
import shutil
import stat
import subprocess
import sys
import time
import urllib.request
import urllib.error
import uuid
import zipfile

BUNDLE = "jp.nekowidget.petidentityprobe"
VERSION = "0.1"
MODEL_SHA256 = "32adffda4e65f790ae624d828b79db7a18f7fdb1facdce1cc91bb9951d948c0b"
ENTITLEMENTS = {
    "application-identifier", "com.apple.developer.team-identifier",
    "get-task-allow", "beta-reports-active", "keychain-access-groups",
}


class InvalidRelease(Exception):
    pass


def require(condition, message):
    if not condition:
        raise InvalidRelease(message)


def run(*command, input=None, failure_message="A required local verification command failed."):
    result = subprocess.run(command, input=input, capture_output=True, check=False)
    require(result.returncode == 0, failure_message)
    return result.stdout


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def load_plist(path):
    with Path(path).open("rb") as stream:
        return plistlib.load(stream)


def owner():
    return ":".join(os.environ[name] for name in (
        "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_SHA"
    ))


def owned_work_dir(path, missing_allowed=False):
    root = Path(os.environ["RUNNER_TEMP"]).resolve()
    expected = root / "pet-identity-testflight"
    work = Path(path)
    require(root != Path("/") and work == expected and not work.is_symlink(),
            "Unexpected release temporary directory.")
    if missing_allowed and not work.exists():
        return work
    require(work.is_dir() and (work / "owner").read_text() == owner(),
            "Release temporary directory is not owned by this run.")
    return work


def valid_uuid(value):
    require(isinstance(value, str) and str(uuid.UUID(value)).lower() == value.lower(),
            "Invalid provisioning profile UUID.")
    return value


def check_entitlements(entitlements, team, *, profile):
    require(isinstance(entitlements, dict) and set(entitlements) <= ENTITLEMENTS,
            "Unexpected entitlement; App Groups, APNs and iCloud are forbidden.")
    require(entitlements.get("application-identifier") == f"{team}.{BUNDLE}",
            "Signing application identifier is not the dedicated probe.")
    require(entitlements.get("com.apple.developer.team-identifier") == team,
            "Signing team does not match.")
    require(entitlements.get("get-task-allow") is False,
            "Debuggable signing is forbidden.")
    require(entitlements.get("beta-reports-active") is True,
            "App Store Connect beta distribution entitlement is missing.")
    groups = entitlements.get("keychain-access-groups", [])
    allowed = [[], [f"{team}.{BUNDLE}"]]
    if profile:
        # Apple's profile allowlist is broader than the app's claimed rights.
        # TN3125 documents this standard pair; never allow it in app signatures.
        allowed.extend([[f"{team}.*"], [f"{team}.*", "com.apple.token"]])
    require(groups in allowed, "Unexpected keychain group.")


def check_profile(profile, team, certificate):
    require(profile.get("TeamIdentifier") == [team], "Profile belongs to another team.")
    require(profile.get("ApplicationIdentifierPrefix") == [team],
            "Unexpected application identifier prefix.")
    check_entitlements(profile.get("Entitlements"), team, profile=True)
    require("ProvisionedDevices" not in profile and not profile.get("ProvisionsAllDevices"),
            "Only an App Store Connect distribution profile is allowed.")
    now = dt.datetime.now(dt.timezone.utc)
    for key in ("CreationDate", "ExpirationDate"):
        value = profile.get(key)
        require(isinstance(value, dt.datetime), "Profile validity dates are missing.")
        value = value.replace(tzinfo=dt.timezone.utc) if value.tzinfo is None else value
        require(value <= now if key == "CreationDate" else value > now,
                "Provisioning profile is not currently valid.")
    require(certificate in profile.get("DeveloperCertificates", []),
            "Profile does not contain the selected valid distribution certificate.")
    return valid_uuid(profile.get("UUID"))


def signing(work, team):
    require(re.fullmatch(r"[A-Z0-9]{10}", team), "Invalid team identifier.")
    keychain = str(work / "probe-signing.keychain-db")
    identities = run("security", "find-identity", "-v", "-p", "codesigning", keychain).decode()
    matches = re.findall(r'^\s*\d+\)\s+([A-F0-9]{40})\s+"Apple Distribution:[^"]+"',
                         identities, re.MULTILINE)
    require(len(matches) == 1, "Exactly one valid Apple Distribution identity is required.")
    pem = run("security", "find-certificate", "-c", "Apple Distribution", "-p", keychain)
    (work / "distribution.pem").write_bytes(pem)
    certificate = run("openssl", "x509", "-outform", "DER", input=pem)
    require(hashlib.sha1(certificate).hexdigest().upper() == matches[0],
            "Selected certificate does not match the valid signing identity.")
    run("openssl", "x509", "-checkend", "0", "-noout", input=pem)
    subject = run("openssl", "x509", "-noout", "-subject", "-nameopt", "RFC2253", input=pem).decode()
    require(re.search(r"(?:^|,)OU=" + re.escape(team) + r"(?:,|$)",
                      subject.strip().removeprefix("subject=").strip()), "Certificate team does not match.")
    (work / "distribution.der").write_bytes(certificate)
    profile_bytes = (work / "probe.mobileprovision").read_bytes()
    profile = plistlib.loads(run("security", "cms", "-D", "-i", str(work / "probe.mobileprovision")))
    profile_uuid = check_profile(profile, team, certificate)
    metadata = {"profile_uuid": profile_uuid, "certificate_sha1": matches[0]}
    (work / "signing.json").write_text(json.dumps(metadata))
    profile_dir = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
    profile_dir.mkdir(parents=True, exist_ok=True)
    installed = profile_dir / f"{profile_uuid}.mobileprovision"
    # Never overwrite or later delete a pre-existing profile.
    with installed.open("xb") as stream:
        stream.write(profile_bytes)
    (work / "installed-profile.json").write_text(json.dumps({
        "uuid": profile_uuid, "sha256": hashlib.sha256(profile_bytes).hexdigest(),
    }))
    previous = shlex.split(run("security", "list-keychains", "-d", "user").decode())
    (work / "original-keychains.json").write_text(json.dumps(previous))
    run("security", "list-keychains", "-d", "user", "-s", keychain, *previous)
    options = {
        "method": "app-store-connect", "destination": "export",
        "signingStyle": "manual", "signingCertificate": matches[0], "teamID": team,
        "provisioningProfiles": {BUNDLE: profile_uuid},
        "manageAppVersionAndBuildNumber": False, "stripSwiftSymbols": True,
        "testFlightInternalTestingOnly": True,
    }
    (work / "ExportOptions.plist").write_bytes(plistlib.dumps(options))


def check_info(info, build):
    require(info.get("CFBundleIdentifier") == BUNDLE, "App is not the dedicated probe bundle.")
    require(info.get("CFBundleExecutable") == "PetIdentityProbe", "Unexpected app executable.")
    require(info.get("CFBundleShortVersionString") == VERSION
            and info.get("CFBundleVersion") == build, "App version/build does not match.")
    require(info.get("UIDeviceFamily") == [1], "Only the independent iPhone target is allowed.")
    require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], "A device app is required.")
    require(not any(key.startswith("NS") and key.endswith("UsageDescription") for key in info),
            "Privacy permission usage descriptions are forbidden in this synthetic probe.")
    require(not any(key in info for key in ("NSExtension", "UIBackgroundModes", "CFBundleURLTypes")),
            "Unexpected extension, background or URL capability.")
    require(info.get("ITSAppUsesNonExemptEncryption") is False,
            "The probe encryption declaration is missing.")


def check_privacy_manifest(manifest):
    require(manifest.get("NSPrivacyTracking") is False
            and manifest.get("NSPrivacyTrackingDomains") == []
            and manifest.get("NSPrivacyCollectedDataTypes") == [],
            "Probe privacy manifest must declare no tracking or collected data.")
    expected = {
        "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
        "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
    }
    entries = manifest.get("NSPrivacyAccessedAPITypes")
    require(isinstance(entries, list) and len(entries) == len(expected),
            "Probe required-reason API declarations are incomplete.")
    actual = {}
    for entry in entries:
        require(isinstance(entry, dict)
                and set(entry) == {"NSPrivacyAccessedAPIType", "NSPrivacyAccessedAPITypeReasons"},
                "Unexpected required-reason API declaration.")
        category = entry["NSPrivacyAccessedAPIType"]
        require(category not in actual, "Duplicate required-reason API declaration.")
        actual[category] = entry["NSPrivacyAccessedAPITypeReasons"]
    require(actual == expected, "Probe required-reason API categories or reasons changed.")


def check_app(app, work, team, build):
    require(app.is_dir() and not app.is_symlink(), "Expected app bundle is missing.")
    check_info(load_plist(app / "Info.plist"), build)
    require(not list(app.rglob("*.appex")) and not list(app.rglob("*.app"))
            and not list(app.rglob("*.xctest")), "Nested applications, extensions and tests are forbidden.")
    ort_info = app / "Frameworks/onnxruntime.framework/Info.plist"
    if ort_info.exists():
        minimum = lambda value: tuple(int(part) for part in value.split(".")) + (0,) * (3 - len(value.split(".")))
        require(minimum(load_plist(ort_info)["MinimumOSVersion"])
                == minimum(load_plist(app / "Info.plist")["MinimumOSVersion"]),
                "ORT copied framework and app minimum OS differ.")
    models = [path for path in app.rglob("*") if path.is_file() and path.suffix.lower() == ".onnx"]
    require(models == [app / "model-fixed.onnx"], "Only the fixed probe model may be packaged.")
    require(digest(app / "model-fixed.onnx") == MODEL_SHA256, "Packaged model digest changed.")
    check_privacy_manifest(load_plist(app / "PrivacyInfo.xcprivacy"))
    generated_notices = Path(__file__).resolve().parent / "Generated/ThirdPartyNotices.txt"
    require(generated_notices.stat().st_size > 0
            and digest(app / "ThirdPartyNotices.txt") == digest(generated_notices),
            "Packaged third-party notices differ from the verified generated notices.")
    run("codesign", "--verify", "--deep", "--strict", str(app),
        failure_message="App code signature verification failed.")
    entitlement_path = work / "checked-entitlements.plist"
    entitlement_path.unlink(missing_ok=True)
    run("codesign", "-d", "--entitlements", str(entitlement_path), "--xml", str(app),
        failure_message="Signed app entitlement extraction failed.")
    check_entitlements(load_plist(entitlement_path), team, profile=False)
    for index in range(4):
        (work / f"app-certificate-{index}").unlink(missing_ok=True)
    run("codesign", "-d", f"--extract-certificates={work / 'app-certificate-'}", str(app),
        failure_message="Signed app certificate extraction failed.")
    certificate = (work / "distribution.der").read_bytes()
    require((work / "app-certificate-0").read_bytes() == certificate,
            "App signature uses a different distribution certificate.")
    if ort_info.exists():
        for index in range(4):
            (work / f"ort-certificate-{index}").unlink(missing_ok=True)
        run("codesign", "-d", f"--extract-certificates={work / 'ort-certificate-'}",
            str(ort_info.parent), failure_message="ORT framework certificate extraction failed.")
        require((work / "ort-certificate-0").read_bytes() == certificate,
                "ORT framework signature uses a different distribution certificate.")
    embedded = plistlib.loads(run("security", "cms", "-D", "-i", str(app / "embedded.mobileprovision"),
        failure_message="Embedded provisioning profile decoding failed."))
    expected = json.loads((work / "signing.json").read_text())["profile_uuid"]
    require(check_profile(embedded, team, certificate) == expected,
            "App embedded a different provisioning profile.")


def check_ipa(work, team, build):
    options = load_plist(work / "ExportOptions.plist")
    require(options.get("testFlightInternalTestingOnly") is True
            and options.get("method") == "app-store-connect"
            and set(options.get("provisioningProfiles", {})) == {BUNDLE},
            "Export is not dedicated internal TestFlight distribution.")
    ipas = list((work / "Export").glob("*.ipa"))
    require(len(ipas) == 1 and ipas[0].name == "PetIdentityProbe.ipa", "Unexpected exported IPA set.")
    unpacked = work / "UnpackedIPA"
    unpacked.mkdir()
    with zipfile.ZipFile(ipas[0]) as archive:
        for item in archive.infolist():
            path = PurePosixPath(item.filename)
            require(not path.is_absolute() and ".." not in path.parts and "\\" not in item.filename
                    and not stat.S_ISLNK(item.external_attr >> 16), "Unsafe IPA archive member.")
        archive.extractall(unpacked)
    apps = list((unpacked / "Payload").iterdir())
    require(len(apps) == 1 and apps[0].name == "PetIdentityProbe.app", "Unexpected IPA payload.")
    check_app(apps[0], work, team, build)
    (work / "verified-ipa.sha256").write_text(digest(ipas[0]))


def check_payload(work):
    require(digest(work / "Export/PetIdentityProbe.ipa") == (work / "verified-ipa.sha256").read_text(),
            "IPA changed after verification.")


def base64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def jwt_signature(der):
    # OpenSSL P-256 ECDSA emits a short DER sequence of two positive integers.
    require(len(der) >= 8 and der[0] == 0x30 and der[1] == len(der) - 2,
            "API key did not produce a P-256 signature.")
    offset, values = 2, []
    for _ in range(2):
        require(offset + 2 <= len(der) and der[offset] == 2, "Invalid API signature.")
        length = der[offset + 1]
        require(1 <= length <= 33 and offset + 2 + length <= len(der), "Invalid API signature.")
        value = der[offset + 2:offset + 2 + length].lstrip(b"\0")
        require(len(value) <= 32, "API key must use P-256.")
        values.append(value.rjust(32, b"\0"))
        offset += 2 + length
    require(offset == len(der), "Unexpected API signature data.")
    return b"".join(values)


def check_app_record(work, record_id):
    require(re.fullmatch(r"[0-9]{8,12}", record_id), "Dedicated App Store Connect record is not configured.")
    key_id, issuer = os.environ["APP_STORE_CONNECT_KEY_ID"], os.environ["APP_STORE_CONNECT_ISSUER_ID"]
    require(re.fullmatch(r"[A-Z0-9]{10}", key_id), "Invalid API key identifier.")
    uuid.UUID(issuer)
    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    claims = {"iss": issuer, "iat": now, "exp": now + 300, "aud": "appstoreconnect-v1"}
    payload = b".".join(base64url(json.dumps(value, separators=(",", ":")).encode())
                        for value in (header, claims))
    signature = run("openssl", "dgst", "-sha256", "-sign",
                    str(work / "private_keys" / f"AuthKey_{key_id}.p8"), input=payload)
    token = (payload + b"." + base64url(jwt_signature(signature))).decode()
    request = urllib.request.Request(
        f"https://api.appstoreconnect.apple.com/v1/apps/{record_id}?fields%5Bapps%5D=bundleId",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            data = json.load(response).get("data", {})
    except urllib.error.HTTPError as error:
        if error.code == 401:
            raise InvalidRelease("App Store Connect rejected API authentication (HTTP 401).") from None
        if error.code == 403:
            raise InvalidRelease("App Store Connect denied access to the app record (HTTP 403).") from None
        if error.code == 404:
            raise InvalidRelease("The dedicated App Store Connect record was not found (HTTP 404).") from None
        raise InvalidRelease("App Store Connect app-record lookup failed.") from None
    require(data.get("type") == "apps" and data.get("id") == record_id
            and data.get("attributes", {}).get("bundleId") == BUNDLE,
            "App Store Connect record does not match the dedicated probe bundle.")


def check_altool(work, stage):
    text = (work / f"altool-{stage}.log").read_text(errors="replace")
    require(not re.search(r"ERROR:|Failed to (validate|upload)|ENTITY_ERROR|UPLOAD FAILED|VALIDATION FAILED",
                          text, re.IGNORECASE), "App Store Connect reported a delivery error.")
    marker = "VERIFY SUCCEEDED with no errors" if stage == "validate" else "UPLOAD SUCCEEDED with no errors"
    require(marker in text, "App Store Connect did not confirm successful delivery.")


def safe_diagnostics(text):
    # Only our literal verification messages may pass through unchanged.
    tree = ast.parse(Path(__file__).read_text(encoding="utf-8"))
    fixed = {"Release verification could not complete.", "A required local verification command failed."}
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            if node.func.id == "run":
                for keyword in node.keywords:
                    if (keyword.arg == "failure_message" and isinstance(keyword.value, ast.Constant)
                            and isinstance(keyword.value.value, str)):
                        fixed.add(keyword.value.value)
            index = 1 if node.func.id == "require" else 0 if node.func.id == "InvalidRelease" else None
            if index is not None and len(node.args) > index:
                value = node.args[index]
                if isinstance(value, ast.Constant) and isinstance(value.value, str):
                    fixed.add(value.value)
    categories = (
        (r"No profiles for|requires a provisioning profile|profile.*not found", "No matching provisioning profile was found."),
        (r"doesn't include signing certificate|does not include signing certificate", "Provisioning profile/certificate mismatch."),
        (r"No signing certificate|no identity found", "Signing identity is unavailable to Xcode."),
        (r"does not support provisioning profiles", "A non-app target received a provisioning profile."),
        (r"errSecInternalComponent|User interaction is not allowed", "Signing keychain access failed."),
        (r"Command CodeSign failed", "The CodeSign command failed."),
        (r"Could not resolve package dependencies", "Swift package resolution failed."),
    )
    emitted = []
    for line in text.splitlines():
        clean = line.strip()
        if clean in fixed:
            emitted.append(clean)
        elif match := re.search(r"([^/\\:\s]+\.swift:\d+:\d+: error: .+)$", clean):
            # Public source locations are useful, but never copy paths or long
            # encoded tokens from a tool's diagnostic into this public job log.
            value = match[1]
            if re.search(r"PRIVATE|Authorization|Bearer|eyJ", value, re.IGNORECASE):
                continue
            value = re.sub(r"(?:/[\w .@~-]+){2,}", "<path>", value)
            value = re.sub(r"[A-Za-z0-9_+/=-]{30,}", "<redacted>", value)
            emitted.append(value[:280])
        else:
            for pattern, message in categories:
                if re.search(pattern, clean, re.IGNORECASE):
                    emitted.append(message)
                    break
            for code in re.findall(r"\bITMS-\d{5}\b", clean):
                emitted.append(f"App Store Connect returned {code}.")
    return list(dict.fromkeys(emitted))[-5:]


def diagnose(work, stage):
    require(re.fullmatch(r"[a-z][a-z-]{0,40}", stage), "Invalid diagnostic stage.")
    text = (work / f"{stage}.log").read_text(errors="replace")
    messages = safe_diagnostics(text)
    for message in messages:
        print(message)
    if not messages:
        print("No allowlisted error diagnostic was available; raw logs were withheld.")


def cleanup(work):
    if not work.exists():
        return
    failures = []
    original = work / "original-keychains.json"
    if original.exists():
        try:
            run("security", "list-keychains", "-d", "user", "-s", *json.loads(original.read_text()))
        except (InvalidRelease, ValueError, OSError):
            failures.append("keychain search list")
    installed = work / "installed-profile.json"
    if installed.exists():
        try:
            metadata = json.loads(installed.read_text())
            profile_uuid = valid_uuid(metadata["uuid"])
            profile = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles" / f"{profile_uuid}.mobileprovision"
            if profile.exists():
                require(not profile.is_symlink() and digest(profile) == metadata["sha256"],
                        "Installed profile changed; it will not be removed.")
                profile.unlink()
        except (InvalidRelease, ValueError, KeyError, OSError):
            failures.append("dedicated profile")
    keychain = work / "probe-signing.keychain-db"
    if keychain.exists():
        try:
            run("security", "delete-keychain", str(keychain))
        except (InvalidRelease, OSError):
            failures.append("temporary keychain")
    # owned_work_dir already checked the exact, non-symlink immediate child.
    shutil.rmtree(work)
    require(not failures, "Cleanup could not complete all owned signing resources.")


def self_test():
    team, certificate = "ABCDEFGHIJ", b"test-certificate"
    now = dt.datetime.now(dt.timezone.utc)
    profile = {
        "UUID": "00000000-0000-0000-0000-000000000001", "TeamIdentifier": [team],
        "ApplicationIdentifierPrefix": [team], "DeveloperCertificates": [certificate],
        "CreationDate": now - dt.timedelta(days=1), "ExpirationDate": now + dt.timedelta(days=1),
        "Entitlements": {"application-identifier": f"{team}.{BUNDLE}",
                         "com.apple.developer.team-identifier": team,
                         "get-task-allow": False, "beta-reports-active": True},
    }
    check_profile(profile, team, certificate)
    for groups in ([f"{team}.*"], [f"{team}.*", "com.apple.token"]):
        check_profile({**profile, "Entitlements": {
            **profile["Entitlements"], "keychain-access-groups": groups,
        }}, team, certificate)
    for groups in ([], [f"{team}.{BUNDLE}"]):
        check_entitlements({**profile["Entitlements"], "keychain-access-groups": groups},
                           team, profile=False)
    for groups in ([f"{team}.*"], ["com.apple.token"],
                   [f"{team}.*", "com.apple.token"],
                   [f"{team}.{BUNDLE}", "com.apple.token"]):
        try:
            check_entitlements({**profile["Entitlements"], "keychain-access-groups": groups},
                               team, profile=False)
        except InvalidRelease:
            continue
        raise InvalidRelease("A profile-only keychain group was allowed in an app signature.")
    variants = [
        {**profile, "ProvisionedDevices": []},
        {**profile, "ExpirationDate": now - dt.timedelta(seconds=1)},
        {**profile, "DeveloperCertificates": [b"another-certificate"]},
        {**profile, "TeamIdentifier": ["OTHERTEAM1"]},
    ]
    for change in (
        {"application-identifier": f"{team}.jp.nekowidget.app"},
        {"get-task-allow": True}, {"com.apple.security.application-groups": []},
        {"aps-environment": "production"}, {"com.apple.developer.icloud-services": []},
        {"keychain-access-groups": [f"{team}.jp.nekowidget.app"]},
        {"keychain-access-groups": ["OTHERTEAM1.*", "com.apple.token"]},
        {"keychain-access-groups": [f"{team}.*", "com.apple.token", "unexpected.group"]},
    ):
        variants.append({**profile, "Entitlements": {**profile["Entitlements"], **change}})
    for variant in variants:
        try:
            check_profile(variant, team, certificate)
        except InvalidRelease:
            continue
        raise InvalidRelease("A forbidden signing fixture passed.")
    info = {"CFBundleIdentifier": BUNDLE, "CFBundleExecutable": "PetIdentityProbe",
            "CFBundleShortVersionString": VERSION, "CFBundleVersion": "1",
            "UIDeviceFamily": [1], "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "ITSAppUsesNonExemptEncryption": False}
    check_info(info, "1")
    for change in ({"NSPhotoLibraryUsageDescription": "forbidden"},
                   {"NSPhotoLibraryAddUsageDescription": "forbidden"},
                   {"CFBundleIdentifier": "jp.nekowidget.app"},
                   {"CFBundleVersion": "2"}):
        try:
            check_info({**info, **change}, "1")
        except InvalidRelease:
            continue
        raise InvalidRelease("A forbidden app metadata fixture passed.")
    manifest = {"NSPrivacyTracking": False, "NSPrivacyTrackingDomains": [],
                "NSPrivacyCollectedDataTypes": [], "NSPrivacyAccessedAPITypes": [
                    {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategorySystemBootTime",
                     "NSPrivacyAccessedAPITypeReasons": ["35F9.1"]},
                    {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp",
                     "NSPrivacyAccessedAPITypeReasons": ["C617.1"]},
                ]}
    check_privacy_manifest(manifest)
    for change in ({"NSPrivacyTracking": True}, {"NSPrivacyAccessedAPITypes": []}):
        try:
            check_privacy_manifest({**manifest, **change})
        except InvalidRelease:
            continue
        raise InvalidRelease("A forbidden privacy fixture passed.")
    diagnostics = safe_diagnostics(
        "-----BEGIN PRIVATE KEY-----\nDO_NOT_PUBLISH_THIS_SECRET\n"
        "/private/runner/ProbeApp.swift:12:8: error: cannot find type Example in scope\n"
        "Provisioning profile SECRET_PROFILE does not support provisioning profiles\n"
        "ERROR ITMS-90035: SECRET_CERTIFICATE\n"
    )
    require(len(diagnostics) == 3 and not any("SECRET" in value or "/private/" in value for value in diagnostics),
            "Safe diagnostics leaked a private fixture or lost all actionable context.")
    require(safe_diagnostics("Signed app certificate extraction failed.\nSECRET_CERTIFICATE")
            == ["Signed app certificate extraction failed."],
            "Command-specific diagnostics leaked data or lost their stage.")
    print("Dedicated release checks passed: profile, metadata, privacy and diagnostic-redaction fixtures.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("signing", "app", "ipa", "payload", "app-record", "altool", "summary", "cleanup", "diagnose", "self-test"))
    parser.add_argument("--work-dir")
    parser.add_argument("--team", default="")
    parser.add_argument("--build", default="")
    parser.add_argument("--app", type=Path)
    parser.add_argument("--app-record-id", default="")
    parser.add_argument("--stage", choices=("validate", "upload"))
    parser.add_argument("--diagnostic-stage", default="")
    args = parser.parse_args()
    if args.command == "self-test":
        self_test()
        return
    work = owned_work_dir(args.work_dir, missing_allowed=args.command == "cleanup")
    if args.command == "signing":
        signing(work, args.team)
    elif args.command == "app":
        check_app(args.app, work, args.team, args.build)
    elif args.command == "ipa":
        check_ipa(work, args.team, args.build)
    elif args.command == "payload":
        check_payload(work)
    elif args.command == "app-record":
        check_app_record(work, args.app_record_id)
    elif args.command == "altool":
        check_altool(work, args.stage)
    elif args.command == "cleanup":
        cleanup(work)
    elif args.command == "diagnose":
        diagnose(work, args.diagnostic_stage)
    elif args.command == "summary":
        check_payload(work)
        require(re.fullmatch(r"[1-9][0-9]{0,8}", args.build), "Invalid summary build number.")
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as stream:
            stream.write("\n### Pet Identity Probe · internal TestFlight\n\n"
                         f"- Source SHA: `{os.environ['GITHUB_SHA']}`\n"
                         f"- Bundle: `{BUNDLE}`\n- Version: `{VERSION} ({args.build})`\n"
                         f"- IPA SHA-256: `{(work / 'verified-ipa.sha256').read_text()}`\n"
                         "- Archive and IPA verified; internal-only validation/upload succeeded.\n")


if __name__ == "__main__":
    try:
        main()
    except (InvalidRelease, OSError, ValueError, KeyError, TypeError) as error:
        # No profile/certificate/response contents or command arguments in public output.
        message = str(error) if isinstance(error, InvalidRelease) else "Release verification could not complete."
        print(message, file=sys.stderr)
        raise SystemExit(1)
