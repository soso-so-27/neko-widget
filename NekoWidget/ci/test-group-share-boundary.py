import importlib.util
from pathlib import Path
import plistlib
import unittest
import distribution_profile as owner
import re

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("sharing_release", ROOT / "ci/validate-sharing-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
preflight_spec = importlib.util.spec_from_file_location("share_preflight", ROOT / "ci/preflight-group-share-settings.py")
preflight = importlib.util.module_from_spec(preflight_spec)
preflight_spec.loader.exec_module(preflight)


class GroupShareBoundaryTests(unittest.TestCase):
    def test_actual_source_plists_and_configurations_before_build(self):
        # Real checked-in sources, with explicit owner release inputs. Xcode's
        # resolved settings are checked separately in CI before compilation.
        base = {}
        def load_config(path):
            for line in path.read_text(encoding="utf-8").splitlines():
                match = re.fullmatch(r"([A-Za-z_][A-Za-z_0-9]*)\s*=\s*(.*?)\s*", line)
                if match:
                    base[match[1]] = match[2]
        load_config(ROOT / "Config.xcconfig")
        base.update(GROUP_WINDOWS_ENABLED="YES", OWNER_INTERNAL_REPORTS_DISABLED="YES",
                    GROUP_REPORTING_PRODUCTION_ENABLED="NO", SHARING_RELEASE_MODE="media-staging",
                    SHARING_FEATURE_ENABLED="YES", SHARING_MEDIA_ENABLED="YES",
                    SHARING_SHARE_EXTENSION_HANDOFF_ENABLED="YES", SHARING_SHARE_EXTENSION_SEND_ENABLED="NO",
                    SHARING_REVIEW_PREVIEW_ENABLED="NO", SHARING_API_BASE_URL=owner.ORIGIN,
                    SHARING_MODERATION_KEY_ID="moderation-v2", SHARING_MODERATION_PUBLIC_KEY=owner.RECIPIENT)
        paths = ("NekoWidget/Info.plist", "NekoWidgetShareExtension/Info.plist", "NekoWidgetWidget/Info.plist")
        def rows(paths=paths):
            return [dict(target=target, buildSettings=dict(base, INFOPLIST_FILE=path))
                    for target, path in zip(preflight.TARGETS, paths)]
        preflight.verify(rows(), owner_internal=True)
        load_config(ROOT / "Config.Production.xcconfig")
        preflight.verify(rows())
        # Xcode omits empty values from -showBuildSettings JSON. The shipped
        # template expands them to empty plist strings, not a missing key.
        base = {key: value for key, value in base.items() if value != ""}
        preflight.verify(rows())
        missing_flag_rows = rows()
        del missing_flag_rows[1]["buildSettings"]["SHARING_FEATURE_ENABLED"]
        with self.assertRaises(ValueError):
            preflight.verify(missing_flag_rows)
        load_config(ROOT / "Config.Disabled.xcconfig")
        preflight.verify(rows((paths[0], "NekoWidgetShareExtension/Info.Disabled.plist", paths[2])))

    def pair(self):
        app = dict(CFBundleIdentifier="jp.nekowidget.app", GroupWindowsEnabled="YES", GroupShareExtensionEnabled="YES",
                   GroupShareKeychainGroup="TEAM.jp.nekowidget.app.group-share", SharingFeatureEnabled="YES",
                   SharingMediaEnabled="YES", SharingReviewPreviewEnabled="NO", SharingShareExtensionSendEnabled="NO",
                   SharingShareExtensionHandoffEnabled="YES", SharingReleaseMode="media-staging",
                   SharingAPIBaseURL="https://synthetic.invalid", SharingModerationKeyID="moderation-v2",
                   SharingModerationPublicKey="synthetic-public-key", SharingPrivacyURL="https://synthetic.invalid/privacy",
                   SharingSupportURL="https://synthetic.invalid/support", SharingCommunityStandardsURL="https://synthetic.invalid/standards")
        share = dict(app, CFBundleIdentifier="jp.nekowidget.app.share",
                     GroupShareAPIBaseURL=app["SharingAPIBaseURL"],
                     SharingInternalEncryptedReportEnabled=False, SharingInternalEncryptedReportScope="")
        for key in ("SharingAPIBaseURL", "SharingModerationKeyID", "SharingModerationPublicKey",
                    "SharingPrivacyURL", "SharingSupportURL", "SharingCommunityStandardsURL"):
            del share[key]
        return app, share

    def failures(self, app, share):
        failures = []
        release.validate_share_extension_boundary(app, share, failures)
        return failures

    def test_exact_host_configuration_required(self):
        app, share = self.pair()
        self.assertEqual(self.failures(app, share), [])
        for key in ("GroupShareAPIBaseURL", "SharingAPIBaseURL", "SharingModerationPublicKey", "SharingPrivacyURL", "GroupShareKeychainGroup"):
            with self.subTest(key=key):
                self.assertTrue(self.failures(app, dict(share, **{key: "another-value"})))
        for key in ("GroupWindowsEnabled", "GroupShareExtensionEnabled", "SharingMediaEnabled"):
            self.assertTrue(self.failures(app, dict(share, **{key: "NO"})))
        self.assertTrue(self.failures(app, dict(share, SharingShareExtensionSendEnabled="YES")))

    def test_reports_remain_forbidden_in_production_and_internal(self):
        app, share = self.pair()
        for mode in ("production", "media-staging"):
            app["SharingReleaseMode"] = share["SharingReleaseMode"] = mode
            self.assertEqual(self.failures(app, share), [])
            for key, value in (("SharingInternalEncryptedReportEnabled", True),
                               ("SharingInternalEncryptedReportScope", "internal-owner-first-connection"),
                               ("GroupReportingProductionEnabled", "YES"),
                               ("SharingModerationKeyID", "moderation-v2")):
                self.assertTrue(self.failures(app, dict(share, **{key: value})))

    def test_owner_photo_route_is_share_only_and_matches_host(self):
        app, share = self.pair()
        app.update(SharingAPIBaseURL=owner.ORIGIN, SharingModerationPublicKey=owner.RECIPIENT,
                   OwnerInternalReportsDisabled="YES", SharingInternalEncryptedReportEnabled=False,
                   SharingInternalEncryptedReportScope="")
        share.update(GroupShareAPIBaseURL=owner.ORIGIN, OwnerInternalReportsDisabled="YES",
                     SharingReviewPreviewEnabled=False)
        widget = dict(OwnerInternalReportsDisabled="YES", SharingInternalEncryptedReportEnabled=False,
                      SharingInternalEncryptedReportScope="", SharingReleaseMode="media-staging")
        products = dict(zip(owner.PLISTS, (app, share, widget)))
        owner.verify_products(products)
        for key, value in (("GroupShareAPIBaseURL", "https://foreign.example"),
                           ("GroupShareKeychainGroup", "TEAM.other.group-share"),
                           ("GroupShareExtensionEnabled", "NO"),
                           ("SharingAPIBaseURL", owner.ORIGIN),
                           ("SharingModerationPublicKey", owner.RECIPIENT)):
            with self.subTest(key=key), self.assertRaises(ValueError):
                owner.verify_products({**products, owner.PLISTS[1]: dict(share, **{key: value})})
        with self.assertRaises(ValueError):
            owner.verify_products({**products, owner.PLISTS[2]: share})

    def test_keychain_scope_excludes_widget_and_preserves_private_defaults(self):
        def read(path):
            return plistlib.loads((ROOT / path).read_bytes())
        app = read("NekoWidget/NekoWidget.entitlements")
        share = read("NekoWidgetShareExtension/NekoWidgetShareExtension.entitlements")
        widget = read("NekoWidgetWidget/NekoWidgetWidget.entitlements")
        scope = "$(AppIdentifierPrefix)$(APP_BUNDLE_IDENTIFIER).group-share"
        self.assertEqual(app["keychain-access-groups"], ["$(AppIdentifierPrefix)$(APP_BUNDLE_IDENTIFIER)", scope])
        self.assertEqual(share["keychain-access-groups"], ["$(AppIdentifierPrefix)$(SHARE_EXTENSION_BUNDLE_IDENTIFIER)", scope])
        self.assertNotIn(scope, widget.get("keychain-access-groups", []))
        self.assertEqual(share["com.apple.developer.sensitivecontentanalysis.client"], ["analysis"])
        for key in ("com.apple.developer.applesignin", "com.apple.developer.icloud-services", "aps-environment"):
            self.assertNotIn(key, share)


if __name__ == "__main__":
    unittest.main()
