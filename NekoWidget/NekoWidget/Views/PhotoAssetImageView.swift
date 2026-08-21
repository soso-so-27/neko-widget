import Photos
import SwiftUI
import UIKit

/// A shared PhotoKit pipeline lets the photo browser warm the same cache used
/// by its visible pages. The browser keeps this cache window deliberately
/// small, so opening a large library does not decode every photo at once.
enum PhotoAssetImagePipeline {
    static let manager = PHCachingImageManager()

    static func startCachingFullImages(
        localIdentifiers: [String],
        targetPixelSize: CGSize
    ) {
        let assets = assets(withLocalIdentifiers: localIdentifiers)
        guard !assets.isEmpty else { return }
        manager.startCachingImages(
            for: assets,
            targetSize: targetPixelSize,
            contentMode: .aspectFit,
            options: fullImageRequestOptions()
        )
    }

    static func stopCachingFullImages(
        localIdentifiers: [String],
        targetPixelSize: CGSize
    ) {
        let assets = assets(withLocalIdentifiers: localIdentifiers)
        guard !assets.isEmpty else { return }
        manager.stopCachingImages(
            for: assets,
            targetSize: targetPixelSize,
            contentMode: .aspectFit,
            options: fullImageRequestOptions()
        )
    }

    private static func assets(withLocalIdentifiers identifiers: [String]) -> [PHAsset] {
        guard !identifiers.isEmpty else { return [] }
        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: identifiers,
            options: nil
        )
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    private static func fullImageRequestOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.resizeMode = .fast
        return options
    }
}

/// Loads a display-sized image directly from PhotoKit. The original photo is never retained.
/// When Vision's normalized bounding box is available, PhotoKit crops around its center.
struct PhotoAssetImageView: View {
    let localIdentifier: String
    var catBoundingBox: CGRect?
    var targetPixelSize: CGSize
    var targetAspectRatio: CGFloat
    var showsFullImage: Bool
    var networkAccessAllowed: Bool

    @StateObject private var loader = PhotoAssetImageLoader()

    init(
        localIdentifier: String,
        catBoundingBox: CGRect? = nil,
        targetPixelSize: CGSize = CGSize(width: 800, height: 800),
        targetAspectRatio: CGFloat = 1,
        showsFullImage: Bool = false,
        networkAccessAllowed: Bool = true
    ) {
        self.localIdentifier = localIdentifier
        self.catBoundingBox = catBoundingBox
        self.targetPixelSize = targetPixelSize
        self.targetAspectRatio = targetAspectRatio
        self.showsFullImage = showsFullImage
        self.networkAccessAllowed = networkAccessAllowed
    }

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)

            switch loader.state {
            case let .loaded(image):
                if showsFullImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    // Grid cells are deliberately one full-bleed layer. The
                    // previous ambient-background fallback drew the same image
                    // twice and caused visible scroll hitches on large lists.
                    // The full photo remains available in the detail browser.
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }

            case .failed:
                ContentUnavailableView(
                    "写真を表示できません",
                    systemImage: "photo",
                    description: Text(
                        networkAccessAllowed
                            ? "iCloud上の写真は、通信できるときに再度読み込みます。"
                            : "この計測では、端末内にある写真だけを使います。"
                        )
                )

            case .loading:
                ProgressView()
                    .controlSize(.small)
            }
        }
        .clipped()
        .task(id: LoadKey(
            localIdentifier: localIdentifier,
            boundingBox: catBoundingBox,
            targetSize: targetPixelSize,
            targetAspectRatio: targetAspectRatio,
            showsFullImage: showsFullImage,
            networkAccessAllowed: networkAccessAllowed
        )) {
            await loader.load(
                localIdentifier: localIdentifier,
                catBoundingBox: catBoundingBox,
                targetPixelSize: targetPixelSize,
                targetAspectRatio: targetAspectRatio,
                showsFullImage: showsFullImage,
                networkAccessAllowed: networkAccessAllowed
            )
        }
        .onDisappear {
            loader.cancel()
        }
        .accessibilityLabel("猫の写真")
    }
}

