import Foundation

/// Admission requests are separate from notebook edits. Unknown outcomes keep
/// their original operation, encrypted bytes and trust effects across restart.
@available(iOS 17.0, macOS 14.0, *)
actor FamilyNotebookAdmissionClient {
    struct Family: Decodable, Sendable { let familyID: UUID; let generation: Int64; let role: String }
    struct PendingJoin: Decodable, Sendable { let familyID: UUID, requestID: UUID, invitationID: UUID; let expiresAt: Int64 }
    struct Directory: Decodable, Sendable { let schemaVersion: Int; let personID: String; let family: Family?; let pendingRequests: [PendingJoin] }
    struct Member: Decodable, Sendable {
        let personID: String, state: String, role: String
        let admittedGeneration: Int64
        let identityPublicKey: Data
    }
    struct Members: Decodable, Sendable { let schemaVersion: Int; let familyID: UUID; let generation: Int64; let members: [Member] }
    struct Request: Decodable, Sendable {
        let requestID: UUID, invitationID: UUID
        let personID: String, deviceID: String
        let encryptedDisplayName: Data, identityPublicKey: Data, signingPublicKey: Data, hpkePublicKey: Data
        let expiresAt: Int64
    }
    struct Requests: Decodable, Sendable { let schemaVersion: Int; let familyID: UUID; let generation: Int64; let requests: [Request] }
    private struct PreviewReply: Codable, Sendable {
        let schemaVersion: Int; let familyID: UUID, invitationID: UUID
        let generation: Int64; let inviterPersonID: String, inviterDeviceID: String
        let encryptedPreview: Data; let expiresAt: Int64
    }
    private struct SavedPreview: Codable {
        let capability: FamilyNotebookInvitationCapability, reply: PreviewReply, verifiedAt: Date
    }
    private struct Body: Codable, Sendable {
        let operationID: String
        var familyID: String? = nil
        var expectedGeneration: Int64? = nil
        var proofPublicKey: Data? = nil
        var encryptedPreview: Data? = nil
        var proofSignature: Data? = nil
        var encryptedDisplayName: Data? = nil
    }
    struct Receipt: Decodable, Sendable {
        let schemaVersion: Int; let operationID: UUID, familyID: UUID; let operation: String
        let appliedGeneration: Int64; let invitationID: UUID?, joinRequestID: UUID?; let expiresAt: Int64?
    }
    private struct Pending: Codable, Sendable {
        let endpoint: String, personID: String, deviceID: String
        let operation: String, familyID: UUID, operationID: UUID, targetID: UUID?
        let generation: Int64, path: String, body: Data
        let approvedPersonID: String?, approvedRoot: Data?
        var semantic: String { operation + ":" + familyID.uuidString + ":" + (targetID?.uuidString ?? "") }
    }
    private let endpoint: String, identity: GroupDeviceIdentity
    private let wire: FamilyNotebookTransport, keys: FamilyNotebookKeyCoordinator
    private let journal: any GroupSecretStore, secrets: any GroupSecretStore
    private let pendingAccount = "op:fnb-admission:pending"
    private var working = false

    init(endpoint: URL, identity: GroupDeviceIdentity, wire: FamilyNotebookTransport, keys: FamilyNotebookKeyCoordinator,
         journal: any GroupSecretStore, secrets: any GroupSecretStore) {
        self.endpoint = endpoint.absoluteString; self.identity = identity; self.wire = wire; self.keys = keys
        self.journal = journal; self.secrets = secrets
    }
    private func root(_ family: UUID) -> String { "/v3/family-notebooks/" + family.uuidString.lowercased() }
    private func secretAccount(_ id: UUID) -> String { "op:fnb-invitation:" + id.uuidString.lowercased() }
    private func previewAccount(_ id: UUID) -> String { "op:fnb-preview:" + id.uuidString.lowercased() }
    private func pending() throws -> Pending? {
        guard let bytes = try journal.read(pendingAccount) else { return nil }
        let value = try GroupWire.decode(Pending.self, bytes)
        let body = try GroupWire.decode(Body.self, value.body)
        guard value.endpoint == endpoint, value.personID == identity.personID, value.deviceID == (try identity.deviceID),
              body.operationID == value.operationID.uuidString.lowercased(),
              value.path == path(value.operation, value.familyID, value.targetID),
              value.operation == "create" ? (value.generation == 0 && body.familyID == value.familyID.uuidString.lowercased())
                : ((1...1_000_000_000).contains(value.generation) && body.expectedGeneration == value.generation) else {
            throw FamilySharingError.unknownOutcome
        }
        return value
    }
    func hasPendingOperation() throws -> Bool { try pending() != nil }
    func directory() async throws -> Directory {
        let value = try GroupWire.decode(Directory.self, await wire.read("/v3/family-notebooks/me"))
        guard value.schemaVersion == 1, value.personID == identity.personID, value.pendingRequests.count <= 64,
              Set(value.pendingRequests.map(\.requestID)).count == value.pendingRequests.count,
              value.pendingRequests.allSatisfy({ $0.expiresAt > 0 && $0.expiresAt <= 32_503_680_000 }) else { throw FamilyNotebookTransportError.invalidResponse }
        if let family = value.family {
            guard (1...1_000_000_000).contains(family.generation), ["payer", "member"].contains(family.role) else { throw FamilyNotebookTransportError.invalidResponse }
        }
        return value
    }
    func members(_ family: UUID) async throws -> Members {
        let value = try GroupWire.decode(Members.self, await wire.read(root(family) + "/members"))
        guard value.schemaVersion == 1, value.familyID == family, (1...1_000_000_000).contains(value.generation),
              (1...64).contains(value.members.count), Set(value.members.map(\.personID)).count == value.members.count,
              value.members.contains(where: { $0.personID == identity.personID }), value.members.allSatisfy({
                  $0.state == "active" && ["payer", "member"].contains($0.role) && (1...value.generation).contains($0.admittedGeneration)
                    && $0.identityPublicKey.count == 32 && $0.personID == GroupWire.base64(GroupCanonical.hash($0.identityPublicKey))
              }) else { throw FamilyNotebookTransportError.invalidResponse }
        return value
    }
    func requests(_ family: UUID) async throws -> Requests {
        let value = try GroupWire.decode(Requests.self, await wire.read(root(family) + "/requests"))
        guard value.schemaVersion == 1, value.familyID == family, (1...1_000_000_000).contains(value.generation),
              value.requests.count <= 64, Set(value.requests.map(\.requestID)).count == value.requests.count else { throw FamilyNotebookTransportError.invalidResponse }
        for request in value.requests {
            guard request.identityPublicKey.count == 32, request.signingPublicKey.count == 32, request.hpkePublicKey.count == 32,
                  request.personID == GroupWire.base64(GroupCanonical.hash(request.identityPublicKey)),
                  request.deviceID == (try GroupWire.base64(GroupCanonical.hash(GroupCanonical.fields([request.signingPublicKey, request.hpkePublicKey])))),
                  request.expiresAt > 0, request.expiresAt <= 32_503_680_000 else { throw FamilyNotebookTransportError.invalidResponse }
            _ = try requestName(request, family: family)
        }
        return value
    }
    func requestName(_ request: Request, family: UUID) throws -> String {
        try FamilyNotebookJoinNameCrypto.open(request.encryptedDisplayName, familyID: family, invitationID: request.invitationID,
            requestID: request.requestID, personID: request.personID, deviceID: request.deviceID,
            signingPublicKey: request.signingPublicKey, recipient: identity)
    }
    private func path(_ action: String, _ family: UUID, _ target: UUID?) -> String {
        if action == "create" { return "/v3/family-notebooks" }
        if action == "invite" { return root(family) + "/invitations" }
        return root(family) + (["approve", "reject"].contains(action) ? "/requests/" : "/invitations/")
            + (target?.uuidString.lowercased() ?? "") + "/" + action
    }
    private func prepare(_ action: String, family: UUID, generation: Int64, operation: UUID, target: UUID? = nil,
                         approved: Request? = nil, body: Body) throws -> Pending {
        try .init(endpoint: endpoint, personID: identity.personID, deviceID: identity.deviceID,
            operation: action, familyID: family, operationID: operation, targetID: target, generation: generation,
            path: path(action, family, target), body: GroupWire.encode(body),
            approvedPersonID: approved?.personID, approvedRoot: approved?.identityPublicKey)
    }
    private func execute(_ value: Pending) async throws -> Receipt {
        let data: Data
        do {
            data = try await wire.mutate(operationID: value.operationID, intent: GroupCanonical.hash(Data(value.semantic.utf8)),
                                         path: value.path, body: value.body) { response, sent in
                let result = try GroupWire.decode(Receipt.self, response)
                let increment: Int64 = ["create", "approve"].contains(value.operation) ? 1 : 0
                guard sent == value.body, result.schemaVersion == 1, result.operationID == value.operationID,
                      result.familyID == value.familyID, result.operation == value.operation,
                      result.appliedGeneration == value.generation + increment,
                      result.invitationID == (value.operation == "invite" ? value.operationID : ["join", "revoke"].contains(value.operation) ? value.targetID : nil),
                      result.joinRequestID == (value.operation == "join" ? value.operationID : ["approve", "reject"].contains(value.operation) ? value.targetID : nil),
                      ["invite", "join"].contains(value.operation) ? (result.expiresAt.map { (1...32_503_680_000).contains($0) } == true) : result.expiresAt == nil
                else { throw FamilyNotebookTransportError.invalidResponse }
            }
        } catch {
            if Self.definitive(error) { try journal.remove(pendingAccount) }
            throw error
        }
        let receipt = try GroupWire.decode(Receipt.self, data)
        // These local trust effects are idempotent and must precede clearing the
        // pending operation. A saved HTTP receipt alone is never sufficient.
        switch value.operation {
        case "create": try await keys.registerCreatedFamily(value.familyID)
        case "join":
            guard let target = value.targetID else { throw FamilyNotebookTransportError.invalidResponse }
            try await keys.registerInvitation(savedPreview(target, enforceExpiry: false))
        case "approve":
            guard let person = value.approvedPersonID, let root = value.approvedRoot else { throw FamilyNotebookTransportError.invalidResponse }
            try await keys.confirmApprovedAddition(family: value.familyID, personID: person, identityPublicKey: root)
        default: break
        }
        try journal.remove(pendingAccount)
        return receipt
    }
    private static func definitive(_ error: Error) -> Bool {
        guard let value = error as? FamilyNotebookTransportError else { return false }
        switch value {
        case .stale, .notMember: return true
        case .server(let code, let status):
            return (status == 403 && ["family_notebook_not_allowed", "plus_entitlement_required"].contains(code))
                || (status == 410 && code == "family_notebook_invitation_unavailable")
                || (status == 409 && ["family_notebook_already_in_family", "family_notebook_member_limit", "family_notebook_request_not_pending"].contains(code))
        default: return false
        }
    }
    private func perform(action: String, family: UUID?, target: UUID? = nil, make: () throws -> Pending) async throws -> Receipt {
        guard !working else { throw FamilyNotebookTransportError.operationInFlight }
        working = true; defer { working = false }
        let value: Pending
        if let saved = try pending() {
            guard saved.operation == action, family == nil || saved.familyID == family, saved.targetID == target else { throw FamilySharingError.unknownOutcome }
            value = saved
        } else {
            value = try make()
            try journal.write(GroupWire.encode(value), account: pendingAccount, createOnly: true)
        }
        return try await execute(value)
    }
    func resumePending() async throws {
        guard !working else { throw FamilyNotebookTransportError.operationInFlight }
        working = true; defer { working = false }
        if let value = try pending() { _ = try await execute(value) }
    }
    func create(operation: UUID) async throws {
        _ = try await perform(action: "create", family: nil) {
            try prepare("create", family: operation, generation: 0, operation: operation,
                        body: .init(operationID: operation.uuidString.lowercased(), familyID: operation.uuidString.lowercased()))
        }
    }
    func invite(family: UUID, generation: Int64, roster: VerifiedFamilyNotebookRoster, payer: String?,
                name: String, catNames: [String], operation: UUID) async throws -> FamilyInvitation {
        let receipt = try await perform(action: "invite", family: family) {
            let (capability, encrypted) = try FamilyNotebookInvitationCrypto.create(roster: roster, generation: generation,
                identity: identity, payerPersonID: payer, invitationID: operation, inviterName: name, catNames: catNames)
            try secrets.write(GroupWire.encode(capability), account: secretAccount(operation), createOnly: true)
            return try prepare("invite", family: family, generation: generation, operation: operation,
                body: .init(operationID: operation.uuidString.lowercased(), expectedGeneration: generation,
                            proofPublicKey: capability.proofKey.publicKey.rawRepresentation, encryptedPreview: encrypted))
        }
        guard let bytes = try secrets.read(secretAccount(receipt.operationID)), let expiry = receipt.expiresAt else { throw FamilyNotebookTransportError.invalidResponse }
        let capability = try GroupWire.decode(FamilyNotebookInvitationCapability.self, bytes).validated()
        guard capability.familyID == family, capability.invitationID == receipt.operationID else { throw FamilyNotebookTransportError.invalidResponse }
        return try .init(link: capability.url, expiresAt: Date(timeIntervalSince1970: Double(expiry)))
    }
    private func verify(_ saved: SavedPreview, now: Date) throws -> VerifiedFamilyNotebookInvitation {
        let reply = saved.reply, capability = saved.capability
        guard reply.schemaVersion == 1, reply.familyID == capability.familyID, reply.invitationID == capability.invitationID else { throw FamilyNotebookTransportError.invalidResponse }
        return try FamilyNotebookInvitationCrypto.open(reply.encryptedPreview, capability: capability,
            serverInviterPersonID: reply.inviterPersonID, serverInviterDeviceID: reply.inviterDeviceID,
            serverGeneration: reply.generation, serverExpiresAt: reply.expiresAt, now: now)
    }
    private func savedPreview(_ id: UUID, enforceExpiry: Bool = true) throws -> VerifiedFamilyNotebookInvitation {
        guard let bytes = try secrets.read(previewAccount(id)) else { throw FamilySharingError.invitationExpired }
        let saved = try GroupWire.decode(SavedPreview.self, bytes)
        guard saved.capability.invitationID == id else { throw FamilyNotebookTransportError.invalidResponse }
        return try verify(saved, now: enforceExpiry ? Date() : saved.verifiedAt)
    }
    func preview(_ link: URL) async throws -> FamilyInvitationPreview {
        let capability = try FamilyNotebookInvitationCapability(url: link), operation = UUID()
        let body = try Body(operationID: operation.uuidString.lowercased(), proofSignature:
            capability.proof(personID: identity.personID, deviceID: identity.deviceID, action: "preview", operationID: operation))
        let route = path("preview", capability.familyID, capability.invitationID)
        // Preview has no membership effect; each explicit opening gets a fresh
        // authenticated proof. Capability bytes are never sent to the relay.
        let bytes = try await wire.mutate(operationID: operation, intent: GroupCanonical.hash(Data(route.utf8)), path: route,
                                         body: GroupWire.encode(body)) { response, _ in
            let reply = try GroupWire.decode(PreviewReply.self, response)
            guard reply.schemaVersion == 1, reply.familyID == capability.familyID, reply.invitationID == capability.invitationID else { throw FamilyNotebookTransportError.invalidResponse }
        }
        let saved = try SavedPreview(capability: capability, reply: GroupWire.decode(PreviewReply.self, bytes), verifiedAt: Date())
        let verified = try verify(saved, now: saved.verifiedAt)
        try secrets.write(GroupWire.encode(saved), account: previewAccount(capability.invitationID), createOnly: false)
        return .init(inviterName: verified.content.inviterName, catNames: verified.content.catNames, expiresAt: verified.expiresAt,
                     contextID: capability.invitationID)
    }
    func join(_ preview: FamilyInvitationPreview, name: String, operation: UUID) async throws {
        guard let id = preview.contextID else { throw FamilySharingError.invitationExpired }
        // Read the sealed context only when preparing a NEW request. A receipt
        // retry must still work after the invitation expires or is consumed.
        _ = try await perform(action: "join", family: nil, target: id) {
            let invitation = try savedPreview(id)
            guard preview.inviterName == invitation.content.inviterName, preview.catNames == invitation.content.catNames,
                  preview.expiresAt == invitation.expiresAt else { throw FamilyNotebookTransportError.invalidResponse }
            return try prepare("join", family: invitation.capability.familyID, generation: invitation.content.generation,
                operation: operation, target: id, body: .init(operationID: operation.uuidString.lowercased(),
                    expectedGeneration: invitation.content.generation,
                    proofSignature: invitation.capability.proof(personID: identity.personID, deviceID: identity.deviceID, action: "join", operationID: operation),
                    encryptedDisplayName: FamilyNotebookJoinNameCrypto.seal(name, invitation: invitation, identity: identity, requestID: operation)))
        }
    }
    func decide(family: UUID, request: Request, generation: Int64, approve: Bool, operation: UUID) async throws {
        let action = approve ? "approve" : "reject"
        _ = try await perform(action: action, family: family, target: request.requestID) {
            _ = try requestName(request, family: family)
            return try prepare(action, family: family, generation: generation, operation: operation, target: request.requestID,
                approved: approve ? request : nil, body: .init(operationID: operation.uuidString.lowercased(), expectedGeneration: generation))
        }
    }
    func revoke(family: UUID, invitation: UUID, generation: Int64, operation: UUID) async throws {
        _ = try await perform(action: "revoke", family: family, target: invitation) {
            try prepare("revoke", family: family, generation: generation, operation: operation, target: invitation,
                        body: .init(operationID: operation.uuidString.lowercased(), expectedGeneration: generation))
        }
    }
}
