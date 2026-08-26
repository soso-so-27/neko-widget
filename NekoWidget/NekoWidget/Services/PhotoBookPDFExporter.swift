@preconcurrency import Photos
import UIKit

struct MemoryPhotoJPEGExport: Equatable, Sendable {
    let jpeg: Data
    let pixelWidth: Int
    let pixelHeight: Int
}

private struct MemoryPhotoSendableImage: @unchecked Sendable {
    let value: UIImage
}

enum MemoryPhotoJPEGExportError: LocalizedError, Equatable {
    case photoNotInMemories
    case photoUnavailable
    case imageUnavailable
    case couldNotCreateJPEG

    var errorDescription: String? {
        switch self {
        case .photoNotInMemories:
            "この写真は現在「思い出」にありません。"
        case .photoUnavailable:
            "この写真を写真ライブラリで確認できませんでした。"
        case .imageUnavailable:
            "写真データを取得できませんでした。"
        case .couldNotCreateJPEG:
            "写真を書き出せませんでした。"
        }
    }
}

/// Builds one privacy-minimal JPEG in memory after an explicit user action.
/// The exact currently liked PhotoKit record is required; no alternate photo,
/// raw-original resource API, or temporary file is used.
struct MemoryPhotoJPEGExporter {
    @MainActor
    func export(
        from records: [AssetRecord],
        localIdentifier: String
    ) async throws -> MemoryPhotoJPEGExport {
        let candidates = records.map {
            PhotoBookPhotoCandidate(
                localIdentifier: $0.localIdentifier,
                creationDate: $0.creationDate,
                isLiked: $0.liked
            )
        }
        guard let selected = MemoryPhotoExportPolicy.selection(
            from: candidates,
            localIdentifier: localIdentifier
        ) else {
            throw MemoryPhotoJPEGExportError.photoNotInMemories
        }

        try Task.checkCancellation()
        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: [selected.localIdentifier],
            options: nil
        )
        guard result.count == 1 else {
            throw MemoryPhotoJPEGExportError.photoUnavailable
        }
        let asset = result.object(at: 0)
        guard asset.localIdentifier == selected.localIdentifier,
              let targetSize = Self.targetSize(for: asset) else {
            throw MemoryPhotoJPEGExportError.photoUnavailable
        }

        guard let image = await image(for: asset, targetSize: targetSize) else {
            try Task.checkCancellation()
            throw MemoryPhotoJPEGExportError.imageUnavailable
        }
        try Task.checkCancellation()

        let sourceImage = MemoryPhotoSendableImage(value: image)
        let buildTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let normalized = WidgetSourceImageNormalizer.normalizedUIImage(
                sourceImage.value
            )
            try Task.checkCancellation()
            return try MomentCanonicalPreviewBuilder.build(image: normalized)
        }
        let preview: MomentCanonicalPreview
        do {
            preview = try await withTaskCancellationHandler {
                try await buildTask.value
            } onCancel: {
                buildTask.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MemoryPhotoJPEGExportError.couldNotCreateJPEG
        }
        try Task.checkCancellation()
        return MemoryPhotoJPEGExport(
            jpeg: preview.jpeg,
            pixelWidth: preview.pixelWidth,
            pixelHeight: preview.pixelHeight
        )
    }

    private static func targetSize(for asset: PHAsset) -> CGSize? {
        let sourceWidth = asset.pixelWidth
        let sourceHeight = asset.pixelHeight
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let longestSide = max(sourceWidth, sourceHeight)
        let scale = min(
            CGFloat(1),
            CGFloat(MomentSharingProtocol.maximumCanonicalPixelDimension)
                / CGFloat(longestSide)
        )
        return CGSize(
            width: max(1, (CGFloat(sourceWidth) * scale).rounded(.down)),
            height: max(1, (CGFloat(sourceHeight) * scale).rounded(.down))
        )
    }

    @MainActor
    private func image(
        for asset: PHAsset,
        targetSize: CGSize
    ) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.version = .current
        options.resizeMode = .exact
        options.deliveryMode = .highQualityFormat
        // Network access exists only inside this explicit export boundary so
        // an iCloud-backed selected photo can be retrieved on demand.
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        let request = PhotoBookImageRequest(
            asset: asset,
            targetSize: targetSize,
            options: options
        )
        return await withTaskCancellationHandler {
            await request.value()
        } onCancel: {
            request.cancel()
        }
    }
}

enum PhotoBookPDFExportError: LocalizedError, Equatable {
    case invalidSelection(minimum: Int, maximum: Int, actual: Int)
    case selectedPhotosUnavailable(expected: Int, actual: Int)
    case photoUnavailable(page: Int)
    case imageUnavailable(page: Int)
    case couldNotCreatePDF

