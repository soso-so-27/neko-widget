#!/usr/bin/env python3
"""Explicit owner-only internal report build settings and artifact checks."""
import argparse
import json
import plistlib
from pathlib import Path
import zipfile

SCOPE = "internal-owner-first-connection"
ORIGIN = "https://neko-window-sharing-staging.nakanishisoya.workers.dev"
PUBLIC_KEY = "T5C7__1xlc4XmIDr6zTJqMtdhBjPnMD10O3vFK_bYWg"
ENABLED = "SharingInternalEncryptedReportEnabled"
SCOPE_KEY = "SharingInternalEncryptedReportScope"


def settings(requested, mode, approval, scope, billing_requested=False):
    if type(requested) is not bool or type(billing_requested) is not bool:
        raise ValueError("Report requests must be explicit booleans.")
    # Combined builds also pass the workflow's signed UI-continuation runtime preflight.
    # Billing approval is checked separately; it never grants report permission.
    if requested and (mode != "media-staging" or approval != "YES" or scope != SCOPE):
        raise ValueError("Reports require separate protected internal approval, media-staging, and owner scope.")
    return {ENABLED: requested, SCOPE_KEY: SCOPE if requested else ""}


def verify_info(info, expected, *, extension=False):
    flag, scope = (False, "") if extension else (expected[ENABLED], expected[SCOPE_KEY])
    if type(info.get(ENABLED)) is not bool or info[ENABLED] is not flag or info.get(SCOPE_KEY) != scope:
        raise ValueError("Compiled internal report settings do not match the release boundary.")
    if flag:
        if (info.get("SharingReleaseMode") != "media-staging" or info.get("SharingAPIBaseURL") != ORIGIN
                or info.get("SharingModerationKeyID") != "moderation-v2" or info.get("SharingModerationPublicKey") != PUBLIC_KEY):
            raise ValueError("Internal report target/key changed.")
        for key in ("SharingFeatureEnabled", "SharingMediaEnabled"):
            value = info.get(key)
            if value is not True and not (type(value) is str and value == "YES"):
                raise ValueError("Internal reports require the media capability.")
        for key in ("SharingReviewPreviewEnabled", "SharingShareExtensionSendEnabled"):
            value = info.get(key)
            if value is not False and not (type(value) is str and value == "NO"):
                raise ValueError("Internal reports prohibit preview and direct Extension send.")


def metadata_settings(metadata):
    if metadata.get("schema") == "jp.nekowidget.moderation-release-metadata.v2":
        if ENABLED in metadata or "internalEncryptedReportEnabled" in metadata or "internalEncryptedReportScope" in metadata:
            raise ValueError("Legacy metadata cannot authorize reports.")
        return {ENABLED: False, SCOPE_KEY: ""}
    flag = metadata.get("internalEncryptedReportEnabled")
    scope = metadata.get("internalEncryptedReportScope")
    if metadata.get("schema") != "jp.nekowidget.moderation-release-metadata.v3" or type(flag) is not bool or scope != (SCOPE if flag else ""):
        raise ValueError("Report metadata is malformed.")
    if type(metadata.get("testFlightInternalTestingOnly")) is not bool:
        raise ValueError("Internal export metadata must be an explicit boolean.")
    if metadata.get("testFlightInternalTestingOnly") is not True and flag:
        raise ValueError("Report metadata requires internal-only export.")
    if flag and (metadata.get("releaseMode") != "media-staging" or metadata.get("moderationKeyId") != "moderation-v2"
                 or metadata.get("moderationPublicKey") != PUBLIC_KEY):
        raise ValueError("Report metadata target/key changed.")
    return {ENABLED: flag, SCOPE_KEY: scope}


def verify_ipa(path, expected):
    paths = {
        "Payload/NekoWidget.app/Info.plist": False,
        "Payload/NekoWidget.app/PlugIns/NekoWidgetShareExtension.appex/Info.plist": True,
        "Payload/NekoWidget.app/PlugIns/NekoWidgetWidgetExtension.appex/Info.plist": True,
    }
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        for name, extension in paths.items():
            if names.count(name) != 1 or archive.getinfo(name).file_size > 1024 * 1024:
                raise ValueError("IPA report Info.plist missing, duplicate or oversized.")
            verify_info(plistlib.loads(archive.read(name)), expected, extension=extension)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--requested", choices=("true", "false"), required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--approval", default="")
    parser.add_argument("--scope", default="")
    parser.add_argument("--billing-requested", choices=("true", "false"), default="false")
    parser.add_argument("--settings-file", type=Path, required=True)
    parser.add_argument("--env-file", type=Path)
    parser.add_argument("--app-source-info-plist", type=Path)
    parser.add_argument("--app-info-plist", type=Path)
    parser.add_argument("--share-info-plist", type=Path)
    parser.add_argument("--widget-info-plist", type=Path)
    parser.add_argument("--export-options-plist", type=Path)
    parser.add_argument("--ipa", type=Path)
    args = parser.parse_args()
    expected = settings(args.requested == "true", args.mode, args.approval, args.scope, args.billing_requested == "true")
    if args.app_source_info_plist:
        info = plistlib.loads(args.app_source_info_plist.read_bytes())
        if type(info.get(ENABLED)) is not bool or info[ENABLED] is not False or info.get(SCOPE_KEY) != "":
            raise ValueError("Source report defaults must remain OFF/empty.")
        args.app_source_info_plist.write_bytes(plistlib.dumps({**info, **expected}))
        with args.settings_file.open("x") as handle:
            json.dump(expected, handle)
        if args.env_file:
            with args.env_file.open("a") as handle:
                handle.write("RELEASE_INTERNAL_REPORTS_ENABLED=" + str(expected[ENABLED]).lower() + "\n")
                handle.write("RELEASE_INTERNAL_REPORTS_SCOPE=" + expected[SCOPE_KEY] + "\n")
    else:
        if json.loads(args.settings_file.read_text()) != expected:
            raise ValueError("Prepared report settings changed.")
        if args.app_info_plist:
            if not args.share_info_plist or not args.widget_info_plist:
                raise ValueError("Both compiled extensions are required.")
            for path, extension in ((args.app_info_plist, False), (args.share_info_plist, True), (args.widget_info_plist, True)):
                verify_info(plistlib.loads(path.read_bytes()), expected, extension=extension)
        elif args.export_options_plist:
            options = plistlib.loads(args.export_options_plist.read_bytes())
            if expected[ENABLED]:
                options["testFlightInternalTestingOnly"] = True
            args.export_options_plist.write_bytes(plistlib.dumps(options))
            if expected[ENABLED] and plistlib.loads(args.export_options_plist.read_bytes()).get("testFlightInternalTestingOnly") is not True:
                raise ValueError("Internal-only export restriction missing.")
        elif args.ipa:
            verify_ipa(args.ipa, expected)
        else:
            raise ValueError("An explicit preparation or verification operation is required.")
    print("PASS internal report release boundary")


if __name__ == "__main__":
    main()
