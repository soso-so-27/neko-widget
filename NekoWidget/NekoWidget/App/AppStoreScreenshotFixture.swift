#if DEBUG
import CoreGraphics
import Foundation
import SwiftUI
import UIKit

struct AppStoreScreenshotFixtureLoadedImage: Hashable {
    let localIdentifier: String
    let loaderIdentifier: UUID
}

@MainActor
final class AppStoreScreenshotFixtureLoadTracker: ObservableObject {
    @Published private(set) var loadedImages = Set<AppStoreScreenshotFixtureLoadedImage>()

    func record(localIdentifier: String, loaderIdentifier: UUID) {
        loadedImages.insert(AppStoreScreenshotFixtureLoadedImage(
            localIdentifier: localIdentifier,
            loaderIdentifier: loaderIdentifier
        ))
    }
}

/// A DEBUG-only presentation harness for App Store screenshot capture.
///
/// It reuses the shipping views and presentation models, but replaces PhotoKit
/// identifiers with deterministic vector illustrations generated in memory.
/// The harness owns no URLSession, Photos request, account, location, or
/// persisted user data. `#if DEBUG` keeps the launch route and fixture pixels
/// out of Release archives.
@MainActor
enum AppStoreScreenshotFixture {
    static let launchArgument = "--app-store-screenshot-fixture"
    static let identifierPrefix = "app-store-screenshot-fixture-"
    static let loadedAccessibilityIdentifierPrefix =
        "app-store-screenshot-fixture-photo-loaded-"
    static let loadTracker = AppStoreScreenshotFixtureLoadTracker()

    private static let identifiers = (1...18).map {
        "\(identifierPrefix)\($0)"
    }
    private static var imageCache: [String: UIImage] = [:]

    static func image(for localIdentifier: String) -> UIImage? {
        guard let index = identifiers.firstIndex(of: localIdentifier) else {
            return nil
        }
        if let cached = imageCache[localIdentifier] {
            return cached
        }
        let image = makeCatIllustration(variant: index)
        imageCache[localIdentifier] = image
        return image
    }

    static func isFixtureIdentifier(_ localIdentifier: String) -> Bool {
        identifiers.contains(localIdentifier)
    }

    static var photos: [PhotoPresentation] {
        let dates = [
            date(year: 2025, month: 12, day: 18),
            date(year: 2025, month: 8, day: 4),
            date(year: 2025, month: 2, day: 22),
            date(year: 2024, month: 10, day: 12),
            date(year: 2024, month: 5, day: 1),
            date(year: 2023, month: 11, day: 9),
            date(year: 2023, month: 3, day: 17),
            date(year: 2022, month: 7, day: 6),
        ]

        return identifiers.prefix(8).enumerated().map { index, identifier in
            PhotoPresentation(
                localIdentifier: identifier,
                creationDate: dates[index],
                catBoundingBox: CGRect(x: 0.18, y: 0.13, width: 0.64, height: 0.76),
                isLiked: index < 5,
                likedAt: index < 5
                    ? date(year: 2026, month: 8, day: 20 - index)
                    : nil,
                albumPostures: index == 1 ? [.sleeping] : [],
                albumContainsPerson: false,
                albumIsOuting: index == 4,
                detectedCatCount: index == 6 ? 2 : 1,
                largestCatAreaRatio: index == 0 ? 0.62 : 0.34,
                isGrowthEligible: true,
                hasCurrentAlbumAnalysis: true
            )
        }
    }

    /// Uses identifiers that never appear in the Memories tab. Keeping each
    /// capture screen's pixels disjoint lets UI tests prove that the active
    /// tab, rather than an off-screen tab retained by `TabView`, has rendered.
    static var likedPhotos: [PhotoPresentation] {
        Array(identifiers[8...16]).enumerated().map { index, identifier in
            PhotoPresentation(
                localIdentifier: identifier,
                creationDate: date(year: 2025, month: 9 - index, day: 14),
                catBoundingBox: CGRect(x: 0.18, y: 0.13, width: 0.64, height: 0.76),
                isLiked: true,
                likedAt: date(year: 2026, month: 8, day: 18 - index),
                albumPostures: [],
                albumContainsPerson: false,
                albumIsOuting: false,
                detectedCatCount: 1,
                largestCatAreaRatio: 0.34,
                isGrowthEligible: false,
                hasCurrentAlbumAnalysis: true
            )
        }
    }

    /// The Window screen also owns a dedicated identifier, so a loaded image
    /// left behind by that tab cannot satisfy the Memories or Likes wait gate.
    static var windowPhoto: PhotoPresentation {
        PhotoPresentation(
            localIdentifier: identifiers[17],
            creationDate: date(year: 2025, month: 12, day: 24),
            catBoundingBox: CGRect(x: 0.18, y: 0.13, width: 0.64, height: 0.76),
            isLiked: false,
            likedAt: nil,
            albumPostures: [],
            albumContainsPerson: false,
            albumIsOuting: false,
            detectedCatCount: 1,
            largestCatAreaRatio: 0.42,
            isGrowthEligible: false,
            hasCurrentAlbumAnalysis: true
        )
    }

