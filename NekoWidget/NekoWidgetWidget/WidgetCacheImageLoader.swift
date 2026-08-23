import Foundation
import ImageIO
import UIKit

enum WidgetCacheImageLoader {
    private static let absoluteMaximumPixelSize = 1_100
    /// 1100x1100 BGRA is about 4.62 MiB. This per-image guard complements the
    /// provider's two-entry timeline cap; it is not an aggregate process limit.
    private static let maximumDecodedByteEstimate = 5 * 1_024 * 1_024

    /// Decodes the image referenced by one entry. WidgetKit may evaluate both
    /// bounded future entries while accepting a timeline. ImageIO also caps the
    /// decoded dimensions defensively if a malformed or stale cache file is larger
    /// than the family-specific JPEG output expected from the app.
    static func image(
        cacheFilename: String,
        photoSourceIdentifier: String,
        maximumPixelSize: Int
    ) -> UIImage? {
        let requestedMaximumPixelSize = min(
            absoluteMaximumPixelSize,
            max(1, maximumPixelSize)
        )
        let fileHash = SharedLog.shortHash(cacheFilename)
        guard let fileURL = WidgetManifestReader.cacheURL(
            for: cacheFilename,
            photoSourceIdentifier: photoSourceIdentifier
        ) else {
            SharedLog.widget.error(
                "image",
                "Rejected widget cache filename",
                metadata: ["file": fileHash]
            )
            return nil
        }
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            SharedLog.widget.error(
                "image",
                "Widget cache image could not be opened",
                metadata: ["file": fileHash]
            )
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: requestedMaximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            SharedLog.widget.error(
                "image",
                "Widget cache image decode failed",
                metadata: [
                    "bytes": "\(data.count)",
                    "file": fileHash,
                    "requestedMaxPixels": "\(requestedMaximumPixelSize)"
                ]
            )
            return nil
        }

        let decodedByteEstimate = image.bytesPerRow * image.height
        guard decodedByteEstimate <= maximumDecodedByteEstimate else {
            SharedLog.widget.error(
                "image",
                "Widget cache image exceeded the decode memory budget",
                metadata: [
                    "decodedBytesEstimate": "\(decodedByteEstimate)",
                    "file": fileHash,
                    "limit": "\(maximumDecodedByteEstimate)"
                ]
            )
            return nil
        }

        SharedLog.widget.debug(
            "image",
            "Widget cache image decoded",
            metadata: [
                "bytes": "\(data.count)",
                "decodedBytesEstimate": "\(decodedByteEstimate)",
                "file": fileHash,
                "outputPixels": "\(image.width)x\(image.height)",
                "requestedMaxPixels": "\(requestedMaximumPixelSize)"
            ]
        )

        return UIImage(cgImage: image)
    }
}
