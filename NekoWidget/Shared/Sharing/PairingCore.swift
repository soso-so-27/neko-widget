import CryptoKit
import Foundation
import Security

enum PairingProtocol {
    static let version = 1
    static let invitationPrefix = "NW1"
    static let deviceRecoveryPrefix = "NWR1"
    static let maximumClockSkewSeconds: TimeInterval = 300
    static let roomKeyEnvelopeAlgorithm = "X25519-HKDF-SHA256-CHACHA20POLY1305"
}

enum PairingRole: String, Codable, Sendable {
    case inviter
    case invitee
}

enum PairingMediaSharingConsent {
    /// Version 2 replaces the retired automatic daily set with an explicit,
    /// one-photo-at-a-time Share Extension flow. Existing version-1 consent
    /// must never authorize the new capture-date and delivery semantics.
    static let currentVersion = 2
}

enum PairingPhase: String, Codable, Sendable {
    case unpaired
    case creatingInvitation
    case awaitingInvitee
    case joining
    case claimingRecovery
    case pendingRecoveryApproval
    case recoveryAwaitingCompletion
    case pendingApproval
    case approvalRequired
    case awaitingCompletion
    case paired
    case failed
}

/// Non-secret pairing metadata shared with the Widget extension.
/// Private keys, the room key, and invite secrets are stored only in Keychain.
struct PairingState: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int = Self.schemaVersion
    /// Optional only for decoding Phase-1 files written before CAS existed.
    /// PairingStateStore normalizes a missing value to zero before returning.
    var storageRevision: Int? = 0
    var installationMarker: String
    var phase: PairingPhase
    var role: PairingRole?
    var credentialAccount: String?
    var participantID: String?
    var spaceID: String?
    var memberID: String?
    /// Stable relay device identity for this installation. Initial pairing
    /// uses the legacy member ID; peer-approved local recovery rotates this
    /// value to the replacement device ID. It is intentionally separate from
    /// `recoveryDeviceID`, which may later describe the peer being recovered.
    var localMomentDeviceID: String?
    var invitationID: String?
    var invitationExpiresAt: Date?
    var enrollmentID: String?
    var peerMemberID: String?
    var peerParticipantID: String?
    var peerAgreementPublicKey: String?
    var peerSigningPublicKey: String?
    var transcript: String?
    var transcriptHash: String?
    var verificationPhrase: String?
    var dailyBoundaryMinuteUTC: Int?
    /// Stable idempotency key for the operation represented by `phase`.
    var pendingClientRequestID: String?
    var pendingOperation: String?
    /// Enrollment challenge is persisted before the signed enrollment request
    /// so a timeout retry sends byte-for-byte identical canonical fields.
    var challengeID: String?
    var challengeValue: String?
    var challengeExpiresAtUnix: Int?
    /// ChaChaPoly uses a random nonce. Persist the exact envelope/signature
    /// before approval so a retry cannot produce a conflicting request hash.
    var pendingKeyEnvelope: String?
    var pendingApprovalSignature: String?
    var pendingCancelRevokesWholeSpace: Bool?
    /// A peer-approved device replacement keeps the space and room key while
    /// rotating only the missing peer's device credential. These fields never
    /// contain the room key or the one-time proof secret.
    var recoveryID: String?
    var recoveryExpiresAt: Date?
    var recoveryMembershipRevision: Int?
    var recoveryKeyEpoch: Int?
    var recoveryDeviceID: String?
    var recoveryPreviousTargetAgreementPublicKey: String?
    var recoveryPreviousTargetSigningPublicKey: String?
    var recoveryCandidateAgreementPublicKey: String?
    var recoveryCandidateSigningPublicKey: String?
    var recoveryTranscript: String?
    var recoveryTranscriptHash: String?
    var recoveryVerificationPhrase: String?
    var recoveryApprovalSubmittedAt: Date?
    var recoveryCompletedAt: Date?
    var recoveryWasLocalDeviceReplacement: Bool?
    /// True for a peer-approved additional iPhone. The historical
    /// `recoveryWasLocalDeviceReplacement` field remains for Build 41 decode
    /// and local device-ID normalization, but an additional device never
    /// revokes or becomes the participant's canonical naming key.
    var localDeviceIsAdditional: Bool?
    /// The participant key that existed before this additional device joined.
    /// Unlike the short-lived recovery fields, this survives later enrollment
    /// ceremonies sponsored by this device and keeps owner window-name
    /// signatures verifiable on every enrolled iPhone.
    var canonicalParticipantSigningPublicKey: String?
    /// Local-only consent evidence. It is never included in a server request.
    /// Existing paired installs without the current version fail closed when
    /// media synchronization is enabled and must explicitly consent again.
    var mediaSharingConsentVersion: Int?
    var mediaSharingConsentAcceptedAt: Date?
    var lastUpdatedAt: Date
    var lastError: String?

    /// Build 41 did not persist `localMomentDeviceID`. Its completed local
    /// recovery record is nevertheless transcript-bound, so it is a safe
    /// one-time source while the normalized value is being persisted.
    var resolvedLocalMomentDeviceID: String? {
        if let localMomentDeviceID { return localMomentDeviceID }
        if recoveryWasLocalDeviceReplacement == true { return recoveryDeviceID }
        return memberID
    }

    /// A Build 41 draft may still contain the initial legacy device ID. The
    /// device ID is deliberately outside moment AAD, so the replacement
    /// credential may finish that exact participant-bound draft. New drafts
    /// always use `resolvedLocalMomentDeviceID`.
    func acceptsPersistedMomentDeviceID(_ candidate: String) -> Bool {
        guard let resolvedLocalMomentDeviceID,
              let memberID,
              PairingValidation.isOpaqueIdentifier(candidate)
        else { return false }
        if candidate == resolvedLocalMomentDeviceID { return true }
        return resolvedLocalMomentDeviceID != memberID && candidate == memberID
    }

    static func unpaired(installationMarker: String) -> Self {
        Self(
            installationMarker: installationMarker,
            phase: .unpaired,
            lastUpdatedAt: .now
        )
    }

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              storageRevision == nil || storageRevision.map({ $0 >= 0 }) == true,
              UUID(uuidString: installationMarker) != nil
        else { throw PairingError.stateUnavailable }
        let allowedOperations: Set<String> = [
            "create", "enroll", "approve", "complete", "cancel",
            "recoveryCreate", "recoveryClaim", "recoveryApprove", "recoveryComplete"
        ]
        guard pendingOperation == nil || allowedOperations.contains(pendingOperation!),
              (pendingOperation == nil) == (pendingClientRequestID == nil),
              pendingClientRequestID == nil
                || pendingClientRequestID.flatMap(UUID.init(uuidString:)) != nil,
              pendingOperation == "cancel" || pendingCancelRevokesWholeSpace == nil
        else { throw PairingError.stateUnavailable }
        guard (mediaSharingConsentVersion == nil) == (mediaSharingConsentAcceptedAt == nil),
              mediaSharingConsentVersion == nil
                || mediaSharingConsentVersion.map({ (1...10_000).contains($0) }) == true
        else { throw PairingError.stateUnavailable }
        guard localMomentDeviceID == nil
                || localMomentDeviceID.map(PairingValidation.isOpaqueIdentifier) == true,
              canonicalParticipantSigningPublicKey == nil
                || canonicalParticipantSigningPublicKey
                    .flatMap({ Data(base64URLString: $0) })?.count == 32,
              localDeviceIsAdditional != true
                || canonicalParticipantSigningPublicKey != nil
        else { throw PairingError.stateUnavailable }

        switch phase {
        case .unpaired:
            guard credentialAccount == nil,
                  participantID == nil,
                  spaceID == nil,
                  memberID == nil,
                  localMomentDeviceID == nil,
                  recoveryID == nil
            else { throw PairingError.stateUnavailable }
        case .creatingInvitation, .joining:
            try validateLocalIdentity()
            guard pendingClientRequestID.flatMap(UUID.init(uuidString:)) != nil,
                  pendingOperation == (phase == .creatingInvitation ? "create" : "enroll")
            else {
                throw PairingError.stateUnavailable
            }
        case .awaitingInvitee:
            try validateLocalIdentity()
            try validateServerIdentity()
            guard invitationID.map(PairingValidation.isOpaqueIdentifier) == true,
                  invitationExpiresAt != nil,
                  dailyBoundaryMinuteUTC.map({ (0...1_439).contains($0) }) == true
            else { throw PairingError.stateUnavailable }
        case .claimingRecovery, .pendingRecoveryApproval, .recoveryAwaitingCompletion:
            try validateLocalIdentity()
            try validateServerIdentity()
            try validatePeerIdentity()
            try validateRecovery(requireDevice: true, requireTranscript: phase != .claimingRecovery)
            if phase == .claimingRecovery {
                guard pendingOperation == "recoveryClaim" else {
                    throw PairingError.stateUnavailable
                }
            } else if phase == .recoveryAwaitingCompletion {
                guard pendingOperation == "recoveryComplete" else {
                    throw PairingError.stateUnavailable
                }
            } else if pendingOperation != nil {
                throw PairingError.stateUnavailable
            }
        case .pendingApproval, .approvalRequired, .awaitingCompletion:
            try validateLocalIdentity()
            try validateServerIdentity()
            try validatePeerIdentity()
            try validatePairingCeremony()
        case .paired:
            try validateLocalIdentity()
            try validateServerIdentity()
            try validatePeerIdentity()
            if invitationID != nil || enrollmentID != nil {
                try validatePairingCeremony()
            } else if localDeviceIsAdditional == true {
                // Once an additional device has completed the peer-approved
                // ceremony, its exact device selector and preserved canonical
                // participant key are the durable local binding. The recovery
                // fields may later describe a new enrollment this device is
                // sponsoring, so they cannot remain its only pairing proof.
                guard let memberID,
                      let localMomentDeviceID,
                      localMomentDeviceID != memberID,
                      canonicalParticipantSigningPublicKey != nil
                else { throw PairingError.stateUnavailable }
            } else {
                guard recoveryCompletedAt != nil else {
                    throw PairingError.stateUnavailable
                }
                try validateRecovery(requireDevice: true, requireTranscript: true)
            }
            if recoveryID != nil, recoveryCompletedAt == nil {
                try validateRecovery(
                    requireDevice: recoveryCandidateAgreementPublicKey != nil,
                    requireTranscript: recoveryTranscript != nil
                )
            }
        case .failed:
            if credentialAccount != nil || participantID != nil {
                try validateLocalIdentity()
            }
        }
        var normalized = self
        normalized.localMomentDeviceID = resolvedLocalMomentDeviceID
        return normalized
    }

    private func validatePairingCeremony() throws {
        guard invitationID.map(PairingValidation.isOpaqueIdentifier) == true,
              enrollmentID.map(PairingValidation.isOpaqueIdentifier) == true,
                  let transcriptData = transcript.flatMap({ Data(base64URLString: $0) }),
                  let hashData = transcriptHash.flatMap({ Data(base64URLString: $0) }),
                  hashData.count == 32,
              verificationPhrase?.isEmpty == false,
              dailyBoundaryMinuteUTC.map({ (0...1_439).contains($0) }) == true
            else { throw PairingError.stateUnavailable }
        let calculatedHash = PairingCrypto.sha256(transcriptData)
        guard calculatedHash == hashData,
              verificationPhrase == PairingCrypto.verificationPhrase(for: calculatedHash)
        else { throw PairingError.stateUnavailable }
    }

    private func validateLocalIdentity() throws {
        guard credentialAccount.flatMap(UUID.init(uuidString:)) != nil,
              participantID.flatMap({ Data(base64URLString: $0) })?.count == 16
        else { throw PairingError.stateUnavailable }
    }

    private func validateServerIdentity() throws {
        guard spaceID.map(PairingValidation.isOpaqueIdentifier) == true,
              memberID.map(PairingValidation.isOpaqueIdentifier) == true,
              resolvedLocalMomentDeviceID.map(PairingValidation.isOpaqueIdentifier) == true
        else { throw PairingError.stateUnavailable }
    }

    private func validatePeerIdentity() throws {
        guard peerMemberID.map(PairingValidation.isOpaqueIdentifier) == true,
              let participant = peerParticipantID.flatMap({ Data(base64URLString: $0) }),
              participant.count == 16,
              let agreement = peerAgreementPublicKey.flatMap({ Data(base64URLString: $0) }),
              agreement.count == 32,
              let signing = peerSigningPublicKey.flatMap({ Data(base64URLString: $0) }),
              signing.count == 32
        else { throw PairingError.stateUnavailable }
        _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreement)
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: signing)
    }

    private func validateRecovery(requireDevice: Bool, requireTranscript: Bool) throws {
        guard recoveryID.map(PairingValidation.isOpaqueIdentifier) == true,
              recoveryExpiresAt != nil,
              recoveryMembershipRevision.map({ $0 > 0 }) == true,
              recoveryKeyEpoch.map({ $0 > 0 }) == true,
              let previousAgreement = recoveryPreviousTargetAgreementPublicKey
                .flatMap({ Data(base64URLString: $0) }),
              previousAgreement.count == 32,
              let previousSigning = recoveryPreviousTargetSigningPublicKey
                .flatMap({ Data(base64URLString: $0) }),
              previousSigning.count == 32
        else { throw PairingError.stateUnavailable }
        _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: previousAgreement)
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: previousSigning)
        if requireDevice {
            guard recoveryDeviceID.map(PairingValidation.isOpaqueIdentifier) == true,
                  let candidateAgreement = recoveryCandidateAgreementPublicKey
                    .flatMap({ Data(base64URLString: $0) }),
                  candidateAgreement.count == 32,
                  let candidateSigning = recoveryCandidateSigningPublicKey
                    .flatMap({ Data(base64URLString: $0) }),
                  candidateSigning.count == 32
            else { throw PairingError.stateUnavailable }
            _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: candidateAgreement)
            _ = try Curve25519.Signing.PublicKey(rawRepresentation: candidateSigning)
        }
        if requireTranscript {
            guard let transcriptData = recoveryTranscript.flatMap({ Data(base64URLString: $0) }),
                  let hashData = recoveryTranscriptHash.flatMap({ Data(base64URLString: $0) }),
                  hashData.count == 32,
                  recoveryVerificationPhrase?.isEmpty == false
            else { throw PairingError.stateUnavailable }
            let calculatedHash = PairingCrypto.sha256(transcriptData)
            guard calculatedHash == hashData,
                  recoveryVerificationPhrase == PairingCrypto.verificationPhrase(for: calculatedHash)
            else { throw PairingError.stateUnavailable }
        }
    }
}

