import CryptoKit
import Foundation
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers
@preconcurrency import Vision

struct WidgetCacheBuildResult: Sendable {
    var manifest: WidgetManifest
    var selectedIdentifiers: [String]
}

struct PersonalWidgetPreparationResult: Sendable {
    let candidateCount: Int
    let addedCount: Int
    let hasMore: Bool
    let attemptedPhotoIDs: Set<String>
}

private struct PersonalWidgetRenderMeasurements {
    var widths: [Int] = []
    var heights: [Int] = []
    var decodedBytes: [Int] = []
    var compositions: [WidgetCompositionMode: Int] = [:]
    var upscaled: [WidgetImageVariant: Int] = [:]
    var maximumScale: CGFloat = 0
    var fallbackPairs = 0
    var currentFallback = 0
    var legacyFallback = 0
    var generatedFiles = 0

    mutating func append(_ other: Self) {
        widths += other.widths
        heights += other.heights
        decodedBytes += other.decodedBytes
        compositions.merge(other.compositions, uniquingKeysWith: +)
        upscaled.merge(other.upscaled, uniquingKeysWith: +)
        maximumScale = max(maximumScale, other.maximumScale)
        fallbackPairs += other.fallbackPairs
        currentFallback += other.currentFallback
        legacyFallback += other.legacyFallback
        generatedFiles += other.generatedFiles
    }
}

private struct WidgetCacheGeneration: Codable, Equatable, Sendable {
    var generatedAt: Date
    var filenames: [String]
}

private struct WidgetCacheHistory: Codable, Sendable {
    var generations: [WidgetCacheGeneration]

    static let empty = WidgetCacheHistory(generations: [])
}

private struct FamilyWidgetCacheGeneration: Codable, Equatable, Sendable {
    var sourceDigest: String
    var cacheFilenames: WidgetCacheFilenames
    var generatedAt: Date
}

private struct FamilyWidgetCacheHistory: Codable, Sendable {
    var generations: [FamilyWidgetCacheGeneration]

    static let empty = FamilyWidgetCacheHistory(generations: [])
}

private struct FamilyWidgetSourceSnapshot: Sendable {
    var item: MomentInboxItem
    var data: Data
    var sourceDigest: String
}

