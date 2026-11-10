import AppIntents
import SwiftUI
import WidgetKit
import UIKit

@main
@MainActor
struct NekoWidgetApp: App {
    @UIApplicationDelegateAdaptor(NekoWidgetAppDelegate.self)
    private var appDelegate

    init() {
        ClientUpgradePresenter.shared.start()
        ShowcaseAppShortcuts.updateAppShortcutParameters()
#if DEBUG
        if CommandLine.arguments.contains("--personal-archive-ui-fixture") {
            // This fixture exercises the real AppRoot/MainTab lifecycle after
            // onboarding, rather than substituting a settings-only root.
            UserDefaults.standard.set(
                OnboardingPresentationPersistence.currentCompletedVersion,
                forKey: OnboardingPresentationPersistence.completedVersionKey
            )
            UserDefaults.standard.set(true, forKey: "hasSeenInitialScanResult.v1")
        }
        let shouldRunLaunchCleanup = !BillingInternalDiagnosticsLaunch.isActive
            && !CommandLine.arguments.contains("--cat-profile-photo-flow-fixture")
            && !CommandLine.arguments.contains("--photo-window-ui-fixture")
            && !CommandLine.arguments.contains("--moderation-resolution-ui-fixture")
#else
        let shouldRunLaunchCleanup = true
#endif
        // A share sheet cannot survive a process relaunch. Remove only export
        // files with this app's exact prefixes before any new export is made.
        if shouldRunLaunchCleanup {
            EvacuationExporter.cleanupOnLaunch()
            CareHandoffExporter.cleanupOnLaunch()
            LostCatFlyerRenderer.cleanupOnLaunch()
            TemporaryExportFileLifecycle.removeManagedFiles()
            Task {
                // A seasonal movie share sheet also cannot survive relaunch.
                // The service validates the exact managed UUID directory.
                try? await SeasonalMovieExportService.shared.cleanupStaleExports(
                    olderThan: 0
                )
            }
        }
#if DEBUG
        if !BillingInternalDiagnosticsLaunch.isActive,
           !CommandLine.arguments.contains("--cat-profile-photo-flow-fixture"),
           !CommandLine.arguments.contains("--photo-window-ui-fixture"),
           !CommandLine.arguments.contains("--moderation-resolution-ui-fixture"),
           ProcessInfo.processInfo.environment["NEKO_RESET_ONBOARDING_FOR_UI_TESTS"] == "1" {
            let defaults = UserDefaults.standard
            defaults.removeObject(
                forKey: OnboardingPresentationPersistence.completedVersionKey
            )
            defaults.removeObject(
                forKey: OnboardingPresentationPersistence.resumePageIndexKey
            )
            defaults.removeObject(forKey: "hasSeenInitialScanResult.v1")
        }
#endif
    }

    var body: some Scene {
        WindowGroup {
#if DEBUG
            if CommandLine.arguments.contains("--client-upgrade-response-fixture") {
                ClientUpgradeResponseFixture()
            } else if CommandLine.arguments.contains("--family-unshare-ui-fixture") {
                FamilyNotebookUnshareFixture()
            } else if CommandLine.arguments.contains("--app-records-ui-fixture") {
                AppRecordPersistenceFixtureView()
            } else if CommandLine.arguments.contains("--tool-backup-ui-fixture") {
                ToolBackupFixtureView()
            } else if BillingInternalDiagnosticsLaunch.isActive {
                BillingInternalDiagnosticsRootView()
            } else if CommandLine.arguments.contains("--managed-preservation-membership-ui-fixture") {
                ManagedPreservationMembershipFixture()
            } else if CommandLine.arguments.contains("--membership-offer-ui-fixture") {
                MembershipOfferFixture()
            } else if CommandLine.arguments.contains("--membership-access-ui-fixture") {
                MembershipAccessFixture()
            } else if CommandLine.arguments.contains("--personal-archive-ui-fixture") {
                LibraryRootUIFixture()
            } else if CommandLine.arguments.contains("--evacuation-ui-fixture") {
                EvacuationFixtureView()
            } else if CommandLine.arguments.contains("--care-handoff-ui-fixture") {
                CareHandoffFixtureView()
            } else if CommandLine.arguments.contains("--lost-cat-draft-ui-fixture") {
                LostCatDraftFixtureView()
            } else if CommandLine.arguments.contains("--widget-photo-opening-ui-fixture") {
                WidgetPhotoOpeningFixture()
            } else if CommandLine.arguments.contains("--official-window-ui-fixture") {
                OfficialWindowUIFixture()
            } else if CommandLine.arguments.contains("--window-list-ui-fixture") {
                WindowListNavigationFixture()
            } else if CommandLine.arguments.contains(AppStoreScreenshotFixture.launchArgument) {
                AppStoreScreenshotFixtureRootView()
            } else if CommandLine.arguments.contains("--cat-profile-photo-flow-fixture") {
                CatProfilePhotoFlowFixture()
            } else if CommandLine.arguments.contains("--photo-window-ui-fixture") {
                PhotoMemoryNoteFixture()
            } else if CommandLine.arguments.contains("--sharing-runtime-self-test") {
                SharingRuntimeSelfTestRootView()
            } else {
                AppRecordProductionRoot()
            }
#else
            AppRecordProductionRoot()
#endif
        }
    }


}

