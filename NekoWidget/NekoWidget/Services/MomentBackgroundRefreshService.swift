import BackgroundTasks
import Combine
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import UserNotifications
import WidgetKit

/// iOS owns the execution time of app refresh tasks. This service therefore
/// makes no immediate-delivery promise: it performs one bounded, authenticated
/// synchronization only when the system wakes the host app with protected data
/// available.
enum MomentBackgroundRefreshPolicy {
    static let taskIdentifier = "jp.nekowidget.app.background-moment-refresh"
    static let earliestBeginDelay: TimeInterval = 15 * 60

    static func isEligible(
        configuration: SharingAPIConfiguration,
        pairing: PairingState
    ) -> Bool {
        configuration.isMediaAvailable
            && pairing.phase == .paired
            && pairing.mediaSharingConsentVersion
                == PairingMediaSharingConsent.currentVersion
            && pairing.mediaSharingConsentAcceptedAt != nil
    }
}

struct MomentBackgroundRefreshResult: Equatable, Sendable {
    let succeeded: Bool
    let didChange: Bool

    static let failed = Self(succeeded: false, didChange: false)
    static let noData = Self(succeeded: true, didChange: false)

    static func changed() -> Self {
        Self(succeeded: true, didChange: true)
    }
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
    static let shared = MomentNotificationTapMailbox()

    @Published private(set) var pendingTap: MomentNotificationTap?

    private init() {}

    func enqueue(_ route: MomentNotificationRoute) {
        pendingTap = MomentNotificationTap(id: UUID(), route: route)
    }

