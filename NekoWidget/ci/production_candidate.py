"""Complete public candidate contract. No service provisioning or Apple upload.

The synthetic contract is deliberately confined to Simulator builds. It is never
accepted by the signed archive/export commands, even if supplied in protected vars.
"""
import argparse
import base64
import datetime
import fnmatch
import hashlib
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
from urllib.parse import urlsplit
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PROFILE = "app-store-candidate"
TARGETS = {
    "NekoWidget": ("", "NekoWidget", "Production/PrivacyInfo.xcprivacy"),
    "NekoWidgetShareExtension": ("PlugIns/NekoWidgetShareExtension.appex", "NekoWidgetShareExtension", "NekoWidgetShareExtension/PrivacyInfo.xcprivacy"),
    "NekoWidgetWidgetExtension": ("PlugIns/NekoWidgetWidgetExtension.appex", "NekoWidgetWidget", "NekoWidgetWidget/PrivacyInfo.xcprivacy"),
}
URL_KEYS = ("SHARING_API_BASE_URL", "MANAGED_PRESERVATION_ORIGIN", "APP_PRIVACY_URL",
            "APP_SUPPORT_URL", "SHARING_COMMUNITY_STANDARDS_URL", "OFFICIAL_WINDOW_FEED_URL")
INPUT_KEYS = set(URL_KEYS) | {"MANAGED_PRESERVATION_MEMBERSHIP_AUDIENCE", "SHARING_MODERATION_PUBLIC_KEY"}
SYNTHETIC_KEY = base64.urlsafe_b64encode(bytes(range(1, 33))).decode().rstrip("=")


def module(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / "ci" / (name + ".py"))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def require(condition, message):
    if not condition:
        raise ValueError(message)


def public_url(value, *, synthetic=False):
    require(isinstance(value, str) and value == value.strip() and not any(c.isspace() for c in value), "URL must be canonical")
    parsed = urlsplit(value)
    host = parsed.hostname or ""
    require(parsed.scheme == "https" and "." in host and not parsed.username and not parsed.password
            and not parsed.query and not parsed.fragment and parsed.port in (None, 443), "Public HTTPS URL required")
    require(not any(s in host.lower() for s in ("staging", "preview", "localhost", "example")), "Non-production host rejected")
    if synthetic:
        require(host.endswith(".candidate.test"), "Synthetic URLs must stay in reserved candidate.test")
    else:
        require(not host.endswith((".test", ".invalid", ".local", ".internal", ".lan", ".home.arpa", ".example")), "Reserved host rejected")
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        raise ValueError("Literal IP destinations are not public candidate configuration")
    require("$" not in value and "\\" not in value, "Unresolved or ambiguous URL")
    return value


def fixture():
    return {"values": dict(zip(URL_KEYS, (
        "https://api.candidate.test", "https://preservation.candidate.test",
        "https://policy.candidate.test/privacy/", "https://policy.candidate.test/support/",
        "https://policy.candidate.test/community/", "https://official.candidate.test/catalog.json"))) | {
            "MANAGED_PRESERVATION_MEMBERSHIP_AUDIENCE": "neko-production-synthetic",
            "SHARING_MODERATION_PUBLIC_KEY": SYNTHETIC_KEY},
        "recipientSHA256": hashlib.sha256(bytes(range(1, 33))).hexdigest(),
        "policyRevision": "2026-11-02", "distribution": PROFILE, "synthetic": True}


