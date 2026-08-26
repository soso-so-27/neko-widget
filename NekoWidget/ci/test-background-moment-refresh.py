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
        self.family_window = (
            ROOT / "NekoWidget/Views/FamilyWindowView.swift"
        ).read_text(encoding="utf-8")
        self.presentation = (
            ROOT / "NekoWidget/Views/MomentSharingPresentation.swift"
        ).read_text(encoding="utf-8")
        self.api_client = (
            ROOT / "NekoWidget/Services/MomentSharingAPIClient.swift"
        ).read_text(encoding="utf-8")
        self.coordinator = (
            ROOT / "NekoWidget/Services/MomentSharingCoordinator.swift"
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
        self.assertEqual(
            self.info["BGTaskSchedulerPermittedIdentifiers"], [identifier]
        )
        self.assertEqual(
            self.info["UIBackgroundModes"], ["fetch", "remote-notification"]
        )
        self.assertIn("@UIApplicationDelegateAdaptor(NekoWidgetAppDelegate.self)", self.app)
        self.assertIn("BGAppRefreshTaskRequest", self.service)
        self.assertIn("scheduleNextRefresh()", self.service)

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
        refresh = self.service.split("func refresh(", 1)[1].split(
            "private func clearFamilyWidgetIfNeeded", 1
        )[0]
        publication = refresh.index("widgetCacheBuilder.buildFamilyWindow(")
        reload = refresh.index("WidgetCenter.shared.reloadTimelines")
        notification = refresh.index("postPrivacyMinimizedNewMomentNotification()")
        self.assertLess(publication, reload)
        self.assertLess(reload, notification)
        self.assertIn("visibleMomentIDs(in: afterState)", refresh)

    def test_remote_wake_reuses_sync_and_suppresses_duplicate_local_alert(self) -> None:
        callback = self.service.split("didReceiveRemoteNotification", 1)[1].split(
            "func userNotificationCenter", 1
        )[0]
        self.assertIn('trigger: "remote-notification"', callback)
        self.assertIn("emitLocalNotifications: false", callback)
        self.assertIn("result.didChange ? .newData : .noData", callback)
        self.assertIn("result.succeeded", callback)
        self.assertIn("WidgetCenter.shared.reloadTimelines", self.service)
        self.assertIn("emitLocalNotifications && newVisibleCount", self.service)
        self.assertIn("emitLocalNotifications && newPawCount", self.service)

    def test_remote_wake_never_syncs_a_different_selected_window(self) -> None:
        callback = self.service.split("didReceiveRemoteNotification", 1)[1].split(
            "func userNotificationCenter", 1
        )[0]
        self.assertIn(
            "guard let route = MomentNotificationRoutePayload.route(from: userInfo)",
            callback,
        )
        malformed = callback.split(
            "guard let route = MomentNotificationRoutePayload.route(from: userInfo)",
            1,
        )[1].split("if let target = route.target", 1)[0]
        self.assertIn("reconcileRemoteNotificationRegistration()", malformed)
        self.assertIn("completionHandler(.noData)", malformed)
        self.assertIn("return", malformed)

        # A valid legacy v1 route has no target and continues to the existing
        # selected-window refresh. Only a target-bearing route enters the
        # active-window check below.
        self.assertIn("if let target = route.target", callback)
        self.assertLess(
            callback.index("if let target = route.target"),
            callback.index("activeRefresh?.cancel()"),
        )
        self.assertIn("notificationTargetMatchesActiveWindow(target)", callback)
        mismatch = callback.split(
            "notificationTargetMatchesActiveWindow(target)", 1
        )[1].split("activeRefresh?.cancel()", 1)[0]
        self.assertIn("reconcileRemoteNotificationRegistration()", mismatch)
        self.assertIn("completionHandler(.noData)", mismatch)
        self.assertIn("return", mismatch)

        matcher = self.service.split(
            "private static func notificationTargetMatchesActiveWindow", 1
        )[1].split("private func run(", 1)[0]
        self.assertIn("PrivateWindowCatalogStore.load()", matcher)
        self.assertIn("$0.localWindowID == catalog.activeWindowID", matcher)
        self.assertIn("active.spaceID == target.spaceID", matcher)

    def test_signed_push_subscription_contract_does_not_persist_token(self) -> None:
        self.assertIn('path: "/v2/push-subscriptions/current"', self.api_client)
        self.assertIn('method: "PUT"', self.api_client)
        self.assertIn('method: "DELETE"', self.api_client)
        self.assertIn("MomentSharingProtocol.version", self.api_client)
        self.assertIn("deviceToken.base64URLEncodedString()", self.api_client)
        self.assertIn("try authenticate(", self.api_client)
        push_service = self.service.split("actor MomentPushSubscriptionService", 1)[1].split(
            "actor MomentBackgroundRefreshService", 1
        )[0]
        for forbidden in (
            "UserDefaults",
            "AtomicJSON",
            "KeychainStore.save",
            "deviceToken.base64",
            "metadata: [",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, push_service)
        reconcile = push_service.split("func reconcileRegistration()", 1)[1].split(
            "func register(deviceToken:", 1
        )[0]
        self.assertIn("authenticatedContextsForAllWindows(", reconcile)
        self.assertIn("for context in contexts where !context.isActive", reconcile)
        self.assertIn("contexts.first(where: { $0.isActive })", reconcile)
        registration = push_service.split("func register(deviceToken:", 1)[1].split(
            "private func deleteCurrentSubscriptionIfPossible", 1
        )[0]
        self.assertIn("contexts.first(where: { $0.isActive })", registration)
        self.assertIn("for context in contexts where !context.isActive", registration)
        self.assertIn("registrationTargetIsCurrent(", registration)
        self.assertIn("continue registrationAttempt", registration)
        self.assertIn("MomentBackgroundRefreshPolicy.isEligible(", registration)
        self.assertIn("performRemoteMutation(", registration)
        self.assertIn(".put(deviceToken: deviceToken)", registration)
        self.assertIn(
            "let latestSettings = await notificationCenter.notificationSettings()",
            registration,
        )
        self.assertLess(
            registration.index("let latestSettings = await"),
            registration.index(".put(deviceToken: deviceToken)"),
        )
        self.assertIn("Self.allowsRemoteAlerts(latestSettings)", registration)
        self.assertIn("await deleteCurrentSubscriptionIfPossible()", registration)
        mutation_gate = push_service.split(
            "private func performRemoteMutation(", 1
        )[1].split("/// Produces one authenticated context", 1)[0]
        self.assertIn("remoteMutationQueue.append", mutation_gate)
        self.assertIn("drainRemoteMutationQueue()", mutation_gate)
        self.assertIn("remoteMutationQueue.removeFirst()", mutation_gate)
        self.assertIn("client.putPushSubscription(", mutation_gate)
        self.assertIn("client.deletePushSubscription(", mutation_gate)
        contexts = push_service.split(
            "private func authenticatedContextsForAllWindows(", 1
        )[1].split("private func registrationTargetIsCurrent(", 1)[0]
        self.assertIn("SharingLifecycleGate.withValidatedToken(", contexts)
        self.assertIn("bootstrap.lifecycleToken", contexts)
        self.assertIn("activeEntry.spaceID == bootstrap.state.spaceID", contexts)
        self.assertIn(
            "activeEntry.credentialAccount\n                    == bootstrap.state.credentialAccount",
            contexts,
        )
        self.assertIn("entry.spaceID == pairing.spaceID", contexts)
        self.assertIn("entry.credentialAccount == account", contexts)
        self.assertIn("SharingLifecycleGate.validate(bootstrap.lifecycleToken)", contexts)

    def test_local_notification_contains_no_shared_identity_or_media(self) -> None:
        notification = self.service.split(
            "private func postPrivacyMinimizedNewMomentNotification()", 1
        )[1].split("private static func familyWidgetManifest", 1)[0]
        self.assertIn("UNMutableNotificationContent", notification)
        self.assertIn("新しい一枚が届きました", notification)
        self.assertIn(
            "content.userInfo = MomentNotificationRoutePayload.userInfo(for: .newMoment)",
            notification,
        )
        for forbidden in (
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

    def test_notification_tap_route_is_bounded_and_cold_launch_safe(self) -> None:
        payload = self.service.split("enum MomentNotificationRoutePayload", 1)[1].split(
            "struct MomentNotificationTap", 1
        )[0]
        self.assertIn('static let envelopeKey = "neko"', payload)
        self.assertIn('static let targetEnvelopeKey = "nekoTarget"', payload)
        self.assertIn("static let legacySchemaVersion = 1", payload)
        self.assertIn("static let targetSchemaVersion = 1", payload)
        self.assertNotIn("static let schemaVersion", payload)
        self.assertIn('Set(envelope.keys) == Set(["v", "kind"])', payload)
        self.assertIn('envelope["v"] as? Int', payload)
        self.assertIn("version == legacySchemaVersion", payload)
        self.assertIn("MomentNotificationRouteKind(rawValue: rawKind)", payload)
        self.assertIn(
            'Set(targetEnvelope.keys) == Set(["v", "spaceId", "momentId"])',
            payload,
        )
        self.assertIn('targetEnvelope["v"] as? Int', payload)
        self.assertIn("targetVersion == targetSchemaVersion", payload)
        self.assertIn('targetEnvelope["spaceId"] as? String', payload)
        self.assertIn('targetEnvelope["momentId"] as? String', payload)
        self.assertGreaterEqual(payload.count("isOpaqueIdentifier"), 2)

        legacy_parser = payload.split("static func route(", 1)[1].split(
            "guard let rawTarget", 1
        )[0]
        self.assertIn("else { return nil }", legacy_parser)

        legacy_user_info = payload.split("static func userInfo(", 1)[1].split(
            "static func routeKind", 1
        )[0]
        self.assertIn("envelopeKey:", legacy_user_info)
        self.assertIn('"v": legacySchemaVersion', legacy_user_info)
        self.assertNotIn("targetEnvelopeKey", legacy_user_info)

        route = self.service.split(
            "struct MomentNotificationRoute: Equatable", 1
        )[1].split(
            "struct MomentNotificationTap", 1
        )[0]
        self.assertIn("let kind: MomentNotificationRouteKind", route)
        self.assertIn("let target: MomentNotificationRouteTarget?", route)
        target = self.service.split(
            "struct MomentNotificationRouteTarget", 1
        )[1].split("struct MomentNotificationRoute", 1)[0]
        self.assertIn("let spaceID: String", target)
        self.assertIn("let momentID: String", target)
        tap = self.service.split("struct MomentNotificationTap", 1)[1].split(
            "final class MomentNotificationTapMailbox", 1
        )[0]
        self.assertIn("let route: MomentNotificationRoute", tap)
        self.assertNotIn("let kind: MomentNotificationRouteKind", tap)

        # The original exact v1 envelope remains valid when the separately
        # versioned target is absent. A present but malformed target must not
        # silently navigate the currently selected window.
        self.assertIn("guard let rawTarget = userInfo[targetEnvelopeKey]", payload)
        self.assertIn("return MomentNotificationRoute(kind: kind, target: nil)", payload)
        malformed_target = payload.split(
            "guard let rawTarget = userInfo[targetEnvelopeKey]", 1
        )[1]
        self.assertIn("else { return nil }", malformed_target)

        callback = self.service.split(
            "didReceive response: UNNotificationResponse", 1
        )[1].split("private func run(", 1)[0]
        self.assertIn("UNNotificationDefaultActionIdentifier", callback)
        self.assertIn("MomentNotificationRoutePayload.route", callback)
        self.assertIn("MomentNotificationTapMailbox.shared.enqueue(route)", callback)

        mailbox = self.service.split("final class MomentNotificationTapMailbox", 1)[
            1
        ].split("final class NekoWidgetAppDelegate", 1)[0]
        self.assertIn("@Published private(set) var pendingTap", mailbox)
        self.assertIn("func enqueue(_ route: MomentNotificationRoute)", mailbox)
        self.assertIn("MomentNotificationTap(id: UUID(), route: route)", mailbox)
        self.assertIn("guard pendingTap?.id == id", mailbox)
        self.assertIn("pendingTap = nil", mailbox)

        self.assertIn(
            ".onChange(of: momentNotificationTapMailbox.pendingTap, initial: true)",
            self.app_root,
        )
        self.assertIn("viewModel.handleMomentNotificationRoute(tap.route)", self.app_root)
        self.assertIn("momentNotificationTapMailbox.consume(id: tap.id)", self.app_root)

    def test_targeted_notification_selects_its_window_before_opening_photo(self) -> None:
        handler = self.app_view_model.split(
            "func handleMomentNotificationRoute(", 1
        )[1].split("private func openPendingDeepLinkIfNeeded", 1)[0]
        self.assertIn("MomentNotificationRoute", handler)
        self.assertIn("PrivateWindowCatalogStore.load()", handler)
        self.assertIn("if let target = route.target", handler)
        self.assertIn("$0.spaceID == target.spaceID", handler)
        self.assertIn("matches.count == 1", handler)
        self.assertIn("PairingInstallationGuard.activatePrivateWindowAsync", handler)
        self.assertIn("localWindowID: targetWindow.localWindowID", handler)
        self.assertIn('trigger: "notification-target"', handler)
        self.assertIn("expectedSpaceID: target.spaceID", handler)
        self.assertIn("pendingFamilyNotificationRoute = route", handler)
        self.assertIn("isFamilyWindowPresented = true", handler)
        self.assertNotIn("withoutTarget()", handler)
        self.assertLess(
            handler.index("PairingInstallationGuard.activatePrivateWindowAsync"),
            handler.index("pendingFamilyNotificationRoute = route"),
        )
        self.assertLess(
            handler.index("pendingFamilyNotificationRoute = route"),
            handler.index("isFamilyWindowPresented = true"),
        )
        self.assertLess(
            handler.index("isFamilyWindowPresented = true"),
            handler.index('trigger: "notification-target"'),
        )
        self.assertIn("momentNotificationRoutingGate.acquire()", handler)
        self.assertIn("momentNotificationRouteGeneration &+= 1", handler)
        self.assertGreaterEqual(
            handler.count("generation == momentNotificationRouteGeneration"),
            3,
        )

        # A legacy kind-only payload intentionally has no target and reaches
        # the common selected-window/section assignment below the target-only
        # activation branch.
        self.assertLess(
            handler.index("if let target = route.target"),
            handler.index("pendingFamilyNotificationRoute = route"),
        )

    def test_target_space_survives_bootstrap_and_process_queue_boundaries(self) -> None:
        callback = self.service.split("didReceiveRemoteNotification", 1)[1].split(
            "func userNotificationCenter", 1
        )[0]
        self.assertIn("expectedSpaceID: route.target?.spaceID", callback)

        refresh = self.service.split("func refresh(", 1)[1].split(
            "private func clearFamilyWidgetIfNeeded", 1
        )[0]
        self.assertIn("expectedSpaceID: String? = nil", refresh)
        self.assertGreaterEqual(
            refresh.count("state.spaceID == expectedSpaceID"),
            2,
        )
        self.assertIn("expectedSpaceID: expectedSpaceID", refresh)

        synchronize = self.coordinator.split(
            "func synchronize(", 1
        )[1].split("func synchronizeWindowNameForUser", 1)[0]
        self.assertIn("expectedSpaceID: String? = nil", synchronize)
        self.assertIn("expectedSpaceID: expectedSpaceID", synchronize)
        perform = self.coordinator.split(
            "private func performSynchronization(\n        trigger: String,", 1
        )[1].split("func synchronizationNotice()", 1)[0]
        self.assertIn("loadedAuthorization.state.spaceID == expectedSpaceID", perform)
        self.assertLess(
            perform.index("loadedAuthorization.state.spaceID == expectedSpaceID"),
            perform.index("let api = try makeNetworkClient()"),
        )

    def test_notification_photo_target_reaches_received_and_sent_presentations(self) -> None:
        self.assertIn(
            "@Published var pendingFamilyNotificationRoute: MomentNotificationRoute?",
            self.app_view_model,
        )
        self.assertIn(
            "$viewModel.pendingFamilyNotificationRoute",
            self.app_root,
        )
        self.assertIn(
            "@Binding var pendingFamilyNotificationRoute: MomentNotificationRoute?",
            self.main_tab,
        )
        self.assertIn(
            "pendingNotificationRoute: $pendingFamilyNotificationRoute",
            self.main_tab,
        )
        self.assertIn(
            "@Binding private var pendingNotificationRoute: MomentNotificationRoute?",
            self.family_window,
        )

        consume = self.family_window.split(
            "private func consumePendingNotificationRoute()", 1
        )[1].split("private var pendingMemoryTargetBootstrapPhase", 1)[0]
        self.assertIn("guard let route = pendingNotificationRoute", consume)
        self.assertIn("route.target?.momentID", consume)
        self.assertIn("case .newMoment:", consume)
        self.assertIn("selectedSection = .received", consume)
        self.assertIn("focusedMomentID = momentID", consume)
        self.assertIn("case .heart:", consume)
        self.assertIn("selectedSection = .sent", consume)
        self.assertIn("focusedSentMomentID = momentID", consume)

        # A target-bearing route is one atomic capability. It remains pending
        # until both its authenticated window and exactly one photo resolve;
        # only a legacy targetless v1 route may fall back to a section.
        targeted = consume.split("if let target = route.target", 1)[1].split(
            "// Legacy v1 notifications", 1
        )[0]
        self.assertIn("model.pairingState?.spaceID == target.spaceID", targeted)
        self.assertEqual(targeted.count("guard matches.count == 1"), 2)
        self.assertEqual(targeted.count("pendingNotificationRoute = nil"), 2)
        first_resolution = targeted.index("guard matches.count == 1")
        first_consume = targeted.index("pendingNotificationRoute = nil")
        self.assertLess(first_resolution, first_consume)
        legacy = consume.split("// Legacy v1 notifications", 1)[1]
        self.assertIn("pendingNotificationRoute = nil", legacy)
        self.assertIn("selectedSection = .received", legacy)
        self.assertIn("selectedSection = .sent", legacy)

        sent_record = self.presentation.split(
            "struct MomentSentRecordPresentation", 1
        )[1].split("struct MomentOutgoingPresentation", 1)[0]
        self.assertIn("let momentID: String?", sent_record)
        visible_sent = self.family_window.split(
            "private var visibleSentRecords", 1
        )[1].split("private var canManageOutgoingPresentation", 1)[0]
        self.assertIn("focusedSentMomentID", visible_sent)
        self.assertIn("$0.momentID == focusedSentMomentID", visible_sent)

    def test_visible_notification_authorization_requires_an_explicit_tap(self) -> None:
        request = self.service.split(
            "func requestVisibleNotificationAuthorization()", 1
        )[1].split("/// Separates execution success", 1)[0]
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
        self.assertIn("選択中のまどの通知", self.family_window)
        self.assertIn("このまどの新着を通知できます", self.family_window)
        self.assertIn("iPhoneで許可済み", self.family_window)
        self.assertNotIn("写真やハートが届いたら必ずすぐ通知します", self.family_window)

    def test_heart_notification_is_text_only_and_privacy_minimized(self) -> None:
        notification = self.service.split(
            "private func postPrivacyMinimizedPawNotification()", 1
        )[1].split("private static func familyWidgetManifest", 1)[0]
        self.assertIn("届けた写真にハートが届きました。", notification)
        self.assertIn("UNMutableNotificationContent", notification)
        self.assertIn(
            "content.userInfo = MomentNotificationRoutePayload.userInfo(for: .heart)",
            notification,
        )
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