private struct LoadKey: Hashable {
    let localIdentifier: String
    let boundingBox: CGRect?
    let targetSize: CGSize
    let targetAspectRatio: CGFloat
    let showsFullImage: Bool
    let networkAccessAllowed: Bool
}

private enum PhotoAssetImageLoadState {
    case loading
    case loaded(UIImage)
    case failed
}

private final class PhotoAssetDisplayCache: @unchecked Sendable {
    static let shared = PhotoAssetDisplayCache()

    private let thumbnails = NSCache<PhotoAssetDisplayCacheKey, UIImage>()
    private let assets = NSCache<NSString, PHAsset>()

    private init() {
        thumbnails.countLimit = 240
        thumbnails.totalCostLimit = 32 * 1_024 * 1_024
        assets.countLimit = 1_024
    }

    func thumbnail(for key: LoadKey) -> UIImage? {
        thumbnails.object(forKey: PhotoAssetDisplayCacheKey(key))
    }

    func storeThumbnail(_ image: UIImage, for key: LoadKey) {
        let pixelHeight = image.cgImage?.height ?? Int(image.size.height * image.scale)
        let bytesPerRow = image.cgImage?.bytesPerRow
            ?? Int(image.size.width * image.scale) * 4
        thumbnails.setObject(
            image,
            forKey: PhotoAssetDisplayCacheKey(key),
            cost: max(1, pixelHeight * bytesPerRow)
        )
    }

    func cachedAsset(localIdentifier: String) -> PHAsset? {
        let key = localIdentifier as NSString
        return assets.object(forKey: key)
    }

    func storeAsset(_ asset: PHAsset) {
        assets.setObject(asset, forKey: asset.localIdentifier as NSString)
    }
}

private struct SendablePhotoAssetBatch: @unchecked Sendable {
    let values: [String: PHAsset]
}

/// Coalesces the first wave of grid-cell lookups into one PhotoKit fetch and
/// performs it away from the main actor. NSCache and immutable PHAsset proxies
/// are safe to share for this read-only display path.
private actor PhotoAssetResolver {
    static let shared = PhotoAssetResolver()

    private var waiters: [String: [CheckedContinuation<PHAsset?, Never>]] = [:]
    private var scheduledFlush: Task<Void, Never>?

    func asset(localIdentifier: String) async -> PHAsset? {
        if let cached = PhotoAssetDisplayCache.shared.cachedAsset(
            localIdentifier: localIdentifier
        ) {
            return cached
        }
        return await withCheckedContinuation { continuation in
            waiters[localIdentifier, default: []].append(continuation)
            scheduleFlushIfNeeded()
        }
    }

    private func scheduleFlushIfNeeded() {
        guard scheduledFlush == nil else { return }
        scheduledFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2))
            await self?.flush()
        }
    }

    private func flush() async {
        let pendingWaiters = waiters
        waiters.removeAll(keepingCapacity: true)
        scheduledFlush = nil
        let identifiers = Array(pendingWaiters.keys)
        guard !identifiers.isEmpty else { return }

        let batch = await Task.detached(priority: .userInitiated) {
            let result = PHAsset.fetchAssets(
                withLocalIdentifiers: identifiers,
                options: nil
            )
            var values: [String: PHAsset] = [:]
            values.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                values[asset.localIdentifier] = asset
            }
            return SendablePhotoAssetBatch(values: values)
        }.value

        for asset in batch.values.values {
            PhotoAssetDisplayCache.shared.storeAsset(asset)
        }
        for (identifier, continuations) in pendingWaiters {
            let asset = batch.values[identifier]
            continuations.forEach { $0.resume(returning: asset) }
        }
    }
}

private final class PhotoAssetDisplayCacheKey: NSObject {
    let value: LoadKey

