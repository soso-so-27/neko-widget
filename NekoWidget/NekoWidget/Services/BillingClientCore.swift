import CryptoKit
import Foundation

/// Client-side values for the independent Plus billing identity. Nothing in
/// this file is a window, participant, device, or sharing credential.
enum BillingProtocolV1 {
    static let version = 1
    static let accountCreationPath = "/v1/billing/accounts"
    static let accountRecoveryPath = "/v1/billing/accounts/recover"
    static let transactionPath = "/v1/billing/transactions"
    static let entitlementPath = "/v1/billing/entitlement"
    static let windowSponsorshipGrantPath = "/v1/window-sponsorship"
    static let windowSponsorshipChangePathPrefix =
        "/v1/billing/window-sponsorships/"
    static let maximumSignedTransactionBytes = 48 * 1_024

    static func isSupportedSignedRequest(
        method: String,
        pathname: String
    ) -> Bool {
        (method == "POST" && pathname == transactionPath)
            || (method == "GET" && pathname == entitlementPath)
            || (["PUT", "DELETE"].contains(method)
                && pathname.hasPrefix(windowSponsorshipChangePathPrefix)
                && BillingValidation.canonicalOpaqueID(
                    String(pathname.dropFirst(
                        windowSponsorshipChangePathPrefix.count
                    )),
                    bytes: 16
                ))
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
    case billingAccountRecoveryUnavailable
    case billingAccountRecoveryEvidenceChanged
    case windowSponsorshipAttemptPending
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
        case .billingAccountRecoveryUnavailable:
            return "引き継げる購入情報を確認できませんでした。"
        case .billingAccountRecoveryEvidenceChanged:
            return "購入情報が変わりました。引き継ぎを最初からやり直してください。"
        case .windowSponsorshipAttemptPending:
            return "このまどのPlus設定を確認中です。もう一度お試しください。"
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

/// An independent, source-controlled gate for account recovery. The billing
/// transport and storefront can be enabled for internal work without making a
/// recovery operation reachable by accident.
struct BillingRecoveryConfiguration: Equatable, Sendable {
    let isEnabled: Bool

    static var current: Self {
        let value = (Bundle.main.infoDictionary ?? [:])[
            "PlusBillingRecoveryEnabled"
        ]
        let enabled: Bool
        if let number = value as? NSNumber {
            enabled = number.boolValue
        } else if let string = value as? String {
            enabled = ["1", "true", "yes"].contains(string.lowercased())
        } else {
            enabled = false
        }
        return Self(isEnabled: enabled)
    }
}

/// Independent source-controlled gate for the private-window sponsorship
/// client. Enabling billing transport or StoreKit must not expose this API.
struct BillingWindowSponsorshipConfiguration: Equatable, Sendable {
    let isEnabled: Bool

    static var current: Self {
        let value = (Bundle.main.infoDictionary ?? [:])[
            "PlusWindowSponsorshipClientEnabled"
        ]
        let enabled: Bool
        if let number = value as? NSNumber {
            enabled = number.boolValue
        } else if let string = value as? String {
            enabled = ["1", "true", "yes"].contains(string.lowercased())
        } else {
            enabled = false
        }
        return Self(isEnabled: enabled)
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

/// StoreKit evidence collected only after an explicit recovery action. Raw
/// JWS values and the device verification identifier are never logged or
/// written to ordinary app storage.
struct BillingStoreKitRecoveryEvidence: Equatable, Sendable {
    let billingAccountID: String
    let deviceVerificationID: String
    let appTransactionID: String
    let signedAppTransactionInfo: String
    let signedTransactionInfo: String
    let expectedTransactionID: String
    let expectedOriginalTransactionID: String

    func validated() throws -> Self {
        guard BillingValidation.canonicalUUIDv4(billingAccountID) != nil,
              BillingValidation.canonicalUUID(deviceVerificationID) != nil,
              BillingValidation.appTransactionID(appTransactionID),
              BillingValidation.compactJWS(signedAppTransactionInfo),
              signedAppTransactionInfo.utf8.count
                <= BillingProtocolV1.maximumSignedTransactionBytes,
              BillingValidation.compactJWS(signedTransactionInfo),
              signedTransactionInfo.utf8.count
                <= BillingProtocolV1.maximumSignedTransactionBytes,
              BillingValidation.transactionID(expectedTransactionID),
              BillingValidation.transactionID(expectedOriginalTransactionID)
        else { throw BillingClientError.billingAccountRecoveryUnavailable }
        return self
    }
}

/// Crash-resumable identity and exact wire evidence for one explicit recovery
/// request. This value is stored only in a ThisDeviceOnly Keychain item, never
/// in ordinary storage or logs, so a lost response can retry a byte-equivalent
/// idempotent body after StoreKit refreshes or renews a transaction.
struct BillingAccountRecoveryAttempt: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int = Self.schemaVersion
    var clientRequestID: String
    var signingPrivateKey: Data
    var billingAccountID: String
    var deviceVerificationID: String
    var appTransactionID: String
    var signedAppTransactionInfo: String
    var signedTransactionInfo: String
    var expectedTransactionID: String
    var expectedOriginalTransactionID: String

    static func pending(evidence: BillingStoreKitRecoveryEvidence) throws -> Self {
        let evidence = try evidence.validated()
        return try Self(
            clientRequestID: UUID().uuidString.lowercased(),
            signingPrivateKey: Curve25519.Signing.PrivateKey().rawRepresentation,
            billingAccountID: evidence.billingAccountID,
            deviceVerificationID: evidence.deviceVerificationID,
            appTransactionID: evidence.appTransactionID,
            signedAppTransactionInfo: evidence.signedAppTransactionInfo,
            signedTransactionInfo: evidence.signedTransactionInfo,
            expectedTransactionID: evidence.expectedTransactionID,
            expectedOriginalTransactionID: evidence.expectedOriginalTransactionID
        ).validated()
    }

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              BillingValidation.canonicalUUIDv4(clientRequestID) != nil,
              signingPrivateKey.count == 32,
              BillingValidation.canonicalUUIDv4(billingAccountID) != nil,
              BillingValidation.canonicalUUID(deviceVerificationID) != nil,
              BillingValidation.appTransactionID(appTransactionID),
              BillingValidation.compactJWS(signedAppTransactionInfo),
              signedAppTransactionInfo.utf8.count
                <= BillingProtocolV1.maximumSignedTransactionBytes,
              BillingValidation.compactJWS(signedTransactionInfo),
              signedTransactionInfo.utf8.count
                <= BillingProtocolV1.maximumSignedTransactionBytes,
              BillingValidation.transactionID(expectedTransactionID),
              BillingValidation.transactionID(expectedOriginalTransactionID)
        else { throw BillingClientError.malformedCredential }
        do {
            _ = try Curve25519.Signing.PrivateKey(
                rawRepresentation: signingPrivateKey
            )
        } catch {
            throw BillingClientError.malformedCredential
        }
        return self
    }

    func matchesCurrentAccount(
        _ evidence: BillingStoreKitRecoveryEvidence
    ) throws -> Bool {
        let attempt = try validated()
        let evidence = try evidence.validated()
        return attempt.billingAccountID == evidence.billingAccountID
            && attempt.deviceVerificationID == evidence.deviceVerificationID
            && attempt.appTransactionID == evidence.appTransactionID
    }

    func matchesExactWireEvidence(
        _ evidence: BillingStoreKitRecoveryEvidence
    ) throws -> Bool {
        let attempt = try validated()
        let evidence = try evidence.validated()
        return try attempt.matchesCurrentAccount(evidence)
            && attempt.signedAppTransactionInfo
                == evidence.signedAppTransactionInfo
            && attempt.signedTransactionInfo == evidence.signedTransactionInfo
            && attempt.expectedTransactionID == evidence.expectedTransactionID
            && attempt.expectedOriginalTransactionID
                == evidence.expectedOriginalTransactionID
    }

    var persistedEvidence: BillingStoreKitRecoveryEvidence {
        BillingStoreKitRecoveryEvidence(
            billingAccountID: billingAccountID,
            deviceVerificationID: deviceVerificationID,
            appTransactionID: appTransactionID,
            signedAppTransactionInfo: signedAppTransactionInfo,
            signedTransactionInfo: signedTransactionInfo,
            expectedTransactionID: expectedTransactionID,
            expectedOriginalTransactionID: expectedOriginalTransactionID
        )
    }

    func registering(
        _ result: BillingAccountRecoveryResult,
        installationMarker: UUID
    ) throws -> BillingCredential {
        let attempt = try validated()
        let result = try result.validated()
        let marker = installationMarker.uuidString.lowercased()
        guard result.clientRequestID == attempt.clientRequestID,
              result.billingAccountID == attempt.billingAccountID,
              BillingValidation.canonicalUUIDv4(marker) != nil
        else { throw BillingClientError.identityMismatch }
        return try BillingCredential(
            phase: .registered,
            installationMarker: marker,
            clientRequestID: attempt.clientRequestID,
            signingPrivateKey: attempt.signingPrivateKey,
            billingAccountID: result.billingAccountID,
            billingKeyID: result.billingKeyID
        ).validated()
    }
}

struct BillingAccountRecoveryResult: Equatable, Sendable {
    let clientRequestID: String
    let billingAccountID: String
    let billingKeyID: String
    let recoveredAt: Int

    func validated() throws -> Self {
        guard BillingValidation.canonicalUUIDv4(clientRequestID) != nil,
              BillingValidation.canonicalUUIDv4(billingAccountID) != nil,
              BillingValidation.canonicalOpaqueID(billingKeyID, bytes: 16),
              recoveredAt > 0
        else { throw BillingClientError.invalidServerResponse }
        return self
    }
}

enum BillingWindowSponsorshipOperation: String, Codable, Sendable {
    case sponsor
    case unsponsor

    var method: String {
        switch self {
        case .sponsor: return "PUT"
        case .unsponsor: return "DELETE"
        }
    }
}

enum BillingWindowSponsorshipServerState: String, Codable, Sendable {
    case active
    case unsponsored
}

/// A confirmed participant-scoped server snapshot. It deliberately preserves
/// "sponsored but currently not granting" as distinct from "unsponsored".
struct BillingWindowSponsorshipGrant: Codable, Equatable, Sendable {
    private static let maximumClockSkewMs = 5 * 60 * 1_000
    private static let offlineGraceDurationMs = 24 * 60 * 60 * 1_000
    private static let maximumAuthorityFreshnessMs =
        36 * 60 * 60 * 1_000 + maximumClockSkewMs

    let windowLineageSponsored: Bool
    let grantsPlus: Bool
    let accessUntilMs: Int?
    let evaluatedAtMs: Int
    let generation: Int

    func validated(now: Date = .now) throws -> Self {
        let nowMs = Int(now.timeIntervalSince1970 * 1_000)
        guard evaluatedAtMs > 0,
              evaluatedAtMs <= nowMs + Self.maximumClockSkewMs,
              (0 ... 1_000_000_000).contains(generation),
              !windowLineageSponsored || generation > 0
        else { throw BillingClientError.invalidServerResponse }
        if grantsPlus {
            guard windowLineageSponsored,
                  let accessUntilMs,
                  accessUntilMs > evaluatedAtMs,
                  accessUntilMs - evaluatedAtMs
                    <= Self.maximumAuthorityFreshnessMs
            else { throw BillingClientError.invalidServerResponse }
        } else {
            guard accessUntilMs == nil else {
                throw BillingClientError.invalidServerResponse
            }
        }
        return self
    }

    func accessState(now: Date = .now) -> BillingWindowPlusAccessState {
        let nowMs = Int(now.timeIntervalSince1970 * 1_000)
        guard grantsPlus, let accessUntilMs else {
            return windowLineageSponsored
                ? .sponsoredWithoutCurrentAccess(
                    generation: generation,
                    evaluatedAtMs: evaluatedAtMs
                )
                : .unsponsored(
                    generation: generation,
                    evaluatedAtMs: evaluatedAtMs
                )
        }
        if nowMs >= accessUntilMs {
            return .expired(
                accessUntilMs: accessUntilMs,
                generation: generation,
                evaluatedAtMs: evaluatedAtMs
            )
        }
        return .active(
            accessUntilMs: accessUntilMs,
            generation: generation,
            evaluatedAtMs: evaluatedAtMs
        )
    }

    /// A previously confirmed grant may bridge a transport outage only for a
    /// bounded interval. The server's access deadline remains authoritative,
    /// and a stale cached snapshot never becomes an unbounded Boolean grant.
    func offlineAccessState(now: Date = .now) -> BillingWindowPlusAccessState {
        let nowMs = Int(now.timeIntervalSince1970 * 1_000)
        guard grantsPlus, let accessUntilMs else {
            return .unknown(reason: .offline, lastConfirmed: self)
        }
        if nowMs >= accessUntilMs {
            return .expired(
                accessUntilMs: accessUntilMs,
                generation: generation,
                evaluatedAtMs: evaluatedAtMs
            )
        }
        let activeUntilMs = min(
            accessUntilMs,
            evaluatedAtMs + Self.offlineGraceDurationMs
        )
        guard nowMs < activeUntilMs else {
            return .unknown(reason: .offline, lastConfirmed: self)
        }
        return .offlineGrace(
            activeUntilMs: activeUntilMs,
            accessUntilMs: accessUntilMs,
            generation: generation,
            evaluatedAtMs: evaluatedAtMs
        )
    }
}

enum BillingWindowPlusUnknownReason: String, Codable, Sendable {
    case clientDisabled
    case offline
    case serverUnavailable
    case requestRejected
    case invalidResponse
}

/// UI may eventually render this state, but no current UI reads it. Unknown,
/// expired, unsponsored, and sponsored-without-access are never collapsed to
/// a single Boolean or treated as an access grant.
enum BillingWindowPlusAccessState: Equatable, Sendable {
    case unknown(
        reason: BillingWindowPlusUnknownReason,
        lastConfirmed: BillingWindowSponsorshipGrant?
    )
    case unsponsored(generation: Int, evaluatedAtMs: Int)
    case sponsoredWithoutCurrentAccess(generation: Int, evaluatedAtMs: Int)
    case active(accessUntilMs: Int, generation: Int, evaluatedAtMs: Int)
    case offlineGrace(
        activeUntilMs: Int,
        accessUntilMs: Int,
        generation: Int,
        evaluatedAtMs: Int
    )
    case expired(accessUntilMs: Int, generation: Int, evaluatedAtMs: Int)
}

struct BillingWindowSponsorshipChangeResult: Equatable, Sendable {
    let clientRequestID: String
    let billingAccountID: String
    let windowLineageID: String
    let state: BillingWindowSponsorshipServerState
    let generation: Int
    let recordedAt: Int

    func validated(
        for attempt: BillingWindowSponsorshipAttempt
    ) throws -> Self {
        let attempt = try attempt.validated()
        let expectedState: BillingWindowSponsorshipServerState =
            attempt.operation == .sponsor ? .active : .unsponsored
        guard BillingValidation.canonicalUUIDv4(clientRequestID) != nil,
              BillingValidation.canonicalUUIDv4(billingAccountID) != nil,
              BillingValidation.canonicalOpaqueID(windowLineageID, bytes: 16),
              clientRequestID == attempt.clientRequestID,
              billingAccountID == attempt.billingAccountID,
              windowLineageID == attempt.windowLineageID,
              state == expectedState,
              generation == attempt.expectedGeneration + 1,
              generation > 0,
              recordedAt > 0
        else { throw BillingClientError.identityMismatch }
        return self
    }
}

/// Exact semantic request body retained only in a ThisDeviceOnly Keychain
/// item. Billing authentication uses a fresh transport nonce on every retry,
/// while this body, request ID, owner consent nonce, and signature remain
/// byte-for-byte identical for server idempotency.
struct BillingWindowSponsorshipAttempt: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let maximumBodyBytes = 4_096

    var schemaVersion: Int = Self.schemaVersion
    var operation: BillingWindowSponsorshipOperation
    var clientRequestID: String
    var billingAccountID: String
    var windowLineageID: String
    var expectedGeneration: Int
    var expectedCurrentBillingAccountID: String?
    var exactRequestBody: Data

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              BillingValidation.canonicalUUIDv4(clientRequestID) != nil,
              BillingValidation.canonicalUUIDv4(billingAccountID) != nil,
              BillingValidation.canonicalOpaqueID(windowLineageID, bytes: 16),
              (0 ... 1_000_000_000).contains(expectedGeneration),
              expectedCurrentBillingAccountID.map({
                  BillingValidation.canonicalUUIDv4($0) != nil
              }) ?? true,
              (1 ... Self.maximumBodyBytes).contains(exactRequestBody.count)
        else { throw BillingClientError.malformedCredential }
        try BillingWindowSponsorshipWireCodec.validate(
            exactRequestBody,
            for: self
        )
        return self
    }

