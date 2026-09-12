import Foundation
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
        targetPixelSize: CGSize,
        networkAccessAllowed: Bool = true
    ) {
        let assets = assets(withLocalIdentifiers: localIdentifiers)
        guard !assets.isEmpty else { return }
        manager.startCachingImages(
            for: assets,
            targetSize: targetPixelSize,
            contentMode: .aspectFit,
            options: fullImageRequestOptions(
                networkAccessAllowed: networkAccessAllowed
            )
        )
    }

    static func stopCachingFullImages(
        localIdentifiers: [String],
        targetPixelSize: CGSize,
        networkAccessAllowed: Bool = true
    ) {
        let assets = assets(withLocalIdentifiers: localIdentifiers)
        guard !assets.isEmpty else { return }
        manager.stopCachingImages(
            for: assets,
            targetSize: targetPixelSize,
            contentMode: .aspectFit,
            options: fullImageRequestOptions(
                networkAccessAllowed: networkAccessAllowed
            )
        )
    }

    private static func assets(withLocalIdentifiers identifiers: [String]) -> [PHAsset] {
#if DEBUG
        // Generated UI images never belong to PhotoKit, including preheating.
        // A fetch for these fake identifiers can itself trigger a Photos prompt.
        let photoIdentifiers = identifiers.filter {
            !$0.hasPrefix("app-store-screenshot-fixture-")
        }
#else
        let photoIdentifiers = identifiers
#endif
        guard !photoIdentifiers.isEmpty else { return [] }
        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: photoIdentifiers,
            options: nil
        )
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    private static func fullImageRequestOptions(
        networkAccessAllowed: Bool
    ) -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = networkAccessAllowed
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
    var allowsZoom: Bool
    var networkAccessAllowed: Bool
    var onLoadResult: (Bool) -> Void
    var onZoomChange: (Bool) -> Void

    @StateObject private var loader = PhotoAssetImageLoader()
    @State private var retryRevision = 0

    init(
        localIdentifier: String,
        catBoundingBox: CGRect? = nil,
        targetPixelSize: CGSize = CGSize(width: 800, height: 800),
        targetAspectRatio: CGFloat = 1,
        showsFullImage: Bool = false,
        allowsZoom: Bool = false,
        networkAccessAllowed: Bool = true,
        onLoadResult: @escaping (Bool) -> Void = { _ in },
        onZoomChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.localIdentifier = localIdentifier
        self.catBoundingBox = catBoundingBox
        self.targetPixelSize = targetPixelSize
        self.targetAspectRatio = targetAspectRatio
        self.showsFullImage = showsFullImage
        self.allowsZoom = allowsZoom
        self.networkAccessAllowed = networkAccessAllowed
        self.onLoadResult = onLoadResult
        self.onZoomChange = onZoomChange
    }

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)

            switch loader.state {
            case let .loaded(image):
                if showsFullImage && allowsZoom {
                    PhotoAssetZoomView(image: image, localIdentifier: localIdentifier,
                                       onZoomChange: onZoomChange)
                } else if showsFullImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel("猫の写真")
                } else {
                    // Every thumbnail fills its fixed frame. If a cat union is
                    // wider than the frame, the best centred crop is preferred
                    // over letterboxing; the detail browser still shows all of
                    // the original photo.
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .accessibilityLabel("猫の写真")
                }

            case .failed:
                if showsFullImage {
                    ContentUnavailableView {
                        Label("写真を表示できません", systemImage: "photo")
                    } description: {
                        Text(
                            networkAccessAllowed
                                ? "写真へのアクセスや通信を確認してください。"
                                : "この計測では、端末内にある写真だけを使います。"
                        )
                    } actions: {
                        Button {
                            // Invalidate callbacks immediately, before SwiftUI
                            // schedules the task for this same photo again.
                            loader.cancel(preservingImage: true)
                            retryRevision &+= 1
                        } label: {
                            Label("再読み込み", systemImage: "arrow.clockwise")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("写真をもう一度読み込む")
                        .accessibilityIdentifier("local-photo-retry")
                    }
                } else {
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("写真を表示できません")
                }

            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("写真を読み込み中")
            }
        }
        .clipped()
        .overlay(alignment: .bottom) {
            if showsFullImage, case .loaded = loader.state,
               loader.fullImageLoadFailed {
                Button {
                    loader.cancel(preservingImage: true)
                    retryRevision &+= 1
                } label: {
                    Label("再読み込み", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("写真をもう一度読み込む")
                .accessibilityHint("読み込みを完了できませんでした。表示中の写真を保ったまま読み直します")
                .accessibilityIdentifier("local-photo-retry")
                .padding(12)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsFullImage, case .loaded = loader.state,
               loader.isLoadingFullImage {
                ProgressView()
                    .padding(10)
                    .background(.regularMaterial, in: Circle())
                    .padding(12)
                    .accessibilityLabel("写真を読み込み中")
                    .allowsHitTesting(false)
            }
        }
        .task(id: PhotoAssetLoadRequest(key: LoadKey(
            localIdentifier: localIdentifier,
            boundingBox: catBoundingBox,
            targetSize: targetPixelSize,
            targetAspectRatio: targetAspectRatio,
            showsFullImage: showsFullImage,
            networkAccessAllowed: networkAccessAllowed
        ), retryRevision: retryRevision)) {
            await loader.load(
                localIdentifier: localIdentifier,
                catBoundingBox: catBoundingBox,
                targetPixelSize: targetPixelSize,
                targetAspectRatio: targetAspectRatio,
                showsFullImage: showsFullImage,
                networkAccessAllowed: networkAccessAllowed,
                preservesDisplayedImage: retryRevision > 0
            )
        }
        .onDisappear {
            loader.cancel()
        }
        .onReceive(loader.$state) { state in
            switch state {
            case .loading:
                break
            case .loaded:
                onLoadResult(true)
            case .failed:
                onLoadResult(false)
            }
        }
    }
}

/// Reuse the photo-detail zoom surface while letting the outer photo pager own
/// horizontal drags at fit size. A zoomed photo owns its own pan gesture.
private struct PhotoAssetZoomView: UIViewRepresentable {
    let image: UIImage
    let localIdentifier: String
    let onZoomChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onZoomChange: onZoomChange)
    }

    func makeUIView(context: Context) -> MomentZoomablePhoto.PhotoScrollView {
        let view = MomentZoomablePhoto.PhotoScrollView()
        view.delegate = context.coordinator
        view.panGestureRecognizer.isEnabled = false
        return view
    }

    func updateUIView(_ view: MomentZoomablePhoto.PhotoScrollView, context: Context) {
        context.coordinator.onZoomChange = onZoomChange
        let preservesViewport = context.coordinator.localIdentifier == localIdentifier
        context.coordinator.localIdentifier = localIdentifier
        view.setImage(image, preservingViewport: preservesViewport)
    }

    static func dismantleUIView(_ view: MomentZoomablePhoto.PhotoScrollView,
                                coordinator: Coordinator) {
        view.delegate = nil
        coordinator.onZoomChange(false)
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var onZoomChange: (Bool) -> Void
        var localIdentifier: String?
        private var wasZoomed = false

        init(onZoomChange: @escaping (Bool) -> Void) {
            self.onZoomChange = onZoomChange
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? MomentZoomablePhoto.PhotoScrollView)?
                .viewForZooming(in: scrollView)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let view = scrollView as? MomentZoomablePhoto.PhotoScrollView else { return }
            view.scrollViewDidZoom(scrollView)
            let isZoomed = view.zoomScale > view.minimumZoomScale + 0.01
            view.panGestureRecognizer.isEnabled = isZoomed
            guard isZoomed != wasZoomed else { return }
            wasZoomed = isZoomed
            onZoomChange(isZoomed)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? MomentZoomablePhoto.PhotoScrollView)?
                .scrollViewDidScroll(scrollView)
        }
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

