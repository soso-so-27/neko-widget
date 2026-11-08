import SwiftUI
import WidgetKit

/// Round 2: the iOS 17 way in to 「写真を見せる」. Control Center and Siri need
/// iOS 18, so a small Home Screen or Lock Screen widget opens the same screen.
/// It shows no photo and no cat's name: only an icon and a word. Nothing is
/// read from the app; a tap opens `ShowcaseWidgetRoute.url`.
struct ShowcaseWidget: Widget {
    static let kind = "jp.nekowidget.showcase.shortcut"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: ShowcaseWidgetProvider()) { _ in
            ShowcaseWidgetView()
        }
        .configurationDisplayName("写真を見せる")
        .description("自慢の9枚を開きます。")
        .supportedFamilies([.accessoryCircular, .systemSmall])
    }
}

struct ShowcaseWidgetEntry: TimelineEntry {
    let date: Date
}

/// One entry that never changes: there is nothing to refresh.
struct ShowcaseWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ShowcaseWidgetEntry {
        ShowcaseWidgetEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (ShowcaseWidgetEntry) -> Void) {
        completion(ShowcaseWidgetEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ShowcaseWidgetEntry>) -> Void) {
        completion(Timeline(entries: [ShowcaseWidgetEntry(date: Date())], policy: .never))
    }
}

struct ShowcaseWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(ShowcaseWidgetRoute.url)
            .containerBackground(for: .widget) {
                if family == .accessoryCircular {
                    Color.clear
                } else {
                    Color(red: 0.12, green: 0.10, blue: 0.09)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("写真を見せる")
    }

    @ViewBuilder
    private var content: some View {
        if family == .accessoryCircular {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Image(systemName: "square.grid.3x3.fill")
                        .font(.system(size: 17, weight: .semibold))
                    Text("見せる")
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .widgetAccentable()
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 30, weight: .semibold))
                Spacer(minLength: 8)
                Text("写真を見せる")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
