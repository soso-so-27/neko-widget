import Foundation

// P3 state exposed to the recovery UI. It never generates or deletes keys.
// Catalogs must come from a root-authenticated successful server response.
enum GroupRootSyncObservation: Equatable, Sendable {
    case checking, unavailable, missing, candidates([String])
}
struct GroupRootMembershipSummary: Equatable, Sendable {
    let rootID: String
    let windowIDs: [String]
    let notebookIDs: [String]
    var isEmpty: Bool { windowIDs.isEmpty && notebookIDs.isEmpty }
}
enum GroupRootSelection: Equatable, Sendable {
    case checking, unavailable, mayCreate, use(String), choose([String])
}
enum GroupRootSelectionPolicy {
    static func resolve(local: String?, sync: GroupRootSyncObservation,
                        catalogs: [String: GroupRootMembershipSummary]) -> GroupRootSelection {
        switch sync {
        case .checking: return .checking
        case .unavailable: return .unavailable
        case .missing: return local.map { .use($0) } ?? .mayCreate
        case .candidates(let candidates):
            let synced = Array(Set(candidates)).sorted()
            guard !synced.isEmpty, synced.allSatisfy({ !$0.isEmpty }) else { return .unavailable }
            let all = Array(Set(synced + (local.map { [$0] } ?? []))).sorted()
            if all.count == 1 { return .use(all[0]) }
            // Sorting is for display only. Never pick a winner by order/date.
            guard all.allSatisfy({ catalogs[$0]?.rootID == $0 }) else { return .checking }
            if synced.count == 1, all.allSatisfy({ catalogs[$0]?.isEmpty == true }) {
                return .use(synced[0])
            }
            return .choose(all)
        }
    }
}

enum GroupRecoveryRegistrationState: Equatable, Sendable {
    case checking(operationID: UUID)
    case notStarted(operationID: UUID)
    case registeredWaitingForKeys(operationID: UUID, deviceID: String)
    case ready(operationID: UUID, deviceID: String)
    case revoked(operationID: UUID)
    /// 元の端末で一度アプリを開くか、もう一度招待が必要。Never create another person.
    case needsOriginalDeviceOrInvitation(operationID: UUID)
    case noKeyProvider(operationID: UUID, deviceID: String)
    case deviceLimit(operationID: UUID)
    case unavailable(operationID: UUID)
    case serverDisabled(operationID: UUID)
}
enum GroupRecoveryRetryAction: Equatable, Sendable {
    case queryStatus(UUID), submitSameOperation(UUID), waitForKeys, complete, stop
    case askFreshGenerationConsent, manageDevices
    case prepareFreshGeneration(UUID, newName: String)
}
extension GroupRecoveryRegistrationState {
    var nextAction: GroupRecoveryRetryAction {
        switch self {
        case .checking(let id): return .queryStatus(id)
        case .notStarted(let id): return .submitSameOperation(id)
        case .registeredWaitingForKeys: return .waitForKeys
        case .ready: return .complete
        case .noKeyProvider: return .askFreshGenerationConsent
        case .deviceLimit: return .manageDevices
        case .unavailable(let id): return .queryStatus(id)
        case .revoked, .needsOriginalDeviceOrInvitation, .serverDisabled: return .stop
        }
    }
    var canOpen: Bool { if case .ready = self { return true }; return false }
    var canSend: Bool { canOpen }
    var knowsWindowExists: Bool {
        switch self {
        case .registeredWaitingForKeys, .noKeyProvider, .ready, .needsOriginalDeviceOrInvitation: true
        default: false
        }
    }
    /// Only produces a local, explicit proposal. No automatic generation change.
    func freshGenerationChoice(confirmedPastUnavailable: Bool, newName: String) -> GroupRecoveryRetryAction {
        guard case .noKeyProvider(let id, _) = self, confirmedPastUnavailable,
              !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              newName.utf8.count <= 80 else { return .stop }
        return .prepareFreshGeneration(id, newName: newName)
    }
}

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
    /// Filled only after encrypted caption verification; absent on legacy photos.
    var caption: String? = nil
}

struct GroupOperation: Codable, Equatable, Sendable {
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
    /// 11/14: the server's `daily_limit` (409): 5 photos per person per
    /// window per day (JST), or 30 hearts a day. Which one is known from the
    /// request that got it.
    case dailyLimit
}

