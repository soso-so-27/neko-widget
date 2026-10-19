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
        .configurationDisplayName("ねこのまど")
        .description("猫写真をウィジェットに表示します。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
