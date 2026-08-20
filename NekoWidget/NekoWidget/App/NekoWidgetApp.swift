import SwiftUI

@main
@MainActor
struct NekoWidgetApp: App {
    @StateObject private var viewModel = AppViewModel()

    init() {
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
            AppRootView(viewModel: viewModel)
#if DEBUG
                .task {
                    await SharingRuntimeSelfTestRunner.shared.runIfRequested()
                }
#endif
        }
    }
}
