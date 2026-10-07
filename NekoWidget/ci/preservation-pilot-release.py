#!/usr/bin/env python3
"""Fixed internal-Sandbox settings; never enable preservation in ordinary releases."""
from __future__ import annotations

import argparse
import json
import plistlib
from pathlib import Path

PRESERVATION_ORIGIN = "https://neko-preservation-staging-disabled.nakanishisoya.workers.dev"
BILLING_ORIGIN = "https://neko-window-sharing-staging.nakanishisoya.workers.dev"
AUDIENCE = "neko-preservation-staging"
MONTHLY_PRODUCT = "jp.nekowidget.plus.monthly"
EXTRA_COLLECTIONS = {
    "NSPrivacyCollectedDataTypeEmailAddress",
    "NSPrivacyCollectedDataTypePurchaseHistory",
    "NSPrivacyCollectedDataTypeOtherUserContent",
}
INFO_KEYS = {
    "MANAGED_PRESERVATION_ENABLED": "ManagedPreservationEnabled",
    "MANAGED_PRESERVATION_ORIGIN": "ManagedPreservationOrigin",
    "MANAGED_PRESERVATION_MEMBERSHIP_AUDIENCE": "ManagedPreservationMembershipAudience",
    "PLUS_STOREFRONT_ENABLED": "PlusStorefrontEnabled",
    "PLUS_MONTHLY_PRODUCT_ID": "PlusMonthlyProductID",
    "PLUS_ANNUAL_PRODUCT_ID": "PlusAnnualProductID",
    "PLUS_BILLING_CLIENT_ENABLED": "PlusBillingClientEnabled",
    "PLUS_BILLING_API_BASE_URL": "PlusBillingAPIBaseURL",
    "PLUS_BILLING_RECOVERY_ENABLED": "PlusBillingRecoveryEnabled",
    "PLUS_WINDOW_SPONSORSHIP_CLIENT_ENABLED": "PlusWindowSponsorshipClientEnabled",
}
FLAGS = {key for key in INFO_KEYS if key.endswith("_ENABLED")}


def settings(requested: bool, mode: str, approval: str, scope: str, *,
             billing_requested: bool = False, billing_approval: str = "",
             billing_scope: str = "") -> dict[str, str]:
    if requested and (mode != "media-staging" or approval != "YES" or scope != "internal"):
        raise ValueError("Preservation requires media-staging and the protected, internal-only pilot approval.")
    if billing_requested and (not requested or billing_approval != "YES" or billing_scope != "internal"):
        raise ValueError("Billing requires the internal preservation pilot and a separate protected Sandbox approval.")
    values = {key: "NO" if key in FLAGS else "" for key in INFO_KEYS}
    if requested:
        values["MANAGED_PRESERVATION_ENABLED"] = "YES"
        values.update({
            "MANAGED_PRESERVATION_ORIGIN": PRESERVATION_ORIGIN,
            "MANAGED_PRESERVATION_MEMBERSHIP_AUDIENCE": AUDIENCE,
        })
    if billing_requested:
        values.update({
            "PLUS_STOREFRONT_ENABLED": "YES", "PLUS_MONTHLY_PRODUCT_ID": MONTHLY_PRODUCT,
            "PLUS_BILLING_CLIENT_ENABLED": "YES", "PLUS_BILLING_API_BASE_URL": BILLING_ORIGIN,
            "PLUS_BILLING_RECOVERY_ENABLED": "YES",
        })
    return values


def billing_enabled(expected: dict[str, str]) -> bool:
    return expected["PLUS_BILLING_CLIENT_ENABLED"] == "YES"


def prepare_membership_info(info: dict, expected: dict[str, str]) -> dict:
    # Change only archive inputs in the protected internal build. Repository
    # defaults and ordinary beta users never become members-only by accident.
    if info.get("MembershipAccessEnforced") is not False:
        raise ValueError("Source membership default must remain disabled.")
    return {**info, "MembershipAccessEnforced": billing_enabled(expected)}


def add_privacy(privacy: dict) -> dict:
    if privacy.get("NSPrivacyTracking") is not False:
        raise ValueError("Pilot must preserve no tracking.")
    entries = privacy.get("NSPrivacyCollectedDataTypes")
    if not isinstance(entries, list):
        raise ValueError("Missing collected-data declarations.")
    names = [entry.get("NSPrivacyCollectedDataType") for entry in entries if isinstance(entry, dict)]
    if len(names) != len(entries) or len(set(names)) != len(names):
        raise ValueError("Malformed or duplicate collected-data declarations.")
    for name in sorted(EXTRA_COLLECTIONS - set(names)):
        entries.append({"NSPrivacyCollectedDataType": name,
                        "NSPrivacyCollectedDataTypeLinked": True,
                        "NSPrivacyCollectedDataTypeTracking": False,
                        "NSPrivacyCollectedDataTypePurposes": ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]})
    return privacy


