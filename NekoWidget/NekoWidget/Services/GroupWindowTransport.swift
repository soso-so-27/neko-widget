import CryptoKit
import Foundation

struct GroupHTTPReply: Sendable {
    let status: Int; let data: Data
    /// 11/20: the reply's HTTP `Date`, only to notice a wrong iPhone clock.
    var serverDate: Date? = nil
}

/// 11/20: the relay refuses a request whose signed time is more than 300 s
/// from its own (group-auth.ts). It says so (`stale_request`, reason
/// `clock_skew`) for a correctly signed request of an active device; an
/// older relay does not, and then a refused reply's HTTP `Date` that far off
/// is the sign. Either way the person is told to fix the iPhone's clock
/// rather than to reopen the window. The signing time is NEVER moved to the
/// relay's clock: neither the reply's `Date` nor its `serverNow` is signed.
enum GroupClockSkew {
    static let limit: TimeInterval = 300
    static let message = "iPhoneの「日付と時刻」を自動設定にしてから、もう一度お試しください。"
    private final class Noticed: @unchecked Sendable {
        let lock = NSLock()
        var at: Date?
    }
    private static let noticed = Noticed()

    /// Within the last 10 minutes, a refusal came with a clock this far off.
    static var isLikely: Bool {
        noticed.lock.lock(); defer { noticed.lock.unlock() }
        return noticed.at.map { Date().timeIntervalSince($0) < 600 } ?? false
    }

    /// The relay's own `clock_skew` answer.
    static func noteRelayReported(now: Date = Date()) {
        noticed.lock.lock(); defer { noticed.lock.unlock() }
        noticed.at = now
    }

    static func note(_ reply: GroupHTTPReply, now: Date = Date()) {
        guard let serverDate = reply.serverDate else { return }
        let skewed = abs(serverDate.timeIntervalSince(now)) > limit
        noticed.lock.lock(); defer { noticed.lock.unlock() }
        if skewed, reply.status == 401 { noticed.at = now }
        else if !skewed { noticed.at = nil }
    }

    /// RFC 9110 IMF-fixdate, as Cloudflare sends it.
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value.trimmingCharacters(in: .whitespaces))
    }
}
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
#if os(iOS) && !NEKO_SHARE_EXTENSION
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
#if os(iOS) && !NEKO_SHARE_EXTENSION
        guard let account = try credential(endpoint: endpoint).billingAccountID else { throw GroupClientError.authenticationRequired }
        return account
#else
        throw GroupClientError.authenticationRequired