    func matchesStableIntent(
        _ candidate: BillingWindowSponsorshipAttempt
    ) throws -> Bool {
        let lhs = try validated()
        let rhs = try candidate.validated()
        guard lhs.operation == rhs.operation,
              lhs.billingAccountID == rhs.billingAccountID,
              lhs.windowLineageID == rhs.windowLineageID,
              lhs.expectedGeneration == rhs.expectedGeneration,
              lhs.expectedCurrentBillingAccountID
                == rhs.expectedCurrentBillingAccountID
        else { return false }
        switch lhs.operation {
        case .unsponsor:
            return true
        case .sponsor:
            let left = try BillingWindowSponsorshipWireCodec.decodeSponsor(
                lhs.exactRequestBody
            )
            let right = try BillingWindowSponsorshipWireCodec.decodeSponsor(
                rhs.exactRequestBody
            )
            return left.consentSpaceId == right.consentSpaceId
                && left.ownerParticipantId == right.ownerParticipantId
                && left.ownerDeviceId == right.ownerDeviceId
                && left.consentMembershipRevision
                    == right.consentMembershipRevision
        }
    }
}

struct BillingWindowOwnerDetachResult: Equatable, Sendable {
    let clientRequestID: String
    let windowLineageSponsored: Bool
    let generation: Int
    let recordedAt: Int

