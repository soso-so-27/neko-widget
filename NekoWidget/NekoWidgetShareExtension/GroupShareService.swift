import Foundation

/// Photo-only configuration. Reporting recipients and the host's report
/// availability predicate are intentionally not part of the extension.
struct GroupShareConfiguration {
    let endpoint: URL
    let releaseMode: String
    static var current: Self? { Self(info: Bundle.main.infoDictionary ?? [:]) }

    init?(info: [String: Any]) {
        guard ["GroupShareExtensionEnabled", "GroupWindowsEnabled", "SharingFeatureEnabled", "SharingMediaEnabled"]
                .allSatisfy({ info[$0] as? String == "YES" }),
              info["SharingShareExtensionSendEnabled"] as? String == "NO",
              (info["SharingReviewPreviewEnabled"] as? String == "NO" || info["SharingReviewPreviewEnabled"] as? Bool == false),
              info["SharingInternalEncryptedReportEnabled"] as? Bool == false,
              info["SharingInternalEncryptedReportScope"] as? String == "",
              (info["GroupReportingProductionEnabled"] as? String ?? "NO") == "NO",
              ["SharingAPIBaseURL", "SharingModerationKeyID", "SharingModerationPublicKey"]
                .allSatisfy({ (info[$0] as? String ?? "").isEmpty }),
              let mode = info["SharingReleaseMode"] as? String,
              ["production", "media-staging"].contains(mode),
              let raw = info["GroupShareAPIBaseURL"] as? String,
              raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", let host = parts.host, host.contains("."),
              !host.contains("$"), parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil, ["", "/"].contains(parts.path)
        else { return nil }
        if mode == "media-staging" {
            guard raw == "https://neko-window-sharing-staging.nakanishisoya.workers.dev" else { return nil }
        } else {
            guard !host.lowercased().contains("staging") else { return nil }
        }
        endpoint = url
        releaseMode = mode
    }
}

/// No billing/bootstrap/invitation/member-management/report endpoint is
/// reachable through the Share Extension's transport.
struct GroupShareTransport: GroupHTTPTransport {
    let transport: any GroupHTTPTransport
    static func allows(method: String, path: String) -> Bool {
        if method == "POST", path == "/v3/group-windows/list" { return true }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "v3", parts[1] == "group-windows",
              GroupCanonical.validID(parts[2]) else { return false }
        let suffix = Array(parts.dropFirst(3))
        if method == "GET" {
            if suffix.isEmpty { return true }
            if suffix.count == 2, suffix[0] == "keys", Int(suffix[1]).map({ $0 > 0 }) == true { return true }
            if suffix.count == 2, suffix[0] == "moments", GroupCanonical.validID(suffix[1]) { return true }
            if suffix.count == 3, suffix[0] == "moments", GroupCanonical.validID(suffix[1]), suffix[2] == "hearts" { return true }
        }
        if method == "POST" {
            if suffix == ["rosters", "list"] || suffix == ["members", "list"] || suffix == ["moments", "reserve"] { return true }
            if suffix.count == 3, suffix[0] == "moments", GroupCanonical.validID(suffix[1]), suffix[2] == "commit" { return true }
        }
        if method == "PUT", suffix.count == 3, suffix[0] == "moments", GroupCanonical.validID(suffix[1]),
           ["ciphertext", "caption-ciphertext"].contains(suffix[2]) { return true }
        return false
    }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        guard let url = request.url, Self.allows(method: request.httpMethod ?? "", path: url.path) else {
            throw GroupClientError.authenticationRequired
        }
        return try await transport.send(request, maximumBytes: maximumBytes)
    }
}

#if os(iOS)
actor GroupShareService: GroupShareServing {
    private let client: ProductionGroupWindowClient
    private let snapshot: any GroupSecretStore
    private let moderation: any MomentModerating

    init(client: ProductionGroupWindowClient, snapshot: any GroupSecretStore,
         moderation: any MomentModerating) {
        self.client = client
        self.snapshot = snapshot
        self.moderation = moderation
    }

    static func live() throws -> GroupShareService {
        guard let configuration = GroupShareConfiguration.current,
              let accessGroup = GroupShareAccess.accessGroup else {
            throw GroupClientError.unavailable
        }
        let endpoint = configuration.endpoint
        let namespace = configuration.releaseMode == "production"
            ? "jp.nekowidget.app.group-v3.production" : "jp.nekowidget.app.group-v3.staging"
        guard let installation = try GroupShareInstallation.existingForShare() else {
            throw GroupClientError.authenticationRequired
        }
        let snapshot = GroupShareKeychain(namespace: namespace + "." + installation, accessGroup: accessGroup)
        let checkpoints = try GroupKeychainStore(namespace: namespace + "." + installation + ".share-checkpoints")
        let secrets = GroupShareReadingStore(snapshot: snapshot, checkpoints: checkpoints)
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw GroupClientError.unavailable
        }
        let client = try ProductionGroupWindowClient(endpoint: endpoint, secrets: secrets,
            transport: GroupShareTransport(transport: GroupURLSessionTransport()),
            outboxDirectory: root.appendingPathComponent(namespace + ".share-outbox", isDirectory: true))
        return GroupShareService(client: client, snapshot: snapshot, moderation: MomentModerationService())
    }

    func destinations() async throws -> [GroupWindow] {
        // A fresh app has not created any group identity yet. Never register an
        // identity or turn a leftover legacy pairing credential into authority.
        guard try snapshot.read("identity") != nil else {
            guard try snapshot.read("host-confirmed-empty") == Data([1]) else { throw GroupClientError.authenticationRequired }
            return []
        }
        return try await client.windows()
    }

    func send(jpeg: Data, caption: String?, windowID: String, operationID: UUID) async throws {
        _ = try GroupPhotoCaption.normalized(caption)
        try GroupJPEG.validate(jpeg)
        let current = try await client.window(id: windowID)
        guard current.state == .active, current.deliveryStatus == .active else {
            throw GroupSubscriptionError.windowPaused
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        try jpeg.write(to: file, options: [.atomic, .completeFileProtection])
        try await moderation.requireSafeImage(at: file)
        // This is exactly the host's roster/epoch/AEAD/signature/reserve/commit
        // path. No success state is emitted until the committed photo is read.
        let retainedOperation = try await client.sharePhotoOperation(jpeg: jpeg, caption: caption,
            windowID: windowID, proposed: operationID)
        let delivered = try await client.sendPhoto(normalizedJPEG: jpeg, caption: caption,
            windowID: windowID, operationID: retainedOperation)
        try await client.finishSharePhoto(operationID: retainedOperation, photoID: delivered.id)
    }
}
#endif