#endif
    }
    func headers(endpoint: URL, accountID: String, body: Data) throws -> [String: String] {
#if os(iOS) && !NEKO_SHARE_EXTENSION
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

/// 11/15 (1115q, 1115s): the relay allows 120 calls a minute per address
/// (two iPhones on one Wi-Fi share it). Every call of the まど and the family
/// notebook goes through here and is automatic unless the person's own tap
/// marks it (`SharingPersonAction.run`): a call added later without a mark is
/// counted and held back, never let through. Automatic calls: 30 in any 60 s,
/// none for at least a minute after a 429. All calls of this iPhone, taps
/// included: 59 in any 60 s, so two iPhones stay under the relay's 120.
struct SharingCallWindow: Sendable {
    let limit: Int
    let seconds: TimeInterval
    private(set) var times: [Date] = []

    init(limit: Int, seconds: TimeInterval = 60) { self.limit = limit; self.seconds = seconds }

    func count(at now: Date) -> Int { times.filter { now.timeIntervalSince($0) < seconds }.count }

    /// Takes one call when the last `seconds` hold fewer than `limit`.
    mutating func admit(at now: Date) -> Bool {
        times.removeAll { now.timeIntervalSince($0) >= seconds }
        guard times.count < limit else { return false }
        times.append(now)
        return true
    }

    /// Counts a call that was made anyway (a tap), so automatic ones wait.
    mutating func record(at now: Date) {
        times.removeAll { now.timeIntervalSince($0) >= seconds }
        times.append(now)
    }
}

final class SharingAutoCallBudget: @unchecked Sendable {
    static let shared = SharingAutoCallBudget()
    /// Automatic calls of one iPhone in any 60 s.
    static let perMinute = 30
    /// All calls of one iPhone in any 60 s, taps included: two iPhones on
    /// one address stay under the relay's 120.
    static let devicePerMinute = 59
    /// No Retry-After: at least this long after a 429.
    static let rateLimitedPause: TimeInterval = 60
    /// Set only by the person's own action (a tap, pull to refresh, opening
    /// a link). Everything else, a call nobody marked included, is automatic.
    @TaskLocal static var isPersonAction = false

    private let lock = NSLock()
    private var automatic: SharingCallWindow
    private var all: SharingCallWindow
    private var pausedUntil: Date?

    init(limit: Int = SharingAutoCallBudget.perMinute, deviceLimit: Int = SharingAutoCallBudget.devicePerMinute) {
        automatic = SharingCallWindow(limit: limit)
        all = SharingCallWindow(limit: deviceLimit)
    }

    /// Takes one call or refuses it. A refused call was never sent: the
    /// caller sees the same error as the relay's own 「少しおいて」 answer.
    func admit(personAction: Bool, at now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        if personAction {
            guard all.admit(at: now) else { throw GroupClientError.unavailable }
            return
        }
        if let pausedUntil, now < pausedUntil { throw GroupClientError.unavailable }
        guard automatic.count(at: now) < automatic.limit, all.count(at: now) < all.limit else {
            throw GroupClientError.unavailable
        }
        _ = automatic.admit(at: now); _ = all.admit(at: now)
    }

    func noteRateLimited(retryAfter: TimeInterval?, at now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let until = now.addingTimeInterval(max(Self.rateLimitedPause, retryAfter ?? 0))
        pausedUntil = max(pausedUntil ?? until, until)
    }

    /// When the automatic passes may call again (nil: now).
    func pausedUntil(at now: Date = Date()) -> Date? {
        lock.lock(); defer { lock.unlock() }
        guard let pausedUntil, now < pausedUntil else { return nil }
        return pausedUntil
    }

    func automaticCalls(at now: Date = Date()) -> Int {
        lock.lock(); defer { lock.unlock() }
        return automatic.count(at: now)
    }

    func allCalls(at now: Date = Date()) -> Int {
        lock.lock(); defer { lock.unlock() }
        return all.count(at: now)
    }

    /// The gate every transport puts in front of a request.
    static func admit(_ budget: SharingAutoCallBudget = .shared, at now: Date = Date()) throws {
        try budget.admit(personAction: isPersonAction, at: now)
    }

    /// The one way a request reaches the network (GroupURLSessionTransport):
    /// admitted or refused before anything is sent, and a 429 noted after.
    static func gated(_ budget: SharingAutoCallBudget = .shared, at now: @escaping () -> Date = { Date() },
                      _ network: (_ replied: (_ status: Int, _ retryAfter: String?) -> Void) async throws -> GroupHTTPReply)
        async throws -> GroupHTTPReply {
        try admit(budget, at: now())
        // 1115v: the pause counts from when the reply came, not from the send.
        return try await network { status, retryAfter in
            noteReply(status: status, retryAfter: retryAfter, budget, at: now())
        }
    }

    /// What a 429 reply sets, whoever made the call.
    static func noteReply(status: Int, retryAfter: String?, _ budget: SharingAutoCallBudget = .shared, at now: Date = Date()) {
        guard status == 429 else { return }
        budget.noteRateLimited(retryAfter: retryAfter.flatMap { retryAfterSeconds($0, now: now) }, at: now)
    }

    /// Retry-After as seconds or as an HTTP date (RFC 9110).
    static func retryAfterSeconds(_ value: String, now: Date = Date()) -> TimeInterval? {
        let text = value.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(text) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text).map { $0.timeIntervalSince(now) }
    }
}

/// 1115s: a check that comes with coming to the front (the まど list, the
/// admission and notification registration, the trust-anchor receipts) does
/// not run again within 20 s of the last one.
enum SharingForegroundGap {
    static let seconds: TimeInterval = 20
    static func allows(since last: Date?, now: Date = Date()) -> Bool {
        last.map { now.timeIntervalSince($0) >= seconds } ?? true
    }
}

