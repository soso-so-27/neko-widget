import CryptoKit
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
    private static let cropAlgorithmVersion = "cat-square-v2"
    private static let maximumGenerationCount = 24
    private static let maximumCachedFileCount = 480

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
                "candidates": "\(candidates.count)",
                "entryTarget": "\(settings.widgetEntryCount)",
                "imageRequestPixels": "900x900",
                "networkAllowed": "false",
                "outputPixels": "400x400"
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

        var available: [(record: AssetRecord, filename: String, byteCount: Int)] = []
        var generatedFileCount = 0
        var reusedFileCount = 0
        var unavailableAssetCount = 0
        var inputPixelWidths: [Int] = []
        var inputPixelHeights: [Int] = []
        for record in candidates {
            try Task.checkCancellation()
            let filename = Self.cacheFilename(for: record)
            let fileURL = cacheDirectory.appendingPathComponent(filename, isDirectory: false)

            let byteCount: Int
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                let output: (data: Data, width: Int, height: Int)? = autoreleasepool {
                    guard let image = imageLoader.image(
                        localIdentifier: record.localIdentifier,
                        targetSize: CGSize(width: 900, height: 900),
                        networkAccessAllowed: false,
                        contentMode: .aspectFit
                    ) else {
                        return nil
                    }
                    guard let data = Self.widgetJPEG(
                        image: image,
                        catBox: record.cat.boundingBox
                    ) else {
                        return nil
                    }
                    let width = image.cgImage?.width ?? Int(image.size.width * image.scale)
                    let height = image.cgImage?.height ?? Int(image.size.height * image.scale)
                    return (data, width, height)
                }
                guard let output else {
                    // The asset may have moved to iCloud since it was analyzed.
                    // Keep walking candidates without downloading it.
                    unavailableAssetCount += 1
                    continue
                }

                try output.data.write(to: fileURL, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: fileURL.path
                )
                byteCount = output.data.count
                generatedFileCount += 1
                inputPixelWidths.append(output.width)
                inputPixelHeights.append(output.height)
            } else {
                guard let existingByteCount = Self.byteCount(of: fileURL) else {
                    unavailableAssetCount += 1
                    continue
                }
                byteCount = existingByteCount
                reusedFileCount += 1
            }

            available.append((record, filename, byteCount))
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
                cacheFilename: item.filename,
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
        let timelineLease: WidgetTimelineLease?
        if let leaseURL = SharedContainer.widgetTimelineLeaseURL {
            timelineLease = try? AtomicJSON.read(WidgetTimelineLease.self, from: leaseURL)
        } else {
            timelineLease = nil
        }
        try Task.checkCancellation()
        try updateHistoryAndRemoveStaleFiles(
            newManifest: manifest,
            activeManifest: try? AtomicJSON.read(WidgetManifest.self, from: manifestURL),
            timelineLease: timelineLease,
            historyURL: historyURL,
            cacheDirectory: cacheDirectory
        )
        try AtomicJSON.write(manifest, to: manifestURL)

        let cachedByteCounts = available.map(\.byteCount)
        SharedLog.app.info(
            "widget-cache",
            "Widget cache build completed",
            metadata: [
                "cacheBytesMax": "\(cachedByteCounts.max() ?? 0)",
                "cacheBytesMin": "\(cachedByteCounts.min() ?? 0)",
                "cacheBytesTotal": "\(cachedByteCounts.reduce(0, +))",
                "entries": "\(items.count)",
                "generatedFiles": "\(generatedFileCount)",
                "inputPixelsMax": Self.pixelRange(widths: inputPixelWidths, heights: inputPixelHeights),
                "reusedFiles": "\(reusedFileCount)",
                "unavailable": "\(unavailableAssetCount)",
                "uniqueFiles": "\(available.count)"
            ]
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
        if let leaseURL = SharedContainer.widgetTimelineLeaseURL {
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
        timelineLease: WidgetTimelineLease?,
        historyURL: URL,
        cacheDirectory: URL
    ) throws {
        let oldHistory = (try? AtomicJSON.read(WidgetCacheHistory.self, from: historyURL)) ?? .empty
        var proposed = [generation(for: newManifest)]
        if let timelineLease {
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
            filenames: manifest.items.map(\.cacheFilename)
        )
    }

    private static func cacheFilename(for record: AssetRecord) -> String {
        let boxBits: String
        if let box = record.cat.boundingBox {
            boxBits = [box.x, box.y, box.width, box.height]
                .map { String($0.bitPattern, radix: 16) }
                .joined(separator: "-")
        } else {
            boxBits = "no-box"
        }
        let identity = [
            cropAlgorithmVersion,
            record.localIdentifier,
            record.analysisFingerprint,
            boxBits
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
        let hexadecimal = digest.map { String(format: "%02x", $0) }.joined()
        return "asset-\(hexadecimal).jpg"
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

    /// Produces an orientation-normalized, cat-centered 400px square. If all
    /// cats cannot fit in a square crop, the full image is aspect-fitted so no
    /// cat is cut off. JPEG quality is then searched down to about 50KB.
    private static func widgetJPEG(image: UIImage, catBox: NormalizedRect?) -> Data? {
        let normalized = normalizedImage(image)
        let focused = catFocusedSquare(image: normalized, catBox: catBox)
        let resized = resizedSquare(focused, pixels: 400)
        return jpegData(resized, targetByteCount: 50 * 1_024)
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

    private static func catFocusedSquare(
        image: UIImage,
        catBox: NormalizedRect?
    ) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let shortSide = min(width, height)
        guard let catBox else {
            return crop(cgImage: cgImage, rect: centeredSquare(width: width, height: height))
        }

        // Vision uses a lower-left origin; Core Graphics image pixels use a
        // top-left visual origin after UIImage orientation is normalized.
        let catRect = CGRect(
            x: CGFloat(catBox.x) * width,
            y: (1 - CGFloat(catBox.y + catBox.height)) * height,
            width: CGFloat(catBox.width) * width,
            height: CGFloat(catBox.height) * height
        )
        let requiredSide = max(catRect.width, catRect.height) * 1.18
        guard requiredSide <= shortSide else {
            return aspectFitInSquare(image: image, pixels: Int(shortSide))
        }

        let side = min(shortSide, max(requiredSide, shortSide * 0.55))
        let proposedX = catRect.midX - side / 2
        let proposedY = catRect.midY - side / 2
        let rect = CGRect(
            x: min(max(0, proposedX), width - side),
            y: min(max(0, proposedY), height - side),
            width: side,
            height: side
        ).integral
        return crop(cgImage: cgImage, rect: rect)
    }

    private static func centeredSquare(width: CGFloat, height: CGFloat) -> CGRect {
        let side = min(width, height)
        return CGRect(
            x: (width - side) / 2,
            y: (height - side) / 2,
            width: side,
            height: side
        ).integral
    }

    private static func crop(cgImage: CGImage, rect: CGRect) -> UIImage {
        guard let cropped = cgImage.cropping(to: rect) else { return UIImage(cgImage: cgImage) }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }

    private static func aspectFitInSquare(image: UIImage, pixels: Int) -> UIImage {
        let side = CGFloat(max(1, pixels))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: format
        ).image { context in
            UIColor.black.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let scale = min(side / image.size.width, side / image.size.height)
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(
                x: (side - drawSize.width) / 2,
                y: (side - drawSize.height) / 2,
                width: drawSize.width,
                height: drawSize.height
            ))
        }
    }

    private static func resizedSquare(_ image: UIImage, pixels: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(
            size: CGSize(width: pixels, height: pixels),
            format: format
        ).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        }
    }

    private static func jpegData(_ image: UIImage, targetByteCount: Int) -> Data? {
        var low: CGFloat = 0.03
        var high: CGFloat = 0.90
        var best: Data?
        for _ in 0..<9 {
            let quality = (low + high) / 2
            guard let candidate = image.jpegData(compressionQuality: quality) else { return nil }
            if candidate.count <= targetByteCount {
                best = candidate
                low = quality
            } else {
                high = quality
            }
        }
        return best ?? image.jpegData(compressionQuality: 0.03)
    }
}
