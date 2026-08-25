from pathlib import Path
import plistlib
import unittest


ROOT = Path(__file__).resolve().parents[1]


class BackgroundMomentRefreshTests(unittest.TestCase):
    def setUp(self) -> None:
        self.service = (
            ROOT / "NekoWidget/Services/MomentBackgroundRefreshService.swift"
        ).read_text(encoding="utf-8")
        self.app = (ROOT / "NekoWidget/App/NekoWidgetApp.swift").read_text(
            encoding="utf-8"
        )
        self.family_window = (
            ROOT / "NekoWidget/Views/FamilyWindowView.swift"
        ).read_text(encoding="utf-8")
        with (ROOT / "NekoWidget/Info.plist").open("rb") as handle:
            self.info = plistlib.load(handle)
        with (ROOT / "NekoWidget/NekoWidget.entitlements").open("rb") as handle:
            self.entitlements = plistlib.load(handle)

    def test_app_refresh_registration_matches_plist(self) -> None:
        identifier = "jp.nekowidget.app.background-moment-refresh"
        self.assertEqual(
            self.info["BGTaskSchedulerPermittedIdentifiers"], [identifier]
        )
        self.assertEqual(self.info["UIBackgroundModes"], ["fetch"])
        self.assertIn("@UIApplicationDelegateAdaptor(NekoWidgetAppDelegate.self)", self.app)
        self.assertIn("BGAppRefreshTaskRequest", self.service)
        self.assertIn("scheduleNextRefresh()", self.service)

    def test_no_remote_notification_capability_is_added(self) -> None:
        self.assertNotIn("aps-environment", self.entitlements)
        self.assertNotIn("remote-notification", self.info["UIBackgroundModes"])
        self.assertNotIn("registerForRemoteNotifications", self.service)
        self.assertNotIn("deviceToken", self.service)

    def test_background_sync_is_eligible_and_fail_closed(self) -> None:
        eligibility = self.service.split(
            "static func isEligible(", 1
        )[1].split("\n    }", 1)[0]
        self.assertIn("configuration.isMediaAvailable", eligibility)
        self.assertIn("pairing.phase == .paired", eligibility)
        self.assertIn("PairingMediaSharingConsent.currentVersion", eligibility)
        self.assertIn("mediaSharingConsentAcceptedAt != nil", eligibility)
        self.assertIn("guard protectedDataAvailable", self.service)
        self.assertGreaterEqual(
            self.service.count("PairingInstallationGuard.bootstrapAsync()"), 2
        )
        self.assertIn("try Task.checkCancellation()", self.service)
        self.assertIn("failed closed", self.service.lower())

    def test_widget_is_published_before_reload_and_notification(self) -> None:
        refresh = self.service.split(
            "func refresh(protectedDataAvailable: Bool) async -> Bool", 1
        )[1].split("private func clearFamilyWidgetIfNeeded", 1)[0]
        publication = refresh.index("widgetCacheBuilder.buildFamilyWindow(")
        reload = refresh.index("WidgetCenter.shared.reloadTimelines")
        notification = refresh.index("postPrivacyMinimizedNewMomentNotification()")
        self.assertLess(publication, reload)
        self.assertLess(reload, notification)
        self.assertIn("visibleMomentIDs(in: afterState)", refresh)

    def test_local_notification_contains_no_shared_identity_or_media(self) -> None:
        notification = self.service.split(
            "private func postPrivacyMinimizedNewMomentNotification()", 1
        )[1].split("private static func familyWidgetManifest", 1)[0]
        self.assertIn("UNMutableNotificationContent", notification)
        self.assertIn("新しい一枚が届きました", notification)
        for forbidden in (
            "userInfo",
            "attachment",
            "windowDisplayName",
            "participant",
            "momentID",
            "imageURL",
            "sound =",
            "badge =",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, notification)
        self.assertIn(".provisional", self.service)

    def test_visible_notification_authorization_requires_an_explicit_tap(self) -> None:
        request = self.service.split(
            "func requestVisibleNotificationAuthorization()", 1
        )[1].split("/// Returns whether", 1)[0]
        self.assertIn("requestAuthorization(options: [.alert])", request)
        self.assertNotIn(".provisional", request)
        self.assertNotIn(".sound", request)
        self.assertNotIn(".badge", request)
        self.assertIn("settings.alertSetting", self.service)
        self.assertIn("family-window-notification-enable", self.family_window)

    def test_denied_notification_permission_links_to_ios_settings(self) -> None:
        self.assertIn("family-window-notification-open-settings", self.family_window)
        self.assertIn("UIApplication.openSettingsURLString", self.family_window)
        self.assertIn("目立つ通知にする", self.family_window)

    def test_notification_copy_does_not_claim_immediate_delivery(self) -> None:
        self.assertIn("受信を確認できたときに通知します", self.family_window)
        self.assertNotIn("写真やハートが届いたら必ずすぐ通知します", self.family_window)

    def test_heart_notification_is_text_only_and_privacy_minimized(self) -> None:
        notification = self.service.split(
            "private func postPrivacyMinimizedPawNotification()", 1
        )[1].split("private static func familyWidgetManifest", 1)[0]
        self.assertIn("届けた写真にハートが届きました。", notification)
        self.assertIn("UNMutableNotificationContent", notification)
        for forbidden in (
            "UNNotificationAttachment",
            "content.sound",
            "content.badge",
            "windowDisplayName",
            "senderParticipant",
            "momentID",
        ):
            self.assertNotIn(forbidden, notification)


if __name__ == "__main__":
    unittest.main()
