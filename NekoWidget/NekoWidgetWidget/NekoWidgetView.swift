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
                    photoSourceIdentifier: entry.photoSourceIdentifier,
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
                    .accessibilityLabel(
                        entry.photoSourceIdentifier == WidgetPhotoSource.familyWindowID
                            ? "\(entry.windowDisplayName)から届いた写真"
                            : "このiPhoneで見つけた猫写真"
                    )
                }
            } else {
                emptyState
            }
        }
        .overlay(alignment: .bottomTrailing) {
            likeButton
        }
        .overlay(alignment: .topLeading) {
            familySourceLabel
        }
        .containerBackground(for: .widget) {
            Color(red: 0.12, green: 0.10, blue: 0.09)
        }
        .widgetURL(entry.photoURL)
    }

    @ViewBuilder
    private var likeButton: some View {
        if let localIdentifier = entry.localIdentifier,
           entry.photoSourceIdentifier == WidgetPhotoSource.personalLibraryID,
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

                    CatPawMark(isFilled: entry.isLiked)
                        .frame(width: pawIconSize, height: pawIconSize)
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

    @ViewBuilder
    private var familySourceLabel: some View {
        if entry.photoSourceIdentifier == WidgetPhotoSource.familyWindowID,
           entry.cacheFilename != nil {
            Text(entry.familyMomentIsFresh
                ? "いま届いた・\(entry.windowDisplayName)"
                : "\(entry.windowDisplayName)から届いた一枚")
                .font(.caption2.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.black.opacity(0.50), in: Capsule())
                .padding(family == .systemSmall ? 8 : 10)
                .accessibilityHidden(true)
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
            CatPawMark(isFilled: true)
                .frame(
                    width: family == .systemLarge ? 42 : 30,
                    height: family == .systemLarge ? 42 : 30
                )
                .foregroundStyle(.orange)

            Text(entry.photoSourceIdentifier == WidgetPhotoSource.familyWindowID
                ? "\(entry.windowDisplayName)にはまだ写真がありません"
                : "猫の写真を追加")
                .font(family == .systemSmall ? .headline : .title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)

            if family == .systemSmall {
                Text(entry.photoSourceIdentifier == WidgetPhotoSource.familyWindowID
                    ? "アプリで更新"
                    : "アプリでスキャン")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.72))
            } else {
                Text(entry.photoSourceIdentifier == WidgetPhotoSource.familyWindowID
                    ? "アプリで\(entry.windowDisplayName)を開いて更新してください"
                    : "アプリで写真へのアクセスを確認し、スキャンしてください")
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