enum GroupInvitationError: Error, Equatable, Sendable {
    case alreadyMember, windowClosed
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
struct GroupAdmissionResult: Codable, Equatable, Sendable, Identifiable {
    let id: String; let windowID: String; let displayName: String; let joinedLocally: Bool
}
protocol GroupWindowClient: Sendable {
    func resumableJoin(invitationID: String) async throws -> GroupJoinRequest?
    func reusableInvitation(windowID: String) async throws -> GroupInvitation?
    func reconcileAdmissions() async throws -> [GroupAdmissionResult]
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
    func resumableJoin(invitationID: String) async throws -> GroupJoinRequest? { nil }
    func reusableInvitation(windowID: String) async throws -> GroupInvitation? { nil }
    func reconcileAdmissions() async throws -> [GroupAdmissionResult] { [] }
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

#if DEBUG || INTERNAL_PRESENTATION
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

#endif
struct GroupNotificationRoute: Sendable {
    let windowID: String
    let requestID: String?
    let kind: String
    static func parse(_ info: [AnyHashable: Any]) -> Self? {
        guard let neko = info["neko"] as? [String: Any], let version = neko["v"] as? Int, version == 3,
              let kind = neko["kind"] as? String, ["moment", "heart", "join_requested", "join_approved"].contains(kind),
              let window = neko["windowId"] as? String, validID(window) else { return nil }
        let request = neko["requestId"] as? String
        if kind.hasPrefix("join_") { guard let request, validID(request) else { return nil } }
        return .init(windowID: window, requestID: request, kind: kind)
    }
    private static func validID(_ value: String) -> Bool {
        value.utf8.count == 22 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
}

/// 11/19 (機種変更 水準2): the relay's silent push to the other devices of a
/// family notebook when a device registers. Exactly
/// {"aps":{"content-available":1},"neko":{"v":3,"kind":"family_device_registered"}};
/// it carries no family ID. Anything else is not this push.
enum FamilyDeviceRegisteredPush {
    static let kind = "family_device_registered"
    static func matches(_ info: [AnyHashable: Any]) -> Bool {
        guard let neko = info["neko"] as? [String: Any], Set(neko.keys) == ["v", "kind"],
              neko["v"] as? Int == 3, neko["kind"] as? String == kind else { return false }
        return true
    }
}

// Presentation only: never use these mutable dates as a pagination cursor.
enum GroupWindowListOrder {
    static func precedes(id: String, received: Date?, created: Int?,
                         otherID: String, otherReceived: Date?, otherCreated: Int?) -> Bool {
        if received != otherReceived {
            if let received, let otherReceived { return received > otherReceived }
            return received != nil
        }
        if created != otherCreated { return (created ?? Int.max) < (otherCreated ?? Int.max) }
        return id < otherID
    }
}

struct GroupDeliveryConfirmationPending: Error { let photoID: String }

struct GroupPhotoCommitReceipt: Decodable {
    let operationID: String; let momentID: String; let windowID: String
    let revision: Int; let keyEpoch: Int; let state: String
    let senderParticipantID: String; let senderDeviceID: String; let createdAt: Int
    func validate(operationID: UUID, windowID: String, photoID: String,
                  participantID: String, deviceID: String, revision: Int, epoch: Int) throws {
        guard self.operationID == operationID.uuidString.lowercased(), self.windowID == windowID,
              momentID == photoID, senderParticipantID == participantID, senderDeviceID == deviceID,
              self.revision == revision, keyEpoch == epoch, state == "committed", createdAt > 0 else {
            throw GroupClientError.invalidResponse
        }
    }
}

/// Root/anchor verification must succeed before mapping relay state for the UI.
/// No server response can produce .ready; P5 owns authenticated key installation.
enum GroupRecoveryPendingStateResolver {
    enum Failure: Error { case invalidState }
    static func resolve(operationID: UUID, state: String, verifiedMembers: [String]?, verifiedOwnerID: String?,
                        personID: String, expectedDeviceID: String, returnedDeviceID: String?,
                        canRequestFreshGeneration: Bool) throws -> GroupRecoveryRegistrationState {
        if state == "needsOriginalDeviceOrInvitation" { return .needsOriginalDeviceOrInvitation(operationID: operationID) }
        guard let members = verifiedMembers, members.contains(personID)
        else { throw Failure.invalidState }
        if state == "notStarted" { return .notStarted(operationID: operationID) }
        guard returnedDeviceID == expectedDeviceID else { throw Failure.invalidState }
        switch state {
        case "registeredWaitingForKeys": return .registeredWaitingForKeys(operationID: operationID, deviceID: expectedDeviceID)
        case "noKeyProvider":
            guard canRequestFreshGeneration, members.count == 1,
                  verifiedOwnerID == personID else { throw Failure.invalidState }
            return .noKeyProvider(operationID: operationID, deviceID: expectedDeviceID)
        default: throw Failure.invalidState
        }
    }
}
