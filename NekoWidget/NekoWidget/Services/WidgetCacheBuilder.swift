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
    private static let compositionAlgorithmVersion = "cat-aware-full-bleed-v5"
    /// The migration-safe maximum is 380 distinct files: new manifest 60,
    /// previous active manifest 60, grace generation 60, three pre-Build-8
    /// family leases of up to 60 each, and the Build-4 legacy lease of 20.
    /// Round to 400; the new provider writes only 20 files per family lease.
    private static let maximumGenerationCount = 8
    private static let maximumCachedFileCount = 400
    /// PhotoKit returns an aspect-fit local derivative. 2048px keeps a normal
    /// 16:9 source above the 1100px Large short side while bounding app-side
    /// source decode memory to roughly 16 MiB. Network behavior stays unchanged.
    private static let sourceImageRequestPixelDimension = 2_048
    /// Padding on every side of the detected cat union before deciding whether
    /// a family crop can keep the cat comfortably inside the frame.
    private static let catMarginFraction: CGFloat = 0.08
    /// Shadow-only baseline used to quantify the one-number 18% -> 8% change
    /// against the exact same generated Small/Large candidates in CI.
    private static let legacyCatMarginFraction: CGFloat = 0.18
    /// Tiny detections still receive visible breathing room in the source photo.
    private static let minimumImageMarginFraction: CGFloat = 0.03
    /// When a Medium crop cannot contain the whole cat union, bias its focal
    /// point toward the upper third of the box. This preserves the likely head
    /// area without introducing face detection or semantic composition.
    private static let mediumUpperFocusFraction: CGFloat = 0.35

    private enum CompositionMode: String, CaseIterable, Sendable {
        case catFullBleed = "cat-full-bleed"
        case mediumUpperFocus = "medium-upper-focus"
        case blurredFitFallback = "blurred-fit-fallback"

        var generatedMetadataKey: String {
            switch self {
            case .catFullBleed:
                return "compositionGeneratedCatFullBleed"
            case .mediumUpperFocus:
                return "compositionGeneratedMediumUpperFocus"
            case .blurredFitFallback:
                return "compositionGeneratedBlurredFitFallback"
            }
        }
    }

    private struct CropPlan {
        var normalizedRect: CGRect
        var compositionMode: CompositionMode
    }

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
                "algorithm": Self.compositionAlgorithmVersion,
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
            byteCounts: [WidgetImageVariant: Int]
        )] = []
        var generatedFileCount = 0
        var reusedFileCount = 0
        var unavailableAssetCount = 0
        var inputPixelWidths: [Int] = []
        var inputPixelHeights: [Int] = []
        var inputDecodedByteEstimates: [Int] = []
        var generatedCompositionCounts: [CompositionMode: Int] = [:]
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

            if !missingSpecs.isEmpty {
                let output: (
                    files: [(
                        variant: WidgetImageVariant,
                        data: Data,
                        compositionMode: CompositionMode,
                        renderScale: CGFloat,
                        legacy18WouldFallback: Bool?
                    )],
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

                    let normalized = Self.normalizedImage(image)
                    let ciContext = Self.makeCIContext()
                    var files: [(
                        variant: WidgetImageVariant,
                        data: Data,
                        compositionMode: CompositionMode,
                        renderScale: CGFloat,
                        legacy18WouldFallback: Bool?
                    )] = []
                    for spec in missingSpecs {
                        let output: (
                            data: Data,
                            compositionMode: CompositionMode,
                            renderScale: CGFloat,
                            legacy18WouldFallback: Bool?
                        )? = autoreleasepool {
                            Self.widgetJPEG(
                                normalizedImage: normalized,
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
                    return (files, width, height, decodedByteEstimate)
                }
                guard let output else {
                    // The asset may have moved to iCloud since it was analyzed.
                    // Keep walking candidates without downloading it.
                    unavailableAssetCount += 1
                    continue
                }

                for file in output.files {
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
                inputPixelWidths.append(output.width)
                inputPixelHeights.append(output.height)
                inputDecodedByteEstimates.append(output.decodedByteEstimate)
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
            guard filesAreAvailable, byteCounts.count == Self.RenderSpec.all.count else {
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
            available.append((record, filenames, byteCounts))
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
                )
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
            "algorithm": Self.compositionAlgorithmVersion,
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
        for mode in CompositionMode.allCases {
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
            compositionAlgorithmVersion,
            variant.rawValue,
            RenderSpec.spec(for: variant).pixelDescription,
            record.localIdentifier,
            record.analysisFingerprint,
            boundingBoxIdentity,
            modificationIdentity
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
        let hexadecimal = digest.map { String(format: "%02x", $0) }.joined()
        return "asset-\(compositionAlgorithmVersion)-\(variant.rawValue)-\(hexadecimal).jpg"
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
        catBoundingBox: CGRect?,
        spec: RenderSpec,
        ciContext: CIContext
    ) -> (
        data: Data,
        compositionMode: CompositionMode,
        renderScale: CGFloat,
        legacy18WouldFallback: Bool?
    )? {
        let rendered = renderedWidgetImage(
            image: image,
            catBoundingBox: catBoundingBox,
            variant: spec.variant,
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
            legacy18WouldFallback = catAwareCropPlan(
                visionBoundingBox: catBoundingBox,
                imageSize: image.size,
                canvasSize: spec.size,
                variant: spec.variant,
                marginFraction: legacyCatMarginFraction
            ) == nil
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

    private static func normalizedImage(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up || image.scale != 1 else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private static func renderedWidgetImage(
        image: UIImage,
        catBoundingBox: CGRect?,
        variant: WidgetImageVariant,
        size: CGSize,
        ciContext: CIContext
    ) -> (image: UIImage, compositionMode: CompositionMode, renderScale: CGFloat) {
        if let cropPlan = catAwareCropPlan(
            visionBoundingBox: catBoundingBox,
            imageSize: image.size,
            canvasSize: size,
            variant: variant,
            marginFraction: catMarginFraction
        ) {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(
                    in: drawRect(
                        imageSize: image.size,
                        normalizedCropRect: cropPlan.normalizedRect,
                        canvasSize: size
                    )
                )
            }
            return (
                rendered,
                cropPlan.compositionMode,
                renderScale(
                    imageSize: image.size,
                    normalizedCropRect: cropPlan.normalizedRect,
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

    /// Returns a normalized, top-left-origin crop rectangle. Vision reports
    /// bottom-left-origin coordinates, so the conversion must happen before
    /// any family-specific focus calculation.
    private static func catAwareCropPlan(
        visionBoundingBox: CGRect?,
        imageSize: CGSize,
        canvasSize: CGSize,
        variant: WidgetImageVariant,
        marginFraction: CGFloat
    ) -> CropPlan? {
        guard let visionBoundingBox,
              imageSize.width > 0,
              imageSize.height > 0,
              canvasSize.width > 0,
              canvasSize.height > 0,
              [
                  visionBoundingBox.minX,
                  visionBoundingBox.minY,
                  visionBoundingBox.width,
                  visionBoundingBox.height,
                  imageSize.width,
                  imageSize.height,
                  canvasSize.width,
                  canvasSize.height
              ].allSatisfy(\.isFinite) else {
            return nil
        }

        let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let photoBoundingBox = CGRect(
            x: visionBoundingBox.minX,
            y: 1 - visionBoundingBox.maxY,
            width: visionBoundingBox.width,
            height: visionBoundingBox.height
        ).standardized.intersection(unitRect)
        guard !photoBoundingBox.isNull,
              photoBoundingBox.width > 0,
              photoBoundingBox.height > 0 else {
            return nil
        }

        let horizontalMargin = max(
            photoBoundingBox.width * marginFraction,
            minimumImageMarginFraction
        )
        let verticalMargin = max(
            photoBoundingBox.height * marginFraction,
            minimumImageMarginFraction
        )
        let paddedBoundingBox = photoBoundingBox.insetBy(
            dx: -horizontalMargin,
            dy: -verticalMargin
        ).intersection(unitRect)

        let imageAspectRatio = imageSize.width / imageSize.height
        let canvasAspectRatio = canvasSize.width / canvasSize.height
        let cropSize: CGSize
        if imageAspectRatio > canvasAspectRatio {
            cropSize = CGSize(width: canvasAspectRatio / imageAspectRatio, height: 1)
        } else {
            cropSize = CGSize(width: 1, height: imageAspectRatio / canvasAspectRatio)
        }

        let keepsPaddedCat = paddedBoundingBox.width <= cropSize.width
            && paddedBoundingBox.height <= cropSize.height
        if keepsPaddedCat {
            return CropPlan(
                normalizedRect: clampedCropRect(
                    centeredAt: CGPoint(x: paddedBoundingBox.midX, y: paddedBoundingBox.midY),
                    cropSize: cropSize
                ),
                compositionMode: .catFullBleed
            )
        }

        guard variant == .medium else {
            // Small and Large never trade away part of a detected cat merely
            // to fill the frame. Their rare impossible cases keep the whole
            // source over a blurred background.
            return nil
        }

        let upperFocus = CGPoint(
            x: paddedBoundingBox.midX,
            y: paddedBoundingBox.minY + paddedBoundingBox.height * mediumUpperFocusFraction
        )
        return CropPlan(
            normalizedRect: clampedCropRect(centeredAt: upperFocus, cropSize: cropSize),
            compositionMode: .mediumUpperFocus
        )
    }

    private static func clampedCropRect(centeredAt focus: CGPoint, cropSize: CGSize) -> CGRect {
        CGRect(
            x: min(max(focus.x - cropSize.width / 2, 0), 1 - cropSize.width),
            y: min(max(focus.y - cropSize.height / 2, 0), 1 - cropSize.height),
            width: cropSize.width,
            height: cropSize.height
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
