from pathlib import Path
import re
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
        # 1115s: the tap's one read of the window is the person's own.
        self.assertIn("(try? await SharingPersonAction.run({ try await client.window(id: route.windowID) })) != nil", group)
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

    def test_family_device_registered_push_runs_one_notebook_pass(self):
        # 11/19 (server #1075): a silent push when a device joins the notebook.
        remote = self.service.split("fetchCompletionHandler completionHandler:", 1)[1].split("func userNotificationCenter(", 1)[0]
        self.assertLess(remote.index("GroupNotificationRoute.parse(userInfo)"), remote.index("FamilyDeviceRegisteredPush.matches(userInfo)"))
        family = remote.split("if FamilyDeviceRegisteredPush.matches(userInfo) {", 1)[1].split("return\n        }", 1)[0]
        self.assertIn("await FamilyNotebookAutoCheck.shared.deviceRegisteredPush()", family)
        self.assertIn("completionHandler(read ? .newData : .noData)", family)
        # Unknown kinds still end with no data.
        self.assertTrue(remote.rstrip().endswith("completionHandler(.noData)\n    }"))
        contract = (ROOT / "NekoWidget/Services/GroupWindowContract.swift").read_text(encoding="utf-8")
        push = contract.split("enum FamilyDeviceRegisteredPush {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn('static let kind = "family_device_registered"', push)
        self.assertIn('Set(neko.keys) == ["v", "kind"]', push)
        self.assertIn('neko["v"] as? Int == 3', push)
        sharing = (ROOT / "NekoWidget/Services/FamilyNotebookSharing.swift").read_text(encoding="utf-8")
        handler = sharing.split("func deviceRegisteredPush() async -> Bool {", 1)[1].split("private func run(pass", 1)[0]
        self.assertIn("SharingAutoCallBudget.shared.pausedUntil() == nil", handler)
        self.assertIn("SharingPersonAction.automatic { await fullPass() }", handler)
        self.assertNotIn("SharingPersonAction.run", handler)
        self.assertIn("beginBackgroundTask(withName:", handler)
        self.assertIn("endBackgroundTask(handle)", handler)
        self.assertIn("work.cancel()", handler)
        # The same work as the schedule's whole-family pass.
        self.assertIn("case .full:\n                    if !model.hasFamily && model.mayResumeEndedNotebook { lastResumeProbeAt = Date() }\n                    await fullPass()", sharing)
        delivery = (ROOT / "ci/verify-family-notebook-key-delivery.swift").read_text(encoding="utf-8")
        self.assertIn("try deviceRegisteredPush()", delivery)

    def test_family_device_push_times_are_in_the_owner_log_only(self):
        # 11/19 (2台試験): the receipt and the end of its pass, with the outcome
        # and the time between, in 診断ログ of the owner's trial builds; no ID,
        # token or key.
        remote = self.service.split("fetchCompletionHandler completionHandler:", 1)[1].split("func userNotificationCenter(", 1)[0]
        family = remote.split("if FamilyDeviceRegisteredPush.matches(userInfo) {", 1)[1].split("return\n        }", 1)[0]
        self.assertLess(family.index("FamilyDevicePushDiagnostics.received()"), family.index("Task { @MainActor in"))
        sharing = (ROOT / "NekoWidget/Services/FamilyNotebookSharing.swift").read_text(encoding="utf-8")
        handler = sharing.split("func deviceRegisteredPush() async -> Bool {", 1)[1].split("private func run(pass", 1)[0]
        skipped = handler.split("if let skip {", 1)[1].split("}", 1)[0]
        self.assertIn("FamilyDevicePushDiagnostics.finished(.skipped, since: started, reason: skip)", skipped)
        self.assertIn("return false", skipped)
        self.assertLess(handler.rindex("let read = await work.value"),
                        handler.index("FamilyDevicePushDiagnostics.finished(read ? .read : .notRead, since: started, reason: waited)"))
        factory = (ROOT / "NekoWidget/Services/FamilyNotebookServiceFactory.swift").read_text(encoding="utf-8")
        diagnostics = factory.split("enum FamilyDevicePushDiagnostics {", 1)[1].split("\n}\n", 1)[0]
        self.assertEqual(diagnostics.count("#if INTERNAL_PRESENTATION && !NEKO_SHARE_EXTENSION"), 2)
        self.assertEqual(diagnostics.count("SharedLog.app.info("), 2)
        # Keys of the literal and of a subscript (metadata["…"] = …).
        keys = set(re.findall(r'"([A-Za-z]+)"(?::|] =)', diagnostics))
        self.assertEqual(keys, {"familyDevicePush", "familyDevicePushOutcome", "familyDevicePushReason", "durationMs"})
        # 11/19 (build 394): which guard skipped it, or what it waited for:
        # fixed tokens only.
        self.assertIn("enum Reason: String { case notReal, noFamily, working, passRunning, budgetPaused }", diagnostics)
        self.assertIn('if let reason { metadata["familyDevicePushReason"] = reason.rawValue }', diagnostics)
        for token in ("deviceID", "personID", "token", "familyID", "userInfo"):
            self.assertNotIn(token, diagnostics)
        privacy = (ROOT / "Shared/Logging/DiagnosticLogPrivacy.swift").read_text(encoding="utf-8")
        self.assertIn('"familyDevicePush": ["finished", "received"],', privacy)
        self.assertIn('"familyDevicePushOutcome": ["notRead", "read", "skipped"],', privacy)
        self.assertIn('"familyDevicePushReason": ["budgetPaused", "noFamily", "notReal", "passRunning", "working"],', privacy)

    def test_family_device_push_opens_the_notebook_and_waits_for_a_pass_in_flight(self):
        # 11/19 (build 394): a launch in the background for the push alone
        # opens the notebook before the guards; a pass in flight (perhaps a
        # requests-only one, or one that read the roster before the device
        # joined) is waited for, then this push makes its own full pass.
        sharing = (ROOT / "NekoWidget/Services/FamilyNotebookSharing.swift").read_text(encoding="utf-8")
        handler = sharing.split("func deviceRegisteredPush() async -> Bool {", 1)[1].split("private func run(pass", 1)[0]
        self.assertLess(handler.index("model.reopenIfUnread()"), handler.index("!model.isReal ? .notReal"))
        self.assertIn("!model.hasFamily ? .noFamily", handler)
        self.assertIn(": .budgetPaused", handler)
        # Busy is waited for, never a skip.
        guard = handler.split("let skip:", 1)[1].split("if let skip {", 1)[0]
        for busy in ("isWorking", "sleeping", "loop", "isReading"):
            self.assertNotIn(busy, guard)
        work = handler.split("let work = Task {", 1)[1].split("#if canImport(UIKit)", 1)[0]
        self.assertLess(work.index("while pushBusyReason != nil, Date().timeIntervalSince(started) < Self.pushWaitLimit {"),
                        work.index("return await SharingPersonAction.automatic { await fullPass() }"))
        self.assertIn("if Task.isCancelled { return false }", work)
        self.assertIn("static let pushWaitLimit: TimeInterval = 20", sharing)
        busy = sharing.split("private var pushBusyReason: FamilyDevicePushDiagnostics.Reason? {", 1)[1].split("\n    }\n", 1)[0]
        self.assertIn("if sharing.isWorking { return .working }", busy)
        self.assertIn("if (loop != nil && !sleeping) || sharing.isReading { return .passRunning }", busy)
        self.assertIn("var isReading: Bool { refreshing }", sharing)
        # The model opens a notebook left unread (a launch while locked, or
        # for the push alone) again, and leaves an open one as it is.
        view = (ROOT / "NekoWidget/Views/FamilyNotebookView.swift").read_text(encoding="utf-8")
        reopen = view.split("func reopenIfUnread() {", 1)[1].split("\n    }\n", 1)[0]
        self.assertIn("guard isReal, store == nil else { return }", reopen)
        self.assertIn("openRealBinding()", reopen)
        self.assertIn("forName: .appRecordsReadableAgain, object: nil, queue: nil) { [weak self] _ in\n"
                      "            Task { @MainActor in self?.reopenIfUnread() }", view)

    def test_group_background_and_album_notice_paths_survive(self):
        protected = self.service.split("if protectedDataAvailable {", 1)[1].split("}", 1)[0]
        authority = "await PlusPurchaseStore.productionShared.refreshWidgetAuthorityInBackground()"
        admission = "await GroupAdmissionService.shared.refresh()"
        photos = "await GroupAdmissionService.shared.refreshWidgetPhotos()"
        for call in (authority, admission, photos):
            self.assertIn(call, protected)
        self.assertLess(protected.index(authority), protected.index(admission))
        self.assertLess(protected.index(admission), protected.index(photos))
        self.assertIn("backgroundTask.expirationHandler", self.service)
        self.assertIn("operation.cancel()", self.service)
        self.assertIn("GroupAdmissionService.shared.register(deviceToken: deviceToken, epoch: callbackEpoch)", self.service)
        self.assertIn("GroupAdmissionService.shared.receive(route, open: true)", self.service)
        self.assertIn("AlbumArrivalOpenInbox.shared.showsAlbum = true", self.service)
        self.assertIn("await GroupAdmissionService.shared.refresh()", self.app_root)

if __name__ == "__main__": unittest.main()
