#if DEBUG
import CoreGraphics
import Foundation
import SwiftUI
import UIKit

/// An offline driver for the shipping received-photo control view. Completion
/// is explicit fixture input, not evidence of PhotoKit import or heart delivery.
@MainActor
final class ReceivedPhotoActionFixture: ObservableObject {
    enum Action: String { case save, remove, heart }
    struct Request {
        let action: Action
        let photoID: Int
        var description: String { "\(action.rawValue)|\(photoID)" }
    }

    @Published private(set) var savedIDs = Set<Int>()
    @Published private(set) var importedIDs = Set<Int>()
    @Published private(set) var hearts: [Int: MomentReceivedPhotoActions.HeartState] = [2: .retry, 3: .unavailable]
    @Published private(set) var pending: Request?
    @Published private(set) var lastRequest: Request?

    func request(_ action: Action, photoID: Int) {
        guard pending == nil else { return }
        let request = Request(action: action, photoID: photoID)
        lastRequest = request
        pending = request
    }

    func finishPresentation() {
        guard let pending else { return }
        switch pending.action {
        case .save:
            savedIDs.insert(pending.photoID)
            importedIDs.insert(pending.photoID)
        case .remove:
            savedIDs.remove(pending.photoID)
        case .heart:
            hearts[pending.photoID] = .sent
        }
        self.pending = nil
    }

    func cancelPresentation() { pending = nil }
}

struct AppStoreScreenshotFixtureLoadedImage: Hashable {
    let localIdentifier: String
    let loaderIdentifier: UUID
}

@MainActor
final class AppStoreScreenshotFixtureLoadTracker: ObservableObject {
    @Published private(set) var loadedImages = Set<AppStoreScreenshotFixtureLoadedImage>()