def settings(contract, *, synthetic=False):
    require(set(contract) == {"values", "recipientSHA256", "policyRevision", "distribution", "synthetic"}, "Unexpected candidate contract fields")
    require(contract["synthetic"] is synthetic, "Synthetic values are not a signed candidate")
    require(contract["distribution"] == PROFILE and contract["policyRevision"] == "2026-11-02", "Unreviewed distribution or policy revision")
    values = contract["values"]
    require(isinstance(values, dict) and set(values) == INPUT_KEYS, "Complete production deployment values required")
    for name in URL_KEYS:
        public_url(values[name], synthetic=synthetic)
    for name in ("SHARING_API_BASE_URL", "MANAGED_PRESERVATION_ORIGIN"):
        require(urlsplit(values[name]).path in ("", "/"), "Service origins cannot contain a path")
    require(len({urlsplit(values[key]).netloc for key in ("APP_PRIVACY_URL", "APP_SUPPORT_URL", "SHARING_COMMUNITY_STANDARDS_URL")}) == 1,
            "Public documents must use the same reviewed site")
    require(re.fullmatch(r"[A-Za-z0-9_-]{8,128}", values["MANAGED_PRESERVATION_MEMBERSHIP_AUDIENCE"]) is not None
            and "staging" not in values["MANAGED_PRESERVATION_MEMBERSHIP_AUDIENCE"].lower(), "Production audience required")
    key = values["SHARING_MODERATION_PUBLIC_KEY"]
    require(re.fullmatch(r"[A-Za-z0-9_-]{43}", key) is not None, "Canonical recipient key required")
    raw = base64.urlsafe_b64decode(key + "=")
    require(base64.urlsafe_b64encode(raw).decode().rstrip("=") == key
            and not module("validate-sharing-release").is_x25519_small_order_public_key(raw), "Invalid recipient key")
    require(hashlib.sha256(raw).hexdigest() == contract["recipientSHA256"], "Recipient differs from reviewed fingerprint")
    require(key != "T5C7__1xlc4XmIDr6zTJqMtdhBjPnMD10O3vFK_bYWg", "Staging recipient rejected")
    require(synthetic or key != SYNTHETIC_KEY, "Synthetic recipient rejected")
    # Read the existing production overlay, then bind only reviewed deployment inputs.
    result = {}
    for line in (ROOT / "Config.Production.xcconfig").read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([A-Z_0-9]+)\s*=\s*(.*)", line)
        if match:
            result[match[1]] = match[2].strip()
    result.update(values)
    result.update({"OWNER_INTERNAL_REPORTS_DISABLED": "NO",
                   "SHARE_EXTENSION_INFOPLIST_FILE": "NekoWidgetShareExtension/Info.plist",
                   "PHOTO_LIBRARY_USAGE_DESCRIPTION": "猫の写真を端末内で解析し、アルバムとウィジェットに表示します。共有では選んだ1枚を最大2,048pxに縮小し、位置情報を除いて暗号化して届けます。原本を自動送信しません。"})
    for name in result:
        result[name] = re.sub(r"\$\(([^)]+)\)", lambda m: result[m[1]], result[name])
    module("validate-production-settings").verify(result)
    require(result["SHARING_SHARE_EXTENSION_HANDOFF_ENABLED"] == "YES"
            and result["PERSONAL_ARCHIVE_ENABLED"] == "YES"
            and result["PLUS_WINDOW_SPONSORSHIP_CLIENT_ENABLED"] == "NO"
            and result["PLUS_MONTHLY_PRODUCT_ID"] == "jp.nekowidget.plus.monthly"
            and result["PLUS_ANNUAL_PRODUCT_ID"] == "", "Production product/capability contract changed")
    return result


def match_info(info, mapping, expected):
    for info_key, setting in mapping.items():
        require(info.get(info_key) == expected[setting], "Processed Info.plist differs: " + info_key)


def verify_products(app, contract, *, synthetic=False):
    expected = settings(contract, synthetic=synthetic)
    config = (ROOT / "Config.xcconfig").read_text(encoding="utf-8")
    identity_keys = dict(zip(TARGETS, ("APP_BUNDLE_IDENTIFIER", "SHARE_EXTENSION_BUNDLE_IDENTIFIER", "WIDGET_BUNDLE_IDENTIFIER")))
    infos = {}
    for target, (relative, source, privacy_source) in TARGETS.items():
        directory = app / relative
        info = plistlib.loads((directory / "Info.plist").read_bytes())
        infos[target] = info
        expected_id = re.search(r"(?m)^" + identity_keys[target] + r"\s*=\s*(\S+)", config)[1]
        require(info.get("CFBundleIdentifier") == expected_id, "Unexpected product bundle identifier: " + target)
        raw = plistlib.loads((ROOT / source / "Info.plist").read_bytes())
        # Bind every production setting exposed by each generated plist, not just app mode.
        for key, value in raw.items():
            if isinstance(value, str) and re.fullmatch(r"\$\([A-Z_0-9]+\)", value):
                setting = value[2:-1]
                if setting in expected:
                    match_info(info, {key: setting}, expected)
        require(info.get("SharingInternalEncryptedReportEnabled") is False
                and info.get("SharingInternalEncryptedReportScope") == "", "Internal reporting leaked into public product")
        if target != "NekoWidget":
            require(not any(info.get(k) for k in ("SharingAPIBaseURL", "SharingModerationPublicKey", "SharingModerationKeyID")), "Extension received report credentials")
        actual_privacy = plistlib.loads((directory / "PrivacyInfo.xcprivacy").read_bytes())
        require(actual_privacy == plistlib.loads((ROOT / privacy_source).read_bytes()), "Bundled privacy manifest differs: " + target)
    host, share, widget = (infos[k] for k in TARGETS)
    require(len({i.get("CFBundleVersion") for i in infos.values()}) == 1 and host.get("CFBundleVersion"), "Target build versions differ")
    require(len({i.get("CFBundleShortVersionString") for i in infos.values()}) == 1, "Target marketing versions differ")
    require(len({i.get("AppGroupIdentifier") for i in infos.values()}) == 1 and host.get("AppGroupIdentifier"), "Target App Groups differ")
    require(share.get("GroupShareKeychainGroup") == host.get("GroupShareKeychainGroup")
            and isinstance(host.get("GroupShareKeychainGroup"), str)
            and "$" not in host["GroupShareKeychainGroup"]
            and host["GroupShareKeychainGroup"].endswith(".group-share"), "Group Share Keychain scope differs or is unresolved")
    require(not any(k.startswith("GroupShare") for k in widget), "Widget received Group Share credentials")
    module("validate-sharing-release").validate_production(host, share, widget, expected)
    module("validate-official-window-release").validate_production(host, widget, expected, synthetic=synthetic)
    module("group-window-release").validate_production(host, share, expected)
    module("preservation-pilot-release").validate_production(host, widget, expected)
    return infos


