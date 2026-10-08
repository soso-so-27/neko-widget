import Foundation
import CryptoKit
import ImageIO

struct ManagedPreservationConfiguration: Sendable {
    let origin: URL?
    let membershipAudience: String?
    var isEnabled: Bool { origin != nil && membershipAudience != nil }

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
        let enabledValue = Bundle.main.object(forInfoDictionaryKey: "ManagedPreservationEnabled")
        let enabled = (enabledValue as? NSNumber)?.boolValue == true
            || (enabledValue as? String)?.uppercased() == "YES"
        return Self(isEnabled: enabled,
             origin: (Bundle.main.object(forInfoDictionaryKey: "ManagedPreservationOrigin") as? String)
                .flatMap(URL.init(string:)),
             membershipAudience: Bundle.main.object(forInfoDictionaryKey: "ManagedPreservationMembershipAudience") as? String)
    }
}

enum ManagedPreservationError: Error, LocalizedError, Equatable, Sendable {
    enum AuthenticationStep: String, Sendable {
        case appleResponse = "A01", credential = "A02", challenge = "A03", state = "A04"
        case challengeExpired = "A05", payload = "A06", sessionExpired = "A07"
    }
    case disabled, authenticationRequired, authenticationFailed, staleSession
    case authenticationStepFailed(AuthenticationStep), appleAuthorizationFailed(Int)
    case secureStorage, invalidRecord, invalidResponse, responseTooLarge
    case membershipRequired, consentRequired, conflict, notFound, unavailable, interrupted
    case capacityReached, accessUnconfirmed, photoReplacement, rateLimited, integrityFailure, accountingUnavailable
    case membershipLinkConsent, membershipLinkConflict, membershipLinkExpired, billingIdentityUnavailable, billingIdentityChanged
    case pilotRegistrationPending(String)
    case requestRejected, uploadTimedOut, servicePaused
    case deletionNotReceived, deletionPending, deletionNotAccepted, exportUnsupported
    case exportThrottled(seconds: Int)

    /// Fixed support codes only: never include a URL, owner, token or raw error.
    var preservationSupportCode: String {
        switch self {
        case .requestRejected: "S01"
        case .uploadTimedOut: "S02"
        case .unavailable: "S03"
        case .invalidResponse: "S04"
        case .interrupted: "S05"
        case .staleSession: "S06"
        case .authenticationRequired: "S07"
        case .servicePaused: "S08"
        case .invalidRecord, .responseTooLarge: "S09"
        case .conflict: "S10"
        case .capacityReached, .accountingUnavailable: "S11"
        case .membershipRequired, .accessUnconfirmed: "S12"
        default: "S99"
        }
    }

