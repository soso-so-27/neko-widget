import AppIntents
import SwiftUI
import WidgetKit

@main
@MainActor
struct NekoWidgetApp: App {
    @UIApplicationDelegateAdaptor(NekoWidgetAppDelegate.self)
    private var appDelegate

    init() {
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
            if CommandLine.arguments.contains("--app-records-ui-fixture") {
                AppRecordPersistenceFixtureView()
            } else if CommandLine.arguments.contains("--tool-backup-ui-fixture") {
                ToolBackupFixtureView()
            } else if BillingInternalDiagnosticsLaunch.isActive {
                BillingInternalDiagnosticsRootView()
            } else if CommandLine.arguments.contains("--moderation-resolution-ui-fixture") {
                moderationResolutionFixture
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
            } else if CommandLine.arguments.contains("--evacuation-ui-fixture") {
                EvacuationFixtureView()
            } else if CommandLine.arguments.contains("--care-handoff-ui-fixture") {
                CareHandoffFixtureView()
            } else if CommandLine.arguments.contains("--lost-cat-draft-ui-fixture") {
                LostCatDraftFixtureView()
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
                AppRecordProductionRoot()
            }
#else
            AppRecordProductionRoot()
#endif
        }
    }

#if DEBUG
    @ViewBuilder
    private var moderationResolutionFixture: some View {
#if targetEnvironment(simulator)
        ModerationResolutionUIFixture()
#else
        Color.clear
#endif
    }
#endif
}

@MainActor
struct ProductionAppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = AppViewModel()
    /// Plus と14日体験を束ねた1つの権限（ADR-027、実装計画 1-4）。画面はこれだけを参照する。
    @StateObject private var membership = MembershipAuthority.productionShared

    var body: some View {
        AppRootView(viewModel: viewModel)
            .environment(\.membershipActions, membership.membershipActions)
            .environment(\.membershipAccess, membership.access)
            .environment(\.membershipTrial, membership.trialPresentation)
            .task(id: membership.access) {
                membership.publishWidgetSnapshot()
                guard let boundary = membership.nextBoundary, boundary > .now else { return }
                do { try await Task.sleep(for: .seconds(boundary.timeIntervalSinceNow)) }
                catch { return }
                guard !Task.isCancelled else { return }
                membership.refresh()
                WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
            }
            .onReceive(NotificationCenter.default.publisher(for: .membershipAccessRefreshRequested)) { _ in
                Task { await membership.refreshAfterForegroundEntry() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .membershipTrialDay14NoticeShown)) { _ in
                membership.markDay14NoticeShown()
            }
            .task {
                await membership.start()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task {
                    await membership.refreshAfterForegroundEntry()
                    // Retry the bounded Widget snapshot even when the server
                    // returns the same entitlement after a prior disk error.
                    membership.publishWidgetSnapshot()
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
