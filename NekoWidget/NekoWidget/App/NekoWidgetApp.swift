import SwiftUI

@main
@MainActor
struct NekoWidgetApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            AppRootView(viewModel: viewModel)
        }
    }
}
