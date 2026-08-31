import CryptoKit
import Foundation

/// Client-side values for the independent Plus billing identity. Nothing in
/// this file is a window, participant, device, or sharing credential.
enum BillingProtocolV1 {
    static let version = 1
    static let accountCreationPath = "/v1/billing/accounts"
    static let transactionPath = "/v1/billing/transactions"
    static let entitlementPath = "/v1/billing/entitlement"
    static let maximumSignedTransactionBytes = 48 * 1_024

    static func isSupportedSignedRequest(
        method: String,
        pathname: String
    ) -> Bool {
        (method == "POST" && pathname == transactionPath)
            || (method == "GET" && pathname == entitlementPath)
    }
}

enum BillingClientError: Error, Equatable, LocalizedError, Sendable {
    case configurationUnavailable
    case protectedDataUnavailable
    case keychainUnavailable
    case localStateUnavailable
    case malformedCredential
    case billingCredentialMissing
    case installationChanged
    case billingAccountRecoveryRequired
    case freshAccountAuthorizationExpired
    case credentialChanged
    case invalidServerResponse
    case identityMismatch
    case transportUnavailable
    case requestRejected(status: Int, code: String?)

    var errorDescription: String? {
        switch self {
        case .configurationUnavailable:
            return "課金機能は現在利用できません。"
        case .protectedDataUnavailable:
            return "購入情報を確認できませんでした。iPhoneのロックを解除して、もう一度お試しください。"
        case .keychainUnavailable, .localStateUnavailable, .malformedCredential:
            return "購入情報を安全に確認できませんでした。"
        case .billingCredentialMissing:
            return "このiPhoneには購入情報がありません。"
        case .installationChanged:
            return "このiPhoneの購入情報を引き継ぐ必要があります。"
        case .billingAccountRecoveryRequired:
            return "購入情報を引き継いでから、もう一度お試しください。"
        case .freshAccountAuthorizationExpired:
            return "購入情報をもう一度確認してください。"
        case .credentialChanged:
            return "購入情報が更新されました。もう一度お試しください。"
        case .invalidServerResponse, .identityMismatch:
            return "購入情報を確認できませんでした。"
        case .transportUnavailable:
            return "購入情報を確認できませんでした。時間をおいて、もう一度お試しください。"
        case let .requestRejected(status, _):
            return "購入情報を確認できませんでした（\(status)）。"
        }
    }
}

/// The billing API may share a deployment origin with the private-window API,
/// but its availability is deliberately configured independently.
struct BillingClientConfiguration: Equatable, Sendable {
    let isEnabled: Bool
    let baseURL: URL?

    var isConfigured: Bool { isEnabled && baseURL != nil }

    static var current: Self {
        let info = Bundle.main.infoDictionary ?? [:]
        let enabled = explicitFlag(info["PlusBillingClientEnabled"])
        let rawURL = (info["PlusBillingAPIBaseURL"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let baseURL = URL(string: rawURL).flatMap {
            publicHTTPSRootURL($0) ? $0 : nil
        }
        return Self(isEnabled: enabled, baseURL: baseURL)
    }

    private static func explicitFlag(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            return ["1", "true", "yes"].contains(string.lowercased())
        }
        return false
    }

    private static func publicHTTPSRootURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let rawHost = url.host?.lowercased(),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              !rawHost.hasSuffix("."),
              rawHost.contains("."),
              !rawHost.contains(":"),
              !rawHost.allSatisfy({ $0.isNumber || $0 == "." }),
              !["localhost", "example", "invalid", "local", "test"]
                .contains(rawHost),
              ![
                  ".localhost", ".example", ".invalid", ".local", ".test",
                  ".internal", ".lan", ".home.arpa"
              ].contains(where: { rawHost.hasSuffix($0) }),
              rawHost.split(separator: ".").allSatisfy({ label in
                  guard (1 ... 63).contains(label.count),
                        label.first != "-",
                        label.last != "-"
                  else { return false }
                  return label.allSatisfy {
                      $0.isLetter || $0.isNumber || $0 == "-"
                  }
              })
        else { return false }
        return true
    }
}

enum BillingCredentialPhase: String, Codable, Sendable {
    case pendingBootstrap
    case registered
}

