import SwiftUI
import WidgetKit

struct NekoWidget: Widget {
    static let kind = "NekoWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind,
            intent: NekoWidgetConfigurationIntent.self,
            provider: NekoWidgetTimelineProvider()
        ) { entry in
            NekoWidgetView(entry: entry)
        }
        .configurationDisplayName("うちの子")
        .description("選ばれた猫の写真をホーム画面に表示します。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
