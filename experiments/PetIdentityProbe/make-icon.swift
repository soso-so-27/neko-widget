// Original geometric diagnostic icon; no product icon or third-party artwork.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let catalog = root.appendingPathComponent("Generated/ProbeAssets.xcassets")
let appIcon = catalog.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: appIcon, withIntermediateDirectories: true)
// Core Graphics supports this opaque 32-bit layout on headless macOS runners.
guard let context = CGContext(data: nil, width: 1024, height: 1024,
    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Cannot create icon drawing context")
}
context.setFillColor(CGColor(red: 0.09, green: 0.12, blue: 0.15, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
let cat = CGMutablePath()
cat.move(to: CGPoint(x: 260, y: 410))
cat.addLine(to: CGPoint(x: 260, y: 760))
cat.addLine(to: CGPoint(x: 415, y: 655))
cat.addCurve(to: CGPoint(x: 609, y: 655), control1: CGPoint(x: 475, y: 680), control2: CGPoint(x: 549, y: 680))
cat.addLine(to: CGPoint(x: 764, y: 760))
cat.addLine(to: CGPoint(x: 764, y: 410))
cat.addCurve(to: CGPoint(x: 260, y: 410), control1: CGPoint(x: 764, y: 190), control2: CGPoint(x: 260, y: 190))
cat.closeSubpath()
context.addPath(cat)
context.setLineWidth(42)
context.setLineJoin(.round)
context.setStrokeColor(CGColor(red: 0.98, green: 0.67, blue: 0.32, alpha: 1))
context.strokePath()
context.setFillColor(CGColor(gray: 1, alpha: 1))
for x in [405.0, 619.0] {
    context.fillEllipse(in: CGRect(x: x - 24, y: 464, width: 48, height: 48))
}
guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(appIcon.appendingPathComponent("Icon.png") as CFURL,
          UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Cannot encode icon")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Cannot save icon") }
let metadata: [String: Any] = [
    "images": [["filename": "Icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]],
    "info": ["author": "xcode", "version": 1]
]
try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
    .write(to: appIcon.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]])
    .write(to: catalog.appendingPathComponent("Contents.json"))
