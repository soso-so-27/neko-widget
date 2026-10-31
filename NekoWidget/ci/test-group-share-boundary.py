import importlib.util
from pathlib import Path
import plistlib
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("sharing_release", ROOT / "ci/validate-sharing-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class GroupShareBoundaryTests(unittest.TestCase):
    def pair(self):
        app = dict(CFBundleIdentifier="jp.nekowidget.app", GroupWindowsEnabled="YES", GroupShareExtensionEnabled="YES",
                   GroupShareKeychainGroup="TEAM.jp.nekowidget.app.group-share", SharingFeatureEnabled="YES",
                   SharingMediaEnabled="YES", SharingReviewPreviewEnabled="NO", SharingShareExtensionSendEnabled="NO",
                   SharingShareExtensionHandoffEnabled="YES", SharingReleaseMode="media-staging",
                   SharingAPIBaseURL="https://synthetic.invalid", SharingModerationKeyID="moderation-v2",
                   SharingModerationPublicKey="synthetic-public-key", SharingPrivacyURL="https://synthetic.invalid/privacy",
                   SharingSupportURL="https://synthetic.invalid/support", SharingCommunityStandardsURL="https://synthetic.invalid/standards")
        return app, dict(app)

    def failures(self, app, share):
        failures = []
        release.validate_share_extension_boundary(app, share, failures)
        return failures

    def test_exact_host_configuration_required(self):
        app, share = self.pair()
        self.assertEqual(self.failures(app, share), [])
        for key in ("SharingAPIBaseURL", "SharingModerationPublicKey", "SharingPrivacyURL", "GroupShareKeychainGroup"):
            with self.subTest(key=key):
                self.assertTrue(self.failures(app, dict(share, **{key: "another-value"})))
        for key in ("GroupWindowsEnabled", "GroupShareExtensionEnabled", "SharingMediaEnabled"):
            self.assertTrue(self.failures(app, dict(share, **{key: "NO"})))
        self.assertTrue(self.failures(app, dict(share, SharingShareExtensionSendEnabled="YES")))

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
