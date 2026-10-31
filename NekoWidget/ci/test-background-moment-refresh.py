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
        self.app_root = (ROOT / "NekoWidget/App/AppRootView.swift").read_text(
            encoding="utf-8"
        )
        self.app_view_model = (
            ROOT / "NekoWidget/ViewModels/AppViewModel.swift"
        ).read_text(encoding="utf-8")
        self.main_tab = (ROOT / "NekoWidget/Views/MainTabView.swift").read_text(
            encoding="utf-8"
        )
        self.presentation = (
            ROOT / "NekoWidget/Views/MomentSharingPresentation.swift"
        ).read_text(encoding="utf-8")
        self.project = (ROOT / "NekoWidget.xcodeproj/project.pbxproj").read_text(
            encoding="utf-8"
        )
        with (ROOT / "NekoWidget/Info.plist").open("rb") as handle:
            self.info = plistlib.load(handle)
        with (ROOT / "NekoWidget/NekoWidget.entitlements").open("rb") as handle:
            self.entitlements = plistlib.load(handle)
        with (
            ROOT / "NekoWidgetWidget/NekoWidgetWidget.entitlements"
        ).open("rb") as handle:
            self.widget_entitlements = plistlib.load(handle)
        with (
            ROOT / "NekoWidgetShareExtension/NekoWidgetShareExtension.entitlements"
        ).open("rb") as handle:
            self.share_entitlements = plistlib.load(handle)

    def test_app_refresh_registration_matches_plist(self) -> None:
        identifier = "jp.nekowidget.app.background-moment-refresh"
        personal_identifier = "jp.nekowidget.app.personal-photo-refresh"
        self.assertEqual(
            self.info["BGTaskSchedulerPermittedIdentifiers"], [identifier, personal_identifier]
        )
        personal = (ROOT / "NekoWidget/Services/PersonalWidgetBackgroundRefresh.swift").read_text(encoding="utf-8")
        self.assertIn(personal_identifier, personal)
        self.assertIn("PersonalWidgetBackgroundRefresh.register()", self.service)
        self.assertEqual(
            self.info["UIBackgroundModes"], ["fetch", "remote-notification"]
        )
        self.assertIn("@UIApplicationDelegateAdaptor(NekoWidgetAppDelegate.self)", self.app)
        self.assertIn("BGAppRefreshTaskRequest", self.service)
        self.assertIn("scheduleNextRefresh()", self.service)

    def test_cat_photo_fixture_suppresses_normal_services_and_launch_cleanup(self) -> None:
        flag = 'CommandLine.arguments.contains("--cat-profile-photo-flow-fixture")'
        debug_guard = self.service.split(
            "private static var suppressesNormalServicesForDebugLaunch: Bool {", 1
        )[1].split("#endif", 1)[0]
        self.assertIn(flag, debug_guard)
        launch_debug = self.app.split("init() {", 1)[1].split("#else", 1)[0]
        self.assertIn("#if DEBUG", launch_debug)
        self.assertIn("&& !" + flag, launch_debug)
        onboarding_reset = self.app.split("if !BillingInternalDiagnosticsLaunch.isActive,", 1)[1]
        self.assertLess(onboarding_reset.index("!" + flag), onboarding_reset.index("defaults.removeObject"))

    def test_remote_notification_capability_is_host_only(self) -> None:
        self.assertEqual(self.entitlements["aps-environment"], "$(APS_ENVIRONMENT)")
        self.assertNotIn("aps-environment", self.widget_entitlements)
        self.assertNotIn("aps-environment", self.share_entitlements)
        self.assertIn("APS_ENVIRONMENT = development;", self.project)
        self.assertIn("APS_ENVIRONMENT = production;", self.project)
        self.assertIn("registerForRemoteNotifications", self.service)
        self.assertIn("didRegisterForRemoteNotificationsWithDeviceToken", self.service)
        self.assertIn("didReceiveRemoteNotification", self.service)
        self.assertIn("didReceive response: UNNotificationResponse", self.service)

    def test_group_admission_and_notification_targets_remain_authenticated(self):
        group = self.service.split("final class GroupAdmissionService:", 1)[1]
        self.assertIn("epoch >= tokenEpoch", group)
        self.assertIn("hasLocalGroupState()", group)
        self.assertIn("client.reconcileAdmissions()", group)
        self.assertIn("client.acceptsNotification(windowID: route.windowID, requestID: route.requestID, kind: route.kind)", group)
        self.assertLess(group.index("client.acceptsNotification("), group.index("GroupWindowOpenInbox.shared.open("))
        self.assertIn("(try? await client.window(id: route.windowID)) != nil", group)
        self.assertIn("requestPermission: Bool = false", group)
        self.assertIn("if permissionRequested, settings.authorizationStatus == .notDetermined", group)
        self.assertIn("if allowed && token == nil", group)
        self.assertIn("else if !allowed", group)
        self.assertIn("deviceToken: nil", group)
        self.assertNotIn("UserDefaults", group)
        self.assertNotIn(".write(", group)

    def test_retired_relays_cannot_be_woken_or_registered(self):
        for name in ("MomentPushSubscriptionService", "MomentBackgroundRefreshService", "MomentSharingCoordinator", "URLSessionMomentSharingAPIClient"):
            self.assertNotIn(name, self.service)
        remote = self.service.split("fetchCompletionHandler completionHandler:", 1)[1].split("func userNotificationCenter(", 1)[0]
        self.assertIn("GroupNotificationRoute.parse(userInfo)", remote)
        self.assertIn("GroupAdmissionService.shared.receive(route, open: false)", remote)
        self.assertIn("completionHandler(.noData)", remote)
        self.assertNotIn("MomentNotificationRoutePayload.route", remote)
        self.assertNotIn("pollMomentSharingWhileActive", self.app_root)
        self.assertNotIn("synchronizeMomentSharing", self.app_view_model)
        self.assertNotIn("MomentNotificationTapMailbox.shared.enqueue", self.service)

    def test_group_background_and_album_notice_paths_survive(self):
        self.assertIn("if protectedDataAvailable { await GroupAdmissionService.shared.refresh() }", self.service)
        self.assertIn("backgroundTask.expirationHandler", self.service)
        self.assertIn("operation.cancel()", self.service)
        self.assertIn("GroupAdmissionService.shared.register(deviceToken: deviceToken, epoch: callbackEpoch)", self.service)
        self.assertIn("GroupAdmissionService.shared.receive(route, open: true)", self.service)
        self.assertIn("AlbumArrivalOpenInbox.shared.showsAlbum = true", self.service)
        self.assertIn("await GroupAdmissionService.shared.refresh()", self.app_root)

if __name__ == "__main__": unittest.main()
