import Foundation

enum GroupAPIModel {
    struct ListInput: Encodable { let after: String?; let limit = 50
        enum CodingKeys: String, CodingKey { case after, limit }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if let after { try c.encode(after, forKey: .after) } else { try c.encodeNil(forKey: .after) }
            try c.encode(limit, forKey: .limit)
        }
    }
    struct WindowItem: Decodable {
        let windowID: String
        // Older relays may only return the ID. Incomplete version information
        // always takes the full detail/roster/member verification path.
        let revision: Int?; let keyEpoch: Int?; let rotationRequired: Bool?
        let myParticipantID: String?; let myRole: GroupRole?; let encryptedName: Data?
        let deliveryStatus: GroupDeliveryStatus?; let deliveryReason: GroupDeliveryReason?; let ownerParticipantID: String?
    }
    struct Page<T: Decodable>: Decodable { let items: [T]; let next: String?; let revision: Int? }
    struct WindowReply: Decodable {
        struct Metadata: Decodable {
            let windowID: String; let revision: Int; let keyEpoch: Int; let rotationRequired: Bool
            let encryptedName: Data; let nameKeyEpoch: Int; let nameRosterRevision: Int
            let nameRevision: Int?; let nameProof: WindowNameProof?
            let deliveryStatus: GroupDeliveryStatus?; let deliveryReason: GroupDeliveryReason?; let ownerParticipantID: String?
        }
        let window: Metadata; let roster: SignedGroupRoster; let rosterHash: Data
    }
    struct WindowNameProof: Decodable {
        let nameRevision: Int; let signerDeviceID: String; let operationID: String; let signature: Data
    }
    struct RenameWindowInput: Codable {
        let operationID: String; let expectedRevision: Int; let keyEpoch: Int
        let expectedNameRevision: Int; let encryptedName: Data; let ownerSignature: Data
    }
    struct CloseWindowInput: Codable {
        let operationID: String; let expectedRevision: Int; let keyEpoch: Int; let ownerSignature: Data
    }
    struct RenameWindowReply: Decodable {
        let operationID: String; let windowID: String; let revision: Int; let keyEpoch: Int; let nameRevision: Int
    }
    struct CloseWindowReply: Decodable {
        let operationID: String; let windowID: String; let revision: Int; let keyEpoch: Int; let state: String
    }
    struct MemberRow: Decodable {
        let id: String; let personID: String; let role: GroupRole; let state: GroupMemberState
        let joinedRevision: Int; let encryptedDisplayName: Data
    }
    struct RosterInput: Encodable { let afterRevision: Int; let limit = 50 }
    struct RosterReply: Decodable { let items: [SignedGroupRoster]; let nextRevision: Int?; let revision: Int }
    struct KeyReply: Decodable { let roster: SignedGroupRoster; let envelopeForThisDevice: GroupKeyEnvelope }
    struct IdentityChallengeInput: Encodable { let purpose = "register"; let signingPublicKey: Data; let hpkePublicKey: Data }
    struct Challenge: Decodable { let challengeID: String; let challenge: String; let expiresAt: Int }
    struct IdentityInput: Encodable {
        let operationID: String; let challengeID: String; let personPublicKey: Data; let signingPublicKey: Data
        let hpkePublicKey: Data; let personSignature: Data; let deviceSignature: Data
    }
    struct IdentityReply: Decodable { let personID: String; let deviceID: String; let state: String }
    struct CreateInput: Codable {
        let operationID: String; let packet: SignedGroupRoster; let envelopes: [GroupKeyEnvelope]
        let encryptedName: Data; let encryptedMemberNames: [String: Data]
    }
    struct Mutation: Codable { let operationID: String; let expectedRevision: Int }
    struct MutationReply: Decodable { let operationID: String; let windowID: String?; let revision: Int?; let keyEpoch: Int? }
    struct BillingConnection: Codable { let operationID: String; let billingAccountID: String; let personID: String; let deviceID: String }
    struct BillingConnectionReply: Decodable { let operationID: String; let personID: String; let state: String }
    struct InviteInput: Codable { let operationID: String; let expectedRevision: Int; let proofPublicKey: Data }
    struct InvitationStatus: Decodable { let invitationID: String; let proofPublicKey: Data; let expiresAt: Int; let revokedAt: Int?; let serverNow: Int }
    struct PushRemoval: Encodable { let operationID: String }
    struct PushInput: Encodable { let operationID: String; let token: Data; let environment: String }
    struct InviteReply: Decodable { let operationID: String; let invitationID: String; let expiresAt: Int; let revision: Int }
    struct InvitationInput: Encodable { let invitationID: String }
    struct JoinChallenge: Decodable {
        let challengeID: String; let challenge: String; let expiresAt: Int
        let ownerPersonID: String; let ownerIdentityPublicKey: Data; let ownerDevices: [GroupRosterDevice]
    }
    struct JoinInput: Codable {
        let operationID: String; let invitationID: String; let challengeID: String; let personID: String; let candidateDeviceID: String
        let encryptedDisplayName: Data; let personAuthorization: Data; let inviteProof: Data; let deviceSignature: Data
    }
    struct JoinStatusInput: Encodable { let requestID: String }
    struct JoinReply: Decodable {
        let requestID: String; let windowID: String; let invitationID: String; let personID: String; let candidateDeviceID: String
        let state: GroupRequestState; let expiresAt: Int; let resultRevision: Int?
        let admissionPaused: Bool?
    }
    struct AdmissionProof: Codable {
        let operationID: String; let challengeID: String; let challenge: String
        let challengeExpiresAt: Int; let inviteProof: Data; let deviceSignature: Data
    }
    struct PendingJoin: Codable {
        let id: String; let invitationID: String; let personID: String; let candidateDeviceID: String
        let state: GroupRequestState; let expiresAt: Int; let encryptedDisplayName: Data; let personAuthorization: Data
        let signingPublicKey: Data; let hpkePublicKey: Data; let identityPublicKey: Data
        var admissionPaused: Bool? = nil
        var admissionProof: AdmissionProof? = nil
    }
    struct Transition: Codable {
        let operationID: String; let expectedRevision: Int; let kind: String; let targetID: String
        let packet: SignedGroupRoster; let envelopes: [GroupKeyEnvelope]
        let encryptedName: Data; let encryptedMemberNames: [String: Data]; let personSponsorSignature: Data?
    }
    struct CancelInput: Codable { let operationID: String }
    struct LeaveInput: Codable { let operationID: String; let expectedRevision: Int; let selfSignature: Data }
    struct CaptionDescriptor: Codable, Sendable {
        let ciphertextSize: Int; let ciphertextSHA256: Data; let senderSignature: Data
    }
    struct PhotoRow: Codable, Sendable {
        let id: String; let clientMomentID: String; let senderParticipantID: String; let senderDeviceID: String
        let keyEpoch: Int; let rosterRevision: Int; let rosterHash: Data; let ciphertextSize: Int
        let ciphertextSHA256: Data; let senderSignature: Data; let createdAt: Int; let accessExpiresAt: Int; let kind: String
        let hearts: [HeartRow]
        var caption: CaptionDescriptor? = nil
    }
    struct HeartRow: Codable, Sendable {
        let reactorParticipantID: String; let reactorDeviceID: String; let active: Bool; let updatedAt: Int
        let keyEpoch: Int; let rosterRevision: Int; let rosterHash: Data; let operationID: String; let reactorSignature: Data
    }
    struct HeartInput: Codable {
        let operationID: String; let active: Bool; let keyEpoch: Int; let rosterRevision: Int; let reactorSignature: Data
    }
    struct HeartReply: Decodable {
        let momentID: String
        let moment: PhotoRow?
    }
    struct ReservePhoto: Codable {
        let operationID: String; let clientMomentID: String; let keyEpoch: Int; let rosterRevision: Int
        let ciphertextSize: Int; let ciphertextSHA256: Data; let senderSignature: Data; let kind: String
        var caption: CaptionDescriptor? = nil
    }
    struct PhotoReservation: Decodable { let operationID: String; let momentID: String; let uploadExpiresAt: Int }
    struct CommitPhoto: Codable { let operationID: String; let expectedRevision: Int; let keyEpoch: Int; let ciphertextSHA256: Data }
    struct AckPhoto: Codable { let operationID: String; let ciphertextSHA256: Data }
    struct OnePhoto: Decodable { let moment: PhotoRow }
}

struct GroupJoinAttempt: Codable, Sendable {
    let invitationID: String; let windowID: String; let personID: String; let deviceID: String
    let operationID: UUID; let displayName: String
}
struct GroupLocalJoin: Codable, Sendable { let windowID: String; var request: GroupJoinRequest }
struct GroupLocalBillingConnection: Codable, Sendable {
    let operationID: UUID; let accountID: String; let personID: String; let deviceID: String; var connected: Bool
}
struct GroupLocalInvitation: Codable, Sendable {
    let windowID: String; let operationID: UUID; let privateKey: Data
    var invitationID: String?; var expiresAt: Date?
}
