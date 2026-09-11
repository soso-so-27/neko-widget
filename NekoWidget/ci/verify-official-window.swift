import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

// Only the container locator is substituted. The catalog, real atomic file
// writer, process/file locks, subscription mutations and image checks ship.
enum SharedContainer {
    static var containerURL: URL? = nil
    static let sharingLifecycleLockURL: URL? = nil
    static let sharingLifecycleStateURL: URL? = nil
    static let sharingCleanupRequiredURL: URL? = nil
}

/// Intercepts the real URLSession byte stream. No request leaves this process.
private final class PreviewURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        let data: Data
        var type = "application/json"
        var status = 200
        var hold = false
    }
    private static let lock = NSLock()
    private static var replies: [String: Reply] = [:]
    private static var paths: [String] = []
    private static var held: [PreviewURLProtocol] = []
    private var reply: Reply?
    private var stopped = false

    static func configure(_ values: [String: Reply]) {
        lock.lock(); defer { lock.unlock() }
        replies = values
        paths = []
    }
    static func requests() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return paths
    }
    static func releaseImages() {
        lock.lock()
        let pending = held
        held = []
        lock.unlock()
        pending.forEach { $0.deliver() }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let path = request.url!.lastPathComponent
        Self.paths.append(path)
        reply = Self.replies[path]
        let hold = reply?.hold == true
        if hold { Self.held.append(self) }
        Self.lock.unlock()
        if !hold { deliver() }
    }
    override func stopLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        stopped = true
    }
    private func deliver() {
        Self.lock.lock()
        let wasStopped = stopped
        let value = reply
        Self.lock.unlock()
        guard !wasStopped else { return }
        guard let value else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: value.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": value.type, "Content-Length": String(value.data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: value.data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main
@MainActor
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

    static func main() async throws {
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
        try await verifyPreview(catalog: active, photo: photo, image: image, root: root, endpoint: endpoint)
        print("Official window: \(assertions) catalog, routing, image, expiry, preview and subscription assertions passed")
    }

    static func verifyPreview(catalog: OfficialWindowCatalog, photo: OfficialCatPhoto, image: Data,
                              root: URL, endpoint: URL) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(catalog)
        let loader = OfficialWindowClient(previewEndpoint: endpoint, protocolClasses: [PreviewURLProtocol.self])
        let model = OfficialWindowPreviewModel()
        let sharedRoot = root.appendingPathComponent("preview-isolation")
        SharedContainer.containerURL = sharedRoot
        defer { SharedContainer.containerURL = nil }
        let directory = sharedRoot.appendingPathComponent("official-window.v1")
        let store = OfficialWindowStore(directory: directory, endpoint: endpoint)
        check(!store.snapshot().isSubscribed, "Preview test must start without consent")
        let stateURL = directory.appendingPathComponent("state.json")
        let originalFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()

        func serve(_ data: Data = body, imageData: Data = image, hold: Bool = false) {
            PreviewURLProtocol.configure([
                "catalog.json": .init(data: data),
                photo.imageFilename: .init(data: imageData, type: "image/jpeg", hold: hold)
            ])
        }
        func waitForImage() async throws {
            let deadline = Date().addingTimeInterval(5)
            while !PreviewURLProtocol.requests().contains(photo.imageFilename) {
                guard Date() < deadline else { fatalError("Real preview loader never requested the JPEG") }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        serve(hold: true)
        let first = Task { await model.load { try await loader.preview() } }
        try await waitForImage()
        let second = Task { await model.load { try await loader.preview() } }
        await Task.yield()
        PreviewURLProtocol.releaseImages()
        await first.value
        await second.value
        check(model.content?.availablePhoto()?.id == photo.id, "Production preview did not render its verified photo")
        check(model.content?.imageData == image, "Preview changed the original JPEG used for full-size viewing")
        check(model.content?.availablePhoto(at: photo.expiresAt) == nil, "Preview survives the exact photo deadline")
        check(model.content?.availablePhoto(at: catalog.validUntil) == nil, "Preview survives the exact catalog deadline")
        check(PreviewURLProtocol.requests() == ["catalog.json", photo.imageFilename], "Discovery and detail duplicated a preview download")
        check(!store.snapshot().isSubscribed && !FileManager.default.fileExists(atPath: stateURL.path), "Preview persisted consent")
        let filesAfterPreview = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        check(filesAfterPreview == originalFiles, "Preview wrote into the received-photo directory")

        for subscribing in [true, false] {
            model.clear()
            serve(hold: true)
            let pending = Task { await model.load { try await loader.preview() } }
            try await waitForImage()
            try store.setSubscribed(subscribing)
            let saved = try Data(contentsOf: stateURL)
            // This is the same generation invalidation used by the shipping UI.
            model.clear()
            PreviewURLProtocol.releaseImages()
            await pending.value
            check(model.content == nil && !model.isLoading, "Late preview repopulated a cleared screen")
            check(store.snapshot().isSubscribed == subscribing, "Preview changed start/stop consent")
            let stateAfterPreview = try Data(contentsOf: stateURL)
            check(stateAfterPreview == saved, "Preview rewrote the new subscription generation")
        }

        serve()
        await model.load { try await loader.preview() }
        let replacement = OfficialCatPhoto(id: "replacement", catID: photo.catID, catName: photo.catName,
                                           credit: photo.credit, caption: nil, photographedOn: nil,
                                           publishedAt: photo.publishedAt, expiresAt: photo.expiresAt,
                                           imageFilename: photo.imageFilename, sha256: photo.sha256,
                                           width: photo.width, height: photo.height)
        let updated = OfficialWindowCatalog(schemaVersion: 1, channelID: "official-cats", enabled: true,
                                            generatedAt: catalog.generatedAt.addingTimeInterval(1),
                                            validUntil: catalog.validUntil, photos: [replacement])
        serve(try encoder.encode(updated), imageData: Data([1, 2, 3]))
        await model.load(force: true) { try await loader.preview() }
        check(model.content?.catalog == updated, "Failed JPEG lost the new removal allowlist")
        check(model.content?.availablePhoto() == nil && model.failed, "Invalid JPEG kept the withdrawn preview visible")
        let paused = OfficialWindowCatalog(schemaVersion: 1, channelID: "official-cats", enabled: false,
                                           generatedAt: catalog.generatedAt.addingTimeInterval(2),
                                           validUntil: catalog.validUntil, photos: [])
        serve(try encoder.encode(paused))
        await model.load(force: true) { try await loader.preview() }
        check(model.content?.catalog.enabled == false && model.content?.availablePhoto() == nil && !model.failed,
              "Pause was rendered as an image failure")
        check(PreviewURLProtocol.requests() == ["catalog.json"], "Paused preview fetched an image")

        for reply in [PreviewURLProtocol.Reply(data: body, type: "text/html"),
                      .init(data: body, status: 302),
                      .init(data: Data(repeating: 32, count: 256 * 1024 + 1))] {
            PreviewURLProtocol.configure(["catalog.json": reply])
            do { _ = try await loader.preview(); fatalError("Preview accepted invalid HTTP/MIME/size") }
            catch { assertions += 1 }
            check(PreviewURLProtocol.requests() == ["catalog.json"], "Invalid response reached the image endpoint")
        }
        let expired = OfficialWindowCatalog(schemaVersion: 1, channelID: "official-cats", enabled: true,
                                            generatedAt: catalog.generatedAt,
                                            validUntil: Date().addingTimeInterval(-1), photos: [photo])
        serve(try encoder.encode(expired))
        do { _ = try await loader.preview(); fatalError("Preview accepted an expired catalog") }
        catch { assertions += 1 }
        check(PreviewURLProtocol.requests() == ["catalog.json"], "Expired catalog reached the image endpoint")
        check(!store.snapshot().isSubscribed, "Preview rejection created a subscription")
    }
}
