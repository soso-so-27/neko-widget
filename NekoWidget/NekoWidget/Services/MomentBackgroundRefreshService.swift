import BackgroundTasks
import Combine
import Foundation
import UIKit
import UserNotifications
import WidgetKit

/// Keep the registered background-task identifier for installed versions.
/// Refresh only current group admissions; iOS controls when this can run.
enum GroupBackgroundRefreshPolicy {
    static let taskIdentifier = "jp.nekowidget.app.background-moment-refresh"
    static let earliestBeginDelay: TimeInterval = 15 * 60
}

/// A privacy-minimized navigation hint shared by remote and local sharing
/// notifications. Older notifications contain only the bounded kind. Newer
/// remote notifications may add an independently versioned opaque target; no
/// user-facing window name, participant identity, media, or local path crosses
/// this boundary. Unknown or malformed envelopes are ignored instead of
/// guessing a destination.
enum MomentNotificationRouteKind: String, Equatable, Sendable {
    case newMoment = "new_moment"
    case heart
}

struct MomentNotificationRouteTarget: Equatable, Sendable {
    let spaceID: String
    let momentID: String
}

struct MomentNotificationRoute: Equatable, Sendable {
    let kind: MomentNotificationRouteKind
    let target: MomentNotificationRouteTarget?
}

enum MomentNotificationRoutePayload {
    static let envelopeKey = "neko"
    static let targetEnvelopeKey = "nekoTarget"
    // The legacy envelope is an installed-client compatibility boundary. The
    // separately versioned target may evolve without ever changing `neko` v1.
    static let legacySchemaVersion = 1
    static let targetedSchemaVersion = 2
    static let targetSchemaVersion = 1

    static func userInfo(
        for kind: MomentNotificationRouteKind
    ) -> [AnyHashable: Any] {
        [
            envelopeKey: [
                "v": legacySchemaVersion,
                "kind": kind.rawValue
            ]
        ]
    }

    static func routeKind(
        from userInfo: [AnyHashable: Any]
    ) -> MomentNotificationRouteKind? {
        route(from: userInfo)?.kind
    }

    static func route(
        from userInfo: [AnyHashable: Any]
    ) -> MomentNotificationRoute? {
        guard let envelope = userInfo[envelopeKey] as? [String: Any],
              Set(envelope.keys) == Set(["v", "kind"]),
              let version = envelope["v"] as? Int,
              version == legacySchemaVersion || version == targetedSchemaVersion,
              let rawKind = envelope["kind"] as? String,
              let kind = MomentNotificationRouteKind(rawValue: rawKind)
        else { return nil }

        guard let rawTarget = userInfo[targetEnvelopeKey] else {
            // Only the active-window legacy subscription may omit a target.
            // Additive multi-window subscriptions always use v2 so an older
            // client fails closed instead of synchronizing whichever window
            // happens to be selected.
            return version == legacySchemaVersion
                ? MomentNotificationRoute(kind: kind, target: nil)
                : nil
        }
        guard let targetEnvelope = rawTarget as? [String: Any],
              Set(targetEnvelope.keys) == Set(["v", "spaceId", "momentId"]),
              let targetVersion = targetEnvelope["v"] as? Int,
              targetVersion == targetSchemaVersion,
              let spaceID = targetEnvelope["spaceId"] as? String,
              let momentID = targetEnvelope["momentId"] as? String,
              PairingValidation.isOpaqueIdentifier(spaceID),
              PairingValidation.isOpaqueIdentifier(momentID)
        else { return nil }
        return MomentNotificationRoute(
            kind: kind,
            target: MomentNotificationRouteTarget(
                spaceID: spaceID,
                momentID: momentID
            )
        )
    }
}

struct MomentNotificationTap: Equatable, Identifiable, Sendable {
    let id: UUID
    let route: MomentNotificationRoute
}

/// Keeps the latest validated tap in memory until SwiftUI has installed its
/// root view. Posting NotificationCenter-only events here would lose a cold
/// launch tap that arrives before AppRootView subscribes.
@MainActor
final class MomentNotificationTapMailbox: ObservableObject {
    struct Feedback: Equatable, Identifiable {
        let id: UUID
        let message: String
    }

    static let shared = MomentNotificationTapMailbox()

    @Published private(set) var pendingTap: MomentNotificationTap?
    @Published private(set) var pendingWidgetFeedback: Feedback?

    private init() {}

    func enqueue(_ route: MomentNotificationRoute) {
        pendingTap = MomentNotificationTap(id: UUID(), route: route)
    }