    func consume(id: UUID) {
        guard pendingTap?.id == id else { return }
        pendingTap = nil
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
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: MomentBackgroundRefreshPolicy.taskIdentifier,
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
        // already reached the relay, cancellation could prevent the actor from
        // observing staleness and re-registering the newest selected window.
        // The generation/catalog CAS inside `register` makes both callbacks
        // converge instead.
        tokenRegistrationEpoch &+= 1
        let callbackEpoch = tokenRegistrationEpoch
        tokenRegistration = Task {
            await MomentPushSubscriptionService.shared.register(
                deviceToken: deviceToken,
                callbackEpoch: callbackEpoch
            )
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
        guard let route = MomentNotificationRoutePayload.route(from: userInfo) else {
            // A malformed or unknown envelope must never be interpreted as a
            // generic wake for whichever private window happens to be active.
            reconcileRemoteNotificationRegistration()
            completionHandler(.noData)
            return
        }
        // A stale APNs binding can briefly deliver a push for a window that is
        // no longer selected. Never synchronize the active window in response
        // to an explicitly different target. A target-less legacy push keeps
        // the existing active-window behavior.
        if let target = route.target {
            guard Self.notificationTargetMatchesActiveWindow(target) else {
                reconcileRemoteNotificationRegistration()
                completionHandler(.noData)
                return
            }
        }
        // A second photo can produce another push while the first authenticated
        // refresh is still running. Queue it behind that work instead of
        // cancelling the earlier fetch and reporting a false failure to iOS.
        let precedingRefresh = activeRefresh
        let operation = Task { @MainActor in
            await precedingRefresh?.value
            guard !Task.isCancelled else {
                completionHandler(.failed)
                return
            }
            let result = await MomentBackgroundRefreshService.shared.refresh(
                protectedDataAvailable: application.isProtectedDataAvailable,
                trigger: "remote-notification",
                emitLocalNotifications: false,
                expectedSpaceID: route.target?.spaceID
            )
            guard !Task.isCancelled, result.succeeded else {
                completionHandler(.failed)
                return
            }
            completionHandler(result.didChange ? .newData : .noData)
        }
        activeRefresh = operation
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
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let route = MomentNotificationRoutePayload.route(
                  from: response.notification.request.content.userInfo
              )
        else { return }
        MomentNotificationTapMailbox.shared.enqueue(route)
    }

    private static func notificationTargetMatchesActiveWindow(
        _ target: MomentNotificationRouteTarget
    ) -> Bool {
        do {
            guard let catalog = try PrivateWindowCatalogStore.load(),
                  let active = catalog.windows.first(where: {
                      $0.localWindowID == catalog.activeWindowID
                  })
            else { return false }
            return active.spaceID == target.spaceID
        } catch {
            return false
        }
    }

    private func run(_ backgroundTask: BGAppRefreshTask) {
        guard SharingAPIConfiguration.current.isMediaAvailable else {
            backgroundTask.setTaskCompleted(success: true)
            return
        }
        // Submit the next request before doing network work. If iOS terminates
        // this attempt, a later best-effort opportunity remains scheduled.
        scheduleNextRefresh()
        // Do not cancel a remote-notification refresh that may already have
        // authenticated and downloaded data. The scheduled task can safely run
        // immediately after it through the process-wide serialized coordinator.
        let precedingRefresh = activeRefresh
        let operation = Task { @MainActor in
            await precedingRefresh?.value
            guard !Task.isCancelled else {
                backgroundTask.setTaskCompleted(success: false)
                return
            }
            let protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
            let result = await MomentBackgroundRefreshService.shared.refresh(
                protectedDataAvailable: protectedDataAvailable
            )
            backgroundTask.setTaskCompleted(
                success: result.succeeded && !Task.isCancelled
            )
        }
        activeRefresh = operation
        backgroundTask.expirationHandler = {
            operation.cancel()
        }
    }

    private func scheduleNextRefresh() {
        let request = BGAppRefreshTaskRequest(
            identifier: MomentBackgroundRefreshPolicy.taskIdentifier
        )
        request.earliestBeginDate = Date().addingTimeInterval(
            MomentBackgroundRefreshPolicy.earliestBeginDelay
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
            await MomentPushSubscriptionService.shared.reconcileRegistration()
        }
    }
}

/// Owns the short-lived handoff from APNs to the signed sharing API. Raw APNs
/// tokens remain in memory only for the duration of one registration request;
/// they are never written to UserDefaults, the App Group, Keychain, or logs.
actor MomentPushSubscriptionService {
    static let shared = MomentPushSubscriptionService()

    private enum RemoteMutationKind {
        case put(
            deviceToken: Data,
            legacyFallbackGuard: LegacyFallbackGuard?
        )
        case delete
    }

    private struct QueuedRemoteMutation {
        let kind: RemoteMutationKind
        let pairing: PairingState
        let credential: PairingCredential
        let tokenCallbackEpoch: UInt64?
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct AuthenticatedWindowContext: Sendable {
        let localWindowID: String
        let isActive: Bool
        let pairing: PairingState
        let credential: PairingCredential
    }

    private struct CatalogFingerprint: Equatable, Sendable {
        struct Entry: Equatable, Sendable {
            let localWindowID: String
            let spaceID: String?
            let credentialAccount: String?
        }

        let activeWindowID: String
        let entries: [Entry]
    }

    private struct LegacyFallbackGuard: Sendable {
        let fingerprint: CatalogFingerprint
        let generation: UInt64
    }

    private struct AuthenticatedWindowSnapshot: Sendable {
        let fingerprint: CatalogFingerprint
        let contexts: [AuthenticatedWindowContext]
    }

    private let notificationCenter: UNUserNotificationCenter
    /// Actor methods are reentrant across network awaits. The generation and
    /// complete catalog fingerprint prevent a request from completing against
    /// a stale private-window authorization map.
    private var registrationGeneration: UInt64 = 0
    /// Assigned by the app delegate before each APNs callback task is created.
    /// A lower epoch can never overwrite part of a newer token's all-window
    /// registration batch.
    private var latestTokenCallbackEpoch: UInt64 = 0
    /// Actor isolation is reentrant across URLSession awaits. A FIFO task gate
    /// makes the server observe signed mutations in the same order in which
    /// generations enqueue them: an old mutation already in flight finishes
    /// before the newest generation's compensating DELETE/PUT can run.
    private var remoteMutationQueue: [QueuedRemoteMutation] = []
    private var remoteMutationWorker: Task<Void, Never>?

    init(notificationCenter: UNUserNotificationCenter = .current()) {
        self.notificationCenter = notificationCenter
    }

    func reconcileRegistration() async {
        guard !Task.isCancelled else { return }
        registrationGeneration &+= 1
        let generation = registrationGeneration
        var settings = await notificationCenter.notificationSettings()
        guard generation == registrationGeneration else { return }
        var verifiedBootstrap: PairingInstallationGuard.BootstrapResult?
        if settings.authorizationStatus == .notDetermined {
            do {
                let bootstrap = try await PairingInstallationGuard.bootstrapAsync()
                verifiedBootstrap = bootstrap
                let snapshot = try await authenticatedContextsForAllWindows(
                    verifiedBootstrap: bootstrap
                )
                guard registrationSnapshotIsCurrent(
                    snapshot.fingerprint,
                    generation: generation
                ), snapshot.contexts.contains(where: {
                    MomentBackgroundRefreshPolicy.isEligible(
                            configuration: .current,
                            pairing: $0.pairing
                        )
                }) else { return }
                _ = try? await notificationCenter.requestAuthorization(
                    options: [.alert, .provisional]
                )
                guard registrationSnapshotIsCurrent(
                    snapshot.fingerprint,
                    generation: generation
                ) else { return }
                settings = await notificationCenter.notificationSettings()
                guard registrationSnapshotIsCurrent(
                    snapshot.fingerprint,
                    generation: generation
                ) else { return }
            } catch {
                return
            }
        }
        guard Self.allowsRemoteAlerts(settings) else {
            if settings.authorizationStatus == .denied
                || settings.alertSetting == .disabled {
                await deleteCurrentSubscriptionIfPossible()
            }
            return
        }

        do {
            let bootstrap: PairingInstallationGuard.BootstrapResult
            if let verifiedBootstrap {
                bootstrap = verifiedBootstrap
            } else {
                bootstrap = try await PairingInstallationGuard.bootstrapAsync()
            }
            let snapshot = try await authenticatedContextsForAllWindows(
                verifiedBootstrap: bootstrap
            )
            let contexts = snapshot.contexts
            guard registrationSnapshotIsCurrent(
                snapshot.fingerprint,
                generation: generation
            ) else { return }
            // A context that is still paired but no longer eligible must lose
            // its own additive binding. Eligible inactive windows stay
            // subscribed; their target-bearing alert is displayed, but the
            // background callback below never synchronizes the active window
            // for that different target.
            for context in contexts where !MomentBackgroundRefreshPolicy.isEligible(
                configuration: .current,
                pairing: context.pairing
            ) {
                guard !Task.isCancelled,
                      registrationSnapshotIsCurrent(
                        snapshot.fingerprint,
                        generation: generation
                      ) else { return }
                try? await performRemoteMutation(
                    .delete,
                    pairing: context.pairing,
                    credential: context.credential
                )
                guard !Task.isCancelled,
                      registrationSnapshotIsCurrent(
                        snapshot.fingerprint,
                        generation: generation
                      ) else { return }
            }
            guard contexts.contains(where: {
                MomentBackgroundRefreshPolicy.isEligible(
                    configuration: .current,
                    pairing: $0.pairing
                )
            }) else {
                return
            }
            guard !Task.isCancelled,
                  registrationSnapshotIsCurrent(
                    snapshot.fingerprint,
                    generation: generation
                  ) else { return }
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            SharedLog.app.warning(
                "moment-push",
                "Remote notification registration reconciliation deferred"
            )
        }
    }

    func register(deviceToken: Data, callbackEpoch: UInt64) async {
        guard (16...256).contains(deviceToken.count) else { return }
        guard callbackEpoch >= latestTokenCallbackEpoch else { return }
        latestTokenCallbackEpoch = callbackEpoch
        let settings = await notificationCenter.notificationSettings()
        guard callbackEpoch == latestTokenCallbackEpoch else { return }
        guard Self.allowsRemoteAlerts(settings) else {
            await deleteCurrentSubscriptionIfPossible()
            return
        }
        do {
            // A stale callback retains the raw token only in this stack frame
            // and retries against the newest complete catalog. Bound rapid
            // switching; a later app activation is the final retry path.
            registrationAttempt: for _ in 0..<4 {
                guard !Task.isCancelled,
                      callbackEpoch == latestTokenCallbackEpoch else { return }
                let generation = registrationGeneration
                let snapshot = try await authenticatedContextsForAllWindows()
                guard callbackEpoch == latestTokenCallbackEpoch else { return }
                guard registrationSnapshotIsCurrent(
                    snapshot.fingerprint,
                    generation: generation,
                    tokenCallbackEpoch: callbackEpoch
                ) else { continue registrationAttempt }

                var mutationFailed = false
                var registeredCount = 0
                for context in snapshot.contexts {
                    guard !Task.isCancelled else { return }
                    guard callbackEpoch == latestTokenCallbackEpoch else { return }
                    guard registrationSnapshotIsCurrent(
                        snapshot.fingerprint,
                        generation: generation,
                        tokenCallbackEpoch: callbackEpoch
                    ) else { continue registrationAttempt }
                    do {
                        if MomentBackgroundRefreshPolicy.isEligible(
                            configuration: .current,
                            pairing: context.pairing
                        ) {
                            // Notification permission can change while earlier
                            // contexts wait on the FIFO/network. Check it again
                            // immediately before every PUT. Opt-out removes all
                            // authenticated window bindings, including ones
                            // already registered by this callback.
                            let latestSettings = await notificationCenter
                                .notificationSettings()
                            guard callbackEpoch == latestTokenCallbackEpoch else {
                                return
                            }
                            guard registrationSnapshotIsCurrent(
                                snapshot.fingerprint,
                                generation: generation,
                                tokenCallbackEpoch: callbackEpoch
                            ) else { continue registrationAttempt }
                            guard Self.allowsRemoteAlerts(latestSettings) else {
                                await deleteCurrentSubscriptionIfPossible()
                                return
                            }
                            try await performRemoteMutation(
                                .put(
                                    deviceToken: deviceToken,
                                    legacyFallbackGuard: context.isActive
                                        ? LegacyFallbackGuard(
                                            fingerprint: snapshot.fingerprint,
                                            generation: generation
                                        )
                                        : nil
                                ),
                                pairing: context.pairing,
                                credential: context.credential,
                                tokenCallbackEpoch: callbackEpoch
                            )
                            registeredCount += 1
                        } else {
                            try await performRemoteMutation(
                                .delete,
                                pairing: context.pairing,
                                credential: context.credential
                            )
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        // One revoked or temporarily unavailable credential
                        // must not prevent other independent windows from
                        // receiving their correctly targeted notifications.
                        mutationFailed = true
                    }
                    guard callbackEpoch == latestTokenCallbackEpoch else { return }
                    guard registrationSnapshotIsCurrent(
                        snapshot.fingerprint,
                        generation: generation,
                        tokenCallbackEpoch: callbackEpoch
                    ) else { continue registrationAttempt }
                }
                guard callbackEpoch == latestTokenCallbackEpoch else { return }
                guard registrationSnapshotIsCurrent(
                    snapshot.fingerprint,
                    generation: generation,
                    tokenCallbackEpoch: callbackEpoch
                ) else { continue registrationAttempt }
                if mutationFailed {
                    throw MomentSharingError.retryableServer(retryAfterSeconds: nil)
                }
                if registeredCount > 0 {
                    SharedLog.app.info(
                        "moment-push",
                        "Remote notification subscriptions registered"
                    )
                } else {
                    SharedLog.app.info(
                        "moment-push",
                        "Remote notification subscriptions removed"
                    )
                }
                return
            }
            throw MomentSharingError.stateUnavailable
        } catch {
            // Registration is best-effort. Foreground and BGAppRefresh
            // synchronization remain available, and the next activation tries
            // again without retaining the raw token locally.
            SharedLog.app.warning(
                "moment-push",
                "Remote notification subscription registration deferred"
            )
        }
    }

    private func deleteCurrentSubscriptionIfPossible() async {
        let generation = registrationGeneration
        do {
            let snapshot = try await authenticatedContextsForAllWindows()
            guard registrationSnapshotIsCurrent(
                snapshot.fingerprint,
                generation: generation
            ) else { return }
            for context in snapshot.contexts {
                guard !Task.isCancelled,
                      registrationSnapshotIsCurrent(
                        snapshot.fingerprint,
                        generation: generation
                      ) else { return }
                try await performRemoteMutation(
                    .delete,
                    pairing: context.pairing,
                    credential: context.credential
                )
                guard !Task.isCancelled,
                      registrationSnapshotIsCurrent(
                        snapshot.fingerprint,
                        generation: generation
                      ) else { return }
            }
        } catch {
            // Device/space revocation cascades server-side and subscriptions
            // also expire. A failed best-effort DELETE must never erase local
            // pairing state or expose credential/token details in a log.
            SharedLog.app.debug(
                "moment-push",
                "Remote notification subscription removal deferred"
            )
        }
    }

    private func performRemoteMutation(
        _ kind: RemoteMutationKind,
        pairing: PairingState,
        credential: PairingCredential,
        tokenCallbackEpoch: UInt64? = nil
    ) async throws {
        guard tokenCallbackIsCurrent(tokenCallbackEpoch) else {
            throw CancellationError()
        }
        try await withCheckedThrowingContinuation { continuation in
            remoteMutationQueue.append(QueuedRemoteMutation(
                kind: kind,
                pairing: pairing,
                credential: credential,
                tokenCallbackEpoch: tokenCallbackEpoch,
                continuation: continuation
            ))
            startRemoteMutationWorkerIfNeeded()
        }
    }

    private func startRemoteMutationWorkerIfNeeded() {
        guard remoteMutationWorker == nil else { return }
        remoteMutationWorker = Task { [weak self] in
            await self?.drainRemoteMutationQueue()
        }
    }

    private func drainRemoteMutationQueue() async {
        while !remoteMutationQueue.isEmpty {
            let mutation = remoteMutationQueue.removeFirst()
            do {
                guard tokenCallbackIsCurrent(mutation.tokenCallbackEpoch) else {
                    throw CancellationError()
                }
                let client = try URLSessionMomentSharingAPIClient()
                switch mutation.kind {
                case let .put(deviceToken, legacyFallbackGuard):
                    do {
                        try await client.putTargetedPushSubscription(
                            deviceToken: deviceToken,
                            pairingState: mutation.pairing,
                            credential: mutation.credential
                        )
                    } catch {
                        guard Self.targetedSubscriptionEndpointIsUnavailable(error)
                        else { throw error }
                        // A legacy server can safely retain one exclusive
                        // binding only. Contexts are active-first, so only the
                        // selected window may cross this rollback boundary.
                        guard let legacyFallbackGuard else { throw error }
                        guard tokenCallbackIsCurrent(
                            mutation.tokenCallbackEpoch
                        ) else { throw CancellationError() }
                        guard registrationSnapshotIsCurrent(
                            legacyFallbackGuard.fingerprint,
                            generation: legacyFallbackGuard.generation,
                            tokenCallbackEpoch: mutation.tokenCallbackEpoch
                        ) else { throw CancellationError() }
                        try await client.putPushSubscription(
                            deviceToken: deviceToken,
                            pairingState: mutation.pairing,
                            credential: mutation.credential
                        )
                        guard registrationSnapshotIsCurrent(
                            legacyFallbackGuard.fingerprint,
                            generation: legacyFallbackGuard.generation,
                            tokenCallbackEpoch: mutation.tokenCallbackEpoch
                        ) else {
                            // A target-less legacy binding must not survive a
                            // window switch that completed while the request
                            // was in flight. Remove that exact signed device
                            // binding before releasing the FIFO gate.
                            try? await client.deletePushSubscription(
                                pairingState: mutation.pairing,
                                credential: mutation.credential
                            )
                            throw CancellationError()
                        }
                    }
                case .delete:
                    // DELETE semantics are identical in v2, making this the
                    // safe opt-out/rollback boundary if a v3 relay is removed.
                    try await client.deletePushSubscription(
                        pairingState: mutation.pairing,
                        credential: mutation.credential
                    )
                }
                guard tokenCallbackIsCurrent(mutation.tokenCallbackEpoch) else {
                    throw CancellationError()
                }
                mutation.continuation.resume()
            } catch {
                mutation.continuation.resume(throwing: error)
            }
        }
        remoteMutationWorker = nil
    }

    private func tokenCallbackIsCurrent(_ epoch: UInt64?) -> Bool {
        guard let epoch else { return true }
        return epoch == latestTokenCallbackEpoch
    }

    private static func targetedSubscriptionEndpointIsUnavailable(
        _ error: Error
    ) -> Bool {
        guard let sharingError = error as? MomentSharingError,
              case let .requestRejected(status, code, _) = sharingError
        else { return false }
        return status == 404 && code == "not_found"
    }

    /// Produces one authenticated context per locally paired window without
    /// switching the user's selected window. The raw token is then registered
    /// independently through each context; this does not grant background
    /// synchronization access to any inactive window's local stores.
    private func authenticatedContextsForAllWindows(
        verifiedBootstrap: PairingInstallationGuard.BootstrapResult? = nil
    ) async throws -> AuthenticatedWindowSnapshot {
        let bootstrap: PairingInstallationGuard.BootstrapResult
        if let verifiedBootstrap {
            bootstrap = verifiedBootstrap
        } else {
            bootstrap = try await PairingInstallationGuard.bootstrapAsync()
        }
        // Capture the catalog and every window state under the lifecycle token
        // returned with the active bootstrap. A window switch bumps that token,
        // so the old active state can never be attached to a new active ID.
        let snapshot = try SharingLifecycleGate.withValidatedToken(
            bootstrap.lifecycleToken
        ) { () -> (
            catalog: PrivateWindowCatalogState,
            pairings: [(entry: PrivateWindowCatalogEntry, state: PairingState?)]
        ) in
            guard let catalog = try PrivateWindowCatalogStore.load(),
                  let activeEntry = catalog.windows.first(where: {
                      $0.localWindowID == catalog.activeWindowID
                  }),
                  activeEntry.spaceID == bootstrap.state.spaceID,
                  activeEntry.credentialAccount
                    == bootstrap.state.credentialAccount
            else { throw PairingError.stateUnavailable }
            let pairings = catalog.windows.map { entry in
                let state: PairingState?
                if entry.localWindowID == catalog.activeWindowID {
                    state = bootstrap.state
                } else {
                    state = try? PairingStateStore.load(
                        localWindowID: entry.localWindowID
                    )
                }
                return (entry: entry, state: state)
            }
            return (catalog: catalog, pairings: pairings)
        }
        var contexts: [AuthenticatedWindowContext] = []
        var seenCredentialAccounts = Set<String>()
        for candidate in snapshot.pairings {
            let entry = candidate.entry
            let pairing = candidate.state
            guard let pairing,
                  pairing.installationMarker == bootstrap.state.installationMarker,
                  pairing.phase == .paired,
                  let account = pairing.credentialAccount,
                  entry.spaceID == pairing.spaceID,
                  entry.credentialAccount == account,
                  seenCredentialAccounts.insert(account).inserted
            else { continue }
            guard let context = try? authenticatedContext(for: pairing) else {
                continue
            }
            contexts.append(AuthenticatedWindowContext(
                localWindowID: entry.localWindowID,
                isActive: entry.localWindowID == snapshot.catalog.activeWindowID,
                pairing: context.pairing,
                credential: context.credential
            ))
        }
        // Keychain resolution does not hold the lifecycle flock. Reject the
        // complete snapshot if another thread selected a window meanwhile.
        try SharingLifecycleGate.validate(bootstrap.lifecycleToken)
        contexts.sort { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.localWindowID < rhs.localWindowID
        }
        return AuthenticatedWindowSnapshot(
            fingerprint: Self.catalogFingerprint(snapshot.catalog),
            contexts: contexts
        )
    }

    private func registrationSnapshotIsCurrent(
        _ fingerprint: CatalogFingerprint,
        generation: UInt64,
        tokenCallbackEpoch: UInt64? = nil
    ) -> Bool {
        guard generation == registrationGeneration,
              tokenCallbackIsCurrent(tokenCallbackEpoch),
              let catalog = try? PrivateWindowCatalogStore.load()
        else { return false }
        return Self.catalogFingerprint(catalog) == fingerprint
    }

    private static func catalogFingerprint(
        _ catalog: PrivateWindowCatalogState
    ) -> CatalogFingerprint {
        CatalogFingerprint(
            activeWindowID: catalog.activeWindowID,
            entries: catalog.windows.map {
                CatalogFingerprint.Entry(
                    localWindowID: $0.localWindowID,
                    spaceID: $0.spaceID,
                    credentialAccount: $0.credentialAccount
                )
            }.sorted { $0.localWindowID < $1.localWindowID }
        )
    }

    private func authenticatedContext(
        for pairing: PairingState
    ) throws -> (pairing: PairingState, credential: PairingCredential) {
        guard SharingAPIConfiguration.current.isAvailable,
              pairing.phase == .paired,
              let account = pairing.credentialAccount
        else { throw MomentSharingError.notPaired }
        let credential = try PairingKeychainStore.load(
            account: account,
            installationMarker: pairing.installationMarker
        )
        return (pairing, credential)
    }

    private static func allowsRemoteAlerts(_ settings: UNNotificationSettings) -> Bool {
        switch settings.authorizationStatus {
        case .provisional:
            // Provisional notifications are intentionally delivered quietly;
            // an alertSetting value must not turn that authorization into a
            // false denial.
            return true
        case .authorized, .ephemeral:
            return settings.alertSetting != .disabled
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }
}

actor MomentBackgroundRefreshService {
    static let shared = MomentBackgroundRefreshService()

    private let coordinator: MomentSharingCoordinator
    private let widgetCacheBuilder: WidgetCacheBuilder
    private let notificationCenter: UNUserNotificationCenter

    init(
        coordinator: MomentSharingCoordinator = MomentSharingCoordinator(),
        widgetCacheBuilder: WidgetCacheBuilder = WidgetCacheBuilder(),
        notificationCenter: UNUserNotificationCenter = .current()
    ) {
        self.coordinator = coordinator
        self.widgetCacheBuilder = widgetCacheBuilder
        self.notificationCenter = notificationCenter
    }

    /// Returns a privacy-safe presentation state for the in-app notification
    /// control. The app never needs to expose framework details to the view.
    func notificationAuthorizationState() async -> MomentNotificationAuthorizationState {
        let settings = await notificationCenter.notificationSettings()
        return MomentNotificationAuthorizationState(
            authorizationStatus: settings.authorizationStatus,
            alertSetting: settings.alertSetting
        )
    }

    /// Upgrades the existing quiet/provisional notification path only after an
    /// explicit tap. The subsequent APNs registration adds no sound, badge,
    /// sender/window label, shared image, or user-visible routing detail to the
    /// alert.
    func requestVisibleNotificationAuthorization() async
        -> MomentNotificationAuthorizationState {
        let settings = await notificationCenter.notificationSettings()
        guard settings.authorizationStatus != .denied else {
            return .denied
        }
        if settings.authorizationStatus != .authorized
            && settings.authorizationStatus != .ephemeral {
            _ = try? await notificationCenter.requestAuthorization(options: [.alert])
        }
        let state = await notificationAuthorizationState()
        await MomentPushSubscriptionService.shared.reconcileRegistration()
        return state
    }

    /// Separates execution success from observable change. BGTaskScheduler
    /// needs only `succeeded`, while the remote-notification callback must
    /// report `.noData` for an already-synchronized or otherwise unchanged
    /// push so iOS does not learn a false background-fetch success signal.
    func refresh(
        protectedDataAvailable: Bool,
        trigger: String = "background-app-refresh",
        emitLocalNotifications: Bool = true,
        expectedSpaceID: String? = nil
    ) async -> MomentBackgroundRefreshResult {
        guard protectedDataAvailable else {
            SharedLog.app.debug(
                "moment-background-refresh",
                "Background refresh skipped while protected data is unavailable"
            )
            return .failed
        }
        do {
            try Task.checkCancellation()
            let configuration = SharingAPIConfiguration.current
            let beforeBootstrap = try await PairingInstallationGuard.bootstrapAsync()
            guard expectedSpaceID == nil
                    || beforeBootstrap.state.spaceID == expectedSpaceID
            else {
                SharedLog.app.info(
                    "moment-background-refresh",
                    "Background refresh skipped because the selected private window changed"
                )
                return .noData
            }
            guard MomentBackgroundRefreshPolicy.isEligible(
                configuration: configuration,
                pairing: beforeBootstrap.state
            ) else {
                let didClear = try await clearFamilyWidgetIfNeeded(
                    pairing: beforeBootstrap.state,
                    lifecycleToken: beforeBootstrap.lifecycleToken
                )
                return didClear ? .changed() : .noData
            }

            // Provisional authorization is quiet and does not display a system
            // prompt. A denied choice is respected forever. When permission is
            // available, APNs registration is reconciled without persisting the
            // raw device token locally.
            await prepareQuietNotificationAuthorization()

            let now = Date()
            let beforeState = try MomentSharingStateStore.load(
                validating: beforeBootstrap.lifecycleToken
            )
            let beforeVisibleIDs = Self.visibleMomentIDs(in: beforeState)
            let beforePawIDs = Set(beforeState.receivedPaws.map(\.reactionID))
            let beforeManifest = Self.familyWidgetManifest()

            let synchronizationSucceeded = await coordinator.synchronize(
                trigger: trigger,
                expectedSpaceID: expectedSpaceID
            )
            try Task.checkCancellation()

            // Synchronization may revoke or replace local pairing. Bootstrap
            // again and never reuse the earlier lifecycle token after network
            // suspension points.
            let afterBootstrap = try await PairingInstallationGuard.bootstrapAsync()
            guard expectedSpaceID == nil
                    || afterBootstrap.state.spaceID == expectedSpaceID
            else {
                SharedLog.app.info(
                    "moment-background-refresh",
                    "Background refresh result discarded because the selected private window changed"
                )
                return .noData
            }
            guard MomentBackgroundRefreshPolicy.isEligible(
                configuration: configuration,
                pairing: afterBootstrap.state
            ) else {
                let didClear = try await clearFamilyWidgetIfNeeded(
                    pairing: afterBootstrap.state,
                    lifecycleToken: afterBootstrap.lifecycleToken
                )
                return didClear ? .changed() : .noData
            }
            let afterState = try MomentSharingStateStore.load(
                validating: afterBootstrap.lifecycleToken
            )
            let afterPresentation = Self.presentation(from: afterState, now: now)
            let newVisibleCount = Self.visibleMomentIDs(in: afterState)
                .subtracting(beforeVisibleIDs)
                .count
            let newPawCount = Set(afterState.receivedPaws.map(\.reactionID))
                .subtracting(beforePawIDs)
                .count
            let afterDisplayName = PrivateWindowPresentationStore.resolvedDisplayName(
                pairing: afterBootstrap.state,
                validating: afterBootstrap.lifecycleToken
            )
            let latestItem = afterPresentation.latestStableID.flatMap { stableID in
                afterState.inbox.first(where: { $0.id == stableID })
            }
            let publishedManifest = try await widgetCacheBuilder.buildFamilyWindow(
                from: latestItem,
                freshUntil: afterPresentation.priorityUntil,
                windowDisplayName: afterDisplayName,
                validating: afterBootstrap.lifecycleToken,
                now: now
            )
            try Task.checkCancellation()
            await MainActor.run {
                WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
                NotificationCenter.default.post(
                    name: .momentSharingContentNeedsReload,
                    object: nil
                )
            }

            if emitLocalNotifications && newVisibleCount > 0 {
                await postPrivacyMinimizedNewMomentNotification(
                    count: newVisibleCount
                )
            }
            if emitLocalNotifications && newPawCount > 0 {
                await postPrivacyMinimizedPawNotification()
            }
            SharedLog.app.info(
                "moment-background-refresh",
                "Background refresh published family presentation"
            )
            let widgetChanged = beforeManifest?.item != publishedManifest.item
                || beforeManifest?.windowDisplayName
                    != publishedManifest.windowDisplayName
            return MomentBackgroundRefreshResult(
                succeeded: synchronizationSucceeded,
                didChange: afterState != beforeState || widgetChanged
            )
        } catch is CancellationError {
            SharedLog.app.debug(
                "moment-background-refresh",
                "Background refresh expired"
            )
            return .failed
        } catch {
            // Foreground activation remains the reliable retry path. Never put
            // relay text, identifiers, filenames, or payload details in logs.
            SharedLog.app.warning(
                "moment-background-refresh",
                "Background refresh failed closed"
            )
            return .failed
        }
    }

    private func clearFamilyWidgetIfNeeded(
        pairing: PairingState,
        lifecycleToken: SharingLifecycleGate.Token
    ) async throws -> Bool {
        let previous = Self.familyWidgetManifest()
        let displayName = pairing.spaceID == nil
            ? nil
            : PrivateWindowPresentationStore.resolvedDisplayName(
                pairing: pairing,
                validating: lifecycleToken
            )
        guard previous?.item != nil || previous?.windowDisplayName != displayName
        else { return false }
        _ = try await widgetCacheBuilder.clearFamilyWindow(
            validating: lifecycleToken,
            windowDisplayName: displayName
        )
        await MainActor.run {
            WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
        }
        return true
    }

    private func prepareQuietNotificationAuthorization() async {
        let settings = await notificationCenter.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await notificationCenter.requestAuthorization(
            options: [.alert, .provisional]
        )
        await MomentPushSubscriptionService.shared.reconcileRegistration()
    }

    private func postPrivacyMinimizedNewMomentNotification(count: Int) async {
        guard count > 0 else { return }
        let settings = await notificationCenter.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral
        else { return }
        let content = UNMutableNotificationContent()
        content.title = "ねこのまど"
        content.body = count == 1
            ? "新しい一枚が届きました。アプリを開いて確認できます。"
            : "新しい写真が\(count)枚届きました。アプリを開いて確認できます。"
        content.userInfo = MomentNotificationRoutePayload.userInfo(for: .newMoment)
        // Keep the request text-only and generic. It carries no identifier-
        // bearing route, media, sender/window label, counter, or audible signal.
        // The bounded kind only selects a section after authenticated local sync.
        let request = UNNotificationRequest(
            identifier: "moment-arrival-\(UUID().uuidString.lowercased())",
            content: content,
            trigger: nil
        )
        try? await notificationCenter.add(request)
    }

    private func postPrivacyMinimizedPawNotification() async {
        let settings = await notificationCenter.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral
        else { return }
        let content = UNMutableNotificationContent()
        content.title = "ねこのまど"
        content.body = "届けた写真にハートが届きました。"
        content.userInfo = MomentNotificationRoutePayload.userInfo(for: .heart)
        // No photo, sender/window label, moment identifier, sound, or badge is
        // attached. Opening the app performs the authenticated state lookup.
        let request = UNNotificationRequest(
            identifier: "moment-paw-\(UUID().uuidString.lowercased())",
            content: content,
            trigger: nil
        )
        try? await notificationCenter.add(request)
    }

    private static func familyWidgetManifest() -> FamilyWidgetManifest? {
        guard let url = SharedContainer.familyWidgetManifestURL else { return nil }
        return try? AtomicJSON.read(FamilyWidgetManifest.self, from: url)
    }

    private static func presentation(
        from state: MomentSharingState,
        now: Date
    ) -> MomentFamilyWindowPresentation {
        MomentFamilyWindowPresentationPolicy.make(
            inputs: state.inbox.map { item in
                let presentationState: MomentFamilyWindowItemState
                switch item.state {
                case .available: presentationState = .available
                case .acknowledged: presentationState = .acknowledged
                case .blocked: presentationState = .blocked
                case .revoked: presentationState = .revoked
                }
                return MomentFamilyWindowPresentationInput(
                    stableID: item.id,
                    state: presentationState,
                    imageURL: validatedReceivedMomentImageURL(for: item),
                    committedAt: item.committedAt,
                    receivedAt: item.receivedAt,
                    changeSequence: item.changeSequence
                )
            },
            now: now
        )
    }

    private static func visibleMomentIDs(in state: MomentSharingState) -> Set<String> {
        Set(state.inbox.compactMap { item in
            validatedReceivedMomentImageURL(for: item) == nil ? nil : item.id
        })
    }

    private static func validatedReceivedMomentImageURL(
        for item: MomentInboxItem
    ) -> URL? {
        guard item.state == .available || item.state == .acknowledged,
              let filename = item.localJPEGFileName,
              filename == "\(item.id).jpg",
              filename == (filename as NSString).lastPathComponent,
              let directory = SharedContainer.momentSharingReceivedDirectoryURL
        else { return nil }
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedURL.deletingLastPathComponent() == resolvedDirectory,
              let values = try? resolvedURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
              ),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= MomentSharingProtocol.maximumMediaCiphertextBytes - 28,
              let source = CGImageSourceCreateWithURL(
                resolvedURL as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...MomentSharingProtocol.maximumCanonicalPixelDimension).contains(width),
              (1...MomentSharingProtocol.maximumCanonicalPixelDimension).contains(height)
        else { return nil }
        return resolvedURL
    }
}

enum MomentNotificationAuthorizationState: Equatable, Sendable {
    case checking
    case notRequested
    case enabled
    case quiet
    case denied

    init(
        authorizationStatus: UNAuthorizationStatus,
        alertSetting: UNNotificationSetting
    ) {
        switch authorizationStatus {
        case .notDetermined:
            self = .notRequested
        case .authorized, .ephemeral:
            self = alertSetting == .enabled ? .enabled : .denied
        case .provisional:
            self = .quiet
        case .denied:
            self = .denied
        @unknown default:
            self = .denied
        }
    }
}
