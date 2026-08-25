import BackgroundTasks
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

@MainActor
final class NekoWidgetAppDelegate: NSObject, UIApplicationDelegate,
    UNUserNotificationCenterDelegate {
    private var activeRefresh: Task<Void, Never>?
    private var registrationReconciliation: Task<Void, Never>?
    private var tokenRegistration: Task<Void, Never>?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [
            UIApplication.LaunchOptionsKey: Any
        ]? = nil
    ) -> Bool {
#if DEBUG
        guard !CommandLine.arguments.contains("--sharing-runtime-self-test"),
              !CommandLine.arguments.contains(AppStoreScreenshotFixture.launchArgument)
        else { return true }
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
        // Notification permission and the APNs token can change outside the
        // app. Reconcile on every foreground activation; the signed PUT is
        // idempotent and extends the server-side bounded subscription lease.
        reconcileRemoteNotificationRegistration()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        guard SharingAPIConfiguration.current.isMediaAvailable else { return }
        scheduleNextRefresh()
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // Do not cancel an in-flight callback here. If its network request has
        // already reached the relay, cancellation could prevent the actor from
        // observing staleness and re-registering the newest selected window.
        // The generation/catalog CAS inside `register` makes both callbacks
        // converge instead.
        tokenRegistration = Task {
            await MomentPushSubscriptionService.shared.register(
                deviceToken: deviceToken
            )
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
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
        activeRefresh?.cancel()
        let operation = Task { @MainActor in
            let result = await MomentBackgroundRefreshService.shared.refresh(
                protectedDataAvailable: application.isProtectedDataAvailable,
                trigger: "remote-notification",
                emitLocalNotifications: false
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
        // APNs and the existing local fallback both contain only generic text.
        // Keep them visible in the foreground without adding sound or a badge.
        [.banner]
    }

    private func run(_ backgroundTask: BGAppRefreshTask) {
        guard SharingAPIConfiguration.current.isMediaAvailable else {
            backgroundTask.setTaskCompleted(success: true)
            return
        }
        // Submit the next request before doing network work. If iOS terminates
        // this attempt, a later best-effort opportunity remains scheduled.
        scheduleNextRefresh()
        activeRefresh?.cancel()
        let operation = Task { @MainActor in
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

    private struct AuthenticatedWindowContext: Sendable {
        let localWindowID: String
        let isActive: Bool
        let pairing: PairingState
        let credential: PairingCredential
    }

    private let notificationCenter: UNUserNotificationCenter
    /// Actor methods are reentrant across network awaits. The generation and
    /// catalog active ID prevent an older APNs callback from winning after a
    /// private-window switch.
    private var registrationGeneration: UInt64 = 0

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
                let contexts = try await authenticatedContextsForAllWindows(
                    verifiedBootstrap: bootstrap
                )
                guard generation == registrationGeneration,
                      contexts.contains(where: {
                    $0.isActive
                        && MomentBackgroundRefreshPolicy.isEligible(
                            configuration: .current,
                            pairing: $0.pairing
                        )
                }) else { return }
                _ = try? await notificationCenter.requestAuthorization(
                    options: [.alert, .provisional]
                )
                guard generation == registrationGeneration else { return }
                settings = await notificationCenter.notificationSettings()
                guard generation == registrationGeneration else { return }
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
            let contexts = try await authenticatedContextsForAllWindows(
                verifiedBootstrap: bootstrap
            )
            guard let activeWindowID = try PrivateWindowCatalogStore.load()?.activeWindowID,
                  registrationTargetIsCurrent(
                      localWindowID: activeWindowID,
                      generation: generation
                  ) else { return }
            let client = try URLSessionMomentSharingAPIClient()
            // Background synchronization currently owns one explicit UI
            // destination: the selected window. Remove subscriptions for all
            // inactive windows before registering that destination so a
            // generic APNs alert can never wake the app for a different room
            // and then publish the selected room by mistake.
            for context in contexts where !context.isActive {
                guard !Task.isCancelled,
                      registrationTargetIsCurrent(
                          localWindowID: activeWindowID,
                          generation: generation
                      ) else { return }
                try? await client.deletePushSubscription(
                    pairingState: context.pairing,
                    credential: context.credential
                )
                guard registrationTargetIsCurrent(
                    localWindowID: activeWindowID,
                    generation: generation
                ) else { return }
            }
            guard let active = contexts.first(where: { $0.isActive }) else {
                return
            }
            guard MomentBackgroundRefreshPolicy.isEligible(
                configuration: .current,
                pairing: active.pairing
            ) else {
                guard registrationTargetIsCurrent(
                    localWindowID: activeWindowID,
                    generation: generation
                ) else { return }
                try? await client.deletePushSubscription(
                    pairingState: active.pairing,
                    credential: active.credential
                )
                return
            }
            guard !Task.isCancelled,
                  registrationTargetIsCurrent(
                      localWindowID: activeWindowID,
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

    func register(deviceToken: Data) async {
        guard (16...256).contains(deviceToken.count) else { return }
        let settings = await notificationCenter.notificationSettings()
        guard Self.allowsRemoteAlerts(settings) else {
            await deleteCurrentSubscriptionIfPossible()
            return
        }
        do {
            // A stale callback retains the raw token only in this stack frame
            // and retries against the newest selected window. Bound rapid
            // switching; a later app activation is the final retry path.
            registrationAttempt: for _ in 0..<4 {
                guard !Task.isCancelled else { return }
                let generation = registrationGeneration
                let contexts = try await authenticatedContextsForAllWindows()
                guard let active = contexts.first(where: { $0.isActive }) else {
                    return
                }
                guard registrationTargetIsCurrent(
                    localWindowID: active.localWindowID,
                    generation: generation
                ) else { continue registrationAttempt }
                let client = try URLSessionMomentSharingAPIClient()
                for context in contexts where !context.isActive {
                    guard registrationTargetIsCurrent(
                        localWindowID: active.localWindowID,
                        generation: generation
                    ) else { continue registrationAttempt }
                    try? await client.deletePushSubscription(
                        pairingState: context.pairing,
                        credential: context.credential
                    )
                    guard registrationTargetIsCurrent(
                        localWindowID: active.localWindowID,
                        generation: generation
                    ) else { continue registrationAttempt }
                }
                guard MomentBackgroundRefreshPolicy.isEligible(
                    configuration: .current,
                    pairing: active.pairing
                ) else {
                    try? await client.deletePushSubscription(
                        pairingState: active.pairing,
                        credential: active.credential
                    )
                    guard registrationTargetIsCurrent(
                        localWindowID: active.localWindowID,
                        generation: generation
                    ) else { continue registrationAttempt }
                    SharedLog.app.info(
                        "moment-push",
                        "Remote notification subscriptions removed"
                    )
                    return
                }
                try await client.putPushSubscription(
                    deviceToken: deviceToken,
                    pairingState: active.pairing,
                    credential: active.credential
                )
                guard registrationTargetIsCurrent(
                    localWindowID: active.localWindowID,
                    generation: generation
                ) else { continue registrationAttempt }
                SharedLog.app.info(
                    "moment-push",
                    "Remote notification subscription registered"
                )
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
        do {
            let contexts = try await authenticatedContextsForAllWindows()
            let client = try URLSessionMomentSharingAPIClient()
            for context in contexts {
                guard !Task.isCancelled else { return }
                try? await client.deletePushSubscription(
                    pairingState: context.pairing,
                    credential: context.credential
                )
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

    /// Produces one authenticated context per locally paired window without
    /// switching the user's selected window. Registration uses the active
    /// context and signed DELETEs for the rest until background synchronization
    /// can safely run against an explicit non-active store scope.
    private func authenticatedContextsForAllWindows(
        verifiedBootstrap: PairingInstallationGuard.BootstrapResult? = nil
    ) async throws -> [AuthenticatedWindowContext] {
        let bootstrap: PairingInstallationGuard.BootstrapResult
        if let verifiedBootstrap {
            bootstrap = verifiedBootstrap
        } else {
            bootstrap = try await PairingInstallationGuard.bootstrapAsync()
        }
        guard let catalog = try PrivateWindowCatalogStore.load() else {
            throw PairingError.stateUnavailable
        }
        var contexts: [AuthenticatedWindowContext] = []
        var seenCredentialAccounts = Set<String>()
        for entry in catalog.windows {
            let pairing: PairingState?
            if entry.localWindowID == catalog.activeWindowID {
                pairing = bootstrap.state
            } else {
                pairing = try? PairingStateStore.load(
                    localWindowID: entry.localWindowID
                )
            }
            guard let pairing,
                  pairing.installationMarker == bootstrap.state.installationMarker,
                  pairing.phase == .paired,
                  let account = pairing.credentialAccount,
                  seenCredentialAccounts.insert(account).inserted
            else { continue }
            guard let context = try? authenticatedContext(for: pairing) else {
                continue
            }
            contexts.append(AuthenticatedWindowContext(
                localWindowID: entry.localWindowID,
                isActive: entry.localWindowID == catalog.activeWindowID,
                pairing: context.pairing,
                credential: context.credential
            ))
        }
        return contexts
    }

    private func registrationTargetIsCurrent(
        localWindowID: String,
        generation: UInt64
    ) -> Bool {
        guard generation == registrationGeneration,
              let catalog = try? PrivateWindowCatalogStore.load()
        else { return false }
        return catalog.activeWindowID == localWindowID
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
    /// sender/window label, shared image, or routing identifier to the alert.
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
        emitLocalNotifications: Bool = true
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
                trigger: trigger
            )
            try Task.checkCancellation()

            // Synchronization may revoke or replace local pairing. Bootstrap
            // again and never reuse the earlier lifecycle token after network
            // suspension points.
            let afterBootstrap = try await PairingInstallationGuard.bootstrapAsync()
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
                await postPrivacyMinimizedNewMomentNotification()
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

    private func postPrivacyMinimizedNewMomentNotification() async {
        let settings = await notificationCenter.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral
        else { return }
        let content = UNMutableNotificationContent()
        content.title = "ねこのまど"
        content.body = "新しい一枚が届きました。アプリを開いて確認できます。"
        // Keep the request text-only and generic. It carries no routing data,
        // media, sender/window label, counter, or audible signal.
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
                    receivedAt: item.receivedAt
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
