import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The preservation server's JPEG framing rule, mirrored on this iPhone
/// (PreservationImageValidator/src/jpeg-envelope.ts and limits.ts). The server
/// answers INVALID_JPEG for anything else, and a saved snapshot is all or
/// nothing, so one such photo stopped every later automatic save (11/16).
/// This is a framing check only; the server still decodes the pixels.
enum PreservationJPEGEnvelope {
    static let maximumBytes = 20 * 1024 * 1024
    static let maximumSide = 4096
    static let maximumMarkers = 4096
    static let maximumScans = 64
    /// The side a re-encoded copy gets: the long side the app already keeps.
    static let repairedSide = 2048

    static func accepts(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes.count <= maximumBytes, bytes[0] == 0xff, bytes[1] == 0xd8 else { return false }
        var at = 2, scans = 0, markers = 0
        var entropy = false
        var frameComponents: Int?
        while at < bytes.count {
            if entropy {
                while at < bytes.count && bytes[at] != 0xff { at += 1 }
                if at >= bytes.count { return false }
            } else if bytes[at] != 0xff { return false }
            while at < bytes.count && bytes[at] == 0xff { at += 1 }
            guard at < bytes.count else { return false }
            let marker = bytes[at]; at += 1
            if entropy && (marker == 0 || (0xd0...0xd7).contains(marker)) { continue }
            entropy = false
            markers += 1
            if markers > maximumMarkers { return false }
            if marker == 0xd9 { return frameComponents != nil && scans > 0 && at == bytes.count }
            let isFrame = marker == 0xc0 || marker == 0xc1 || marker == 0xc2
            let isMetadata = (0xe0...0xef).contains(marker) || marker == 0xfe
            if !isFrame && !isMetadata && ![0xc4, 0xdb, 0xdd, 0xda].contains(marker) { return false }
            guard at + 2 <= bytes.count else { return false }
            let length = Int(bytes[at]) * 256 + Int(bytes[at + 1])
            let end = at + length
            guard length >= 2, end <= bytes.count else { return false }
            let start = at + 2
            // MPF (a second picture, such as an HDR gain map) is refused.
            if marker == 0xe2 && length >= 6 && bytes[start] == 0x4d && bytes[start + 1] == 0x50
                && bytes[start + 2] == 0x46 && bytes[start + 3] == 0 { return false }
            if isFrame {
                guard frameComponents == nil, length >= 8, bytes[start] == 8 else { return false }
                let height = Int(bytes[start + 1]) * 256 + Int(bytes[start + 2])
                let width = Int(bytes[start + 3]) * 256 + Int(bytes[start + 4])
                let components = Int(bytes[start + 5])
                guard [1, 3, 4].contains(components), length == 8 + 3 * components,
                      width > 0, height > 0, width <= maximumSide, height <= maximumSide,
                      width * height <= maximumSide * maximumSide else { return false }
                frameComponents = components
            }
            if marker == 0xda {
                guard let frame = frameComponents, length >= 6 else { return false }
                scans += 1
                if scans > maximumScans { return false }
                let components = Int(bytes[start])
                guard components > 0, components <= frame, length == 6 + 2 * components else { return false }
                entropy = true
            }
            at = end
        }
        return false
    }

    /// The bytes to save: the original when the server accepts it, otherwise
    /// one plain re-encoded JPEG (long side 2048, no metadata, no second
    /// picture). The photo on this iPhone is never changed. Nil when the
    /// pixels cannot be read at all.
    static func conforming(_ data: Data) -> Data? {
        if accepts(data) { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: repairedSide,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        for quality in [0.85, 0.7, 0.5] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            let encoded = output as Data
            if accepts(encoded) { return encoded }
        }
        return nil
    }
}