    func validated(for attempt: BillingWindowOwnerDetachAttempt) throws -> Self {
        let attempt = try attempt.validated()
        guard BillingValidation.canonicalUUIDv4(clientRequestID) != nil,
              clientRequestID == attempt.clientRequestID,
              !windowLineageSponsored,
              generation == attempt.expectedGeneration + 1,
              recordedAt > 0
        else { throw BillingClientError.identityMismatch }
        return self
    }
}

/// Exact owner-signed detach body. It is separate from payer sponsorship and
/// contains no BillingAccountID, purchase, photo, room key, or E2E material.
struct BillingWindowOwnerDetachAttempt: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int = Self.schemaVersion
    var clientRequestID: String
    var memberID: String
    var deviceID: String?
    var expectedGeneration: Int
    var exactRequestBody: Data

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              BillingValidation.canonicalUUIDv4(clientRequestID) != nil,
              BillingValidation.canonicalOpaqueID(memberID, bytes: 16),
              deviceID.map({
                  BillingValidation.canonicalOpaqueID($0, bytes: 16)
              }) ?? true,
              (1 ... 1_000_000_000).contains(expectedGeneration),
              (1 ... 512).contains(exactRequestBody.count)
        else { throw BillingClientError.malformedCredential }
        let body = try BillingWindowSponsorshipWireCodec.decodeOwnerDetach(
            exactRequestBody
        )
        guard body.protocolVersion == BillingProtocolV1.version,
              body.clientRequestId == clientRequestID,
              body.expectedGeneration == expectedGeneration,
              try BillingWindowSponsorshipWireCodec.encode(body)
                == exactRequestBody
        else { throw BillingClientError.malformedCredential }
        return self
    }

    func matchesStableIntent(
        _ candidate: BillingWindowOwnerDetachAttempt
    ) throws -> Bool {
        let lhs = try validated()
        let rhs = try candidate.validated()
        return lhs.memberID == rhs.memberID
            && lhs.deviceID == rhs.deviceID
            && lhs.expectedGeneration == rhs.expectedGeneration
    }
}

