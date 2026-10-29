#!/usr/bin/env python3
"""Owner-only group staging switch; verify compiled archive and exported IPA."""
import argparse
import plistlib
import zipfile
from pathlib import Path
import internal_report_release

ORIGIN = "https://neko-window-sharing-staging.nakanishisoya.workers.dev"
KEY = "GroupWindowsEnabled"
TRIAL_KEY = "GroupReportingProductionEnabled"


def resolve(requested: bool, mode: str, approval: str) -> str:
    if type(requested) is not bool:
        raise ValueError("Group request must be an explicit boolean.")
    if requested and (mode != "media-staging" or approval != "YES"):
        raise ValueError("Groups require media-staging and protected owner approval.")
    return "YES" if requested else "NO"


def resolve_trial(requested: bool, groups: str, mode: str, internal_requested: bool,
                  internal_approval: str, internal_scope: str) -> str:
    if type(requested) is not bool or type(internal_requested) is not bool:
        raise ValueError("Group report trial requests must be explicit booleans.")
    if requested:
        if groups != "YES" or not internal_requested:
            raise ValueError("Group report trials require both group_windows and internal_reports.")
        internal_report_release.settings(True, mode, internal_approval, internal_scope)
    return "YES" if requested else "NO"


def verify_info(info: dict, expected: str, trial: str = "NO") -> None:
    if info.get(KEY) != expected:
        raise ValueError("Compiled GroupWindowsEnabled must match the explicit YES/NO request.")
    if info.get(TRIAL_KEY) != trial or trial not in ("YES", "NO"):
        raise ValueError("Compiled GroupReportingProductionEnabled must match the explicit YES/NO trial request.")
    if trial == "YES":
        if expected != "YES":
            raise ValueError("Real group reports require group windows.")
        internal_report_release.verify_info(info, {
            internal_report_release.ENABLED: True,
            internal_report_release.SCOPE_KEY: internal_report_release.SCOPE,
        })
    if expected == "YES":
        if info.get("SharingReleaseMode") != "media-staging" or info.get("SharingAPIBaseURL") != ORIGIN:
            raise ValueError("Group build must use the reviewed staging endpoint.")
        for key in ("SharingFeatureEnabled", "SharingMediaEnabled"):
            value = info.get(key)
            if value is not True and value != "YES":
                raise ValueError("Group build requires sharing/media capability.")


def verify_ipa(path: Path, expected: str, trial: str = "NO") -> None:
    name = "Payload/NekoWidget.app/Info.plist"
    with zipfile.ZipFile(path) as archive:
        if archive.namelist().count(name) != 1 or archive.getinfo(name).file_size > 1024 * 1024:
            raise ValueError("IPA app Info.plist is missing, duplicate or oversized.")
        verify_info(plistlib.loads(archive.read(name)), expected, trial)
        if trial == "YES":
            for target in ("NekoWidgetShareExtension", "NekoWidgetWidgetExtension"):
                extension = f"Payload/NekoWidget.app/PlugIns/{target}.appex/Info.plist"
                if archive.namelist().count(extension) != 1 or archive.getinfo(extension).file_size > 1024 * 1024:
                    raise ValueError("IPA extension Info.plist is missing, duplicate or oversized.")
                info = plistlib.loads(archive.read(extension))
                if info.get(TRIAL_KEY, "NO") != "NO":
                    raise ValueError("Extensions must not enable real group reports.")
                internal_report_release.verify_info(info, {}, extension=True)


def prepare_export(options: dict, expected: str) -> dict:
    # Other independent internal pilots may already require this restriction.
    if expected == "YES":
        options["testFlightInternalTestingOnly"] = True
    return options


def verify_export(options: dict, expected: str) -> None:
    if expected == "YES" and options.get("testFlightInternalTestingOnly") is not True:
        raise ValueError("Group export must remain TestFlight internal testing only.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--requested", choices=("true", "false"), required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--approval", default="")
    parser.add_argument("--report-trial-requested", choices=("true", "false"), default="false")
    parser.add_argument("--internal-reports-requested", choices=("true", "false"), default="false")
    parser.add_argument("--internal-reports-approval", default="")
    parser.add_argument("--internal-reports-scope", default="")
    parser.add_argument("--env-file", type=Path)
    parser.add_argument("--app-info-plist", type=Path)
    parser.add_argument("--export-options-plist", type=Path)
    parser.add_argument("--verify-export-options-plist", type=Path)
    parser.add_argument("--ipa", type=Path)
    args = parser.parse_args()
    expected = resolve(args.requested == "true", args.mode, args.approval)
    trial = resolve_trial(args.report_trial_requested == "true", expected, args.mode,
                          args.internal_reports_requested == "true", args.internal_reports_approval,
                          args.internal_reports_scope)
    if args.env_file:
        with args.env_file.open("a") as output:
            output.write("RELEASE_GROUP_WINDOWS_ENABLED=" + expected + "\n")
            output.write("RELEASE_GROUP_REPORTING_PRODUCTION_ENABLED=" + trial + "\n")
    if args.app_info_plist:
        verify_info(plistlib.loads(args.app_info_plist.read_bytes()), expected, trial)
    if args.export_options_plist:
        options = prepare_export(plistlib.loads(args.export_options_plist.read_bytes()), expected)
        args.export_options_plist.write_bytes(plistlib.dumps(options))
    if args.ipa:
        verify_ipa(args.ipa, expected, trial)
    if args.verify_export_options_plist:
        verify_export(plistlib.loads(args.verify_export_options_plist.read_bytes()), expected)
    print("PASS group staging release boundary: " + expected + "; real group report trial: " + trial)


if __name__ == "__main__":
    main()
