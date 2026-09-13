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
    private static var urls: [URL] = []
    private static var held: [PreviewURLProtocol] = []
    private var reply: Reply?
    private var stopped = false

    static func configure(_ values: [String: Reply]) {
        lock.lock(); defer { lock.unlock() }
        replies = values
        paths = []
        urls = []
    }
    static func requests() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return paths
    }
    static func requestedURLs() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return urls
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
        Self.urls.append(request.url!)
        reply = Self.replies[request.url!.absoluteString] ?? Self.replies[path]
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
        try await verifyPublicWindows(catalog: active, photo: photo, image: image,
                                      root: root.appendingPathComponent("multi-window"), endpoint: endpoint)
        print("Official window: \(assertions) catalog, routing, image, expiry, preview and subscription assertions passed")
    }

    static func waitFor(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { fatalError(message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func verifyPublicWindows(catalog: OfficialWindowCatalog, photo: OfficialCatPhoto, image: Data,
                                    root: URL, endpoint: URL) async throws {
        let definitionA = PublicWindowDefinition(id: "official-cats", displayName: "A", subtitle: "既存", endpoint: endpoint)
        let endpointB = URL(string: "https://official.invalid/dusk/catalog.json")!
        let definitionB = PublicWindowDefinition(id: "dusk-cats", displayName: "B", subtitle: "確認用", endpoint: endpointB)
        let a = OfficialWindowStore.forWindow(definitionA, containerURL: root)
        let b = OfficialWindowStore.forWindow(definitionB, containerURL: root)
        check(a.directory?.lastPathComponent == "official-window.v1", "Legacy directory moved")
        check(b.directory?.deletingLastPathComponent().lastPathComponent == "public-windows.v1"
              && b.directory?.lastPathComponent == definitionB.id, "Public directory is not ID-scoped")
        check(a.directory != b.directory && b.windowID == definitionB.id && b.displayName == "B", "Store lost its definition")
        let invalidDefinition = PublicWindowDefinition(id: "../escape", displayName: "無効", subtitle: "確認用", endpoint: endpoint)
        check(OfficialWindowStore.forWindow(invalidDefinition, containerURL: root).directory == nil, "Definition escaped its storage root")
        for raw in ["http://official.invalid/catalog.json", "https://user@official.invalid/catalog.json",
                    "https://official.invalid/catalog.json?other=1", "https://official.invalid:443/catalog.json"] {
            let invalid = OfficialWindowStore(directory: root, definition: PublicWindowDefinition(
                id: definitionB.id, displayName: "B", subtitle: "確認用", endpoint: URL(string: raw)))
            check(invalid.endpoint == nil, "Unpinned endpoint shape accepted")
            rejects("invalid endpoint subscription") { try invalid.setSubscribed(true) }
        }
        let productionDefinitions = OfficialWindowConfiguration.definitions
        check(productionDefinitions.map(\.id) == ["official-cats", "nap-cats"], "Product public-window registry changed")
        check(productionDefinitions == OfficialWindowConfiguration.definitions(baseFeedURL: OfficialWindowConfiguration.feedURL),
              "Production bypassed the validated base feed configuration")
        check(productionDefinitions[0].endpoint == OfficialWindowConfiguration.feedURL
              && productionDefinitions[0].displayName == OfficialWindowCatalog.displayName, "Legacy definition changed")
        check(productionDefinitions[1].displayName == "おひるね" && productionDefinitions[1].subtitle == "お昼寝中の猫の写真"
              && OfficialWindowConfiguration.definition(for: "nap-cats") == productionDefinitions[1], "Nap window definition is unavailable")
        for (base, expected) in [
            ("https://official.invalid/catalog.json", "https://official.invalid/windows/nap-cats/catalog.json"),
            ("https://official.invalid/preview/v1/catalog.json", "https://official.invalid/preview/v1/windows/nap-cats/catalog.json"),
            ("https://official.invalid/cat%20photos/catalog.json", "https://official.invalid/cat%20photos/windows/nap-cats/catalog.json")
        ] {
            let configured = OfficialWindowConfiguration.definitions(baseFeedURL: URL(string: base))
            check(configured[0].endpoint?.absoluteString == base, "Derivation changed the legacy endpoint")
            check(configured[1].endpoint?.absoluteString == expected, "Nap feed escaped its configured path base")
        }
        check(OfficialWindowConfiguration.definitions(baseFeedURL: nil).allSatisfy { $0.endpoint == nil },
              "Missing base enabled a public feed")
        for raw in ["http://official.invalid/catalog.json", "https://user@official.invalid/catalog.json",
                    "https://official.invalid:443/catalog.json", "https://official.invalid/catalog.json?other=1",
                    "https://official.invalid/catalog.json#other", "https://official.invalid/feed.json",
                    "https://official.invalid/catalog.json/", "/catalog.json"] {
            let configured = OfficialWindowConfiguration.definitions(baseFeedURL: URL(string: raw))
            check(configured.allSatisfy { $0.endpoint == nil }, "Invalid base enabled a public feed")
        }
        let configured = OfficialWindowConfiguration.definitions(baseFeedURL: endpoint)
        let configuredRoot = root.appendingPathComponent("production-definitions")
        let configuredLegacy = OfficialWindowStore.forWindow(configured[0], containerURL: configuredRoot)
        let configuredNap = OfficialWindowStore.forWindow(configured[1], containerURL: configuredRoot)
        check(configuredLegacy.directory?.lastPathComponent == "official-window.v1"
              && configuredNap.directory?.lastPathComponent == "nap-cats"
              && configuredNap.directory?.deletingLastPathComponent().lastPathComponent == "public-windows.v1",
              "Production stores lost legacy compatibility or nap isolation")
        check(configured[0].widgetSourceID == "official-cats" && configured[1].widgetSourceID == "public-window:nap-cats",
              "Production Widget sources collide")
        try configuredLegacy.setSubscribed(true)
        check(!configuredNap.snapshot().isSubscribed, "Legacy subscription enabled nap delivery")
        try configuredNap.setSubscribed(true)
        try configuredLegacy.setSubscribed(false)
        check(configuredNap.snapshot().isSubscribed, "Stopping legacy disabled nap delivery")
        check(OfficialWindowConfiguration.definition(for: "unknown-cats") == nil, "Unknown registry ID fell back to legacy")
        check(definitionA.widgetSourceID == "official-cats" && definitionB.widgetSourceID == "public-window:dusk-cats", "Widget IDs changed")
        check(PublicWindowDefinition.windowID(from: "public-window:unknown-cats") == "unknown-cats", "Unknown public Widget ID fell back")
        for source in ["public-window:", "public-window:../cats", "public-window:CAT", "family-window:cats", "random"] {
            check(PublicWindowDefinition.windowID(from: source) == nil, "Malformed source ID accepted")
        }
        let oldRoute = OfficialWindowRoute(photoID: photo.id)
        check(oldRoute.url?.absoluteString == "nekowidget://official-window?photo=test-photo", "Legacy URL changed")
        let newRoute = OfficialWindowRoute(windowID: definitionB.id, photoID: photo.id)
        check(newRoute.url?.absoluteString == "nekowidget://public-window?window=dusk-cats&photo=test-photo", "Public URL changed")
        check(OfficialWindowRoute(url: newRoute.url!)?.windowID == definitionB.id && newRoute.id != oldRoute.id, "Routes conflate equal photo IDs")
        check(OfficialWindowRoute(url: URL(string: "nekowidget://public-window?window=unknown-cats")!)?.windowID == "unknown-cats", "Unknown route fell back")
        for raw in ["nekowidget://public-window", "nekowidget://public-window?photo=cat", "nekowidget://public-window?window=a&window=b",
                    "nekowidget://public-window?window=a&photo=x&photo=y", "nekowidget://public-window?window=a&extra=b",
                    "nekowidget://public-window?window=../cats", "nekowidget://public-window/path?window=a",
                    "nekowidget://public-window?window=a#x", "nekowidget://user@public-window?window=a"] {
            check(OfficialWindowRoute(url: URL(string: raw)!) == nil, "Malformed public route accepted")
        }

        let photoB = OfficialCatPhoto(id: photo.id, catID: photo.catID, catName: "Bの猫", credit: photo.credit,
                                     caption: nil, photographedOn: photo.photographedOn, publishedAt: photo.publishedAt,
                                     expiresAt: photo.expiresAt, imageFilename: photo.imageFilename, sha256: photo.sha256,
                                     width: photo.width, height: photo.height)
        let catalogB = OfficialWindowCatalog(schemaVersion: 1, channelID: definitionB.id, enabled: true,
                                            generatedAt: catalog.generatedAt, validUntil: catalog.validUntil, photos: [photoB])
        try catalogB.validate(at: Date(), expectedChannelID: definitionB.id)
        rejects("B catalog on legacy validation") { try catalogB.validate(at: Date()) }
        rejects("A catalog on B validation") { try catalog.validate(at: Date(), expectedChannelID: definitionB.id) }

        // Simulate the exact old state format by omitting only the new key.
        _ = a.snapshot()
        let legacyState = OfficialWindowState(subscriptionID: UUID(), endpoint: endpoint, catalog: catalog)
        let stateURL = a.directory!.appendingPathComponent("state.json")
        try AtomicJSON.write(legacyState, to: stateURL)
        var legacyJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
        legacyJSON.removeValue(forKey: "windowID")
        try JSONSerialization.data(withJSONObject: legacyJSON).write(to: stateURL, options: .atomic)
        check(a.snapshot().subscriptionID == legacyState.subscriptionID && a.snapshot().photos == [photo], "Old state did not decode as legacy")
        let wrongOwner = OfficialWindowStore(directory: a.directory, definition: PublicWindowDefinition(
            id: definitionB.id, displayName: "B", subtitle: "確認用", endpoint: endpoint))
        check(!wrongOwner.snapshot().isSubscribed, "Old unscoped data became a new window subscription")
        let requestA = a.snapshot()
        try a.saveImage(image, photo: photo, for: requestA)
        try b.setSubscribed(true)
        let requestB = b.snapshot()
        try b.accept(catalogB, for: requestB)
        try b.saveImage(image, photo: photoB, for: requestB)
        check(a.imageURL(for: photo) != b.imageURL(for: photoB), "Equal hashes share a cache path across windows")
        check(a.imageURL(for: photoB) == nil && b.imageURL(for: photo) == nil, "Filename-only lookup accepted the other photo struct")
        rejects("wrong-channel store accept") { try b.accept(catalog, for: requestB) }
        rejects("foreign photo with equal hash") { try b.saveImage(image, photo: photo, for: requestB) }
        var wrongRequest = requestB
        wrongRequest.windowID = definitionA.id
        rejects("request from another window") { try b.accept(catalogB, for: wrongRequest) }
        wrongRequest = requestB
        wrongRequest.endpoint = endpoint
        rejects("request from another endpoint") { try b.saveImage(image, photo: photoB, for: wrongRequest) }
        try a.setSubscribed(false)
        check(b.snapshot().subscriptionID == requestB.subscriptionID && b.imageURL(for: photoB) != nil, "Stopping A changed B")
        rejects("late A catalog after stop") { try a.accept(catalog, for: requestA) }
        rejects("late A bytes after stop") { try a.saveImage(image, photo: photo, for: requestA) }
        let expiredB = OfficialWindowCatalog(schemaVersion: 1, channelID: definitionB.id, enabled: true,
                                            generatedAt: catalog.generatedAt, validUntil: Date().addingTimeInterval(-1), photos: [photoB])
        var expiredState = b.snapshot()
        expiredState.catalog = expiredB
        try AtomicJSON.write(expiredState, to: b.directory!.appendingPathComponent("state.json"))
        check(b.snapshot().isSubscribed && b.snapshot().photos.isEmpty && b.imageURL(for: photoB) == nil, "Expired B remained visible or lost consent")
        rejects("late B image after catalog expiry") { try b.saveImage(image, photo: photoB, for: requestB) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bodyA = try encoder.encode(catalog)
        let bodyB = try encoder.encode(catalogB)
        let imageA = endpoint.deletingLastPathComponent().appendingPathComponent(photo.imageFilename)
        let imageB = endpointB.deletingLastPathComponent().appendingPathComponent(photo.imageFilename)
        let loader = OfficialWindowClient(previewEndpoint: endpoint, protocolClasses: [PreviewURLProtocol.self])
        func serve(holdA: Bool = false, holdB: Bool = false) {
            PreviewURLProtocol.configure([
                endpoint.absoluteString: .init(data: bodyA), endpointB.absoluteString: .init(data: bodyB),
                imageA.absoluteString: .init(data: image, type: "image/jpeg", hold: holdA),
                imageB.absoluteString: .init(data: image, type: "image/jpeg", hold: holdB)
            ])
        }

        // A held download must not serialize B; stopping A rejects only A's
        // eventual bytes. Both calls exercise the production client actor.
        try a.setSubscribed(true)
        try b.setSubscribed(true)
        serve(holdA: true)
        let refreshingA = Task { try await loader.refresh(store: a) }
        try await waitFor("A never requested its image") { PreviewURLProtocol.requestedURLs().contains(imageA) }
        let refreshingB = Task { try await loader.refresh(store: b) }
        try await waitFor("A's pending request blocked B") { b.imageURL(for: photoB) != nil }
        try a.setSubscribed(false)
        try await refreshingB.value
        PreviewURLProtocol.releaseImages()
        do { try await refreshingA.value; fatalError("Late A request succeeded after stop") }
        catch { assertions += 1 }
        check(a.snapshot().photos.isEmpty && b.imageURL(for: photoB) != nil, "Late A response changed B")

        // Same ID and endpoint in a different container must not join A's task.
        let twin = OfficialWindowStore.forWindow(definitionA, containerURL: root.appendingPathComponent("other-container"))
        try a.setSubscribed(true)
        try twin.setSubscribed(true)
        serve(holdA: true)
        let firstDirectory = Task { try await loader.refresh(store: a) }
        try await waitFor("First directory never requested image") { PreviewURLProtocol.requestedURLs().contains(imageA) }
        let secondDirectory = Task { try await loader.refresh(store: twin) }
        try await waitFor("Same endpoint in a different directory was coalesced") {
            PreviewURLProtocol.requestedURLs().filter { $0 == imageA }.count == 2
        }
        try a.setSubscribed(false)
        PreviewURLProtocol.releaseImages()
        try await secondDirectory.value
        do { try await firstDirectory.value; fatalError("Stopped directory accepted delayed bytes") }
        catch { assertions += 1 }
        check(twin.imageURL(for: photo) != nil && a.imageURL(for: photo) == nil, "Directory-scoped generation failed")

        // A rebuilt endpoint for the same ID/directory starts independently;
        // its new generation cannot be overwritten by the old endpoint.
        let changedEndpoint = URL(string: "https://official.invalid/changed/catalog.json")!
        let changedImage = changedEndpoint.deletingLastPathComponent().appendingPathComponent(photo.imageFilename)
        let changedStore = OfficialWindowStore(directory: a.directory, definition: PublicWindowDefinition(
            id: definitionA.id, displayName: "A", subtitle: "確認用", endpoint: changedEndpoint))
        try a.setSubscribed(true)
        PreviewURLProtocol.configure([
            endpoint.absoluteString: .init(data: bodyA), imageA.absoluteString: .init(data: image, type: "image/jpeg", hold: true),
            changedEndpoint.absoluteString: .init(data: bodyA), changedImage.absoluteString: .init(data: image, type: "image/jpeg")
        ])
        let oldEndpointTask = Task { try await loader.refresh(store: a) }
        try await waitFor("Old endpoint never requested image") { PreviewURLProtocol.requestedURLs().contains(imageA) }
        try changedStore.setSubscribed(true)
        let changedRequest = changedStore.snapshot()
        let changedEndpointTask = Task { try await loader.refresh(store: changedStore) }
        try await waitFor("Old pending endpoint blocked its replacement") { changedStore.imageURL(for: photo) != nil }
        try await changedEndpointTask.value
        PreviewURLProtocol.releaseImages()
        do { try await oldEndpointTask.value; fatalError("Old endpoint accepted late bytes") }
        catch { assertions += 1 }
        check(changedStore.snapshot().subscriptionID == changedRequest.subscriptionID && !a.snapshot().isSubscribed,
              "Late endpoint response replaced the new subscription")

        // Coalesce concurrent equivalent requests using the effective 1...6
        // cap, rather than refetching for different over-limit input values.
        try a.setSubscribed(true)
        serve(holdA: true)
        let cappedFirst = Task { try await loader.refresh(store: a, maximumImages: 600) }
        try await waitFor("Capped refresh never requested image") { PreviewURLProtocol.requestedURLs().contains(imageA) }
        let cappedSecond = Task { try await loader.refresh(store: a, maximumImages: 999) }
        try await Task.sleep(for: .milliseconds(100))
        PreviewURLProtocol.releaseImages()
        try await cappedFirst.value
        try await cappedSecond.value
        check(PreviewURLProtocol.requestedURLs().filter { $0 == endpoint }.count == 1, "Equivalent image limits refetched the catalog")
        try a.setSubscribed(true)
        serve(holdA: true)
        let smaller = Task { try await loader.refresh(store: a, maximumImages: 1) }
        try await waitFor("Small refresh never requested image") { PreviewURLProtocol.requestedURLs().contains(imageA) }
        let larger = Task { try await loader.refresh(store: a, maximumImages: 2) }
        try await Task.sleep(for: .milliseconds(100))
        PreviewURLProtocol.releaseImages()
        try await smaller.value
        try await larger.value
        check(PreviewURLProtocol.requestedURLs().filter { $0 == endpoint }.count == 2, "Larger joined request did not refresh its image budget")

        // Preview uses each supplied store's endpoint, validates its channel,
        // and never persists consent or a received image for either window.
        try a.setSubscribed(false)
        try b.setSubscribed(false)
        let savedA = try Data(contentsOf: stateURL)
        let stateBURL = b.directory!.appendingPathComponent("state.json")
        let savedB = try Data(contentsOf: stateBURL)
        let previewA = OfficialWindowPreviewModel()
        let previewB = OfficialWindowPreviewModel(windowID: definitionB.id)
        serve(holdA: true)
        let browsingA = Task { await previewA.load { try await loader.preview(store: a) } }
        try await waitFor("A preview never requested image") { PreviewURLProtocol.requestedURLs().contains(imageA) }
        await previewB.load { try await loader.preview(store: b) }
        check(previewB.content?.availablePhoto() == photoB, "B preview used A's catalog or endpoint")
        check(previewB.content?.availablePhoto(at: photoB.expiresAt) == nil, "B preview survived its photo deadline")
        previewA.clear()
        PreviewURLProtocol.releaseImages()
        await browsingA.value
        check(previewA.content == nil && previewB.content?.availablePhoto() == photoB, "Clearing A's late preview changed B")
        previewB.clear()
        await previewB.load { OfficialWindowPreview(catalog: catalog, photo: photo, imageData: image) }
        check(previewB.content == nil && previewB.failed, "B model accepted A's preview")
        PreviewURLProtocol.configure([endpointB.absoluteString: .init(data: bodyA)])
        do { _ = try await loader.preview(store: b); fatalError("B client accepted A's channel") }
        catch { assertions += 1 }
        check(PreviewURLProtocol.requestedURLs() == [endpointB], "Wrong channel fetched image bytes")
        let afterPreviewA = try Data(contentsOf: stateURL)
        let afterPreviewB = try Data(contentsOf: stateBURL)
        check(afterPreviewA == savedA && afterPreviewB == savedB, "Preview wrote into a received state")
        check(a.imageURL(for: photo) == nil && b.imageURL(for: photoB) == nil, "Preview saved a Widget image")
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
