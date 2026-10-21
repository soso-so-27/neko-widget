import Foundation

// UI-facing draft contract. No network, cryptography, persistence, or billing authority.
// Names here are display values resolved by the production adapter after verification.
// The wire protocol in the companion specification uses encrypted names instead.

enum GroupRole: String, Codable, Sendable { case owner, member }
enum GroupMemberState: String, Codable, Sendable { case pending, active, left, removed }
enum GroupRequestState: String, Codable, Sendable {
    case pending, approved, rejected, cancelled, expired
}
enum GroupConnectionState: String, Codable, Sendable { case active, rotationRequired, closed }
// Server-derived delivery policy is separate from membership. A paused window
// still supports reading, hearts and member management. nil means unconfirmed,
// never a locally calculated trial or an assertion of paid access.
enum GroupDeliveryStatus: String, Codable, Sendable { case active, paused }
enum GroupDeliveryReason: String, Codable, Sendable { case ownerPlus = "owner_plus", ownerPlusRequired = "owner_plus_required" }
enum GroupSubscriptionError: Error, Equatable, Sendable { case ownerPlusRequired, windowPaused }

struct GroupDevice: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let isThisDevice: Bool
}

struct GroupMember: Identifiable, Codable, Equatable, Sendable {
    let id: String                         // participantId, not personId/deviceId
    let personID: String
    let displayName: String
    let role: GroupRole
    var state: GroupMemberState
    var devices: [GroupDevice]
}

struct GroupWindow: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    var revision: Int
    var keyEpoch: Int
    let myParticipantID: String
    let myRole: GroupRole
    var state: GroupConnectionState
    var members: [GroupMember]
    var deliveryStatus: GroupDeliveryStatus? = nil
    var deliveryReason: GroupDeliveryReason? = nil
    var ownerParticipantID: String? = nil

    var activeMembers: [GroupMember] { members.filter { $0.state == .active } }
    var memberCount: Int { activeMembers.count }
    var deviceCount: Int { activeMembers.reduce(0) { $0 + $1.devices.count } }
    var canManage: Bool { myRole == .owner && state != .closed }
}

struct GroupInvitation: Identifiable, Equatable, Sendable {
    let id: String
    let windowID: String
    let expiresAt: Date
    var revoked: Bool
    // Fixture deliberately has no usable URL/secret. Production adapter creates a secret-bearing
    // share item on explicit user action; never encode a real invitation into ordinary UI state.
    let shareText: String
}

struct GroupJoinRequest: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let invitationID: String
    let personID: String
    let candidateDeviceID: String
    let displayName: String
    let verificationPhrase: String
    let expiresAt: Date
    var state: GroupRequestState
}

struct GroupHeart: Identifiable, Codable, Equatable, Sendable {
    var id: String { participantID }
    let participantID: String
    let displayName: String
    var active: Bool
    let updatedAt: Date
}

struct GroupPhoto: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let windowID: String
    let senderParticipantID: String
    let senderDisplayName: String
    let createdAt: Date
    // UI fixture asset name, never a real photo path or signed download URL.
    let fixtureAssetName: String?
    var hearts: [GroupHeart]
}

struct GroupOperation: Equatable, Sendable {
    let id: UUID
    let expectedRevision: Int
    init(id: UUID = UUID(), expectedRevision: Int) {
        self.id = id
        self.expectedRevision = expectedRevision
    }
}

enum GroupClientError: Error, Equatable, Sendable {
    case offline, unavailable, authenticationRequired, notMember, ownerRequired
    case staleRevision(current: Int), staleEpoch, rotationPending
    case memberLimit, deviceLimit, totalWindowLimit, ownedWindowLimit
    case invitationExpired, invitationRevoked, requestNotPending
    case cannotRemoveOwner, ownerCannotLeave, invalidResponse
    case idempotencyConflict
}

// Methods receive intent, never a room key. The production adapter is responsible for
// signing, verifying the complete roster, creating envelopes, CAS, and durable retries.
protocol GroupWindowClient: Sendable {
    func windows() async throws -> [GroupWindow]
    func window(id: String) async throws -> GroupWindow
    func createWindow(name: String, operationID: UUID) async throws -> GroupWindow
    /// Explicit creator name; adapters must encrypt it instead of substituting
    /// a local-only label such as "自分" for the other members to see.
    func createWindow(name: String, ownerDisplayName: String, operationID: UUID) async throws -> GroupWindow
    func createInvitation(windowID: String, operation: GroupOperation) async throws -> GroupInvitation
    func revokeInvitation(id: String, windowID: String, operation: GroupOperation) async throws
    func apply(invitationID: String, displayName: String, operationID: UUID) async throws -> GroupJoinRequest
    func joinStatus(requestID: String) async throws -> GroupJoinRequest
    func pendingRequests(windowID: String) async throws -> [GroupJoinRequest]
    func approve(requestID: String, windowID: String, operation: GroupOperation) async throws -> GroupWindow
    func reject(requestID: String, windowID: String, operation: GroupOperation) async throws
    func cancel(requestID: String, operationID: UUID) async throws
    func addDevice(participantID: String, windowID: String, displayName: String,
                   operation: GroupOperation) async throws -> GroupWindow
    func removeMember(participantID: String, windowID: String,
                      operation: GroupOperation) async throws -> GroupWindow
    func leave(windowID: String, operation: GroupOperation) async throws
    /// Renews the window's key after someone left or was removed. Only the
    /// creator can; until then the relay refuses new photos and hearts.
    func rotate(windowID: String, operation: GroupOperation) async throws -> GroupWindow
    func photos(windowID: String) async throws -> [GroupPhoto]
    func setHeart(photoID: String, windowID: String, active: Bool,
                  operationID: UUID) async throws -> GroupPhoto
}

extension GroupWindowClient {
    // Legacy/preview adapters fail explicitly until they support this intent;
    // silently ignoring a supplied name would recreate the original problem.
    func createWindow(name: String, ownerDisplayName: String, operationID: UUID) async throws -> GroupWindow {
        throw GroupClientError.unavailable
    }
}

// Main app writes this derived snapshot only AFTER authenticating membership and photo.
// Widget reads it; this value contains no membership authority, room keys, or API credentials.
struct GroupWidgetSnapshot: Codable, Equatable, Sendable {
    let windowID: String
    let revision: Int
    let photoID: String
    let senderDisplayName: String
    let localJPEGPath: String
    let capturedAt: Date
    let cacheGeneration: String
}
