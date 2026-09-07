#if DEBUG && targetEnvironment(simulator)
@preconcurrency import AVFoundation
@preconcurrency import Photos
import UIKit
import Foundation
/// Explicit acceptance capture for a disposable CI Simulator only.
/// The PNG is decoded from the shipping exporter's MP4, not a parallel renderer.
@MainActor
enum MainlineMovieAcceptance {
    static func run() async throws -> URL {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
              CommandLine.arguments.contains(AppStoreScreenshotFixture.launchArgument),
              ProcessInfo.processInfo.environment["NEKO_MAINLINE_ACCEPTANCE_CASE"] == "movie" else {
            throw SeasonalMovieExportError.assetMissing
        }
        // Fresh Simulators can contain Apple's bundled non-cat sample photos.
        // Preserve that exact baseline; export and delete only our new asset.
        func libraryIdentifiers() -> Set<String> {
            let assets = PHAsset.fetchAssets(with: options)
            var identifiers = Set<String>()
            assets.enumerateObjects { asset, _, _ in _ = identifiers.insert(asset.localIdentifier) }
            return identifiers
        }
        let baselineIdentifiers = libraryIdentifiers()

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 720, height: 1_280), format: format
        ).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 720, height: 1_280))
        }
        let manager = FileManager.default
        let directory = try manager.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("MainlineAcceptance", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let movieURL = directory.appendingPathComponent("opening.mp4")
        let pngURL = directory.appendingPathComponent("opening.png")
        // Only these generated acceptance artifacts may be replaced on a retry.
        for url in [movieURL, pngURL] where manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }

        var createdIdentifier: String?
        var managedExportURL: URL?
        var failure: Error?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest.creationRequestForAsset(from: image)
                request.creationDate = Date(timeIntervalSince1970: 1_735_689_600)
                createdIdentifier = request.placeholderForCreatedAsset?.localIdentifier
            }
            guard let identifier = createdIdentifier,
                  PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).count == 1 else {
                throw SeasonalMovieExportError.assetMissing
            }
            let start = Date(timeIntervalSince1970: 1_735_689_600)
            let scene = SeasonalMovieCandidate(
                localIdentifier: identifier, creationDate: start, mediaKind: .stillPhoto,
                catBoundingBox: nil, largestCatAreaRatio: nil, isMemory: false,
                suggestedStartTime: nil, suggestedDuration: nil
            )
            let presentation = SeasonalMoviePresentation(
                quarterStart: start, quarterEnd: Date(timeIntervalSince1970: 1_743_465_600),
                startYearNumber: 2025, startMonthNumber: 1,
                endYearNumber: 2025, endMonthNumber: 3, scenes: [scene]
            )
            let exported = try await SeasonalMovieExportService.shared.export(
                presentation, soundEnabled: false
            )
            managedExportURL = exported
            try manager.copyItem(at: exported, to: movieURL)

            let asset = AVURLAsset(url: movieURL)
            let duration = CMTimeGetSeconds(try await asset.load(.duration))
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard duration.isFinite, abs(duration - 3.6) < 0.1,
                  videoTracks.count == 1, audioTracks.isEmpty,
                  let track = videoTracks.first else {
                throw SeasonalMovieExportError.encodingFailed
            }
            let size = try await track.load(.naturalSize)
            guard size == CGSize(width: 720, height: 1_280) else {
                throw SeasonalMovieExportError.encodingFailed
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let frame = try await generator.image(at: CMTime(seconds: 0.25, preferredTimescale: 600))
            guard frame.image.width == 720, frame.image.height == 1_280,
                  let png = UIImage(cgImage: frame.image).pngData(), !png.isEmpty else {
                throw SeasonalMovieExportError.encodingFailed
            }
            try png.write(to: pngURL, options: .atomic)
        } catch {
            failure = error
        }

        if let managedExportURL {
            await SeasonalMovieExportService.shared.cleanupExport(at: managedExportURL)
        }
        if let createdIdentifier {
            let created = PHAsset.fetchAssets(withLocalIdentifiers: [createdIdentifier], options: nil)
            if created.count > 0 {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(created)
                }
            }
            guard PHAsset.fetchAssets(withLocalIdentifiers: [createdIdentifier], options: nil).count == 0 else {
                throw SeasonalMovieExportError.assetMissing
            }
        }
        guard libraryIdentifiers() == baselineIdentifiers else {
            throw SeasonalMovieExportError.assetMissing
        }
        if let failure { throw failure }
        return pngURL
    }
}
#endif
