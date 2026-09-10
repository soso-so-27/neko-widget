import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

// Only the container locator is substituted. The catalog, real atomic file
// writer, process/file locks, subscription mutations and image checks ship.
enum SharedContainer {
    static let containerURL: URL? = nil
    static let sharingLifecycleLockURL: URL? = nil
    static let sharingLifecycleStateURL: URL? = nil
    static let sharingCleanupRequiredURL: URL? = nil
}

@main
struct OfficialWindowChecks {
    static var assertions = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    static func rejects(_ label: String, _ operation: () throws -> Void) {
        do { try operation(); fatalError("Accepted: \(label)") }
        catch { assertions += 1 }
    }

    static func main() throws {
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 10)
        let bytes = NSMutableData()
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.7, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let destination = CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        check(CGImageDestinationFinalize(destination), "Could not encode synthetic JPEG")
        let image = bytes as Data
        let hash = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        let photo = OfficialCatPhoto(id: "test-photo", catID: "test-cat", catName: "確認用の猫",
                                     credit: "合成テスト", caption: nil, photographedOn: "2026-09-01",
                                     publishedAt: now, expiresAt: now.addingTimeInterval(86400),
                                     imageFilename: hash + ".jpg", sha256: hash, width: 64, height: 48)
        func catalog(_ date: Date = now, enabled: Bool = true, photos: [OfficialCatPhoto] = [photo]) -> OfficialWindowCatalog {
            OfficialWindowCatalog(schemaVersion: 1, channelID: "official-cats", enabled: enabled,
                                  generatedAt: date, validUntil: date.addingTimeInterval(48 * 3600), photos: photos)
        }
        let active = catalog()
        try active.validate(at: now)
        check(active.availablePhotos(at: now).count == 1, "First publication is unavailable")
        check(active.availablePhotos(at: photo.expiresAt).isEmpty, "Photo survives exact expiry")
        check(active.availablePhotos(at: now.addingTimeInterval(-1)).isEmpty, "Future photo leaked")
        check(catalog(enabled: false, photos: []).availablePhotos(at: now).isEmpty, "Paused photo visible")
        rejects("paused catalog with photos") { try catalog(enabled: false).validate(at: now) }
        rejects("duplicate photo ID") { try catalog(photos: [photo, photo]).validate(at: now) }
        rejects("future publication") { try catalog(now.addingTimeInterval(-1)).validate(at: now) }
        rejects("expired edition") { try active.validate(at: active.validUntil) }
        check(!OfficialWindowCatalog.isIdentifier("../private-photo"), "Traversal ID accepted")
        check(!OfficialWindowCatalog.isIdentifier("family-window:foo"), "Private namespace accepted")
        let url = OfficialWindowRoute(photoID: photo.id).url!
        check(OfficialWindowRoute(url: url)?.photoID == photo.id, "Exact photo route did not roundtrip")
        for raw in ["nekowidget://official-window?photo=../x", "nekowidget://official-window?photo=a&photo=b",
                    "nekowidget://official-window?window=private", "nekowidget://official-window/path"] {
            check(OfficialWindowRoute(url: URL(string: raw)!) == nil, "Invalid route accepted")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("official-window-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = URL(string: "https://official.invalid/cats/catalog.json")!
        let store = OfficialWindowStore(directory: root, endpoint: endpoint)
        check(!store.snapshot().isSubscribed, "Fresh installation subscribed itself")
        try store.setSubscribed(true)
        let captured = store.snapshot()
        try store.accept(active, for: captured)
        let revisionBeforeDownload = store.snapshot().imageRevision
        try store.saveImage(image, photo: photo, for: captured)
        check(store.snapshot().imageRevision != revisionBeforeDownload, "Photo download did not invalidate image presentation")
        check(store.imageURL(for: photo) != nil, "Valid JPEG not readable")
        rejects("wrong image bytes") { try store.saveImage(Data([1, 2, 3]), photo: photo, for: captured) }
        try store.setSubscribed(false)
        check(store.snapshot().photos.isEmpty, "Stop left photos selectable")
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent(photo.imageFilename).path), "Stop retained cached JPEG")
        rejects("catalog arriving after stop") { try store.accept(active, for: captured) }
        rejects("image arriving after stop") { try store.saveImage(image, photo: photo, for: captured) }
        try store.setSubscribed(true)
        rejects("old request after resubscribe") { try store.accept(active, for: captured) }
        let resubscribed = store.snapshot()
        try store.accept(active, for: resubscribed)
        try store.saveImage(image, photo: photo, for: resubscribed)
        try store.accept(catalog(now.addingTimeInterval(1), enabled: false, photos: []), for: resubscribed)
        check(store.snapshot().photos.isEmpty && store.imageURL(for: photo) == nil, "Pause retained display")
        rejects("old catalog undoing pause") { try store.accept(active, for: resubscribed) }
        rejects("conflicting edition at same publication time") { try store.accept(catalog(now.addingTimeInterval(1)), for: resubscribed) }
        rejects("old image undoing pause") { try store.saveImage(image, photo: photo, for: resubscribed) }
        let otherEndpoint = OfficialWindowStore(directory: root, endpoint: URL(string: "https://other.invalid/catalog.json"))
        check(!otherEndpoint.snapshot().isSubscribed, "Environment change reused old subscription")
        let disabled = OfficialWindowStore(directory: root, endpoint: nil)
        rejects("unconfigured subscribe") { try disabled.setSubscribed(true) }
        print("Official window: \(assertions) catalog, routing, image, expiry and subscription assertions passed")
    }
}
