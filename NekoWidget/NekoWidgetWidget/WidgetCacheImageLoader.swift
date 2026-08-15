import Foundation
import ImageIO
import UIKit

enum WidgetCacheImageLoader {
    private static let maximumPixelSize = 400

    /// Decodes only the image used by the current entry. ImageIO also caps the
    /// decoded dimensions defensively if a malformed or stale cache file is larger
    /// than the app's intended 400 x 400 JPEG output.
    static func image(cacheFilename: String) -> UIImage? {
        let fileHash = SharedLog.shortHash(cacheFilename)
        guard let fileURL = WidgetManifestReader.cacheURL(for: cacheFilename) else {
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
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            SharedLog.widget.error(
                "image",
                "Widget cache image decode failed",
                metadata: [
                    "bytes": "\(data.count)",
                    "file": fileHash,
                    "requestedMaxPixels": "\(maximumPixelSize)"
                ]
            )
            return nil
        }

        SharedLog.widget.debug(
            "image",
            "Widget cache image decoded",
            metadata: [
                "bytes": "\(data.count)",
                "decodedBytesEstimate": "\(image.width * image.height * 4)",
                "file": fileHash,
                "outputPixels": "\(image.width)x\(image.height)",
                "requestedMaxPixels": "\(maximumPixelSize)"
            ]
        )

        return UIImage(cgImage: image)
    }
}