    var errorDescription: String? {
        switch self {
        case .deletionNotReceived: "削除依頼の受付がまだ確認できません。受付結果を再確認するか、同じ依頼を再送してください。"
        case .deletionPending: "この保管先は削除処理中です。削除状況を確認してください。"
        case .deletionNotAccepted: "削除依頼は受け付けられませんでした。この操作では削除は始まっていません。"
        case .requestRejected: "保管先で送信データを受け付けられませんでした。元の写真とメモは端末に残っています。"
        case .uploadTimedOut: "保管先の応答が時間内に届きませんでした。保管結果を確認してください。"
        case .servicePaused: "保管先の受付が一時停止しています。保管済みの記録は引き続き開けます。"
        case .disabled: "この保管先はまだ利用できません。"
        case .authenticationRequired: "保管用の本人確認をやり直してください。"
        case .authenticationFailed: "本人確認を完了できませんでした。もう一度お試しください。"
        case .authenticationStepFailed(let step): "本人確認を完了できませんでした（\(step.rawValue)）。"
        case .appleAuthorizationFailed(let code): "Appleの本人確認を完了できませんでした（Apple \(code)）。"
        case .pilotRegistrationPending(let reference): "内部テストの登録確認待ちです。登録番号：\(reference)"
        case .staleSession: "本人確認の状態が変わりました。記録を読み込み直してください。"
        case .secureStorage: "本人確認情報を安全に保存・削除できませんでした。端末のロック解除後にお試しください。"
        case .invalidRecord: "写真またはメモの形式・大きさを確認してください。"
        case .invalidResponse: "保管結果を確認できませんでした。成功とは扱わず、記録を読み込み直してください。"
        case .responseTooLarge: "受信する記録が大きすぎるため中断しました。"
        case .membershipRequired: "新しく保管するには有効な会員資格が必要です。既存記録は引き続き利用できます。"
        case .consentRequired: "新しく保管する前に、保管方法への同意が必要です。"
        case .conflict: "記録が更新されています。最新の内容を読み込み直してください。"
        case .notFound: "この記録は見つからないか、削除されています。"
        case .exportUnsupported: "保管先がこの書き出し方式に対応していません。"
        case .unavailable: "保管先と通信できませんでした。変更結果は再読み込みで確認してください。"
        case .interrupted: "操作を中断しました。変更が届いた可能性があるため、記録を読み込み直してください。"
        case .capacityReached: "保管できる容量または件数の上限に達しています。既存の記録は削除せず、保管先の案内を確認してください。"
        case .accessUnconfirmed: "会員資格を確認できないため、新しい保管はまだ行えません。既存の記録は引き続き利用できます。"
        case .photoReplacement: "保管済みの写真は差し替えられません。別の写真は新しい記録として選び直してください。"
        case .rateLimited, .exportThrottled: "操作が続いたため一時的に制限されています。時間をおいてお試しください。"
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
    var weight: PhotoMemoWeightValue? = nil

    private enum CodingKeys: String, CodingKey {
        case formatVersion, text, capturedAt, writtenAt, updatedAt, catNames, photoFile, weight
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
        try values.encodeIfPresent(weight, forKey: .weight)
    }

    func validated() throws -> Self {
        do { try weight?.validate() } catch { throw ManagedPreservationError.invalidRecord }
        guard (1...2).contains(formatVersion), weight == nil || formatVersion == 2,
              text.count <= 500, text.utf8.count <= 65_536,
              catNames.count <= 100,
              catNames.allSatisfy({ !$0.isEmpty && $0.count <= 200 && $0.utf8.count <= 800 }),
              photoFile == nil || photoFile == "photo.jpg",
              photoFile != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || weight != nil else {
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
        weight = try values.decodeIfPresent(PhotoMemoWeightValue.self, forKey: .weight)
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
    enum Access: String, Codable, Sendable { case pilot }
    let linked: Bool
    let status: Status
    let access: Access?
    let pilotEndsAt: Int64?
    init(linked: Bool, status: Status, access: Access? = nil, pilotEndsAt: Int64? = nil) {
        self.linked = linked; self.status = status; self.access = access; self.pilotEndsAt = pilotEndsAt
    }
    var canSave: Bool {
        if access == .pilot {
            return !linked && status == .unknown && (pilotEndsAt ?? 0) > Int64(Date().timeIntervalSince1970 * 1000)
        }
        return linked && (status == .active || status == .grace)
    }
}

struct ManagedPreservationNoticeContact: Decodable, Equatable, Sendable {
    let version: Int
    let email: String?
    let source: String?

    func validated() throws -> Self {
        guard version == 1, (email == nil) == (source == nil),
              source == nil || source == "apple" else {
            throw ManagedPreservationError.invalidResponse
        }
        if let email {
            guard email.utf8.count <= 254,
                  email.range(of: #"^[^\s\x00-\x1f\x7f@]+@[^\s\x00-\x1f\x7f@]+\.[^\s\x00-\x1f\x7f@]+$"#,
                              options: .regularExpression) != nil else {
                throw ManagedPreservationError.invalidResponse
            }
        }
        return self
    }
}

struct ManagedPreservationRetention: Decodable, Equatable, Sendable {
    enum Status: String, Decodable, Sendable { case unlinked, active, grace, expired, unknown }
    let version: Int
    let status: Status
    let dueAt: Int64?
    let paused: Bool
    let finalNoticeDeliveredAt: Int64?

    func validated() throws -> Self {
        guard version == 1,
              dueAt == nil || (dueAt! > 0 && dueAt! < 253_402_300_800_000),
              finalNoticeDeliveredAt == nil || (finalNoticeDeliveredAt! > 0
                  && finalNoticeDeliveredAt! < 253_402_300_800_000) else {
            throw ManagedPreservationError.invalidResponse
        }
        switch status {
        case .unlinked, .active, .grace:
            guard dueAt == nil, !paused, finalNoticeDeliveredAt == nil else {
                throw ManagedPreservationError.invalidResponse
            }
        case .unknown:
            guard dueAt == nil, finalNoticeDeliveredAt == nil else {
                throw ManagedPreservationError.invalidResponse
            }
        case .expired:
            guard dueAt != nil, !paused,
                  finalNoticeDeliveredAt == nil || finalNoticeDeliveredAt! <= dueAt! else {
                throw ManagedPreservationError.invalidResponse
            }
        }
        return self
    }
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
        // Older deployed services do not include the record limit yet.
        let maximumRecords: Int64?
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
              records.saved >= 0, records.pending >= 0,
              records.saved <= Int64.max - records.pending else {
            throw ManagedPreservationError.invalidResponse
        }
        let allocated = space.usedBytes + space.reservedBytes
        guard space.overLimit == (allocated > space.limitBytes),
              space.availableBytes == max(0, space.limitBytes - allocated) else {
            throw ManagedPreservationError.invalidResponse
        }
        if let limit = records.maximumRecords {
            guard limit > 0,
                  records.creationLimitReached == (records.saved + records.pending >= limit) else {
                throw ManagedPreservationError.invalidResponse
            }
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
        var ownerID: String { credential.ownerId }
    }
    static let consentVersion = "managed-preservation-v1"
    private static let maximumPhotoBytes = 20 * 1024 * 1024
    private let configuration: ManagedPreservationConfiguration
    private let transport = ManagedPreservationTransport()
    private let requestOverride: RequestTransport?
    private let exportNow: @Sendable () -> Date
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
        struct Code: Decodable { let code: String; let registrationReference: String? }
        let error: Code
    }

    init(configuration: ManagedPreservationConfiguration = .current,
         billingIdentity: ManagedPreservationBillingIdentity = .init(), requestOverride: RequestTransport? = nil,
         exportNow: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.exportNow = exportNow
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

    func savedDeletionState() throws -> ManagedPreservationSessionStore.DeletionReceipt.State? {
        try store.deletionReceipt()?.state
    }

    func requestAccountDeletion() async throws {
        try Task.checkCancellation()
        let checkpoint = try captureSessionCheckpoint()
        let existing = try store.deletionReceipt()
        guard existing == nil || (existing?.ownerId == checkpoint.credential.ownerId
            && existing?.state == .unconfirmed) else { throw ManagedPreservationError.staleSession }
        var generator = SystemRandomNumberGenerator()
        let token = BillingProtocolCodec.base64URLEncode(Data((0..<32).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        }))
        let receipt = existing ?? .init(ownerId: checkpoint.credential.ownerId,
                                        token: token, state: .unconfirmed)
        let body = try JSONEncoder().encode(["confirmation": "delete-service-account", "receipt": receipt.token])
        do {
            _ = try await request("POST", path: "/v1/account-deletion", body: body,
                                  token: checkpoint.credential.token, maximumBytes: 2048, expectedStatus: 202,
                                  beforeDispatch: {
                if existing == nil { try self.store.saveDeletionReceipt(receipt, replacing: nil) }
            })
        } catch ManagedPreservationError.deletionNotAccepted {
            // A rejected retry cannot settle an older request still in flight.
            if existing == nil { try store.clearRejectedDeletion(receipt) }
            throw ManagedPreservationError.deletionNotAccepted
        } catch ManagedPreservationError.deletionPending {
            // Persist the proof before the next network hop, so a lost status
            // response/restart does not turn another device's request into 404 limbo.
            var pending = receipt; pending.state = .resolvingPending
            try store.saveDeletionReceipt(pending, replacing: receipt)
            _ = try await checkAccountDeletion()
            if try store.clear(ifMatching: checkpoint.credential) {
                credential = nil; loaded = true; challenge = nil; epoch &+= 1
            }
            return
        }
        var accepted = receipt; accepted.state = .processing
        try store.saveDeletionReceipt(accepted, replacing: receipt)
        // Forget only the login that issued this request; keep the receipt.
        if try store.clear(ifMatching: checkpoint.credential) {
            credential = nil; loaded = true; challenge = nil; epoch &+= 1
        }
    }

    func checkAccountDeletion() async throws -> ManagedPreservationSessionStore.DeletionReceipt.State {
        guard let receipt = try store.deletionReceipt() else { throw ManagedPreservationError.staleSession }
        struct Result: Decodable { let state: String }
        let data: Data
        do {
            data = try await request("GET", path: "/v1/account-deletion/" + receipt.ownerId.lowercased(),
                                     token: receipt.token, maximumBytes: 2048, expectedStatus: 200)
        } catch ManagedPreservationError.deletionNotReceived where receipt.state == .resolvingPending {
            var elsewhere = receipt; elsewhere.state = .requestedElsewhere
            try store.saveDeletionReceipt(elsewhere, replacing: receipt)
            if let login = try store.load(), login.ownerId == receipt.ownerId,
               try store.clear(ifMatching: login) {
                credential = nil; loaded = true; challenge = nil; epoch &+= 1
            }
            return .requestedElsewhere
        }
        let result: Result = try decode(data)
        guard let state = ManagedPreservationSessionStore.DeletionReceipt.State(rawValue: result.state),
              state == .processing || state == .completed else { throw ManagedPreservationError.invalidResponse }
        var updated = receipt; updated.state = state
        try store.saveDeletionReceipt(updated, replacing: receipt)
        return state
    }

    func dismissCompletedDeletion() throws { try store.dismissCompletedDeletion() }

    func requireSessionCheckpoint(_ checkpoint: SessionCheckpoint) throws {
        try ensureEpoch(checkpoint.epoch)
        guard try hasSession(), credential == checkpoint.credential,
              checkpoint.credential.expiresAt > Date(),
              try store.load() == checkpoint.credential else {
            throw ManagedPreservationError.staleSession
        }
    }

    /// Export alone may ask the person to authenticate again at a complete page
    /// boundary. Expiry is distinct from an unexpected credential/epoch change.
    func exportNeedsReauthentication(_ checkpoint: SessionCheckpoint, minimumLifetime: TimeInterval) throws -> Bool {
        try ensureEpoch(checkpoint.epoch)
        guard credential == checkpoint.credential, try store.load() == checkpoint.credential,
              try store.deletionReceipt() == nil else { throw ManagedPreservationError.staleSession }
        return checkpoint.credential.expiresAt.timeIntervalSince(exportNow()) <= minimumLifetime
    }

    func prepareExportSignIn(replacing checkpoint: SessionCheckpoint) async throws -> ManagedPreservationChallenge {
        _ = try exportNeedsReauthentication(checkpoint, minimumLifetime: 0)
        return try await prepareSignIn()
    }

    func requireExportReplacement(_ replacement: SessionCheckpoint, for previous: SessionCheckpoint) throws {
        try requireSessionCheckpoint(replacement)
        guard replacement.credential.ownerId == previous.credential.ownerId,
              replacement.credential.token != previous.credential.token,
              replacement.epoch != previous.epoch else { throw ManagedPreservationError.staleSession }
    }

    func cancelSignIn(ifState state: String) {
        guard challenge?.state == state else { return }
        cancelSignIn()
    }

    func membership() async throws -> ManagedPreservationMembership {
        let data = try await authenticated("GET", path: "/v1/membership", maximumBytes: 4096)
        let result: ManagedPreservationMembership = try decode(data)
        guard result.linked || result.status == .unknown else { throw ManagedPreservationError.invalidResponse }
        if result.access == .pilot {
            guard !result.linked, result.status == .unknown, let end = result.pilotEndsAt,
                  end > 0, end < 253_402_300_800_000 else { throw ManagedPreservationError.invalidResponse }
        } else if result.pilotEndsAt != nil { throw ManagedPreservationError.invalidResponse }
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

    func noticeContact() async throws -> ManagedPreservationNoticeContact {
        let data = try await authenticated("GET", path: "/v1/notice-contact", maximumBytes: 4096)
        let result: ManagedPreservationNoticeContact = try decode(data)
        return try result.validated()
    }

    func retention() async throws -> ManagedPreservationRetention {
        let data = try await authenticated("GET", path: "/v1/retention", maximumBytes: 4096)
        let result: ManagedPreservationRetention = try decode(data)
        return try result.validated()
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
        guard let pending = challenge else { throw ManagedPreservationError.authenticationStepFailed(.challenge) }
        challenge = nil // one attempt, including failed/cancelled exchanges
        try ensureEpoch(pending.epoch)
        guard state == pending.state else { throw ManagedPreservationError.authenticationStepFailed(.state) }
        guard pending.wire.expiresAt > Date() else {
            throw ManagedPreservationError.authenticationStepFailed(.challengeExpired)
        }
        guard identityToken.count <= 32_768, authorizationCode.count <= 8192,
              let token = String(data: identityToken, encoding: .utf8), !token.isEmpty,
              let code = String(data: authorizationCode, encoding: .utf8), !code.isEmpty else {
            throw ManagedPreservationError.authenticationStepFailed(.payload)
        }
        let payload = Exchange(challengeId: pending.wire.challengeId, challengeProof: pending.wire.challengeProof,
                               identityToken: token, authorizationCode: code)
        let data = try await request("POST", path: "/v1/auth/sessions",
                                     body: ManagedPreservationWire.encoder().encode(payload))
        try ensureEpoch(pending.epoch)
        let value: ManagedPreservationSessionStore.Credential = try decode(data)
        _ = try value.validated()
        guard value.expiresAt > Date() else {
            throw ManagedPreservationError.authenticationStepFailed(.sessionExpired)
        }
        guard try store.save(value, replacing: pending.replacing) else {
            throw ManagedPreservationError.staleSession
        }
        credential = value; loaded = true; epoch &+= 1
    }

    /// Rebind only at an explicit screen entry or sign-in preparation. Mutations
    /// still reject a changed credential; they never silently switch owners.
    func reloadSessionFromSecureStorage() throws {
        let current = try store.load()?.validated()
        credential = current; challenge = nil; loaded = true; epoch &+= 1
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

    func list(after: String? = nil, forExport: Bool = false) async throws -> ManagedPreservationPage {
        if let after, UUID(uuidString: after) == nil { throw ManagedPreservationError.invalidRecord }
        let query = [URLQueryItem(name: "limit", value: "20")]
            + (after.map { [URLQueryItem(name: "after", value: $0)] } ?? [])
        let data: Data
        if forExport {
            data = try await exportRead(path: "/v1/records", query: query, maximumBytes: 4 * 1024 * 1024)
        } else {
            data = try await authenticated("GET", path: "/v1/records", query: query, maximumBytes: 4 * 1024 * 1024)
        }
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
        let snapshot = try decodeExportRecord(data)
        guard snapshot.record.id == id else { throw ManagedPreservationError.invalidResponse }
        return snapshot
    }

    func exportPage(after: String? = nil, generation: Int? = nil) async throws -> ManagedPreservationExportPageFile {
        if let after, UUID(uuidString: after) == nil || generation == nil { throw ManagedPreservationError.invalidRecord }
        if let generation, generation < 0 { throw ManagedPreservationError.invalidRecord }
        let query = (after.map { [URLQueryItem(name: "after", value: $0)] } ?? [])
            + (generation.map { [URLQueryItem(name: "generation", value: String($0))] } ?? [])
        let payload = try PhotoMemoryNoteExporter.createServicePageBuffer()
        do {
            _ = try await exportRead(path: "/v1/export-page", query: query,
                maximumBytes: 96 * 1024 * 1024, responseFile: payload.fileURL,
                expectedMIMEType: "application/x-ndjson")
            return try ManagedPreservationExportPageFile(payload: payload, after: after, generation: generation)
        } catch {
            do { try payload.cleanup() }
            catch { throw PhotoMemoryNoteExportCleanupPending(payload: payload) }
            throw error
        }
    }

    /// Only export reads may wait for the owner's next request window. The
    /// original session stays fixed; mutations and ordinary browsing never retry.
    private func exportRead(path: String, query: [URLQueryItem], maximumBytes: Int,
                            responseFile: URL? = nil, expectedMIMEType: String = "application/json") async throws -> Data {
        guard ["/v1/export-page", "/v1/records"].contains(path) else { throw ManagedPreservationError.invalidRecord }
        let checkpoint = try captureSessionCheckpoint()
        for attempt in 0...1 {
            try requireSessionCheckpoint(checkpoint)
            do {
                let data = try await authenticated("GET", path: path, query: query, maximumBytes: maximumBytes,
                    responseFile: responseFile, expectedMIMEType: expectedMIMEType)
                try requireSessionCheckpoint(checkpoint)
                return data
            } catch ManagedPreservationError.exportThrottled(let seconds) where attempt == 0 {
                try requireSessionCheckpoint(checkpoint)
                guard checkpoint.credential.expiresAt > Date().addingTimeInterval(TimeInterval(seconds)) else {
                    throw ManagedPreservationError.authenticationRequired
                }
                try await Task.sleep(for: .seconds(seconds))
                try requireSessionCheckpoint(checkpoint)
            }
        }
        throw ManagedPreservationError.rateLimited
    }

    func decodeExportRecord(_ data: Data) throws -> ManagedPreservationExportSnapshot {
        let value: Detail = try decode(data)
        let record = ManagedPreservationRecord(recordId: value.recordId, revision: value.revision, document: value.document)
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
                               maximumBytes: Int = 65_536, responseFile: URL? = nil,
                               expectedMIMEType: String = "application/json") async throws -> Data {
        guard try hasSession(), let captured = credential else { throw ManagedPreservationError.authenticationRequired }
        let capturedEpoch = epoch
        do {
            let data = try await request(method, path: path, query: query, body: body,
                                         token: captured.token, revision: revision, maximumBytes: maximumBytes,
                                         responseFile: responseFile, expectedMIMEType: expectedMIMEType)
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
                         expectedStatus: Int? = nil, beforeDispatch: (() throws -> Void)? = nil,
                         responseFile: URL? = nil, expectedMIMEType: String = "application/json") async throws -> Data {
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
        request.setValue(expectedMIMEType, forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let revision { request.setValue(String(revision), forHTTPHeaderField: "If-Match") }
        do {
            let (data, response): (Data, URLResponse)
            try beforeDispatch?()
            if let requestOverride {
                let result = try await requestOverride(request, maximumBytes)
                guard result.0.count <= maximumBytes else { throw ManagedPreservationError.responseTooLarge }
                if let responseFile {
                    let file = try FileHandle(forWritingTo: responseFile)
                    do { try file.truncate(atOffset: 0); try file.write(contentsOf: result.0); try file.close() }
                    catch { try? file.close(); throw error }
                    data = Data(result.0.prefix(65_536))
                } else { data = result.0 }
                response = result.1
            } else { (data, response) = try await transport.data(for: request, maximumBytes: maximumBytes, responseFile: responseFile) }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.url == url else {
                throw ManagedPreservationError.invalidResponse
            }
            guard (200...299).contains(http.statusCode) else {
                let failure = (try? ManagedPreservationWire.decoder().decode(Failure.self, from: data))?.error
                let code = failure?.code
                if method == "GET", path == "/v1/export-page", http.statusCode == 404, code == "NOT_FOUND" {
                    throw ManagedPreservationError.exportUnsupported
                }
                if method == "GET", ["/v1/export-page", "/v1/records"].contains(path),
                   http.statusCode == 429, code == "RATE_LIMITED",
                   let value = http.value(forHTTPHeaderField: "Retry-After"),
                   let seconds = Int(value), (1...60).contains(seconds) {
                    throw ManagedPreservationError.exportThrottled(seconds: seconds)
                }
                if method == "POST", path == "/v1/account-deletion",
                   ["OWNER_DELETION_DISABLED", "PRESERVATION_DISABLED", "INVALID_REQUEST", "SESSION_INVALID", "unauthorized"].contains(code ?? "") {
                    throw ManagedPreservationError.deletionNotAccepted
                }
                switch code {
                case "OWNER_DELETION_NOT_FOUND": throw ManagedPreservationError.deletionNotReceived
                case "OWNER_DELETION_PENDING": throw ManagedPreservationError.deletionPending
                case "PILOT_REGISTRATION_PENDING":
                    guard let reference = failure?.registrationReference, UUID(uuidString: reference) != nil else {
                        throw ManagedPreservationError.invalidResponse
                    }
                    throw ManagedPreservationError.pilotRegistrationPending(reference)
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
                case "INVALID_REQUEST": throw ManagedPreservationError.requestRejected
                case "PILOT_WRITES_PAUSED", "PRESERVATION_INTAKE_PAUSED", "PRESERVATION_DISABLED":
                    throw ManagedPreservationError.servicePaused
                case "RATE_LIMITED": throw ManagedPreservationError.rateLimited
                case "SESSION_INVALID", "unauthorized": throw ManagedPreservationError.authenticationRequired
                default:
                    if http.statusCode == 401 { throw ManagedPreservationError.authenticationRequired }
                    if http.statusCode == 409 || http.statusCode == 412 { throw ManagedPreservationError.conflict }
                    if http.statusCode == 404 || http.statusCode == 410 { throw ManagedPreservationError.notFound }
                    throw ManagedPreservationError.unavailable
                }
            }
            guard http.statusCode == 204 || http.mimeType == expectedMIMEType else {
                throw ManagedPreservationError.invalidResponse
            }
            if let expectedStatus, http.statusCode != expectedStatus {
                throw ManagedPreservationError.invalidResponse
            }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as ManagedPreservationError { throw error }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as URLError where error.code == .timedOut { throw ManagedPreservationError.uploadTimedOut }
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

/// A completed HTTP page remains private until every record and the terminal
/// frame have been checked. The ZIP writer reads only one bounded frame at a time.
final class ManagedPreservationExportPageFile: @unchecked Sendable {
    let generation: Int
    let totalRecords: Int
    private let payload: PhotoMemoryNoteExportPayload
    private let file: FileHandle
    private let lock = NSLock()
    private var buffer: Data
    private var count = 0
    private var previousID: String?
    private var finished = false
    private var closed = false
    private var cursor: String?

    fileprivate init(payload: PhotoMemoryNoteExportPayload, after: String?, generation: Int?) throws {
        let file = try FileHandle(forReadingFrom: payload.fileURL)
        var buffer = Data()
        do {
            let line = try Self.readLine(file, buffer: &buffer, maximum: 1024)
            guard let header = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  Set(header.keys) == ["version", "type", "generation", "totalRecords"],
                  header["type"] as? String == "header", Self.integer(header["version"]) == 1,
                  let actualGeneration = Self.integer(header["generation"]), actualGeneration >= 0,
                  generation == nil || generation == actualGeneration,
                  let total = Self.integer(header["totalRecords"]), (0...1000).contains(total) else {
                throw ManagedPreservationError.invalidResponse
            }
            self.generation = actualGeneration; self.totalRecords = total
            self.payload = payload; self.file = file; self.buffer = buffer; self.previousID = after
        } catch { try? file.close(); throw error }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue,
              value.doubleValue >= 0, value.doubleValue <= 9_007_199_254_740_991 else { return nil }
        return value.intValue
    }

    private static func readLine(_ file: FileHandle, buffer: inout Data, maximum: Int) throws -> Data {
        var scanned = 0
        while true {
            try Task.checkCancellation()
            if let newline = buffer.dropFirst(scanned).firstIndex(of: 10) {
                let length = buffer.distance(from: buffer.startIndex, to: newline)
                guard length > 0, length <= maximum else { throw ManagedPreservationError.invalidResponse }
                let line = Data(buffer.prefix(length)); buffer.removeFirst(length + 1)
                return line
            }
            guard buffer.count <= maximum else { throw ManagedPreservationError.responseTooLarge }
            scanned = buffer.count
            guard let bytes = try file.read(upToCount: 65_536), !bytes.isEmpty else {
                throw ManagedPreservationError.invalidResponse // EOF without terminal newline is truncated.
            }
            buffer.append(bytes)
        }
    }

    func nextRecordData() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw ManagedPreservationError.invalidResponse }
        if finished { return nil }
        let line = try Self.readLine(file, buffer: &buffer, maximum: 29 * 1024 * 1024)
        guard let frame = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw ManagedPreservationError.invalidResponse
        }
        if frame["type"] as? String == "record" {
            guard count < 50, count < totalRecords,
                  let id = frame["recordId"] as? String, UUID(uuidString: id)?.uuidString.lowercased() == id,
                  previousID == nil || id > previousID! else { throw ManagedPreservationError.invalidResponse }
            previousID = id; count += 1
            return line
        }
        guard Set(frame.keys) == ["type", "generation", "recordCount", "nextCursor"],
              frame["type"] as? String == "complete", Self.integer(frame["generation"]) == generation,
              Self.integer(frame["recordCount"]) == count,
              frame["nextCursor"] is NSNull || (count > 0 && frame["nextCursor"] as? String == previousID),
              count > 0 || totalRecords == 0,
              buffer.isEmpty, (try file.read(upToCount: 1) ?? Data()).isEmpty else {
            throw ManagedPreservationError.invalidResponse
        }
        cursor = frame["nextCursor"] as? String; finished = true
        return nil
    }

    func nextCursor() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        guard finished else { throw ManagedPreservationError.invalidResponse }
        return cursor
    }

    func cleanup() throws {
        lock.lock(); defer { lock.unlock() }
        do {
            if !closed { try file.close(); closed = true }
            try payload.cleanup()
        } catch { throw PhotoMemoryNoteExportCleanupPending(payload: payload) }
    }

    deinit { try? file.close() } // Normal/error ownership always calls cleanup explicitly.
}

/// Streaming delegate bounds accumulated bytes before appending (not data(for:) after the fact).
private final class ManagedPreservationTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Pending {
        let limit: Int
        let continuation: CheckedContinuation<(Data, URLResponse), Error>
        let file: FileHandle?
        var received = 0
        var data = Data(); var response: URLResponse?; var failure: Error?
        init(_ limit: Int, _ continuation: CheckedContinuation<(Data, URLResponse), Error>, file: FileHandle?) {
            self.limit = limit; self.continuation = continuation; self.file = file
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

    override convenience init() { self.init(protocolClasses: nil) }

    fileprivate init(protocolClasses: [AnyClass]?) {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForResource = 120
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func invalidate() { session.invalidateAndCancel() }

    func data(for request: URLRequest, maximumBytes: Int, responseFile: URL? = nil) async throws -> (Data, URLResponse) {
        let file = try responseFile.map { try FileHandle(forWritingTo: $0) }
        do { try file?.truncate(atOffset: 0) }
        catch { try? file?.close(); throw error }
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.lock(); pending[task.taskIdentifier] = Pending(maximumBytes, continuation, file: file); lock.unlock()
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
        guard data.count <= item.limit - item.received else {
            item.failure = ManagedPreservationError.responseTooLarge
            lock.unlock(); dataTask.cancel(); return
        }
        do {
            if let file = item.file {
                try file.write(contentsOf: data)
                // Only retain the bounded error envelope in memory. Successful
                // export pages are consumed record by record from protected disk.
                item.data.append(data.prefix(max(0, 65_536 - item.data.count)))
            } else { item.data.append(data) }
            item.received += data.count
            lock.unlock()
        } catch {
            item.failure = error; lock.unlock(); dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let item = pending.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let item else { return }
        do { try item.file?.close() }
        catch { if item.failure == nil { item.failure = error } }
        if let error = item.failure ?? error { item.continuation.resume(throwing: error) }
        else if let response = item.response { item.continuation.resume(returning: (item.data, response)) }
        else { item.continuation.resume(throwing: ManagedPreservationError.invalidResponse) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping (CachedURLResponse?) -> Void) { completionHandler(nil) }
}

#if DEBUG
/// Exercises the real URLSession delegate/file path without external traffic.
private final class PreservationExportTransportFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "export-transport-fixture.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/x-ndjson"])!, cacheStoragePolicy: .notAllowed)
        let chunk = Data(repeating: 42, count: 65_536)
        client?.urlProtocol(self, didLoad: chunk)
        if url.path == "/cancel" { return }
        client?.urlProtocol(self, didLoad: chunk)
        client?.urlProtocol(self, didLoad: chunk)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension ManagedPreservationClient {
    static func testExportTransportFileBoundary() async throws {
        let transport = ManagedPreservationTransport(protocolClasses: [PreservationExportTransportFixture.self])
        defer { transport.invalidate() }
        let payload = try PhotoMemoryNoteExporter.createServicePageBuffer()
        defer { try? payload.cleanup() }
        let request = URLRequest(url: URL(string: "https://export-transport-fixture.invalid/complete")!)
        let (prefix, _) = try await transport.data(for: request, maximumBytes: 196_608, responseFile: payload.fileURL)
        guard prefix.count == 65_536,
              try Data(contentsOf: payload.fileURL) == Data(repeating: 42, count: 196_608) else {
            throw ManagedPreservationError.invalidResponse
        }
        do {
            _ = try await transport.data(for: request, maximumBytes: 100_000, responseFile: payload.fileURL)
            throw ManagedPreservationError.invalidResponse
        } catch ManagedPreservationError.responseTooLarge {}
        let size = try FileManager.default.attributesOfItem(atPath: payload.fileURL.path)[.size] as? NSNumber
        guard let size, size.intValue <= 100_000 else { throw ManagedPreservationError.responseTooLarge }
        let empty = try FileHandle(forWritingTo: payload.fileURL)
        try empty.truncate(atOffset: 0); try empty.close()
        let cancelRequest = URLRequest(url: URL(string: "https://export-transport-fixture.invalid/cancel")!)
        let task = Task { try await transport.data(for: cancelRequest, maximumBytes: 100_000, responseFile: payload.fileURL) }
        let deadline = ContinuousClock.now + .seconds(2)
        var received = false
        // Wait for the actual delegate write, then cancel the unfinished response.
        while ContinuousClock.now < deadline {
            let bytes = try FileManager.default.attributesOfItem(atPath: payload.fileURL.path)[.size] as? NSNumber
            if bytes?.intValue == 65_536 { received = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do { _ = try await task.value; throw ManagedPreservationError.invalidResponse }
        catch is CancellationError {}
        catch let error as URLError where error.code == .cancelled {}
        guard received else { throw ManagedPreservationError.invalidResponse }
        try payload.cleanup()
        guard !FileManager.default.fileExists(atPath: payload.fileURL.path) else { throw ManagedPreservationError.secureStorage }
    }
}
#endif