/// A crash-resumable billing identity. The pending key and request ID must be
/// saved to Keychain before the first network request so a lost response can
/// be retried without creating an orphaned second account.
struct BillingCredential: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int = Self.schemaVersion
    var phase: BillingCredentialPhase
    var installationMarker: String
    var clientRequestID: String
    var signingPrivateKey: Data
    var billingAccountID: String?
    var billingKeyID: String?

    static func pending(installationMarker: UUID) -> Self {
        let signingKey = Curve25519.Signing.PrivateKey()
        return Self(
            phase: .pendingBootstrap,
            installationMarker: installationMarker.uuidString.lowercased(),
            clientRequestID: UUID().uuidString.lowercased(),
            signingPrivateKey: signingKey.rawRepresentation,
            billingAccountID: nil,
            billingKeyID: nil
        )
    }

    var billingAccountUUID: UUID? {
        billingAccountID.flatMap(UUID.init(uuidString:))
    }

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              BillingValidation.canonicalUUIDv4(installationMarker) != nil,
              BillingValidation.canonicalUUIDv4(clientRequestID) != nil,
              signingPrivateKey.count == 32
        else { throw BillingClientError.malformedCredential }
        do {
            _ = try Curve25519.Signing.PrivateKey(
                rawRepresentation: signingPrivateKey
            )
        } catch {
            throw BillingClientError.malformedCredential
        }

        switch phase {
        case .pendingBootstrap:
            guard billingAccountID == nil, billingKeyID == nil else {
                throw BillingClientError.malformedCredential
            }
        case .registered:
            guard let billingAccountID,
                  let billingKeyID,
                  BillingValidation.canonicalUUIDv4(billingAccountID) != nil,
                  BillingValidation.canonicalOpaqueID(billingKeyID, bytes: 16)
            else { throw BillingClientError.malformedCredential }
        }
        return self
    }

    func registering(_ result: BillingAccountBootstrapResult) throws -> Self {
        guard phase == .pendingBootstrap else {
            throw BillingClientError.malformedCredential
        }
        let result = try result.validated()
        var copy = self
        copy.phase = .registered
        copy.billingAccountID = result.billingAccountID
        copy.billingKeyID = result.billingKeyID
        return try copy.validated()
    }
}

struct BillingAccountBootstrapResult: Equatable, Sendable {
    let billingAccountID: String
    let billingKeyID: String
    let createdAt: Int

    func validated() throws -> Self {
        guard BillingValidation.canonicalUUIDv4(billingAccountID) != nil,
              BillingValidation.canonicalOpaqueID(billingKeyID, bytes: 16),
              createdAt > 0
        else { throw BillingClientError.invalidServerResponse }
        return self
    }
}

enum BillingTransactionDisposition: String, Codable, Sendable {
    /// The ledger event is eligible for later account/status reconciliation.
    /// It is not, by itself, an active Plus entitlement or window sponsorship.
    case candidate
    case nonEntitling
}

enum BillingProvisionalEntitlementStatus: String, Codable, Sendable {
    case activeCandidate
    case noActiveCandidate
}

enum BillingAuthoritativeEntitlementStatus: String, Codable, Sendable {
    case active
    case gracePeriod
    case billingRetry
    case expired
    case revoked
    case upgraded
    case unconfirmed

    var grantsAccess: Bool {
        switch self {
        case .active, .gracePeriod:
            return true
        case .billingRetry, .expired, .revoked, .upgraded, .unconfirmed:
            return false
        }
    }
}

/// The only server response that may grant Plus on this client. The server's
/// Apple subscription status and its bounded freshness window are both
/// required: a long StoreKit expiry can never outlive stale server authority.
struct BillingAuthoritativeEntitlement: Codable, Equatable, Sendable {
    private static let maximumClockSkewMs = 5 * 60 * 1_000
    private static let maximumAuthorityFreshnessMs =
        36 * 60 * 60 * 1_000 + maximumClockSkewMs

    let status: BillingAuthoritativeEntitlementStatus
    let productId: String?
    let accessUntilMs: Int?
    let authorityStaleAtMs: Int?
    let evaluatedAtMs: Int
    let provisional: Bool
    let grantsPlus: Bool

