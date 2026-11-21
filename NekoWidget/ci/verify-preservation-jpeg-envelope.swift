import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// 11/16: automatic saving stopped on 「この写真かメモは保存できません」. A
// 「この子のこと」 photo was 6144 px (screen-scale renderer); the server's JPEG
// rule (max side 4096, no MPF, nothing after EOI) answered INVALID_JPEG.

func check(_ condition: Bool, _ name: String) {
    if !condition { FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8)); exit(1) }
    print("ok: \(name)")
}

func jpeg(width: Int, height: Int) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.8, green: 0.5, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    precondition(CGImageDestinationFinalize(destination))
    return output as Data
}

func size(_ data: Data) -> (Int, Int) {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
    return (properties[kCGImagePropertyPixelWidth] as! Int, properties[kCGImagePropertyPixelHeight] as! Int)
}

@main enum Main {
    static func main() {
        let small = jpeg(width: 2048, height: 1536)
        check(PreservationJPEGEnvelope.accepts(small), "2048 px JPEG is accepted")
        check(PreservationJPEGEnvelope.conforming(small) == small, "an accepted photo goes unchanged")
        check(PreservationJPEGEnvelope.accepts(jpeg(width: 4096, height: 3072)), "4096 px is the server's edge")

        let screenScaled = jpeg(width: 6144, height: 4608)
        check(!PreservationJPEGEnvelope.accepts(screenScaled), "6144 px (2048 pt at 3x) is refused like the server")
        guard let repaired = PreservationJPEGEnvelope.conforming(screenScaled) else { return check(false, "repair") }
        check(PreservationJPEGEnvelope.accepts(repaired), "the repaired copy passes the server rule")
        let (w, h) = size(repaired)
        check(max(w, h) == 2048 && w * 3 == h * 4, "the repaired copy keeps the shape at 2048 px")

        var trailing = small; trailing.append(0)
        check(!PreservationJPEGEnvelope.accepts(trailing), "bytes after EOI are refused")
        check(PreservationJPEGEnvelope.conforming(trailing).map(PreservationJPEGEnvelope.accepts) == true, "trailing bytes are repaired")

        // An APP2 MPF segment (as in an HDR gain-map JPEG) right after SOI.
        var mpf = Data([0xff, 0xd8, 0xff, 0xe2, 0x00, 0x08, 0x4d, 0x50, 0x46, 0x00, 0x00, 0x00])
        mpf.append(small.dropFirst(2))
        check(!PreservationJPEGEnvelope.accepts(mpf), "an MPF second picture is refused")
        check(PreservationJPEGEnvelope.conforming(mpf).map(PreservationJPEGEnvelope.accepts) == true, "MPF is repaired")

        check(!PreservationJPEGEnvelope.accepts(Data("not a photo".utf8)), "non-JPEG refused")
        check(PreservationJPEGEnvelope.conforming(Data("not a photo".utf8)) == nil, "unreadable stays an error")

        // The source that made the 6144 px files: the size must be in pixels.
        // 11/21: cleanJPEG uses ImageIO's copy, which counts pixels and
        // never decodes the whole photo.
        let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
        let view = try! String(contentsOf: root.appendingPathComponent("NekoWidget/Views/CatCareView.swift"), encoding: .utf8)
        guard let start = view.range(of: "static func cleanJPEG") else { return check(false, "cleanJPEG present") }
        let body = view[start.lowerBound...].prefix(600)
        check(body.contains("VeterinaryCapture.copy(of: data)") && !body.contains("UIImage(data:"),
              "cleanJPEG reads at most 2048 px")
        let capture = try! String(contentsOf: root.appendingPathComponent("NekoWidget/Views/VeterinaryCapture.swift"), encoding: .utf8)
        check(capture.contains("kCGImageSourceThumbnailMaxPixelSize: copyPixels")
              && capture.contains("static let copyPixels: CGFloat = 2048"), "the copy is 2048 px at most")
    }
}