/// All values in this type are secrets or are bound directly to the secret
/// material. The encoded representation may only be written to Keychain.
struct PairingCredential: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int = Self.schemaVersion
    var installationMarker: String
    var account: String
    var participantID: Data
    var agreementPrivateKey: Data
    var signingPrivateKey: Data
    var roomKey: Data?
    var enrollmentSecret: Data?
    /// Stable relay device identity used to select this exact signing key when
    /// a participant has more than one active iPhone. Missing means a Build 40
    /// legacy credential and deliberately uses the server's legacy-device
    /// fallback.
    var deviceID: String? = nil

    var participantIDString: String { participantID.base64URLEncodedString() }

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              UUID(uuidString: account) != nil,
              participantID.count == 16,
              agreementPrivateKey.count == 32,
              signingPrivateKey.count == 32,
              roomKey == nil || roomKey?.count == 32,
              enrollmentSecret == nil || enrollmentSecret?.count == 32,
              deviceID == nil || deviceID.map(PairingValidation.isOpaqueIdentifier) == true
        else {
            throw PairingError.malformedCredential
        }

        // Parsing also rejects invalid future key encodings even if lengths match.
        _ = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreementPrivateKey)
        _ = try Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivateKey)
        if let enrollmentSecret {
            _ = try Curve25519.Signing.PrivateKey(rawRepresentation: enrollmentSecret)
        }
        return self
    }
}