def verify_export(options):
    require(options.get("method") == "app-store-connect" and options.get("destination") == "export"
            and options.get("testFlightInternalTestingOnly", False) is False
            and options.get("signingStyle") == "manual"
            and options.get("manageAppVersionAndBuildNumber") is False, "Public candidate export boundary changed")


def verify_signatures(app):
    """Inspect actual distribution signatures after archive AND after IPA export."""
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    for target, (relative, source, _) in TARGETS.items():
        directory = app / relative
        info = plistlib.loads((directory / "Info.plist").read_bytes())
        entitlements = plistlib.loads(subprocess.run(
            ["codesign", "-d", "--entitlements", ":-", str(directory)], check=True, capture_output=True).stdout)
        profile = plistlib.loads(subprocess.run(
            ["security", "cms", "-D", "-i", str(directory / "embedded.mobileprovision")], check=True, capture_output=True).stdout)
        team = entitlements.get("com.apple.developer.team-identifier")
        require(team == os.environ.get("APPLE_TEAM_ID") and team, "Signature does not belong to the selected release Team")
        require(profile.get("TeamIdentifier") == [team] and re.fullmatch(r"[A-Z0-9]{10}", team or ""), "Signature team differs from profile")
        expiration = profile.get("ExpirationDate")
        require(isinstance(expiration, datetime.datetime) and expiration.replace(tzinfo=datetime.timezone.utc)
                > datetime.datetime.now(datetime.timezone.utc), "Distribution profile is expired")
        require(entitlements.get("application-identifier") == f"{team}.{info['CFBundleIdentifier']}"
                and profile["Entitlements"].get("application-identifier") == entitlements["application-identifier"], "Signature identity differs from profile")
        for key, actual in entitlements.items():
            allowed = profile["Entitlements"].get(key)
            if isinstance(actual, list):
                require(isinstance(allowed, list) and all(any(
                    fnmatch.fnmatchcase(item, pattern) if isinstance(item, str) and isinstance(pattern, str)
                    else item == pattern for pattern in allowed) for item in actual), "Signed capability not authorized by profile: " + key)
            else:
                require(actual == allowed, "Signed capability differs from profile: " + key)
        require(entitlements.get("get-task-allow", False) is False and profile["Entitlements"].get("get-task-allow") is False
                and not profile.get("ProvisionedDevices") and not profile.get("ProvisionsAllDevices"), "Not an App Store distribution signature")
        require(entitlements.get("com.apple.security.application-groups") == [info["AppGroupIdentifier"]], "App Group signature differs")
        if target == "NekoWidget":
            require(entitlements.get("com.apple.developer.applesignin") == ["Default"]
                    and entitlements.get("aps-environment") == "production", "Public account/push entitlements missing")
            require(entitlements.get("com.apple.developer.icloud-container-identifiers") == [info["PersonalArchiveContainerIdentifier"]]
                    and entitlements.get("com.apple.developer.icloud-services") == ["CloudKit"]
                    and entitlements.get("com.apple.developer.icloud-container-environment") == "Production", "Existing CloudKit access boundary changed")
            require(entitlements.get("com.apple.developer.associated-domains") == ["applinks:nekonomado.com"], "Reviewed invite domain changed")
        else:
            require(not entitlements.get("aps-environment") and not entitlements.get("com.apple.developer.applesignin"), "Extension received account/push capabilities")
        if target != "NekoWidgetWidgetExtension":
            require(entitlements.get("keychain-access-groups") == [f"{team}.{info['CFBundleIdentifier']}", info["GroupShareKeychainGroup"]]
                    and info["GroupShareKeychainGroup"].startswith(team + "."), "Group Share credential scope differs from signature")
            require(entitlements.get("com.apple.developer.sensitivecontentanalysis.client") == ["analysis"], "Photo analysis entitlement missing")
        else:
            require(not any(str(k).endswith(".group-share") for k in entitlements.get("keychain-access-groups", [])), "Widget has Group Share credentials")