    func consume(id: UUID) {
        guard pendingTap?.id == id else { return }
        pendingTap = nil
    }

    // Widget intents also run before the root view can observe a cold launch.
    // Keep their latest feedback in this same in-memory mailbox; it neither
    // replaces a pending photo route nor writes another persistent store.
    func enqueueWidgetFeedback(_ message: String) {
        pendingWidgetFeedback = Feedback(id: UUID(), message: message)
    }

    func consumeWidgetFeedback(id: UUID) {
        guard pendingWidgetFeedback?.id == id else { return }
        pendingWidgetFeedback = nil
    }
}

@MainActor
final class NekoWidgetAppDelegate: NSObject, UIApplicationDelegate,
    UNUserNotificationCenterDelegate {
    private var activeRefresh: Task<Void, Never>?
    private var registrationReconciliation: Task<Void, Never>?
    private var tokenRegistration: Task<Void, Never>?
    private var tokenRegistrationEpoch: UInt64 = 0

#if DEBUG
    private static var suppressesNormalServicesForDebugLaunch: Bool {
        CommandLine.arguments.contains("--sharing-runtime-self-test")
            || CommandLine.arguments.contains("--cat-profile-photo-flow-fixture")
            || CommandLine.arguments.contains("--photo-window-ui-fixture")
            || CommandLine.arguments.contains("--moment-shared-album-ui-fixture")
            || CommandLine.arguments.contains("--moderation-resolution-ui-fixture")
            || CommandLine.arguments.contains(
                AppStoreScreenshotFixture.launchArgument
            )
            || BillingInternalDiagnosticsLaunch.isActive
    }
#endif

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [
            UIApplication.LaunchOptionsKey: Any
        ]? = nil
    ) -> Bool {
#if DEBUG
        guard !Self.suppressesNormalServicesForDebugLaunch else { return true }
#endif
        UNUserNotificationCenter.current().delegate = self
        PersonalWidgetBackgroundRefresh.register()
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: GroupBackgroundRefreshPolicy.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor [weak self] in
                self?.run(refreshTask)
            }
        }
        if SharingAPIConfiguration.current.isMediaAvailable {
            scheduleNextRefresh()
        }
        reconcileRemoteNotificationRegistration()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
#if DEBUG
        guard !Self.suppressesNormalServicesForDebugLaunch else { return }
#endif
        // Notification permission and the APNs token can change outside the
        // app. Reconcile on every foreground activation; the signed PUT is
        // idempotent and extends the server-side bounded subscription lease.
        reconcileRemoteNotificationRegistration()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
#if DEBUG
        guard !Self.suppressesNormalServicesForDebugLaunch else { return }
#endif
        PersonalWidgetBackgroundRefresh.schedule()
        guard SharingAPIConfiguration.current.isMediaAvailable else { return }
        scheduleNextRefresh()
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
#if DEBUG
        guard !Self.suppressesNormalServicesForDebugLaunch else { return }