struct BillingWindowSponsorWireRequest: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let clientRequestId: String
    let expectedGeneration: Int
    let expectedCurrentBillingAccountId: String?
    let consentSpaceId: String
    let ownerParticipantId: String
    let ownerDeviceId: String
    let consentMembershipRevision: Int
    let consentIssuedAt: Int
    let ownerConsentNonce: String
    let ownerConsentSignature: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion, clientRequestId, expectedGeneration
        case expectedCurrentBillingAccountId, consentSpaceId
        case ownerParticipantId, ownerDeviceId, consentMembershipRevision
        case consentIssuedAt, ownerConsentNonce, ownerConsentSignature
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(clientRequestId, forKey: .clientRequestId)
        try container.encode(expectedGeneration, forKey: .expectedGeneration)
        if let expectedCurrentBillingAccountId {
            try container.encode(
                expectedCurrentBillingAccountId,
                forKey: .expectedCurrentBillingAccountId
            )
        } else {
            try container.encodeNil(forKey: .expectedCurrentBillingAccountId)
        }
        try container.encode(consentSpaceId, forKey: .consentSpaceId)
        try container.encode(ownerParticipantId, forKey: .ownerParticipantId)
        try container.encode(ownerDeviceId, forKey: .ownerDeviceId)
        try container.encode(
            consentMembershipRevision,
            forKey: .consentMembershipRevision
        )
        try container.encode(consentIssuedAt, forKey: .consentIssuedAt)
        try container.encode(ownerConsentNonce, forKey: .ownerConsentNonce)
        try container.encode(
            ownerConsentSignature,
            forKey: .ownerConsentSignature
        )
    }
}

