#!/usr/bin/env python3
"""Owner-only group staging switch; verify compiled archive and exported IPA."""
import argparse
import base64
import json
import os
import plistlib
import re
import uuid
import zipfile
from pathlib import Path

ORIGIN = "https://neko-window-sharing-staging.nakanishisoya.workers.dev"
KEY = "GroupWindowsEnabled"
TWO_DEVICE_KEY = "OwnerStagingTwoDeviceEnabled"
TRIAL_KEY = "OwnerTwoDeviceTrial"


def trial_config(raw: str) -> dict[str, str]:
    def canonical(value, size: int) -> bool:
        if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", value):
            return False
        data = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
        return len(data) == size and base64.urlsafe_b64encode(data).decode().rstrip("=") == value

    try:
        data = json.loads(raw)
        if len(raw) <= 600 and set(data) == {"proof", "family", "window", "owner"} and all(
                canonical(data[k], size) for k, size in (("proof", 32), ("window", 16), ("owner", 32))):
            family = uuid.UUID(data["family"])
            if str(family) == data["family"] and family.version == 4:
                return data
    except (TypeError, AttributeError, KeyError, ValueError):
        pass
    raise ValueError("Missing or invalid protected owner two-device settings.") from None


def prepare_trial_info(info: dict, expected: dict[str, str] | None) -> dict:
    if TRIAL_KEY in info:
        raise ValueError("The checked-in app contains owner trial credentials.")
    return {**info, TRIAL_KEY: expected} if expected else info


def resolve(requested: bool, mode: str, approval: str) -> str:
    if type(requested) is not bool:
        raise ValueError("Group request must be an explicit boolean.")
    if requested and (mode != "media-staging" or approval != "YES"):
        raise ValueError("Groups require media-staging and protected owner approval.")
    return "YES" if requested else "NO"


def resolve_family(requested: bool, profile: str, mode: str, group_expected: str) -> str:
    if type(requested) is not bool:
        raise ValueError("Family notebook request must be an explicit boolean.")
    if requested and (profile != "owner-internal" or mode != "media-staging" or group_expected != "YES"):
        raise ValueError("Family notebooks require owner-internal, media-staging and approved group access.")
    return "YES" if requested else "NO"


def resolve_two_device(requested: bool, profile: str, mode: str, family_expected: str) -> str:
    if type(requested) is not bool:
        raise ValueError("Two-device exercise request must be an explicit boolean.")
    if requested and (profile != "owner-internal" or mode != "media-staging" or family_expected != "YES"):
        raise ValueError("Two-device exercise requires owner-internal, media-staging and approved family access.")
    return "YES" if requested else "NO"


def verify_info(info: dict, expected: str, family_expected: str | None = None,
                two_device_expected: str | None = None, *, sandbox_billing: bool = False,
                trial: dict[str, str] | None = None) -> None:
    if info.get(TRIAL_KEY) != trial or (trial is None and TRIAL_KEY in info):
        raise ValueError("The archive owner trial credential does not match its protected selection.")
    if two_device_expected is not None:
        if info.get(TWO_DEVICE_KEY, "NO") != two_device_expected:
            raise ValueError("Compiled two-device exercise must match the explicit request.")
        if two_device_expected == "YES" and (family_expected != "YES"
                or info.get("OwnerInternalReportsDisabled") != "YES"):
            raise ValueError("Two-device exercise requires family access with general reporting disabled.")
        if two_device_expected == "YES":
            billing = "YES" if sandbox_billing else "NO"
            if info.get("PlusBillingClientEnabled", "NO") != billing or info.get("PlusStorefrontEnabled", "NO") != billing:
                raise ValueError("Two-device archive billing must match the explicit Sandbox request.")
            if sandbox_billing and (info.get("PlusBillingAPIBaseURL") != ORIGIN
                    or info.get("PlusMonthlyProductID") != "jp.nekowidget.plus.monthly"
                    or info.get("PlusAnnualProductID") != ""
                    or info.get("PlusBillingRecoveryEnabled") != "NO"
                    or info.get("PlusWindowSponsorshipClientEnabled") != "NO"
                    or info.get("ManagedPreservationEnabled") != "NO"
                    or info.get("MembershipAccessEnforced") is not True or trial is None):
                raise ValueError("Two-device billing must use only the reviewed staging Sandbox and product.")
    if info.get(KEY) != expected:
        raise ValueError("Compiled GroupWindowsEnabled must match the explicit YES/NO request.")
    if family_expected is not None:
        if info.get("FamilyNotebookProductionEnabled") != family_expected:
            raise ValueError("Compiled family notebook adapter must match the explicit request.")
        if family_expected == "YES" and expected != "YES":
            raise ValueError("Real family notebooks require the approved group identity path.")
    if expected == "YES":
        if info.get("SharingReleaseMode") != "media-staging" or info.get("SharingAPIBaseURL") != ORIGIN:
            raise ValueError("Group build must use the reviewed staging endpoint.")
        for key in ("SharingFeatureEnabled", "SharingMediaEnabled"):
            value = info.get(key)
            if value is not True and value != "YES":
                raise ValueError("Group build requires sharing/media capability.")