    init(_ value: LoadKey) {
        self.value = value
    }

    override var hash: Int { value.hashValue }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? PhotoAssetDisplayCacheKey else { return false }
        return value == other.value
    }
}

@MainActor
private final class PhotoAssetImageLoader: ObservableObject {
    @Published private(set) var state: PhotoAssetImageLoadState = .loading

    private var requestID: PHImageRequestID?
    private var loadGeneration = 0

    func load(
        localIdentifier: String,
        catBoundingBox: CGRect?,
        targetPixelSize: CGSize,
        targetAspectRatio: CGFloat,
        showsFullImage: Bool,
        networkAccessAllowed: Bool
    ) async {
        cancel()
        let generation = loadGeneration
        let loadKey = LoadKey(
            localIdentifier: localIdentifier,
            boundingBox: catBoundingBox,
            targetSize: targetPixelSize,
            targetAspectRatio: targetAspectRatio,
            showsFullImage: showsFullImage,
            networkAccessAllowed: networkAccessAllowed
        )
        state = .loading

        if !showsFullImage,
           let cached = PhotoAssetDisplayCache.shared.thumbnail(for: loadKey) {
            state = .loaded(cached)
            return
        }

        guard let asset = await PhotoAssetResolver.shared.asset(
            localIdentifier: localIdentifier
        ) else {
            guard loadGeneration == generation, !Task.isCancelled else { return }
            state = .failed
            return
        }
        guard loadGeneration == generation, !Task.isCancelled else { return }

        let options = PHImageRequestOptions()
        options.deliveryMode = showsFullImage ? .opportunistic : .fastFormat
        options.isNetworkAccessAllowed = networkAccessAllowed
        options.version = .current
        var requestedContentMode: PHImageContentMode = showsFullImage ? .aspectFit : .aspectFill
        var composesWideFallback = false
        if showsFullImage {
            options.resizeMode = .fast
        } else if let catBoundingBox {
            if let cropRect = Self.cropRect(
                aroundVisionRect: catBoundingBox,
                imagePixelSize: CGSize(width: asset.pixelWidth, height: asset.pixelHeight),
                targetAspectRatio: targetAspectRatio
            ) {
                options.normalizedCropRect = cropRect
                options.resizeMode = .exact
            } else {
                // A wide union (often multiple cats) cannot fit a cat-centred
                // crop without cutting one animal off. Request the full image,
                // then flatten an ambient fill and the uncropped foreground
                // into one cached bitmap. Scrolling still renders one layer.
                requestedContentMode = .aspectFit
                options.resizeMode = .fast
                composesWideFallback = true
            }
        } else {
            options.resizeMode = .fast
        }

        requestID = PhotoAssetImagePipeline.manager.requestImage(
            for: asset,
            targetSize: targetPixelSize,
            contentMode: requestedContentMode,
            options: options
        ) { [weak self] image, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
            let error = info?[PHImageErrorKey] as? Error
            Task { @MainActor in
                guard let self,
                      self.loadGeneration == generation,
                      !cancelled else { return }
                if let image {
                    let displayImage: UIImage
                    if composesWideFallback {
                        let source = SendablePhotoImage(value: image)
                        let rendered = await Task.detached(priority: .utility) {
                            SendablePhotoImage(
                                value: PhotoAssetThumbnailComposer.composeWideThumbnail(
                                    source.value,
                                    targetPixelSize: targetPixelSize
                                )
                            )
                        }.value
                        displayImage = rendered.value
                    } else {
                        displayImage = image
                    }
                    guard self.loadGeneration == generation else { return }
                    if !showsFullImage {
                        PhotoAssetDisplayCache.shared.storeThumbnail(
                            displayImage,
                            for: loadKey
                        )
                    }
                    self.state = .loaded(displayImage)
                } else if error != nil || !degraded {
                    self.state = .failed
                }
            }
        }
    }