    var effectiveAccessUntilMs: Int? {
        guard let accessUntilMs, let authorityStaleAtMs else { return nil }
        return min(accessUntilMs, authorityStaleAtMs)
    }

    func validated(now: Date = .now) throws -> Self {
        let nowMs = Int(now.timeIntervalSince1970 * 1_000)
        guard evaluatedAtMs > 0,
              evaluatedAtMs <= nowMs + Self.maximumClockSkewMs,
              !provisional,
              grantsPlus == status.grantsAccess,
              productId.map(BillingValidation.productID) ?? true,
              accessUntilMs.map({ $0 > 0 }) ?? true,
              authorityStaleAtMs.map({ $0 > 0 }) ?? true
        else { throw BillingClientError.invalidServerResponse }

        switch status {
        case .active, .gracePeriod:
            guard productId != nil,
                  let accessUntilMs,
                  let authorityStaleAtMs,
                  accessUntilMs > evaluatedAtMs,
                  authorityStaleAtMs > evaluatedAtMs,
                  authorityStaleAtMs - evaluatedAtMs
                    <= Self.maximumAuthorityFreshnessMs,
                  min(accessUntilMs, authorityStaleAtMs) > nowMs
            else { throw BillingClientError.invalidServerResponse }
        case .billingRetry, .expired, .revoked, .upgraded:
            guard productId != nil,
                  accessUntilMs == nil,
                  authorityStaleAtMs != nil
            else { throw BillingClientError.invalidServerResponse }
        case .unconfirmed:
            let hasNoAuthority = productId == nil
                && accessUntilMs == nil
                && authorityStaleAtMs == nil
            let hasUnsupportedAuthority = productId != nil
                && accessUntilMs == nil
                && authorityStaleAtMs != nil
            let hasExpiredOrStaleAuthority: Bool
            if productId != nil,
               let accessUntilMs,
               let authorityStaleAtMs {
                hasExpiredOrStaleAuthority = accessUntilMs <= evaluatedAtMs
                    || authorityStaleAtMs <= evaluatedAtMs
            } else {
                hasExpiredOrStaleAuthority = false
            }
            guard hasNoAuthority
                    || hasUnsupportedAuthority
                    || hasExpiredOrStaleAuthority
            else { throw BillingClientError.invalidServerResponse }
        }
        return self
    }
}

/// A deliberately non-authoritative summary of the verified transaction
/// ledger. Even `activeCandidate` must never grant Plus or sponsorship; only a
/// future authoritative status contract may do that.
struct BillingProvisionalEntitlement: Codable, Equatable, Sendable {
    let status: BillingProvisionalEntitlementStatus
    let productId: String?
    let expiresDateMs: Int?
    let lastEventSignedDateMs: Int?
    let evaluatedAtMs: Int
    let provisional: Bool
    let grantsPlus: Bool

    func validated() throws -> Self {
        guard evaluatedAtMs > 0,
              provisional,
              !grantsPlus,
              lastEventSignedDateMs.map({ $0 > 0 }) ?? true
        else { throw BillingClientError.invalidServerResponse }

        switch status {
        case .activeCandidate:
            guard let productId,
                  BillingValidation.productID(productId),
                  let expiresDateMs,
                  expiresDateMs > evaluatedAtMs,
                  lastEventSignedDateMs != nil
            else { throw BillingClientError.invalidServerResponse }
        case .noActiveCandidate:
            guard productId == nil, expiresDateMs == nil else {
                throw BillingClientError.invalidServerResponse
            }
        }
        return self
    }
}

struct BillingTransactionRecordAcknowledgement: Equatable, Sendable {
    let billingAccountID: BillingAccountID
    let originalTransactionID: String
    let transactionID: String
    let disposition: BillingTransactionDisposition

    func validated(
        credential: BillingCredential,
        expectedTransactionID: String,
        expectedOriginalTransactionID: String
    ) throws -> Self {
        let credential = try credential.validated()
        guard credential.phase == .registered,
              billingAccountID.rawValue.uuidString.lowercased()
                == credential.billingAccountID,
              transactionID == expectedTransactionID,
              originalTransactionID == expectedOriginalTransactionID,
              BillingValidation.transactionID(transactionID),
              BillingValidation.transactionID(originalTransactionID)
        else { throw BillingClientError.identityMismatch }
        return self
    }
}

