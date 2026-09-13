import CryptoKit
import Darwin
import Foundation
import Combine
import ImageIO

enum OfficialWindowConfiguration {
    static var feedURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "OfficialWindowFeedURL") as? String,
              let url = URL(string: raw) else { return nil }
        return validatedEndpoint(url)
    }

    static var definitions: [PublicWindowDefinition] {
        [PublicWindowDefinition(id: OfficialWindowCatalog.sourceID,
                                displayName: OfficialWindowCatalog.displayName,
                                subtitle: "運営から届く猫の写真", endpoint: feedURL)]
    }

    static func definition(for windowID: String) -> PublicWindowDefinition? {
        definitions.first { $0.id == windowID }
    }

    static func validatedEndpoint(_ url: URL?) -> URL? {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.hasSuffix("/catalog.json") else { return nil }
        return parts.url
    }
}

struct OfficialWindowState: Codable, Sendable {
    var windowID: String = OfficialWindowCatalog.sourceID
    var subscriptionID: UUID?
    var endpoint: URL?
    var catalog: OfficialWindowCatalog?
    var checkedAt: Date?
    var imageRevision: UUID?

    static let empty = Self()
    var isSubscribed: Bool {
        subscriptionID != nil && endpoint != nil
    }
    var photos: [OfficialCatPhoto] {
        guard isSubscribed, let catalog,
              (try? catalog.validate(at: Date(), expectedChannelID: windowID)) != nil else { return [] }
        return catalog.availablePhotos(at: Date())
    }

    private enum CodingKeys: String, CodingKey {
        case windowID, subscriptionID, endpoint, catalog, checkedAt, imageRevision
    }
}

extension OfficialWindowState {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Only records written before public-window scoping omit this field.
        windowID = try values.decodeIfPresent(String.self, forKey: .windowID) ?? OfficialWindowCatalog.sourceID
        subscriptionID = try values.decodeIfPresent(UUID.self, forKey: .subscriptionID)
        endpoint = try values.decodeIfPresent(URL.self, forKey: .endpoint)
        catalog = try values.decodeIfPresent(OfficialWindowCatalog.self, forKey: .catalog)
        checkedAt = try values.decodeIfPresent(Date.self, forKey: .checkedAt)
        imageRevision = try values.decodeIfPresent(UUID.self, forKey: .imageRevision)
    }
}

/// One atomic state file and a cross-process lock isolate this opt-in feed from
/// private sharing. A subscription generation prevents an in-flight refresh
/// from restoring content after the person stops receiving it.
struct OfficialWindowStore: Sendable {
    static var shared: Self {
        Self(directory: SharedContainer.containerURL?.appendingPathComponent("official-window.v1", isDirectory: true),
             endpoint: OfficialWindowConfiguration.feedURL)
    }
    private static let processLock = NSLock()
    let directory: URL?
    let definition: PublicWindowDefinition
    var windowID: String { definition.id }
    var displayName: String { definition.displayName }
    var endpoint: URL? { OfficialWindowConfiguration.validatedEndpoint(definition.endpoint) }

    init(directory: URL?, endpoint: URL?) {
        self.init(directory: directory, definition: PublicWindowDefinition(
            id: OfficialWindowCatalog.sourceID, displayName: OfficialWindowCatalog.displayName,
            subtitle: "運営から届く猫の写真", endpoint: endpoint
        ))
    }

    init(directory: URL?, definition: PublicWindowDefinition) {
        self.directory = OfficialWindowCatalog.isIdentifier(definition.id) ? directory : nil
        self.definition = definition
    }

    static func forWindow(_ definition: PublicWindowDefinition,
                          containerURL: URL? = SharedContainer.containerURL) -> Self {
        let directory: URL?
        if !OfficialWindowCatalog.isIdentifier(definition.id) {
            directory = nil
        } else if definition.id == OfficialWindowCatalog.sourceID {
            directory = containerURL?.appendingPathComponent("official-window.v1", isDirectory: true)
        } else {
            directory = containerURL?.appendingPathComponent("public-windows.v1", isDirectory: true)
                .appendingPathComponent(definition.id, isDirectory: true)
        }
        return Self(directory: directory, definition: definition)
    }

