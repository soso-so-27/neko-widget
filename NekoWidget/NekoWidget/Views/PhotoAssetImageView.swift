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
                    // Every thumbnail fills its fixed frame. If a cat union is
                    // wider than the frame, the best centred crop is preferred
                    // over letterboxing; the detail browser still shows all of
                    // the original photo.
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
    private var finalImageGeneration: Int?
    private var displayedImageGeneration: Int?

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
        // Opportunistic delivery gives the grid a quick preview followed by a
        // display-sized final image. A degraded preview is never cached as the
        // terminal thumbnail, which previously made Build 24 remain blurry.
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = networkAccessAllowed
        options.version = .current
        let requestedContentMode: PHImageContentMode = showsFullImage ? .aspectFit : .aspectFill
        if showsFullImage {
            options.resizeMode = .fast
        } else if let catBoundingBox {
            if let cropRect = PhotoThumbnailCropPolicy.cropRect(
                aroundVisionRect: catBoundingBox,
                imagePixelSize: CGSize(width: asset.pixelWidth, height: asset.pixelHeight),
                targetAspectRatio: targetAspectRatio
            ) {
                options.normalizedCropRect = cropRect
                options.resizeMode = .exact
            } else {
                options.resizeMode = .fast
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
                    if degraded, self.finalImageGeneration == generation {
                        return
                    }
                    if !degraded {
                        self.finalImageGeneration = generation
                    }
                    guard self.loadGeneration == generation else { return }
                    self.displayedImageGeneration = generation
                    if !showsFullImage, !degraded {
                        PhotoAssetDisplayCache.shared.storeThumbnail(
                            image,
                            for: loadKey
                        )
                    }
                    self.state = .loaded(image)
                } else if (error != nil || !degraded),
                          self.displayedImageGeneration != generation {
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
        finalImageGeneration = nil
        displayedImageGeneration = nil
        state = .loading
    }

}