struct PairingInvitationCode: Equatable, Sendable {
    let invitationID: String
    let enrollmentSecret: Data

    init(invitationID: String, enrollmentSecret: Data) throws {
        guard Self.isSafeOpaqueIdentifier(invitationID), enrollmentSecret.count == 32 else {
            throw PairingError.invalidInvitationCode
        }
        self.invitationID = invitationID
        self.enrollmentSecret = enrollmentSecret
    }

    init(code: String) throws {
        let compact = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = compact.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0] == Substring(PairingProtocol.invitationPrefix),
              Self.isSafeOpaqueIdentifier(String(components[1])),
              let secret = Data(base64URLString: String(components[2])),
              secret.count == 32
        else {
            throw PairingError.invalidInvitationCode
        }
        invitationID = String(components[1])
        enrollmentSecret = secret
    }

    var code: String {
        "\(PairingProtocol.invitationPrefix).\(invitationID).\(enrollmentSecret.base64URLEncodedString())"
    }

    /// The raw enrollment secret is intentionally placed in the fragment. URL
    /// fragments are not sent in an HTTP request, though the chosen messaging
    /// service and anyone with the link can still see it.
    var invitationURL: URL? {
        URL(string: "nekowidget://pair/invite?id=\(invitationID)#\(enrollmentSecret.base64URLEncodedString())")
    }

    static func parse(url: URL) throws -> Self {
        guard url.scheme == "nekowidget",
              url.host == "pair",
              url.path == "/invite",
              let invitationID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "id" })?.value,
              let fragment = url.fragment,
              let secret = Data(base64URLString: fragment)
        else {
            throw PairingError.invalidInvitationCode
        }
        return try Self(invitationID: invitationID, enrollmentSecret: secret)
    }

    private static func isSafeOpaqueIdentifier(_ value: String) -> Bool {
        guard (8...128).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122)
                || $0 == 45
                || $0 == 95
        }
    }
}

