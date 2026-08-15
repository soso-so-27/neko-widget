import SwiftUI
import WidgetKit

struct NekoWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: NekoWidgetEntry

    var body: some View {
        Group {
            if
                let cacheFilename = entry.cacheFilename,
                let image = WidgetCacheImageLoader.image(cacheFilename: cacheFilename)
            {
                GeometryReader { proxy in
                    ZStack {
                        Color(red: 0.12, green: 0.10, blue: 0.09)

                        // The app has already produced the cat-aware square.
                        // Aspect-fit prevents medium/large widget rectangles
                        // from applying a second crop that could hide the cat.
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .accessibilityLabel("うちの子の写真")
                }
            } else {
                emptyState
            }
        }
        .containerBackground(for: .widget) {
            Color(red: 0.12, green: 0.10, blue: 0.09)
        }
        .widgetURL(entry.photoURL)
    }

    private var emptyState: some View {
        VStack(spacing: family == .systemSmall ? 8 : 12) {
            Image(systemName: "pawprint.fill")
                .font(.system(size: family == .systemLarge ? 42 : 30, weight: .semibold))
                .foregroundStyle(.orange)

            Text("うちの子を見つけよう")
                .font(family == .systemSmall ? .headline : .title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)

            if family != .systemSmall {
                Text("アプリを開いて写真をスキャンしてください")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
