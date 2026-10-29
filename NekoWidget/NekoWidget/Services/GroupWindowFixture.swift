#if DEBUG
import Foundation

// IN-MEMORY UI FIXTURE ONLY. No production authentication, encryption, limits, or persistence.
// Compile alongside GroupWindowContract_1020.swift. Never select this client from Release config.
// Supply a fixed Date from a preview/test to make expiry deterministic.
actor GroupWindowFixture: GroupWindowClient {
    enum Scenario: Equatable, Sendable { case normal, sixPeople, threeDevices, offline, conflict, expiredInvitation, rotationPending }
    private let scenario: Scenario
    private let now: Date
    private var room: GroupWindow
    private var invitations: [String: GroupInvitation] = [:]
    private var requests: [String: GroupJoinRequest] = [:]
    private var pictures: [GroupPhoto]
    private var completed: [UUID: (String, GroupWindow)] = [:]

    init(scenario: Scenario = .normal,
         now: Date = Date(timeIntervalSince1970: 1_792_454_400)) {
        self.scenario = scenario
        self.now = now
        let owner = GroupMember(id: "fixture-owner", personID: "fixture-person-a", displayName: "自分",
            role: .owner, state: .active,
            devices: [.init(id: "fixture-a1", displayName: "このiPhone", isThisDevice: true)])
        var mother = GroupMember(id: "fixture-mother", personID: "fixture-person-b", displayName: "お母さん",
            role: .member, state: .active,
            devices: [.init(id: "fixture-b1", displayName: "iPhone", isThisDevice: false)])
        if scenario == .threeDevices {
            mother.devices += (2...3).map { .init(id: "fixture-b\($0)", displayName: "iPhone \($0)", isThisDevice: false) }
        }
        var members = [owner, mother]
        if scenario == .sixPeople {
            members += (3...6).map { i in
                GroupMember(id: "fixture-member-\(i)", personID: "fixture-person-\(i)", displayName: "家族\(i)",
                    role: .member, state: .active,
                    devices: [.init(id: "fixture-device-\(i)", displayName: "iPhone", isThisDevice: false)])
            }
        }
        room = GroupWindow(id: "fixture-window", name: "実家のまど", revision: 8, keyEpoch: 3,
            myParticipantID: owner.id, myRole: .owner,
            state: scenario == .rotationPending ? .rotationRequired : .active, members: members)
        pictures = [.init(id: "fixture-photo", windowID: "fixture-window", senderParticipantID: mother.id,
            senderDisplayName: mother.displayName, createdAt: now, fixtureAssetName: nil,
            hearts: [.init(participantID: owner.id, displayName: owner.displayName, active: true, updatedAt: now)])]
        let expiry = now.addingTimeInterval(scenario == .expiredInvitation ? -1 : 86_400)
        invitations["fixture-invite"] = .init(id: "fixture-invite", windowID: room.id,
            expiresAt: expiry, revoked: false, shareText: "画面確認用の招待（実際には参加できません）")
        requests["fixture-request"] = .init(id: "fixture-request", invitationID: "fixture-invite",
            personID: "fixture-person-c", candidateDeviceID: "fixture-c1", displayName: "お父さん",
            verificationPhrase: "ねこ・ひなた・まど", expiresAt: expiry, state: .pending)
    }

    private func online() throws {
        if scenario == .offline { throw GroupClientError.offline }
    }
    private func validate(_ id: String) throws {
        try online()
        guard id == room.id else { throw GroupClientError.notMember }
    }
    private func begin(_ operation: GroupOperation, fingerprint: String) throws -> GroupWindow? {
        try online()
        if let previous = completed[operation.id] {
            guard previous.0 == fingerprint else { throw GroupClientError.idempotencyConflict }
            return previous.1
        }
        if scenario == .conflict || operation.expectedRevision != room.revision {
            throw GroupClientError.staleRevision(current: room.revision + (scenario == .conflict ? 1 : 0))
        }
        guard room.canManage else { throw GroupClientError.ownerRequired }
        return nil
    }
    private func commit(_ operation: GroupOperation, fingerprint: String, rotates: Bool) -> GroupWindow {
        room.revision += 1
        if rotates { room.keyEpoch += 1 }
        completed[operation.id] = (fingerprint, room)
        return room
    }
    private func invitation(_ id: String) throws -> GroupInvitation {
        guard let value = invitations[id] else { throw GroupClientError.invitationRevoked }
        guard !value.revoked else { throw GroupClientError.invitationRevoked }
        guard value.expiresAt > now else { throw GroupClientError.invitationExpired }
        return value
    }
    private func pending(_ id: String) throws -> GroupJoinRequest {
        guard let value = requests[id], value.state == .pending else { throw GroupClientError.requestNotPending }
        _ = try invitation(value.invitationID)
        guard value.expiresAt > now else { throw GroupClientError.invitationExpired }
        return value
    }

    func windows() async throws -> [GroupWindow] { try online(); return [room] }
    func window(id: String) async throws -> GroupWindow { try validate(id); return room }
    func createWindow(name: String, operationID: UUID) async throws -> GroupWindow {
        try online()
        // Default fixture represents a free owner who already has one window.
        throw GroupClientError.ownedWindowLimit
    }
    func createWindow(name: String, ownerDisplayName: String, operationID: UUID) async throws -> GroupWindow {
        // Keep the fixture's existing occupied-window scenario. No supplied
        // display name is silently stored as a successful creation.
        try await createWindow(name: name, operationID: operationID)
    }
    func createInvitation(windowID: String, operation: GroupOperation) async throws -> GroupInvitation {
        try validate(windowID)
        let key = "invite:\(operation.id.uuidString)"
        if try begin(operation, fingerprint: key) != nil, let old = invitations[key] { return old }
        let value = GroupInvitation(id: key, windowID: windowID, expiresAt: now.addingTimeInterval(86_400),
            revoked: false, shareText: "画面確認用の招待（実際には参加できません）")
        invitations[key] = value
        _ = commit(operation, fingerprint: key, rotates: false)
        return value
    }
    func revokeInvitation(id: String, windowID: String, operation: GroupOperation) async throws {
        try validate(windowID)
        let key = "revoke:\(id)"
        if try begin(operation, fingerprint: key) != nil { return }
        _ = try invitation(id)
        invitations[id]?.revoked = true
        for requestID in Array(requests.keys) where requests[requestID]?.invitationID == id && requests[requestID]?.state == .pending {
            requests[requestID]?.state = .cancelled
        }
        _ = commit(operation, fingerprint: key, rotates: false)
    }
    func apply(invitationID: String, displayName: String, operationID: UUID) async throws -> GroupJoinRequest {
        try online()
        let invite = try invitation(invitationID)
        let id = "apply:\(operationID.uuidString)"
        if let old = requests[id] {
            guard old.invitationID == invitationID && old.displayName == displayName else { throw GroupClientError.idempotencyConflict }
            return old
        }
        let request = GroupJoinRequest(id: id, invitationID: invitationID, personID: "fixture-person-\(id)",
            candidateDeviceID: "fixture-device-\(id)", displayName: displayName,
            verificationPhrase: "ねこ・ひなた・まど", expiresAt: invite.expiresAt, state: .pending)
        requests[id] = request
        return request
    }
    func joinStatus(requestID: String) async throws -> GroupJoinRequest {
        try online()
        guard var result = requests[requestID] else { throw GroupClientError.requestNotPending }
        if result.state == .pending && result.expiresAt <= now { result.state = .expired }
        return result
    }
    func pendingRequests(windowID: String) async throws -> [GroupJoinRequest] {
        try validate(windowID)
        return requests.values.filter { $0.state == .pending && $0.expiresAt > now }.sorted { $0.id < $1.id }
    }
    func approve(requestID: String, windowID: String, operation: GroupOperation) async throws -> GroupWindow {
        try validate(windowID)
        let key = "approve:\(requestID)"
        if let old = try begin(operation, fingerprint: key) { return old }
        let request = try pending(requestID)
        guard room.memberCount < 6 else { throw GroupClientError.memberLimit }
        room.members.append(.init(id: "member:\(request.id)", personID: request.personID, displayName: request.displayName,
            role: .member, state: .active,
            devices: [.init(id: request.candidateDeviceID, displayName: "iPhone", isThisDevice: false)]))
        requests[requestID]?.state = .approved
        return commit(operation, fingerprint: key, rotates: true)
    }
    func reject(requestID: String, windowID: String, operation: GroupOperation) async throws {
        try validate(windowID)
        let key = "reject:\(requestID)"
        if try begin(operation, fingerprint: key) != nil { return }
        _ = try pending(requestID)
        requests[requestID]?.state = .rejected
        _ = commit(operation, fingerprint: key, rotates: false)
    }
    func cancel(requestID: String, operationID: UUID) async throws {
        try online()
        guard requests[requestID]?.state == .pending else { throw GroupClientError.requestNotPending }
        requests[requestID]?.state = .cancelled
    }
    func addDevice(participantID: String, windowID: String, displayName: String, operation: GroupOperation) async throws -> GroupWindow {
        try validate(windowID)
        let key = "device:\(participantID):\(displayName)"
        if let old = try begin(operation, fingerprint: key) { return old }
        guard let index = room.members.firstIndex(where: { $0.id == participantID && $0.state == .active }) else { throw GroupClientError.notMember }
        guard room.members[index].devices.count < 3 else { throw GroupClientError.deviceLimit }
        room.members[index].devices.append(.init(id: operation.id.uuidString, displayName: displayName, isThisDevice: false))
        return commit(operation, fingerprint: key, rotates: true)
    }
    func removeMember(participantID: String, windowID: String, operation: GroupOperation) async throws -> GroupWindow {
        try validate(windowID)
        let key = "remove:\(participantID)"
        if let old = try begin(operation, fingerprint: key) { return old }
        guard let index = room.members.firstIndex(where: { $0.id == participantID && $0.state == .active }) else { throw GroupClientError.notMember }
        guard room.members[index].role != .owner else { throw GroupClientError.cannotRemoveOwner }
        room.members[index].state = .removed
        return commit(operation, fingerprint: key, rotates: true)
    }
    func leave(windowID: String, operation: GroupOperation) async throws {
        try validate(windowID)
        if room.myRole == .owner { throw GroupClientError.ownerCannotLeave }
    }
    func rotate(windowID: String, operation: GroupOperation) async throws -> GroupWindow {
        try validate(windowID)
        let key = "rotate"
        if let old = try begin(operation, fingerprint: key) { return old }
        room.state = .active
        return commit(operation, fingerprint: key, rotates: true)
    }
    func photos(windowID: String) async throws -> [GroupPhoto] { try validate(windowID); return pictures }
    func setHeart(photoID: String, windowID: String, active: Bool, operationID: UUID) async throws -> GroupPhoto {
        try validate(windowID)
        guard let index = pictures.firstIndex(where: { $0.id == photoID }) else { throw GroupClientError.invalidResponse }
        let me = room.myParticipantID
        pictures[index].hearts.removeAll { $0.participantID == me }
        pictures[index].hearts.append(.init(participantID: me, displayName: "自分", active: active, updatedAt: now))
        return pictures[index]
    }
}
#endif