/// A one-time capability created by the still-connected peer. The secret is
/// used only to prove possession of the recovery invitation; it never derives
/// or encrypts the room key.
struct PairingDeviceRecoveryCode: Equatable, Sendable {
    let recoveryID: String
    let proofSecret: Data

    init(recoveryID: String, proofSecret: Data) throws {
        guard PairingValidation.isOpaqueIdentifier(recoveryID), proofSecret.count == 32 else {
            throw PairingError.invalidDeviceRecoveryCode
        }
        _ = try Curve25519.Signing.PrivateKey(rawRepresentation: proofSecret)
        self.recoveryID = recoveryID
        self.proofSecret = proofSecret
    }

    init(code: String) throws {
        let compact = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = compact.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0] == Substring(PairingProtocol.deviceRecoveryPrefix),
              let secret = Data(base64URLString: String(components[2]))
        else { throw PairingError.invalidDeviceRecoveryCode }
        try self.init(recoveryID: String(components[1]), proofSecret: secret)
    }

    var code: String {
        "\(PairingProtocol.deviceRecoveryPrefix).\(recoveryID).\(proofSecret.base64URLEncodedString())"
    }

    var recoveryURL: URL? {
        URL(
            string: "nekowidget://pair/recover?id=\(recoveryID)#\(proofSecret.base64URLEncodedString())"
        )
    }

    static func parse(url: URL) throws -> Self {
        guard url.scheme == "nekowidget",
              url.host == "pair",
              url.path == "/recover",
              let recoveryID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "id" })?.value,
              let fragment = url.fragment,
              let secret = Data(base64URLString: fragment)
        else { throw PairingError.invalidDeviceRecoveryCode }
        return try Self(recoveryID: recoveryID, proofSecret: secret)
    }
}

struct PairingDeviceRecoveryIdentity: Codable, Equatable, Sendable {
    let memberID: String
    let participantID: String
    let role: String
    let agreementPublicKey: String
    let signingPublicKey: String
    let state: String

    enum CodingKeys: String, CodingKey {
        case memberID = "memberId"
        case participantID = "participantId"
        case role
        case agreementPublicKey
        case signingPublicKey
        case state
    }

    var pairingRole: PairingRole? {
        switch role {
        case "owner": return .inviter
        case "invitee": return .invitee
        default: return nil
        }
    }

    var memberIdentity: PairingMemberIdentity {
        PairingMemberIdentity(
            memberID: memberID,
            participantID: participantID,
            agreementPublicKey: agreementPublicKey,
            signingPublicKey: signingPublicKey
        )
    }

