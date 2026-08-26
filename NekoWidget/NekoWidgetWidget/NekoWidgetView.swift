import SwiftUI
import WidgetKit
#if DEBUG && APP_STORE_SCREENSHOT_WIDGET_FIXTURE
import Foundation
import UIKit
#endif

#if APP_STORE_SCREENSHOT_WIDGET_FIXTURE && !DEBUG
#error("The App Store Widget screenshot fixture must never compile outside Debug.")
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
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        WidgetPhotoSource.isFamilyWindowSourceID(entry.photoSourceIdentifier)
                            ? "\(entry.windowDisplayName)に届いた写真"
                            : "このiPhoneで見つけた猫写真"
                    )
                }
            } else {
                emptyState
            }
        }
        .overlay(alignment: .bottomTrailing) {
            photoActionButtons
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
    private var photoActionButtons: some View {
        if WidgetPhotoSource.isFamilyWindowSourceID(entry.photoSourceIdentifier),
           let sourceDigest = entry.familySourceDigest,
           entry.isBookmarkInteractionEnabled {
            HStack(spacing: family == .systemSmall ? 6 : 8) {
                if let memoryActionURL = entry.memoryActionURL {
                    Link(destination: memoryActionURL) {
                        actionPill(
                            entry.isBookmarked ? "残した" : "残す",
                            systemImage: entry.isBookmarked
                                ? "checkmark.circle.fill"
                                : "photo.badge.plus",
                            isActive: entry.isBookmarked
                        )
                    }
                    .accessibilityLabel(
                        entry.isBookmarked ? "思い出に残した写真" : "アプリで思い出に残す"
                    )
                    .accessibilityHint("写真アプリへの取り込みを確認するため、アプリを開きます")
                }

                familyHeartControl(sourceDigest: sourceDigest)
            }
            .padding(actionButtonInset)
        } else if let localIdentifier = entry.localIdentifier,
                  entry.photoSourceIdentifier == WidgetPhotoSource.personalLibraryID,
                  entry.isLikeInteractionEnabled {
            Button(
                intent: ToggleWidgetLikeIntent(
                    localIdentifier: localIdentifier,
                    fallbackIsLiked: entry.isLiked
                )
            ) {
                actionPill(
                    entry.isLiked ? "残した" : "残す",
                    systemImage: entry.isLiked
                        ? "checkmark.circle.fill"
                        : "photo.badge.plus",
                    isActive: entry.isLiked,
                    invalidatesContent: true
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.isLiked ? "思い出から外す" : "思い出に残す")
            .accessibilityHint("アプリを開かず、自分の思い出一覧を更新します")
            .padding(actionButtonInset)
        }
    }

    @ViewBuilder
    private func familyHeartControl(sourceDigest: String) -> some View {
        switch entry.familyHeartStatus {
        case .ready:
            Button(intent: SendFamilyWidgetHeartIntent(sourceDigest: sourceDigest)) {
                actionPill(
                    "ハート",
                    systemImage: "heart",
                    isActive: false,
                    invalidatesContent: true
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("ハートを送信待ちに追加")
            .accessibilityHint("アプリの同期後、サーバー受付済みとして表示します")
        case .pending:
            actionPill(
                "送信待ち",
                systemImage: "clock.fill",
                isActive: false,
                invalidatesContent: true
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("ハートは送信待ちです")
        case .serverAccepted:
            actionPill(
                "受付済み",
                systemImage: "heart.fill",
                isActive: true,
                invalidatesContent: true
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("ハートはサーバー受付済みです")
        case .hidden:
            EmptyView()
        }
    }

    private func actionPill(
        _ title: String,
        systemImage: String,
        isActive: Bool,
        invalidatesContent: Bool = false
    ) -> some View {
        HStack(spacing: 4) {
            if invalidatesContent {
                Image(systemName: systemImage)
                    .invalidatableContent()
            } else {
                Image(systemName: systemImage)
            }
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.caption2.bold())
        .foregroundStyle(.white)
        .padding(.horizontal, family == .systemSmall ? 7 : 9)
        .frame(height: actionButtonSize)
        .background(
            isActive ? Color.accentColor.opacity(0.92) : Color.black.opacity(0.56),
            in: Capsule()
        )
        .contentShape(Capsule())
    }

    @ViewBuilder
    private var familySourceLabel: some View {
        if WidgetPhotoSource.isFamilyWindowSourceID(entry.photoSourceIdentifier),
           entry.cacheFilename != nil {
            Text(entry.familyMomentIsFresh
                ? "いま届いた・\(entry.windowDisplayName)"
                : "\(entry.windowDisplayName)に届いた一枚")
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

    private var actionButtonSize: CGFloat {
        switch family {
        case .systemSmall:
            return 38
        case .systemMedium:
            return 40
        default:
            return 42
        }
    }

    private var actionButtonInset: CGFloat {
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

            Text(WidgetPhotoSource.isFamilyWindowSourceID(entry.photoSourceIdentifier)
                ? "\(entry.windowDisplayName)にはまだ写真がありません"
                : "猫の写真を追加")
                .font(family == .systemSmall ? .headline : .title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)

            if family == .systemSmall {
                Text(WidgetPhotoSource.isFamilyWindowSourceID(entry.photoSourceIdentifier)
                    ? "アプリで更新"
                    : "アプリでスキャン")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.72))
            } else {
                Text(WidgetPhotoSource.isFamilyWindowSourceID(entry.photoSourceIdentifier)
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

#if DEBUG && APP_STORE_SCREENSHOT_WIDGET_FIXTURE
/// A workflow-gated Widget Gallery preview. It is compiled only in Debug and
/// only when the manual screenshot workflow injects its dedicated compiler
/// condition. Ordinary Debug and every Release archive omit these pixels.
enum AppStoreWidgetPreviewFixture {
    static let cacheFilename = "app-store-widget-gallery-preview.fixture"

    static func entry(at date: Date, variant: WidgetImageVariant) -> NekoWidgetEntry {
        NekoWidgetEntry(
            date: date,
            localIdentifier: nil,
            cacheFilename: cacheFilename,
            imageVariant: variant,
            photoSourceIdentifier: WidgetPhotoSource.personalLibraryID,
            familySourceDigest: nil,
            usesFamilySpecificImage: true,
            familyMomentIsFresh: false,
            windowDisplayName: PrivateWindowDisplayName.fallback,
            isLiked: false,
            isLikeInteractionEnabled: false,
            isBookmarked: false,
            isBookmarkInteractionEnabled: false,
            familyHeartStatus: .hidden
        )
    }

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
