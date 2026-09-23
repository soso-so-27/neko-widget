import Foundation
import CryptoKit
import ImageIO

struct ManagedPreservationConfiguration: Sendable {
    let origin: URL?
    let membershipAudience: String?
    var isEnabled: Bool { origin != nil }

    /// Bundle/build configuration only. Never accept a user, deep-link or server supplied origin.
    init(isEnabled: Bool = false, origin: URL? = nil, membershipAudience: String? = nil) {
        self.membershipAudience = membershipAudience.flatMap {
            $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$"#, options: .regularExpression) != nil ? $0 : nil
        }
        guard isEnabled, let origin,
              let parts = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443,
              parts.path.isEmpty || parts.path == "/",
              parts.query == nil, parts.fragment == nil else { self.origin = nil; return }
        var normalized = parts
        normalized.path = ""; normalized.port = nil
        self.origin = normalized.url
    }

    static var current: Self {
        Self(isEnabled: Bundle.main.object(forInfoDictionaryKey: "ManagedPreservationEnabled") as? Bool == true,
             origin: (Bundle.main.object(forInfoDictionaryKey: "ManagedPreservationOrigin") as? String)
                .flatMap(URL.init(string:)),
             membershipAudience: Bundle.main.object(forInfoDictionaryKey: "ManagedPreservationMembershipAudience") as? String)
    }
}

enum ManagedPreservationError: Error, LocalizedError, Equatable, Sendable {
    case disabled, authenticationRequired, authenticationFailed, staleSession
    case secureStorage, invalidRecord, invalidResponse, responseTooLarge
    case membershipRequired, consentRequired, conflict, notFound, unavailable, interrupted
    case capacityReached, accessUnconfirmed, photoReplacement, rateLimited, integrityFailure, accountingUnavailable
    case membershipLinkConsent, membershipLinkConflict, membershipLinkExpired, billingIdentityUnavailable, billingIdentityChanged

    var errorDescription: String? {
        switch self {
        case .disabled: "この保管先はまだ利用できません。"
        case .authenticationRequired: "保管用の本人確認をやり直してください。"
        case .authenticationFailed: "本人確認を完了できませんでした。もう一度お試しください。"
        case .staleSession: "本人確認の状態が変わりました。記録を読み込み直してください。"
        case .secureStorage: "本人確認情報を安全に保存・削除できませんでした。端末のロック解除後にお試しください。"
        case .invalidRecord: "写真またはメモの形式・大きさを確認してください。"
        case .invalidResponse: "保管結果を確認できませんでした。成功とは扱わず、記録を読み込み直してください。"
        case .responseTooLarge: "受信する記録が大きすぎるため中断しました。"
        case .membershipRequired: "新しく保管するには有効な会員資格が必要です。既存記録は引き続き利用できます。"
        case .consentRequired: "新しく保管する前に、保管方法への同意が必要です。"
        case .conflict: "記録が更新されています。最新の内容を読み込み直してください。"
        case .notFound: "この記録は見つからないか、削除されています。"
        case .unavailable: "保管先と通信できませんでした。変更結果は再読み込みで確認してください。"
        case .interrupted: "操作を中断しました。変更が届いた可能性があるため、記録を読み込み直してください。"
        case .capacityReached: "保管できる容量または件数の上限に達しています。既存の記録は削除せず、保管先の案内を確認してください。"
        case .accessUnconfirmed: "会員資格を確認できないため、新しい保管はまだ行えません。既存の記録は引き続き利用できます。"
        case .photoReplacement: "保管済みの写真は差し替えられません。別の写真は新しい記録として選び直してください。"
        case .rateLimited: "操作が続いたため一時的に制限されています。時間をおいてお試しください。"
        case .integrityFailure: "保管された記録の内容を安全に確認できませんでした。元の写真・メモを削除せず、保管先へお問い合わせください。"
        case .accountingUnavailable: "保管容量を安全に確認できません。空きがあるとは扱わず、時間をおいて確認してください。"
        case .membershipLinkConsent: "保管用の本人情報と会員情報をつなぐことを確認してください。"
        case .membershipLinkConflict: "別の本人情報との接続があるため変更できません。購入し直さず、サポートへお問い合わせください。保存済みの記録は引き続き利用できます。"
        case .membershipLinkExpired: "接続の確認期限が切れました。もう一度「会員情報を接続」を押してください。"
        case .billingIdentityUnavailable: "このiPhoneの会員情報を確認できません。会員情報の引き継ぎが必要な場合があります。購入し直さず、サポートへお問い合わせください。保存済みの記録は引き続き利用できます。"
        case .billingIdentityChanged: "会員情報が変わったため中断しました。接続状況を確認してからやり直してください。"
        }
    }
}