enum BillingProtocolCodec {
    static func accountCreationTranscript(
        clientRequestID: String,
        signingPublicKey: String
    ) throws -> Data {
        guard BillingValidation.canonicalUUIDv4(clientRequestID) != nil,
              BillingValidation.canonicalOpaqueID(signingPublicKey, bytes: 32)
        else { throw BillingClientError.malformedCredential }
        return try encodeCanonicalFields([
            "NWB1.ACCOUNT.CREATE",
            String(BillingProtocolV1.version),
            clientRequestID,
            signingPublicKey
        ])
    }

    static func signedRequestTranscript(
        billingAccountID: String,
        billingKeyID: String,
        timestamp: Int,
        nonce: String,
        method: String,
        pathname: String,
        bodySHA256: String
    ) throws -> Data {
        guard BillingValidation.canonicalUUIDv4(billingAccountID) != nil,
              BillingValidation.canonicalOpaqueID(billingKeyID, bytes: 16),
              timestamp > 0,
              BillingValidation.canonicalOpaqueID(nonce, bytes: 16),
              BillingProtocolV1.isSupportedSignedRequest(
                  method: method,
                  pathname: pathname
              ),
              BillingValidation.canonicalOpaqueID(bodySHA256, bytes: 32)
        else { throw BillingClientError.malformedCredential }
        return try encodeCanonicalFields([
            "NWB1.REQUEST",
            String(BillingProtocolV1.version),
            billingAccountID,
            billingKeyID,
            String(timestamp),
            nonce,
            method.uppercased(),
            pathname,
            bodySHA256
        ])
    }

    static func signingPublicKey(for credential: BillingCredential) throws -> String {
        let credential = try credential.validated()
        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: credential.signingPrivateKey
        )
        return base64URLEncode(key.publicKey.rawRepresentation)
    }

    static func sign(_ data: Data, credential: BillingCredential) throws -> String {
        let credential = try credential.validated()
        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: credential.signingPrivateKey
        )
        return base64URLEncode(try key.signature(for: data))
    }

    static func sha256(_ data: Data) -> String {
        base64URLEncode(Data(SHA256.hash(data: data)))
    }

    static func randomNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0 ..< 16).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
        return base64URLEncode(bytes)
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ value: String) -> Data? {
        guard value.utf8.allSatisfy({ byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 45
                || byte == 95
        }) else { return nil }
        var encoded = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              base64URLEncode(data) == value
        else { return nil }
        return data
    }

    private static func encodeCanonicalFields(_ fields: [String]) throws -> Data {
        var result = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            guard bytes.count <= Int(UInt16.max) else {
                throw BillingClientError.malformedCredential
            }
            var length = UInt16(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(bytes)
        }
        return result
    }
}

enum BillingValidation {
    static func canonicalUUIDv4(_ value: String) -> UUID? {
        guard let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value
        else { return nil }
        var tuple = uuid.uuid
        let bytes = withUnsafeBytes(of: &tuple) { Array($0) }
        guard bytes.count == 16,
              bytes[6] >> 4 == 4,
              bytes[8] & 0xc0 == 0x80
        else { return nil }
        return uuid
    }

    static func canonicalOpaqueID(_ value: String, bytes: Int) -> Bool {
        BillingProtocolCodec.base64URLDecode(value)?.count == bytes
    }

    static func transactionID(_ value: String) -> Bool {
        let bytes = value.utf8
        return (1 ... 32).contains(bytes.count)
            && bytes.allSatisfy { byte in byte >= 48 && byte <= 57 }
    }

    static func productID(_ value: String) -> Bool {
        let bytes = value.utf8
        return (1 ... 100).contains(bytes.count)
            && bytes.allSatisfy { byte in
                (byte >= 48 && byte <= 57)
                    || (byte >= 65 && byte <= 90)
                    || (byte >= 97 && byte <= 122)
                    || byte == 45
                    || byte == 46
                    || byte == 95
            }
    }
}
