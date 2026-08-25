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

@MainActor
final class NekoWidgetAppDelegate: NSObject, UIApplicationDelegate {
    private var activeRefresh: Task<Void, Never>?

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
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        guard SharingAPIConfiguration.current.isMediaAvailable else { return }
        scheduleNextRefresh()
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
            let succeeded = await MomentBackgroundRefreshService.shared.refresh(
                protectedDataAvailable: protectedDataAvailable
            )
            backgroundTask.setTaskCompleted(
                success: succeeded && !Task.isCancelled
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

    /// Returns whether the scheduled task completed safely. A successful
    /// no-op (not paired, consent off, or no new change) is intentionally true;
    /// it tells iOS the task behaved correctly without claiming a delivery.
    func refresh(protectedDataAvailable: Bool) async -> Bool {
        guard protectedDataAvailable else {
            SharedLog.app.debug(
                "moment-background-refresh",
                "Background refresh skipped while protected data is unavailable"
            )
            return false
        }
        do {
            try Task.checkCancellation()
            let configuration = SharingAPIConfiguration.current
            let beforeBootstrap = try await PairingInstallationGuard.bootstrapAsync()
            guard MomentBackgroundRefreshPolicy.isEligible(
                configuration: configuration,
                pairing: beforeBootstrap.state
            ) else {
                try await clearFamilyWidgetIfNeeded(
                    pairing: beforeBootstrap.state,
                    lifecycleToken: beforeBootstrap.lifecycleToken
                )
                return true
            }

            // Provisional authorization is quiet and does not display a system
            // prompt. A denied choice is respected forever. Notifications are
            // local-only; no push token or APNs entitlement is introduced.
            await prepareQuietNotificationAuthorization()

            let now = Date()
            let beforeState = try MomentSharingStateStore.load(
                validating: beforeBootstrap.lifecycleToken
            )
            let beforeVisibleIDs = Self.visibleMomentIDs(in: beforeState)

            let synchronizationSucceeded = await coordinator.synchronize(
                trigger: "background-app-refresh"
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
                try await clearFamilyWidgetIfNeeded(
                    pairing: afterBootstrap.state,
                    lifecycleToken: afterBootstrap.lifecycleToken
                )
                return true
            }
            let afterState = try MomentSharingStateStore.load(
                validating: afterBootstrap.lifecycleToken
            )
            let afterPresentation = Self.presentation(from: afterState, now: now)
            let newVisibleCount = Self.visibleMomentIDs(in: afterState)
                .subtracting(beforeVisibleIDs)
                .count
            let afterDisplayName = PrivateWindowPresentationStore.resolvedDisplayName(
                pairing: afterBootstrap.state,
                validating: afterBootstrap.lifecycleToken
            )
            let latestItem = afterPresentation.latestStableID.flatMap { stableID in
                afterState.inbox.first(where: { $0.id == stableID })
            }
            _ = try await widgetCacheBuilder.buildFamilyWindow(
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

            if newVisibleCount > 0 {
                await postPrivacyMinimizedNewMomentNotification()
            }
            SharedLog.app.info(
                "moment-background-refresh",
                "Background refresh published family presentation"
            )
            return synchronizationSucceeded
        } catch is CancellationError {
            SharedLog.app.debug(
                "moment-background-refresh",
                "Background refresh expired"
            )
            return false
        } catch {
            // Foreground activation remains the reliable retry path. Never put
            // relay text, identifiers, filenames, or payload details in logs.
            SharedLog.app.warning(
                "moment-background-refresh",
                "Background refresh failed closed"
            )
            return false
        }
    }

    private func clearFamilyWidgetIfNeeded(
        pairing: PairingState,
        lifecycleToken: SharingLifecycleGate.Token
    ) async throws {
        let previous = Self.familyWidgetManifest()
        let displayName = pairing.spaceID == nil
            ? nil
            : PrivateWindowPresentationStore.resolvedDisplayName(
                pairing: pairing,
                validating: lifecycleToken
            )
        guard previous?.item != nil || previous?.windowDisplayName != displayName
        else { return }
        _ = try await widgetCacheBuilder.clearFamilyWindow(
            validating: lifecycleToken,
            windowDisplayName: displayName
        )
        await MainActor.run {
            WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
        }
    }

    private func prepareQuietNotificationAuthorization() async {
        let settings = await notificationCenter.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await notificationCenter.requestAuthorization(
            options: [.alert, .provisional]
        )
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