enum ManagedPreservationWire {
    static func string(_ date: Date) throws -> String {
        let value = date.timeIntervalSince1970
        guard value.isFinite, value >= -62_135_596_800, value < 253_402_300_800 else {
            throw ManagedPreservationError.invalidRecord
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func date(_ value: String) throws -> Date {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{3})?Z$"#,
                          options: .regularExpression) != nil else {
            throw ManagedPreservationError.invalidResponse
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let date = formatter.date(from: value),
              try string(date) == (value.contains(".") ? value : String(value.dropLast()) + ".000Z") else {
            throw ManagedPreservationError.invalidResponse
        }
        return date
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { value, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(value))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try date(decoder.singleValueContainer().decode(String.self))
        }
        return decoder
    }
}

/// Public single-record export fields only. Unknown dates remain null, not inferred.
struct ManagedPreservationDocument: Codable, Equatable, Sendable {
    var formatVersion: Int = 1
    var text: String
    var capturedAt: Date?
    var writtenAt: Date?
    var updatedAt: Date?
    var catNames: [String]
    var photoFile: String?

    private enum CodingKeys: String, CodingKey {
        case formatVersion, text, capturedAt, writtenAt, updatedAt, catNames, photoFile
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(formatVersion, forKey: .formatVersion)
        try values.encode(text, forKey: .text)
        try values.encode(capturedAt, forKey: .capturedAt)
        try values.encode(writtenAt, forKey: .writtenAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(catNames, forKey: .catNames)
        try values.encode(photoFile, forKey: .photoFile)
    }

    func validated() throws -> Self {
        guard formatVersion == 1, text.count <= 500, text.utf8.count <= 65_536,
              catNames.count <= 100,
              catNames.allSatisfy({ !$0.isEmpty && $0.count <= 200 && $0.utf8.count <= 800 }),
              photoFile == nil || photoFile == "photo.jpg",
              photoFile != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ManagedPreservationError.invalidRecord
        }
        for date in [capturedAt, writtenAt, updatedAt].compactMap({ $0 }) {
            _ = try ManagedPreservationWire.string(date)
        }
        return self
    }
}

struct ManagedPreservationDraft: Sendable {
    /// Keep this UUID stable across an uncertain save/retry; never silently generate another record.
    var recordID: UUID = UUID()
    var document: ManagedPreservationDocument
    var jpegData: Data?
}

extension ManagedPreservationDocument {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decode(Int.self, forKey: .formatVersion)
        text = try values.decode(String.self, forKey: .text)
        capturedAt = try values.decode(Date?.self, forKey: .capturedAt)
        writtenAt = try values.decode(Date?.self, forKey: .writtenAt)
        updatedAt = try values.decode(Date?.self, forKey: .updatedAt)
        catNames = try values.decode([String].self, forKey: .catNames)
        photoFile = try values.decode(String?.self, forKey: .photoFile)
    }
}

struct ManagedPreservationRecord: Codable, Identifiable, Sendable {
    let recordId: UUID
    let revision: Int
    let document: ManagedPreservationDocument
    var id: UUID { recordId }
}

struct ManagedPreservationPage: Decodable, Sendable {
    let items: [ManagedPreservationRecord]
    let nextCursor: String?
    let generation: Int
}

struct ManagedPreservationExportSnapshot: Sendable {
    let record: ManagedPreservationRecord
    let jpegData: Data?
    var document: ManagedPreservationDocument { record.document }
}

struct ManagedPreservationChallenge: Sendable {
    let nonce: String
    let state: String
    let expiresAt: Date
}

struct ManagedPreservationMembership: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case active, grace, expired, unknown }
    let linked: Bool
    let status: Status
    var canSave: Bool { linked && (status == .active || status == .grace) }
}