    func record(localIdentifier: String, loaderIdentifier: UUID) {
        let image = AppStoreScreenshotFixtureLoadedImage(
            localIdentifier: localIdentifier,
            loaderIdentifier: loaderIdentifier
        )
        // Reappearing lazy cells can report the same load again. A no-op must
        // not publish another change and rebuild the fixture's navigation root.
        guard !loadedImages.contains(image) else { return }
        loadedImages.insert(image)
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
        if let number = Int(localIdentifier.replacingOccurrences(
            of: "app-store-screenshot-fixture-page-", with: "")),
           localIdentifier.hasPrefix("app-store-screenshot-fixture-page-"),
           (1...6_000).contains(number) {
            // Many unique assets, eight shared image objects: the paging test
            // must not manufacture a large decoded-image memory footprint.
            return image(for: "\(identifierPrefix)\((number - 1) % 8 + 1)")
        }
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
        if localIdentifier.hasPrefix("app-store-screenshot-fixture-page-"),
           let number = Int(localIdentifier.dropFirst("app-store-screenshot-fixture-page-".count)),
           (1...6_000).contains(number) { return true }
        return identifiers.contains(localIdentifier)
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

    /// Favorites use identifiers outside the scoped Photos collection. This
    /// also exercises saved photos surviving a different album source.
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

    /// Widget detail owns a dedicated identifier, separate from both scoped
    /// photos and favorites.
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
    private static let archiveStore = PersonalArchiveStore(directory:
        FileManager.default.temporaryDirectory.appendingPathComponent("AppStoreArchiveFixture/\(UUID().uuidString)"),
        transport: PersonalArchiveFixtureTransport())
    var widgetPhotoIdentifier: String? = nil
    var widgetPhotoShownAt: Date? = nil
    @State private var selectedPhotoIdentifier: String?
    @State private var selectedPhotoShownAt: Date?
    @State private var showsFamilyWindow = false
    @ObservedObject private var loadTracker = AppStoreScreenshotFixture.loadTracker

    private var photos: [PhotoPresentation] {
        if widgetRecoveryCase == "rediscovery" {
            return AppStoreScreenshotFixture.photos.enumerated().map { index, photo in
                PhotoPresentation(localIdentifier: photo.localIdentifier,
                    creationDate: index == 1 ? AppStoreScreenshotFixture.photos[0].creationDate : photo.creationDate,
                    catBoundingBox: photo.catBoundingBox, isLiked: photo.isLiked, likedAt: photo.likedAt,
                    albumPostures: photo.albumPostures, albumContainsPerson: photo.albumContainsPerson,
                    albumIsOuting: photo.albumIsOuting, detectedCatCount: photo.detectedCatCount,
                    largestCatAreaRatio: index < 2 ? 0.62 : photo.largestCatAreaRatio,
                    isGrowthEligible: photo.isGrowthEligible, hasCurrentAlbumAnalysis: true)
            }
        }
        guard ProcessInfo.processInfo.environment["NEKO_UX_RECOVERY_CASE"] == "paging" else {
            return AppStoreScreenshotFixture.photos
        }
        return (1...50).map { number in
            PhotoPresentation(
                localIdentifier: "app-store-screenshot-fixture-page-\(number)",
                creationDate: Date(timeIntervalSince1970: 1_754_006_400 + Double(number) * 86_400)
            )
        }
    }
    private var widgetRecoveryCase: String? {
        ProcessInfo.processInfo.environment["NEKO_UX_RECOVERY_CASE"]
    }
    private var scopedPhotos: [PhotoPresentation] {
        if widgetRecoveryCase == "source-unavailable" { return [] }
        if widgetRecoveryCase == "excluded" || widgetRecoveryCase == "scoped" {
            return Array(photos.dropFirst())
        }
        return photos
    }
    private var sourceStatus: PhotoSourceAlbumStatus {
        switch widgetRecoveryCase {
        case "source-unavailable": return .unavailable
        case "scoped":
            return .selected(PhotoSourceAlbumOption(localIdentifier: "fixture-album",
                title: "確認用アルバム", accessibleAssetCount: scopedPhotos.count))
        default: return .allLibrary
        }
    }
    private var catProfiles: CatProfilesPresentation {
        guard ["cats", "rediscovery"].contains(widgetRecoveryCase ?? "") else { return CatProfilesPresentation() }
        let all = photos.map {
            CatProfilePhotoPresentation(localIdentifier: $0.localIdentifier,
                                        creationDate: $0.creationDate)
        }
        return CatProfilesPresentation(profiles: (0..<2).map { index in
            let identifier = "fixture-cat-\(index)"
            let selected = widgetRecoveryCase == "rediscovery"
                ? Array(all[(index * 2)..<(index * 2 + 2)]) : [all[index]]
            let confirmed = selected.map { source in
                var photo = source
                photo.assignedProfileIdentifiers = [identifier]
                return photo
            }
            let assigned = Set(confirmed.map(\.localIdentifier))
            return CatProfilePresentation(
                identifier: identifier, name: index == 0 ? "ミケ" : "ソラ",
                coverPhoto: confirmed[0], confirmedPhotos: confirmed,
                manualCandidatePhotos: all.filter { !assigned.contains($0.localIdentifier) }
            )
        })
    }
    private let likedPhotos = AppStoreScreenshotFixture.likedPhotos
    private let windowPhoto = AppStoreScreenshotFixture.windowPhoto

    var body: some View {
        if let widgetPhotoIdentifier {
            // Match AppRootView's direct destination call inside its own
            // NavigationStack. MainTabView.body must not supply environments.
            mainTabContent.widgetPhotoDestination(
                for: widgetPhotoIdentifier, shownAt: widgetPhotoShownAt
            )
        } else {
#if targetEnvironment(simulator)
            if let scenario = ProcessInfo.processInfo.environment["NEKO_MAINLINE_ACCEPTANCE_CASE"] {
                MainlineAcceptanceFixtureRootView(scenario: scenario)
            } else {
                productScreens
            }
#else
            productScreens
#endif
        }
    }

    private var mainTabContent: MainTabView {
        MainTabView(
            currentPhoto: windowPhoto,
            likedPhotos: likedPhotos,
            catPhotos: scopedPhotos,
            libraryPhotos: photos,
            photoPresentationVersion: LibraryPresentationVersion(
                photoContentRevision: 0,
                removedPhotoRevision: 0,
                snapshotAssetCount: photos.count,
                analysisFingerprint: "app-store-screenshot-fixture",
                curationMutationRevision: 0,
                identityMutationRevision: nil,
                sourceResolutionRevision: 0,
                canPresent: true
            ),
            scan: scan,
            albumState: .ready(photoCount: photos.count, updatedAt: nil),
            settings: SettingsPresentation(),
            detectionAccuracySample: DetectionAccuracySamplePresentation(),
            highResolutionRecoverySample: DetectionAccuracySamplePresentation(),
            excludedCatPhotos: widgetRecoveryCase == "excluded" ? [ExcludedCatPhotoPresentation(
                localIdentifier: photos[0].localIdentifier,
                creationDate: photos[0].creationDate, excludedAt: .distantPast
            )] : [],
            photoSourceAlbums: [],
            photoSourceStatus: sourceStatus,
            catProfilesPresentation: catProfiles,
            profileAlbumPhotos: Dictionary(uniqueKeysWithValues: catProfiles.profiles.map { profile in
                let assigned = Set(profile.confirmedPhotos.map(\.localIdentifier))
                return (profile.identifier, photos.filter { assigned.contains($0.localIdentifier) })
            }),
            catProfilesActions: .noOp,
            hasPhotoAccess: true,
            isLimitedAccess: false,
            isScanning: false,
            shouldOfferWidgetPlacementGuide: false,
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
            exportJSON: { nil },
            personalArchiveStore: Self.archiveStore
        )
    }

    private var productScreens: some View {
        mainTabContent
        .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--ux-large-text") ? .accessibility5 : .large)
        .accessibilityIdentifier("app-store-screenshot-fixture-root")
        .task {
            if ["excluded", "scoped", "available", "rediscovery"].contains(widgetRecoveryCase ?? "") {
                selectedPhotoIdentifier = photos[0].localIdentifier
                selectedPhotoShownAt = Date()
            }
        }
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

#if targetEnvironment(simulator)
/// Exercises shipping views with fixed inputs in the existing isolated CI
/// Simulator. It never starts AppViewModel, billing or sharing services.
@MainActor
private struct MainlineAcceptanceFixtureRootView: View {
    let scenario: String
    @State private var page: OnboardingPresentationPage
    @State private var finished = false
    @State private var action = ""
    @State private var movieStatus = "working"
    @ObservedObject private var loadTracker = AppStoreScreenshotFixture.loadTracker

    init(scenario: String) {
        self.scenario = scenario
        _page = State(initialValue: scenario == "skip" ? .photoPermission : .scanResult)
    }

    var body: some View {
        Group {
            if finished {
                Text("確認完了").accessibilityIdentifier("mainline-fixture-finished")
            } else if scenario == "family-settings" {
                NavigationStack { FamilyWindowView(initialPresentation: .settings) }
            } else if scenario == "solo-memories-rediscovery" {
                SoloRediscoveryFixtureView()
            } else if scenario == "monthly-save" || scenario == "monthly-save-unconfirmed" {
                MonthlySaveFixtureView(confirmsRequests: scenario == "monthly-save")
            } else if scenario.hasPrefix("solo-memories-") {
                SoloMemoriesFixtureView(scenario: scenario)
            } else if scenario == "monthly-empty" || scenario == "monthly-pending" {
                NavigationStack {
                    LikedPhotosView(
                        photos: [], hasPhotoAccess: true,
                        monthlyWindowCollection: scenario == "monthly-pending" ? nil
                            : MonthlyWindowCollectionPresentation(letters: [], unavailable: nil),
                        latestMonthlyWindowIsUnread: false, latestSeasonalMovieIsNew: false,
                        seasonalMovies: [], exportPhotoBook: { _ in throw CocoaError(.fileWriteUnknown) },
                        openPhotos: { finished = true }
                    )
                    .navigationDestination(for: MemoriesRoute.self) { route in
                        if case .favorites = route {
                            SavedMemoriesGalleryView(
                                photos: [], startsInExportMode: false,
                                exportPhotoBook: { _ in throw CocoaError(.fileWriteUnknown) }
                            )
                        }
                    }
                }
            } else if scenario == "movie" {
                Text(movieStatus).accessibilityIdentifier("mainline-movie-\(movieStatus)")
                    .task {
                        do {
                            _ = try await MainlineMovieAcceptance.run()
                            movieStatus = "ready"
                        } catch {
                            movieStatus = "failed"
                        }
                    }
            } else {
                OnboardingView(
                    page: $page,
                    authorizationStatus: scenario == "skip" ? .notDetermined
                        : (scenario == "limited-zero" ? .limited : .authorized),
                    isPhotoRequestReady: true, scan: scan, resultPhotos: photos,
                    scanErrorMessage: nil, isLimitedAccess: scenario == "limited-zero",
                    requestPhotoAccess: { action = "request" }, skipPhotoAccess: { finished = true },
                    openPhotoSettings: { action = "settings" },
                    chooseMorePhotos: { action = "choose" }, rescan: { action = "rescan" },
                    finishWithoutWidgetPhoto: { finished = true }, finish: { finished = true }
                )
            }
        }
        .overlay(alignment: .topLeading) {
            VStack {
                Text("loaded").accessibilityIdentifier("mainline-loaded-\(loadedCount)")
                Text("action").accessibilityIdentifier("mainline-action-\(action)")
            }
            .foregroundStyle(.clear).frame(width: 1, height: 1).clipped()
            .allowsHitTesting(false)
        }
    }

    private var photos: [PhotoPresentation] {
        switch scenario {
        case "one": return Array(AppStoreScreenshotFixture.photos.prefix(1))
        // Four inputs exercise the shipping three-thumbnail cap.
        case "three": return Array(AppStoreScreenshotFixture.photos.prefix(4))
        case "unavailable":
            return [PhotoPresentation(localIdentifier: "mainline-unavailable-photo", creationDate: nil,
                                      catBoundingBox: nil, isLiked: false)]
        default: return []
        }
    }

    private var scan: ScanPresentation {
        var result = ScanPresentation()
        result.finalCatAssets = photos.count
        result.totalAssets = photos.count
        result.scannedAssets = photos.count
        return result
    }

    private var loadedCount: Int {
        Set(loadTracker.loadedImages.map(\.localIdentifier)).count
    }
}

/// Keeps the shipping Albums root alive while its inputs change. Only
/// presentation values and existing in-memory illustrations are supplied;
/// Monthly, highlight and cat destinations use the shipping photo views.
/// Remaining destinations acknowledge navigation without opening services.
@MainActor
private final class SoloMemoriesFixturePersistence: ObservableObject {
    let defaults: UserDefaults
    let recommendations: AlbumHighlightRecommendationStore
    let memoryNotes: PhotoMemoryNoteStore
    let archive: PersonalArchiveStore

    init(scenario: String) {
        let suiteName = "neko.fixture.albums.\(scenario)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        self.defaults = defaults
        recommendations = AlbumHighlightRecommendationStore(
            defaults: defaults, timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoloMemoriesFixture/\(UUID().uuidString)")
        memoryNotes = PhotoMemoryNoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        archive = PersonalArchiveStore(directory: directory.appendingPathComponent("archive"),
                                       transport: PersonalArchiveFixtureTransport())
    }
}

@MainActor
private struct SoloMemoriesFixtureView: View {
    let scenario: String
    @StateObject private var persistence: SoloMemoriesFixturePersistence
    @State private var hasMonthlyLetter: Bool
    @State private var hasPhotoAccess: Bool
    @State private var showsOtherScreen = false
    @State private var otherScreenTitle = "別の画面"
    @State private var detailPath = NavigationPath()
    @State private var photosPath = NavigationPath()
    @State private var selectedFixtureTab = "albums"
    @State private var photoSection: PhotoLibrarySection = .all
    @State private var highlightMemoryRequest = "none"
    @State private var savedFixturePhotoIdentifiers: Set<String> = ["app-store-screenshot-fixture-9"]
    @State private var excludedFixturePhotoIdentifiers = Set<String>()
    @State private var clearedFirstCatAssignments = false
    @State private var preparedDeliveryIdentifier = "none"
    @State private var fixtureSendCount = 0
    @State private var didSeedMemo = false
    @ObservedObject private var loadTracker = AppStoreScreenshotFixture.loadTracker

    init(scenario: String) {
        self.scenario = scenario
        _persistence = StateObject(wrappedValue: SoloMemoriesFixturePersistence(scenario: scenario))
        _hasMonthlyLetter = State(initialValue: [
            "solo-memories-monthly", "solo-memories-denied",
        ].contains(scenario) || scenario.contains("-cats"))
        _hasPhotoAccess = State(initialValue: !scenario.hasSuffix("-denied"))
    }

    var body: some View {
        TabView(selection: $selectedFixtureTab) {
            fixtureNavigation(isAlbums: true)
                .tabItem {
                    Label("アルバム", systemImage: "rectangle.stack")
                        .accessibilityIdentifier("main-tab-albums")
                }
                .tag("albums")
            fixtureNavigation(isAlbums: false)
                .tabItem {
                    Label("写真", systemImage: "photo.on.rectangle")
                        .accessibilityIdentifier("main-tab-photos")
                }
                .tag("photos")
        }
        .dynamicTypeSize(scenario.hasSuffix("-large") ? .accessibility5 : .large)
        .overlay(alignment: .topLeading) { fixtureEvidence }
    }

    private func fixtureNavigation(isAlbums: Bool) -> some View {
        NavigationStack(path: isAlbums ? $detailPath : $photosPath) {
            Group {
                if isAlbums {
                    if scenario == "solo-memories-memo", !didSeedMemo { ProgressView() }
                    else { albumsView() }
                }
                else { photoLibrary }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("便りを追加") { hasMonthlyLetter = true }
                            .disabled(hasMonthlyLetter)
                            .accessibilityIdentifier("solo-memories-add-letter")
                        Button("写真アクセスを切り替える") { hasPhotoAccess.toggle() }
                            .accessibilityIdentifier("solo-memories-toggle-access")
                        if usesCatProfiles {
                            Button("ミケの割り当てを外す") { clearedFirstCatAssignments = true }
                                .accessibilityIdentifier("solo-memories-clear-first-cat")
                        }
                        Button("別の画面へ") {
                            otherScreenTitle = "別の画面"
                            showsOtherScreen = true
                        }
                        .accessibilityIdentifier("solo-memories-open-other")
                    } label: {
                        Label("確認操作", systemImage: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("solo-memories-fixture-actions")
                    .accessibilityValue(
                        "便り\(hasMonthlyLetter ? "あり" : "なし")、"
                            + "写真アクセス\(hasPhotoAccess ? "あり" : "なし")"
                    )
                }
            }
            .task {
                guard scenario == "solo-memories-memo", !didSeedMemo else { return }
                _ = try? await persistence.memoryNotes.save(text: "はじめてのおふろ",
                    for: "app-store-screenshot-fixture-9", expectedRevision: nil)
                didSeedMemo = true
            }
            .navigationDestination(isPresented: $showsOtherScreen) {
                VStack(spacing: 20) {
                    Text(otherScreenTitle)
                        .accessibilityIdentifier("solo-memories-other-screen")
                    Button("アルバムに戻る") { showsOtherScreen = false }
                        .accessibilityIdentifier("solo-memories-return")
                }
            }
            // Match the shipping NavigationStack's registered value type so
            // its real photo/letter/movie links remain enabled in this fixture.
            .navigationDestination(for: AlbumCatalogRoute.self) { route in
                switch route {
                case .months:
                    albumsView().periodArchive(showsMovies: false)
                case .movies:
                    albumsView().periodArchive(showsMovies: true)
                case .cats:
                    albumsView().catArchive
                case let .years(profileIdentifier):
                    if let profileIdentifier,
                       !fixtureProfiles.contains(where: { $0.identifier == profileIdentifier }) {
                        ContentUnavailableView("この猫のアルバムを開けません", systemImage: "cat")
                    } else {
                        albumsView(scope: profileIdentifier.map(CatProfileScopePresentation.profile) ?? .everyone).yearArchive
                    }
                }
            }
            .navigationDestination(for: MemoriesRoute.self) { route in
                switch route {
                case .favorites:
                    SavedMemoriesGalleryView(
                        photos: savedPhotos, startsInExportMode: false,
                        exportPhotoBook: { _ in throw CocoaError(.fileWriteUnknown) }
                    )
                case .reflectionsArchive:
                    albumsView(showsReflectionArchive: true)
                case .highlightsArchive:
                    albumsView(showsHighlightArchive: true)
                case let .catAlbums(identifier):
                    albumsView(scope: .profile(identifier))
                case let .catHighlightsArchive(identifier):
                    albumsView(scope: .profile(identifier), showsHighlightArchive: true)
                case let .catHighlight(identifier, highlight):
                    highlightBrowser(highlight, scope: .profile(identifier))
                case let .highlight(highlight):
                    highlightBrowser(highlight)
                case let .monthlyWindow(snapshot):
                    monthlyBrowser(snapshot)
                case let .memoryNote(identifier):
                    PhotoMemoryNoteDetailView(recordID: identifier, photos: fixturePhotos,
                        store: persistence.memoryNotes, archiveStore: persistence.archive)
                case .photo, .seasonalMovie, .memoryNotes, .memoryNotePhoto:
                    VStack(spacing: 20) {
                        Text("アルバムの詳細")
                            .accessibilityIdentifier("solo-memories-detail-destination")
                            .accessibilityValue(detailRouteKey(route))
                        Button("アルバムに戻る") {
                            popFixtureDetail(isAlbums: isAlbums)
                        }
                        .accessibilityIdentifier("solo-memories-detail-return")
                    }
                }
            }
            .navigationDestination(for: AlbumRoute.self) { route in
                if case let .catAlbum(identifier, albumID) = route {
                    catAlbumDestination(identifier, albumID: albumID)
                } else if case let .catPhoto(identifier, albumID, photoID) = route {
                    catPhotoDestination(identifier, albumID: albumID, photoID: photoID)
                } else {
                    VStack(spacing: 20) {
                        Text("アルバムの詳細")
                            .accessibilityIdentifier("solo-memories-detail-destination")
                            .accessibilityValue(albumRouteKey(route))
                        Button("アルバムに戻る") {
                            popFixtureDetail(isAlbums: isAlbums)
                        }
                        .accessibilityIdentifier("solo-memories-detail-return")
                    }
                }
            }
        }
    }

    private func popFixtureDetail(isAlbums: Bool) {
        if isAlbums {
            if !detailPath.isEmpty { detailPath.removeLast() }
        } else if !photosPath.isEmpty { photosPath.removeLast() }
    }

    private var fixtureEvidence: some View {
            VStack {
                Text("loaded")
                    .accessibilityIdentifier("solo-memories-loaded-\(loadedCount)")
                Text("loaded photos")
                    .accessibilityIdentifier("solo-memories-loaded-photos")
                    .accessibilityValue("|" + loadedPhotoIdentifiers.joined(separator: "|") + "|")
                Text(highlightMemoryRequest)
                    .accessibilityIdentifier("solo-memories-highlight-memory-request")
                Text("\(preparedDeliveryIdentifier)|\(fixtureSendCount)")
                    .accessibilityIdentifier("solo-memories-delivery-state")
            }
            .foregroundStyle(.clear).frame(width: 1, height: 1).clipped()
            .allowsHitTesting(false)
    }

    private var photoLibrary: some View {
        VStack(spacing: 0) {
            PhotoLibrarySectionPicker(selection: $photoSection)
            switch photoSection {
            case .all:
                HomeView(scan: albumScan, hasPhotoAccess: hasPhotoAccess, isLimitedAccess: false,
                    shouldOfferWidgetPlacementGuide: false, requestPhotoAccess: {}, chooseMorePhotos: {},
                    showWidgetPlacementGuide: {}, showSettings: {}, rescan: {},
                    catPhotos: fixturePhotos, isEmbedded: true)
            case .favorites:
                SavedMemoriesGalleryView(photos: savedPhotos, startsInExportMode: false,
                    isEmbedded: true, exportPhotoBook: { _ in throw CocoaError(.fileWriteUnknown) })
            case .notes:
                PhotoMemoryNotesListView(photos: fixturePhotos, store: persistence.memoryNotes,
                    archiveStore: persistence.archive, isEmbedded: true) { photoSection = .all }
            }
        }
        .navigationTitle("写真")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func albumsView(
        scope: CatProfileScopePresentation = .everyone,
        showsReflectionArchive: Bool = false,
        showsHighlightArchive: Bool = false
    ) -> LikedPhotosView {
        LikedPhotosView(
            photos: savedPhotos,
            hasPhotoAccess: hasPhotoAccess,
            monthlyWindowCollection: MonthlyWindowCollectionPresentation(
                letters: scope == .everyone ? monthlyLetters : [], unavailable: nil
            ),
            latestMonthlyWindowIsUnread: scope == .everyone && hasMonthlyLetter,
            latestSeasonalMovieIsNew: scope == .everyone && !seasonalMovies.isEmpty,
            seasonalMovies: scope == .everyone ? seasonalMovies : [],
            exportPhotoBook: { _ in throw CocoaError(.fileWriteUnknown) },
            openPhotos: {
                photoSection = .all
                selectedFixtureTab = "photos"
            },
            albumSections: albumSections(for: scope),
            albumScan: scenario == "solo-memories-seasonal-large" || usesHighlightPhotos ? albumScan : nil,
            albumProfiles: fixtureProfiles,
            albumScope: .constant(scope),
            showsReflectionArchive: showsReflectionArchive,
            showsHighlightArchive: showsHighlightArchive,
            referenceDate: referenceDate,
            isCatDetail: scope != .everyone,
            navigationTitleOverride: fixtureProfiles.first { $0.identifier == profileIdentifier(for: scope) }
                .map { "\($0.displayName)のアルバム" },
            recommendationStore: persistence.recommendations,
            featuredSnapshotDefaults: persistence.defaults,
            memoryNoteStore: persistence.memoryNotes
        )
    }

    @ViewBuilder
    private func highlightBrowser(_ highlight: AlbumHighlightPresentation,
                                  scope: CatProfileScopePresentation = .everyone) -> some View {
        let current = albumSections(for: scope).flatMap(\.albums)
            .first { $0.id == highlight.sourceAlbumID }?.photos ?? []
        let currentByID = Dictionary(current.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let resolved = hasPhotoAccess ? highlight.photos.compactMap { currentByID[$0.localIdentifier] } : []
        if let first = resolved.first {
            PhotoBrowserView(
                photos: resolved,
                libraryPhotos: scopedFixturePhotos(for: scope),
                initialPhoto: first,
                widgetShownAt: nil,
                showsWidgetTiming: false,
                setMemorySaved: recordMemory,
                excludedCatCandidateIdentifiers: excludedFixturePhotoIdentifiers,
                excludeFromCatCandidates: excludeFixturePhotos, restoreCatCandidates: { _ in },
                profiles: [], assignmentsByPhotoIdentifier: [:],
                replaceProfileAssignments: { _ in true }, deliveryActions: fixtureDeliveryActions
            )
            .overlay(alignment: .topLeading) {
                // Route metadata is a fixture assertion aid. Actual paging and
                // selected-photo identity are checked through browser actions.
                Text(highlight.id)
                    .accessibilityIdentifier("solo-memories-highlight-destination")
                    .accessibilityValue(resolved.map(\.localIdentifier).joined(separator: "|"))
                    .foregroundStyle(.clear).frame(width: 1, height: 1).clipped()
                    .allowsHitTesting(false)
            }
            .onAppear {
                persistence.recommendations.markOpened(highlight.id, scopeKey: scope.id, on: referenceDate)
            }
        } else {
            ContentUnavailableView("このピックアップを開けません", systemImage: "photo.stack")
        }
    }

    private func monthlyBrowser(_ snapshot: MonthlyWindowPresentation) -> some View {
        let refreshed = snapshot.refreshed(from: fixturePhotos, hasPhotoAccess: hasPhotoAccess,
            excludedIdentifiers: excludedFixturePhotoIdentifiers, timeZone: TimeZone(secondsFromGMT: 0)!)
        return MonthlyWindowView(
            presentation: refreshed, setMemorySaved: recordMemory,
            libraryPhotos: fixturePhotos,
            excludedCatCandidateIdentifiers: excludedFixturePhotoIdentifiers,
            excludeFromCatCandidates: excludeFixturePhotos,
            deliveryActions: fixtureDeliveryActions
        )
        .overlay(alignment: .topLeading) {
            Text(snapshot.periodIdentifier)
                .accessibilityIdentifier("solo-memories-monthly-destination")
                .accessibilityValue(refreshed.storyPhotos.map(\.localIdentifier).joined(separator: "|"))
                .foregroundStyle(.clear).frame(width: 1, height: 1).clipped().allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func catAlbumDestination(_ identifier: String, albumID: CuratedAlbumID) -> some View {
        if let album = albumSections(for: .profile(identifier)).flatMap(\.albums).first(where: { $0.id == albumID }) {
            CuratedAlbumDetailView(album: album, albumOpened: { _, _ in },
                excludeFromCatCandidates: excludeFixturePhotos,
                profiles: [], assignmentsByPhotoIdentifier: [:], replaceProfileAssignments: { _ in true },
                profileIdentifier: identifier)
        } else {
            ContentUnavailableView("この猫の写真はまだありません", systemImage: "cat")
        }
    }

    @ViewBuilder
    private func catPhotoDestination(_ identifier: String, albumID: CuratedAlbumID, photoID: String) -> some View {
        let photos = albumSections(for: .profile(identifier)).flatMap(\.albums).first { $0.id == albumID }?.photos ?? []
        if let first = photos.first(where: { $0.localIdentifier == photoID }) {
            PhotoBrowserView(photos: photos, libraryPhotos: scopedFixturePhotos(for: .profile(identifier)),
                initialPhoto: first, widgetShownAt: nil, showsWidgetTiming: false,
                setMemorySaved: recordMemory, excludedCatCandidateIdentifiers: excludedFixturePhotoIdentifiers,
                excludeFromCatCandidates: excludeFixturePhotos, restoreCatCandidates: { _ in },
                profiles: [], assignmentsByPhotoIdentifier: [:], replaceProfileAssignments: { _ in true },
                deliveryActions: fixtureDeliveryActions)
        } else {
            ContentUnavailableView("この猫の写真を開けません", systemImage: "cat")
        }
    }

    private func recordMemory(_ identifier: String, _ isSaved: Bool) {
        highlightMemoryRequest = "\(identifier)|\(isSaved)"
        if isSaved { savedFixturePhotoIdentifiers.insert(identifier) }
        else { savedFixturePhotoIdentifiers.remove(identifier) }
    }

    private func excludeFixturePhotos(_ identifiers: [String]) {
        excludedFixturePhotoIdentifiers.formUnion(identifiers)
    }

    private var fixtureDeliveryActions: PhotoWindowDeliveryActions {
        PhotoWindowDeliveryActions(
            destinations: { [MomentDeliveryDestination(localWindowID: "fixture-family",
                bindingSHA256: Data(repeating: 1, count: 32), displayName: "家族のまど")] },
            prepare: { photo in
                guard let image = AppStoreScreenshotFixture.image(for: photo.localIdentifier) else {
                    throw MemoryPhotoJPEGExportError.photoUnavailable
                }
                preparedDeliveryIdentifier = photo.localIdentifier
                let preview = try MomentCanonicalPreviewBuilder.build(image: image)
                return MomentShareIngressPhoto(canonicalJPEG: preview.jpeg,
                    capturedAt: photo.creationDate, pixelWidth: preview.pixelWidth, pixelHeight: preview.pixelHeight)
            },
            send: { _, _, _ in
                fixtureSendCount += 1
                return nil
            }
        )
    }

    private var usesCatProfiles: Bool { scenario.contains("-cats") }

    private func profileIdentifier(for scope: CatProfileScopePresentation) -> String? {
        guard case let .profile(identifier) = scope else { return nil }
        return identifier
    }

    private var fixtureProfiles: [CatProfilePresentation] {
        guard usesCatProfiles else { return [] }
        return (0..<2).map { index in
            let identifier = "fixture-cat-\(index)"
            let photos = scopedFixturePhotos(for: .profile(identifier)).map {
                CatProfilePhotoPresentation(localIdentifier: $0.localIdentifier, creationDate: $0.creationDate,
                                            assignedProfileIdentifiers: [identifier])
            }
            return CatProfilePresentation(identifier: identifier, name: index == 0 ? "ミケ" : "ソラ",
                coverPhoto: photos.first, confirmedPhotos: photos)
        }
    }

    private func scopedFixturePhotos(for scope: CatProfileScopePresentation) -> [PhotoPresentation] {
        guard hasPhotoAccess else { return [] }
        guard case let .profile(identifier) = scope else { return fixturePhotos }
        guard usesCatProfiles, ["fixture-cat-0", "fixture-cat-1"].contains(identifier) else { return [] }
        if identifier == "fixture-cat-0", clearedFirstCatAssignments { return [] }
        return fixturePhotos.filter { photo in
            let number = Int(photo.localIdentifier.replacingOccurrences(of: AppStoreScreenshotFixture.identifierPrefix, with: "")) ?? 0
            let belongsToFirst = (1...6).contains(number) || (16...18).contains(number)
            return identifier == "fixture-cat-0" ? belongsToFirst : !belongsToFirst
        }
    }

    private var fixturePhotos: [PhotoPresentation] {
        guard hasPhotoAccess else { return [] }
        let photos = usesHighlightPhotos ? highlightPhotos : AppStoreScreenshotFixture.photos.enumerated().map { index, photo in
            let date: Date?
            if index < 5 {
                date = Date(timeIntervalSince1970: 1_754_179_200 + Double(index) * 4 * 86_400)
            } else if index == 5 {
                date = Date(timeIntervalSince1970: 1_752_580_800) // 2025-07-15 12:00 UTC
            } else { date = photo.creationDate }
            return PhotoPresentation(localIdentifier: photo.localIdentifier, creationDate: date,
                catBoundingBox: photo.catBoundingBox, isLiked: savedFixturePhotoIdentifiers.contains(photo.localIdentifier),
                albumPostures: photo.albumPostures, albumContainsPerson: photo.albumContainsPerson,
                albumIsOuting: photo.albumIsOuting, detectedCatCount: photo.detectedCatCount,
                largestCatAreaRatio: photo.largestCatAreaRatio, hasCurrentAlbumAnalysis: true)
        }
        return photos.filter { !excludedFixturePhotoIdentifiers.contains($0.localIdentifier) }
    }

    private var usesHighlightPhotos: Bool {
        scenario.hasPrefix("solo-memories-highlights")
    }

    private var referenceDate: Date {
        // The same week and completed month in every simulator locale/run.
        Date(timeIntervalSince1970: 1_757_937_600) // 2025-09-15 12:00 UTC
    }

    private var highlightPhotos: [PhotoPresentation] {
        let photos = (0..<18).map { index in
            let theme = index / 3
            let position = index % 3
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let date = calendar.date(from: DateComponents(
                year: 2025, month: theme == 4 ? 2 : (theme == 5 ? 7 : 8),
                day: theme == 4 ? 22 : 3 + position * 7,
                hour: theme == 4 ? 3 + position * 5 : 12
            ))!
            return PhotoPresentation(
                localIdentifier: "app-store-screenshot-fixture-\(index + 1)",
                creationDate: date,
                catBoundingBox: CGRect(x: 0.18, y: 0.13, width: 0.64, height: 0.76),
                isLiked: savedFixturePhotoIdentifiers.contains("app-store-screenshot-fixture-\(index + 1)"),
                albumContainsPerson: theme == 1,
                albumIsOuting: theme == 3,
                detectedCatCount: theme == 2 ? 2 : 1,
                largestCatAreaRatio: theme == 0 || theme == 5 ? 0.62 : 0.34,
                hasCurrentAlbumAnalysis: true
            )
        }
        return scenario.hasSuffix("-few") ? Array(photos.prefix(2)) : photos
    }

    private func albumSections(for scope: CatProfileScopePresentation) -> [CuratedAlbumSectionPresentation] {
        if usesHighlightPhotos || scenario == "solo-memories-memo" {
            return CuratedAlbumBuilder(timeZone: TimeZone(secondsFromGMT: 0)!)
                .sections(from: scopedFixturePhotos(for: scope), lifeReference: nil, includesGrowth: false)
        }
        guard scenario == "solo-memories-seasonal-large" else { return [] }
        let photos = fixturePhotos
        var sections: [CuratedAlbumSectionPresentation] = []
        let curatedAlbums = CuratedAlbumBuilder()
            .sections(from: photos, lifeReference: nil, includesGrowth: false)
            .flatMap(\.albums)
        var timeAlbums = curatedAlbums.filter {
            $0.id == .calendarYear(2024) || $0.id == .calendarYear(2025)
        }
        if let growth = HouseholdGrowthAlbumBuilder().album(from: photos) {
            timeAlbums.insert(growth, at: 0)
        }
        if !timeAlbums.isEmpty {
            sections.append(CuratedAlbumSectionPresentation(id: .time, albums: timeAlbums))
        }
        let themes = curatedAlbums.filter { $0.id == .closeUp }
        if !themes.isEmpty {
            sections.append(CuratedAlbumSectionPresentation(id: .cuteness, albums: themes))
        }
        return sections
    }

    private var albumScan: ScanPresentation {
        var scan = ScanPresentation()
        scan.totalAssets = usesHighlightPhotos ? highlightPhotos.count : AppStoreScreenshotFixture.photos.count
        scan.scannedAssets = scan.totalAssets
        scan.finalCatAssets = scan.totalAssets
        return scan
    }

    private var loadedPhotoIdentifiers: [String] {
        Set(loadTracker.loadedImages.map(\.localIdentifier)).sorted()
    }

    private var savedPhotos: [PhotoPresentation] {
        guard hasPhotoAccess,
              scenario != "solo-memories-empty" else { return [] }
        let currentSaved = fixturePhotos.filter { savedFixturePhotoIdentifiers.contains($0.localIdentifier) }
        let currentIDs = Set(currentSaved.map(\.localIdentifier))
        return AppStoreScreenshotFixture.likedPhotos.prefix(1).filter {
            savedFixturePhotoIdentifiers.contains($0.localIdentifier) && !currentIDs.contains($0.localIdentifier)
        }
            + currentSaved
    }

    private var monthlyLetter: MonthlyWindowPresentation {
        MonthlyWindowPresentation(
            monthStart: Date(timeIntervalSince1970: 1_754_006_400),
            yearNumber: 2025, monthNumber: 8,
            photos: Array(fixturePhotos.prefix(5)),
            availableSceneCount: 5
        )
    }

    private var monthlyLetters: [MonthlyWindowPresentation] {
        guard hasMonthlyLetter, hasPhotoAccess else { return [] }
        guard scenario == "solo-memories-monthly" else { return [monthlyLetter] }
        let previous = MonthlyWindowPresentation(
            monthStart: Date(timeIntervalSince1970: 1_751_328_000),
            yearNumber: 2025, monthNumber: 7,
            // Exercise an archived cover with only one available photograph.
            photos: fixturePhotos.filter { $0.localIdentifier == "app-store-screenshot-fixture-6" },
            availableSceneCount: 1
        )
        return [monthlyLetter, previous]
    }

    private var seasonalMovies: [SeasonalMovieArchiveRecord] {
        guard hasPhotoAccess, scenario == "solo-memories-seasonal-large" || usesCatProfiles else { return [] }
        let start = Date(timeIntervalSince1970: 1_751_328_000)
        let end = Date(timeIntervalSince1970: 1_759_276_800)
        let scenes = AppStoreScreenshotFixture.photos.prefix(3).enumerated().map { index, photo in
            SeasonalMovieCandidate(
                localIdentifier: photo.localIdentifier,
                creationDate: start.addingTimeInterval(Double(index) * 31 * 86_400),
                mediaKind: .stillPhoto, catBoundingBox: photo.catBoundingBox,
                largestCatAreaRatio: photo.largestCatAreaRatio,
                isMemory: photo.isLiked, suggestedStartTime: nil, suggestedDuration: nil
            )
        }
        let presentation = SeasonalMoviePresentation(
            quarterStart: start, quarterEnd: end,
            startYearNumber: 2025, startMonthNumber: 7,
            endYearNumber: 2025, endMonthNumber: 9, scenes: scenes
        )
        return [SeasonalMovieArchiveRecord(
            version: SeasonalMovieArchiveRecord.schemaVersion,
            periodID: SeasonalMoviePeriodID(presentation: presentation),
            createdAt: end, updatedAt: end, presentation: presentation,
            excludedSceneIdentifiers: [], frozenAt: nil, freezeReason: nil
        )]
    }

    private var loadedCount: Int {
        Set(loadTracker.loadedImages.map(\.localIdentifier)).count
    }

    private func detailRouteKey(_ route: MemoriesRoute) -> String {
        switch route {
        case .favorites: "favorites"
        case .memoryNotes: "memory-notes"
        case let .memoryNote(id): "memory-note:\(id)"
        case let .memoryNotePhoto(id): "memory-note-photo:\(id)"
        case .reflectionsArchive: "reflections-archive"
        case .highlightsArchive: "highlights-archive"
        case let .catAlbums(identifier): "cat-albums:\(identifier)"
        case let .catHighlightsArchive(identifier): "cat-highlights-archive:\(identifier)"
        case let .catHighlight(identifier, highlight): "cat-highlight:\(identifier):\(highlight.id)"
        case let .highlight(highlight): "highlight:\(highlight.id)"
        case let .photo(identifier): "photo:\(identifier)"
        case let .monthlyWindow(presentation): "monthly:\(presentation.periodIdentifier)"
        case let .seasonalMovie(period): "seasonal:\(period.id)"
        }
    }

    private func albumRouteKey(_ route: AlbumRoute) -> String {
        switch route {
        case let .album(identifier): "album:\(identifier.logKey)"
        case let .photo(album, identifier): "album-photo:\(album.logKey):\(identifier)"
        case let .catAlbum(profile, album): "cat-album:\(profile):\(album.logKey)"
        case let .catPhoto(profile, album, identifier): "cat-album-photo:\(profile):\(album.logKey):\(identifier)"
        }
    }
}

/// The real single-photo browser opens the real same-day grid. This fixture
/// records which save callback is requested and republishes presentation state
/// only; it never calls the memory store or writes a Photos asset.
@MainActor
private struct MonthlySaveFixtureView: View {
    let confirmsRequests: Bool
    @State private var isSaved = false
    @State private var lastRequest = ""

    var body: some View {
        NavigationStack {
            MonthlyWindowView(
                presentation: MonthlyWindowPresentation(
                    monthStart: Date(timeIntervalSince1970: 1_754_006_400),
                    yearNumber: 2025, monthNumber: 8,
                    photos: [PhotoPresentation(
                        localIdentifier: "app-store-screenshot-fixture-1",
                        creationDate: Date(timeIntervalSince1970: 1_754_006_400),
                        isLiked: isSaved
                    )], availableSceneCount: 1
                ), setMemorySaved: { identifier, value in
                    lastRequest = "\(identifier)|\(value)"
                    if confirmsRequests { isSaved = value }
                }
            )
        }
        .overlay(alignment: .topLeading) {
            Text(lastRequest).accessibilityIdentifier("monthly-fixture-memory-request")
                .foregroundStyle(.clear).frame(width: 1, height: 1).clipped()
                .allowsHitTesting(false)
        }
    }
}

@MainActor
private struct SoloRediscoveryFixtureView: View {
    @State private var savedIdentifiers = Set<String>()
    @State private var memoryRequest = "none"

    var body: some View {
        let dayPhotos = photos
        NavigationStack {
            PhotoBrowserView(
                photos: [dayPhotos[0]],
                libraryPhotos: dayPhotos,
                initialPhoto: dayPhotos[0],
                widgetShownAt: nil,
                showsWidgetTiming: false,
                setMemorySaved: { identifier, isSaved in
                    memoryRequest = "\(identifier)|\(isSaved)"
                    if isSaved {
                        savedIdentifiers.insert(identifier)
                    } else {
                        savedIdentifiers.remove(identifier)
                    }
                },
                excludedCatCandidateIdentifiers: [],
                excludeFromCatCandidates: { _ in },
                restoreCatCandidates: { _ in },
                profiles: [],
                assignmentsByPhotoIdentifier: [:],
                replaceProfileAssignments: { _ in true }
            )
        }
        .overlay(alignment: .topLeading) {
            Text(memoryRequest)
                .accessibilityIdentifier("solo-rediscovery-memory-request")
                .foregroundStyle(.clear).frame(width: 1, height: 1).clipped()
                .allowsHitTesting(false)
        }
    }

    private var photos: [PhotoPresentation] {
        AppStoreScreenshotFixture.photos.prefix(2).enumerated().map { index, photo in
            let isSaved = savedIdentifiers.contains(photo.localIdentifier)
            return PhotoPresentation(
                localIdentifier: photo.localIdentifier,
                creationDate: Date(timeIntervalSince1970: 1_754_006_400 + Double(index) * 3_600),
                catBoundingBox: photo.catBoundingBox,
                isLiked: isSaved,
                likedAt: isSaved ? Date(timeIntervalSince1970: 1_788_912_000) : nil
            )
        }
    }
}
#endif

#endif