// Retry identity belongs to the request, not the shared thumbnail cache key.
private struct PhotoAssetLoadRequest: Hashable {
    let key: LoadKey
    let retryRevision: Int
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

    func removeAsset(localIdentifier: String) {
        assets.removeObject(forKey: localIdentifier as NSString)
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

    func asset(localIdentifier: String, bypassingCache: Bool = false) async -> PHAsset? {
        if bypassingCache {
            // Explicit retry rechecks the user's current access instead of
            // treating a cached PHAsset as proof it remains available.
            let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard authorization == .authorized || authorization == .limited else {
                PhotoAssetDisplayCache.shared.removeAsset(localIdentifier: localIdentifier)
                return nil
            }
        }
        if !bypassingCache, let cached = PhotoAssetDisplayCache.shared.cachedAsset(
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
            if asset == nil { PhotoAssetDisplayCache.shared.removeAsset(localIdentifier: identifier) }
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
    @Published private(set) var isLoadingFullImage = false
    @Published private(set) var fullImageLoadFailed = false

    private var requestID: PHImageRequestID?
    private var loadGeneration = 0
    private var finalImageGeneration: Int?
    private var displayedImageGeneration: Int?
    private var lastLoadKey: LoadKey?
#if DEBUG
    private let screenshotFixtureLoaderIdentifier = UUID()
    private var injectedFixtureFailure = false
    private var injectedPreviewFailure = false
#endif

    func load(
        localIdentifier: String,
        catBoundingBox: CGRect?,
        targetPixelSize: CGSize,
        targetAspectRatio: CGFloat,
        showsFullImage: Bool,
        networkAccessAllowed: Bool,
        preservesDisplayedImage: Bool = false
    ) async {
        let loadKey = LoadKey(
            localIdentifier: localIdentifier,
            boundingBox: catBoundingBox,
            targetSize: targetPixelSize,
            targetAspectRatio: targetAspectRatio,
            showsFullImage: showsFullImage,
            networkAccessAllowed: networkAccessAllowed
        )
        // A retry may retain only this exact photo/rendition. A new asset or
        // changed crop never inherits the previous image or its zoom state.
        cancel(preservingImage: preservesDisplayedImage && lastLoadKey == loadKey)
        let generation = loadGeneration
        lastLoadKey = loadKey
        if case .loaded = state { displayedImageGeneration = generation }
        isLoadingFullImage = showsFullImage

#if DEBUG
        // App Store screenshot capture uses deterministic illustrations that
        // never enter Photos. The launch route and identifiers are DEBUG-only,
        // so Release archives continue to resolve every image through PhotoKit.
        if let fixture = AppStoreScreenshotFixture.image(for: localIdentifier) {
            if showsFullImage,
               ProcessInfo.processInfo.arguments.contains("--photo-load-fails-once"),
               localIdentifier == "app-store-screenshot-fixture-1",
               !injectedFixtureFailure {
                injectedFixtureFailure = true
                isLoadingFullImage = false
                state = .failed
                return
            }
            if showsFullImage,
               ProcessInfo.processInfo.arguments.contains("--photo-load-preview-then-fail"),
               localIdentifier == "app-store-screenshot-fixture-1",
               !injectedPreviewFailure {
                injectedPreviewFailure = true
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let size = CGSize(width: 120, height: 120 * fixture.size.height / fixture.size.width)
                let preview = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    fixture.draw(in: CGRect(origin: .zero, size: size))
                }
                consumeResult(image: preview, cancelled: false, degraded: true,
                              failed: false, generation: generation, loadKey: loadKey)
                consumeResult(image: nil, cancelled: false, degraded: false,
                              failed: true, generation: generation, loadKey: loadKey)
            } else {
                consumeResult(image: fixture, cancelled: false, degraded: false,
                              failed: false, generation: generation, loadKey: loadKey)
            }
            AppStoreScreenshotFixture.loadTracker.record(
                localIdentifier: localIdentifier,
                loaderIdentifier: screenshotFixtureLoaderIdentifier
            )
            return
        }
#endif

        if !showsFullImage,
           let cached = PhotoAssetDisplayCache.shared.thumbnail(for: loadKey) {
            state = .loaded(cached)
            return
        }

        guard let asset = await PhotoAssetResolver.shared.asset(
            localIdentifier: localIdentifier,
            bypassingCache: preservesDisplayedImage
        ) else {
            guard loadGeneration == generation, !Task.isCancelled else { return }
            isLoadingFullImage = false
            fullImageLoadFailed = true
            displayedImageGeneration = nil
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
                self?.consumeResult(image: image, cancelled: cancelled, degraded: degraded,
                                    failed: error != nil, generation: generation, loadKey: loadKey)
            }
        }
    }

    private func consumeResult(image: UIImage?, cancelled: Bool, degraded: Bool,
                               failed: Bool, generation: Int, loadKey: LoadKey) {
        guard loadGeneration == generation, !cancelled,
              finalImageGeneration != generation else { return }
        if let image {
            // Keep a displayed preview during retry; a later degraded callback
            // must not replace it with fewer pixels.
            if case let .loaded(current) = state, degraded,
               image.size.width * image.scale < current.size.width * current.scale {
                // State below still records whether this request failed.
            } else {
                displayedImageGeneration = generation
                state = .loaded(image)
            }
            if !degraded && !failed {
                finalImageGeneration = generation
                isLoadingFullImage = false
                fullImageLoadFailed = false
                if !loadKey.showsFullImage {
                    PhotoAssetDisplayCache.shared.storeThumbnail(image, for: loadKey)
                }
                return
            }
        }
        if failed || (image == nil && !degraded) {
            isLoadingFullImage = false
            fullImageLoadFailed = loadKey.showsFullImage
            if displayedImageGeneration != generation { state = .failed }
        }
    }

    func cancel(preservingImage: Bool = false) {
        loadGeneration &+= 1
        if let requestID {
            PhotoAssetImagePipeline.manager.cancelImageRequest(requestID)
        }
        requestID = nil
        finalImageGeneration = nil
        displayedImageGeneration = nil
        isLoadingFullImage = false
        fullImageLoadFailed = false
        if !preservingImage {
            lastLoadKey = nil
            state = .loading
        }
    }

}