def verify(info: dict, expected: dict[str, str], privacy: dict, widget_info: dict | None = None) -> None:
    for build_key, info_key in INFO_KEYS.items():
        if info.get(info_key, "") != expected[build_key]:
            raise ValueError(f"Archived {info_key} does not match the fixed release settings.")
    if info.get("MembershipAccessEnforced") is not billing_enabled(expected):
        raise ValueError("Archived app membership boundary does not match the release settings.")
    if billing_enabled(expected) and widget_info is None:
        raise ValueError("Sandbox billing requires verification of the widget membership boundary.")
    if widget_info is not None and widget_info.get("MembershipAccessEnforced") is not billing_enabled(expected):
        raise ValueError("Archived widget membership boundary does not match the release settings.")
    if expected["MANAGED_PRESERVATION_ENABLED"] == "YES":
        if info.get("SharingReleaseMode") != "media-staging":
            raise ValueError("Archived preservation must remain in media-staging.")
        declarations = {entry.get("NSPrivacyCollectedDataType"): entry for entry in privacy.get("NSPrivacyCollectedDataTypes", [])}
        if not EXTRA_COLLECTIONS <= declarations.keys():
            raise ValueError("Archived preservation privacy declarations are incomplete.")
        for name in EXTRA_COLLECTIONS:
            entry = declarations[name]
            if entry.get("NSPrivacyCollectedDataTypeLinked") is not True or entry.get("NSPrivacyCollectedDataTypeTracking") is not False:
                raise ValueError("Archived preservation privacy declaration changed.")


def prepare_export_options(options: dict, expected: dict[str, str]) -> dict:
    if expected["MANAGED_PRESERVATION_ENABLED"] == "YES":
        options["testFlightInternalTestingOnly"] = True
    elif options.get("testFlightInternalTestingOnly", False) is not False:
        raise ValueError("Ordinary export unexpectedly contains the preservation pilot restriction.")
    return options


def verify_export_options(options: dict, expected: dict[str, str]) -> None:
    required = expected["MANAGED_PRESERVATION_ENABLED"] == "YES"
    if options.get("testFlightInternalTestingOnly", False) is not required:
        raise ValueError("Export internal-testing restriction does not match the release settings.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--requested", choices=("true", "false"), required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--approval", default="")
    parser.add_argument("--scope", default="")
    parser.add_argument("--billing-requested", choices=("true", "false"), default="false")
    parser.add_argument("--billing-approval", default="")
    parser.add_argument("--billing-scope", default="")
    parser.add_argument("--env-file", type=Path)
    parser.add_argument("--settings-file", type=Path, required=True)
    parser.add_argument("--privacy-manifest", type=Path)
    parser.add_argument("--app-info-plist", type=Path)
    parser.add_argument("--widget-info-plist", type=Path)
    parser.add_argument("--app-source-info-plist", type=Path)
    parser.add_argument("--widget-source-info-plist", type=Path)
    parser.add_argument("--export-options-plist", type=Path)
    args = parser.parse_args()
    expected = settings(args.requested == "true", args.mode, args.approval, args.scope,
                        billing_requested=args.billing_requested == "true",
                        billing_approval=args.billing_approval, billing_scope=args.billing_scope)
    if args.export_options_plist:
        if json.loads(args.settings_file.read_text()) != expected:
            raise ValueError("Prepared preservation settings changed before exporting.")
        with args.export_options_plist.open("rb") as handle:
            options = prepare_export_options(plistlib.load(handle), expected)
        with args.export_options_plist.open("wb") as handle:
            plistlib.dump(options, handle)
        with args.export_options_plist.open("rb") as handle:
            verify_export_options(plistlib.load(handle), expected)
        print("Preservation export restriction: verified")
        return
    if not args.privacy_manifest:
        raise ValueError("Privacy manifest is required for preparation and archive verification.")
    if not args.app_info_plist and not args.env_file:
        raise ValueError("Environment output is required for preparation.")
    with args.privacy_manifest.open("rb") as handle:
        privacy = plistlib.load(handle)
    if args.app_info_plist:
        if json.loads(args.settings_file.read_text()) != expected:
            raise ValueError("Prepared preservation settings changed before archiving.")
        with args.app_info_plist.open("rb") as handle:
            info = plistlib.load(handle)
        widget_info = None
        if args.widget_info_plist:
            with args.widget_info_plist.open("rb") as handle:
                widget_info = plistlib.load(handle)
        verify(info, expected, privacy, widget_info)
    else:
        sources = [args.app_source_info_plist, args.widget_source_info_plist]
        if billing_enabled(expected) and any(path is None for path in sources):
            raise ValueError("Sandbox billing requires both app and widget source Info.plists.")
        prepared = []
        for path in sources:
            if path is not None:
                with path.open("rb") as handle:
                    prepared.append((path, prepare_membership_info(plistlib.load(handle), expected)))
        for path, info in prepared:
            with path.open("wb") as handle:
                plistlib.dump(info, handle)
        if expected["MANAGED_PRESERVATION_ENABLED"] == "YES":
            with args.privacy_manifest.open("wb") as handle:
                plistlib.dump(add_privacy(privacy), handle)
        args.settings_file.write_text(json.dumps(expected, indent=2) + "\n")
        with args.env_file.open("a") as handle:
            for key, value in expected.items():
                handle.write(f"RELEASE_{key}={value}\n")
    print("Preservation release settings: verified" if args.app_info_plist else "Preservation release settings: prepared")


if __name__ == "__main__":
    main()
