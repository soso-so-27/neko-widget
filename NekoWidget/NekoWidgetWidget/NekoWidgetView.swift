import SwiftUI
import WidgetKit
#if DEBUG && APP_STORE_SCREENSHOT_WIDGET_FIXTURE
import Foundation
import ImageIO
import UIKit
#endif

#if APP_STORE_SCREENSHOT_WIDGET_FIXTURE && !DEBUG
#error("The App Store Widget screenshot fixture must never compile outside Debug.")
#endif
#if WIDGET_VISUAL_REVIEW_FIXTURE && (!DEBUG || !APP_STORE_SCREENSHOT_WIDGET_FIXTURE)
#error("Widget visual review requires Debug and the dedicated screenshot fixture.")
#endif
#if (WIDGET_VISUAL_REVIEW_LONG_CAPTION || WIDGET_VISUAL_REVIEW_NO_CAPTION || WIDGET_VISUAL_REVIEW_WHITE_BACKGROUND || WIDGET_VISUAL_REVIEW_LARGE_TEXT) && !WIDGET_VISUAL_REVIEW_FIXTURE
#error("Widget review scenarios require the dedicated visual review fixture.")
#endif
#if WIDGET_VISUAL_REVIEW_LONG_CAPTION && WIDGET_VISUAL_REVIEW_NO_CAPTION
#error("Choose one Widget caption review scenario per build.")
#endif
#if OFFICIAL_WINDOW_WIDGET_FIXTURE && (!DEBUG || !APP_STORE_SCREENSHOT_WIDGET_FIXTURE)
#error("Official Widget review requires Debug and the dedicated screenshot fixture.")
#endif
#if OFFICIAL_WINDOW_WIDGET_FIXTURE && WIDGET_VISUAL_REVIEW_FIXTURE
#error("Choose either the official or private-window Widget review fixture.")
#endif

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

                        // Every photo fills the Widget, including a legacy cache
                        // briefly retained while the app and extension update.
                        // Keep the source ratio and crop only the overflow.
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                            .frame(
                                width: proxy.size.width,
                                height: proxy.size.height
                            )
                            .clipped()
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(loadedPhotoAccessibilityLabel)
                    .overlay(alignment: .bottom) {
                        if let photo = entry.officialPhoto {
                            Text(photo.catName)
                                .font(.caption.weight(.medium))
                                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                                .lineLimit(1)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.top, 20)
                                .padding(.bottom, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        } else if WidgetPhotoSource.isFamilyWindowSourceID(entry.photoSourceIdentifier) {
                            familyPhotoFooter
                        } else {
                            photoActionButtons()
                                .padding(actionButtonInset)
                        }
                    }
                }
            } else {
                emptyState
            }
        }
        .containerBackground(for: .widget) {
            Color(red: 0.12, green: 0.10, blue: 0.09)
        }
#if WIDGET_VISUAL_REVIEW_LARGE_TEXT
        // Use the normal shipping text-size limits, with the environment at
        // its largest setting; this never changes ordinary or Release Widgets.
        .environment(\.dynamicTypeSize, .accessibility5)
