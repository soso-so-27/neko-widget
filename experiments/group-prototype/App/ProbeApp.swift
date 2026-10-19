import SwiftUI
import WidgetKit
@main struct ProbeApp: App {
    @State private var status = "PREPARING"
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 20) {
                Text(status).accessibilityIdentifier("protocol-status")
                Text(PrototypeCache.widgetResult).accessibilityIdentifier("widget-status")
            }
            .task {
                do { try PrototypeCache.prepare(); status = "PROTOCOLS_PASS"; WidgetCenter.shared.reloadAllTimelines() }
                catch { status = "PROTOCOLS_FAILED" }
            }
        }
    }
}