    private static func date(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: 12
        ))!
    }

    /// Draws an original, code-defined cat illustration. It has no source
    /// image, EXIF, GPS, face, text, logo, or third-party asset lineage.
    private static func makeCatIllustration(variant: Int) -> UIImage {
        let canvas = CGSize(width: 1_200, height: 1_200)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1

        let palettes: [(UIColor, UIColor, UIColor, UIColor)] = [
            (#colorLiteral(red: 0.968, green: 0.827, blue: 0.643, alpha: 1), #colorLiteral(red: 0.454, green: 0.278, blue: 0.207, alpha: 1), #colorLiteral(red: 0.976, green: 0.941, blue: 0.846, alpha: 1), #colorLiteral(red: 0.255, green: 0.557, blue: 0.545, alpha: 1)),
            (#colorLiteral(red: 0.718, green: 0.827, blue: 0.902, alpha: 1), #colorLiteral(red: 0.247, green: 0.286, blue: 0.337, alpha: 1), #colorLiteral(red: 0.902, green: 0.898, blue: 0.851, alpha: 1), #colorLiteral(red: 0.816, green: 0.478, blue: 0.404, alpha: 1)),
            (#colorLiteral(red: 0.875, green: 0.741, blue: 0.827, alpha: 1), #colorLiteral(red: 0.510, green: 0.361, blue: 0.451, alpha: 1), #colorLiteral(red: 0.949, green: 0.890, blue: 0.800, alpha: 1), #colorLiteral(red: 0.376, green: 0.525, blue: 0.690, alpha: 1)),
            (#colorLiteral(red: 0.729, green: 0.851, blue: 0.753, alpha: 1), #colorLiteral(red: 0.369, green: 0.302, blue: 0.239, alpha: 1), #colorLiteral(red: 0.941, green: 0.855, blue: 0.659, alpha: 1), #colorLiteral(red: 0.659, green: 0.412, blue: 0.286, alpha: 1)),
        ]
        let palette = palettes[variant % palettes.count]

        return UIGraphicsImageRenderer(size: canvas, format: format).image { renderer in
            let context = renderer.cgContext
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: [palette.0.cgColor, palette.3.withAlphaComponent(0.72).cgColor] as CFArray,
                locations: [0, 1]
            )!
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 1_200, y: 1_200),
                options: []
            )

            UIColor.white.withAlphaComponent(0.28).setFill()
            UIBezierPath(ovalIn: CGRect(x: 95, y: 90, width: 310, height: 310)).fill()
            UIColor.white.withAlphaComponent(0.16).setFill()
            UIBezierPath(ovalIn: CGRect(x: 840, y: 170, width: 225, height: 225)).fill()

            palette.2.withAlphaComponent(0.88).setFill()
            UIBezierPath(
                roundedRect: CGRect(x: 90, y: 760, width: 1_020, height: 370),
                cornerRadius: 170
            ).fill()

            palette.1.setFill()
            UIBezierPath(ovalIn: CGRect(x: 285, y: 455, width: 630, height: 610)).fill()

            let leftEar = UIBezierPath()
            leftEar.move(to: CGPoint(x: 340, y: 500))
            leftEar.addLine(to: CGPoint(x: 385, y: 220))
            leftEar.addLine(to: CGPoint(x: 545, y: 455))
            leftEar.close()
            leftEar.fill()

            let rightEar = UIBezierPath()
            rightEar.move(to: CGPoint(x: 655, y: 455))
            rightEar.addLine(to: CGPoint(x: 815, y: 220))
            rightEar.addLine(to: CGPoint(x: 860, y: 500))
            rightEar.close()
            rightEar.fill()

            UIColor.systemPink.withAlphaComponent(0.42).setFill()
            let innerLeft = UIBezierPath()
            innerLeft.move(to: CGPoint(x: 385, y: 430))
            innerLeft.addLine(to: CGPoint(x: 410, y: 295))
            innerLeft.addLine(to: CGPoint(x: 490, y: 430))
            innerLeft.close()
            innerLeft.fill()
            let innerRight = UIBezierPath()
            innerRight.move(to: CGPoint(x: 710, y: 430))
            innerRight.addLine(to: CGPoint(x: 790, y: 295))
            innerRight.addLine(to: CGPoint(x: 815, y: 430))
            innerRight.close()
            innerRight.fill()

            palette.1.setFill()
            UIBezierPath(ovalIn: CGRect(x: 315, y: 365, width: 570, height: 520)).fill()

            palette.2.withAlphaComponent(0.90).setFill()
            UIBezierPath(ovalIn: CGRect(x: 430, y: 590, width: 340, height: 250)).fill()

            let eyeColor = UIColor(red: 0.89, green: 0.75, blue: 0.30, alpha: 1)
            eyeColor.setFill()
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
            let whiskerOffsets: [CGFloat] = [-42, 0, 42]
            for offset in whiskerOffsets {
                let leftWhisker = UIBezierPath()
                leftWhisker.move(to: CGPoint(x: 545, y: 715 + offset * 0.35))
                leftWhisker.addLine(to: CGPoint(x: 245, y: 700 + offset))
                leftWhisker.lineWidth = 7
                leftWhisker.stroke()

                let rightWhisker = UIBezierPath()
                rightWhisker.move(to: CGPoint(x: 655, y: 715 + offset * 0.35))
                rightWhisker.addLine(to: CGPoint(x: 955, y: 700 + offset))
                rightWhisker.lineWidth = 7
                rightWhisker.stroke()
            }

            palette.2.setFill()
            UIBezierPath(ovalIn: CGRect(x: 345, y: 875, width: 235, height: 185)).fill()
            UIBezierPath(ovalIn: CGRect(x: 620, y: 875, width: 235, height: 185)).fill()
        }
    }
}