struct ManagedPreservationUsage: Decodable, Equatable, Sendable {
    struct Storage: Decodable, Equatable, Sendable {
        let usedBytes: Int64
        let reservedBytes: Int64
        let limitBytes: Int64
        let availableBytes: Int64
        let overLimit: Bool
    }
    struct Records: Decodable, Equatable, Sendable {
        let saved: Int64
        let pending: Int64
        let creationLimitReached: Bool
    }
    let version: Int
    let accounting: String
    let storage: Storage
    let records: Records

    func validated() throws -> Self {
        let space = storage
        guard version == 1, accounting == "encrypted-records-v1",
              space.usedBytes >= 0, space.reservedBytes >= 0,
              space.limitBytes > 0, space.availableBytes >= 0,
              space.usedBytes <= Int64.max - space.reservedBytes,
              records.saved >= 0, records.pending >= 0 else {
            throw ManagedPreservationError.invalidResponse
        }
        let allocated = space.usedBytes + space.reservedBytes
        guard space.overLimit == (allocated > space.limitBytes),
              space.availableBytes == max(0, space.limitBytes - allocated) else {
            throw ManagedPreservationError.invalidResponse
        }
        return self
    }
}

/// Read existing host-only identity. No bootstrap, purchase, recovery or deletion.
struct ManagedPreservationBillingIdentity: Sendable {
    var credential: @Sendable () throws -> BillingCredential? = { try BillingKeychainStore.load() }
    var installation: @Sendable () throws -> UUID = { try BillingInstallationMarkerStore.loadOrCreate() }

    func existing() throws -> BillingCredential {
        do {
            guard let value = try credential()?.validated(), value.phase == .registered,
                  value.installationMarker == (try installation()).uuidString.lowercased() else {
                throw ManagedPreservationError.billingIdentityUnavailable
            }
            return value
        } catch { throw ManagedPreservationError.billingIdentityUnavailable }
    }
}

struct ManagedPreservationLinkChallenge: Codable, Sendable {
    let version: Int; let purpose: String; let audience: String
    let challengeId: String; let ownerId: String; let billingAccountId: String
    let issuedAt: Int64; let expiresAt: Int64

    func signingBody(owner: String, billing: String, audience expected: String, now: Date = .now) throws -> Data {
        let millis = now.timeIntervalSince1970 * 1000
        guard version == 1, purpose == "preservation-membership-link", audience == expected,
              audience.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$"#, options: .regularExpression) != nil,
              ownerId == owner, billingAccountId == billing,
              BillingValidation.canonicalUUIDv4(ownerId) != nil,
              BillingValidation.canonicalUUIDv4(billingAccountId) != nil,
              BillingValidation.canonicalOpaqueID(challengeId, bytes: 32),
              issuedAt >= 0, expiresAt > issuedAt, expiresAt - issuedAt == 300_000,
              Double(issuedAt) <= millis + 30_000, Double(expiresAt) > millis,
              Double(expiresAt) <= millis + 330_000 else { throw ManagedPreservationError.invalidResponse }
        // Every interpolated string was restricted above to non-escaping ASCII.
        // Match the server's insertion order exactly; do not sign arbitrary JSON.
        return Data("{\"version\":1,\"purpose\":\"preservation-membership-link\",\"audience\":\"\(audience)\",\"challengeId\":\"\(challengeId)\",\"ownerId\":\"\(ownerId)\",\"billingAccountId\":\"\(billingAccountId)\",\"issuedAt\":\(issuedAt),\"expiresAt\":\(expiresAt)}".utf8)
    }
}