    var errorDescription: String? {
        switch self {
        case let .invalidSelection(minimum, maximum, actual):
            "PDFには\(minimum)〜\(maximum)枚を選んでください。現在は\(actual)枚です。"
        case let .selectedPhotosUnavailable(expected, actual):
            "選んだ\(expected)枚のうち、\(actual)枚だけを確認できました。選び直してください。"
        case let .photoUnavailable(page):
            "\(page)ページ目の写真を写真ライブラリから取得できませんでした。"
        case let .imageUnavailable(page):
            "\(page)ページ目の画像を読み込めませんでした。"
        case .couldNotCreatePDF:
            "PDFを作成できませんでした。"
        }
    }
}

/// Creates one local A4-portrait PDF from one to thirty explicitly selected
/// liked photos. The returned temporary file can be passed directly to a
/// `UIActivityViewController`. The caller owns the file's eventual cleanup.
struct PhotoBookPDFExporter {
    static let pageSize = CGSize(width: 595.2, height: 841.8)
    static let pageInsets = UIEdgeInsets(top: 36, left: 36, bottom: 36, right: 36)
    static let imageRequestScale: CGFloat = 2

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Convenience boundary for AppViewModel. Filtering remains inside the
    /// pure policy, so passing the full candidate snapshot cannot export an
    /// unliked photo accidentally.
    @MainActor
    func export(
        from records: [AssetRecord],
        selectedIdentifiers: [String]
    ) async throws -> URL {
        try await export(from: records.map {
            PhotoBookPhotoCandidate(
                localIdentifier: $0.localIdentifier,
                creationDate: $0.creationDate,
                isLiked: $0.liked
            )
        }, selectedIdentifiers: selectedIdentifiers)
    }

    @MainActor
    func export(
        from candidates: [PhotoBookPhotoCandidate],
        selectedIdentifiers: [String]
    ) async throws -> URL {
        let uniqueSelection = Set(selectedIdentifiers)
        guard uniqueSelection.count == selectedIdentifiers.count,
              uniqueSelection.count >= PhotoBookPolicy.minimumPhotosPerExport,
              uniqueSelection.count <= PhotoBookPolicy.maximumPhotosPerExport else {
            throw PhotoBookPDFExportError.invalidSelection(
                minimum: PhotoBookPolicy.minimumPhotosPerExport,
                maximum: PhotoBookPolicy.maximumPhotosPerExport,
                actual: uniqueSelection.count
            )
        }
        let selected = PhotoBookPolicy.selection(
            from: candidates,
            selectedIdentifiers: selectedIdentifiers
        )
        guard selected.count == uniqueSelection.count else {
            throw PhotoBookPDFExportError.selectedPhotosUnavailable(
                expected: uniqueSelection.count,
                actual: selected.count
            )
        }

        try Task.checkCancellation()
        let assets = PHAsset.fetchAssets(
            withLocalIdentifiers: selected.map(\.localIdentifier),
            options: nil
        )
        var assetsByIdentifier: [String: PHAsset] = [:]
        assets.enumerateObjects { asset, _, _ in
            assetsByIdentifier[asset.localIdentifier] = asset
        }

        let exportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("PhotoBookExports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: exportDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw PhotoBookPDFExportError.couldNotCreatePDF
        }
        let outputURL = exportDirectory.appendingPathComponent(
            "ねこのまど-写真まとめ.pdf",
            isDirectory: false
        )

        let pageBounds = CGRect(origin: .zero, size: Self.pageSize)
        let documentInfo: [AnyHashable: Any] = [
            kCGPDFContextTitle as String: "ねこのまど 写真まとめ",
            kCGPDFContextCreator as String: "ねこのまど"
        ]
        guard let consumer = CGDataConsumer(url: outputURL as CFURL) else {
            try? fileManager.removeItem(at: exportDirectory)
            throw PhotoBookPDFExportError.couldNotCreatePDF
        }
        var mediaBox = pageBounds
        guard let pdfContext = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            documentInfo as CFDictionary
        ) else {
            try? fileManager.removeItem(at: exportDirectory)
            throw PhotoBookPDFExportError.couldNotCreatePDF
        }

        do {
            for (offset, candidate) in selected.enumerated() {
                try Task.checkCancellation()
                let page = offset + 1
                guard let asset = assetsByIdentifier[candidate.localIdentifier] else {
                    throw PhotoBookPDFExportError.photoUnavailable(page: page)
                }
                guard let image = await image(for: asset) else {
                    try Task.checkCancellation()
                    throw PhotoBookPDFExportError.imageUnavailable(page: page)
                }
                try Task.checkCancellation()

                pdfContext.beginPDFPage(nil)
                pdfContext.saveGState()
                pdfContext.translateBy(x: 0, y: pageBounds.height)
                pdfContext.scaleBy(x: 1, y: -1)
                UIGraphicsPushContext(pdfContext)
                UIColor.white.setFill()
                UIRectFill(pageBounds)
                image.draw(in: Self.aspectFitRect(
                    imageSize: image.size,
                    inside: pageBounds.inset(by: Self.pageInsets)
                ))
                UIGraphicsPopContext()
                pdfContext.restoreGState()
                pdfContext.endPDFPage()
            }
            pdfContext.closePDF()
        } catch {
            pdfContext.closePDF()
            try? fileManager.removeItem(at: exportDirectory)
            throw error
        }