#endif
        // Do not cancel an in-flight callback here. If its network request has
        // already reached the service, cancellation could prevent the group
        // coordinator from observing the newest token. Its epoch check makes
        // callbacks converge instead.
        tokenRegistrationEpoch &+= 1
        let callbackEpoch = tokenRegistrationEpoch
        tokenRegistration = Task {
            await GroupAdmissionService.shared.register(deviceToken: deviceToken, epoch: callbackEpoch)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
#if DEBUG
        guard !Self.suppressesNormalServicesForDebugLaunch else { return }
#endif
        // The framework error can contain device/environment details. Keep the
        // log generic; a future activation retries registration automatically.
        SharedLog.app.warning(
            "moment-push",
            "Remote notification registration was deferred"
        )
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
#if DEBUG
        guard !Self.suppressesNormalServicesForDebugLaunch else {
            completionHandler(.noData)
            return
        }
#endif
        if let route = GroupNotificationRoute.parse(userInfo) {
            Task {
                let accepted = await GroupAdmissionService.shared.receive(route, open: false)
                completionHandler(accepted ? .newData : .noData)
            }
            return
        }
        // Legacy and malformed envelopes cannot wake the retired relay.
        completionHandler(.noData)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
#if DEBUG
        guard !Self.suppressesNormalServicesForDebugLaunch else { return [] }
#endif
        // APNs and the existing local fallback both contain only generic text.
        // Keep them visible in the foreground without adding sound or a badge.
        return [.banner]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
#if DEBUG
        guard !Self.suppressesNormalServicesForDebugLaunch else { return }
#endif
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let route = GroupNotificationRoute.parse(response.notification.request.content.userInfo) {
            _ = await GroupAdmissionService.shared.receive(route, open: true)
            return
        }
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           response.notification.request.content.userInfo[AlbumArrivalNotice.userInfoKey] != nil {
            AlbumArrivalOpenInbox.shared.showsAlbum = true
            return
        }
        // Legacy two-person notification taps no longer select a window.
    }

    private func run(_ backgroundTask: BGAppRefreshTask) {
        guard SharingAPIConfiguration.current.isMediaAvailable else {
            backgroundTask.setTaskCompleted(success: true)
            return
        }
        // Submit the next request before doing network work. If iOS terminates
        // this attempt, a later best-effort opportunity remains scheduled.
        scheduleNextRefresh()
        // Serialize scheduled refresh attempts. GroupAdmissionService also
        // coalesces foreground and authenticated notification refreshes.
        let precedingRefresh = activeRefresh
        let operation = Task { @MainActor in
            await precedingRefresh?.value
            guard !Task.isCancelled else {
                backgroundTask.setTaskCompleted(success: false)
                return
            }
            let protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
            if protectedDataAvailable { await GroupAdmissionService.shared.refresh() }
            backgroundTask.setTaskCompleted(success: protectedDataAvailable && !Task.isCancelled)
        }
        activeRefresh = operation
        backgroundTask.expirationHandler = {
            operation.cancel()
        }
    }

    private func scheduleNextRefresh() {
        let request = BGAppRefreshTaskRequest(
            identifier: GroupBackgroundRefreshPolicy.taskIdentifier
        )
        request.earliestBeginDate = Date().addingTimeInterval(
            GroupBackgroundRefreshPolicy.earliestBeginDelay
        )
        do {
            try BGTaskScheduler.shared.submit(request)
            SharedLog.app.debug(
                "moment-background-refresh",
                "Background refresh requested"
            )
        } catch {
            // Do not log the framework error description. It can contain
            // environment details and is not actionable to the person using
            // the app. Foreground synchronization remains available.
            SharedLog.app.warning(
                "moment-background-refresh",
                "Background refresh request was deferred"
            )
        }
    }

    private func reconcileRemoteNotificationRegistration() {
        registrationReconciliation?.cancel()
        registrationReconciliation = Task {
            await GroupAdmissionService.shared.refresh()
        }
    }
}

/// Single foreground/background coordinator. Admission remains recoverable without notifications.
@MainActor
final class GroupAdmissionService: ObservableObject {
    static let shared = GroupAdmissionService()
    @Published private(set) var results: [GroupAdmissionResult] = []
    private var token: Data?
    private var tokenEpoch: UInt64 = 0
    private var running = false
    private var rerun = false
    private var permissionRequested = false

    func register(deviceToken: Data, epoch: UInt64) async {
        guard epoch >= tokenEpoch else { return }
        tokenEpoch = epoch; token = deviceToken
        await refresh()
    }
    func refresh(requestPermission: Bool = false) async {
        permissionRequested = permissionRequested || requestPermission
        rerun = true
        guard !running else { return }
        running = true; defer { running = false }
        repeat {
            rerun = false
            guard !Task.isCancelled, let client = GroupWindowClientProvider.production,
                  (try? await client.hasLocalGroupState()) == true else { return }
            var settings = await UNUserNotificationCenter.current().notificationSettings()
            if permissionRequested, settings.authorizationStatus == .notDetermined {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge])
                settings = await UNUserNotificationCenter.current().notificationSettings()
            }
            permissionRequested = false
            let allowed = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
            if allowed && token == nil { UIApplication.shared.registerForRemoteNotifications() }
            if let refreshed = try? await client.reconcileAdmissions(), !refreshed.isEmpty { results = refreshed }
#if DEBUG
            let environment = "development"
#else
            let environment = "production"
#endif
            if allowed, let token { try? await client.updatePushSubscriptions(deviceToken: token, environment: environment) }
            else if !allowed { try? await client.updatePushSubscriptions(deviceToken: nil, environment: environment) }
        } while rerun && !Task.isCancelled
    }
    func receive(_ route: GroupNotificationRoute, open: Bool) async -> Bool {
        guard let client = GroupWindowClientProvider.production,
              (try? await client.acceptsNotification(windowID: route.windowID, requestID: route.requestID, kind: route.kind)) == true else { return false }
        await refresh()
        // Explicit tap may navigate only AFTER authenticated membership, roster and key loading.
        if open, (try? await client.window(id: route.windowID)) != nil {
            GroupWindowOpenInbox.shared.open(windowID: route.windowID)
        }
        return true
    }
}
