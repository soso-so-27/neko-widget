import SwiftUI
import WidgetKit
struct ProbeEntry: TimelineEntry { let date: Date; let result: String }
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> ProbeEntry { ProbeEntry(date: .now, result: "Synthetic group probe") }
    func getSnapshot(in context: Context, completion: @escaping (ProbeEntry) -> Void) {
        completion(ProbeEntry(date: .now, result: PrototypeCache.widgetRead()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ProbeEntry>) -> Void) {
        completion(Timeline(entries: [ProbeEntry(date: .now, result: PrototypeCache.widgetRead())], policy: .never))
    }
}
@main struct ProbeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "IsolatedGroupProbe", provider: Provider()) { entry in
            Text(entry.result).font(.caption).containerBackground(.blue.opacity(0.1), for: .widget)
        }
        .configurationDisplayName("Neko Group Probe")
        .description("Synthetic HPKE and MLS extension read")
        .supportedFamilies([.systemSmall])
    }
}