        let outputSize = (
            try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        ) ?? 0
        guard fileManager.fileExists(atPath: outputURL.path), outputSize > 0 else {
            try? fileManager.removeItem(at: exportDirectory)
            throw PhotoBookPDFExportError.couldNotCreatePDF
        }
        return outputURL
    }

    @MainActor
    private func image(for asset: PHAsset) async -> UIImage? {
        let contentBounds = CGRect(origin: .zero, size: Self.pageSize)
            .inset(by: Self.pageInsets)
        let targetSize = CGSize(
            width: contentBounds.width * Self.imageRequestScale,
            height: contentBounds.height * Self.imageRequestScale
        )
        let options = PHImageRequestOptions()
        options.version = .current
        options.resizeMode = .exact
        options.deliveryMode = .highQualityFormat
        // Export is an explicit user action. The selection grid may show an
        // iCloud-backed thumbnail, so the matching display-sized derivative
        // must also be allowed here instead of failing after selection.
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        let request = PhotoBookImageRequest(
            asset: asset,
            targetSize: targetSize,
            options: options
        )
        return await withTaskCancellationHandler {
            await request.value()
        } onCancel: {
            request.cancel()
        }
    }

    private static func aspectFitRect(
        imageSize: CGSize,
        inside bounds: CGRect
    ) -> CGRect {
        guard imageSize.width.isFinite,
              imageSize.height.isFinite,
              imageSize.width > 0,
              imageSize.height > 0,
              bounds.width > 0,
              bounds.height > 0 else {
            return .zero
        }
        let scale = min(
            bounds.width / imageSize.width,
            bounds.height / imageSize.height
        )
        let fittedSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        return CGRect(
            x: bounds.midX - fittedSize.width / 2,
            y: bounds.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }
}

/// A cancellation-safe bridge for PhotoKit's potentially multi-callback image
/// request. Degraded previews are ignored so each explicit export receives one
/// final, high-quality image and the continuation is resumed exactly once.
private final class PhotoBookImageRequest: @unchecked Sendable {
    /// iCloud-backed display derivatives can legitimately take longer than the
    /// former local-only ten-second budget. Keep a finite escape hatch while
    /// the UI exposes explicit task cancellation.
    private static let timeoutNanoseconds: UInt64 = 120_000_000_000

    private let asset: PHAsset
    private let targetSize: CGSize
    private let options: PHImageRequestOptions
    private let manager = PHImageManager.default()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var requestIdentifier: PHImageRequestID?
    private var timeoutTask: Task<Void, Never>?
    private var isFinished = false

    init(
        asset: PHAsset,
        targetSize: CGSize,
        options: PHImageRequestOptions
    ) {
        self.asset = asset
        self.targetSize = targetSize
        self.options = options
    }

    func value() async -> UIImage? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isFinished {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            self.continuation = continuation
            lock.unlock()

            let identifier = manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { [weak self] image, info in
                self?.handle(image: image, info: info)
            }

            lock.lock()
            if isFinished {
                lock.unlock()
                manager.cancelImageRequest(identifier)
            } else {
                requestIdentifier = identifier
                lock.unlock()
            }

            let timeoutTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(nanoseconds: Self.timeoutNanoseconds)
                } catch {
                    return
                }
                self.finish(nil, cancelImageRequest: true)
            }
            lock.lock()
            if isFinished {
                lock.unlock()
                timeoutTask.cancel()
            } else {
                self.timeoutTask = timeoutTask
                lock.unlock()
            }
        }
    }

    func cancel() {
        finish(nil, cancelImageRequest: true)
    }

    private func handle(image: UIImage?, info: [AnyHashable: Any]?) {
        let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
        let wasCancelled = (info?[PHImageCancelledKey] as? Bool) == true
        let hasError = info?[PHImageErrorKey] as? Error != nil
        if isDegraded, !wasCancelled, !hasError { return }
        finish(
            wasCancelled || hasError ? nil : image,
            cancelImageRequest: false
        )
    }

    private func finish(_ image: UIImage?, cancelImageRequest: Bool) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        let requestIdentifier = self.requestIdentifier
        let timeoutTask = self.timeoutTask
        self.continuation = nil
        self.requestIdentifier = nil
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        if cancelImageRequest, let requestIdentifier {
            manager.cancelImageRequest(requestIdentifier)
        }
        continuation?.resume(returning: image)
    }
}
