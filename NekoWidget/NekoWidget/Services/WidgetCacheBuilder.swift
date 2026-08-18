import CryptoKit
import CoreImage
import Foundation
import UIKit

struct WidgetCacheBuildResult: Sendable {
    var manifest: WidgetManifest
    var selectedIdentifiers: [String]
}

private struct WidgetCacheGeneration: Codable, Equatable, Sendable {
    var generatedAt: Date
    var filenames: [String]
}

private struct WidgetCacheHistory: Codable, Sendable {
    var generations: [WidgetCacheGeneration]

    static let empty = WidgetCacheHistory(generations: [])
}

actor WidgetCacheBuilder {
    private static let historyFilename = "widget-cache-history.json"
    /// The migration-safe maximum is 380 distinct files: new manifest 60,
    /// previous active manifest 60, grace generation 60, three pre-Build-8
    /// family leases of up to 60 each, and the Build-4 legacy lease of 20.
    /// Round to 400; the bounded provider writes at most 2 files per family lease.
    private static let maximumGenerationCount = 8
    private static let maximumCachedFileCount = 400
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
            let reusableMetadata = currentRendererActiveItem.flatMap { item in
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
                    let ciContext = Self.makeCIContext()
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
                                spec: spec,
                                ciContext: ciContext
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

        // Limited access or iCloud offloading can leave fewer local images than
        // requested. Repeat the successful subset so the manifest still holds
        // the configured 15–20 future entries without network access.
        let items = (0..<settings.widgetEntryCount).map { offset in
            let item = available[offset % available.count]
            return WidgetManifestItem(
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
    /// plus margin, falling back to Build 5's blurred fit only when geometry
    /// makes that impossible. Medium remains full-bleed and favors the upper
    /// part of an oversized cat union. No face detection, subject lifting, or
    /// semantic composition runs here or in the Widget extension.
    private static func widgetJPEG(
        normalizedImage image: UIImage,
        renderPlan: WidgetFamilyRenderPlan,
        catBoundingBox: CGRect?,
        spec: RenderSpec,
        ciContext: CIContext
    ) -> (
        data: Data,
        compositionMode: WidgetCompositionMode,
        renderScale: CGFloat,
        legacy18WouldFallback: Bool?
    )? {
        let rendered = renderedWidgetImage(
            image: image,
            renderPlan: renderPlan,
            size: spec.size,
            ciContext: ciContext
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
            rendered.compositionMode,
            rendered.renderScale,
            legacy18WouldFallback
        )
    }

    private static func renderedWidgetImage(
        image: UIImage,
        renderPlan: WidgetFamilyRenderPlan,
        size: CGSize,
        ciContext: CIContext
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

        let background = aspectFillImage(image, size: size)
        let blurredBackground = gaussianBlurredImage(
            background,
            radius: 18,
            ciContext: ciContext
        ) ?? background

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            blurredBackground.draw(in: CGRect(origin: .zero, size: size))
            image.draw(in: aspectFitRect(imageSize: image.size, canvasSize: size))
        }
        return (
            rendered,
            .blurredFitFallback,
            aspectFitScale(imageSize: image.size, canvasSize: size)
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

    private static func gaussianBlurredImage(
        _ image: UIImage,
        radius: CGFloat,
        ciContext: CIContext
    ) -> UIImage? {
        guard let input = CIImage(image: image) else { return nil }
        let extent = input.extent
        let output = input
            .clampedToExtent()
            .applyingFilter(
                "CIGaussianBlur",
                parameters: [kCIInputRadiusKey: radius]
            )
            .cropped(to: extent)
        guard let cgImage = ciContext.createCGImage(output, from: extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    private static func makeCIContext() -> CIContext {
        var options: [CIContextOption: Any] = [.cacheIntermediates: false]
        #if targetEnvironment(simulator)
        // Hosted Simulators do not always expose a stable Metal device. The
        // production device keeps Core Image's normal hardware renderer.
        options[.useSoftwareRenderer] = true
        #endif
        return CIContext(options: options)
    }

    private static func aspectFitRect(imageSize: CGSize, canvasSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: canvasSize)
        }
        let scale = aspectFitScale(imageSize: imageSize, canvasSize: canvasSize)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (canvasSize.width - drawSize.width) / 2,
            y: (canvasSize.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
    }

    private static func aspectFitScale(imageSize: CGSize, canvasSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return .infinity }
        return min(canvasSize.width / imageSize.width, canvasSize.height / imageSize.height)
    }

    private static func aspectFillRect(imageSize: CGSize, canvasSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: canvasSize)
        }
        let scale = max(canvasSize.width / imageSize.width, canvasSize.height / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (canvasSize.width - drawSize.width) / 2,
            y: (canvasSize.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
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
