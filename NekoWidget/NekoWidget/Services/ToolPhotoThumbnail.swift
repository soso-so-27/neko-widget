import ImageIO
import UIKit

/// The kept photos of the tools (迷子・預ける・避難) are shown from a small
/// copy: read once, made small away from the main thread, and kept by file
/// and date, so opening a tool does not decode a full photo on every drawing
/// (11/8). The images and the PDF still read the full photo.
enum ToolPhotoThumbnail {
    /// Longest side for a tile on a tool page.
    static let tileMaxPixel: CGFloat = 600

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 32
        return cache
    }()

    static func load(_ url: URL?, maxPixel: CGFloat = tileMaxPixel) async -> UIImage? {
        guard let url else { return nil }
        return await Task.detached(priority: .userInitiated) {
            decode(url, maxPixel: maxPixel)
        }.value
    }

    /// A copy kept by the caller's key: the photos of 「病院で見せる」, which the
    /// store hands over as checked bytes, never as a file (349).
    static func cached(_ key: String, maxPixel: CGFloat) -> UIImage? {
        cache.object(forKey: "\(key)#\(Int(maxPixel))" as NSString)
    }

    static func load(_ data: Data, key: String, maxPixel: CGFloat) async -> UIImage? {
        if let hit = cached(key, maxPixel: maxPixel) { return hit }
        return await Task.detached(priority: .userInitiated) {
            guard let image = decode(data, maxPixel: maxPixel) else { return nil }
            cache.setObject(image, forKey: "\(key)#\(Int(maxPixel))" as NSString)
            return image
        }.value
    }

    /// Made small straight from the bytes, never decoded whole.
    static func decode(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    private static func decode(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)#\(modified?.timeIntervalSinceReferenceDate ?? 0)#\(Int(maxPixel))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = GroupPhotoDecoder.image(at: url, maxPixel: maxPixel) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
