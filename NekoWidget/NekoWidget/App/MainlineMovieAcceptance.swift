#if DEBUG && targetEnvironment(simulator)
@preconcurrency import AVFoundation
@preconcurrency import Photos
import UIKit
import Foundation
import CryptoKit
/// Explicit acceptance capture for a disposable CI Simulator only.
/// The PNG is decoded from the shipping exporter's MP4, not a parallel renderer.
@MainActor
enum MainlineMovieAcceptance {
    static func run() async throws -> URL {
        // Only the pinned synthetic Simulator diagnostic requests permission
        // after Xcode's final installation. All other acceptance routes retain
        // their existing authorization behavior.
        let environment = ProcessInfo.processInfo.environment
        guard CommandLine.arguments.contains(AppStoreScreenshotFixture.launchArgument),
              environment["NEKO_MAINLINE_ACCEPTANCE_CASE"] == "movie",
              environment["NEKO_MOVIE_SYNTHETIC_FIXTURE_DIR"] == "@app-tmp/movie-synthetic-inputs" else {
            return try await runAuthorizedCapture()
        }
        let diagnosticDirectory = try createSyntheticDiagnosticDirectory()
        var stage = SyntheticFailureStage.photosAuthorization
        do {
            try writeSyntheticFailureReceipt(at: diagnosticDirectory, stage: stage, result: .pending)
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
                _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            }
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
                throw SeasonalMovieExportError.assetMissing
            }
            stage = .cleanupLifecycle
            try writeSyntheticFailureReceipt(at: diagnosticDirectory, stage: stage, result: .pending)
            try await verifyExportCleanupLifecycle()
            stage = .syntheticFixture
            try writeSyntheticFailureReceipt(at: diagnosticDirectory, stage: stage, result: .pending)
            let output = try await runSyntheticFixture(at: FileManager.default.temporaryDirectory
                .appendingPathComponent("movie-synthetic-inputs", isDirectory: true))
            try writeSyntheticFailureReceipt(at: diagnosticDirectory, stage: stage, result: .completed)
            return output
        } catch {
            // Never serialize error descriptions, Photos identifiers or paths.
            try? writeSyntheticFailureReceipt(at: diagnosticDirectory, stage: stage, result: .failed)
            throw error
        }
    }

    private enum SyntheticDiagnosticResult: String {
        case pending, failed, completed
    }

    private enum SyntheticFailureStage: String {
        case photosAuthorization = "photos-authorization"
        case cleanupLifecycle = "cleanup-lifecycle"
        case syntheticFixture = "synthetic-fixture"
    }

    private static func createSyntheticDiagnosticDirectory() throws -> URL {
        let manager = FileManager.default
        let documents = try manager.url(for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)
        let values = try documents.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink == false else {
            throw SeasonalMovieExportError.cannotCreateOutput
        }
        // A new owned directory preserves previous evidence and foreign files.
        let output = documents.appendingPathComponent("MovieSyntheticDiagnostic-" + UUID().uuidString,
            isDirectory: true)
        try manager.createDirectory(at: output, withIntermediateDirectories: false)
        return output
    }

    private static func writeSyntheticFailureReceipt(at output: URL, stage: SyntheticFailureStage,
                                                     result: SyntheticDiagnosticResult) throws {
        let authorization: String
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined: authorization = "notDetermined"
        case .restricted: authorization = "restricted"
        case .denied: authorization = "denied"
        case .authorized: authorization = "authorized"
        case .limited: authorization = "limited"
        @unknown default: authorization = "unknown"
        }
        let suppliedSHA = ProcessInfo.processInfo.environment["NEKO_MOVIE_BUILD_SHA"] ?? ""
        let sourceSHA = suppliedSHA.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
            ? suppliedSHA : "not supplied"
        let receipt: [String: Any] = ["schemaVersion": 1, "syntheticOnly": true,
            "result": result.rawValue, "stage": stage.rawValue, "photosAuthorization": authorization,
            "buildSourceSHA": sourceSHA]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("receipt.json"), options: [.atomic, .completeFileProtection])
    }

    private static func runAuthorizedCapture() async throws -> URL {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
              CommandLine.arguments.contains(AppStoreScreenshotFixture.launchArgument),
              ProcessInfo.processInfo.environment["NEKO_MAINLINE_ACCEPTANCE_CASE"] == "movie" else {
            throw SeasonalMovieExportError.assetMissing
        }
        try await verifyExportCleanupLifecycle()
        if let path = ProcessInfo.processInfo.environment["NEKO_MOVIE_SYNTHETIC_FIXTURE_DIR"] {
            // The diagnostic runner seeds this single fixed directory in the
            // disposable app container. No host path crosses the UI-test boundary.
            let directory = path == "@app-tmp/movie-synthetic-inputs"
                ? FileManager.default.temporaryDirectory.appendingPathComponent("movie-synthetic-inputs")
                : URL(fileURLWithPath: path, isDirectory: true)
            return try await runSyntheticFixture(at: directory)
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

    private struct SyntheticFixture: Decodable {
        struct Scene: Decodable { let file: String; let date: String; let kind: String; let duration: Double }
        let schemaVersion: Int
        let syntheticOnly: Bool
        let productionExportExecuted: Bool
        let expectedFrameCount: Int
        let expectedDuration: Double
        let sha256: [String: String]
        let scenes: [Scene]
    }

    /// Optional DEBUG Simulator path; the normal opening-only capture stays intact.
    /// The externally supplied fixture is read-only and verified before Photos changes.
    private static func runSyntheticFixture(at fixtureDirectory: URL) async throws -> URL {
        let manager = FileManager.default
        let values = try fixtureDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink == false else {
            throw SeasonalMovieExportError.assetMissing
        }
        func fileBytes(_ name: String) throws -> Data {
            let url = fixtureDirectory.appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink == false else {
                throw SeasonalMovieExportError.assetMissing
            }
            return try Data(contentsOf: url)
        }
        let manifestData = try fileBytes("fixture.json")
        let manifestHash = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
        // Pin the already verified synthetic fixture, rather than trusting an
        // editable syntheticOnly flag and caller-supplied photo hashes.
        guard manifestHash == "643f16febdb4088c28a1aea1d6d25032be324296dd3f2955d0f94ce93f100e82" else {
            throw SeasonalMovieExportError.assetMissing
        }
        let fixture = try JSONDecoder().decode(SyntheticFixture.self, from: manifestData)
        let stillNames = (1...6).map { "still-\($0).png" }
        let inputNames = stillNames + ["source-video.mp4", "source-audio-997hz.wav"]
        let sceneNames = ["still-1.png", "still-2.png", "source-video.mp4", "still-3.png",
                          "still-4.png", "source-video.mp4", "still-5.png", "still-6.png"]
        let expectedKinds = ["stillPhoto", "stillPhoto", "video", "stillPhoto", "stillPhoto", "video", "stillPhoto", "stillPhoto"]
        let expectedDurations: [Double] = [1.8, 1.45, 2, 1.45, 1.45, 2, 1.45, 2]
        guard fixture.schemaVersion == 1, fixture.syntheticOnly, !fixture.productionExportExecuted,
              fixture.expectedFrameCount == 370, abs(fixture.expectedDuration - 370.0/24) < 0.000001,
              Set(fixture.sha256.keys) == Set(inputNames), fixture.scenes.map(\.file) == sceneNames,
              fixture.scenes.map(\.kind) == expectedKinds, fixture.scenes.map(\.duration) == expectedDurations else {
            throw SeasonalMovieExportError.assetMissing
        }
        for name in inputNames {
            let hash = SHA256.hash(data: try fileBytes(name)).map { String(format: "%02x", $0) }.joined()
            guard hash == fixture.sha256[name] else { throw SeasonalMovieExportError.assetMissing }
        }
        let dates = try fixture.scenes.map { scene -> Date in
            guard let date = ISO8601DateFormatter().date(from: scene.date),
                  date >= Date(timeIntervalSince1970: 1_735_689_600),
                  date < Date(timeIntervalSince1970: 1_743_465_600) else { throw SeasonalMovieExportError.assetMissing }
            return date
        }
        guard dates == dates.sorted() else { throw SeasonalMovieExportError.assetMissing }
        let options = PHFetchOptions(); options.includeHiddenAssets = true; options.includeAllBurstAssets = true
        func identifiers() -> Set<String> {
            var result = Set<String>()
            PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in _ = result.insert(asset.localIdentifier) }
            return result
        }
        let baseline = identifiers()
        let exportRoot = manager.temporaryDirectory.appendingPathComponent("SeasonalMovieExports")
        func exportDirectoryNames() throws -> Set<String> {
            guard manager.fileExists(atPath: exportRoot.path) else { return [] }
            let values = try exportRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink == false else {
                throw SeasonalMovieExportError.cannotCreateOutput
            }
            return Set(try manager.contentsOfDirectory(at: exportRoot, includingPropertiesForKeys: nil)
                .map(\.lastPathComponent))
        }
        let exportBaseline = try exportDirectoryNames()
        let documents = try manager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let output = documents.appendingPathComponent("MovieSyntheticAcceptance-" + UUID().uuidString)
        try manager.createDirectory(at: output, withIntermediateDirectories: false,
                                    attributes: [.protectionKey: FileProtectionType.complete])
        var created: [String: String] = [:]
        var exports: [URL] = []
        var results: [[String: Any]] = []
        var exportAttempts = 0
        var failure: Error?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for name in stillNames + ["source-video.mp4"] {
                    let url = fixtureDirectory.appendingPathComponent(name)
                    let request = name.hasSuffix(".mp4")
                        ? PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                        : PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                    if let identifier = request?.placeholderForCreatedAsset?.localIdentifier {
                        created[name] = identifier
                    }
                }
            }
            guard created.count == 7, Set(created.values).count == 7,
                  Set(created.values).isDisjoint(with: baseline) else { throw SeasonalMovieExportError.assetMissing }
            let scenes = try fixture.scenes.enumerated().map { index, scene -> SeasonalMovieCandidate in
                guard let identifier = created[scene.file],
                      PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).count == 1 else {
                    throw SeasonalMovieExportError.assetMissing
                }
                return SeasonalMovieCandidate(localIdentifier: identifier, creationDate: dates[index],
                    mediaKind: scene.kind == "video" ? .video : .stillPhoto, catBoundingBox: nil,
                    largestCatAreaRatio: nil, isMemory: false,
                    suggestedStartTime: scene.kind == "video" ? 0 : nil,
                    suggestedDuration: scene.kind == "video" ? scene.duration : nil)
            }
            let presentation = SeasonalMoviePresentation(quarterStart: Date(timeIntervalSince1970: 1_735_689_600),
                quarterEnd: Date(timeIntervalSince1970: 1_743_465_600), startYearNumber: 2025, startMonthNumber: 1,
                endYearNumber: 2025, endMonthNumber: 3, scenes: scenes)
            for enabled in [true, false] {
                exportAttempts += 1
                let managed = try await SeasonalMovieExportService.shared.export(presentation, soundEnabled: enabled)
                exports.append(managed)
                let file = output.appendingPathComponent(enabled ? "exported-on.mp4" : "exported-off.mp4")
                try manager.copyItem(at: managed, to: file)
                let asset = AVURLAsset(url: file)
                let duration = CMTimeGetSeconds(try await asset.load(.duration))
                let videos = try await asset.loadTracks(withMediaType: .video)
                let audio = try await asset.loadTracks(withMediaType: .audio)
                guard duration.isFinite, abs(duration-fixture.expectedDuration) < 0.1,
                      videos.count == 1, audio.count == (enabled ? 1 : 0), let track = videos.first,
                      try await track.load(.naturalSize) == CGSize(width: 720, height: 1280) else {
                    throw SeasonalMovieExportError.encodingFailed
                }
                results.append(["file": file.lastPathComponent, "soundEnabled": enabled, "duration": duration,
                    "sha256": SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()])
                if !enabled {
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    let image = try await generator.image(at: CMTime(seconds: 0.25, preferredTimescale: 600))
                    guard let png = UIImage(cgImage: image.image).pngData() else { throw SeasonalMovieExportError.encodingFailed }
                    try png.write(to: output.appendingPathComponent("opening.png"), options: [.atomic, .completeFileProtection])
                }
            }
        } catch { failure = error }
        for file in exports { await SeasonalMovieExportService.shared.cleanupExport(at: file) }
        let returnedManagedExportsCleaned = exports.allSatisfy { !manager.fileExists(atPath: $0.deletingLastPathComponent().path) }
        // A throwing exporter may leave a directory without ever returning a
        // URL. Observe new entries as well; never delete an unowned baseline.
        let remainingNewManagedDirectories = (try? exportDirectoryNames()).map { $0.subtracting(exportBaseline) }
        let managedCleanupSucceeded = returnedManagedExportsCleaned && remainingNewManagedDirectories?.isEmpty == true
        // Even on a failed import/export, only IDs created by this run can be deleted.
        let createdIDs = Set(created.values).subtracting(baseline)
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(createdIDs), options: nil)
        if assets.count > 0 {
            do { try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) } }
            catch { if failure == nil { failure = error } }
        }
        let baselineRestored = identifiers() == baseline
        if (!baselineRestored || !managedCleanupSucceeded) && failure == nil { failure = SeasonalMovieExportError.assetMissing }
        let remainingDirectoryEvidence: Any
        if let remainingNewManagedDirectories { remainingDirectoryEvidence = Array(remainingNewManagedDirectories).sorted() }
        else { remainingDirectoryEvidence = NSNull() }
        let receipt: [String: Any] = ["syntheticOnly": true, "shippingExporterInvoked": exportAttempts > 0,
            "exportAttempts": exportAttempts,
            "fixtureManifestSHA256": manifestHash,
            "buildSourceSHA": ProcessInfo.processInfo.environment["NEKO_MOVIE_BUILD_SHA"] ?? "not supplied",
            "exports": results, "photoBaselineRestored": baselineRestored, "managedCleanupSucceeded": managedCleanupSucceeded,
            "returnedManagedExportsCleaned": returnedManagedExportsCleaned,
            "remainingNewManagedDirectories": remainingDirectoryEvidence,
            "result": failure == nil ? "exported; external inspection pending" : "failed",
            "visualInspection": "not performed", "listening": "not performed"]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("receipt.json"), options: [.atomic, .completeFileProtection])
        if let failure { throw failure }
        return output.appendingPathComponent("opening.png")
    }

    /// Only synthetic files under a new disposable temp root are affected.
    /// Covers exact output ownership, stale/fresh exports and both symlink levels.
    private static func verifyExportCleanupLifecycle() async throws {
        let manager = FileManager.default
        let suite = manager.temporaryDirectory.appendingPathComponent("movie-cleanup-verify-" + UUID().uuidString)
        try manager.createDirectory(at: suite, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: suite) }
        let temporary = suite.appendingPathComponent("temporary")
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        let fixtureManager = MovieAcceptanceFileManager(testRoot: temporary)
        let service = SeasonalMovieExportService(fileManager: fixtureManager)
        let root = temporary.appendingPathComponent("SeasonalMovieExports")
        let saved = suite.appendingPathComponent("saved")
        let old = root.appendingPathComponent(UUID().uuidString)
        let fresh = root.appendingPathComponent(UUID().uuidString)
        let invalid = root.appendingPathComponent("not-a-uuid")
        let sentinel = Data("synthetic-saved-copy".utf8)
        for directory in [saved, old, fresh, invalid] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try sentinel.write(to: directory.appendingPathComponent("seasonal-movie.mp4"))
        }
        let savedCopy = saved.appendingPathComponent("seasonal-movie.mp4")
        let childLink = root.appendingPathComponent(UUID().uuidString)
        try manager.createSymbolicLink(at: childLink, withDestinationURL: saved)
        await service.cleanupExport(at: savedCopy)
        await service.cleanupExport(at: invalid.appendingPathComponent("seasonal-movie.mp4"))
        await service.cleanupExport(at: fresh.appendingPathComponent("foreign-name.mp4"))
        await service.cleanupExport(at: childLink.appendingPathComponent("seasonal-movie.mp4"))
        guard try Data(contentsOf: savedCopy) == sentinel,
              manager.fileExists(atPath: invalid.path), manager.fileExists(atPath: fresh.path),
              try childLink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true else {
            throw SeasonalMovieExportError.encodingFailed
        }
        try manager.setAttributes([.modificationDate: Date().addingTimeInterval(-48*60*60)], ofItemAtPath: old.path)
        try SeasonalMovieExportService.cleanupStaleExports(fileManager: fixtureManager)
        guard !manager.fileExists(atPath: old.path), manager.fileExists(atPath: fresh.path),
              manager.fileExists(atPath: invalid.path), try Data(contentsOf: savedCopy) == sentinel,
              try childLink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true else {
            throw SeasonalMovieExportError.encodingFailed
        }
        await service.cleanupExport(at: fresh.appendingPathComponent("seasonal-movie.mp4"))
        guard !manager.fileExists(atPath: fresh.path), try Data(contentsOf: savedCopy) == sentinel else {
            throw SeasonalMovieExportError.encodingFailed
        }
        let linkedTemporary = suite.appendingPathComponent("linked-temporary")
        try manager.createDirectory(at: linkedTemporary, withIntermediateDirectories: true)
        let foreignChild = saved.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: foreignChild, withIntermediateDirectories: true)
        let foreignOutput = foreignChild.appendingPathComponent("seasonal-movie.mp4")
        try sentinel.write(to: foreignOutput)
        let rootLink = linkedTemporary.appendingPathComponent("SeasonalMovieExports")
        try manager.createSymbolicLink(at: rootLink, withDestinationURL: saved)
        let linkedManager = MovieAcceptanceFileManager(testRoot: linkedTemporary)
        let linkedService = SeasonalMovieExportService(fileManager: linkedManager)
        await linkedService.cleanupExport(at: rootLink.appendingPathComponent(foreignChild.lastPathComponent)
            .appendingPathComponent("seasonal-movie.mp4"))
        try SeasonalMovieExportService.cleanupStaleExports(fileManager: linkedManager, olderThan: 0)
        guard try Data(contentsOf: foreignOutput) == sentinel,
              try rootLink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true else {
            throw SeasonalMovieExportError.encodingFailed
        }
    }
}

private final class MovieAcceptanceFileManager: FileManager, @unchecked Sendable {
    private let testRoot: URL
    init(testRoot: URL) { self.testRoot = testRoot; super.init() }
    override var temporaryDirectory: URL { testRoot }
}
#endif
