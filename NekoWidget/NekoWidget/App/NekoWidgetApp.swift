import SwiftUI

@main
@MainActor
struct NekoWidgetApp: App {
    @UIApplicationDelegateAdaptor(NekoWidgetAppDelegate.self)
    private var appDelegate

    init() {
        // A share sheet cannot survive a process relaunch. Remove only export
        // files with this app's exact prefixes before any new export is made.
        TemporaryExportFileLifecycle.removeManagedFiles()
        Task {
            // A seasonal movie share sheet also cannot survive relaunch. The
            // service validates the exact managed UUID directory before delete.
            try? await SeasonalMovieExportService.shared.cleanupStaleExports(
                olderThan: 0
            )
        }
#if DEBUG
        if ProcessInfo.processInfo.environment["NEKO_RESET_ONBOARDING_FOR_UI_TESTS"] == "1" {
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
            if CommandLine.arguments.contains(AppStoreScreenshotFixture.launchArgument) {
                AppStoreScreenshotFixtureRootView()
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
    @StateObject private var viewModel = AppViewModel()

    var body: some View {
        AppRootView(viewModel: viewModel)
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