    func validated(allowedStates: Set<String>) throws -> Self {
        guard pairingRole != nil,
              allowedStates.contains(state)
        else { throw PairingError.invalidServerResponse }
        _ = try memberIdentity.validated()
        return self
    }
}

struct PairingDeviceRecoveryTranscript: Equatable, Sendable {
    let recoveryID: String
    let spaceID: String
    let dailyBoundaryMinuteUTC: Int
    let expiresAtUnix: Int
    let membershipRevision: Int
    let keyEpoch: Int
    let target: PairingDeviceRecoveryIdentity
    let peer: PairingDeviceRecoveryIdentity
    let clientRequestID: String
    let deviceID: String
    let agreementPublicKey: String
    let signingPublicKey: String

    func canonicalData() throws -> Data {
        guard PairingValidation.isOpaqueIdentifier(recoveryID),
              PairingValidation.isOpaqueIdentifier(spaceID),
              (0...1_439).contains(dailyBoundaryMinuteUTC),
              expiresAtUnix > 0,
              membershipRevision > 0,
              keyEpoch > 0,
              UUID(uuidString: clientRequestID) != nil,
              PairingValidation.isOpaqueIdentifier(deviceID),
              let agreement = Data(base64URLString: agreementPublicKey), agreement.count == 32,
              let signing = Data(base64URLString: signingPublicKey), signing.count == 32
        else { throw PairingError.invalidServerResponse }
        let target = try target.validated(allowedStates: ["active"])
        let peer = try peer.validated(allowedStates: ["active"])
        guard target.memberID != peer.memberID,
              target.participantID != peer.participantID,
              target.pairingRole != peer.pairingRole
        else { throw PairingError.invalidServerResponse }
        _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreement)
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: signing)
        return try PairingCanonicalEncoder.encode([
            "NW2.DEVICE-RECOVERY.CLAIM",
            "2",
            recoveryID,
            spaceID,
            String(dailyBoundaryMinuteUTC),
            String(expiresAtUnix),
            String(membershipRevision),
            String(keyEpoch),
            target.memberID,
            target.participantID,
            target.role,
            target.agreementPublicKey,
            target.signingPublicKey,
            peer.memberID,
            peer.participantID,
            peer.role,
            peer.agreementPublicKey,
            peer.signingPublicKey,
            clientRequestID.lowercased(),
            deviceID,
            agreementPublicKey,
            signingPublicKey
        ])
    }

    func hash() throws -> Data {
        PairingCrypto.sha256(try canonicalData())
    }
}

struct PairingMemberIdentity: Codable, Equatable, Sendable {
    let memberID: String
    let participantID: String
    let agreementPublicKey: String
    let signingPublicKey: String

    enum CodingKeys: String, CodingKey {
        case memberID = "id"
        case participantID = "participantId"
        case agreementPublicKey
        case signingPublicKey
    }

    func validated() throws -> Self {
        guard PairingValidation.isOpaqueIdentifier(memberID),
              let participant = Data(base64URLString: participantID), participant.count == 16,
              let agreement = Data(base64URLString: agreementPublicKey), agreement.count == 32,
              let signing = Data(base64URLString: signingPublicKey), signing.count == 32
        else {
            throw PairingError.invalidServerResponse
        }
        _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreement)
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: signing)
        return self
    }
}

struct PairingVerificationTranscript: Equatable, Sendable {
    let spaceID: String
    let invitationID: String
    let enrollmentID: String
    let dailyBoundaryMinuteUTC: Int
    let inviter: PairingMemberIdentity
    let invitee: PairingMemberIdentity

    func canonicalData() throws -> Data {
        guard PairingValidation.isOpaqueIdentifier(spaceID),
              PairingValidation.isOpaqueIdentifier(invitationID),
              PairingValidation.isOpaqueIdentifier(enrollmentID),
              (0...1_439).contains(dailyBoundaryMinuteUTC)
        else {
            throw PairingError.invalidServerResponse
        }
        let inviter = try inviter.validated()
        let invitee = try invitee.validated()
        return try PairingCanonicalEncoder.encode([
            "NW1.PAIRING",
            String(PairingProtocol.version),
            spaceID,
            invitationID,
            enrollmentID,
            String(dailyBoundaryMinuteUTC),
            inviter.memberID,
            inviter.participantID,
            inviter.agreementPublicKey,
            inviter.signingPublicKey,
            invitee.memberID,
            invitee.participantID,
            invitee.agreementPublicKey,
            invitee.signingPublicKey
        ])
    }

    func hash() throws -> Data {
        PairingCrypto.sha256(try canonicalData())
    }
}

enum PairingError: LocalizedError, Equatable {
    case apiNotConfigured
    case invalidInvitationCode
    case invalidDeviceRecoveryCode
    case keychainUnavailable(OSStatus)
    case keychainAccessGroupUnavailable
    case malformedCredential
    case installationChanged
    case invalidServerResponse
    case transcriptMismatch
    case unsupportedProtocol
    case requestRejected(status: Int, code: String?, message: String)
    case noPendingEnrollment
    case approvalNotConfirmed
    case invalidWindowDisplayName
    case stateUnavailable