actor ManagedPreservationClient {
    typealias RequestTransport = @Sendable (URLRequest, Int) async throws -> (Data, URLResponse)
    /// An opaque identity for one uninterrupted authenticated operation. The
    /// epoch changes even when the same owner signs out and back in.
    struct SessionCheckpoint: Sendable {
        fileprivate let epoch: UInt64
        fileprivate let credential: ManagedPreservationSessionStore.Credential
    }
    static let consentVersion = "managed-preservation-v1"
    private static let maximumPhotoBytes = 20 * 1024 * 1024
    private let configuration: ManagedPreservationConfiguration
    private let transport = ManagedPreservationTransport()
    private let requestOverride: RequestTransport?
    private let billingIdentity: ManagedPreservationBillingIdentity
    private let store: ManagedPreservationSessionStore
    private var credential: ManagedPreservationSessionStore.Credential?
    private var loaded = false
    private var epoch: UInt64 = 0
    private var challenge: (wire: ChallengeResponse, state: String, epoch: UInt64,
                            replacing: ManagedPreservationSessionStore.Credential?)?

    private struct ChallengeResponse: Decodable {
        let challengeId: String; let challengeProof: String; let nonce: String; let expiresAt: Date
    }
    private struct Exchange: Encodable {
        let challengeId: String; let challengeProof: String
        let identityToken: String; let authorizationCode: String
    }
    private struct Put: Encodable {
        let expectedRevision: Int?; let consentVersion: String
        let document: ManagedPreservationDocument; let photoBase64: String?
        private enum CodingKeys: String, CodingKey { case expectedRevision, consentVersion, document, photoBase64 }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(expectedRevision, forKey: .expectedRevision)
            try c.encode(consentVersion, forKey: .consentVersion)
            try c.encode(document, forKey: .document)
            try c.encode(photoBase64, forKey: .photoBase64)
        }
    }
    private struct Detail: Decodable {
        let recordId: UUID; let revision: Int; let document: ManagedPreservationDocument
        let photoBase64: String?; let photoSHA256: String?
    }
    private struct Mutation: Decodable { let recordId: UUID; let revision: Int }
    private struct Failure: Decodable {
        struct Code: Decodable { let code: String }
        let error: Code
    }

    init(configuration: ManagedPreservationConfiguration = .current,
         billingIdentity: ManagedPreservationBillingIdentity = .init(), requestOverride: RequestTransport? = nil) {
        self.configuration = configuration
        self.billingIdentity = billingIdentity; self.requestOverride = requestOverride
        self.store = ManagedPreservationSessionStore(origin: configuration.origin?.absoluteString ?? "disabled")
    }

    deinit { transport.invalidate() }

    func hasSession() throws -> Bool {
        guard configuration.isEnabled else { return false }
        let persisted = try store.load()
        if !loaded { credential = persisted; loaded = true }
        else if persisted != credential { throw ManagedPreservationError.staleSession }
        if let value = credential, value.expiresAt <= Date() {
            credential = nil; epoch &+= 1
            guard try store.clear(ifMatching: value) else { throw ManagedPreservationError.staleSession }
        }
        return credential != nil
    }

    func sessionOwnerID() throws -> String? {
        try hasSession() ? credential?.ownerId : nil
    }

    func captureSessionCheckpoint() throws -> SessionCheckpoint {
        guard try hasSession(), let credential else { throw ManagedPreservationError.authenticationRequired }
        return SessionCheckpoint(epoch: epoch, credential: credential)
    }

    func requireSessionCheckpoint(_ checkpoint: SessionCheckpoint) throws {
        try ensureEpoch(checkpoint.epoch)
        guard try hasSession(), credential == checkpoint.credential,
              checkpoint.credential.expiresAt > Date(),
              try store.load() == checkpoint.credential else {
            throw ManagedPreservationError.staleSession
        }
    }

    func membership() async throws -> ManagedPreservationMembership {
        let data = try await authenticated("GET", path: "/v1/membership", maximumBytes: 4096)
        let result: ManagedPreservationMembership = try decode(data)
        guard result.linked || result.status == .unknown else { throw ManagedPreservationError.invalidResponse }
        return result
    }

    /// The server's authenticated snapshot is independent of membership.
    func usage() async throws -> ManagedPreservationUsage {
        let data = try await authenticated("GET", path: "/v1/usage", maximumBytes: 4096)
        do {
            let result: ManagedPreservationUsage = try decode(data)
            return try result.validated()
        } catch ManagedPreservationError.invalidResponse {
            throw ManagedPreservationError.accountingUnavailable
        }
    }

    func linkMembership(consent: Bool) async throws -> ManagedPreservationMembership {
        guard consent else { throw ManagedPreservationError.membershipLinkConsent }
        guard let audience = configuration.membershipAudience else { throw ManagedPreservationError.accessUnconfirmed }
        guard try hasSession(), let session = credential else { throw ManagedPreservationError.authenticationRequired }
        let capturedEpoch = epoch
        let billing = try billingIdentity.existing()
        guard let billingID = billing.billingAccountID, let keyID = billing.billingKeyID else {
            throw ManagedPreservationError.billingIdentityUnavailable
        }
        struct Issue: Encodable { let billingAccountId: String }
        struct Issued: Decodable { let challenge: ManagedPreservationLinkChallenge; let signingPath: String; let signingBody: String }
        struct Proof: Encodable { let billingKeyId: String; let timestamp: String; let nonce: String; let signature: String }
        struct Complete: Encodable { let challengeId: String; let proof: Proof }
        struct Completed: Decodable { let linked: Bool }
        func unchanged() throws {
            try ensureEpoch(capturedEpoch)
            guard credential == session, session.expiresAt > Date(), try store.load() == session else {
                throw ManagedPreservationError.staleSession
            }
            guard try billingIdentity.existing() == billing else { throw ManagedPreservationError.billingIdentityChanged }
        }
        let issueData = try await authenticated("POST", path: "/v1/membership/challenges",
            body: ManagedPreservationWire.encoder().encode(Issue(billingAccountId: billingID)), maximumBytes: 4096)
        try unchanged()
        let issued: Issued = try decode(issueData)
        let body = try issued.challenge.signingBody(owner: session.ownerId, billing: billingID, audience: audience)
        guard issued.signingPath == BillingProtocolV1.preservationMembershipLinkPath,
              Data(issued.signingBody.utf8) == body else { throw ManagedPreservationError.invalidResponse }
        let timestamp = Int(Date().timeIntervalSince1970)
        let nonce = BillingProtocolCodec.randomNonce()
        let transcript = try BillingProtocolCodec.signedRequestTranscript(billingAccountID: billingID, billingKeyID: keyID,
            timestamp: timestamp, nonce: nonce, method: "POST", pathname: BillingProtocolV1.preservationMembershipLinkPath,
            bodySHA256: BillingProtocolCodec.sha256(body))
        let proof = Proof(billingKeyId: keyID, timestamp: String(timestamp), nonce: nonce,
                          signature: try BillingProtocolCodec.sign(transcript, credential: billing))
        try unchanged()
        let completedData = try await authenticated("POST", path: "/v1/membership/link",
            body: ManagedPreservationWire.encoder().encode(Complete(challengeId: issued.challenge.challengeId, proof: proof)), maximumBytes: 4096)
        try unchanged()
        let completed: Completed = try decode(completedData)
        guard completed.linked else { throw ManagedPreservationError.invalidResponse }
        let result = try await membership()
        try unchanged()
        guard result.linked else { throw ManagedPreservationError.invalidResponse }
        return result
    }

    func prepareSignIn() async throws -> ManagedPreservationChallenge {
        guard configuration.isEnabled else { throw ManagedPreservationError.disabled }
        // Explicit reauthentication may replace a persisted session, but only if
        // that exact snapshot is still current when the Apple exchange finishes.
        let replacing = try store.load()
        credential = nil; loaded = true
        epoch &+= 1; let capturedEpoch = epoch; challenge = nil
        let data = try await request("POST", path: "/v1/auth/challenges", body: Data("{}".utf8))
        try ensureEpoch(capturedEpoch)
        let value: ChallengeResponse = try decode(data)
        guard !value.challengeId.isEmpty, value.challengeId.utf8.count <= 256,
              !value.challengeProof.isEmpty, value.challengeProof.utf8.count <= 1024,
              !value.nonce.isEmpty, value.nonce.utf8.count <= 1024,
              value.expiresAt > Date(), value.expiresAt.timeIntervalSinceNow <= 600 else {
            throw ManagedPreservationError.invalidResponse
        }
        let state = UUID().uuidString
        challenge = (value, state, capturedEpoch, replacing)
        return ManagedPreservationChallenge(nonce: value.nonce, state: state, expiresAt: value.expiresAt)
    }

    func cancelSignIn() {
        challenge = nil
        epoch &+= 1
    }

    func finishSignIn(state: String?, identityToken: Data, authorizationCode: Data) async throws {
        guard let pending = challenge else { throw ManagedPreservationError.authenticationFailed }
        challenge = nil // one attempt, including failed/cancelled exchanges
        try ensureEpoch(pending.epoch)
        guard state == pending.state, pending.wire.expiresAt > Date(),
              identityToken.count <= 32_768, authorizationCode.count <= 8192,
              let token = String(data: identityToken, encoding: .utf8), !token.isEmpty,
              let code = String(data: authorizationCode, encoding: .utf8), !code.isEmpty else {
            throw ManagedPreservationError.authenticationFailed
        }
        let payload = Exchange(challengeId: pending.wire.challengeId, challengeProof: pending.wire.challengeProof,
                               identityToken: token, authorizationCode: code)
        let data = try await request("POST", path: "/v1/auth/sessions",
                                     body: ManagedPreservationWire.encoder().encode(payload))
        try ensureEpoch(pending.epoch)
        let value: ManagedPreservationSessionStore.Credential = try decode(data)
        _ = try value.validated()
        guard value.expiresAt > Date() else { throw ManagedPreservationError.authenticationFailed }
        guard try store.save(value, replacing: pending.replacing) else {
            throw ManagedPreservationError.staleSession
        }
        credential = value; loaded = true; epoch &+= 1
    }

    /// Locally forget first even if revocation is unavailable. Never deletes archive records.
    func signOut() async throws {
        let previous: ManagedPreservationSessionStore.Credential?
        if loaded { previous = credential } else { previous = try store.load() }
        credential = nil; challenge = nil; loaded = true; epoch &+= 1
        guard try store.clear(ifMatching: previous) else { throw ManagedPreservationError.staleSession }
        if let previous {
            _ = try await request("DELETE", path: "/v1/auth/session", token: previous.token, expectedStatus: 204)
        }
    }

    func list(after: String? = nil) async throws -> ManagedPreservationPage {
        if let after, UUID(uuidString: after) == nil { throw ManagedPreservationError.invalidRecord }
        let query = [URLQueryItem(name: "limit", value: "20")]
            + (after.map { [URLQueryItem(name: "after", value: $0)] } ?? [])
        let data = try await authenticated("GET", path: "/v1/records", query: query, maximumBytes: 4 * 1024 * 1024)
        let page: ManagedPreservationPage = try decode(data)
        guard page.items.count <= 20, page.generation >= 0,
              Set(page.items.map(\.recordId)).count == page.items.count,
              page.nextCursor == nil || UUID(uuidString: page.nextCursor!) != nil,
              page.nextCursor == nil || page.nextCursor != after else { throw ManagedPreservationError.invalidResponse }
        for item in page.items { try validate(item) }
        return page
    }

    func detail(_ id: UUID) async throws -> ManagedPreservationExportSnapshot {
        let data = try await authenticated("GET", path: recordPath(id), maximumBytes: 30 * 1024 * 1024)
        let value: Detail = try decode(data)
        let record = ManagedPreservationRecord(recordId: value.recordId, revision: value.revision, document: value.document)
        guard value.recordId == id else { throw ManagedPreservationError.invalidResponse }
        try validate(record)
        var photo: Data?
        if let base64 = value.photoBase64 {
            guard base64.utf8.count <= ((Self.maximumPhotoBytes + 2) / 3) * 4,
                  let decoded = Data(base64Encoded: base64),
                  value.document.photoFile == "photo.jpg",
                  value.photoSHA256 == SHA256.hash(data: decoded).map({ String(format: "%02x", $0) }).joined() else {
                throw ManagedPreservationError.invalidResponse
            }
            try Self.validateJPEG(decoded)
            photo = decoded
        } else if value.document.photoFile != nil || value.photoSHA256 != nil {
            throw ManagedPreservationError.invalidResponse
        }
        try Task.checkCancellation()
        return ManagedPreservationExportSnapshot(record: record, jpegData: photo)
    }

    /// Existing edits use the current revision and unchanged photo copy. Server enforces both.
    func put(_ draft: ManagedPreservationDraft, expectedRevision: Int? = nil,
             consent: Bool) async throws -> Int {
        if expectedRevision == nil && !consent { throw ManagedPreservationError.consentRequired }
        if let expectedRevision, expectedRevision <= 0 { throw ManagedPreservationError.invalidRecord }
        let document = try draft.document.validated()
        guard (draft.jpegData == nil) == (document.photoFile == nil) else { throw ManagedPreservationError.invalidRecord }
        if let photo = draft.jpegData { try Self.validateJPEG(photo) }
        let payload = Put(expectedRevision: expectedRevision, consentVersion: Self.consentVersion,
                          document: document, photoBase64: draft.jpegData?.base64EncodedString())
        let body = try ManagedPreservationWire.encoder().encode(payload)
        guard body.count <= 30 * 1024 * 1024 else { throw ManagedPreservationError.invalidRecord }
        let data = try await authenticated("PUT", path: recordPath(draft.recordID), body: body)
        let result: Mutation = try decode(data)
        guard result.recordId == draft.recordID, result.revision > 0,
              expectedRevision == nil || result.revision > expectedRevision! else {
            throw ManagedPreservationError.invalidResponse
        }
        return result.revision
    }

    func delete(_ record: ManagedPreservationRecord) async throws {
        try validate(record)
        let data = try await authenticated("DELETE", path: recordPath(record.id), revision: record.revision)
        let result: Mutation = try decode(data)
        guard result.recordId == record.id, result.revision > record.revision else {
            throw ManagedPreservationError.invalidResponse
        }
    }

    private func validate(_ record: ManagedPreservationRecord) throws {
        guard record.revision > 0 else { throw ManagedPreservationError.invalidResponse }
        _ = try record.document.validated()
    }

    private func recordPath(_ id: UUID) -> String { "/v1/records/" + id.uuidString.lowercased() }

    private func ensureEpoch(_ captured: UInt64) throws {
        try Task.checkCancellation()
        guard epoch == captured else { throw ManagedPreservationError.staleSession }
    }

    private func authenticated(_ method: String, path: String, query: [URLQueryItem] = [],
                               body: Data? = nil, revision: Int? = nil,
                               maximumBytes: Int = 65_536) async throws -> Data {
        guard try hasSession(), let captured = credential else { throw ManagedPreservationError.authenticationRequired }
        let capturedEpoch = epoch
        do {
            let data = try await request(method, path: path, query: query, body: body,
                                         token: captured.token, revision: revision, maximumBytes: maximumBytes)
            try ensureEpoch(capturedEpoch)
            guard credential?.ownerId == captured.ownerId, credential?.token == captured.token,
                  captured.expiresAt > Date(), try store.load() == captured else {
                throw ManagedPreservationError.staleSession
            }
            return data
        } catch ManagedPreservationError.authenticationRequired {
            if epoch == capturedEpoch {
                credential = nil; epoch &+= 1
                _ = try store.clear(ifMatching: captured)
            }
            throw ManagedPreservationError.authenticationRequired
        }
    }

    private func request(_ method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil,
                         token: String? = nil, revision: Int? = nil, maximumBytes: Int = 65_536,
                         expectedStatus: Int? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard let origin = configuration.origin,
              var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            throw ManagedPreservationError.disabled
        }
        parts.path = path; parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw ManagedPreservationError.disabled }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        request.httpMethod = method; request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let revision { request.setValue(String(revision), forHTTPHeaderField: "If-Match") }
        do {
            let (data, response): (Data, URLResponse)
            if let requestOverride { (data, response) = try await requestOverride(request, maximumBytes) }
            else { (data, response) = try await transport.data(for: request, maximumBytes: maximumBytes) }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.url == url else {
                throw ManagedPreservationError.invalidResponse
            }
            guard (200...299).contains(http.statusCode) else {
                let code = (try? ManagedPreservationWire.decoder().decode(Failure.self, from: data))?.error.code
                switch code {
                case "MEMBERSHIP_LINK_CONFLICT": throw ManagedPreservationError.membershipLinkConflict
                case "LINK_CHALLENGE_INVALID", "INVALID_LINK_CHALLENGE": throw ManagedPreservationError.membershipLinkExpired
                case "BILLING_PROOF_UNCONFIRMED", "MEMBERSHIP_UNCONFIRMED", "MEMBERSHIP_NOT_CONFIGURED": throw ManagedPreservationError.accessUnconfirmed
                case "NEW_SAVE_REQUIRES_MEMBERSHIP": throw ManagedPreservationError.membershipRequired
                case "PRESERVATION_CONSENT_REQUIRED": throw ManagedPreservationError.consentRequired
                case "REVISION_CONFLICT", "ARCHIVE_CHANGED": throw ManagedPreservationError.conflict
                case "RECORD_NOT_FOUND", "RECORD_DELETED": throw ManagedPreservationError.notFound
                case "ARCHIVE_CAPACITY_REACHED": throw ManagedPreservationError.capacityReached
                case "ACCESS_UNCONFIRMED": throw ManagedPreservationError.accessUnconfirmed
                case "PHOTO_REPLACEMENT_REQUIRES_NEW_RECORD": throw ManagedPreservationError.photoReplacement
                case "ARCHIVE_INTEGRITY_FAILED", "ARCHIVE_PHOTO_UNAVAILABLE": throw ManagedPreservationError.integrityFailure
                case "ARCHIVE_ACCOUNTING_UNAVAILABLE": throw ManagedPreservationError.accountingUnavailable
                case "INVALID_RECORD", "INVALID_RECORD_ID", "INVALID_REVISION", "INVALID_JPEG",
                     "ARCHIVE_TOO_LARGE", "REQUEST_TOO_LARGE": throw ManagedPreservationError.invalidRecord
                case "RATE_LIMITED": throw ManagedPreservationError.rateLimited
                case "SESSION_INVALID", "unauthorized": throw ManagedPreservationError.authenticationRequired
                default:
                    if http.statusCode == 401 { throw ManagedPreservationError.authenticationRequired }
                    if http.statusCode == 409 || http.statusCode == 412 { throw ManagedPreservationError.conflict }
                    if http.statusCode == 404 || http.statusCode == 410 { throw ManagedPreservationError.notFound }
                    throw ManagedPreservationError.unavailable
                }
            }
            guard http.statusCode == 204 || http.mimeType == "application/json" else {
                throw ManagedPreservationError.invalidResponse
            }
            if let expectedStatus, http.statusCode != expectedStatus {
                throw ManagedPreservationError.invalidResponse
            }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as ManagedPreservationError { throw error }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw ManagedPreservationError.unavailable }
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do { return try ManagedPreservationWire.decoder().decode(Value.self, from: data) }
        catch { throw ManagedPreservationError.invalidResponse }
    }

    private static func validateJPEG(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximumPhotoBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceShouldCache: false
              ] as CFDictionary) != nil,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw ManagedPreservationError.invalidRecord
        }
    }
}

