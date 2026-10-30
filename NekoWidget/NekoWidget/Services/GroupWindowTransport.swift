import CryptoKit
import Foundation

struct GroupHTTPReply: Sendable { let status: Int; let data: Data }
protocol GroupHTTPTransport: Sendable {
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply
}

// Existing host billing identity only. Never bootstrap, buy, recover or copy a
// billing key into group storage. Each request rechecks the current credential.
protocol GroupBillingSigner: Sendable {
    func accountID(endpoint: URL) throws -> String
    func headers(endpoint: URL, accountID: String, body: Data) throws -> [String: String]
}

struct GroupHostBillingSigner: GroupBillingSigner {
    static let path = "/v3/group-windows/billing-connection"
#if os(iOS)
    private func credential(endpoint: URL) throws -> BillingCredential {
        let config = BillingClientConfiguration.current
        let sharing = SharingAPIConfiguration.current
        guard sharing.isGroupRuntimeAvailable, config.isConfigured,
              endpoint == sharing.baseURL,
              config.baseURL?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ==
                endpoint.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              let saved = try BillingKeychainStore.load() else { throw GroupClientError.authenticationRequired }
        let value = try saved.validated()
        guard value.phase == .registered,
              let marker = try BillingInstallationMarkerStore.loadExisting(),
              value.installationMarker == marker.uuidString.lowercased()
        else { throw GroupClientError.authenticationRequired }
        return value
    }
#endif
    func accountID(endpoint: URL) throws -> String {
#if os(iOS)
        guard let account = try credential(endpoint: endpoint).billingAccountID else { throw GroupClientError.authenticationRequired }
        return account
#else
        throw GroupClientError.authenticationRequired
#endif
    }
    func headers(endpoint: URL, accountID: String, body: Data) throws -> [String: String] {
#if os(iOS)
        let value = try credential(endpoint: endpoint)
        guard value.billingAccountID == accountID, let key = value.billingKeyID else { throw GroupClientError.authenticationRequired }
        let timestamp = Int(Date().timeIntervalSince1970), nonce = BillingProtocolCodec.randomNonce()
        let transcript = try BillingProtocolCodec.signedRequestTranscript(billingAccountID: accountID, billingKeyID: key,
            timestamp: timestamp, nonce: nonce, method: "POST", pathname: Self.path, bodySHA256: BillingProtocolCodec.sha256(body))
        return ["Neko-Billing-Protocol-Version": "1", "Neko-Billing-Account-ID": accountID, "Neko-Billing-Key-ID": key,
                "Neko-Billing-Timestamp": String(timestamp), "Neko-Billing-Nonce": nonce,
                "Neko-Billing-Signature": try BillingProtocolCodec.sign(transcript, credential: value)]
#else
        throw GroupClientError.authenticationRequired
#endif
    }
}

private final class GroupNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
final class GroupURLSessionTransport: GroupHTTPTransport, Sendable {
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 90
        session = URLSession(configuration: config, delegate: GroupNoRedirect(), delegateQueue: nil)
    }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, response.url == request.url,
                  response.expectedContentLength <= Int64(maximumBytes) else { throw GroupClientError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw GroupClientError.invalidResponse }
                data.append(byte)
            }
            return .init(status: http.statusCode, data: data)
        } catch let error as URLError {
            // A request the app itself cancelled (a screen closed) is not an outage.
            if error.code == .cancelled { throw CancellationError() }
            if [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost].contains(error.code) {
                throw GroupClientError.offline
            }
            throw GroupClientError.unavailable
        }
    }
}

enum GroupHTTPRequest {
    static func make(endpoint: URL, path: String, body: Data?, identity: GroupDeviceIdentity?, now: Date = Date(), nonce: Data? = nil, method: String? = nil) throws -> URLRequest {
        guard let base = URLComponents(url: endpoint, resolvingAgainstBaseURL: false), base.scheme == "https", base.host != nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              ["", "/"].contains(base.path),
              (path.hasPrefix("/v3/group-") || path == "/v3/family-notebooks" || path.hasPrefix("/v3/family-notebooks/")),
              path.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 47, 95].contains($0) }),
              let url = URL(string: path, relativeTo: endpoint)?.absoluteURL, url.host == base.host
        else { throw GroupClientError.invalidResponse }
        var request = URLRequest(url: url)
        let verb = method ?? (body == nil ? "GET" : "POST")
        guard ["GET", "POST", "PUT"].contains(verb), verb != "GET" || body == nil else { throw GroupClientError.invalidResponse }
        request.httpMethod = verb
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let identity {
            let nonceBytes = nonce ?? SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
            guard nonceBytes.count == 16 else { throw GroupClientError.invalidResponse }
            let deviceID = try identity.deviceID, timestamp = String(Int(now.timeIntervalSince1970)), encodedNonce = GroupWire.base64(nonceBytes)
            let message = try GroupCanonical.fields(["NW3.REQUEST", "3", deviceID, timestamp, encodedNonce, request.httpMethod!, path].map(GroupCanonical.text)
                + [GroupCanonical.hash(body ?? Data())])
            let signature = try identity.signingKey.signature(for: message)
            for (key, value) in ["Neko-Protocol-Version": "3", "Neko-Device-Id": deviceID, "Neko-Timestamp": timestamp,
                                 "Neko-Nonce": encodedNonce, "Neko-Signature": GroupWire.base64(signature)] {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        return request
    }
    private struct ErrorBody: Decodable {
        struct Detail: Decodable { let code: String; let currentRevision: Int? }
        let error: Detail
    }
    static func check(_ reply: GroupHTTPReply) throws -> Data {
        guard (200...299).contains(reply.status) else {
            guard let error = try? GroupWire.decode(ErrorBody.self, reply.data).error else { throw GroupClientError.unavailable }
            switch error.code {
            case "invalid_authentication", "invalid_proof", "replay", "stale_request", "invalid_billing_authentication", "stale_billing_request", "replayed_billing_request": throw GroupClientError.authenticationRequired
            case "not_found", "not_member", "epoch_not_authorized": throw GroupClientError.notMember
            case "owner_required": throw GroupClientError.ownerRequired
            case "owner_plus_required": throw GroupSubscriptionError.ownerPlusRequired
            case "window_paused": throw GroupSubscriptionError.windowPaused
            case "stale_revision": throw GroupClientError.staleRevision(current: error.currentRevision ?? 0)
            case "stale_epoch": throw GroupClientError.staleEpoch
            case "stale_name_revision": throw GroupWindowManagementError.staleNameRevision
            case "group_management_disabled": throw GroupWindowManagementError.unavailable
            case "rotation_pending": throw GroupClientError.rotationPending
            case "member_limit": throw GroupClientError.memberLimit
            case "device_limit": throw GroupClientError.deviceLimit
            case "total_window_limit": throw GroupClientError.totalWindowLimit
            case "owned_window_limit": throw GroupClientError.ownedWindowLimit
            case "invitation_expired", "challenge_expired": throw GroupClientError.invitationExpired
            case "invitation_revoked": throw GroupClientError.invitationRevoked
            case "invitation_paused": throw GroupClientError.invitationPaused
            case "request_not_pending": throw GroupClientError.requestNotPending
            case "cannot_remove_owner", "cannot_remove_last_owner_device": throw GroupClientError.cannotRemoveOwner
            case "owner_cannot_leave": throw GroupClientError.ownerCannotLeave
            case "idempotency_conflict": throw GroupClientError.idempotencyConflict
            default: throw GroupClientError.unavailable
            }
        }
        return reply.data
    }
}
