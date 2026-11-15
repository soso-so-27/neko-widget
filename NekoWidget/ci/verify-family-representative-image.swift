import Foundation
import ImageIO
import UniformTypeIdentifiers

func verifyFamilyRepresentativeImage() throws {
    enum Failure: Error { case image, metadata, size }
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: 1400, height: 700, bitsPerComponent: 8,
        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw Failure.image }
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1400, height: 700))
    guard let image = context.makeImage() else { throw Failure.image }
    let input = NSMutableData()
    guard let writer = CGImageDestinationCreateWithData(input, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw Failure.image }
    CGImageDestinationAddImage(writer, image, [
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 35.0, kCGImagePropertyGPSLatitudeRef: "N"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "synthetic private metadata"]
    ] as CFDictionary)
    guard CGImageDestinationFinalize(writer) else { throw Failure.image }
    let prepared = try FamilyNotebookRepresentativePhotoImage.prepare(input as Data)
    guard prepared.width == 1024, prepared.height == 512, prepared.jpeg.count <= 200_000,
          let source = CGImageSourceCreateWithData(prepared.jpeg as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { throw Failure.size }
    guard properties[kCGImagePropertyGPSDictionary] == nil,
          properties[kCGImagePropertyExifDictionary] == nil else { throw Failure.metadata }
}