def run_build(contract, arguments, *, synthetic=False):
    expected = settings(contract, synthetic=synthetic)
    require(not synthetic or "iphonesimulator" in arguments, "Synthetic contract is Simulator-only")
    require(not any(arg in arguments for arg in ("-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration", "-exportArchive")), "No remote signing mutation or upload")
    # No shell interpolation and no -xcconfig precedence surprises.
    command = ["xcodebuild", "-project", "NekoWidget.xcodeproj", "-scheme", "NekoWidget", "-configuration", "Release"]
    command += arguments + [f"{k}={v}" for k, v in expected.items()]
    if any(action in arguments for action in ("build", "archive")):
        probe = []
        items = iter(command)
        for item in items:
            if item in ("-archivePath", "-resultBundlePath"):
                next(items)  # Inspect settings without creating the archive's output paths.
            elif item not in ("build", "archive"):
                probe.append(item)
        rows = json.loads(subprocess.run(probe + ["-showBuildSettings", "-json"], cwd=ROOT,
                                        check=True, capture_output=True, text=True).stdout)
        require(rows and any(row["target"] == "NekoWidget" for row in rows), "Missing resolved app settings")
        for row in rows:
            actual = row["buildSettings"]
            for key, value in expected.items():
                require(actual.get(key, "") == value, "Resolved production setting differs: " + key)
            conditions = actual.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "").split()
            require("DEBUG" not in conditions, "Debug public candidate rejected")
            required = {"NekoWidget": "NEKO_HOST_APP", "NekoWidgetShareExtension": "NEKO_SHARE_EXTENSION"}.get(row["target"])
            require(required is None or required in conditions, "Target-specific compilation boundary missing: " + row["target"])
    subprocess.run(command, cwd=ROOT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "build", "products", "export", "ipa", "fixture"))
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--synthetic", action="store_true")
    parser.add_argument("--path", type=Path)
    args, extra = parser.parse_known_args()
    if args.command == "fixture":
        require(args.synthetic, "Fixture is synthetic only")
        args.contract.write_text(json.dumps(fixture()), encoding="utf-8")
        return
    if args.command == "prepare":
        require(not args.synthetic, "Signed workflow cannot prepare synthetic contract")
        contract = json.loads(os.environ["PRODUCTION_CANDIDATE_CONFIG"])
        settings(contract)
        require(os.environ.get("PRODUCTION_CANDIDATE_APPROVED") == "YES", "Protected candidate approval missing")
        require(all(os.environ.get(k, "false") == "false" for k in
                    ("UPLOAD_TO_TESTFLIGHT", "INTERNAL_REPORTS_REQUESTED", "GROUP_WINDOWS_REQUESTED", "PRESERVATION_REQUESTED", "BILLING_REQUESTED")), "Candidate cannot use internal switches or upload")
        args.contract.write_text(json.dumps(contract), encoding="utf-8")
        with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as env:
            env.write("SHARING_EXPECTED_MODE=production\nRELEASE_ENVIRONMENT=production\nRELEASE_INTERNAL_REPORTS_ENABLED=false\nRELEASE_MODE_SUMMARY=production/App Store candidate (archive and export only)\n")
        return
    contract = json.loads(args.contract.read_text(encoding="utf-8"))
    settings(contract, synthetic=args.synthetic)
    if args.command == "build":
        run_build(contract, extra[1:] if extra[:1] == ["--"] else extra, synthetic=args.synthetic)
    elif args.command == "products":
        verify_products(args.path, contract, synthetic=args.synthetic)
        if not args.synthetic:
            verify_signatures(args.path)
    elif args.command == "export":
        require(not args.synthetic, "Synthetic candidate cannot export")
        verify_export(plistlib.loads(args.path.read_bytes()))
    elif args.command == "ipa":
        require(not args.synthetic, "Synthetic candidate cannot export")
        with tempfile.TemporaryDirectory() as directory, zipfile.ZipFile(args.path) as archive:
            names = archive.namelist()
            require(len(names) == len(set(names)) and all(not Path(n).is_absolute() and ".." not in Path(n).parts for n in names), "Unsafe or duplicate IPA entries")
            archive.extractall(directory)
            app = Path(directory) / "Payload/NekoWidget.app"
            verify_products(app, contract)
            verify_signatures(app)
    print("PASS production candidate " + args.command + (" (synthetic Simulator; not distributable)" if args.synthetic else ""))


if __name__ == "__main__":
    main()