@MainActor
struct ProductionAppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = AppViewModel()
    @StateObject private var plusPurchases = PlusPurchaseStore.productionShared
    @State private var membershipNow = Date()

    var body: some View {
        AppRootView(viewModel: viewModel)
            .environment(\.membershipActions, plusPurchases.membershipActions)
            .environment(\.membershipAccess,
                MembershipAccessContext(entitlement: plusPurchases.entitlementState, now: membershipNow))
            .task(id: plusPurchases.entitlementState) {
                membershipNow = .now
                let access = MembershipAccessContext(entitlement: plusPurchases.entitlementState)
                try? PersonalWidgetMembershipStore.publish(access.personal)
                if let expiration = plusPurchases.entitlementState.lastServerConfirmed?.expirationDate,
                   expiration > .now {
                    do { try await Task.sleep(for: .seconds(expiration.timeIntervalSinceNow)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    membershipNow = .now
                    WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .membershipAccessRefreshRequested)) { _ in
                Task {
                    await plusPurchases.refreshAfterForegroundEntry()
                    membershipNow = .now
                }
            }
            .task {
                await plusPurchases.start()
            }
            // Usage counts (11/7): earlier days are sent on becoming active,
            // and the file is written only on going to the background.
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await UsageCounter.shared.appBecameActive(viewModel: viewModel,
                    plus: plusPurchases.entitlementState.permitsPersonalPlus)
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .background {
                    UsageCounter.shared.appEnteredBackground(viewModel: viewModel,
                        plus: plusPurchases.entitlementState.permitsPersonalPlus)
                }
                guard newPhase == .active else { return }
                Task {
                    await plusPurchases.refreshAfterForegroundEntry()
                    // Retry the bounded Widget snapshot even when the server
                    // returns the same entitlement after a prior disk error.
                    try? PersonalWidgetMembershipStore.publish(
                        MembershipAccessContext(entitlement: plusPurchases.entitlementState).personal)
                    membershipNow = .now
                }
            }
    }
}

#if DEBUG
/// Keeps deterministic sharing runtime fixtures isolated from production
/// launch and foreground tasks that intentionally purge disabled handoffs.
@MainActor
private struct SharingRuntimeSelfTestRootView: View {
    var body: some View {
        Color.clear
            .task {
                await SharingRuntimeSelfTestRunner.shared.runIfRequested()
            }
    }
}
#endif


/// Independent of navigation/sheet state; ordinary errors keep their current UI.
@MainActor
private final class ClientUpgradePresenter {
    static let shared = ClientUpgradePresenter()
    private var observers: [NSObjectProtocol] = []
    private var windows: [UIWindow] = []

    func start() {
        guard observers.isEmpty else { return }
        for name in [ClientUpgradeRequirement.notification, UIScene.didActivateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in self.presentIfRequired() }
            })
        }
    }

    private func presentIfRequired() {
        guard ClientUpgradeRequirement.shared.isRequired else { return }
        windows.removeAll { $0.windowScene?.activationState == .unattached }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            where scene.activationState == .foregroundActive {
            guard !windows.contains(where: { $0.windowScene === scene }) else { continue }
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.rootViewController = UIHostingController(rootView: ClientUpgradeRequiredView())
            window.makeKeyAndVisible()
            windows.append(window)
        }
    }
}

#if DEBUG
private struct ClientUpgradeResponseFixture: View {
    @State private var sheet = false
    var body: some View {
        Button("設定を開く") { sheet = true }
            .accessibilityIdentifier("upgrade-fixture-settings")
            .sheet(isPresented: $sheet) {
                VStack {
                    Text("通常のエラー")
                    Button("426 を受け取る") {
                        try? ClientUpgradeRequirement.shared.checkResponse(status: 426,
                            data: Data(#"{"error":{"code":"CLIENT_UPGRADE_REQUIRED"}}"#.utf8))
                    }.accessibilityIdentifier("upgrade-fixture-426")
                    Button("503 を受け取る") {
                        try? ClientUpgradeRequirement.shared.checkResponse(status: 503,
                            data: Data(#"{"error":{"code":"CLIENT_UPGRADE_REQUIRED"}}"#.utf8))
                    }.accessibilityIdentifier("upgrade-fixture-503")
                }
            }
    }
}
#endif