actor WidgetCacheBuilder {
    private static let historyFilename = "widget-cache-history.json"
    /// Local cache-only revision. Keep this separate from the encrypted sharing
    /// geometry version: changing the visual fallback must rebuild existing
    /// personal JPEGs without making otherwise compatible peers disagree.
    private static let cacheRenderingRevision = "cat-focused-fallback-v2"
    /// The migration-safe maximum is 380 distinct files: new manifest 60,
    /// previous active manifest 60, grace generation 60, three pre-Build-8
    /// family leases of up to 60 each, and the Build-4 legacy lease of 20.
    /// Round to 400; the bounded provider writes at most 2 files per family lease.
    private static let maximumGenerationCount = 8
    private static let maximumCachedFileCount = 400
    private static let maximumFamilyGenerationCount = 4
    /// PhotoKit returns an aspect-fit local derivative. 2048px keeps a normal
    /// 16:9 source above the 1100px Large short side while bounding app-side
    /// source decode memory to roughly 16 MiB. Network behavior stays unchanged.
    private static let sourceImageRequestPixelDimension = 2_048
    private struct RenderSpec: Sendable {
        var variant: WidgetImageVariant
        var size: CGSize

        static let all: [RenderSpec] = WidgetImageVariant.allCases.map { variant in
            RenderSpec(
                variant: variant,
                size: CGSize(
                    width: CGFloat(variant.pixelWidth),
                    height: CGFloat(variant.pixelHeight)
                )
            )
        }

        static func spec(for variant: WidgetImageVariant) -> RenderSpec {
            all.first(where: { $0.variant == variant })!
        }

        var pixelDescription: String {
            variant.pixelDescription
        }

        var maximumJPEGByteCount: Int {
            variant.maximumJPEGByteCount
        }
    }

    private let imageLoader: PhotoImageLoader
    private let selector: WeightedPhotoSelector

    init(
        imageLoader: PhotoImageLoader = PhotoImageLoader(),
        selector: WeightedPhotoSelector = WeightedPhotoSelector()
    ) {
        self.imageLoader = imageLoader
        self.selector = selector
    }

    /// The app supplies an already-curated snapshot and a compare-and-swap
    /// authority token. Rendering happens outside the cross-process store lock;
    /// only final placement/publication/collection shares the Provider's lock.
    func replenishPersonal(
        from snapshot: LibrarySnapshot,
        eligibilityRevision: String,
        skippingPhotoIDs: Set<String> = [],
        now: Date = .now
    ) async throws -> PersonalWidgetPreparationResult {
        guard let container = SharedContainer.containerURL,
              let cache = SharedContainer.widgetCacheDirectoryURL,
              let manifestURL = SharedContainer.widgetManifestURL else {
            throw NekoWidgetError.appGroupUnavailable(SharedContainer.appGroupIdentifier)
        }
        let rediscovery = PersonalRediscoveryStore.shared
        guard let initial = try rediscovery.snapshot(now: now),
              initial.isAuthorized,
              initial.eligibilityRevision == eligibilityRevision else {
            throw CancellationError()
        }
        let existingIDs = Set(initial.candidates.filter {
            Self.hasUsablePersonalFiles(for: $0.item, cacheDirectory: cache)
        }.map { $0.item.localIdentifier })
        let discardedIDs = Set(initial.candidates.map { $0.item.localIdentifier }).subtracting(existingIDs)
        let needsGeometryIDs = Set(initial.candidates.filter {
            $0.item.rendererVersion == nil || $0.item.renderPlans == nil || $0.item.sourcePixelSize == nil
        }.map { $0.item.localIdentifier })
        var ordered = selector.candidateOrder(from: snapshot.assets,
                                              settings: snapshot.settings, now: now)
            .filter { initial.eligiblePhotoIDs.contains($0.localIdentifier)
                && (!existingIDs.contains($0.localIdentifier) || needsGeometryIDs.contains($0.localIdentifier))
                && !skippingPhotoIDs.contains($0.localIdentifier) }
        // Full, mostly unissued pools need no work. Issued candidates can be
        // replaced later, once their live leases and history no longer pin them.
        if existingIDs.count >= 100 && initial.remainingUnissuedCount > 30 {
            ordered.removeAll { !needsGeometryIDs.contains($0.localIdentifier) }
        }
        let stage = container.appendingPathComponent("personal-widget-staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: stage.path)
        defer { try? FileManager.default.removeItem(at: stage) }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let legacy = try? AtomicJSON.read(WidgetManifest.self, from: manifestURL)
        // Reuse known cached photos before probing the randomized PhotoKit
        // order. Its first thirty records can all be unavailable in iCloud.
        var prepared = Self.personalBootstrapCandidates(from: ordered.filter { !existingIDs.contains($0.localIdentifier) },
            manifest: legacy, cacheDirectory: cache, now: now)
        if prepared.isEmpty && existingIDs.isEmpty {
            prepared = Self.recoverUnindexedPersonalCache(from: ordered, cacheDirectory: cache, now: now)
        }
        let cachedIDs = Set(prepared.map { $0.item.localIdentifier })
        let accessibleCachedIDs = Set(Self.currentPersonalRecords(
            from: ordered.filter { cachedIDs.contains($0.localIdentifier) }).map(\.localIdentifier))
        prepared.removeAll { !accessibleCachedIDs.contains($0.item.localIdentifier) }
        let reusedIDs = Set(prepared.map { $0.item.localIdentifier })
        let recoveredWithoutGeometryIDs = Set(prepared.filter { $0.item.renderPlans == nil }
            .map { $0.item.localIdentifier })
        ordered.removeAll { reusedIDs.contains($0.localIdentifier) }
        var measurements = PersonalWidgetRenderMeasurements()
        let started = Date()
        // Recovered display bytes have not attempted an original-image load.
        // Let the next bounded batch restore their sharing geometry if possible.
        var attemptedPhotoIDs = reusedIDs.subtracting(recoveredWithoutGeometryIDs)
        var unavailable = 0
        // Bound both successful work and unavailable-iCloud probes. No network
        // download, Vision rescan or unbounded library pass occurs in this job.
        for record in ordered.prefix(30) where prepared.count < 10 {
            try Task.checkCancellation()
            if !attemptedPhotoIDs.isEmpty && Date().timeIntervalSince(started) >= 5 { break }
            attemptedPhotoIDs.insert(record.localIdentifier)
            if let rendered = try preparePersonalItem(record, in: stage, now: now) {
                measurements.append(rendered.measurements)
                prepared.append(.init(item: rendered.item, creationDate: record.creationDate,
                                      burstIdentifier: record.burstIdentifier,
                                      isFavorite: record.isFavorite, isSaved: record.liked,
                                      preparedAt: now))
            } else { unavailable += 1 }
            if prepared.count >= 10 { break }
        }
        try Task.checkCancellation()
        let published = try rediscovery.publish(
            candidates: prepared,
            expectedRevision: eligibilityRevision,
            now: now,
            interval: TimeInterval(snapshot.settings.widgetEntryIntervalMinutes * 60),
            discardCandidateIDs: discardedIDs
        ) { protectedFiles in
            try Task.checkCancellation()
            // An unsuccessful first batch has no new files to publish. Keep
            // old unindexed JPEGs available for a later recovery attempt.
            if prepared.isEmpty && initial.candidates.isEmpty { return }
            let incoming = Set(prepared.flatMap { $0.item.allCacheFilenames })
            // The store includes incoming references in this set. Never collect
            // a Provider/grant dependency in order to make space for a new photo.
            var required = protectedFiles.union(incoming)
            // Preserve the installed pre-upgrade Provider's active references
            // while its extension transitions to the new store.
            if let currentLegacy = try? AtomicJSON.read(WidgetManifest.self, from: manifestURL),
               currentLegacy.generatedAt > now.addingTimeInterval(-12 * 60 * 60) {
                required.formUnion(currentLegacy.items.flatMap(\.allCacheFilenames))
            }
            for leaseURL in SharedContainer.allWidgetTimelineLeaseURLs {
                if let lease = try? AtomicJSON.read(WidgetTimelineLease.self, from: leaseURL),
                   lease.recordedAt > now.addingTimeInterval(-12 * 60 * 60) {
                    required.formUnion(lease.cacheFilenames)
                }
            }
            guard required.count <= Self.maximumCachedFileCount else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            let contents = try FileManager.default.contentsOfDirectory(
                at: cache, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            for url in contents where !required.contains(url.lastPathComponent)
                && ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) {
                try FileManager.default.removeItem(at: url)
            }
            for filename in incoming {
                let staged = stage.appendingPathComponent(filename)
                guard FileManager.default.fileExists(atPath: staged.path) else { continue }
                let data = try Data(contentsOf: staged)
                let destination = cache.appendingPathComponent(filename)
                try data.write(to: destination, options: .atomic)
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: destination.path)
            }
        }
        // Rolling upgrades still see at most the legacy twenty-entry shape.
        // New Providers use the persisted plan, never this compatibility order.
        try rediscovery.withProtectedCacheFiles(expectedRevision: eligibilityRevision, now: now) { protected in
            let available = published.candidates.filter {
                Set($0.item.allCacheFilenames).isSubset(of: protected)
            }
            let legacyItems = Array(available.prefix(20)).enumerated().map { offset, candidate in
                var item = candidate.item
                item.scheduledDate = now.addingTimeInterval(
                    TimeInterval(offset * snapshot.settings.widgetEntryIntervalMinutes * 60))
                return item
            }
            try AtomicJSON.write(WidgetManifest(items: legacyItems, generatedAt: now), to: manifestURL)
        }
        // Preserve the existing diagnostic completion contract. These are
        // measurements of this render batch and the published pool, never
        // invented view counts or a legacy generation-history write.
        let filenames = Set(published.candidates.flatMap { $0.item.allCacheFilenames })
        let byteCounts = filenames.compactMap { filename in
            (try? cache.appendingPathComponent(filename).resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        }
        var metadata: [String: String] = [
            "algorithm": WidgetRenderPlanner.rendererVersion,
            "entries": "\(published.candidates.count)",
            "uniqueAssets": "\(published.candidates.count)",
            "uniqueFiles": "\(filenames.count)",
            "generatedFiles": "\(measurements.generatedFiles)",
            "reusedFiles": "\(prepared.count * 3 - measurements.generatedFiles)",
            "cacheFileCap": "\(Self.maximumCachedFileCount)",
            "cacheBytesMax": "\(byteCounts.max() ?? 0)",
            "cacheBytesMin": "\(byteCounts.min() ?? 0)",
            "cacheBytesTotal": "\(byteCounts.reduce(0, +))",
            "inputPixelsMax": Self.pixelRange(widths: measurements.widths, heights: measurements.heights),
            "inputDecodedBytesMax": "\(measurements.decodedBytes.max() ?? 0)",
            "current8Fallback": "\(measurements.currentFallback)",
            "legacy18Fallback": "\(measurements.legacyFallback)",
            "marginFallbackDenominator": "\(measurements.fallbackPairs)",
            "marginComparisonScope": "generated-small-large",
            "renderScaleMax": String(format: "%.4f", measurements.maximumScale),
            "outputPixels": Self.outputPixelDescription,
            "targetBytesEach": Self.targetByteDescription,
            "retainedCacheWorstCaseBytes": "\(Self.maximumRetainedCacheByteUpperBound)",
            "unavailable": "\(unavailable)",
            "networkAllowed": "false"
        ]
        for spec in Self.RenderSpec.all {
            metadata["renderUpscaled\(spec.variant.rawValue.capitalized)"] = "\(measurements.upscaled[spec.variant, default: 0])"
        }
        for mode in WidgetCompositionMode.allCases {
            metadata[mode.generatedMetadataKey] = "\(measurements.compositions[mode, default: 0])"
        }
        SharedLog.app.info("widget-cache", "Widget cache build completed", metadata: metadata)
        let addedCount = Set(published.candidates.map { $0.item.localIdentifier })
            .subtracting(existingIDs).count
        return .init(candidateCount: published.candidates.count,
                     addedCount: addedCount,
                     hasMore: (!recoveredWithoutGeometryIDs.isEmpty
                        || attemptedPhotoIDs.subtracting(reusedIDs).count < ordered.count)
                        && published.candidates.count < 100,
                     attemptedPhotoIDs: attemptedPhotoIDs)
    }

    /// Only current, explicitly eligible records can adopt a legacy manifest.
    /// Checking the deterministic filenames also rejects a stale analysis box
    /// or renderer cache revision, even when PhotoKit's edit date is unchanged.
    static func personalBootstrapCandidates(
        from eligible: [AssetRecord], manifest: WidgetManifest?,
        cacheDirectory: URL, now: Date
    ) -> [PersonalRediscoveryCandidate] {
        guard let manifest, !manifest.items.isEmpty else { return [] }
        let records = Dictionary(eligible.map { ($0.localIdentifier, $0) },
                                 uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return PersonalWidgetRotationPolicy.orderedUniqueItems(from: manifest.items).compactMap { original in
            var item = original
            guard let record = records[item.localIdentifier],
                  seen.insert(item.localIdentifier).inserted,
                  item.sourceModificationDate == record.sourceModificationDate,
                  hasUsablePersonalFiles(for: item, cacheDirectory: cacheDirectory)
            else { return nil }
            if item.rendererVersion == "cat-aware-full-bleed-v5",
               WidgetImageVariant.allCases.allSatisfy({ variant in
                   item.cacheFilename(for: variant).hasPrefix("asset-cat-aware-full-bleed-v5-\(variant.rawValue)-")
               }), fullyDecodesPersonalItem(item, cacheDirectory: cacheDirectory) {
                // Build 166 kept its active v5 photo if the v6 original could
                // not be loaded. Preserve that display while requesting a v6
                // rebuild; do not reintroduce old geometry into sharing.
                item.rendererVersion = nil
                item.sourcePixelSize = nil
                item.renderPlans = nil
            } else {
                guard item.rendererVersion == WidgetRenderPlanner.rendererVersion,
                      item.cacheFilenames == cacheFilenames(for: record) else { return nil }
            }
            return .init(item: item, creationDate: record.creationDate,
                         burstIdentifier: record.burstIdentifier,
                         isFavorite: record.isFavorite, isSaved: record.liked, preparedAt: now)
        }
    }

    /// Metadata-only permission/edit check; this never downloads an image.
    /// Callers have already reduced this to at most twenty cached records.
    static func currentPersonalRecords(from records: [AssetRecord]) -> [AssetRecord] {
        guard !records.isEmpty else { return [] }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return [] }
        let known = Dictionary(records.map { ($0.localIdentifier, $0) },
                               uniquingKeysWith: { first, _ in first })
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(known.keys), options: nil)
        var result: [AssetRecord] = []
        assets.enumerateObjects { asset, _, _ in
            guard let record = known[asset.localIdentifier], asset.mediaType == .image,
                  record.sourceModificationDateWasCaptured == true else { return }
            let modified = asset.modificationDate.map {
                Date(timeIntervalSince1970: floor($0.timeIntervalSince1970))
            }
            if record.sourceModificationDate == modified { result.append(record) }
        }
        return result
    }

    /// Build 167 could replace the legacy index with an empty manifest. Recover
    /// only exact current cache identities; never infer an ID from a filename
    /// or invent the lost original-image geometry. The existing sharing freezer
    /// will require an original-image rebuild when geometry is unavailable.
    private static func recoverUnindexedPersonalCache(
        from eligible: [AssetRecord], cacheDirectory: URL, now: Date
    ) -> [PersonalRediscoveryCandidate] {
        let files = Set((try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)) ?? [])
        guard !files.isEmpty else { return [] }
        let started = Date()
        var result: [PersonalRediscoveryCandidate] = []
        // The pre-upgrade app recorded the last prepared photos in lastShownAt.
        // Prioritize these metadata records; no PhotoKit image is requested.
        for record in eligible.sorted(by: { ($0.lastShownAt ?? .distantPast) > ($1.lastShownAt ?? .distantPast) }) {
            if result.count >= 20 || Date().timeIntervalSince(started) >= 2 { break }
            let filenames = cacheFilenames(for: record)
            guard Set(filenames.all).isSubset(of: files) else { continue }
            let item = WidgetManifestItem(localIdentifier: record.localIdentifier,
                cacheFilename: filenames.small, cacheFilenames: filenames, scheduledDate: now,
                sourceModificationDate: record.sourceModificationDate)
            guard hasUsablePersonalFiles(for: item, cacheDirectory: cacheDirectory),
                  fullyDecodesPersonalItem(item, cacheDirectory: cacheDirectory) else { continue }
            result.append(.init(item: item, creationDate: record.creationDate,
                burstIdentifier: record.burstIdentifier, isFavorite: record.isFavorite,
                isSaved: record.liked, preparedAt: now))
        }
        return result
    }

    private static func fullyDecodesPersonalItem(_ item: WidgetManifestItem, cacheDirectory: URL) -> Bool {
        WidgetImageVariant.allCases.allSatisfy { variant in
            autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(
                    cacheDirectory.appendingPathComponent(item.cacheFilename(for: variant)) as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
                      let image = CGImageSourceCreateImageAtIndex(source, 0,
                          [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                else { return false }
                return image.width > 0 && image.height > 0
                    && image.width <= variant.pixelWidth && image.height <= variant.pixelHeight
            }
        }
    }

    private func preparePersonalItem(_ record: AssetRecord, in stage: URL,
                                     now: Date) throws -> (item: WidgetManifestItem, measurements: PersonalWidgetRenderMeasurements)? {
        try autoreleasepool {
            guard let image = imageLoader.image(localIdentifier: record.localIdentifier,
                targetSize: CGSize(width: Self.sourceImageRequestPixelDimension,
                                   height: Self.sourceImageRequestPixelDimension),
                networkAccessAllowed: false, contentMode: .aspectFit) else { return nil }
            let normalized = WidgetSourceImageNormalizer.normalizedUIImage(image)
            let size = WidgetSourcePixelSize(width: normalized.cgImage?.width ?? Int(normalized.size.width),
                                            height: normalized.cgImage?.height ?? Int(normalized.size.height))
            let plans = WidgetRenderPlanner.plans(visionBoundingBox: record.cat.boundingBox?.cgRect,
                                                  sourcePixelSize: size)
            let filenames = Self.cacheFilenames(for: record)
            var measurements = PersonalWidgetRenderMeasurements()
            let width = image.cgImage?.width ?? Int(image.size.width * image.scale)
            let height = image.cgImage?.height ?? Int(image.size.height * image.scale)
            measurements.widths = [width]
            measurements.heights = [height]
            measurements.decodedBytes = [image.cgImage.map { $0.bytesPerRow * $0.height } ?? width * height * 4]
            for spec in Self.RenderSpec.all {
                try Task.checkCancellation()
                guard let output = Self.widgetJPEG(normalizedImage: normalized,
                    renderPlan: plans.plan(for: spec.variant), catBoundingBox: record.cat.boundingBox?.cgRect,
                    spec: spec) else { return nil }
                try output.data.write(to: stage.appendingPathComponent(filenames.filename(for: spec.variant)),
                                      options: .atomic)
                measurements.generatedFiles += 1
                measurements.compositions[output.compositionMode, default: 0] += 1
                measurements.maximumScale = max(measurements.maximumScale, output.renderScale)
                if output.renderScale > 1.001 { measurements.upscaled[spec.variant, default: 0] += 1 }
                if let legacyFallback = output.legacy18WouldFallback {
                    measurements.fallbackPairs += 1
                    if output.compositionMode == .blurredFitFallback { measurements.currentFallback += 1 }
                    if legacyFallback { measurements.legacyFallback += 1 }
                }
            }
            let item = WidgetManifestItem(localIdentifier: record.localIdentifier,
                cacheFilename: filenames.small, cacheFilenames: filenames, scheduledDate: now,
                rendererVersion: WidgetRenderPlanner.rendererVersion, sourcePixelSize: size,
                renderPlans: plans, sourceModificationDate: record.sourceModificationDate)
            return (item, measurements)
        }
    }

    private static func hasUsablePersonalFiles(for item: WidgetManifestItem, cacheDirectory: URL) -> Bool {
        guard hasCompleteFamilyFiles(for: item, cacheDirectory: cacheDirectory) else { return false }
        return item.allCacheFilenames.allSatisfy { filename in
            guard let source = CGImageSourceCreateWithURL(cacheDirectory.appendingPathComponent(filename) as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) == 1,
                  CGImageSourceGetStatus(source) == .statusComplete else { return false }
            return true
        }
    }

    func build(from snapshot: LibrarySnapshot, now: Date = .now) async throws -> WidgetCacheBuildResult {
        guard let containerURL = SharedContainer.containerURL,
              let cacheDirectory = SharedContainer.widgetCacheDirectoryURL,
              let manifestURL = SharedContainer.widgetManifestURL else {
            throw NekoWidgetError.appGroupUnavailable(SharedContainer.appGroupIdentifier)
        }

        let settings = snapshot.settings.normalized()
        let candidates = selector.candidateOrder(
            from: snapshot.assets,
            settings: settings,
            now: now
        )
        SharedLog.app.info(
            "widget-cache",
            "Widget cache build started",
            metadata: [
                "algorithm": WidgetRenderPlanner.rendererVersion,
                "candidates": "\(candidates.count)",
                "entryTarget": "\(settings.widgetEntryCount)",
                "imageRequestPixels": "\(Self.sourceImageRequestPixelDimension)x\(Self.sourceImageRequestPixelDimension)",
                "networkAllowed": "false",
                "outputPixels": Self.outputPixelDescription,
                "targetBytesEach": Self.targetByteDescription
            ]
        )
        guard !candidates.isEmpty else {
            SharedLog.app.warning("widget-cache", "Widget cache has no eligible candidates")
            try clear()
            return WidgetCacheBuildResult(manifest: .empty, selectedIdentifiers: [])
        }

        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )

        var available: [(
            record: AssetRecord,
            filenames: WidgetCacheFilenames,
            byteCounts: [WidgetImageVariant: Int],
            sourcePixelSize: WidgetSourcePixelSize?,
            renderPlans: WidgetRenderPlans?
        )] = []
        let activeManifest = try? AtomicJSON.read(WidgetManifest.self, from: manifestURL)
        var generatedFileCount = 0
        var reusedFileCount = 0
        var unavailableAssetCount = 0
        var inputPixelWidths: [Int] = []
        var inputPixelHeights: [Int] = []
        var inputDecodedByteEstimates: [Int] = []
        var generatedCompositionCounts: [WidgetCompositionMode: Int] = [:]
        var renderUpscaledCounts: [WidgetImageVariant: Int] = [:]
        var maximumRenderScale: CGFloat = 0
        var marginFallbackDenominator = 0
        var current8Fallback = 0
        var legacy18Fallback = 0
        for record in candidates {
            try Task.checkCancellation()
            let filenames = Self.cacheFilenames(for: record)
            let missingSpecs = Self.RenderSpec.all.filter { spec in
                let filename = filenames.filename(for: spec.variant)
                let fileURL = cacheDirectory.appendingPathComponent(filename, isDirectory: false)
                return !FileManager.default.fileExists(atPath: fileURL.path)
            }
            let currentRendererActiveItem = activeManifest?.items.first(where: {
                $0.localIdentifier == record.localIdentifier
                    && $0.cacheFilenames == filenames
            })
            let reusableMetadata: (WidgetSourcePixelSize, WidgetRenderPlans)? =
                currentRendererActiveItem.flatMap { item in
                    guard item.rendererVersion == WidgetRenderPlanner.rendererVersion,
                          item.sourcePixelSize?.isValid == true,
                          item.renderPlans?.allAreValid == true,
                          item.sourceModificationDate == record.sourceModificationDate,
                          let size = item.sourcePixelSize,
                          let plans = item.renderPlans
                    else { return nil }
                    return (size, plans)
                }
            var renderMetadata = reusableMetadata

            if !missingSpecs.isEmpty || renderMetadata == nil {
                let output: (
                    files: [(
                        variant: WidgetImageVariant,
                        data: Data,
                        compositionMode: WidgetCompositionMode,
                        renderScale: CGFloat,
                        legacy18WouldFallback: Bool?
                    )],
                    sourcePixelSize: WidgetSourcePixelSize,
                    renderPlans: WidgetRenderPlans,
                    width: Int,
                    height: Int,
                    decodedByteEstimate: Int
                )? = autoreleasepool {
                    guard let image = imageLoader.image(
                        localIdentifier: record.localIdentifier,
                        targetSize: CGSize(
                            width: Self.sourceImageRequestPixelDimension,
                            height: Self.sourceImageRequestPixelDimension
                        ),
                        networkAccessAllowed: false,
                        contentMode: .aspectFit
                    ) else {
                        return nil
                    }

                    let normalized = WidgetSourceImageNormalizer.normalizedUIImage(image)
                    let sourcePixelSize = WidgetSourcePixelSize(
                        width: normalized.cgImage?.width
                            ?? max(1, Int(normalized.size.width.rounded())),
                        height: normalized.cgImage?.height
                            ?? max(1, Int(normalized.size.height.rounded()))
                    )
                    let renderPlans = WidgetRenderPlanner.plans(
                        visionBoundingBox: record.cat.boundingBox?.cgRect,
                        sourcePixelSize: sourcePixelSize
                    )
                    var files: [(
                        variant: WidgetImageVariant,
                        data: Data,
                        compositionMode: WidgetCompositionMode,
                        renderScale: CGFloat,
                        legacy18WouldFallback: Bool?
                    )] = []
                    for spec in missingSpecs {
                        let output: (
                            data: Data,
                            compositionMode: WidgetCompositionMode,
                            renderScale: CGFloat,
                            legacy18WouldFallback: Bool?
                        )? = autoreleasepool {
                            Self.widgetJPEG(
                                normalizedImage: normalized,
                                renderPlan: renderPlans.plan(for: spec.variant),
                                catBoundingBox: record.cat.boundingBox?.cgRect,
                                spec: spec
                            )
                        }
                        guard let output else {
                            return nil
                        }
                        files.append(
                            (
                                spec.variant,
                                output.data,
                                output.compositionMode,
                                output.renderScale,
                                output.legacy18WouldFallback
                            )
                        )
                    }
                    let width = image.cgImage?.width ?? Int(image.size.width * image.scale)
                    let height = image.cgImage?.height ?? Int(image.size.height * image.scale)
                    let decodedByteEstimate = image.cgImage.map {
                        $0.bytesPerRow * $0.height
                    } ?? (width * height * 4)
                    return (
                        files,
                        sourcePixelSize,
                        renderPlans,
                        width,
                        height,
                        decodedByteEstimate
                    )
                }
                if output == nil {
                    // The asset may have moved to iCloud since it was analyzed.
                    // Renderer-version changes deliberately produce different
                    // filenames, so `missingSpecs` says nothing about whether
                    // the currently published v5 family is complete. Match the
                    // active source identity independently and verify its exact
                    // three old files before retaining the published manifest.
                    if let activeManifest,
                       let retained = Self.retainedActiveManifestIfPhotoUnavailable(
                            activeManifest,
                            record: record,
                            cacheDirectory: cacheDirectory
                       ) {
                        SharedLog.app.warning(
                            "widget-cache",
                            "Retained complete legacy cache without sharing render metadata",
                            metadata: ["asset": SharedLog.shortHash(record.localIdentifier)]
                        )
                        // Do not rewrite its schedule or enter stale-file
                        // cleanup. Sharing alone waits for a later local v6
                        // render while the personal Widget keeps exact bytes.
                        return retained
                    } else {
                        // Keep walking candidates without downloading it. A
                        // partial family set is not safe to publish.
                        unavailableAssetCount += 1
                        continue
                    }
                }

                for file in output?.files ?? [] {
                    let filename = filenames.filename(for: file.variant)
                    let fileURL = cacheDirectory.appendingPathComponent(filename, isDirectory: false)
                    try file.data.write(to: fileURL, options: .atomic)
                    generatedCompositionCounts[file.compositionMode, default: 0] += 1
                    maximumRenderScale = max(maximumRenderScale, file.renderScale)
                    if file.renderScale > 1.001 {
                        renderUpscaledCounts[file.variant, default: 0] += 1
                    }
                    if let legacy18WouldFallback = file.legacy18WouldFallback {
                        marginFallbackDenominator += 1
                        if file.compositionMode == .blurredFitFallback {
                            current8Fallback += 1
                        }
                        if legacy18WouldFallback {
                            legacy18Fallback += 1
                        }
                    }
                    try? FileManager.default.setAttributes(
                        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                        ofItemAtPath: fileURL.path
                    )
                }
                if let output {
                    inputPixelWidths.append(output.width)
                    inputPixelHeights.append(output.height)
                    inputDecodedByteEstimates.append(output.decodedByteEstimate)
                    renderMetadata = (output.sourcePixelSize, output.renderPlans)
                }
            }

            var byteCounts: [WidgetImageVariant: Int] = [:]
            var filesAreAvailable = true
            for spec in Self.RenderSpec.all {
                let filename = filenames.filename(for: spec.variant)
                let fileURL = cacheDirectory.appendingPathComponent(filename, isDirectory: false)
                guard let existingByteCount = Self.byteCount(of: fileURL),
                      existingByteCount > 0,
                      existingByteCount <= spec.maximumJPEGByteCount else {
                    filesAreAvailable = false
                    break
                }
                byteCounts[spec.variant] = existingByteCount
            }
            guard filesAreAvailable,
                  byteCounts.count == Self.RenderSpec.all.count else {
                for filename in filenames.all {
                    try? FileManager.default.removeItem(
                        at: cacheDirectory.appendingPathComponent(filename, isDirectory: false)
                    )
                }
                unavailableAssetCount += 1
                continue
            }

            generatedFileCount += missingSpecs.count
            reusedFileCount += Self.RenderSpec.all.count - missingSpecs.count
            available.append(
                (record, filenames, byteCounts, renderMetadata?.0, renderMetadata?.1)
            )
            if available.count == settings.widgetEntryCount { break }
        }

        guard !available.isEmpty else {
            SharedLog.app.error(
                "widget-cache",
                "No local image could be written to the widget cache",
                metadata: ["unavailable": "\(unavailableAssetCount)"]
            )
            try clear()
            return WidgetCacheBuildResult(manifest: .empty, selectedIdentifiers: [])
        }

        // Keep each locally available photo once, even for a short library.
        // The provider loops this rotation itself; padding to the target count
        // repeats photos at the cycle boundary and inflates selection history.
        // Spread nearby captures only after local image failures and the
        // weighted selection cap, so neither can erase the intended spacing.
        let displayOrder = selector.widgetDisplayOrder(from: available, asset: { $0.record }, now: now)
        let items = PersonalWidgetRotationPolicy.orderedUniqueItems(
            from: displayOrder.enumerated().map { offset, item in
                WidgetManifestItem(
                    localIdentifier: item.record.localIdentifier,
                    cacheFilename: item.filenames.small,
                    cacheFilenames: item.filenames,
                    scheduledDate: now.addingTimeInterval(
                        TimeInterval(offset * settings.widgetEntryIntervalMinutes * 60)
                    ),
                    rendererVersion: item.renderPlans == nil ? nil : WidgetRenderPlanner.rendererVersion,
                    sourcePixelSize: item.sourcePixelSize,
                    renderPlans: item.renderPlans,
                    sourceModificationDate: item.renderPlans == nil ? nil : item.record.sourceModificationDate
                )
            }
        )

        let manifest = WidgetManifest(items: items, generatedAt: now)
        let historyURL = containerURL.appendingPathComponent(
            Self.historyFilename,
            isDirectory: false
        )

        // Finish every JPEG and protect both new and currently published files
        // before atomically replacing the manifest. This actor performs no await
        // while building, so build/clear cannot interleave through reentrancy.
        let timelineLeases = SharedContainer.allWidgetTimelineLeaseURLs.compactMap {
            try? AtomicJSON.read(WidgetTimelineLease.self, from: $0)
        }
        try Task.checkCancellation()
        try updateHistoryAndRemoveStaleFiles(
            newManifest: manifest,
            activeManifest: try? AtomicJSON.read(WidgetManifest.self, from: manifestURL),
            timelineLeases: timelineLeases,
            historyURL: historyURL,
            cacheDirectory: cacheDirectory
        )
        try AtomicJSON.write(manifest, to: manifestURL)

        let cachedByteCounts = available.flatMap { $0.byteCounts.values }
        let bytesByVariant = Dictionary(uniqueKeysWithValues: Self.RenderSpec.all.map { spec in
            let values = available.compactMap { $0.byteCounts[spec.variant] }
            return (
                "cacheBytes\(spec.variant.rawValue.capitalized)",
                "\(values.min() ?? 0)-\(values.max() ?? 0)"
            )
        })
        var completionMetadata: [String: String] = [
            "algorithm": WidgetRenderPlanner.rendererVersion,
            "cacheFileCap": "\(Self.maximumCachedFileCount)",
            "cacheGenerationCap": "\(Self.maximumGenerationCount)",
            "cacheBytesMax": "\(cachedByteCounts.max() ?? 0)",
            "cacheBytesMin": "\(cachedByteCounts.min() ?? 0)",
            "cacheBytesTotal": "\(cachedByteCounts.reduce(0, +))",
            "entries": "\(items.count)",
            "generatedFiles": "\(generatedFileCount)",
            "inputPixelsMax": Self.pixelRange(widths: inputPixelWidths, heights: inputPixelHeights),
            "inputDecodedBytesMax": "\(inputDecodedByteEstimates.max() ?? 0)",
            "current8Fallback": "\(current8Fallback)",
            "legacy18Fallback": "\(legacy18Fallback)",
            "marginFallbackDenominator": "\(marginFallbackDenominator)",
            "marginComparisonScope": "generated-small-large",
            "renderScaleMax": String(format: "%.4f", maximumRenderScale),
            "outputPixels": Self.outputPixelDescription,
            "reusedFiles": "\(reusedFileCount)",
            "targetBytesEach": Self.targetByteDescription,
            "retainedCacheWorstCaseBytes": "\(Self.maximumRetainedCacheByteUpperBound)",
            "unavailable": "\(unavailableAssetCount)",
            "uniqueAssets": "\(available.count)",
            "uniqueFiles": "\(available.count * Self.RenderSpec.all.count)"
        ]
        completionMetadata.merge(bytesByVariant) { current, _ in current }
        for spec in Self.RenderSpec.all {
            completionMetadata["renderUpscaled\(spec.variant.rawValue.capitalized)"] =
                "\(renderUpscaledCounts[spec.variant, default: 0])"
        }
        for mode in WidgetCompositionMode.allCases {
            completionMetadata[mode.generatedMetadataKey] = "\(generatedCompositionCounts[mode, default: 0])"
        }
        SharedLog.app.info(
            "widget-cache",
            "Widget cache build completed",
            metadata: completionMetadata
        )

        return WidgetCacheBuildResult(
            manifest: manifest,
            selectedIdentifiers: items.map(\.localIdentifier)
        )
    }

    /// Publishes only one locally moderated family photo into a namespace that
    /// personal Widget cleanup never reads or removes. The lifecycle token is
    /// checked both before decoding and at the final JPEG+manifest commit.
    func buildFamilyWindow(
        from item: MomentInboxItem?,
        freshUntil: Date?,
        windowDisplayName: String,
        validating lifecycleToken: SharingLifecycleGate.Token,
        now: Date = .now
    ) throws -> FamilyWidgetManifest {
        let resolvedWindowDisplayName = PrivateWindowDisplayName.resolved(
            windowDisplayName
        )
        guard let item, let freshUntil else {
            return try clearFamilyWindow(
                validating: lifecycleToken,
                generatedAt: now,
                windowDisplayName: resolvedWindowDisplayName
            )
        }
        guard let manifestURL = SharedContainer.familyWidgetManifestURL,
              let cacheDirectory = SharedContainer.familyWidgetCacheDirectoryURL,
              let historyURL = SharedContainer.familyWidgetCacheHistoryURL
        else {
            throw NekoWidgetError.appGroupUnavailable(SharedContainer.appGroupIdentifier)
        }

        let source: FamilyWidgetSourceSnapshot
        do {
            source = try MomentSharingStateStore.withStateWhileLifecycleLocked(
                validating: lifecycleToken
            ) { state in
                try Self.familySourceSnapshot(for: item, in: state)
            }
        } catch {
            return try clearFamilyWindow(
                validating: lifecycleToken,
                generatedAt: now,
                windowDisplayName: resolvedWindowDisplayName
            )
        }
        let filenames = Self.familyCacheFilenames(sourceDigest: source.sourceDigest)
        if let active = try? AtomicJSON.read(FamilyWidgetManifest.self, from: manifestURL),
           active.schemaVersion == FamilyWidgetManifest.schemaVersion,
           active.item?.sourceDigest == source.sourceDigest,
           active.item?.momentID == source.item.id,
           active.item?.receivedAt == source.item.receivedAt,
           active.item?.freshUntil == freshUntil,
           active.item?.cacheFilenames == filenames,
           Self.hasCompleteFamilyWidgetFiles(
                filenames,
                cacheDirectory: cacheDirectory
           ) {
            let reusable = try MomentSharingStateStore.withStateWhileLifecycleLocked(
                validating: lifecycleToken
            ) { state in
                guard let current = try? Self.familySourceSnapshot(for: item, in: state),
                      current.sourceDigest == source.sourceDigest,
                      var refreshedItem = active.item
                else { return nil as FamilyWidgetManifest? }
                let currentCaption = try MomentCaption.normalized(current.item.caption)
                let requiresManifestRefresh = active.windowDisplayName
                    != resolvedWindowDisplayName
                    || refreshedItem.heartExpiresAt != current.item.accessExpiresAt
                    || refreshedItem.caption != currentCaption
                guard requiresManifestRefresh else {
                    return active
                }
                refreshedItem.heartExpiresAt = current.item.accessExpiresAt
                refreshedItem.caption = currentCaption
                var refreshed = active
                refreshed.item = refreshedItem
                refreshed.windowDisplayName = resolvedWindowDisplayName
                refreshed.generatedAt = now
                try Self.writeSharingJSON(refreshed, to: manifestURL)
                return refreshed
            }
            if let reusable { return reusable }
        }

        let renderedFiles: [(variant: WidgetImageVariant, data: Data)] = try autoreleasepool {
            guard let image = UIImage(data: source.data),
                  Self.isCanonicalFamilyJPEG(source.data)
            else { throw MomentSharingError.invalidPayload }
            let normalized = WidgetSourceImageNormalizer.normalizedUIImage(image)
            let sourcePixelSize = WidgetSourcePixelSize(
                width: normalized.cgImage?.width
                    ?? max(1, Int(normalized.size.width.rounded())),
                height: normalized.cgImage?.height
                    ?? max(1, Int(normalized.size.height.rounded()))
            )
            guard sourcePixelSize.isValid,
                  sourcePixelSize.width <= MomentSharingProtocol.maximumCanonicalPixelDimension,
                  sourcePixelSize.height <= MomentSharingProtocol.maximumCanonicalPixelDimension
            else { throw MomentSharingError.invalidPayload }
            let catBoundingBox = Self.familyCatBoundingBox(in: normalized)
            let renderPlans = WidgetRenderPlans(
                small: WidgetRenderPlanner.focusedFullBleedPlan(
                    visionBoundingBox: catBoundingBox,
                    sourcePixelSize: sourcePixelSize,
                    variant: .small
                ),
                medium: WidgetRenderPlanner.focusedFullBleedPlan(
                    visionBoundingBox: catBoundingBox,
                    sourcePixelSize: sourcePixelSize,
                    variant: .medium
                ),
                large: WidgetRenderPlanner.focusedFullBleedPlan(
                    visionBoundingBox: catBoundingBox,
                    sourcePixelSize: sourcePixelSize,
                    variant: .large
                )
            )
            return try Self.RenderSpec.all.map { spec in
                guard let output = Self.widgetJPEG(
                    normalizedImage: normalized,
                    renderPlan: renderPlans.plan(for: spec.variant),
                    catBoundingBox: catBoundingBox,
                    spec: spec
                ) else { throw MomentSharingError.invalidPayload }
                return (variant: spec.variant, data: output.data)
            }
        }

        return try MomentSharingStateStore.withStateWhileLifecycleLocked(
            validating: lifecycleToken
        ) { state in
            guard let current = try? Self.familySourceSnapshot(for: item, in: state),
                  current.sourceDigest == source.sourceDigest,
                  Data(SHA256.hash(data: current.data))
                    == Data(SHA256.hash(data: source.data))
            else {
                return try Self.clearFamilyWindowWhileLifecycleLocked(
                    manifestURL: manifestURL,
                    cacheDirectory: cacheDirectory,
                    historyURL: historyURL,
                    generatedAt: now,
                    windowDisplayName: resolvedWindowDisplayName
                )
            }

            for file in renderedFiles {
                let filename = filenames.filename(for: file.variant)
                try SharingSecureFile.write(
                    file.data,
                    to: cacheDirectory.appendingPathComponent(filename, isDirectory: false)
                )
            }
            guard Self.hasCompleteFamilyWidgetFiles(
                filenames,
                cacheDirectory: cacheDirectory
            ) else { throw MomentSharingError.stateUnavailable }

            let manifest = FamilyWidgetManifest(
                item: FamilyWidgetManifestItem(
                    sourceDigest: current.sourceDigest,
                    momentID: current.item.id,
                    cacheFilenames: filenames,
                    receivedAt: current.item.receivedAt,
                    freshUntil: freshUntil,
                    heartExpiresAt: current.item.accessExpiresAt,
                    caption: try MomentCaption.normalized(current.item.caption)
                ),
                windowDisplayName: resolvedWindowDisplayName,
                generatedAt: now
            )
            try Self.writeSharingJSON(manifest, to: manifestURL)
            try Self.updateFamilyHistoryAndRemoveStaleFiles(
                manifest: manifest,
                state: state,
                historyURL: historyURL,
                cacheDirectory: cacheDirectory,
                now: now
            )
            SharedLog.app.info(
                "family-widget-cache",
                "Family Widget cache published",
                metadata: ["files": "\(renderedFiles.count)"]
            )
            return manifest
        }
    }

    /// Resolves an exact action URL emitted by a still-visible Widget entry.
    /// The active manifest covers the current entry; the small, time-bounded
    /// history covers an older WidgetKit timeline whose rendered photo is still
    /// on screen. History grants no authority by itself: the digest must also
    /// map uniquely to a lifecycle-safe inbox item and its canonical JPEG.
    static func retainedFamilyMomentID(
        forSourceDigest sourceDigest: String,
        localWindowID: String,
        now: Date = .now,
        validating lifecycleToken: SharingLifecycleGate.Token
    ) throws -> String? {
        guard let windowUUID = UUID(uuidString: localWindowID),
              windowUUID.uuidString.lowercased() == localWindowID.lowercased(),
              isLowercaseFamilySourceDigest(sourceDigest),
              let manifestURL = SharedContainer.familyWidgetManifestURL(
                localWindowID: localWindowID
              ),
              let historyURL = SharedContainer.familyWidgetCacheHistoryURL(
                localWindowID: localWindowID
              )
        else { return nil }

        let currentManifestMomentID: String? = {
            guard let manifest = try? AtomicJSON.read(
                    FamilyWidgetManifest.self,
                    from: manifestURL
                  ),
                  manifest.schemaVersion == FamilyWidgetManifest.schemaVersion,
                  let item = manifest.item,
                  item.sourceDigest == sourceDigest,
                  item.hasValidBookmarkTarget
            else { return nil }
            return item.momentID
        }()

        let retainedByHistory: Bool = {
            guard let history = try? AtomicJSON.read(
                    FamilyWidgetCacheHistory.self,
                    from: historyURL
                  ),
                  history.generations.count <= maximumFamilyGenerationCount
            else { return false }
            let cutoff = now.addingTimeInterval(-12 * 60 * 60)
            let futureLimit = now.addingTimeInterval(5 * 60)
            let digests = history.generations.map(\.sourceDigest)
            guard Set(digests).count == digests.count,
                  history.generations.allSatisfy({ generation in
                    isLowercaseFamilySourceDigest(generation.sourceDigest)
                        && generation.cacheFilenames == familyCacheFilenames(
                            sourceDigest: generation.sourceDigest
                        )
                        && generation.generatedAt >= cutoff
                        && generation.generatedAt <= futureLimit
                  })
            else { return false }
            return history.generations.contains { $0.sourceDigest == sourceDigest }
        }()

        guard currentManifestMomentID != nil || retainedByHistory else { return nil }
        return try MomentSharingStateStore.withStateWhileLifecycleLocked(
            validating: lifecycleToken
        ) { state in
            guard PrivateWindowCatalogStore.activeEntry()?.localWindowID
                    == windowUUID.uuidString.lowercased()
            else { return nil }
            let identityMatches = state.inbox.filter {
                Self.familySourceDigest(for: $0) == sourceDigest
            }
            guard identityMatches.count == 1,
                  let target = identityMatches.first,
                  currentManifestMomentID == nil
                    || currentManifestMomentID == target.id
                    || retainedByHistory,
                  let snapshot = try? Self.familySourceSnapshot(
                    for: target,
                    in: state
                  ),
                  snapshot.sourceDigest == sourceDigest
            else { return nil }
            return target.id
        }
    }

    @discardableResult
    func clearFamilyWindow(
        validating lifecycleToken: SharingLifecycleGate.Token,
        generatedAt: Date = .now,
        windowDisplayName: String? = nil
    ) throws -> FamilyWidgetManifest {
        guard let manifestURL = SharedContainer.familyWidgetManifestURL,
              let cacheDirectory = SharedContainer.familyWidgetCacheDirectoryURL,
              let historyURL = SharedContainer.familyWidgetCacheHistoryURL
        else {
            throw NekoWidgetError.appGroupUnavailable(SharedContainer.appGroupIdentifier)
        }
        return try SharingLifecycleGate.withValidatedToken(lifecycleToken) {
            try Self.clearFamilyWindowWhileLifecycleLocked(
                manifestURL: manifestURL,
                cacheDirectory: cacheDirectory,
                historyURL: historyURL,
                generatedAt: generatedAt,
                windowDisplayName: windowDisplayName.map {
                    PrivateWindowDisplayName.resolved($0)
                }
            )
        }
    }

    func clearPersonal(expectedRevision: String) throws {
        try PersonalRediscoveryStore.shared.withProtectedCacheFiles(expectedRevision: expectedRevision) { _ in
            try clear()
        }
    }

    func clear() throws {
        guard let containerURL = SharedContainer.containerURL,
              let cacheDirectory = SharedContainer.widgetCacheDirectoryURL,
              let manifestURL = SharedContainer.widgetManifestURL else {
            throw NekoWidgetError.appGroupUnavailable(SharedContainer.appGroupIdentifier)
        }

        // Commit the empty manifest before removing its former dependencies.
        try AtomicJSON.write(WidgetManifest.empty, to: manifestURL)
        let historyURL = containerURL.appendingPathComponent(
            Self.historyFilename,
            isDirectory: false
        )
        try? FileManager.default.removeItem(at: historyURL)
        for leaseURL in SharedContainer.allWidgetTimelineLeaseURLs {
            try? FileManager.default.removeItem(at: leaseURL)
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
        SharedLog.app.info("widget-cache", "Widget cache and manifest cleared")
    }

    private static func familySourceSnapshot(
        for expected: MomentInboxItem,
        in state: MomentSharingState
    ) throws -> FamilyWidgetSourceSnapshot {
        guard let current = state.inbox.first(where: { $0.id == expected.id }),
              current.state == .available || current.state == .acknowledged,
              current.senderParticipantID == expected.senderParticipantID,
              current.committedAt == expected.committedAt,
              current.receivedAt == expected.receivedAt,
              let filename = current.localJPEGFileName,
              filename == "\(current.id).jpg",
              filename == (filename as NSString).lastPathComponent,
              let directory = SharedContainer.momentSharingReceivedDirectoryURL
        else { throw MomentSharingError.stateUnavailable }
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty,
              data.count <= MomentSharingProtocol.maximumMediaCiphertextBytes - 28,
              isCanonicalFamilyJPEG(data)
        else { throw MomentSharingError.invalidPayload }
        return FamilyWidgetSourceSnapshot(
            item: current,
            data: data,
            sourceDigest: familySourceDigest(for: current)
        )
    }

    private static func familySourceDigest(for item: MomentInboxItem) -> String {
        let identity = [
            "family-widget-v3-cat-focused-full-bleed",
            item.id,
            String(item.committedAt.timeIntervalSinceReferenceDate.bitPattern, radix: 16),
            String(item.receivedAt.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
        ].joined(separator: "|")
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// One best-effort, on-device pass for the single received photo being
    /// published. Detection failure keeps the existing centered full-bleed
    /// result; it never blocks receipt or sends geometry off the device.
    private static func familyCatBoundingBox(in image: UIImage) -> CGRect? {
        guard let cgImage = image.cgImage else { return nil }
        let request = VNRecognizeAnimalsRequest()
#if targetEnvironment(simulator)
        request.usesCPUOnly = true
#endif
        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:])
                .perform([request])
        } catch {
            return nil
        }
        let boxes = (request.results ?? []).compactMap { observation -> CGRect? in
            guard observation.labels.contains(where: {
                $0.identifier.caseInsensitiveCompare("cat") == .orderedSame
                    && $0.confidence >= 0.70
            }) else { return nil }
            return observation.boundingBox
        }
        guard !boxes.isEmpty else { return nil }
        return boxes.reduce(CGRect.null) { $0.union($1) }
    }

    private static func isLowercaseFamilySourceDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func familyCacheFilenames(
        sourceDigest: String
    ) -> WidgetCacheFilenames {
        WidgetCacheFilenames(
            small: "family-small-\(sourceDigest).jpg",
            medium: "family-medium-\(sourceDigest).jpg",
            large: "family-large-\(sourceDigest).jpg"
        )
    }

    private static func isCanonicalFamilyJPEG(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
        CGImageSourceGetCount(source) == 1,
        CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int,
        (1...MomentSharingProtocol.maximumCanonicalPixelDimension).contains(width),
        (1...MomentSharingProtocol.maximumCanonicalPixelDimension).contains(height)
        else { return false }
        return true
    }

    private static func hasCompleteFamilyWidgetFiles(
        _ filenames: WidgetCacheFilenames,
        cacheDirectory: URL
    ) -> Bool {
        RenderSpec.all.allSatisfy { spec in
            let filename = filenames.filename(for: spec.variant)
            guard filename == (filename as NSString).lastPathComponent,
                  filename.lowercased().hasSuffix(".jpg")
            else { return false }
            let url = cacheDirectory.appendingPathComponent(filename, isDirectory: false)
            guard let count = byteCount(of: url) else { return false }
            return count > 0 && count <= spec.maximumJPEGByteCount
        }
    }

    private static func clearFamilyWindowWhileLifecycleLocked(
        manifestURL: URL,
        cacheDirectory: URL,
        historyURL: URL,
        generatedAt: Date,
        windowDisplayName: String?
    ) throws -> FamilyWidgetManifest {
        let manifest = FamilyWidgetManifest(
            item: nil,
            windowDisplayName: windowDisplayName,
            generatedAt: generatedAt
        )
        // Remove renderable bytes first. If the subsequent empty-manifest
        // commit fails, a stale manifest can only point at missing files.
        // Still attempt both operations so either one independently closes
        // the display path, and report any cleanup failure to the caller.
        var cacheRemovalError: Error?
        if FileManager.default.fileExists(atPath: cacheDirectory.path) {
            do {
                try FileManager.default.removeItem(at: cacheDirectory)
            } catch {
                cacheRemovalError = error
            }
        }
        try? FileManager.default.removeItem(at: historyURL)
        do {
            try writeSharingJSON(manifest, to: manifestURL)
        } catch {
            // Cache removal may already have made the stale manifest
            // unreadable, but callers still need the I/O failure.
            throw error
        }
        if let cacheRemovalError {
            // The committed empty manifest prevents presentation even when
            // best-effort deletion of old JPEG bytes did not complete.
            throw cacheRemovalError
        }
        SharedLog.app.info("family-widget-cache", "Family Widget cache cleared")
        return manifest
    }

    private static func updateFamilyHistoryAndRemoveStaleFiles(
        manifest: FamilyWidgetManifest,
        state: MomentSharingState,
        historyURL: URL,
        cacheDirectory: URL,
        now: Date
    ) throws {
        guard let item = manifest.item else { return }
        let oldHistory = (try? AtomicJSON.read(
            FamilyWidgetCacheHistory.self,
            from: historyURL
        )) ?? .empty
        // History is capped at four generations. Restrict source decoding to
        // those few digests (plus the just-published one) so the lifecycle
        // transaction never scans every JPEG in a large inbox.
        let retainedCandidateDigests = Set(
            oldHistory.generations.map(\.sourceDigest) + [item.sourceDigest]
        )
        let safeDigests = Set(state.inbox.compactMap { candidate -> String? in
            // Old Widget timelines may retain a prior generation only while
            // its source is still both lifecycle-safe and a canonical JPEG.
            // Existence alone is insufficient: corruption must revoke the
            // old generation just like blocked/revoked state does.
            guard retainedCandidateDigests.contains(familySourceDigest(for: candidate))
            else { return nil }
            return try? familySourceSnapshot(for: candidate, in: state).sourceDigest
        })
        let newest = FamilyWidgetCacheGeneration(
            sourceDigest: item.sourceDigest,
            cacheFilenames: item.cacheFilenames,
            generatedAt: manifest.generatedAt
        )
        let cutoff = now.addingTimeInterval(-12 * 60 * 60)
        let generations = ([newest] + oldHistory.generations)
            .filter { $0.generatedAt >= cutoff && safeDigests.contains($0.sourceDigest) }
            .reduce(into: [FamilyWidgetCacheGeneration]()) { result, candidate in
                guard !result.contains(where: { $0.sourceDigest == candidate.sourceDigest }),
                      result.count < maximumFamilyGenerationCount
                else { return }
                result.append(candidate)
            }
        try writeSharingJSON(
            FamilyWidgetCacheHistory(generations: generations),
            to: historyURL
        )
        let retained = Set(generations.flatMap { $0.cacheFilenames.all })
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in contents where !retained.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func writeSharingJSON<Value: Encodable>(
        _ value: Value,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try SharingSecureFile.write(try encoder.encode(value), to: url)
    }

    private func updateHistoryAndRemoveStaleFiles(
        newManifest: WidgetManifest,
        activeManifest: WidgetManifest?,
        timelineLeases: [WidgetTimelineLease],
        historyURL: URL,
        cacheDirectory: URL
    ) throws {
        let oldHistory = (try? AtomicJSON.read(WidgetCacheHistory.self, from: historyURL)) ?? .empty
        var proposed = [generation(for: newManifest)]
        for timelineLease in timelineLeases {
            proposed.append(
                WidgetCacheGeneration(
                    generatedAt: timelineLease.recordedAt,
                    filenames: timelineLease.cacheFilenames
                )
            )
        }
        if let activeManifest {
            proposed.append(generation(for: activeManifest))
        }
        // A pre-lease widget may still hold the oldest timeline in a rapid
        // rebuild burst. Pin that generation during the maximum 30-minute x 20
        // entry horizon plus margin, while the hard file/generation caps remain.
        let graceCutoff = newManifest.generatedAt.addingTimeInterval(-12 * 60 * 60)
        if let oldestGraceGeneration = oldHistory.generations
            .filter({ $0.generatedAt >= graceCutoff })
            .min(by: { $0.generatedAt < $1.generatedAt }) {
            proposed.append(oldestGraceGeneration)
        }
        proposed.append(contentsOf: oldHistory.generations)

        var retained: [WidgetCacheGeneration] = []
        var retainedFiles: Set<String> = []
        for candidate in proposed {
            guard retained.count < Self.maximumGenerationCount else { break }
            let filenames = Array(Set(candidate.filenames)).filter { filename in
                guard filename == (filename as NSString).lastPathComponent,
                      filename.lowercased().hasSuffix(".jpg") || filename.lowercased().hasSuffix(".jpeg") else {
                    return false
                }
                let url = cacheDirectory.appendingPathComponent(filename, isDirectory: false)
                return FileManager.default.fileExists(atPath: url.path)
            }.sorted()
            guard !filenames.isEmpty else { continue }
            let additions = Set(filenames).subtracting(retainedFiles)
            guard retainedFiles.count + additions.count <= Self.maximumCachedFileCount else {
                continue
            }
            guard !retained.contains(where: { $0.filenames == filenames }) else { continue }
            retained.append(
                WidgetCacheGeneration(
                    generatedAt: candidate.generatedAt,
                    filenames: filenames
                )
            )
            retainedFiles.formUnion(filenames)
        }

        try AtomicJSON.write(WidgetCacheHistory(generations: retained), to: historyURL)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in contents where !retainedFiles.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func generation(for manifest: WidgetManifest) -> WidgetCacheGeneration {
        WidgetCacheGeneration(
            generatedAt: manifest.generatedAt,
            filenames: manifest.items.flatMap(\.allCacheFilenames)
        )
    }

    /// Returns the exact already-published manifest only after proving that
    /// the unavailable PhotoKit source is one of its active items and that
    /// every active item still has three bounded family JPEGs. This check is
    /// intentionally independent of the current renderer's cache filenames.
    private static func retainedActiveManifestIfPhotoUnavailable(
        _ activeManifest: WidgetManifest,
        record: AssetRecord,
        cacheDirectory: URL
    ) -> WidgetCacheBuildResult? {
        guard !activeManifest.items.isEmpty,
              activeManifest.items.contains(where: {
                  guard $0.localIdentifier == record.localIdentifier else { return false }
                  // Pre-modification-date manifests can only bind by PhotoKit
                  // identifier. Once a date was persisted, require it exactly.
                  guard let activeDate = $0.sourceModificationDate else { return true }
                  return activeDate == record.sourceModificationDate
              }),
              activeManifest.items.allSatisfy({
                  hasCompleteFamilyFiles(for: $0, cacheDirectory: cacheDirectory)
              })
        else { return nil }
        return WidgetCacheBuildResult(
            manifest: activeManifest,
            selectedIdentifiers: activeManifest.items.map(\.localIdentifier)
        )
    }

    private static func hasCompleteFamilyFiles(
        for item: WidgetManifestItem,
        cacheDirectory: URL
    ) -> Bool {
        guard let filenames = item.cacheFilenames,
              Set(filenames.all).count == RenderSpec.all.count
        else { return false }
        return RenderSpec.all.allSatisfy { spec in
            let filename = filenames.filename(for: spec.variant)
            guard filename == URL(fileURLWithPath: filename).lastPathComponent,
                  !filename.contains("/"),
                  !filename.contains("\\")
            else { return false }
            let fileURL = cacheDirectory.appendingPathComponent(filename, isDirectory: false)
            guard let count = byteCount(of: fileURL) else { return false }
            return count > 0 && count <= spec.maximumJPEGByteCount
        }
    }

#if DEBUG
    /// DEBUG smoke seam for the exact production migration decision. A nil
    /// PhotoKit result reaches this helper in `build`; the test supplies a v5
    /// manifest and old family files without introducing a second algorithm.
    static func runtimeSelfTestRetainedActiveManifestIfPhotoUnavailable(
        _ activeManifest: WidgetManifest,
        record: AssetRecord,
        cacheDirectory: URL
    ) -> WidgetCacheBuildResult? {
        retainedActiveManifestIfPhotoUnavailable(
            activeManifest,
            record: record,
            cacheDirectory: cacheDirectory
        )
    }

    static func runtimeSelfTestCurrentCacheFilenames(
        for record: AssetRecord
    ) -> WidgetCacheFilenames {
        cacheFilenames(for: record)
    }

    static func runtimeSelfTestRecoveredPersonalCache(
        from records: [AssetRecord], cacheDirectory: URL, now: Date
    ) -> [PersonalRediscoveryCandidate] {
        recoverUnindexedPersonalCache(from: records, cacheDirectory: cacheDirectory, now: now)
    }

    /// Exercises the production JPEG path without PhotoKit or cache publication.
    /// The supplied plan remains the manifest's canonical sharing geometry.
    static func runtimeSelfTestPersonalWidgetJPEG(
        image: UIImage,
        renderPlan: WidgetFamilyRenderPlan,
        catBoundingBox: CGRect?,
        variant: WidgetImageVariant
    ) -> Data? {
        widgetJPEG(
            normalizedImage: image,
            renderPlan: renderPlan,
            catBoundingBox: catBoundingBox,
            spec: RenderSpec.spec(for: variant)
        )?.data
    }
#endif

    private static func cacheFilenames(for record: AssetRecord) -> WidgetCacheFilenames {
        WidgetCacheFilenames(
            small: cacheFilename(for: record, variant: .small),
            medium: cacheFilename(for: record, variant: .medium),
            large: cacheFilename(for: record, variant: .large)
        )
    }

    private static func cacheFilename(
        for record: AssetRecord,
        variant: WidgetImageVariant
    ) -> String {
        let boundingBoxIdentity: String
        if let box = record.cat.boundingBox {
            boundingBoxIdentity = [box.x, box.y, box.width, box.height]
                .map { String($0.bitPattern, radix: 16) }
                .joined(separator: ":")
        } else {
            boundingBoxIdentity = "no-bounding-box"
        }
        let modificationIdentity = record.sourceModificationDate.map {
            String($0.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
        } ?? "no-modification-date"
        let identity = [
            WidgetRenderPlanner.rendererVersion,
            Self.cacheRenderingRevision,
            variant.rawValue,
            RenderSpec.spec(for: variant).pixelDescription,
            record.localIdentifier,
            record.analysisFingerprint,
            boundingBoxIdentity,
            modificationIdentity
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
        let hexadecimal = digest.map { String(format: "%02x", $0) }.joined()
        return "asset-\(WidgetRenderPlanner.rendererVersion)-\(variant.rawValue)-\(hexadecimal).jpg"
    }

    private static func byteCount(of url: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let offset = try? handle.seekToEnd() else { return nil }
        return Int(exactly: offset)
    }

    private static func pixelRange(widths: [Int], heights: [Int]) -> String {
        guard let minimumWidth = widths.min(),
              let maximumWidth = widths.max(),
              let minimumHeight = heights.min(),
              let maximumHeight = heights.max() else {
            return "cached-only"
        }
        return "\(minimumWidth)x\(minimumHeight)-\(maximumWidth)x\(maximumHeight)"
    }

    private static var outputPixelDescription: String {
        RenderSpec.all
            .map { "\($0.variant.rawValue):\($0.pixelDescription)" }
            .joined(separator: ",")
    }

    private static var targetByteDescription: String {
        RenderSpec.all
            .map { "\($0.variant.rawValue):\($0.maximumJPEGByteCount)" }
            .joined(separator: ",")
    }

    private static var maximumRetainedCacheByteUpperBound: Int {
        let largestFileBudget = RenderSpec.all.map(\.maximumJPEGByteCount).max() ?? 0
        return maximumCachedFileCount * largestFileBudget
    }

    /// Produces a family-sized JPEG that fills the canvas with a sharp crop
    /// guided only by the existing cat union. Small and Large preserve the cat
    /// plus margin when possible and otherwise keep the detected cat centered.
    /// Missing or invalid cat geometry keeps the centered sharp fill.
    /// Medium remains full-bleed and favors the upper
    /// part of an oversized cat union. No face detection, subject lifting, or
    /// semantic composition runs here or in the Widget extension.
    private static func widgetJPEG(
        normalizedImage image: UIImage,
        renderPlan: WidgetFamilyRenderPlan,
        catBoundingBox: CGRect?,
        spec: RenderSpec
    ) -> (
        data: Data,
        compositionMode: WidgetCompositionMode,
        renderScale: CGFloat,
        legacy18WouldFallback: Bool?
    )? {
        // The persisted plan is canonical sharing metadata; the existing local
        // fallback already renders a sharp fill instead of its legacy wire mode.
        // Resolve only that local display crop here. Never replace renderPlan or
        // the manifest metadata consumed by DailyManifestFreezer/canonical binding.
        // Received-photo plans already specify full bleed and do not enter this.
        let displayPlan: WidgetFamilyRenderPlan
        if (spec.variant == .small || spec.variant == .large),
           renderPlan.compositionMode == .blurredFitFallback {
            displayPlan = WidgetRenderPlanner.focusedFullBleedPlan(
                visionBoundingBox: catBoundingBox,
                sourcePixelSize: WidgetSourcePixelSize(
                    width: max(1, Int(image.size.width.rounded())),
                    height: max(1, Int(image.size.height.rounded()))
                ),
                variant: spec.variant
            )
        } else {
            displayPlan = renderPlan
        }
        let rendered = renderedWidgetImage(
            image: image,
            renderPlan: displayPlan,
            size: spec.size
        )
        guard let data = jpegData(
            rendered.image,
            targetByteCount: spec.maximumJPEGByteCount
        ) else {
            return nil
        }
        let legacy18WouldFallback: Bool?
        if spec.variant == .small || spec.variant == .large {
            legacy18WouldFallback = WidgetRenderPlanner.plan(
                visionBoundingBox: catBoundingBox,
                sourcePixelSize: WidgetSourcePixelSize(
                    width: max(1, Int(image.size.width.rounded())),
                    height: max(1, Int(image.size.height.rounded()))
                ),
                variant: spec.variant,
                marginFraction: WidgetRenderPlanner.legacyCatMarginFraction
            ).compositionMode == .blurredFitFallback
        } else {
            legacy18WouldFallback = nil
        }
        return (
            data,
            // Preserve the canonical fallback classification used by existing
            // diagnostics; renderScale describes the actual local display crop.
            renderPlan.compositionMode,
            rendered.renderScale,
            legacy18WouldFallback
        )
    }

    private static func renderedWidgetImage(
        image: UIImage,
        renderPlan: WidgetFamilyRenderPlan,
        size: CGSize
    ) -> (image: UIImage, compositionMode: WidgetCompositionMode, renderScale: CGFloat) {
        if renderPlan.compositionMode != .blurredFitFallback {
            let normalizedRect = renderPlan.sourceRect.cgRect
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(
                    in: drawRect(
                        imageSize: image.size,
                        normalizedCropRect: normalizedRect,
                        canvasSize: size
                    )
                )
            }
            return (
                rendered,
                renderPlan.compositionMode,
                renderScale(
                    imageSize: image.size,
                    normalizedCropRect: normalizedRect,
                    canvasSize: size
                )
            )
        }

        // `blurredFitFallback` remains a wire-compatible plan value for older
        // sharing records, but the product display no longer letterboxes a
        // photo. A centered aspect-fill is deterministic and always edge-to-edge.
        let rendered = aspectFillImage(image, size: size)
        return (
            rendered,
            .blurredFitFallback,
            aspectFillScale(imageSize: image.size, canvasSize: size)
        )
    }

    private static func drawRect(
        imageSize: CGSize,
        normalizedCropRect: CGRect,
        canvasSize: CGSize
    ) -> CGRect {
        let cropWidth = normalizedCropRect.width * imageSize.width
        let cropHeight = normalizedCropRect.height * imageSize.height
        guard cropWidth > 0, cropHeight > 0 else {
            return CGRect(origin: .zero, size: canvasSize)
        }
        let scale = max(canvasSize.width / cropWidth, canvasSize.height / cropHeight)
        return CGRect(
            x: -normalizedCropRect.minX * imageSize.width * scale,
            y: -normalizedCropRect.minY * imageSize.height * scale,
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
    }

    private static func renderScale(
        imageSize: CGSize,
        normalizedCropRect: CGRect,
        canvasSize: CGSize
    ) -> CGFloat {
        let cropWidth = normalizedCropRect.width * imageSize.width
        let cropHeight = normalizedCropRect.height * imageSize.height
        guard cropWidth > 0, cropHeight > 0 else { return .infinity }
        return max(canvasSize.width / cropWidth, canvasSize.height / cropHeight)
    }

    private static func aspectFillImage(_ image: UIImage, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: aspectFillRect(imageSize: image.size, canvasSize: size))
        }
    }

    private static func aspectFillRect(imageSize: CGSize, canvasSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: canvasSize)
        }
        let scale = aspectFillScale(imageSize: imageSize, canvasSize: canvasSize)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (canvasSize.width - drawSize.width) / 2,
            y: (canvasSize.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
    }

    private static func aspectFillScale(imageSize: CGSize, canvasSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return .infinity }
        return max(canvasSize.width / imageSize.width, canvasSize.height / imageSize.height)
    }

    private static func jpegData(_ image: UIImage, targetByteCount: Int) -> Data? {
        guard let minimum = image.jpegData(compressionQuality: 0),
              minimum.count <= targetByteCount else {
            return nil
        }
        var low: CGFloat = 0
        var high: CGFloat = 0.92
        var best: Data? = minimum
        for _ in 0..<10 {
            let quality = (low + high) / 2
            guard let candidate = image.jpegData(compressionQuality: quality) else { return nil }
            if candidate.count <= targetByteCount {
                best = candidate
                low = quality
            } else {
                high = quality
            }
        }
        return best
    }
}