struct BillingWindowUnsponsorWireRequest: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let clientRequestId: String
    let expectedGeneration: Int
    let expectedCurrentBillingAccountId: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion, clientRequestId, expectedGeneration
        case expectedCurrentBillingAccountId
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(clientRequestId, forKey: .clientRequestId)
        try container.encode(expectedGeneration, forKey: .expectedGeneration)
        if let expectedCurrentBillingAccountId {
            try container.encode(
                expectedCurrentBillingAccountId,
                forKey: .expectedCurrentBillingAccountId
            )
        } else {
            try container.encodeNil(forKey: .expectedCurrentBillingAccountId)
        }
    }
}

struct BillingWindowOwnerDetachWireRequest: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let clientRequestId: String
    let expectedGeneration: Int
}

enum BillingWindowSponsorshipWireCodec {
    private static let sponsorKeys: Set<String> = [
        "protocolVersion", "clientRequestId", "expectedGeneration",
        "expectedCurrentBillingAccountId", "consentSpaceId",
        "ownerParticipantId", "ownerDeviceId", "consentMembershipRevision",
        "consentIssuedAt", "ownerConsentNonce", "ownerConsentSignature"
    ]
    private static let unsponsorKeys: Set<String> = [
        "protocolVersion", "clientRequestId", "expectedGeneration",
        "expectedCurrentBillingAccountId"
    ]
    private static let ownerDetachKeys: Set<String> = [
        "protocolVersion", "clientRequestId", "expectedGeneration"
    ]

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(value)
        } catch {
            throw BillingClientError.malformedCredential
        }
    }

    static func decodeSponsor(_ data: Data) throws
        -> BillingWindowSponsorWireRequest {
        try requireExactKeys(data, expected: sponsorKeys)
        do { return try JSONDecoder().decode(
            BillingWindowSponsorWireRequest.self,
            from: data
        ) } catch { throw BillingClientError.malformedCredential }
    }

    static func decodeOwnerDetach(_ data: Data) throws
        -> BillingWindowOwnerDetachWireRequest {
        try requireExactKeys(data, expected: ownerDetachKeys)
        do { return try JSONDecoder().decode(
            BillingWindowOwnerDetachWireRequest.self,
            from: data
        ) } catch { throw BillingClientError.malformedCredential }
    }

    static func validate(
        _ data: Data,
        for attempt: BillingWindowSponsorshipAttempt
    ) throws {
        switch attempt.operation {
        case .sponsor:
            let body = try decodeSponsor(data)
            guard body.protocolVersion == BillingProtocolV1.version,
                  body.clientRequestId == attempt.clientRequestID,
                  body.expectedGeneration == attempt.expectedGeneration,
                  body.expectedCurrentBillingAccountId
                    == attempt.expectedCurrentBillingAccountID,
                  BillingValidation.canonicalOpaqueID(
                    body.consentSpaceId,
                    bytes: 16
                  ),
                  BillingValidation.canonicalOpaqueID(
                    body.ownerParticipantId,
                    bytes: 16
                  ),
                  BillingValidation.canonicalOpaqueID(
                    body.ownerDeviceId,
                    bytes: 16
                  ),
                  (1 ... 1_000_000_000).contains(
                    body.consentMembershipRevision
                  ),
                  body.consentIssuedAt > 0,
                  BillingValidation.canonicalOpaqueID(
                    body.ownerConsentNonce,
                    bytes: 16
                  ),
                  BillingValidation.canonicalOpaqueID(
                    body.ownerConsentSignature,
                    bytes: 64
                  ),
                  try encode(body) == data
            else { throw BillingClientError.malformedCredential }
        case .unsponsor:
            try requireExactKeys(data, expected: unsponsorKeys)
            let body: BillingWindowUnsponsorWireRequest
            do { body = try JSONDecoder().decode(
                BillingWindowUnsponsorWireRequest.self,
                from: data
            ) } catch { throw BillingClientError.malformedCredential }
            guard body.protocolVersion == BillingProtocolV1.version,
                  body.clientRequestId == attempt.clientRequestID,
                  body.expectedGeneration == attempt.expectedGeneration,
                  body.expectedCurrentBillingAccountId
                    == attempt.expectedCurrentBillingAccountID,
                  try encode(body) == data
            else { throw BillingClientError.malformedCredential }
        }
    }

    private static func requireExactKeys(
        _ data: Data,
        expected: Set<String>
    ) throws {
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data) }
        catch { throw BillingClientError.malformedCredential }
        guard let object = value as? [String: Any],
              Set(object.keys) == expected
        else { throw BillingClientError.malformedCredential }
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

    static func accountRecoveryTranscript(
        attempt: BillingAccountRecoveryAttempt,
        evidence: BillingStoreKitRecoveryEvidence,
        signingPublicKey: String
    ) throws -> Data {
        let attempt = try attempt.validated()
        let evidence = try evidence.validated()
        guard try attempt.matchesExactWireEvidence(evidence),
              BillingValidation.canonicalOpaqueID(signingPublicKey, bytes: 32)
        else { throw BillingClientError.billingAccountRecoveryEvidenceChanged }
        return try encodeCanonicalFields([
            "NWB1.ACCOUNT.RECOVER",
            String(BillingProtocolV1.version),
            attempt.clientRequestID,
            attempt.billingAccountID,
            signingPublicKey,
            evidence.deviceVerificationID,
            attempt.appTransactionID,
            attempt.expectedTransactionID,
            attempt.expectedOriginalTransactionID,
            sha256(Data(evidence.signedAppTransactionInfo.utf8)),
            sha256(Data(evidence.signedTransactionInfo.utf8))
        ])
    }

    static func windowSponsorshipOwnerConsentTranscript(
        clientRequestID: String,
        billingAccountID: String,
        windowLineageID: String,
        expectedGeneration: Int,
        expectedCurrentBillingAccountID: String?,
        consentSpaceID: String,
        ownerParticipantID: String,
        ownerDeviceID: String,
        consentIssuedAt: Int,
        consentMembershipRevision: Int,
        ownerConsentNonce: String
    ) throws -> Data {
        guard BillingValidation.canonicalUUIDv4(clientRequestID) != nil,
              BillingValidation.canonicalUUIDv4(billingAccountID) != nil,
              BillingValidation.canonicalOpaqueID(windowLineageID, bytes: 16),
              (0 ... 1_000_000_000).contains(expectedGeneration),
              expectedCurrentBillingAccountID.map({
                  BillingValidation.canonicalUUIDv4($0) != nil
              }) ?? true,
              BillingValidation.canonicalOpaqueID(consentSpaceID, bytes: 16),
              BillingValidation.canonicalOpaqueID(
                ownerParticipantID,
                bytes: 16
              ),
              BillingValidation.canonicalOpaqueID(ownerDeviceID, bytes: 16),
              consentIssuedAt > 0,
              (1 ... 1_000_000_000).contains(consentMembershipRevision),
              BillingValidation.canonicalOpaqueID(
                ownerConsentNonce,
                bytes: 16
              )
        else { throw BillingClientError.malformedCredential }
        return try encodeCanonicalFields([
            "NWB1.WINDOW.SPONSORSHIP",
            String(BillingProtocolV1.version),
            BillingWindowSponsorshipOperation.sponsor.rawValue,
            clientRequestID,
            billingAccountID,
            windowLineageID,
            String(expectedGeneration),
            expectedCurrentBillingAccountID ?? "",
            consentSpaceID,
            ownerParticipantID,
            ownerDeviceID,
            String(consentIssuedAt),
            String(consentMembershipRevision),
            ownerConsentNonce
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

    static func signingPublicKey(
        for attempt: BillingAccountRecoveryAttempt
    ) throws -> String {
        let attempt = try attempt.validated()
        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: attempt.signingPrivateKey
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

    static func sign(
        _ data: Data,
        recoveryAttempt: BillingAccountRecoveryAttempt
    ) throws -> String {
        let attempt = try recoveryAttempt.validated()
        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: attempt.signingPrivateKey
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
    static func canonicalUUID(_ value: String) -> UUID? {
        guard let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value
        else { return nil }
        return uuid
    }

    static func canonicalUUIDv4(_ value: String) -> UUID? {
        guard let uuid = canonicalUUID(value) else { return nil }
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

    static func appTransactionID(_ value: String) -> Bool {
        let bytes = value.utf8
        return (1 ... 256).contains(bytes.count)
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x20
                    && !(0x7f ... 0x9f).contains(scalar.value)
            }
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

    static func compactJWS(_ value: String) -> Bool {
        let components = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard components.count == 3 else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component.utf8.allSatisfy { byte in
                (byte >= 48 && byte <= 57)
                    || (byte >= 65 && byte <= 90)
                    || (byte >= 97 && byte <= 122)
                    || byte == 45
                    || byte == 95
            }
        }
    }
}
