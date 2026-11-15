#if DEBUG || INTERNAL_PRESENTATION
import Foundation
import CryptoKit

/// P3 only: root-authenticated discovery and pending registration. Never installs
/// a roster/key, grants access, creates an identity, or chooses a root for the UI.
actor GroupRecoveryClient {
    enum Failure: Error { case disabled, invalidResponse, unavailable, authentication, deviceLimit, updateRequired }
    struct Device: Decodable, Sendable { let deviceID: String; let model: String?; let registeredAt: Int }
    struct Catalog: Decodable, Sendable {
        struct Window: Decodable, Sendable { let windowID: String }
        struct Notebook: Decodable, Sendable { let familyID: String }
        let personID: String
        let windows: [Window]
        let notebooks: [Notebook]
        let devices: [Device]
        let windowCount: Int
        let notebookCount: Int
        let serverNow: Int
    }
    struct Draft: Codable, Equatable, Sendable {
        let operationID: UUID
        let windowID: String
        let signingPublicKey: Data
        let hpkePublicKey: Data
        let model: String
    }
    struct Registration: Sendable {
        let state: GroupRecoveryRegistrationState
        let model: String?
        let registeredAt: Date?
    }
    private struct Challenge: Decodable {
        let id: String; let person_id: String; let identity_public_key: String
        let operation_id: String; let purpose: String; let environment: String
        let nonce: String; let issued_at: Int; let expires_at: Int; let consumed_at: Int?
        func transcript() throws -> Data {
            try GroupCanonical.fields(["NW3.RECOVERY.CATALOG.V1", environment, purpose, id, person_id].map(GroupCanonical.text)
                + [GroupWire.bytes(identity_public_key, count: 32), GroupCanonical.text(operation_id),
                   GroupWire.bytes(nonce, count: 32), GroupCanonical.text(String(issued_at)), GroupCanonical.text(String(expires_at))])
        }
    }
    private struct ChallengeReply: Decodable { let challenge: Challenge }
    private struct Pending: Decodable {
        struct Anchor: Decodable {
            let environment: String; let personID: String; let windowID: String
            let ownerPersonID: String; let ownerPublicKey: Data; let rootSignature: Data
        }
        let operationID: String; let personID: String; let windowID: String
        let state: String; let canOpen: Bool; let canSend: Bool; let exists: Bool
        let deviceID: String?; let model: String?; let registeredAt: Int?
        let canRequestFreshGeneration: Bool?
        let anchorReceipt: Anchor?; let roster: SignedGroupRoster?; let revision: Int?; let rosterHash: Data?
    }
    private let endpoint: URL
    private let environment: String
    private let root: Curve25519.Signing.PrivateKey
    private let transport: any GroupHTTPTransport
    private let journal: any GroupSecretStore
    private let enabled: Bool
    private var personID: String { GroupWire.base64(GroupCanonical.hash(root.publicKey.rawRepresentation)) }

    init(endpoint: URL, environment: String, root: Data, transport: any GroupHTTPTransport,
         journal: any GroupSecretStore, enabled: Bool = false) throws {
        guard ["production", "staging"].contains(environment), endpoint.scheme == "https",
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
              endpoint.path.isEmpty || endpoint.path == "/" else { throw Failure.invalidResponse }
#if os(iOS)
        guard endpoint == SharingAPIConfiguration.current.baseURL else { throw Failure.invalidResponse }
#endif
        self.endpoint = endpoint; self.environment = environment
        self.root = try Curve25519.Signing.PrivateKey(rawRepresentation: root)
        self.transport = transport; self.journal = journal; self.enabled = enabled
    }
    private func post(_ path: String, _ body: [String: Any]) async throws -> Data {
        guard enabled else { throw Failure.disabled }
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let reply = try await transport.send(request, maximumBytes: 1_500_000)
        guard reply.data.count <= 1_500_000 else { throw Failure.invalidResponse }
        guard (200...299).contains(reply.status) else {
            let value = try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any]
            let code = (value?["error"] as? [String: Any])?["code"] as? String
            if code == "device_limit" { throw Failure.deviceLimit }
            if code == "client_upgrade_required" { throw Failure.updateRequired }
            if reply.status == 401 || reply.status == 403 { throw Failure.authentication }
            throw Failure.unavailable
        }
        return reply.data
    }
    private func challenge(_ operation: UUID, purpose: String) async throws -> Challenge {
        let bytes = try await post("v3/group-recovery/challenges", ["identityPublicKey": GroupWire.base64(root.publicKey.rawRepresentation),
            "operationId": operation.uuidString.lowercased(), "purpose": purpose])
        let c = try JSONDecoder().decode(ChallengeReply.self, from: bytes).challenge
        let now = Int(Date().timeIntervalSince1970)
        guard c.environment == environment, c.purpose == purpose, c.person_id == personID,
              c.operation_id == operation.uuidString.lowercased(), UUID(uuidString: c.id)?.uuidString.lowercased() == c.id,
              try GroupWire.bytes(c.identity_public_key, count: 32) == root.publicKey.rawRepresentation,
              c.consumed_at == nil, c.issued_at <= now + 30, c.issued_at >= now - 300,
              c.expires_at > now, c.expires_at - c.issued_at == 300 else { throw Failure.invalidResponse }
        _ = try GroupWire.bytes(c.nonce, count: 32)
        return c
    }
    func catalog() async throws -> Catalog {
        let c = try await challenge(UUID(), purpose: "catalog")
        let bytes = try await post("v3/group-recovery/catalog", ["challengeId": c.id,
            "rootSignature": GroupWire.base64(root.signature(for: c.transcript()))])
        let result = try GroupWire.decode(Catalog.self, bytes)
        guard result.personID == personID, result.windowCount == result.windows.count,
              result.notebookCount == result.notebooks.count,
              Set(result.windows.map(\.windowID)).count == result.windows.count,
              Set(result.notebooks.map(\.familyID)).count == result.notebooks.count,
              Set(result.devices.map(\.deviceID)).count == result.devices.count,
              result.serverNow >= c.issued_at else { throw Failure.invalidResponse }
        for w in result.windows { _ = try GroupWire.bytes(w.windowID, count: 16) }
        for n in result.notebooks { guard UUID(uuidString: n.familyID) != nil else { throw Failure.invalidResponse } }
        for d in result.devices {
            _ = try GroupWire.bytes(d.deviceID, count: 32)
            guard d.registeredAt > 0, d.registeredAt <= result.serverNow,
                  d.model.map({ !$0.isEmpty && $0.count <= 80 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) ?? true
            else { throw Failure.invalidResponse }
        }
        return result
    }
    private func account(_ window: String) -> String {
        "op:recovery:" + GroupCanonical.hash(Data((endpoint.absoluteString + "|" + environment + "|" + personID + "|" + window).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// Caller owns device keys in Keychain. Only their public intent is journaled.
    func prepare(windowID: String, signingPublicKey: Data, hpkePublicKey: Data, model: String) throws -> Draft {
        guard enabled else { throw Failure.disabled }
        _ = try GroupWire.bytes(windowID, count: 16)
        guard signingPublicKey.count == 32, hpkePublicKey.count == 32, !model.isEmpty, model.count <= 80,
              !model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw Failure.invalidResponse }
        if let saved = try journal.read(account(windowID)) {
            let draft = try GroupWire.decode(Draft.self, saved)
            guard draft.windowID == windowID, draft.signingPublicKey == signingPublicKey,
                  draft.hpkePublicKey == hpkePublicKey, draft.model == model else { throw Failure.invalidResponse }
            return draft
        }
        let draft = Draft(operationID: UUID(), windowID: windowID, signingPublicKey: signingPublicKey, hpkePublicKey: hpkePublicKey, model: model)
        try journal.write(GroupWire.encode(draft), account: account(windowID), createOnly: true)
        return draft
    }
    func status(_ draft: Draft) async throws -> Registration { try await pending(draft, signingKey: nil) }
    func register(_ draft: Draft, signingKey: Data) async throws -> Registration {
        try await pending(draft, signingKey: Curve25519.Signing.PrivateKey(rawRepresentation: signingKey))
    }
    private func pending(_ draft: Draft, signingKey: Curve25519.Signing.PrivateKey?) async throws -> Registration {
        guard let saved = try journal.read(account(draft.windowID)), try GroupWire.decode(Draft.self, saved) == draft,
              signingKey.map({ $0.publicKey.rawRepresentation == draft.signingPublicKey }) ?? true else { throw Failure.invalidResponse }
        let register = signingKey != nil
        let c = try await challenge(draft.operationID, purpose: register ? "register" : "status")
        let intent = register ? try GroupCanonical.fields([GroupCanonical.text("NW3.RECOVERY.PENDING.INTENT.V1"),
            GroupCanonical.text(draft.windowID), draft.signingPublicKey, draft.hpkePublicKey, GroupCanonical.text(draft.model)]) : Data()
        func transcript(_ signer: String) throws -> Data {
            try GroupCanonical.fields([GroupCanonical.text(register ? "NW3.RECOVERY.PENDING.REGISTER.V1" : "NW3.RECOVERY.PENDING.STATUS.V1"),
                GroupCanonical.text(signer), c.transcript(), GroupCanonical.text(draft.windowID), intent])
        }
        var body: [String: Any] = ["challengeId": c.id, "windowId": draft.windowID,
            "rootSignature": try GroupWire.base64(root.signature(for: transcript("root")))]
        if let signingKey {
            body["signingPublicKey"] = GroupWire.base64(draft.signingPublicKey); body["hpkePublicKey"] = GroupWire.base64(draft.hpkePublicKey)
            body["model"] = draft.model; body["deviceSignature"] = try GroupWire.base64(signingKey.signature(for: transcript("device")))
        }
        let result = try GroupWire.decode(Pending.self, await post("v3/group-recovery/operations/" + draft.operationID.uuidString.lowercased() + (register ? "" : "/status"), body))
        guard result.operationID == draft.operationID.uuidString.lowercased(), result.personID == personID,
              result.windowID == draft.windowID, !result.canOpen, !result.canSend, result.exists else { throw Failure.invalidResponse }
        var verified: VerifiedGroupRoster?
        if result.state != "needsOriginalDeviceOrInvitation" {
            guard let a = result.anchorReceipt, a.personID == personID, a.environment == environment, a.windowID == draft.windowID,
                  let packet = result.roster, let revision = result.revision, let hash = result.rosterHash else { throw Failure.invalidResponse }
            let receipt = GroupAnchorReceipt(environment: a.environment, personID: a.personID,
                anchor: .init(windowID: a.windowID, ownerPersonID: a.ownerPersonID, ownerIdentityPublicKey: a.ownerPublicKey), rootSignature: a.rootSignature)
            verified = try GroupRosterVerifier.verifyRecoveryHead(packet, receipts: [receipt], root: root.publicKey.rawRepresentation,
                environment: environment, windowID: draft.windowID, currentRevision: revision, currentHash: hash, rootIsCurrent: true)
        }
        let deviceID = try GroupWire.base64(GroupCanonical.hash(GroupCanonical.fields([draft.signingPublicKey, draft.hpkePublicKey])))
        let state = try GroupRecoveryPendingStateResolver.resolve(operationID: draft.operationID, state: result.state,
            verifiedMembers: verified?.roster.members.map(\.personID), verifiedOwnerID: verified?.roster.members.first(where: { $0.role == .owner })?.personID,
            personID: personID, expectedDeviceID: deviceID, returnedDeviceID: result.deviceID,
            canRequestFreshGeneration: result.canRequestFreshGeneration == true)
        if let date = result.registeredAt { guard date > 0, date <= Int(Date().timeIntervalSince1970) + 30 else { throw Failure.invalidResponse } }
        if let model = result.model { guard model == draft.model else { throw Failure.invalidResponse } }
        return Registration(state: state, model: result.model, registeredAt: result.registeredAt.map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }
}
#endif