    var errorDescription: String? {
        switch self {
        case .apiNotConfigured:
            return "このビルドには共有サーバーが設定されていません。"
        case .invalidInvitationCode:
            return "招待コードを確認できませんでした。コード全体を貼り付けてください。"
        case .invalidDeviceRecoveryCode:
            return "端末追加コードを確認できませんでした。NWR1.で始まるコード全体を貼り付けてください。"
        case .keychainUnavailable:
            return "共有鍵を安全に保存できませんでした。iPhoneを再起動して、もう一度お試しください。"
        case .keychainAccessGroupUnavailable:
            return "このアプリでは共有鍵を利用できません。アプリを更新して、もう一度お試しください。"
        case .malformedCredential:
            return "保存されている共有鍵を確認できません。再招待が必要です。"
        case .installationChanged:
            return "アプリの再インストールまたは機種変更を検出しました。安全のため再招待が必要です。"
        case .invalidServerResponse:
            return "共有サーバーからの応答を確認できませんでした。"
        case .transcriptMismatch:
            return "相手の確認情報が一致しません。承認せず、招待をやり直してください。"
        case .unsupportedProtocol:
            return "この招待は現在のアプリでは利用できません。アプリを更新してください。"
        case let .requestRejected(status, code, _):
            switch code {
            case "enrollment_expired":
                return "招待の期限が切れました。新しい招待コードが必要です。"
            case "invitation_unavailable", "enrollment_unavailable":
                return "この招待は利用できません。新しい招待コードが必要です。"
            case "pairing_cancelled", "sharing_revoked":
                return "このまどの共有は終了しました。もう一度招待してください。"
            case "invalid_authentication":
                return "共有の認証を一時的に確認できませんでした。まどは解除せず、時間をおいてもう一度お試しください。"
            case "invalid_enrollment_proof", "invitation_not_found":
                return "招待コードを確認できませんでした。新しいコードを相手に送ってもらってください。"
            case "invalid_recovery_proof", "invalid_recovery_signature",
                 "device_recovery_not_found", "recovery_already_claimed":
                return "端末追加コードを確認できませんでした。接続済みの相手から新しいコードを受け取ってください。"
            case "device_recovery_expired", "device_recovery_unavailable", "recovery_unavailable":
                return "端末追加コードの期限が切れました。接続済みの相手に新しいコードを作ってもらってください。"
            case "recovery_already_pending":
                return "以前の端末追加コードがまだ有効です。期限が切れてから、新しいコードを作ってください。"
            case "device_recovery_conflict", "recovery_conflict", "invalid_recovery_state",
                 "recovery_target_unavailable", "membership_changed", "key_epoch_changed":
                return "まどの状態が変わったため端末追加を停止しました。現在の共有は解除せず、状態を確認してください。"
            case "invalid_pairing_state":
                return "まどの状態が変わりました。状態を確認して、もう一度お試しください。"
            case "rate_limited":
                return "操作が続いたため、少し待ってからもう一度お試しください。"
            default:
                if status == 429 {
                    return "操作が続いたため、少し待ってからもう一度お試しください。"
                }
                if status >= 500 {
                    return "共有サーバーが一時的に利用できません。時間をおいて、もう一度お試しください。"
                }
                return "共有の処理を完了できませんでした。状態を確認して、もう一度お試しください。"
            }
        case .noPendingEnrollment:
            return "承認待ちの相手はまだいません。"
        case .approvalNotConfirmed:
            return "両方の端末で確認フレーズが同じことを確かめてください。"
        case .invalidWindowDisplayName:
            return "まどの名前は64バイト以内で、改行なしにしてください。"
        case .stateUnavailable:
            return "共有の状態を読み込めませんでした。"
        }
    }
}

enum PairingCrypto {
    static func makeCredential(
        installationMarker: String,
        includesInvitationSecret: Bool,
        includesRoomKey: Bool
    ) -> PairingCredential {
        let agreementKey = Curve25519.KeyAgreement.PrivateKey()
        let signingKey = Curve25519.Signing.PrivateKey()
        return PairingCredential(
            installationMarker: installationMarker,
            account: UUID().uuidString,
            participantID: randomData(count: 16),
            agreementPrivateKey: agreementKey.rawRepresentation,
            signingPrivateKey: signingKey.rawRepresentation,
            roomKey: includesRoomKey ? randomData(count: 32) : nil,
            enrollmentSecret: includesInvitationSecret ? randomData(count: 32) : nil
        )
    }

