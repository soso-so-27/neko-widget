import SwiftUI
import WidgetKit

@main
@MainActor
struct NekoWidgetApp: App {
    @UIApplicationDelegateAdaptor(NekoWidgetAppDelegate.self)
    private var appDelegate

    init() {
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
#else
        let shouldRunLaunchCleanup = true
#endif
        // A share sheet cannot survive a process relaunch. Remove only export
        // files with this app's exact prefixes before any new export is made.
        if shouldRunLaunchCleanup {
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
            if BillingInternalDiagnosticsLaunch.isActive {
                BillingInternalDiagnosticsRootView()
            } else if CommandLine.arguments.contains("--managed-preservation-membership-ui-fixture") {
                ManagedPreservationMembershipFixture()
            } else if CommandLine.arguments.contains("--membership-offer-ui-fixture") {
                MembershipOfferFixture()
            } else if CommandLine.arguments.contains("--window-support-resume-ui-fixture") {
                WindowSupportResumePreviewView(initialScenario:
                    CommandLine.arguments.contains("--window-support-owner") ? .ownerApproval : .pending)
            } else if CommandLine.arguments.contains("--membership-access-ui-fixture") {
                MembershipAccessFixture()
            } else if CommandLine.arguments.contains("--personal-archive-ui-fixture") {
                PersonalArchiveUIFixture()
            } else if CommandLine.arguments.contains("--family-record-ui-fixture") {
                FamilyRecordUIFixture()
            } else if CommandLine.arguments.contains("--widget-photo-opening-ui-fixture") {
                WidgetPhotoOpeningFixture()
            } else if CommandLine.arguments.contains("--personal-rediscovery-ui-fixture") {
                PersonalRediscoveryHistoryFixture()
            } else if CommandLine.arguments.contains("--official-window-ui-fixture") {
                OfficialWindowUIFixture()
            } else if CommandLine.arguments.contains("--window-list-ui-fixture") {
                WindowListNavigationFixture()
            } else if CommandLine.arguments.contains(AppStoreScreenshotFixture.launchArgument) {
                AppStoreScreenshotFixtureRootView()
            } else if CommandLine.arguments.contains("--cat-profile-photo-flow-fixture") {
                CatProfilePhotoFlowFixture()
            } else if CommandLine.arguments.contains("--photo-delivery-progress-ui-fixture") {
                MomentPhotoDeliveryProgressFixture()
            } else if CommandLine.arguments.contains("--photo-window-ui-fixture") {
                PhotoWindowDeliveryFixture()
            } else if CommandLine.arguments.contains("--moment-composer-ui-fixture") {
                MomentDeliveryComposerFixture()
            } else if CommandLine.arguments.contains("--moment-history-ui-fixture") {
                MomentSentHistoryFixture()
            } else if CommandLine.arguments.contains("--moment-shared-album-ui-fixture") {
                MomentSharedAlbumFixture()
            } else if CommandLine.arguments.contains("--moment-received-ui-fixture") {
                MomentReceivedLayoutFixture()
            } else if CommandLine.arguments.contains("--sharing-runtime-self-test") {
                SharingRuntimeSelfTestRootView()
            } else {
                ProductionAppRootView()
            }
#else
            ProductionAppRootView()
#endif
        }
    }
}

@MainActor
private struct ProductionAppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = AppViewModel()
    @StateObject private var plusPurchases = PlusPurchaseStore()
    @State private var membershipNow = Date()

    var body: some View {
        AppRootView(viewModel: viewModel)
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
            .onChange(of: scenePhase) { _, newPhase in
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
