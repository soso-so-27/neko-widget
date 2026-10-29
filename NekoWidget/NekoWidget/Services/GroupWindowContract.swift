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
    // nil means this relay has not exposed the management capability yet.
    var nameRevision: Int? = nil

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
    // Optional so requests saved before operator admission controls still decode.
    var admissionPaused: Bool? = nil
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
    case invitationExpired, invitationRevoked, invitationPaused, requestNotPending
    case cannotRemoveOwner, ownerCannotLeave, invalidResponse
    case idempotencyConflict
}

enum GroupWindowManagementError: Error, Equatable, Sendable {
    case invalidName, unavailable, staleNameRevision, closed
    case reconciliationRequired, stateRefreshRequired
}

struct GroupWindowClosure: Equatable, Sendable {
    let windowID: String
    let operationID: UUID
    let revision: Int
    let keyEpoch: Int
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
    func renameWindow(windowID: String, name: String, expectedNameRevision: Int,
                      operation: GroupOperation) async throws -> GroupWindow
    func closeWindow(windowID: String, operation: GroupOperation) async throws -> GroupWindowClosure
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
    func renameWindow(windowID: String, name: String, expectedNameRevision: Int,
                      operation: GroupOperation) async throws -> GroupWindow {
        throw GroupWindowManagementError.unavailable
    }
    func closeWindow(windowID: String, operation: GroupOperation) async throws -> GroupWindowClosure {
        throw GroupWindowManagementError.unavailable
    }
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

// A caller-scoped, in-memory diagnostic. Only the internal UI creates one.
// TaskLocal prevents unrelated actor calls from being counted in this load.
// The lock protects inherited tasks (e.g. identity registration); no IDs, URLs,
// names, response bodies, credentials or error descriptions are retained.
enum GroupListMeasurement {
    @TaskLocal static var current: GroupListTrace?
}

final class GroupListTrace: @unchecked Sendable {
    struct Request: Sendable {
        let kind: String
        let seconds: TimeInterval
        let outcome: String
    }
    struct Snapshot: Sendable {
        let requests: [Request]
        let cache: [String]
        let storageSeconds: TimeInterval
        let cacheSeconds: TimeInterval
        let detailLocalSeconds: TimeInterval
        let entryWaitSeconds: TimeInterval
        var networkSeconds: TimeInterval { requests.reduce(0) { $0 + $1.seconds } }
        func text(total: TimeInterval) -> String {
            let calls = requests.prefix(20).enumerated().map { index, request in
                String(format: "%d. %@ %.3f秒 %@", index + 1, request.kind, request.seconds, request.outcome)
            }.joined(separator: " / ")
            let remainder = requests.count > 20 ? "（ほか\(requests.count - 20)回）" : ""
            let outcomes = cache.isEmpty ? "未判定（対象なし・途中終了など）" : cache.joined(separator: " / ")
            return String(format: "通信 %d回・計 %.3f秒（受信・処理再開待ちを含む）", requests.count, networkSeconds)
                + (calls.isEmpty ? "" : "\n" + calls + remainder)
                + "\nキャッシュ: " + outcomes
                + String(format: "\n通信以外 %.3f秒 / 開始待ち %.3f秒 / 鍵読込 %.3f秒 / キャッシュ照合 %.3f秒",
                         max(0, total - networkSeconds), entryWaitSeconds, storageSeconds, cacheSeconds)
                + String(format: "\n詳細処理（署名検証・復号など、通信除く） %.3f秒", detailLocalSeconds)
                + "\n内訳は通信以外の内数。照合・詳細処理には鍵読込を含みます。"
        }
    }
    private let lock = NSLock()
    private let started = ProcessInfo.processInfo.systemUptime
    private var requests: [Request] = []
    private var cache: [String] = []
    private var storageSeconds: TimeInterval = 0
    private var cacheSeconds: TimeInterval = 0
    private var detailLocalSeconds: TimeInterval = 0
    private var entryWaitSeconds: TimeInterval = 0

    func enteredClient() {
        lock.lock(); defer { lock.unlock() }
        entryWaitSeconds = ProcessInfo.processInfo.systemUptime - started
    }
    func recordRequest(path: String, seconds: TimeInterval, outcome: String) {
        let kind: String
        if path == "/v3/group-windows/list" { kind = "一覧" }
        else if path.hasSuffix("/members/list") { kind = "メンバー" }
        else if path.hasSuffix("/rosters/list") { kind = "署名履歴" }
        else if path.contains("/keys/") { kind = "鍵取得" }
        else if path.hasPrefix("/v3/group-identities") { kind = "端末登録" }
        else { kind = "詳細" }
        lock.lock(); defer { lock.unlock() }
        requests.append(.init(kind: kind, seconds: seconds, outcome: outcome))
    }
    func recordStorage(seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }; storageSeconds += seconds
    }
    func recordCache(_ outcome: String, seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }; cache.append(outcome); cacheSeconds += seconds
    }
    func recordDetail(seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }; detailLocalSeconds += max(0, seconds)
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return .init(requests: requests, cache: cache, storageSeconds: storageSeconds,
                     cacheSeconds: cacheSeconds, detailLocalSeconds: detailLocalSeconds, entryWaitSeconds: entryWaitSeconds)
    }
}
