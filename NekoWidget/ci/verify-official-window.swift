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
        try await verifyCatWindow(catalog: active, photo: photo, image: image,
                                  root: root.appendingPathComponent("cat-window"), endpoint: endpoint)
        try await verifyProgramme(root: root, endpoint: endpoint, photo: photo)
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
        let productionDefinitions = OfficialWindowConfiguration.definitions(baseFeedURL: OfficialWindowConfiguration.feedURL, blackCatDailyEnabled: true)
        check(productionDefinitions.map(\.id) == ["black-cats"], "Unavailable public windows appeared in discovery")
        check(OfficialWindowConfiguration.definitions(baseFeedURL: endpoint, blackCatDailyEnabled: false).map(\.id)
            == ["official-cats", "nap-cats", "cat-tabby-nap"], "Internal black-cat discovery leaked into the public build")
        check(OfficialWindowConfiguration.definitions == OfficialWindowConfiguration.definitions(baseFeedURL: OfficialWindowConfiguration.feedURL, blackCatDailyEnabled: Version1.isOn),
              "Production bypassed the validated base feed configuration")
        check(OfficialWindowConfiguration.definition(for: "official-cats")?.displayName == OfficialWindowCatalog.displayName,
              "Legacy subscription definition was lost")
        check(productionDefinitions[0].displayName == "黒猫のまど", "Black-cat window unavailable")
        check(productionDefinitions[0].catID == nil,
              "Mixed public feeds gained a cat constraint")
        check(OfficialWindowConfiguration.definition(for: "nap-cats")?.displayName == "おひるね"
              && OfficialWindowConfiguration.definition(forCatID: "generated-tabby-nap")?.id == "cat-tabby-nap",
              "Legacy subscription or exact cat lookup was lost")
        for id in ["", "generated-tabby", "Generated-tabby-nap", "generated-tabby-nap ", "unknown-cat"] {
            check(OfficialWindowConfiguration.definition(forCatID: id) == nil, "Cat lookup guessed a different identity")
        }
        for (base, expected) in [
            ("https://official.invalid/catalog.json", "https://official.invalid/windows/nap-cats/catalog.json"),
            ("https://official.invalid/preview/v1/catalog.json", "https://official.invalid/preview/v1/windows/nap-cats/catalog.json"),
            ("https://official.invalid/cat%20photos/catalog.json", "https://official.invalid/cat%20photos/windows/nap-cats/catalog.json")
        ] {
            let configured = OfficialWindowConfiguration.definitions(baseFeedURL: URL(string: base), blackCatDailyEnabled: true)
            check(configured[0].endpoint?.absoluteString == expected.replacingOccurrences(of: "/nap-cats/", with: "/black-cats/"), "Black-cat feed escaped its configured path base")
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
        let configured = OfficialWindowConfiguration.definitions(baseFeedURL: endpoint, blackCatDailyEnabled: true)
        let configuredRoot = root.appendingPathComponent("production-definitions")
        let legacy = PublicWindowDefinition(id: OfficialWindowCatalog.sourceID, displayName: OfficialWindowCatalog.displayName,
            subtitle: "以前のまど", endpoint: endpoint)
        let configuredLegacy = OfficialWindowStore.forWindow(legacy, containerURL: configuredRoot)
        let configuredNap = OfficialWindowStore.forWindow(configured[0], containerURL: configuredRoot)
        check(configuredLegacy.directory?.lastPathComponent == "official-window.v1"
              && configuredNap.directory?.lastPathComponent == "black-cats"
              && configuredNap.directory?.deletingLastPathComponent().lastPathComponent == "public-windows.v1",
              "Production stores lost legacy compatibility or nap isolation")
        check(legacy.widgetSourceID == "official-cats" && configured[0].widgetSourceID == "public-window:black-cats",
              "Production Widget sources collide")
        let weeklyDefinition = PublicWindowDefinition(id: "weekly-theme", displayName: "今週のテーマ", subtitle: "以前のまど",
            endpoint: endpoint.deletingLastPathComponent().appendingPathComponent("windows/weekly-theme/catalog.json"))
        let configuredCat = OfficialWindowStore.forWindow(weeklyDefinition, containerURL: configuredRoot)
        check(configuredCat.directory?.lastPathComponent == "weekly-theme"
              && configuredCat.directory != configuredNap.directory && configuredCat.directory != configuredLegacy.directory
              && weeklyDefinition.widgetSourceID == "public-window:weekly-theme", "Cat store or Widget source collides")
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

    static func verifyCatWindow(catalog: OfficialWindowCatalog, photo: OfficialCatPhoto, image: Data,
                                root: URL, endpoint: URL) async throws {
        // Old saved cat-window subscriptions remain supported after discovery changes.
        let definition = PublicWindowDefinition(id: "cat-tabby-nap", displayName: "キジ白のまど", subtitle: "この猫の写真",
            endpoint: endpoint.deletingLastPathComponent().appendingPathComponent("windows/cat-tabby-nap/catalog.json"), catID: "generated-tabby-nap")
        let catID = definition.catID!
        let store = OfficialWindowStore.forWindow(definition, containerURL: root)
        let stateURL = store.directory!.appendingPathComponent("state.json")
        func tagged(_ id: String, _ catID: String) -> OfficialCatPhoto {
            OfficialCatPhoto(id: id, catID: catID, catName: photo.catName, credit: photo.credit,
                             caption: photo.caption, photographedOn: photo.photographedOn, publishedAt: photo.publishedAt,
                             expiresAt: photo.expiresAt, imageFilename: photo.imageFilename, sha256: photo.sha256,
                             width: photo.width, height: photo.height)
        }
        let own = tagged(photo.id, catID), other = tagged("other-photo", "another-cat")
        func feed(_ photos: [OfficialCatPhoto], validUntil: Date? = nil) -> OfficialWindowCatalog {
            OfficialWindowCatalog(schemaVersion: 1, channelID: definition.id, enabled: true,
                                  generatedAt: catalog.generatedAt, validUntil: validUntil ?? catalog.validUntil, photos: photos)
        }
        let valid = feed([own]), mixed = feed([own, other]), wrong = feed([other])
        try valid.validate(at: Date(), expectedChannelID: definition.id, expectedCatID: catID)
        rejects("wrong cat in catalog") { try wrong.validate(at: Date(), expectedChannelID: definition.id, expectedCatID: catID) }
        rejects("one foreign cat in mixed catalog") { try mixed.validate(at: Date(), expectedChannelID: definition.id, expectedCatID: catID) }
        rejects("invalid build cat constraint") { try valid.validate(at: Date(), expectedChannelID: definition.id, expectedCatID: "../cat") }
        for id in ["official-cats", "nap-cats"] {
            let compatible = OfficialWindowCatalog(schemaVersion: 1, channelID: id, enabled: true,
                generatedAt: catalog.generatedAt, validUntil: catalog.validUntil, photos: [own, other])
            try compatible.validate(at: Date(), expectedChannelID: id)
            let mixedDefinition = PublicWindowDefinition(id: id, displayName: "確認", subtitle: "確認", endpoint: endpoint)
            let mixedStore = OfficialWindowStore.forWindow(mixedDefinition, containerURL: root)
            try mixedStore.setSubscribed(true)
            try mixedStore.accept(compatible, for: mixedStore.snapshot())
            check(mixedStore.snapshot().photos.count == 2, "Nil cat constraint rejected a legacy mixed feed")
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let loader = OfficialWindowClient(previewEndpoint: endpoint, protocolClasses: [PreviewURLProtocol.self])
        let catEndpoint = definition.endpoint!
        let imageURL = catEndpoint.deletingLastPathComponent().appendingPathComponent(own.imageFilename)
        func serve(_ value: OfficialWindowCatalog) throws {
            PreviewURLProtocol.configure([
                catEndpoint.absoluteString: .init(data: try encoder.encode(value)),
                imageURL.absoluteString: .init(data: image, type: "image/jpeg")
            ])
        }
        let model = OfficialWindowPreviewModel(windowID: definition.id)
        try serve(valid)
        await model.load { try await loader.preview(store: store) }
        check(model.content?.availablePhoto() == own, "Unsubscribed cat preview rejected its own photo")
        check(!FileManager.default.fileExists(atPath: store.directory!.path), "Cat preview created received storage")
        model.clear()
        await model.load { OfficialWindowPreview(catalog: mixed, photo: own, imageData: image) }
        check(model.content == nil && model.failed, "Cat preview model accepted a mixed catalog")
        try serve(wrong)
        do { _ = try await loader.preview(store: store); fatalError("Cat preview fetched another cat") }
        catch { assertions += 1 }
        check(PreviewURLProtocol.requestedURLs() == [catEndpoint], "Wrong cat preview fetched JPEG bytes")
        check(!FileManager.default.fileExists(atPath: stateURL.path), "Rejected cat preview persisted a subscription")

        try store.setSubscribed(true)
        let request = store.snapshot()
        try store.accept(valid, for: request)
        try store.saveImage(image, photo: own, for: request)
        check(store.snapshot().photos == [own] && store.imageURL(for: own) != nil
              && store.imageURL(filename: own.imageFilename) != nil, "Cat cache was not available to Widget readers")
        rejects("store accepting mixed cats") { try store.accept(mixed, for: request) }
        rejects("same JPEG with another cat metadata") { try store.saveImage(image, photo: other, for: request) }
        let original = store.snapshot()
        let savedJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
        check(savedJSON["expectedCatID"] == nil && savedJSON["catID"] == nil, "Build cat constraint was persisted")
        var corrupt = original
        corrupt.catalog = wrong
        try AtomicJSON.write(corrupt, to: stateURL)
        var injected = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
        injected["expectedCatID"] = other.catID
        injected["catID"] = other.catID
        try JSONSerialization.data(withJSONObject: injected).write(to: stateURL, options: .atomic)
        check(store.snapshot().isSubscribed && store.snapshot().photos.isEmpty
              && store.imageURL(for: other) == nil && store.imageURL(filename: other.imageFilename) == nil,
              "Disk cat constraint overrode the build or exposed another cat to Widget")
        rejects("foreign image into corrupted cat cache") { try store.saveImage(image, photo: other, for: request) }
        var expired = original
        expired.catalog = feed([own], validUntil: Date().addingTimeInterval(-1))
        try AtomicJSON.write(expired, to: stateURL)
        check(store.snapshot().subscriptionID == request.subscriptionID && store.snapshot().photos.isEmpty
              && store.imageURL(for: own) == nil, "Expired cat catalog stayed visible or lost subscription")
        rejects("image after cat catalog expiry") { try store.saveImage(image, photo: own, for: request) }

        try store.setSubscribed(true)
        try serve(mixed)
        do { try await loader.refresh(store: store); fatalError("Cat refresh accepted a mixed feed") }
        catch { assertions += 1 }
        check(store.snapshot().isSubscribed && store.snapshot().photos.isEmpty
              && PreviewURLProtocol.requestedURLs() == [catEndpoint], "Rejected cat refresh changed consent or fetched bytes")
        try serve(valid)
        try await loader.refresh(store: store)
        check(store.snapshot().photos == [own] && store.imageURL(for: own) != nil, "Valid cat refresh did not recover")
        try store.setSubscribed(false)
        rejects("cat catalog after stop") { try store.accept(valid, for: request) }
        check(store.imageURL(for: own) == nil, "Stopped cat feed retained Widget media")
    }

    static func verifyProgramme(root: URL, endpoint: URL, photo: OfficialCatPhoto) async throws {
        let iso = ISO8601DateFormatter(), cutover = iso.date(from: "2026-10-22T09:00:00Z")!
        func posted(_ at: Date, _ id: String) -> OfficialCatPhoto {
            OfficialCatPhoto(id: id, catID: photo.catID, catName: photo.catName, credit: photo.credit,
                caption: nil, photographedOn: nil, publishedAt: at, expiresAt: at.addingTimeInterval(7 * 86400),
                imageFilename: photo.imageFilename, sha256: photo.sha256, width: photo.width, height: photo.height)
        }
        let yesterday = posted(cutover.addingTimeInterval(-86400), "yesterday"), today = posted(cutover, "today")
        let daily = OfficialWindowCatalog(schemaVersion: 1, channelID: "official-cats", enabled: true,
            generatedAt: cutover, validUntil: cutover.addingTimeInterval(2 * 86400), photos: [yesterday, today])
        check(daily.widgetPhotos(at: cutover, blackCatDailyEnabled: true).map(\.id) == ["today", "yesterday"],
              "The shipped official channel gained the black-cat selection policy")
        check(daily.widgetPhotos(at: cutover, blackCatDailyEnabled: false).map(\.id) == ["today", "yesterday"],
              "Public Widget selection changed")
        check(daily.widgetDeadline(for: today, blackCatDailyEnabled: false) == daily.validUntil,
              "Public Widget deadline changed")
        let black = OfficialWindowCatalog(schemaVersion: 1, channelID: "black-cats", enabled: true,
            generatedAt: cutover, validUntil: daily.validUntil, photos: [yesterday, today])
        check(black.widgetPhotos(at: cutover, blackCatDailyEnabled: false).map(\.id) == ["today", "yesterday"],
              "Black-cat daily selection escaped the internal gate")
        check(black.widgetDeadline(for: today, blackCatDailyEnabled: false) == black.validUntil,
              "Black-cat daily deadline escaped the internal gate")
        check(black.widgetPhotos(at: cutover, blackCatDailyEnabled: true).map(\.id) == ["today"], "Black-cat Widget rotated through history")
        check(black.widgetPhotos(at: cutover.addingTimeInterval(86400), blackCatDailyEnabled: true).isEmpty, "Black-cat Widget retained yesterday")
        check(black.widgetDeadline(for: today, blackCatDailyEnabled: true) == iso.date(from: "2026-10-22T15:00:00Z")!, "Black-cat Widget missed JST midnight")
        let midnight = iso.date(from: "2026-10-22T15:00:00Z")!
        let midnightPhoto = posted(midnight, "midnight")
        let midnightCatalog = OfficialWindowCatalog(schemaVersion: 1, channelID: "black-cats", enabled: true,
            generatedAt: midnight, validUntil: midnight.addingTimeInterval(86400), photos: [today, midnightPhoto])
        check(midnightCatalog.widgetPhotos(at: midnight, blackCatDailyEnabled: true).map(\.id) == ["midnight"], "Black-cat midnight edition ignored")
        check(midnightCatalog.widgetPhotos(at: midnight.addingTimeInterval(86400), blackCatDailyEnabled: true).isEmpty, "Black-cat midnight edition outlived its day")
        check(midnightCatalog.widgetDeadline(for: midnightPhoto, blackCatDailyEnabled: true) == midnight.addingTimeInterval(86400), "Black-cat deadline assumes 18:00")
        check(OfficialWindowCatalog.nextBlackCatCutover(after: midnight.addingTimeInterval(-1)) == midnight,
              "Black-cat refresh missed JST midnight")
        check(black.widgetPhotos(at: iso.date(from: "2026-10-22T15:00:00Z")!, blackCatDailyEnabled: true).isEmpty,
              "Black-cat Widget kept a previous-day image across JST midnight")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        let now = Date(), day = calendar.startOfDay(for: now)
        // Repeating JPEG bytes must arrive as a NEW daily publication. A cached
        // catalog from the previous cycle remains expired and cannot roll back
        // the current day, even though both photos have the same content hash.
        func loopCatalog(_ start: Date, _ id: String) -> OfficialWindowCatalog {
            let end = start.addingTimeInterval(86400)
            let item = OfficialCatPhoto(id: id, catID: photo.catID, catName: "黒猫",
                credit: "ねこのまど（AI で作った画像）", caption: nil, photographedOn: nil,
                publishedAt: start, expiresAt: end, imageFilename: photo.imageFilename,
                sha256: photo.sha256, width: photo.width, height: photo.height)
            return .init(schemaVersion: 1, channelID: "black-cats", enabled: true,
                         generatedAt: start, validUntil: end, photos: [item])
        }
        let firstCycle = loopCatalog(day.addingTimeInterval(-10 * 86400), "black-first-cycle")
        let nextCycle = loopCatalog(day, "black-next-cycle")
        try firstCycle.validate(at: firstCycle.generatedAt, expectedChannelID: "black-cats")
        try nextCycle.validate(at: now, expectedChannelID: "black-cats")
        let loopStore = OfficialWindowStore(directory: root.appendingPathComponent("black-cat-loop"),
            definition: .init(id: "black-cats", displayName: "黒猫のまど", subtitle: "今日の1枚",
                endpoint: endpoint.deletingLastPathComponent().appendingPathComponent("windows/black-cats/catalog.json")))
        try loopStore.setSubscribed(true)
        let request = loopStore.snapshot()
        var oldState = request; oldState.catalog = firstCycle
        try AtomicJSON.write(oldState, to: loopStore.directory!.appendingPathComponent("state.json"))
        check(loopStore.snapshot().photos.isEmpty, "Expired previous cycle was shown before refreshing")
        try loopStore.accept(nextCycle, for: request)
        check(loopStore.snapshot().photos == nextCycle.photos, "New daily publication with a repeated hash was rejected")
        try loopStore.accept(nextCycle, for: request)
        rejects("old cycle cannot replace the current daily edition") { try loopStore.accept(firstCycle, for: request) }
        check(nextCycle.widgetPhotos(at: nextCycle.validUntil, blackCatDailyEnabled: true).isEmpty,
              "Repeating delivery weakened the midnight Widget deadline")
        let monday = calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: day) + 5) % 7), to: day)!
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        let themes = (0..<3).map { i -> OfficialWeeklyThemeIndex.Theme in
            let date = formatter.string(from: calendar.date(byAdding: .day, value: -7 * i, to: monday)!)
            return .init(name: ["あくび", "おなか", "箱"][i], weekStart: date,
                channelID: i == 0 ? "weekly-theme" : "weekly-theme-" + date.replacingOccurrences(of: "-", with: ""))
        }
        let index = OfficialWeeklyThemeIndex(schemaVersion: 1, generatedAt: now, validUntil: now.addingTimeInterval(3600), themes: themes)
        try index.validate(at: now)
        rejects("weekly metadata lease expired") { try index.validate(at: index.validUntil) }
        let wrong = OfficialWeeklyThemeIndex(schemaVersion: 1, generatedAt: now, validUntil: index.validUntil,
            themes: [.init(name: "猫", weekStart: themes[0].weekStart, channelID: "private-window")])
        rejects("metadata selected a private window") { try wrong.validate(at: now) }
        let weekly = PublicWindowDefinition(id: "weekly-theme", displayName: "今週のテーマ", subtitle: "以前のまど",
            endpoint: endpoint.deletingLastPathComponent().appendingPathComponent("windows/weekly-theme/catalog.json"))
        check(themes[1].definition(relativeTo: weekly)?.endpoint?.host == endpoint.host, "Theme archive escaped the configured origin")
        check(themes[1].definition(relativeTo: weekly)?.endpoint?.lastPathComponent == "catalog.json", "Theme archive lost catalog path")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        PreviewURLProtocol.configure(["themes.json": .init(data: try encoder.encode(index))])
        let store = OfficialWindowStore.forWindow(weekly, containerURL: root)
        let client = OfficialWindowClient(previewEndpoint: endpoint, protocolClasses: [PreviewURLProtocol.self])
        let fetched = try await client.weeklyThemes(store: store)
        check(fetched.themes == themes, "Weekly names/history did not reach the adapter")
        check(PreviewURLProtocol.requests() == ["themes.json"], "Metadata fetched a photo or credential")
        check(!store.snapshot().isSubscribed, "Metadata browsing created a subscription")
        PreviewURLProtocol.configure(["themes.json": .init(data: try encoder.encode(wrong))])
        do { _ = try await client.weeklyThemes(store: store); fatalError("Unsafe weekly metadata accepted") }
        catch { assertions += 1 }
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