def verify_ipa(path: Path, expected: str, family_expected: str | None = None,
               two_device_expected: str | None = None, *, sandbox_billing: bool = False,
               trial: dict[str, str] | None = None) -> None:
    name = "Payload/NekoWidget.app/Info.plist"
    with zipfile.ZipFile(path) as archive:
        if archive.namelist().count(name) != 1 or archive.getinfo(name).file_size > 1024 * 1024:
            raise ValueError("IPA app Info.plist is missing, duplicate or oversized.")
        verify_info(plistlib.loads(archive.read(name)), expected, family_expected, two_device_expected,
                    sandbox_billing=sandbox_billing, trial=trial)


def prepare_export(options: dict, expected: str) -> dict:
    # Other independent internal pilots may already require this restriction.
    if expected == "YES":
        options["testFlightInternalTestingOnly"] = True
    return options


def verify_export(options: dict, expected: str) -> None:
    if expected == "YES" and options.get("testFlightInternalTestingOnly") is not True:
        raise ValueError("Group export must remain TestFlight internal testing only.")


def validate_production(app: dict, share: dict, expected: dict) -> None:
    from production_candidate import match_info, require
    require(app.get(TWO_DEVICE_KEY, "NO") == "NO", "Public candidate carries the two-device exercise")
    require(TRIAL_KEY not in app and TRIAL_KEY not in share, "Public candidate carries an owner trial credential")
    match_info(app, {"SharingReleaseMode": "SHARING_RELEASE_MODE", "GroupWindowsEnabled": "GROUP_WINDOWS_ENABLED",
                     "SharingAPIBaseURL": "SHARING_API_BASE_URL", "FamilyNotebookProductionEnabled": "FAMILY_NOTEBOOK_PRODUCTION_ENABLED"}, expected)
    match_info(share, {"SharingReleaseMode": "SHARING_RELEASE_MODE", "GroupWindowsEnabled": "GROUP_WINDOWS_ENABLED",
                       "GroupShareAPIBaseURL": "SHARING_API_BASE_URL"}, expected)
    require(app.get("GroupShareExtensionEnabled") == share.get("GroupShareExtensionEnabled") == "YES", "Public Group Share must match the host")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--requested", choices=("true", "false"), required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--approval", default="")
    parser.add_argument("--family-requested", choices=("true", "false"), default="false")
    parser.add_argument("--two-device-requested", choices=("true", "false"), default="false")
    parser.add_argument("--sandbox-billing-requested", choices=("true", "false"), default="false")
    parser.add_argument("--profile", default="")
    parser.add_argument("--env-file", type=Path)
    parser.add_argument("--app-info-plist", type=Path)
    parser.add_argument("--app-source-info-plist", type=Path)
    parser.add_argument("--export-options-plist", type=Path)
    parser.add_argument("--verify-export-options-plist", type=Path)
    parser.add_argument("--ipa", type=Path)
    args = parser.parse_args()
    expected = resolve(args.requested == "true", args.mode, args.approval)
    family_expected = resolve_family(args.family_requested == "true", args.profile, args.mode, expected)
    two_device = resolve_two_device(args.two_device_requested == "true", args.profile, args.mode, family_expected)
    sandbox = args.sandbox_billing_requested == "true" and two_device == "YES"
    trial = trial_config(os.environ.get("OWNER_TWO_DEVICE_TRIAL_CONFIG", "")) if sandbox else None
    if args.app_source_info_plist:
        info = prepare_trial_info(plistlib.loads(args.app_source_info_plist.read_bytes()), trial)
        if trial:
            if os.environ.get("GITHUB_ACTIONS") == "true":
                print("::add-mask::" + trial["proof"])
            args.app_source_info_plist.write_bytes(plistlib.dumps(info))
    if args.env_file:
        with args.env_file.open("a") as output:
            output.write("RELEASE_GROUP_WINDOWS_ENABLED=" + expected + "\n")
            output.write("RELEASE_FAMILY_NOTEBOOK_ENABLED=" + family_expected + "\n")
            output.write("RELEASE_TWO_DEVICE_STAGING_ENABLED=" + two_device + "\n")
    if args.app_info_plist:
        verify_info(plistlib.loads(args.app_info_plist.read_bytes()), expected, family_expected, two_device,
                    sandbox_billing=sandbox, trial=trial)
    if args.export_options_plist:
        options = prepare_export(plistlib.loads(args.export_options_plist.read_bytes()), expected)
        args.export_options_plist.write_bytes(plistlib.dumps(options))
    if args.ipa:
        verify_ipa(args.ipa, expected, family_expected, two_device,
                   sandbox_billing=sandbox, trial=trial)
    if args.verify_export_options_plist:
        verify_export(plistlib.loads(args.verify_export_options_plist.read_bytes()), expected)
    print("PASS group staging release boundary: " + expected + "; family: " + family_expected)


if __name__ == "__main__":
    main()