/// The person's own action: its calls are not held to the automatic budget
/// (only to the iPhone's 59 a minute). Tasks started inside inherit it; a
/// detached task or a send saved for later does not, and is automatic.
enum SharingPersonAction {
    static func run<T>(_ work: () async throws -> T) async rethrows -> T {
        try await SharingAutoCallBudget.$isPersonAction.withValue(true, operation: work)
    }

    /// 1115v: a long-lived loop or listener started from a tap (a task
    /// inherits the mark) is automatic all the same: its later calls are not
    /// the person's.
    static func automatic<T>(_ work: () async throws -> T) async rethrows -> T {
        try await SharingAutoCallBudget.$isPersonAction.withValue(false, operation: work)
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
        try ClientUpgradeRequirement.shared.checkAllowed()
        // 11/15 (1115q, 1115s): every call passes the gate first; unmarked ones
        // are automatic. The checks drive this same gate with the network replaced.
        return try await SharingAutoCallBudget.gated { replied in
            try await network(request, maximumBytes: maximumBytes, replied: replied)
        }
    }

    private func network(_ request: URLRequest, maximumBytes: Int,
                         replied: (_ status: Int, _ retryAfter: String?) -> Void) async throws -> GroupHTTPReply {
        var request = request
        request.setValue(ClientUpgradeRequirement.buildHeader, forHTTPHeaderField: "X-Neko-App-Build")
#if os(iOS) && INTERNAL_PRESENTATION && !NEKO_SHARE_EXTENSION
        OwnerTwoDeviceTrialConfiguration.current?.authorize(&request)
#endif
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, response.url == request.url,
                  response.expectedContentLength <= Int64(maximumBytes) else { throw GroupClientError.invalidResponse }
            // A captive Wi-Fi portal answers any request with its own HTML
            // page and a success status. That is no connection, not bad data.
            if (200...299).contains(http.statusCode), http.mimeType?.lowercased() == "text/html" { throw GroupClientError.offline }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw GroupClientError.invalidResponse }
                data.append(byte)
            }
            replied(http.statusCode, http.value(forHTTPHeaderField: "Retry-After"))
            try ClientUpgradeRequirement.shared.checkResponse(status: http.statusCode, data: data)
            let reply = GroupHTTPReply(status: http.statusCode, data: data,
                                       serverDate: GroupClockSkew.date(http.value(forHTTPHeaderField: "Date")))
            GroupClockSkew.note(reply)
            return reply
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
        struct Detail: Decodable { let code: String; let currentRevision: Int?; var reason: String? = nil }
        let error: Detail
    }
    static func check(_ reply: GroupHTTPReply) throws -> Data {
        guard (200...299).contains(reply.status) else {
            guard let error = try? GroupWire.decode(ErrorBody.self, reply.data).error else { throw GroupClientError.unavailable }
            // 11/20: the relay names a correctly signed request from this
            // device that arrived outside its 5 minutes (group-auth.ts).
            if error.code == "stale_request", error.reason == "clock_skew" { GroupClockSkew.noteRelayReported() }
            switch error.code {
            case "invalid_authentication", "invalid_proof", "replay", "stale_request", "invalid_billing_authentication", "stale_billing_request", "replayed_billing_request": throw GroupClientError.authenticationRequired
            case "not_found", "not_member", "epoch_not_authorized": throw GroupClientError.notMember
            case "already_member": throw GroupInvitationError.alreadyMember
            case "window_closed": throw GroupInvitationError.windowClosed
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
            // SharingService group-api.ts: group_photo_daily_limit and
            // group_heart_daily_limit both answer 409 daily_limit.
            case "daily_limit": throw GroupClientError.dailyLimit
            // 11/20: a reservation that ran out, and a photo no longer held for this iPhone.
            case "reservation_expired": throw GroupClientError.reservationExpired
            case "delivery_expired": throw GroupClientError.deliveryExpired
            default: throw GroupClientError.unavailable
            }
        }
        return reply.data
    }
}
