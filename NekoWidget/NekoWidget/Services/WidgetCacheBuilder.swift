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
    private static let compositionAlgorithmVersion = "cat-family-blur-v3"
    private static let maximumGenerationCount = 24
    private static let maximumCachedFileCount = 480
    private static let targetJPEGByteCount = 50 * 1_024

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
                "imageRequestPixels": "900x900",
                "networkAllowed": "false",
                "outputPixels": Self.outputPixelDescription,
                "targetBytesEach": "\(Self.targetJPEGByteCount)"
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
                    files: [(variant: WidgetImageVariant, data: Data)],
                    width: Int,
                    height: Int
                )? = autoreleasepool {
                    guard let image = imageLoader.image(
                        localIdentifier: record.localIdentifier,
                        targetSize: CGSize(width: 900, height: 900),
                        networkAccessAllowed: false,
                        contentMode: .aspectFit
                    ) else {
                        return nil
                    }

                    let normalized = Self.normalizedImage(image)
                    let ciContext = Self.makeCIContext()
                    var files: [(variant: WidgetImageVariant, data: Data)] = []
                    for spec in missingSpecs {
                        let data: Data? = autoreleasepool {
                            Self.widgetJPEG(
                                normalizedImage: normalized,
                                spec: spec,
                                ciContext: ciContext
                            )
                        }
                        guard let data else {
                            return nil
                        }
                        files.append((spec.variant, data))
                    }
                    let width = image.cgImage?.width ?? Int(image.size.width * image.scale)
                    let height = image.cgImage?.height ?? Int(image.size.height * image.scale)
                    return (files, width, height)
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
                    try? FileManager.default.setAttributes(
                        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                        ofItemAtPath: fileURL.path
                    )
                }
                inputPixelWidths.append(output.width)
                inputPixelHeights.append(output.height)
            }

            var byteCounts: [WidgetImageVariant: Int] = [:]
            var filesAreAvailable = true
            for spec in Self.RenderSpec.all {
                let filename = filenames.filename(for: spec.variant)
                let fileURL = cacheDirectory.appendingPathComponent(filename, isDirectory: false)
                guard let existingByteCount = Self.byteCount(of: fileURL),
                      existingByteCount > 0,
                      existingByteCount <= Self.targetJPEGByteCount else {
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
            "cacheBytesMax": "\(cachedByteCounts.max() ?? 0)",
            "cacheBytesMin": "\(cachedByteCounts.min() ?? 0)",
            "cacheBytesTotal": "\(cachedByteCounts.reduce(0, +))",
            "entries": "\(items.count)",
            "generatedFiles": "\(generatedFileCount)",
            "inputPixelsMax": Self.pixelRange(widths: inputPixelWidths, heights: inputPixelHeights),
            "outputPixels": Self.outputPixelDescription,
            "reusedFiles": "\(reusedFileCount)",
            "targetBytesEach": "\(Self.targetJPEGByteCount)",
            "unavailable": "\(unavailableAssetCount)",
            "uniqueAssets": "\(available.count)",
            "uniqueFiles": "\(available.count * Self.RenderSpec.all.count)"
        ]
        completionMetadata.merge(bytesByVariant) { current, _ in current }
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
        let identity = [
            compositionAlgorithmVersion,
            variant.rawValue,
            RenderSpec.spec(for: variant).pixelDescription,
            record.localIdentifier,
            record.analysisFingerprint
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

    /// Produces a family-sized JPEG with a blurred aspect-fill background and
    /// the full, sharp original aspect-fitted over it. Build 5 deliberately
    /// avoids subject lifting and new composition/cropping heuristics.
    private static func widgetJPEG(
        normalizedImage image: UIImage,
        spec: RenderSpec,
        ciContext: CIContext
    ) -> Data? {
        let rendered = renderedWidgetImage(
            image: image,
            size: spec.size,
            ciContext: ciContext
        )
        return jpegData(rendered, targetByteCount: targetJPEGByteCount)
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
        size: CGSize,
        ciContext: CIContext
    ) -> UIImage {
        let background = aspectFillImage(image, size: size)
        let blurredBackground = gaussianBlurredImage(
            background,
            radius: 18,
            ciContext: ciContext
        ) ?? background

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            blurredBackground.draw(in: CGRect(origin: .zero, size: size))
            image.draw(in: aspectFitRect(imageSize: image.size, canvasSize: size))
        }
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
        let scale = min(canvasSize.width / imageSize.width, canvasSize.height / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (canvasSize.width - drawSize.width) / 2,
            y: (canvasSize.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
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
