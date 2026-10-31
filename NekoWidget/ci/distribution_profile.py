"""Explicit distribution boundary. No key operations or server mutations."""
import argparse
import plistlib
import zipfile
from pathlib import Path

OWNER = "owner-internal"
REVIEWED = "existing-reviewed"
OFF_KEY = "OwnerInternalReportsDisabled"
OWNER_SCHEMA = "jp.nekowidget.moderation-release-metadata.v4"
ORIGIN = "https://neko-window-sharing-staging.nakanishisoya.workers.dev"
RECIPIENT = "T5C7__1xlc4XmIDr6zTJqMtdhBjPnMD10O3vFK_bYWg"
PLISTS = ("Info.plist", "PlugIns/NekoWidgetShareExtension.appex/Info.plist",
          "PlugIns/NekoWidgetWidgetExtension.appex/Info.plist")


def validate(profile, mode, internal_reports):
    if profile not in (OWNER, REVIEWED) or type(internal_reports) is not bool:
        raise ValueError("An explicit known distribution profile and boolean report input are required.")
    if profile == OWNER and (mode != "media-staging" or internal_reports):
        raise ValueError("Owner internal requires media-staging and real reports OFF.")


def verify_readiness(policy, *, profile, mode, internal_reports):
    from moderation_readiness import verify_distribution_readiness
    verify_distribution_readiness(policy, profile=profile, mode=mode, internal_reports=internal_reports)


def verify_info(info, *, extension=False, share_extension=False):
    if info.get(OFF_KEY) != "YES" or info.get("SharingInternalEncryptedReportEnabled") is not False:
        raise ValueError("Owner internal artifact must explicitly disable all real reports.")
    if info.get("SharingInternalEncryptedReportScope") != "":
        raise ValueError("Owner internal must have no report scope.")
    if info.get("GroupReportingProductionEnabled", "NO") != "NO":
        raise ValueError("Owner internal cannot select real group reporting.")
    if extension:
        if info.get("SharingReleaseMode") != "media-staging":
            raise ValueError("Extension release mode changed.")
        if any(info.get(k) for k in ("SharingAPIBaseURL", "SharingModerationKeyID", "SharingModerationPublicKey")):
            raise ValueError("Owner internal extensions cannot have a reporting recipient.")
        if info.get("SharingShareExtensionSendEnabled", "NO") not in (False, "NO"):
            raise ValueError("Direct extension send must stay OFF.")
        group_keys = ("GroupShareExtensionEnabled", "GroupShareAPIBaseURL", "GroupShareKeychainGroup")
        if any(key in info for key in group_keys):
            if not share_extension:
                raise ValueError("Widget cannot receive Group Share configuration.")
            enabled = info.get("GroupShareExtensionEnabled")
            if enabled not in ("YES", "NO") or info.get("GroupWindowsEnabled") != enabled:
                raise ValueError("Group Share switch must match the group runtime.")
            if info.get("GroupShareAPIBaseURL") != ORIGIN:
                raise ValueError("Owner Group Share photo endpoint changed.")
            scope = info.get("GroupShareKeychainGroup")
            if not isinstance(scope, str) or "$" in scope or not scope.endswith(".group-share"):
                raise ValueError("Group Share Keychain scope must be resolved.")
            if (info.get("SharingFeatureEnabled") != "YES" or info.get("SharingMediaEnabled") != "YES"
                    or info.get("SharingReviewPreviewEnabled") not in (False, "NO")):
                raise ValueError("Owner Group Share media runtime changed.")
        return
    if info.get("SharingReleaseMode") != "media-staging" or info.get("SharingAPIBaseURL") != ORIGIN:
        raise ValueError("Owner internal target changed.")
    if info.get("SharingModerationKeyID") != "moderation-v2" or info.get("SharingModerationPublicKey") != RECIPIENT:
        raise ValueError("Owner internal recipient changed.")
    for name in ("SharingReviewPreviewEnabled", "SharingShareExtensionSendEnabled"):
        if info.get(name) not in (False, "NO"):
            raise ValueError("Owner internal cannot enable preview or direct extension send.")


def verify_products(infos):
    for relative, info in infos.items():
        verify_info(info, extension=relative != "Info.plist", share_extension=relative == PLISTS[1])
    app, share = infos[PLISTS[0]], infos[PLISTS[1]]
    if "GroupShareExtensionEnabled" in share:
        for key in ("GroupShareExtensionEnabled", "GroupWindowsEnabled", "GroupShareKeychainGroup"):
            if app.get(key) != share.get(key):
                raise ValueError("Owner Group Share configuration differs from host: " + key)
        if share.get("GroupShareAPIBaseURL") != app.get("SharingAPIBaseURL"):
            raise ValueError("Owner Group Share endpoint differs from host.")


def verify_app(app):
    verify_products({relative: plistlib.loads((app / relative).read_bytes()) for relative in PLISTS})


def verify_ipa(path):
    with zipfile.ZipFile(path) as archive:
        infos = {}
        for relative in PLISTS:
            name = "Payload/NekoWidget.app/" + relative
            if archive.namelist().count(name) != 1 or archive.getinfo(name).file_size > 1024 * 1024:
                raise ValueError("Owner internal IPA plist missing, duplicate or oversized.")
            infos[relative] = plistlib.loads(archive.read(name))
        verify_products(infos)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--internal-reports", choices=("true", "false"), required=True)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--ipa", type=Path)
    parser.add_argument("--prepare-export", type=Path)
    parser.add_argument("--verify-export", type=Path)
    args = parser.parse_args()
    validate(args.profile, args.mode, args.internal_reports == "true")
    if args.profile == OWNER:
        if args.app:
            verify_app(args.app)
        if args.ipa:
            verify_ipa(args.ipa)
        if args.prepare_export:
            info = plistlib.loads(args.prepare_export.read_bytes())
            info["testFlightInternalTestingOnly"] = True
            args.prepare_export.write_bytes(plistlib.dumps(info))
        if args.verify_export and plistlib.loads(args.verify_export.read_bytes()).get("testFlightInternalTestingOnly") is not True:
            raise ValueError("Owner internal export must be Internal Only.")
    print("PASS explicit distribution profile: " + args.profile)


if __name__ == "__main__":
    main()
