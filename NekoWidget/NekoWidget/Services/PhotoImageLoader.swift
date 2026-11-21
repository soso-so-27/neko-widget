@preconcurrency import Photos
import UIKit

struct PhotoImageLoader {
    private let manager = PHImageManager.default()

    func image(
        localIdentifier: String,
        targetSize: CGSize,
        networkAccessAllowed: Bool = true,
        contentMode: PHImageContentMode = .aspectFit
    ) -> UIImage? {
        let fetch = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        )
        guard let asset = fetch.firstObject else { return nil }
        return image(
            for: asset,
            targetSize: targetSize,
            networkAccessAllowed: networkAccessAllowed,
            contentMode: contentMode
        )
    }

    /// 11/21: an iCloud-only photo can wait for the network without end.
    /// A read that may use the network gives up after this and returns nil,
    /// so saving or attaching ends with its own failure instead of hanging.
    static let networkTimeoutSeconds: TimeInterval = 120

    func image(
        for asset: PHAsset,
        targetSize: CGSize,
        networkAccessAllowed: Bool,
        contentMode: PHImageContentMode = .aspectFit
    ) -> UIImage? {
        guard networkAccessAllowed else {
            return requestImage(for: asset, targetSize: targetSize,
                                networkAccessAllowed: false, contentMode: contentMode, request: nil)
        }
        let request = PhotoImageLoadRequest()
        let semaphore = DispatchSemaphore(value: 0)
        let imageManager = self.manager
        DispatchQueue.global(qos: .userInitiated).async {
            let image = Self.requestImage(manager: imageManager, for: asset, targetSize: targetSize,
                                          networkAccessAllowed: true, contentMode: contentMode, request: request)
            request.finish(image)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + Self.networkTimeoutSeconds) == .success else {
            // Stops the download at its next progress report; the late
            // result, if any, is dropped.
            request.abandon()
            return nil
        }
        return request.image
    }

    private func requestImage(
        for asset: PHAsset,
        targetSize: CGSize,
        networkAccessAllowed: Bool,
        contentMode: PHImageContentMode,
        request: PhotoImageLoadRequest?
    ) -> UIImage? {
        Self.requestImage(manager: manager, for: asset, targetSize: targetSize,
                          networkAccessAllowed: networkAccessAllowed, contentMode: contentMode, request: request)
    }

    private static func requestImage(
        manager: PHImageManager,
        for asset: PHAsset,
        targetSize: CGSize,
        networkAccessAllowed: Bool,
        contentMode: PHImageContentMode,
        request: PhotoImageLoadRequest?
    ) -> UIImage? {
        let options = PHImageRequestOptions()
        options.version = .current
        options.resizeMode = .fast
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = networkAccessAllowed
        options.isSynchronous = true
        if let request {
            options.progressHandler = { _, _, stop, _ in
                if request.isAbandoned { stop.pointee = true }
            }
        }

        var result: UIImage?
        manager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: contentMode,
            options: options
        ) { image, info in
            let wasCancelled = (info?[PHImageCancelledKey] as? Bool) == true
            let error = info?[PHImageErrorKey] as? Error
            // 11/20: without network access an iCloud-only photo can come
            // back as its small degraded preview. That is not the photo: the
            // Widget preparation (the only caller without network) leaves it
            // for a later pass instead of drawing an enlarged, blurry copy.
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
            if !wasCancelled, error == nil, networkAccessAllowed || !isDegraded {
                result = image
            }
        }
        return result
    }
}

/// One network read shared between the waiting caller and PhotoKit's thread.
private final class PhotoImageLoadRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var abandoned = false
    private var loadedImage: UIImage?

    var isAbandoned: Bool {
        lock.lock(); defer { lock.unlock() }
        return abandoned
    }

    var image: UIImage? {
        lock.lock(); defer { lock.unlock() }
        return abandoned ? nil : loadedImage
    }

    func finish(_ image: UIImage?) {
        lock.lock(); defer { lock.unlock() }
        if !abandoned { loadedImage = image }
    }

    func abandon() {
        lock.lock(); defer { lock.unlock() }
        abandoned = true
        loadedImage = nil
    }
}