/// Streaming delegate bounds accumulated bytes before appending (not data(for:) after the fact).
private final class ManagedPreservationTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Pending {
        let limit: Int
        let continuation: CheckedContinuation<(Data, URLResponse), Error>
        var data = Data(); var response: URLResponse?; var failure: Error?
        init(_ limit: Int, _ continuation: CheckedContinuation<(Data, URLResponse), Error>) {
            self.limit = limit; self.continuation = continuation
        }
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock(); private var task: URLSessionTask?; private var cancelled = false
        func set(_ task: URLSessionTask) {
            lock.lock(); self.task = task; let cancel = cancelled; lock.unlock()
            if cancel { task.cancel() }
        }
        func cancel() {
            lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel()
        }
    }
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var session: URLSession!

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForResource = 120
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func invalidate() { session.invalidateAndCancel() }

    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, URLResponse) {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.lock(); pending[task.taskIdentifier] = Pending(maximumBytes, continuation); lock.unlock()
                cancellation.set(task); task.resume()
            }
        } onCancel: { cancellation.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        guard let item = pending[dataTask.taskIdentifier] else { lock.unlock(); completionHandler(.cancel); return }
        item.response = response
        if response.expectedContentLength > Int64(item.limit) {
            item.failure = ManagedPreservationError.responseTooLarge
            lock.unlock(); completionHandler(.cancel)
        } else { lock.unlock(); completionHandler(.allow) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let item = pending[dataTask.taskIdentifier], item.failure == nil else { lock.unlock(); return }
        guard data.count <= item.limit - item.data.count else {
            item.failure = ManagedPreservationError.responseTooLarge
            lock.unlock(); dataTask.cancel(); return
        }
        item.data.append(data); lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let item = pending.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let item else { return }
        if let error = item.failure ?? error { item.continuation.resume(throwing: error) }
        else if let response = item.response { item.continuation.resume(returning: (item.data, response)) }
        else { item.continuation.resume(throwing: ManagedPreservationError.invalidResponse) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping (CachedURLResponse?) -> Void) { completionHandler(nil) }
}