#endif
        // A photo is always navigation, never an implicit memory action.
        // The photo opens its detail; only the separate heart sends a reaction.
        // Shared save stays in detail. Personal-library memory stays explicit.
        .widgetURL(entry.photoURL)
    }

    /// Used only inside the successfully decoded photo branch above. The
    /// optional text never gives an empty or personal-library Widget a caption.
    private var familyCaption: String? {
        guard WidgetPhotoSource.isFamilyWindowSourceID(entry.photoSourceIdentifier),
              let text = entry.familyCaption?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private var loadedPhotoAccessibilityLabel: String {
        if let photo = entry.officialPhoto { return "公式まど。\(photo.catName)の写真。タップして開く" }
        guard WidgetPhotoSource.isFamilyWindowSourceID(entry.photoSourceIdentifier)
        else { return "このiPhoneで見つけた猫写真" }
        let photo = "\(entry.windowDisplayName)に届いた写真"
        return familyCaption.map { "\(photo)。ひとこと。\($0)" } ?? photo
    }

    /// One quiet footer for shared photos. Its background covers the full
    /// width and fades into the image, without adding separate text panels.
    private var familyPhotoFooter: some View {
        HStack(alignment: .bottom, spacing: 6) {
            VStack(spacing: 4) {
                if let caption = familyCaption {
                    familyCaptionPreview(caption)
                }
                familySourceLabel
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            // Only the text is decorative. Hiding or disabling the entire
            // footer would also hide the heart from touch and VoiceOver.
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            familyHeartShortcut
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .background {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.60)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: familyCaption == nil ? 16 : 26)
                // Maintain contrast directly under both lines of text, even
                // on a white photo; only the area above the footer fades out.
                LinearGradient(
                    colors: [.black.opacity(0.60), .black.opacity(0.63)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .padding(.top, familyCaption == nil ? -16 : -26)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var familyHeartShortcut: some View {
        if let sourceDigest = entry.familySourceDigest,
           let localWindowID = WidgetPhotoSource.localWindowID(
               from: entry.photoSourceIdentifier
           ), entry.isBookmarkInteractionEnabled {
            familyHeartControl(
                sourceDigest: sourceDigest,
                localWindowID: localWindowID
            )
        } else {
            // Inactive or legacy sources retain photo navigation but must not
            // offer a reaction against an unvalidated target.
            unavailableHeartSlot
        }
    }

    @ViewBuilder
    private func familyHeartControl(
        sourceDigest: String,
        localWindowID: String
    ) -> some View {
        switch entry.familyHeartStatus {
        case .ready:
            Button(
                intent: SendFamilyWidgetHeartIntent(
                    sourceDigest: sourceDigest,
                    localWindowID: localWindowID
                )
            ) {
                heartMark(status: .ready)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("ハートを送る")
            .accessibilityHint("アプリを開いて送信します")
        case .pending:
            heartMark(status: .pending)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("ハートは送信待ちです")
                .accessibilityHint("アプリの同期で送ります")
        case .serverAccepted:
            heartMark(status: .serverAccepted)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("ハートを送りました")
                .accessibilityHint("相手が確認したことを示す表示ではありません")
        case .hidden:
            unavailableHeartSlot
        }
    }

    private var unavailableHeartSlot: some View {
        // Keep the text and action position stable when a heart expires.
        Color.clear
            .frame(width: 44, height: 44)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func heartMark(status: FamilyWidgetHeartStatus) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: status == .serverAccepted ? "heart.fill" : "heart")
                .invalidatableContent()

            if status == .pending {
                Image(systemName: "clock.fill")
                    .font(.system(size: 10, weight: .bold))
                    .padding(1.5)
                    .background(Color.black.opacity(0.82), in: Circle())
                    .offset(x: 2, y: 2)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .frame(width: 30, height: 30)
        .background(Color.black.opacity(0.64), in: Circle())
        .overlay {
            Circle()
                .stroke(Color.white.opacity(0.20), lineWidth: 0.5)
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }

    private func familyCaptionPreview(_ caption: String) -> some View {
        Text(verbatim: caption)
            .font(.caption)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(family == .systemLarge ? 2 : 1)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func photoActionButtons() -> some View {
        if let localIdentifier = entry.localIdentifier,
           entry.photoSourceIdentifier == WidgetPhotoSource.personalLibraryID,
           entry.isLikeInteractionEnabled {
            actionTray {
                if entry.isLiked {
                    memoryMark(isSelected: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("思い出に残した写真")
                    .accessibilityHint("解除はアプリの思い出画面から確認して行えます")
                } else {
                    Button(
                        intent: ToggleWidgetLikeIntent(
                            localIdentifier: localIdentifier,
                            fallbackIsLiked: false
                        )
                    ) {
                        memoryMark(isSelected: false, invalidatesContent: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("思い出に残す")
                    .accessibilityHint("アプリを開かず、自分の思い出一覧に追加します")
                }
            }
        }
    }

    private func actionTray<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: actionButtonSpacing) {
            Spacer(minLength: 0)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The private-memory control stays in exactly the same place before and
    /// after selection. Its visible label is intentionally omitted so the cat
    /// photo remains primary; VoiceOver continues to announce the full action.
    private func memoryMark(
        isSelected: Bool,
        invalidatesContent: Bool = false
    ) -> some View {
        Group {
            if invalidatesContent {
                Image(systemName: isSelected ? "bookmark.fill" : "bookmark")
                    .invalidatableContent()
            } else {
                Image(systemName: isSelected ? "bookmark.fill" : "bookmark")
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .frame(width: 30, height: 30)
        .background(Color.black.opacity(0.64), in: Circle())
        .overlay {
            Circle()
                .stroke(Color.white.opacity(0.20), lineWidth: 0.5)
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }

    private var familySourceLabel: some View {
        Text(entry.windowDisplayName)
            .font(.caption2)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(.white.opacity(0.92))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    private var actionButtonSpacing: CGFloat {
        family == .systemSmall ? 2 : 4
    }

    private var actionButtonInset: CGFloat {
        family == .systemSmall ? 8 : 10
    }

    private func maximumPixelSize(for variant: WidgetImageVariant) -> Int {
        variant.maximumPixelDimension
    }

    /// Missing permissions, an unfinished scan, sync latency, and an invalid
    /// cache all fail closed to the same empty entry. Keep this copy neutral
    /// instead of presenting an unverified diagnosis inside the Widget.
    private var emptyState: some View {
        ZStack {
            LinearGradient(
                colors: [
                    QuietWindowPalette.backgroundTop,
                    QuietWindowPalette.backgroundBottom,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    QuietWindowPalette.cream.opacity(0.09),
                    .clear,
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: family == .systemLarge ? 280 : 170
            )

            VStack(spacing: family == .systemSmall ? 9 : 12) {
                QuietWindowMark()
                    .frame(
                        width: emptyStateMarkSize,
                        height: emptyStateMarkSize
                    )

                Text(emptyStateTitle)
                    .font(
                        family == .systemSmall
                            ? .subheadline.weight(.semibold)
                            : .headline.weight(.semibold)
                    )
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(QuietWindowPalette.cream.opacity(0.96))

                Text(emptyStateSubtitle)
                    .font(family == .systemSmall ? .caption2 : .caption)
                    .foregroundStyle(QuietWindowPalette.cream.opacity(0.62))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(family == .systemSmall ? 14 : 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(emptyStateTitle)。\(emptyStateSubtitle)")
    }

    private var emptyStateTitle: String {
        if entry.photoSourceIdentifier == OfficialWindowCatalog.sourceID {
            if OfficialWindowConfiguration.feedURL == nil { return "公式まどを準備中" }
            return OfficialWindowStore.shared.snapshot().isSubscribed ? "いま届いている写真はありません" : "どこかの猫に会えるまど"
        }
        if effectiveEmptyStateReason == .sourceUnavailable {
            return "このまどは利用できません"
        }
        if effectiveEmptyStateReason == .needsApp {
            return "写真を表示できません"
        }
        if WidgetPhotoSource.isFamilyWindowSourceID(entry.photoSourceIdentifier) {
            // Waiting also follows the expiry of a previously displayed photo.
            return "写真を待っています"
        }
        return "写真を準備しています"
    }

    private var emptyStateSubtitle: String {
        if entry.photoSourceIdentifier == OfficialWindowCatalog.sourceID { return "タップして公式まどを開く" }
        if effectiveEmptyStateReason == .sourceUnavailable {
            return "ウィジェットを編集してください"
        }
        if effectiveEmptyStateReason == .needsApp {
            return "アプリを開いて更新"
        }
        if WidgetPhotoSource.isFamilyWindowSourceID(entry.photoSourceIdentifier) {
            return entry.windowDisplayName
        }
        return "タップしてアプリを開く"
    }

    private var effectiveEmptyStateReason: WidgetEmptyStateReason {
        if entry.emptyStateReason == .none, entry.cacheFilename != nil {
            // The provider validated a file but image decoding failed while
            // rendering. This is actionable and must not look like "not yet".
            return .needsApp
        }
        return entry.emptyStateReason
    }

    private var emptyStateMarkSize: CGFloat {
        if family == .systemLarge {
            return 58
        }
        if family == .systemMedium {
            return 46
        }
        return 38
    }
}

private enum QuietWindowPalette {
    static let backgroundTop = Color(red: 0.12, green: 0.10, blue: 0.09)
    static let backgroundBottom = Color(red: 0.075, green: 0.067, blue: 0.06)
    static let cream = Color(red: 0.95, green: 0.91, blue: 0.84)
}

/// A quiet, reduced version of the app icon's window. The warm neutral frame
/// keeps an empty Widget recognizable without turning it into a bright tile.
private struct QuietWindowMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(QuietWindowPalette.cream.opacity(0.025))

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(QuietWindowPalette.cream.opacity(0.68), lineWidth: 1.25)

            QuietWindowOpening()
                .fill(QuietWindowPalette.cream.opacity(0.08))
                .padding(6)

            QuietWindowOpening()
                .stroke(QuietWindowPalette.cream.opacity(0.32), lineWidth: 0.75)
                .padding(6)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// Mirrors the app icon's softly notched opening instead of using a generic
/// four-pane window or a primary-color app tile.
private struct QuietWindowOpening: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + (rect.width * x),
                y: rect.minY + (rect.height * y)
            )
        }

        var path = Path()
        path.move(to: point(0, 0.08))
        path.addCurve(
            to: point(0.20, 0.08),
            control1: point(0, 0.025),
            control2: point(0.12, 0)
        )
        path.addLine(to: point(0.80, 0.08))
        path.addCurve(
            to: point(1, 0.08),
            control1: point(0.88, 0),
            control2: point(1, 0.025)
        )
        path.addLine(to: point(1, 0.84))
        path.addCurve(
            to: point(0.84, 1),
            control1: point(1, 0.93),
            control2: point(0.93, 1)
        )
        path.addLine(to: point(0.16, 1))
        path.addCurve(
            to: point(0, 0.84),
            control1: point(0.07, 1),
            control2: point(0, 0.93)
        )
        path.closeSubpath()
        return path
    }
}

#if DEBUG && APP_STORE_SCREENSHOT_WIDGET_FIXTURE
/// A workflow-gated Widget Gallery preview. It is compiled only in Debug and
/// only when a screenshot run injects its dedicated compiler
/// condition. Ordinary Debug and every Release archive omit these pixels.
enum AppStoreWidgetPreviewFixture {
    static let cacheFilename = "app-store-widget-gallery-preview.fixture"

    static func image(maximumPixelSize: Int) -> UIImage? {
#if WIDGET_VISUAL_REVIEW_FIXTURE
#if WIDGET_VISUAL_REVIEW_WHITE_BACKGROUND
        // Uniform white is a worst-case text-contrast control, not a cat photo
        // or resolution evidence. Other scenarios retain the injected photos.
        let size = CGSize(width: 32, height: 32)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
#else
        // CI injects the three JPEGs built by production buildFamilyWindow from
        // one known portrait. This retains its Vision-guided crop and encoding.
        // Missing injection must show no photo, never a substitute illustration.
        let encoded: String
        switch maximumPixelSize {
        case WidgetImageVariant.small.maximumPixelDimension:
            encoded = "__W1_WIDGET_SMALL_CACHE_JPEG_BASE64__"
        case WidgetImageVariant.medium.maximumPixelDimension:
            encoded = "__W1_WIDGET_MEDIUM_CACHE_JPEG_BASE64__"
        case WidgetImageVariant.large.maximumPixelDimension:
            encoded = "__W1_WIDGET_LARGE_CACHE_JPEG_BASE64__"
        default:
            return nil
        }
        guard let data = Data(base64Encoded: encoded),
              data.starts(with: [0xff, 0xd8])
        else { return nil }
        return WidgetCacheImageLoader.decodedImage(
            data: data,
            maximumPixelSize: maximumPixelSize,
            fileHash: SharedLog.shortHash(cacheFilename)
        )
#endif
#else
        return image
#endif
    }

    static func entry(at date: Date, variant: WidgetImageVariant) -> NekoWidgetEntry {
#if OFFICIAL_WINDOW_WIDGET_FIXTURE
        // Exercise the shipping official-photo footer and hidden-action branch.
        // These existing illustration pixels bypass feed/cache I/O only in this
        // explicit Debug capture; they are not evidence of real-photo quality.
        let photo = OfficialCatPhoto(
            id: "widget-review-photo", catID: "widget-review-cat",
            catName: "確認用の猫", credit: "コードで描いた確認用イラスト",
            caption: nil, photographedOn: nil,
            publishedAt: date.addingTimeInterval(-60),
            expiresAt: date.addingTimeInterval(86400),
            imageFilename: String(repeating: "a", count: 64) + ".jpg",
            sha256: String(repeating: "a", count: 64), width: 1000, height: 1000
        )
        return NekoWidgetEntry(
            date: date, localIdentifier: nil, cacheFilename: cacheFilename,
            imageVariant: variant, photoSourceIdentifier: OfficialWindowCatalog.sourceID,
            familySourceDigest: nil, usesFamilySpecificImage: false,
            windowDisplayName: OfficialWindowCatalog.displayName,
            isLiked: false, isLikeInteractionEnabled: false,
            isBookmarked: false, isBookmarkInteractionEnabled: false,
            familyHeartStatus: .hidden, familyActionsRequireApp: false,
            emptyStateReason: .none, officialPhoto: photo
        )
#elseif WIDGET_VISUAL_REVIEW_FIXTURE
        // Fixed display-only identities; no catalog, room key, Photos or relay.
        // The Gallery capture never invokes these production action controls.
        return NekoWidgetEntry(
            date: date,
            localIdentifier: nil,
            cacheFilename: cacheFilename,
            imageVariant: variant,
            photoSourceIdentifier: WidgetPhotoSource.familyWindowIDPrefix
                + "00000000-0000-4000-8000-000000000001",
            familySourceDigest: String(repeating: "a", count: 64),
            usesFamilySpecificImage: true,
            windowDisplayName: "みんなのねこと毎日の写真のまど",
            isLiked: false,
            isLikeInteractionEnabled: false,
            isBookmarked: false,
            isBookmarkInteractionEnabled: true,
            familyHeartStatus: .ready,
            familyActionsRequireApp: false,
            emptyStateReason: .none,
            familyCaption: caption(for: variant)
        )
#else
        return NekoWidgetEntry(
            date: date,
            localIdentifier: nil,
            cacheFilename: cacheFilename,
            imageVariant: variant,
            photoSourceIdentifier: WidgetPhotoSource.personalLibraryID,
            familySourceDigest: nil,
            usesFamilySpecificImage: true,
            windowDisplayName: PrivateWindowDisplayName.fallback,
            isLiked: false,
            isLikeInteractionEnabled: false,
            isBookmarked: false,
            isBookmarkInteractionEnabled: false,
            familyHeartStatus: .hidden,
            familyActionsRequireApp: false,
            emptyStateReason: .none
        )
#endif
    }

#if WIDGET_VISUAL_REVIEW_FIXTURE
    /// Additional flags use the existing Widget-only fixture build setting:
    /// LONG_CAPTION or NO_CAPTION selects the same case for all three sizes;
    /// WHITE_BACKGROUND and LARGE_TEXT can be combined with either text case.
    private static func caption(for variant: WidgetImageVariant) -> String? {
#if WIDGET_VISUAL_REVIEW_NO_CAPTION
        return nil
#elseif WIDGET_VISUAL_REVIEW_LONG_CAPTION
        return longCaption
#else
        switch variant {
        case .small:
            return "おひるねのあと 🐾"
        case .medium:
            return "窓辺でのんびり。\nきょうもいっしょ 🐈"
        case .large:
            return longCaption
        }
#endif
    }

    private static var longCaption: String {
        // 100 Swift Characters, two line breaks, and emoji; the original text
        // remains available to VoiceOver even when the small preview truncates.
        String(repeating: "あたたかい窓辺でのんびり。", count: 6)
            + "\n今日もいっしょにいようね。\nおやすみ 🐾。"
    }
#endif

    /// Original code-defined pixels only: no Photos input, account, network,
    /// EXIF/GPS, face, text, logo, or third-party asset lineage.
    static let image: UIImage = {
        let artboard = CGSize(width: 1_200, height: 1_200)
        let canvas = CGSize(width: 1_000, height: 1_000)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let background = UIColor(red: 0.875, green: 0.741, blue: 0.827, alpha: 1)
        let fur = UIColor(red: 0.510, green: 0.361, blue: 0.451, alpha: 1)
        let cream = UIColor(red: 0.949, green: 0.890, blue: 0.800, alpha: 1)
        let accent = UIColor(red: 0.376, green: 0.525, blue: 0.690, alpha: 1)

        return UIGraphicsImageRenderer(size: canvas, format: format).image { renderer in
            let context = renderer.cgContext
            context.scaleBy(
                x: canvas.width / artboard.width,
                y: canvas.height / artboard.height
            )
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [background.cgColor, accent.withAlphaComponent(0.72).cgColor] as CFArray,
                locations: [0, 1]
            )!
            context.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: artboard.width, y: artboard.height),
                options: []
            )

            UIColor.white.withAlphaComponent(0.28).setFill()
            UIBezierPath(ovalIn: CGRect(x: 95, y: 90, width: 310, height: 310)).fill()
            UIColor.white.withAlphaComponent(0.16).setFill()
            UIBezierPath(ovalIn: CGRect(x: 840, y: 170, width: 225, height: 225)).fill()

            cream.withAlphaComponent(0.88).setFill()
            UIBezierPath(
                roundedRect: CGRect(x: 90, y: 760, width: 1_020, height: 370),
                cornerRadius: 170
            ).fill()
            fur.setFill()
            UIBezierPath(ovalIn: CGRect(x: 285, y: 455, width: 630, height: 610)).fill()

            for points in [
                [CGPoint(x: 340, y: 500), CGPoint(x: 385, y: 220), CGPoint(x: 545, y: 455)],
                [CGPoint(x: 655, y: 455), CGPoint(x: 815, y: 220), CGPoint(x: 860, y: 500)],
            ] {
                let ear = UIBezierPath()
                ear.move(to: points[0])
                ear.addLine(to: points[1])
                ear.addLine(to: points[2])
                ear.close()
                ear.fill()
            }

            UIColor.systemPink.withAlphaComponent(0.42).setFill()
            for points in [
                [CGPoint(x: 385, y: 430), CGPoint(x: 410, y: 295), CGPoint(x: 490, y: 430)],
                [CGPoint(x: 710, y: 430), CGPoint(x: 790, y: 295), CGPoint(x: 815, y: 430)],
            ] {
                let innerEar = UIBezierPath()
                innerEar.move(to: points[0])
                innerEar.addLine(to: points[1])
                innerEar.addLine(to: points[2])
                innerEar.close()
                innerEar.fill()
            }

            fur.setFill()
            UIBezierPath(ovalIn: CGRect(x: 315, y: 365, width: 570, height: 520)).fill()
            cream.withAlphaComponent(0.90).setFill()
            UIBezierPath(ovalIn: CGRect(x: 430, y: 590, width: 340, height: 250)).fill()

            UIColor(red: 0.89, green: 0.75, blue: 0.30, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 430, y: 535, width: 105, height: 82)).fill()
            UIBezierPath(ovalIn: CGRect(x: 665, y: 535, width: 105, height: 82)).fill()
            UIColor.black.withAlphaComponent(0.82).setFill()
            UIBezierPath(ovalIn: CGRect(x: 475, y: 545, width: 22, height: 62)).fill()
            UIBezierPath(ovalIn: CGRect(x: 710, y: 545, width: 22, height: 62)).fill()

            UIColor.systemPink.withAlphaComponent(0.78).setFill()
            let nose = UIBezierPath()
            nose.move(to: CGPoint(x: 570, y: 670))
            nose.addLine(to: CGPoint(x: 630, y: 670))
            nose.addLine(to: CGPoint(x: 600, y: 710))
            nose.close()
            nose.fill()

            UIColor.white.withAlphaComponent(0.80).setStroke()
            for offset in [CGFloat(-42), 0, 42] {
                let left = UIBezierPath()
                left.move(to: CGPoint(x: 545, y: 715 + offset * 0.35))
                left.addLine(to: CGPoint(x: 245, y: 700 + offset))
                left.lineWidth = 7
                left.stroke()

                let right = UIBezierPath()
                right.move(to: CGPoint(x: 655, y: 715 + offset * 0.35))
                right.addLine(to: CGPoint(x: 955, y: 700 + offset))
                right.lineWidth = 7
                right.stroke()
            }

            cream.setFill()
            UIBezierPath(ovalIn: CGRect(x: 345, y: 875, width: 235, height: 185)).fill()
            UIBezierPath(ovalIn: CGRect(x: 620, y: 875, width: 235, height: 185)).fill()
        }
    }()
}
#endif
