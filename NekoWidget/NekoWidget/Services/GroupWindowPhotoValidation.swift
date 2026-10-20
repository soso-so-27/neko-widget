import Foundation
import ImageIO

enum GroupJPEG {
    /// The caller uses the existing normalization pipeline before sending.
    /// Do not send library originals or silently strip/replace source files.
    static func validate(_ bytes: Data) throws {
        guard (4...1_048_548).contains(bytes.count),
              let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1, CGImageSourceGetType(source) as String? == "public.jpeg",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...2048).contains(width), (1...2048).contains(height),
              properties[kCGImagePropertyExifDictionary] == nil, properties[kCGImagePropertyGPSDictionary] == nil,
              properties[kCGImagePropertyTIFFDictionary] == nil,
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              decoded.width == width, decoded.height == height else { throw GroupProtocolError.invalidPhoto }
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let tags = CGImageMetadataCopyTags(metadata) as? [Any], !tags.isEmpty { throw GroupProtocolError.invalidPhoto }
    }
}