    func cancel() {
        loadGeneration &+= 1
        if let requestID {
            PhotoAssetImagePipeline.manager.cancelImageRequest(requestID)
        }
        requestID = nil
        state = .loading
    }

    private static func cropRect(
        aroundVisionRect visionRect: CGRect,
        imagePixelSize: CGSize,
        targetAspectRatio: CGFloat
    ) -> CGRect? {
        guard imagePixelSize.width > 0,
              imagePixelSize.height > 0,
              targetAspectRatio > 0 else {
            return nil
        }

        // Vision uses a bottom-left origin; PhotoKit's normalizedCropRect uses top-left.
        let photoRect = CGRect(
            x: visionRect.minX,
            y: 1 - visionRect.maxY,
            width: visionRect.width,
            height: visionRect.height
        )
        let imageAspect = imagePixelSize.width / imagePixelSize.height

        let cropWidth: CGFloat
        let cropHeight: CGFloat
        if imageAspect > targetAspectRatio {
            cropWidth = targetAspectRatio / imageAspect
            cropHeight = 1
        } else {
            cropWidth = 1
            cropHeight = imageAspect / targetAspectRatio
        }

        let horizontalMargin = visionRect.width * 0.12
        let verticalMargin = visionRect.height * 0.12
        let paddedPhotoRect = photoRect.insetBy(
            dx: -horizontalMargin,
            dy: -verticalMargin
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !paddedPhotoRect.isNull,
              !paddedPhotoRect.isEmpty,
              paddedPhotoRect.midX.isFinite,
              paddedPhotoRect.midY.isFinite,
              paddedPhotoRect.width <= cropWidth,
              paddedPhotoRect.height <= cropHeight else {
            return nil
        }

        let preferredX = paddedPhotoRect.midX - cropWidth / 2
        let preferredY = paddedPhotoRect.midY - cropHeight / 2
        return CGRect(
            x: min(max(preferredX, 0), 1 - cropWidth),
            y: min(max(preferredY, 0), 1 - cropHeight),
            width: cropWidth,
            height: cropHeight
        )
    }
}

private struct SendablePhotoImage: @unchecked Sendable {
    let value: UIImage
}

private enum PhotoAssetThumbnailComposer {
    static func composeWideThumbnail(
        _ image: UIImage,
        targetPixelSize: CGSize
    ) -> UIImage {
        guard image.size.width > 0,
              image.size.height > 0,
              targetPixelSize.width.isFinite,
              targetPixelSize.height.isFinite,
              targetPixelSize.width > 0,
              targetPixelSize.height > 0 else {
            return image
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let bounds = CGRect(origin: .zero, size: targetPixelSize)
        return UIGraphicsImageRenderer(
            size: targetPixelSize,
            format: format
        ).image { _ in
            UIColor.black.setFill()
            UIRectFill(bounds)
            image.draw(
                in: aspectFillRect(imageSize: image.size, inside: bounds),
                blendMode: .normal,
                alpha: 0.48
            )
            UIColor.black.withAlphaComponent(0.22).setFill()
            UIRectFill(bounds)
            image.draw(in: aspectFitRect(imageSize: image.size, inside: bounds))
        }
    }

    private static func aspectFitRect(
        imageSize: CGSize,
        inside bounds: CGRect
    ) -> CGRect {
        scaledRect(imageSize: imageSize, inside: bounds, useMaximumScale: false)
    }

    private static func aspectFillRect(
        imageSize: CGSize,
        inside bounds: CGRect
    ) -> CGRect {
        scaledRect(imageSize: imageSize, inside: bounds, useMaximumScale: true)
    }

    private static func scaledRect(
        imageSize: CGSize,
        inside bounds: CGRect,
        useMaximumScale: Bool
    ) -> CGRect {
        let widthScale = bounds.width / imageSize.width
        let heightScale = bounds.height / imageSize.height
        let scale = useMaximumScale
            ? max(widthScale, heightScale)
            : min(widthScale, heightScale)
        let size = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

}