    func snapshot() -> OfficialWindowState {
        (try? locked { root in
            var state = try read(root)
            if let catalog = state.catalog,
               (try? catalog.validate(at: Date(), expectedChannelID: windowID)) == nil {
                state.catalog = nil
            }
            return state
        }) ?? OfficialWindowState(windowID: windowID)
    }

    func setSubscribed(_ subscribed: Bool) throws {
        guard !subscribed || endpoint != nil else { throw OfficialWindowError.notConfigured }
        try locked { root in
            let state = OfficialWindowState(windowID: windowID, subscriptionID: subscribed ? UUID() : nil, endpoint: endpoint)
            try AtomicJSON.write(state, to: root.appendingPathComponent("state.json"))
            try purgeImages(in: root, keeping: [])
        }
    }

    func imageURL(for photo: OfficialCatPhoto) -> URL? {
        try? locked { root -> URL? in
            let state = try read(root)
            guard state.photos.contains(photo) else { return nil }
            let url = root.appendingPathComponent(photo.imageFilename)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    func imageURL(filename: String) -> URL? {
        try? locked { root -> URL? in
            let state = try read(root)
            guard state.photos.contains(where: { $0.imageFilename == filename }) else { return nil }
            let url = root.appendingPathComponent(filename)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    func accept(_ catalog: OfficialWindowCatalog, for request: OfficialWindowState) throws {
        try catalog.validate(at: Date(), expectedChannelID: windowID)
        try locked { root in
            var state = try read(root)
            guard state.isSubscribed, state.subscriptionID == request.subscriptionID,
                  state.windowID == windowID, request.windowID == windowID,
                  state.endpoint == endpoint, request.endpoint == endpoint else { throw OfficialWindowError.subscriptionChanged }
            // A slow, older request must not undo a withdrawal or a newer edition.
            guard state.catalog.map({ $0.generatedAt < catalog.generatedAt || $0 == catalog }) ?? true
            else { throw OfficialWindowError.invalidCatalog }
            state.catalog = catalog
            state.checkedAt = Date()
            try AtomicJSON.write(state, to: root.appendingPathComponent("state.json"))
            try purgeImages(in: root, keeping: Set(state.photos.map(\.imageFilename)))
        }
    }

    func saveImage(_ data: Data, photo: OfficialCatPhoto, for request: OfficialWindowState) throws {
        try OfficialWindowImageValidator.validate(data, photo: photo)
        try locked { root in
            var state = try read(root)
            guard state.isSubscribed, state.subscriptionID == request.subscriptionID,
                  state.windowID == windowID, request.windowID == windowID,
                  state.endpoint == endpoint, request.endpoint == endpoint,
                  state.photos.contains(photo) else { throw OfficialWindowError.subscriptionChanged }
            let url = root.appendingPathComponent(photo.imageFilename)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path
            )
            state.imageRevision = UUID()
            try AtomicJSON.write(state, to: root.appendingPathComponent("state.json"))
        }
    }

    private func read(_ root: URL) throws -> OfficialWindowState {
        let url = root.appendingPathComponent("state.json")
        do {
            let state = try AtomicJSON.read(OfficialWindowState.self, from: url)
            guard state.windowID == windowID, state.endpoint == endpoint else {
                return OfficialWindowState(windowID: windowID)
            }
            guard state.catalog.map({ $0.channelID == windowID }) ?? true else { throw OfficialWindowError.invalidCatalog }
            return state
        }
        catch {
            if SharingFileReadFailureClassifier.disposition(error) == .missing { return OfficialWindowState(windowID: windowID) }
            throw error
        }
    }

    private func purgeImages(in root: URL, keeping names: Set<String>) throws {
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            guard name.hasSuffix(".jpg"), OfficialWindowCatalog.isSHA256(String(name.dropLast(4))),
                  !names.contains(name), url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL
            else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func locked<T>(_ operation: (URL) throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard let root = directory else { throw OfficialWindowError.unavailableStorage }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let descriptor = Darwin.open(root.appendingPathComponent("store.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw OfficialWindowError.unavailableStorage }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw OfficialWindowError.unavailableStorage }
        defer { flock(descriptor, LOCK_UN) }
        return try operation(root)
    }
}

enum OfficialWindowImageValidator {
    static func validate(_ data: Data, photo: OfficialCatPhoto) throws {
        guard data.count <= 4 * 1024 * 1024,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == photo.sha256,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == photo.width,
              properties[kCGImagePropertyPixelHeight] as? Int == photo.height
        else { throw OfficialWindowError.invalidImage }
    }
}

/// A single public preview lives only in the browsing screen's memory. It is
/// never accepted by the subscription store or exposed to a Widget timeline.
struct OfficialWindowPreview: Sendable {
    let catalog: OfficialWindowCatalog
    let photo: OfficialCatPhoto?
    let imageData: Data?

    func availablePhoto(at date: Date = Date()) -> OfficialCatPhoto? {
        guard let photo, imageData != nil,
              catalog.availablePhotos(at: date).contains(photo) else { return nil }
        return photo
    }
}

@MainActor
final class OfficialWindowPreviewModel: ObservableObject {
    let windowID: String
    @Published private(set) var content: OfficialWindowPreview?
    @Published private(set) var isLoading = false
    @Published private(set) var hasChecked = false
    @Published private(set) var failed = false
    private var generation = UUID()
    private var loadingTask: Task<Void, Never>?

    init(windowID: String = OfficialWindowCatalog.sourceID) { self.windowID = windowID }

    func load(force: Bool = false, using fetch: @escaping () async throws -> OfficialWindowPreview) async {
        if let loadingTask { await loadingTask.value; return }
        guard force || !hasChecked else { return }
        let request = generation
        isLoading = true
        // Moving from discovery into the photo must not cancel its preview or
        // start a second download. Both screens await this one memory-only task.
        let task = Task { await self.performLoad(request: request, using: fetch) }
        loadingTask = task
        await task.value
    }

    private func performLoad(request: UUID, using fetch: () async throws -> OfficialWindowPreview) async {
        defer {
            if request == generation {
                isLoading = false
                hasChecked = true
                loadingTask = nil
            }
        }
        do {
            let next = try await fetch()
            try Task.checkCancellation()
            guard request == generation else { return }
            try next.catalog.validate(at: Date(), expectedChannelID: windowID)
            guard content.map({ $0.catalog.generatedAt < next.catalog.generatedAt || $0.catalog == next.catalog }) ?? true else {
                throw OfficialWindowError.invalidCatalog
            }
            content = next
            failed = next.availablePhoto() == nil && !next.catalog.availablePhotos(at: Date()).isEmpty
        } catch is CancellationError {
            return
        } catch {
            if request == generation { failed = true }
        }
    }

    func clear() {
        generation = UUID()
        loadingTask?.cancel()
        loadingTask = nil
        content = nil
        isLoading = false
        hasChecked = false
        failed = false
    }
}

private final class OfficialWindowRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Public feed URLs are pinned by the build. Do not follow third-party,
        // authentication, or downgraded redirects, even for image requests.
        completionHandler(nil)
    }
}

actor OfficialWindowClient {
    static let shared = OfficialWindowClient()
    private struct StoreKey: Hashable {
        let windowID: String
        let endpoint: URL?
        let directory: URL?

        init(_ store: OfficialWindowStore) {
            windowID = store.windowID
            endpoint = store.endpoint
            directory = store.directory?.standardizedFileURL
        }
    }
    private struct Pending {
        let id: UUID
        let subscription: UUID
        let imageCount: Int
        let task: Task<Void, Error>
    }
    private var pending: [StoreKey: Pending] = [:]
    private let previewEndpoint: URL?
    #if OFFICIAL_WINDOW_CHECKS
    private var previewProtocolClasses: [AnyClass]? = nil
    #endif

    init() { previewEndpoint = nil }

    #if OFFICIAL_WINDOW_CHECKS
    // The standalone boundary runner supplies only an in-process URLProtocol.
    // Release builds cannot override the configured endpoint or transport.
    init(previewEndpoint: URL, protocolClasses: [AnyClass]) {
        self.previewEndpoint = previewEndpoint
        self.previewProtocolClasses = protocolClasses
    }
    #endif

    func refresh(store: OfficialWindowStore = .shared, maximumImages: Int = 1) async throws {
        let request = store.snapshot()
        guard request.isSubscribed, let subscription = request.subscriptionID else { return }
        let key = StoreKey(store)
        let imageCount = max(1, min(6, maximumImages))
        if let existing = pending[key] {
            let result = await existing.task.result
            if pending[key]?.id == existing.id { pending[key] = nil }
            if existing.subscription != subscription || existing.imageCount < imageCount {
                try await refresh(store: store, maximumImages: imageCount)
            } else {
                try result.get()
            }
            return
        }
        let id = UUID()
        let task = Task { try await self.performRefresh(store: store, request: request, maximumImages: imageCount) }
        pending[key] = Pending(id: id, subscription: subscription, imageCount: imageCount, task: task)
        defer { if pending[key]?.id == id { pending[key] = nil } }
        try await task.value
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        #if OFFICIAL_WINDOW_CHECKS
        if let previewProtocolClasses { configuration.protocolClasses = previewProtocolClasses }
        #endif
        return URLSession(configuration: configuration, delegate: OfficialWindowRedirectPolicy(), delegateQueue: nil)
    }

    /// Read only the build-configured public endpoint. Browsing does not create
    /// a subscription, write a cache, or change any existing received content.
    func preview(store: OfficialWindowStore = .shared) async throws -> OfficialWindowPreview {
        var configuredEndpoint = store.endpoint
        #if OFFICIAL_WINDOW_CHECKS
        // Preserve the old standalone preview test initializer. Explicit
        // scoped stores always use their own endpoint, including window B.
        if configuredEndpoint == nil, store.windowID == OfficialWindowCatalog.sourceID {
            configuredEndpoint = OfficialWindowConfiguration.validatedEndpoint(previewEndpoint)
        }
        #endif
        guard OfficialWindowCatalog.isIdentifier(store.windowID), let endpoint = configuredEndpoint else {
            throw OfficialWindowError.notConfigured
        }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let catalog = try await fetchCatalog(endpoint, expectedChannelID: store.windowID, session: session)
        guard let photo = catalog.availablePhotos(at: Date()).first else {
            return OfficialWindowPreview(catalog: catalog, photo: nil, imageData: nil)
        }
        let url = endpoint.deletingLastPathComponent().appendingPathComponent(photo.imageFilename)
        do {
            let data = try await fetch(url, session: session, limit: 4 * 1024 * 1024, contentType: "image/jpeg")
            try OfficialWindowImageValidator.validate(data, photo: photo)
            try catalog.validate(at: Date(), expectedChannelID: store.windowID)
            return OfficialWindowPreview(catalog: catalog, photo: photo, imageData: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A known new allowlist must replace the preview even if its image
            // fails. Never keep showing a photo removed by this catalog.
            try catalog.validate(at: Date(), expectedChannelID: store.windowID)
            return OfficialWindowPreview(catalog: catalog, photo: nil, imageData: nil)
        }
    }

    private func fetchCatalog(_ endpoint: URL, expectedChannelID: String, session: URLSession) async throws -> OfficialWindowCatalog {
        let data = try await fetch(endpoint, session: session, limit: 256 * 1024, contentType: "application/json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalog = try decoder.decode(OfficialWindowCatalog.self, from: data)
        try catalog.validate(at: Date(), expectedChannelID: expectedChannelID)
        return catalog
    }

    private func performRefresh(store: OfficialWindowStore, request: OfficialWindowState, maximumImages: Int) async throws {
        guard request.windowID == store.windowID, let endpoint = request.endpoint,
              endpoint == store.endpoint else { throw OfficialWindowError.subscriptionChanged }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let catalog = try await fetchCatalog(endpoint, expectedChannelID: store.windowID, session: session)
        // Persist the new allowlist before media downloads: removal/pause works
        // even when a new photo subsequently fails to download.
        try store.accept(catalog, for: request)
        for photo in catalog.availablePhotos(at: Date()).prefix(max(1, min(6, maximumImages))) {
            try Task.checkCancellation()
            if store.imageURL(for: photo) != nil { continue }
            let url = endpoint.deletingLastPathComponent().appendingPathComponent(photo.imageFilename)
            let image = try await fetch(url, session: session, limit: 4 * 1024 * 1024, contentType: "image/jpeg")
            try store.saveImage(image, photo: photo, for: request)
        }
    }

    private func fetch(_ url: URL, session: URLSession, limit: Int, contentType: String) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(contentType, forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url == url, http.mimeType == contentType,
              http.expectedContentLength <= Int64(limit) else { throw OfficialWindowError.invalidResponse }
        var result = Data()
        for try await byte in bytes {
            guard result.count < limit else { throw OfficialWindowError.invalidResponse }
            result.append(byte)
        }
        return result
    }
}