@MainActor
struct AppStoreScreenshotFixtureRootView: View {
    @State private var selectedPhotoIdentifier: String?
    @State private var selectedPhotoShownAt: Date?
    @State private var showsFamilyWindow = false
    @ObservedObject private var loadTracker = AppStoreScreenshotFixture.loadTracker

    private let photos = AppStoreScreenshotFixture.photos
    private let likedPhotos = AppStoreScreenshotFixture.likedPhotos
    private let windowPhoto = AppStoreScreenshotFixture.windowPhoto

    var body: some View {
        MainTabView(
            currentPhoto: windowPhoto,
            likedPhotos: likedPhotos,
            catPhotos: photos,
            libraryPhotos: photos,
            scan: scan,
            albumState: .ready(photoCount: photos.count, updatedAt: nil),
            settings: SettingsPresentation(),
            detectionAccuracySample: DetectionAccuracySamplePresentation(),
            highResolutionRecoverySample: DetectionAccuracySamplePresentation(),
            excludedCatPhotos: [],
            photoSourceAlbums: [],
            photoSourceStatus: .allLibrary,
            catProfilesPresentation: CatProfilesPresentation(),
            profileAlbumPhotos: [:],
            catProfilesActions: .noOp,
            hasPhotoAccess: true,
            isLimitedAccess: false,
            isScanning: false,
            shouldOfferWidgetPlacementGuide: false,
            widgetIntervalMinutes: 60,
            privateWindowDisplayName: "ミケのまど",
            deepLinkedPhotoIdentifier: $selectedPhotoIdentifier,
            deepLinkedPhotoShownAt: $selectedPhotoShownAt,
            deepLinkedFamilyWindowIsPresented: $showsFamilyWindow,
            deepLinkedFamilyMomentSourceDigest: .constant(nil),
            pendingFamilyNotificationRoute: .constant(nil),
            chooseMorePhotos: {},
            requestPhotoAccess: {},
            showWidgetPlacementGuide: {},
            setMemorySaved: { _, _ in },
            exportPhotoBook: { _ in
                throw CocoaError(.fileWriteUnknown)
            },
            exportMemoryPhoto: { _ in
                throw CocoaError(.fileWriteUnknown)
            },
            albumOpened: { _, _ in },
            updateAlbum: {},
            rescan: {},
            savePhotoSettings: { _, _ in },
            saveDetectionSettings: { _, _ in },
            saveLifeReference: { _ in },
            excludeFromCatCandidates: { _ in },
            restoreCatCandidates: { _ in },
            selectPhotoSourceAlbum: { _ in },
            refreshPhotoSourceAlbums: {},
            exportJSON: { nil }
        )
        .accessibilityIdentifier("app-store-screenshot-fixture-root")
        // Image views sit inside NavigationLink labels, whose accessibility
        // element can absorb child identifiers. Publish DEBUG-only completion
        // markers outside those links so XCTest observes actual loader state.
        .overlay(alignment: .topLeading) {
            loadedAccessibilityMarkers
        }
    }

    private var loadedAccessibilityMarkers: some View {
        ZStack {
            ForEach(sortedLoadedImages, id: \.self) { loaded in
                Text("fixture image loaded")
                    .foregroundStyle(Color.clear)
                    .frame(width: 1, height: 1)
                    .clipped()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("fixture image loaded")
                    .accessibilityIdentifier(
                        AppStoreScreenshotFixture.loadedAccessibilityIdentifierPrefix
                            + loaded.localIdentifier
                    )
            }
        }
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
    }

    private var sortedLoadedImages: [AppStoreScreenshotFixtureLoadedImage] {
        loadTracker.loadedImages.sorted { lhs, rhs in
            if lhs.localIdentifier != rhs.localIdentifier {
                return lhs.localIdentifier < rhs.localIdentifier
            }
            return lhs.loaderIdentifier.uuidString < rhs.loaderIdentifier.uuidString
        }
    }

    private var scan: ScanPresentation {
        var value = ScanPresentation()
        value.scannedAssets = photos.count
        value.totalAssets = photos.count
        value.finalCatAssets = photos.count
        value.finalOldestDate = photos.compactMap(\.creationDate).min()
        value.lastScannedAt = AppStoreScreenshotFixture.photos
            .compactMap(\.creationDate)
            .max()
        return value
    }
}

#endif
