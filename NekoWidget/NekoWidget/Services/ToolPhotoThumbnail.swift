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

    private static func decode(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)#\(modified?.timeIntervalSinceReferenceDate ?? 0)#\(Int(maxPixel))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = GroupPhotoDecoder.image(at: url, maxPixel: maxPixel) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
