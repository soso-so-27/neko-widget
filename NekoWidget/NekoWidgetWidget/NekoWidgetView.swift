import SwiftUI
import WidgetKit

struct NekoWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: NekoWidgetEntry

    var body: some View {
        Group {
            if
                let cacheFilename = entry.cacheFilename,
                let variant = entry.imageVariant,
                let image = WidgetCacheImageLoader.image(
                    cacheFilename: cacheFilename,
                    maximumPixelSize: maximumPixelSize(for: variant)
                )
            {
                GeometryReader { proxy in
                    ZStack {
                        Color(red: 0.12, green: 0.10, blue: 0.09)

                        if entry.usesFamilySpecificImage {
                            // The app precomposes the family canvas: normally a
                            // sharp cat-aware full-bleed crop, with blurred fit
                            // retained only for geometric fallback.
                            Image(uiImage: image)
                                .resizable()
                                .interpolation(.high)
                                .scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .clipped()
                        } else {
                            // During an app/extension update, an old manifest can
                            // still point at the legacy square. Avoid recropping it.
                            Image(uiImage: image)
                                .resizable()
                                .interpolation(.high)
                                .scaledToFit()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .accessibilityLabel("うちの子の写真")
                }
            } else {
                emptyState
            }
        }
        .overlay(alignment: .bottomTrailing) {
            likeButton
        }
        .containerBackground(for: .widget) {
            Color(red: 0.12, green: 0.10, blue: 0.09)
        }
        .widgetURL(entry.photoURL)
    }

    @ViewBuilder
    private var likeButton: some View {
        if let localIdentifier = entry.localIdentifier,
           entry.isLikeInteractionEnabled {
            Button(
                intent: ToggleWidgetLikeIntent(
                    localIdentifier: localIdentifier,
                    fallbackIsLiked: entry.isLiked
                )
            ) {
                ZStack {
                    Circle()
                        .fill(.black.opacity(0.48))

                    Image(systemName: entry.isLiked ? "pawprint.fill" : "pawprint")
                        .font(.system(size: pawIconSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .invalidatableContent()
                }
                .frame(width: pawButtonSize, height: pawButtonSize)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.isLiked ? "好きを解除" : "これ好き")
            .accessibilityHint("アプリを開かずに、この写真の好き状態を切り替えます")
            .padding(pawButtonInset)
        }
    }

    private var pawButtonSize: CGFloat {
        switch family {
        case .systemSmall:
            return 38
        case .systemMedium:
            return 40
        default:
            return 42
        }
    }

    private var pawIconSize: CGFloat {
        switch family {
        case .systemSmall:
            return 18
        default:
            return 20
        }
    }

    private var pawButtonInset: CGFloat {
        family == .systemSmall ? 8 : 10
    }

    private func maximumPixelSize(for variant: WidgetImageVariant) -> Int {
        variant.maximumPixelDimension
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
