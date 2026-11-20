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

    func image(
        for asset: PHAsset,
        targetSize: CGSize,
        networkAccessAllowed: Bool,
        contentMode: PHImageContentMode = .aspectFit
    ) -> UIImage? {
        let options = PHImageRequestOptions()
        options.version = .current
        options.resizeMode = .fast
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = networkAccessAllowed
        options.isSynchronous = true

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
