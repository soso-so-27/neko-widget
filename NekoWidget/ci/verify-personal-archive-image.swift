import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
enum PersonalArchiveImageVerifier {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard let context = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("context") }
        context.setFillColor(CGColor(red: 0.4, green: 0.25, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        guard let image = context.makeImage() else { fatalError("image") }
        let sourceURL = root.appendingPathComponent("private-original.jpg")
        guard let destination = CGImageDestinationCreateWithURL(sourceURL as CFURL,
            UTType.jpeg.identifier as CFString, 1, nil) else { fatalError("destination") }
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 35.0,
                kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 139.0,
                kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "PRIVATE COMMENT"]
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { fatalError("source finalize") }
        let original = try Data(contentsOf: sourceURL)
        let copy = try PersonalArchiveImage.jpeg(from: sourceURL)
        guard let source = CGImageSourceCreateWithData(copy as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("copy decode") }
        try require(decoded.width == 80 && decoded.height == 120, "orientation not applied")
        try require(properties[kCGImagePropertyGPSDictionary] == nil, "GPS copied")
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        try require(exif?[kCGImagePropertyExifUserComment] == nil, "private EXIF copied")
        try require(copy.count <= PersonalArchiveImage.maximumBytes, "size exceeds limit")
        try require(try Data(contentsOf: sourceURL) == original, "original modified")
        let invalid = root.appendingPathComponent("invalid.jpg")
        try Data("not an image".utf8).write(to: invalid)
        do {
            _ = try PersonalArchiveImage.jpeg(from: invalid)
            fatalError("invalid data accepted")
        } catch PersonalArchiveImage.PreparationError.unreadable { }
        print("Personal archive image passed: orientation, metadata privacy, decodable copy, original preserved, invalid input")
    }

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { fatalError(message) }
    }
}
