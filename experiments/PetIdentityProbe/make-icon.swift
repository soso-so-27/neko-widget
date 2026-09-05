// Original geometric diagnostic icon; no product icon or third-party artwork.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let catalog = root.appendingPathComponent("Generated/ProbeAssets.xcassets")
let appIcon = catalog.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: appIcon, withIntermediateDirectories: true)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor(srgbRed: 0.09, green: 0.12, blue: 0.15, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
let cat = NSBezierPath()
cat.move(to: NSPoint(x: 260, y: 410))
cat.line(to: NSPoint(x: 260, y: 760))
cat.line(to: NSPoint(x: 415, y: 655))
cat.curve(to: NSPoint(x: 609, y: 655), controlPoint1: NSPoint(x: 475, y: 680), controlPoint2: NSPoint(x: 549, y: 680))
cat.line(to: NSPoint(x: 764, y: 760))
cat.line(to: NSPoint(x: 764, y: 410))
cat.curve(to: NSPoint(x: 260, y: 410), controlPoint1: NSPoint(x: 764, y: 190), controlPoint2: NSPoint(x: 260, y: 190))
cat.close()
cat.lineWidth = 42
cat.lineJoinStyle = .round
NSColor(srgbRed: 0.98, green: 0.67, blue: 0.32, alpha: 1).setStroke()
cat.stroke()
NSColor.white.setFill()
for x in [405.0, 619.0] {
    NSBezierPath(ovalIn: NSRect(x: x - 24, y: 464, width: 48, height: 48)).fill()
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: appIcon.appendingPathComponent("Icon.png"))
let metadata: [String: Any] = [
    "images": [["filename": "Icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]],
    "info": ["author": "xcode", "version": 1]
]
try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
    .write(to: appIcon.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]])
    .write(to: catalog.appendingPathComponent("Contents.json"))