    static func agreementPublicKey(for credential: PairingCredential) throws -> Data {
        try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: credential.validated().agreementPrivateKey
        ).publicKey.rawRepresentation
    }

    static func signingPublicKey(for credential: PairingCredential) throws -> Data {
        try Curve25519.Signing.PrivateKey(
            rawRepresentation: credential.validated().signingPrivateKey
        ).publicKey.rawRepresentation
    }

    static func invitationProofPublicKey(for credential: PairingCredential) throws -> Data {
        guard let secret = try credential.validated().enrollmentSecret else {
            throw PairingError.malformedCredential
        }
        return try Curve25519.Signing.PrivateKey(
            rawRepresentation: secret
        ).publicKey.rawRepresentation
    }

    static func signInvitationProof(_ data: Data, credential: PairingCredential) throws -> Data {
        guard let secret = try credential.validated().enrollmentSecret else {
            throw PairingError.malformedCredential
        }
        return try Curve25519.Signing.PrivateKey(
            rawRepresentation: secret
        ).signature(for: data)
    }

    static func makeDeviceRecoveryProofSecret() -> Data {
        Curve25519.Signing.PrivateKey().rawRepresentation
    }

    static func deviceRecoveryProofPublicKey(for secret: Data) throws -> Data {
        guard secret.count == 32 else { throw PairingError.malformedCredential }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
            .publicKey.rawRepresentation
    }

    static func signDeviceRecoveryProof(_ data: Data, secret: Data) throws -> Data {
        guard secret.count == 32 else { throw PairingError.malformedCredential }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
            .signature(for: data)
    }

    static func sign(_ data: Data, credential: PairingCredential) throws -> Data {
        try Curve25519.Signing.PrivateKey(
            rawRepresentation: credential.validated().signingPrivateKey
        ).signature(for: data)
    }

    static func verifySignature(
        _ signature: Data,
        for data: Data,
        publicKey: Data
    ) throws -> Bool {
        guard signature.count == 64, publicKey.count == 32 else {
            throw PairingError.invalidServerResponse
        }
        return try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
            .isValidSignature(signature, for: data)
    }

    static func approvalTranscript(
        transcriptHash: String,
        envelopeAlgorithm: String,
        keyEnvelope: String
    ) throws -> Data {
        guard Data(base64URLString: transcriptHash)?.count == 32,
              envelopeAlgorithm == PairingProtocol.roomKeyEnvelopeAlgorithm,
              Data(base64URLString: keyEnvelope)?.count == 60
        else { throw PairingError.invalidServerResponse }
        return try PairingCanonicalEncoder.encode([
            "NW1.APPROVE",
            String(PairingProtocol.version),
            transcriptHash,
            envelopeAlgorithm,
            keyEnvelope
        ])
    }

    static func deviceRecoveryApprovalTranscript(
        recoveryID: String,
        spaceID: String,
        targetMemberID: String,
        deviceID: String,
        membershipRevision: Int,
        keyEpoch: Int,
        transcriptHash: String,
        envelopeAlgorithm: String,
        keyEnvelope: String
    ) throws -> Data {
        guard PairingValidation.isOpaqueIdentifier(recoveryID),
              PairingValidation.isOpaqueIdentifier(spaceID),
              PairingValidation.isOpaqueIdentifier(targetMemberID),
              PairingValidation.isOpaqueIdentifier(deviceID),
              membershipRevision > 0,
              keyEpoch > 0,
              Data(base64URLString: transcriptHash)?.count == 32,
              envelopeAlgorithm == PairingProtocol.roomKeyEnvelopeAlgorithm,
              Data(base64URLString: keyEnvelope)?.count == 60
        else { throw PairingError.invalidServerResponse }
        return try PairingCanonicalEncoder.encode([
            "NW2.DEVICE-RECOVERY.APPROVE",
            "2",
            recoveryID,
            spaceID,
            targetMemberID,
            deviceID,
            String(membershipRevision),
            String(keyEpoch),
            transcriptHash,
            envelopeAlgorithm,
            keyEnvelope
        ])
    }

    static func deviceRecoverySignedRequestTranscript(
        recoveryID: String,
        timestamp: Int,
        nonce: String,
        method: String,
        path: String,
        bodySHA256: String
    ) throws -> Data {
        guard PairingValidation.isOpaqueIdentifier(recoveryID),
              timestamp > 0,
              Data(base64URLString: nonce)?.count == 16,
              !method.isEmpty,
              path.hasPrefix("/v2/device-recoveries/"),
              Data(base64URLString: bodySHA256)?.count == 32
        else { throw PairingError.invalidServerResponse }
        return try PairingCanonicalEncoder.encode([
            "NW2.DEVICE-RECOVERY.REQUEST",
            "2",
            recoveryID,
            String(timestamp),
            nonce,
            method.uppercased(),
            path,
            bodySHA256
        ])
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func verifyTranscript(_ transcript: Data, expectedHash: String) throws -> Data {
        let calculated = sha256(transcript)
        guard calculated.base64URLEncodedString() == expectedHash else {
            throw PairingError.transcriptMismatch
        }
        return calculated
    }

    static func verificationPhrase(for transcriptHash: Data) -> String {
        // Twelve independently selected words expose 60 comparison bits. This
        // makes transcript grinding impractical while keeping spoken comparison
        // possible for two people pairing in person or over a call.
        let words = [
            "あさ", "あめ", "いと", "うみ", "えき", "おと", "かぎ", "かぜ",
            "きり", "くも", "こえ", "さくら", "しずく", "すず", "そら", "たね",
            "つき", "てらす", "とり", "なみ", "にじ", "ねこ", "のはら", "はな",
            "ひかり", "ふね", "ほし", "まど", "みち", "もり", "ゆき", "よる"
        ]
        var indices: [Int] = []
        var accumulator: UInt64 = 0
        var bitCount = 0
        for byte in transcriptHash {
            accumulator = (accumulator << 8) | UInt64(byte)
            bitCount += 8
            while bitCount >= 5, indices.count < 12 {
                bitCount -= 5
                indices.append(Int((accumulator >> UInt64(bitCount)) & 0x1f))
            }
            if indices.count == 12 { break }
            if bitCount == 0 { accumulator = 0 }
            else { accumulator &= (UInt64(1) << UInt64(bitCount)) - 1 }
        }
        return indices.map { words[$0] }.joined(separator: "・")
    }

    static func makeRoomKeyEnvelope(
        roomKey: Data,
        peerAgreementPublicKey: Data,
        transcript: Data,
        transcriptHash: Data,
        credential: PairingCredential
    ) throws -> Data {
        guard roomKey.count == 32, peerAgreementPublicKey.count == 32 else {
            throw PairingError.malformedCredential
        }
        guard sha256(transcript) == transcriptHash else {
            throw PairingError.transcriptMismatch
        }
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: credential.validated().agreementPrivateKey
        )
        let peerKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: peerAgreementPublicKey
        )
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        let wrappingKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcriptHash,
            sharedInfo: Data("NW1.ROOM.KEY.WRAP".utf8),
            outputByteCount: 32
        )
        let box = try ChaChaPoly.seal(
            roomKey,
            using: wrappingKey,
            authenticating: transcript
        )
        return box.combined
    }

    static func openRoomKeyEnvelope(
        _ envelope: Data,
        peerAgreementPublicKey: Data,
        transcript: Data,
        transcriptHash: Data,
        credential: PairingCredential
    ) throws -> Data {
        guard envelope.count == 60, peerAgreementPublicKey.count == 32 else {
            throw PairingError.invalidServerResponse
        }
        guard sha256(transcript) == transcriptHash else {
            throw PairingError.transcriptMismatch
        }
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: credential.validated().agreementPrivateKey
        )
        let peerKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: peerAgreementPublicKey
        )
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        let wrappingKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcriptHash,
            sharedInfo: Data("NW1.ROOM.KEY.WRAP".utf8),
            outputByteCount: 32
        )
        let roomKey = try ChaChaPoly.open(
            ChaChaPoly.SealedBox(combined: envelope),
            using: wrappingKey,
            authenticating: transcript
        )
        guard roomKey.count == 32 else { throw PairingError.invalidServerResponse }
        return roomKey
    }

    static func makeDeviceRecoveryRoomKeyEnvelope(
        roomKey: Data,
        peerAgreementPublicKey: Data,
        transcript: Data,
        transcriptHash: Data,
        credential: PairingCredential
    ) throws -> Data {
        guard roomKey.count == 32, peerAgreementPublicKey.count == 32 else {
            throw PairingError.malformedCredential
        }
        guard sha256(transcript) == transcriptHash else {
            throw PairingError.transcriptMismatch
        }
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: credential.validated().agreementPrivateKey
        )
        let peerKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: peerAgreementPublicKey
        )
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        let wrappingKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcriptHash,
            sharedInfo: Data("NW2.DEVICE-RECOVERY.ROOM.KEY.WRAP".utf8),
            outputByteCount: 32
        )
        return try ChaChaPoly.seal(
            roomKey,
            using: wrappingKey,
            authenticating: transcript
        ).combined
    }

    static func openDeviceRecoveryRoomKeyEnvelope(
        _ envelope: Data,
        peerAgreementPublicKey: Data,
        transcript: Data,
        transcriptHash: Data,
        credential: PairingCredential
    ) throws -> Data {
        guard envelope.count == 60, peerAgreementPublicKey.count == 32 else {
            throw PairingError.invalidServerResponse
        }
        guard sha256(transcript) == transcriptHash else {
            throw PairingError.transcriptMismatch
        }
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: credential.validated().agreementPrivateKey
        )
        let peerKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: peerAgreementPublicKey
        )
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        let wrappingKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcriptHash,
            sharedInfo: Data("NW2.DEVICE-RECOVERY.ROOM.KEY.WRAP".utf8),
            outputByteCount: 32
        )
        let roomKey = try ChaChaPoly.open(
            ChaChaPoly.SealedBox(combined: envelope),
            using: wrappingKey,
            authenticating: transcript
        )
        guard roomKey.count == 32 else { throw PairingError.invalidServerResponse }
        return roomKey
    }

    static func randomData(count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }
}

enum PairingValidation {
    static func isOpaqueIdentifier(_ value: String) -> Bool {
        guard (8...128).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122)
                || $0 == 45
                || $0 == 95
        }
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLString: String) {
        guard base64URLString.utf8.allSatisfy({
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122)
                || $0 == 45
                || $0 == 95
        }) else { return nil }
        var value = base64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        value.append(String(repeating: "=", count: (4 - value.count % 4) % 4))
        guard let decoded = Data(base64Encoded: value),
              decoded.base64URLEncodedString() == base64URLString
        else { return nil }
        self = decoded
    }
}

/// Canonical cross-platform encoder used by every signed pairing transcript.
/// Each UTF-8 value is prefixed with an unsigned UInt16 big-endian byte length.
/// No JSON normalization, delimiter escaping, locale, or newline is involved.
enum PairingCanonicalEncoder {
    static func encode(_ fields: [String]) throws -> Data {
        var result = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            guard bytes.count <= Int(UInt16.max) else {
                throw PairingError.invalidServerResponse
            }
            var length = UInt16(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(bytes)
        }
        return result
    }
}
