#if DEBUG || INTERNAL_PRESENTATION
import Foundation
import CryptoKit

/// P3 only: root-authenticated discovery and pending registration. Never installs
/// a roster/key, grants access, creates an identity, or chooses a root for the UI.
actor GroupRecoveryClient {
    enum Failure: Error { case disabled, serverDisabled, invalidResponse, unavailable, authentication, deviceLimit, updateRequired }
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
    private let secrets: (any GroupSecretStore)?
    private let enabled: Bool
    private var heads: [String: (SignedGroupRoster, GroupTrustAnchor)] = [:]
    private var personID: String { GroupWire.base64(GroupCanonical.hash(root.publicKey.rawRepresentation)) }

    init(endpoint: URL, environment: String, root: Data, transport: any GroupHTTPTransport,
         journal: any GroupSecretStore, secrets: (any GroupSecretStore)? = nil, enabled: Bool = false) throws {
        guard ["production", "staging"].contains(environment), endpoint.scheme == "https",
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
              endpoint.path.isEmpty || endpoint.path == "/" else { throw Failure.invalidResponse }
#if os(iOS)
        guard endpoint == SharingAPIConfiguration.current.baseURL else { throw Failure.invalidResponse }
#endif
        self.endpoint = endpoint; self.environment = environment
        self.root = try Curve25519.Signing.PrivateKey(rawRepresentation: root)
        self.transport = transport; self.journal = journal; self.secrets = secrets; self.enabled = enabled
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
            if reply.status == 503 && code == "recovery_disabled" { throw Failure.serverDisabled }
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
                  d.model.map({ !$0.isEmpty && $0.utf16.count <= 80 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) ?? true
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
        guard signingPublicKey.count == 32, hpkePublicKey.count == 32, !model.isEmpty, model.utf16.count <= 80,
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
    func removeDevice(_ deviceID: String, operationID: UUID) async throws {
        let c = try await challenge(operationID, purpose: "register")
        let transcript = try GroupCanonical.fields([GroupCanonical.text("NW3.RECOVERY.REMOVE-DEVICE.V1"),
            c.transcript(), GroupWire.bytes(deviceID, count: 32)])
        struct Reply: Decodable { let personID: String; let operationID: String; let deviceID: String; let state: String }
        let reply = try GroupWire.decode(Reply.self, await post("v3/group-recovery/devices/remove", ["challengeId": c.id,
            "deviceId": deviceID, "rootSignature": GroupWire.base64(root.signature(for: transcript))]))
        guard reply.personID == personID, reply.operationID == operationID.uuidString.lowercased(),
              reply.deviceID == deviceID, reply.state == "revoked" else { throw Failure.invalidResponse }
    }

    private struct FreshMaterial: Codable {
        let previous: SignedGroupRoster; let anchor: GroupTrustAnchor
        let packet: SignedGroupRoster; let envelopes: [GroupKeyEnvelope]
        let encryptedName: Data; let encryptedMemberNames: [String: Data]
        let nameDigest: Data
        let requestedName: String
        func hash() throws -> Data {
            let r = packet.roster
            guard r.members.count == 1, envelopes.count == 1, encryptedMemberNames.count == 1,
                  let name = encryptedMemberNames[r.members[0].participantID] else { throw Failure.invalidResponse }
            let e = envelopes[0]
            var fields = ["NW3.RECOVERY.FRESH-MATERIAL.V1", r.windowID, String(r.revision), String(r.keyEpoch)].map(GroupCanonical.text)
            fields += [r.previousHash, GroupCanonical.text(packet.signerDeviceID), packet.signature,
                GroupCanonical.text(GroupWire.base64(encryptedName)), GroupCanonical.text(r.members[0].participantID), GroupCanonical.text(GroupWire.base64(name))]
            fields += [e.windowID, String(e.keyEpoch), GroupWire.base64(e.rosterHash), e.deviceID, GroupWire.base64(e.encapsulatedKey),
                       GroupWire.base64(e.ciphertext), e.signerDeviceID, GroupWire.base64(e.signature)].map(GroupCanonical.text)
            return try GroupCanonical.hash(GroupCanonical.fields(fields))
        }
    }
    func resumeFreshGeneration(_ draft: Draft, identity: GroupDeviceIdentity) async throws -> Registration? {
        guard let saved = try journal.read(freshAccount(draft.windowID)) else { return nil }
        let material = try GroupWire.decode(FreshMaterial.self, saved)
        return try await freshGeneration(draft, identity: identity, newName: material.requestedName)
    }
    private func freshAccount(_ window: String) -> String {
        "op:rf:" + GroupWire.base64(GroupCanonical.hash(Data(account(window).utf8)))
    }
    /// Caller supplies this root's dedicated local Keychain store and exact
    /// device keys. An existing identity/window is never overwritten by another.
    func freshGeneration(_ draft: Draft, identity: GroupDeviceIdentity, newName: String) async throws -> Registration {
        guard let secrets else { throw Failure.disabled }
        let deviceID = try identity.deviceID
        guard enabled, identity.personPublicKey == root.publicKey.rawRepresentation,
              try identity.signingKey.publicKey.rawRepresentation == draft.signingPublicKey,
              try identity.agreementKey.publicKey.rawRepresentation == draft.hpkePublicKey else { throw Failure.invalidResponse }
        let name = try GroupWire.name(newName), key = freshAccount(draft.windowID)
        let saved = try journal.read(key)
        let material: FreshMaterial
        if let saved {
            material = try GroupWire.decode(FreshMaterial.self, saved)
            guard material.nameDigest == GroupCanonical.hash(Data(name.utf8)) else { throw Failure.invalidResponse }
        } else {
            let state = try await status(draft).state
            guard case .noKeyProvider = state, let (oldPacket, anchor) = heads[draft.windowID],
                  oldPacket.roster.members.count == 1 else { throw Failure.invalidResponse }
            let old = oldPacket.roster, member = old.members[0], device = try identity.certificate(windowID: draft.windowID)
            let next = GroupRoster(windowID: old.windowID, revision: old.revision + 1, keyEpoch: old.keyEpoch + 1,
                previousHash: GroupCanonical.hash(try old.canonicalBytes()), ownerPersonID: personID,
                members: [.init(participantID: member.participantID, personID: personID, identityPublicKey: root.publicKey.rawRepresentation, role: .owner, devices: [device])])
            let packet = try GroupRosterVerifier.sign(next, deviceID: device.id, privateKey: identity.signingKey)
            // This locally constructed packet is pinned only for creating its
            // ciphertexts; it is not installed or treated as server membership.
            let verified = try GroupRosterVerifier.restoreLocalCheckpoint(packet, anchor: anchor,
                pinnedRevision: next.revision, pinnedHash: GroupCanonical.hash(next.canonicalBytes()))
            let roomKey = SymmetricKey(size: .bits256)
            material = try .init(previous: oldPacket, anchor: anchor, packet: packet,
                envelopes: [GroupHPKE.wrap(roomKey: roomKey, for: device.id, roster: verified, signerID: device.id, signingKey: identity.signingKey)],
                encryptedName: GroupNameCrypto.seal(name, slot: "window", key: roomKey, roster: verified, signerID: device.id, signingKey: identity.signingKey),
                encryptedMemberNames: [member.participantID: GroupNameCrypto.seal("自分", slot: "member:" + member.participantID,
                    key: roomKey, roster: verified, signerID: device.id, signingKey: identity.signingKey)], nameDigest: GroupCanonical.hash(Data(name.utf8)), requestedName: name)
            try Task.checkCancellation()
            try journal.write(GroupWire.encode(material), account: key, createOnly: true)
        }
        let c = try await challenge(draft.operationID, purpose: "register"), old = material.previous.roster, next = material.packet.roster
        let previous = try GroupRosterVerifier.restoreLocalCheckpoint(material.previous, anchor: material.anchor,
            pinnedRevision: old.revision, pinnedHash: GroupCanonical.hash(old.canonicalBytes()))
        guard old.windowID == draft.windowID, old.members.count == 1, old.ownerPersonID == personID,
              material.anchor.ownerIdentityPublicKey == root.publicKey.rawRepresentation,
              next.members.first?.devices.first?.id == deviceID else { throw Failure.invalidResponse }
        let claim = try GroupRecoveryClaim(version: 1, environment: environment, windowID: draft.windowID, personID: personID,
            participantID: old.members[0].participantID, recoveryGeneration: old.revision, previousRevision: old.revision,
            previousHash: previous.hash, nextHash: GroupCanonical.hash(next.canonicalBytes()), newDevice: next.members[0].devices[0],
            replacedDeviceIDs: old.members[0].devices.map(\.id), operationID: draft.operationID.uuidString.lowercased(),
            challenge: GroupWire.bytes(c.nonce, count: 32), issuedAt: c.issued_at, expiresAt: c.expires_at)
        let proof = try GroupRecoveryProof(claim: claim, rootSignature: root.signature(for: claim.signatureBytes(root: true)),
            deviceSignature: identity.signingKey.signature(for: claim.signatureBytes(root: false)))
        let ledger = GroupRecoveryLedger(environment: environment, windowID: draft.windowID, personID: personID,
            participantID: claim.participantID, identityPublicKey: root.publicKey.rawRepresentation, revision: old.revision,
            hash: previous.hash, recoveryGeneration: old.revision, state: .active, newDeviceWasRevoked: false,
            challenge: .init(value: claim.challenge, operationID: claim.operationID, issuedAt: c.issued_at, expiresAt: c.expires_at, consumed: false))
        let verified = try GroupRosterVerifier.verifySoloRecovery(material.packet, previous: previous, proof: proof, ledger: ledger, now: Int(Date().timeIntervalSince1970))
        struct Input: Encodable { let challengeID: String; let proof: GroupRecoveryProof; let packet: SignedGroupRoster
            let envelopes: [GroupKeyEnvelope]; let encryptedName: Data; let encryptedMemberNames: [String: Data]; let consentSignature: Data }
        let consent = try GroupCanonical.fields([GroupCanonical.text("NW3.RECOVERY.FRESH-CONSENT.V1"), c.transcript(), material.hash()])
        let input = try Input(challengeID: c.id, proof: proof, packet: material.packet, envelopes: material.envelopes,
            encryptedName: material.encryptedName, encryptedMemberNames: material.encryptedMemberNames, consentSignature: root.signature(for: consent))
        let body = try JSONSerialization.jsonObject(with: GroupWire.encode(input)) as! [String: Any]
        struct Reply: Decodable { let personID: String; let operationID: String; let windowID: String; let deviceID: String
            let revision: Int; let rosterHash: Data; let state: String }
        let reply = try GroupWire.decode(Reply.self, await post("v3/group-recovery/operations/" + claim.operationID + "/fresh", body))
        guard reply.personID == personID, reply.operationID == claim.operationID, reply.windowID == draft.windowID,
              reply.deviceID == deviceID, reply.revision == next.revision, reply.rosterHash == verified.hash,
              reply.state == "freshGenerationCommitted" else { throw Failure.invalidResponse }
        let roomKey = try GroupHPKE.unwrap(material.envelopes[0], deviceID: identity.deviceID, agreementKey: identity.agreementKey, roster: verified)
        try Task.checkCancellation()
        if let value = try secrets.read("identity") {
            let local = try GroupWire.decode(GroupDeviceIdentity.self, value)
            guard local.personPublicKey == identity.personPublicKey, try local.deviceID == identity.deviceID else { throw Failure.invalidResponse }
        }
        var local = try secrets.read("window:" + draft.windowID).map { try GroupWire.decode(GroupLocalWindow.self, $0) } ?? .empty(anchor: material.anchor)
        guard local.anchor == material.anchor, !local.left, local.closed != true,
              local.pinnedRevision <= next.revision,
              local.pinnedRevision != next.revision || local.pinnedHash == verified.hash else { throw Failure.invalidResponse }
        local.packet = material.packet; local.pinnedRevision = next.revision; local.pinnedHash = verified.hash
        local.keys[String(next.keyEpoch)] = roomKey.withUnsafeBytes { Data($0) }
        local.rosterHashes[String(next.revision)] = verified.hash
        local.minimumAdmissionRevision = next.revision; local.nameCheckpoint = nil
        var registered = identity; registered.registered = true
        try secrets.write(GroupWire.encode(registered), account: "identity", createOnly: false)
        try secrets.write(GroupWire.encode(local), account: "window:" + draft.windowID, createOnly: false)
        return Registration(state: .ready(operationID: draft.operationID, deviceID: reply.deviceID), model: draft.model, registeredAt: nil)
    }
    struct KeyDeliveryProgress: Sendable {
        let state: String
        let receivedEpochs: [Int]
        let nextAfterEpoch: Int?
        var canSend: Bool { false }
    }
    private struct ReceivedKeys: Codable {
        let anchor: GroupTrustAnchor; let previousHash: Data; let previousRevision: Int
        let admissionRevision: Int; let deviceID: String
        var keys: [String: Data]; var rosterHashes: [String: Data]
    }
    private func receivedAccount(_ draft: Draft) throws -> String {
        try "p5-ready:" + GroupWire.base64(GroupCanonical.hash(GroupCanonical.fields([
            environment, personID, draft.windowID, draft.operationID.uuidString.lowercased()].map(GroupCanonical.text))))
    }
    private struct KeyPage: Decodable {
        struct Item: Decodable { let offer: GroupRecoveryKeyOffer; let epochRoster: SignedGroupRoster }
        let state: String
        let roster: SignedGroupRoster?
        let participation: GroupParticipationBoundary?
        let recipientProof: GroupRecoveryRecipientProof?
        let items: [Item]?
        let nextAfterEpoch: Int?
    }
    private func keyAction(_ draft: Draft, action: String, payload: Data, fields: [String: Any]) async throws -> Data {
        let c = try await challenge(draft.operationID, purpose: "status")
        let transcript = try GroupCanonical.fields([GroupCanonical.text("NW3.RECOVERY.KEY.ACTION.V1"),
            GroupCanonical.text(action), c.transcript(), GroupCanonical.text(draft.windowID), payload])
        var body = fields
        body["challengeId"] = c.id; body["windowId"] = draft.windowID
        body["rootSignature"] = try GroupWire.base64(root.signature(for: transcript))
        return try await post("v3/group-recovery/operations/" + draft.operationID.uuidString.lowercased()
            + (action == "offers" ? "/key-offers" : "/key-receipts"), body)
    }
    /// A bounded page; repeat with nextAfterEpoch and the SAME draft. Keys are
    /// persisted in the dedicated journal before receipts, not in the active window.
    func receiveKeys(_ draft: Draft, identity: GroupDeviceIdentity, afterEpoch: Int = 0) async throws -> KeyDeliveryProgress {
        guard let secrets, afterEpoch >= 0, identity.personPublicKey == root.publicKey.rawRepresentation,
              try identity.signingKey.publicKey.rawRepresentation == draft.signingPublicKey,
              try identity.agreementKey.publicKey.rawRepresentation == draft.hpkePublicKey,
              let saved = try journal.read(account(draft.windowID)), try GroupWire.decode(Draft.self, saved) == draft
        else { throw Failure.invalidResponse }
        _ = try await status(draft)
        guard let (packet, anchor) = heads[draft.windowID] else { throw Failure.invalidResponse }
        let current = try GroupRosterVerifier.verifyHistoricalRecoveryRoster(packet, anchor: anchor)
        let bytes = try await keyAction(draft, action: "offers", payload: GroupCanonical.fields([GroupCanonical.text(String(afterEpoch))]),
            fields: ["afterEpoch": afterEpoch])
        let page = try GroupWire.decode(KeyPage.self, bytes)
        if page.state == "needsParticipationProof" || page.state == "recoveryCommitted" {
            return .init(state: page.state, receivedEpochs: [], nextAfterEpoch: nil)
        }
        guard page.state == "waitingForReceipt", let returned = page.roster,
              try GroupCanonical.hash(returned.roster.canonicalBytes()) == current.hash,
              let boundary = page.participation?.verified(head: current, environment: environment, personID: personID),
              let recipient = page.recipientProof?.verified(head: current, environment: environment),
              recipient.personID == personID, recipient.deviceID == (try identity.deviceID),
              recipient.operationID == draft.operationID.uuidString.lowercased(), let items = page.items, items.count <= 16
        else { throw Failure.invalidResponse }
        let storage = GroupRecoveryKeyJournal(store: secrets)
        var received: [Int] = []
        for item in items {
            try Task.checkCancellation()
            let old = try GroupRosterVerifier.verifyHistoricalRecoveryRoster(item.epochRoster, anchor: anchor)
            guard item.offer.keyEpoch > afterEpoch, !received.contains(item.offer.keyEpoch) else { throw Failure.invalidResponse }
            let key = try await storage.receive(item.offer, recipient: recipient, participation: boundary,
                current: current, epoch: old, agreementKey: identity.agreementKey, signingKey: identity.signingKey,
                now: Int(Date().timeIntervalSince1970))
            let slot = try receivedAccount(draft)
            var bundle = try secrets.read(slot).map { try GroupWire.decode(ReceivedKeys.self, $0) }
                ?? ReceivedKeys(anchor: anchor, previousHash: current.hash, previousRevision: current.roster.revision,
                    admissionRevision: boundary.proof.admissionRevision, deviceID: recipient.deviceID, keys: [:], rosterHashes: [:])
            guard bundle.anchor == anchor, bundle.previousHash == current.hash, bundle.deviceID == recipient.deviceID,
                  bundle.admissionRevision == boundary.proof.admissionRevision else { throw Failure.invalidResponse }
            bundle.keys[String(old.roster.keyEpoch)] = key.key
            bundle.rosterHashes[String(old.roster.revision)] = old.hash
            try secrets.write(GroupWire.encode(bundle), account: slot, createOnly: false)
            let d = GroupRosterDevice(id: recipient.deviceID, signingPublicKey: draft.signingPublicKey,
                hpkePublicKey: draft.hpkePublicKey, personAuthorization: Data())
            let authorization = try root.signature(for: d.authorizationBytes(windowID: draft.windowID, personID: personID))
            let payload = try GroupCanonical.fields([GroupCanonical.text(item.offer.offerID), GroupCanonical.text(String(item.offer.keyEpoch)),
                key.receiptSignature, authorization])
            let response = try await keyAction(draft, action: "receipt", payload: payload, fields: ["offerId": item.offer.offerID,
                "keyEpoch": item.offer.keyEpoch, "receiptSignature": GroupWire.base64(key.receiptSignature),
                "personAuthorization": GroupWire.base64(authorization)])
            struct Ack: Decodable { let state: String; let operationID: String; let offerID: String }
            let ack = try GroupWire.decode(Ack.self, response)
            guard ack.state == "receivedWaitingForOwner", ack.operationID == recipient.operationID, ack.offerID == item.offer.offerID
            else { throw Failure.invalidResponse }
            received.append(item.offer.keyEpoch)
        }
        if let next = page.nextAfterEpoch { guard next == received.last else { throw Failure.invalidResponse } }
        return .init(state: "receivedWaitingForOwner", receivedEpochs: received, nextAfterEpoch: page.nextAfterEpoch)
    }

    /// Poll after the owner commits. Server status alone never installs a key.
    func finishKeyDelivery(_ draft: Draft, identity: GroupDeviceIdentity) async throws -> Registration {
        guard let secrets, identity.personPublicKey == root.publicKey.rawRepresentation,
              let bytes = try secrets.read(receivedAccount(draft)) else { throw Failure.invalidResponse }
        let bundle = try GroupWire.decode(ReceivedKeys.self, bytes)
        let deviceID = try identity.deviceID
        guard bundle.deviceID == deviceID, try identity.signingKey.publicKey.rawRepresentation == draft.signingPublicKey,
              try identity.agreementKey.publicKey.rawRepresentation == draft.hpkePublicKey else { throw Failure.invalidResponse }
        let response = try await keyAction(draft, action: "offers", payload: GroupCanonical.fields([GroupCanonical.text("0")]), fields: ["afterEpoch": 0])
        struct Done: Decodable {
            let state: String; let deviceID: String; let previousHash: Data
            let revision: Int; let rosterHash: Data; let roster: SignedGroupRoster; let envelopeForThisDevice: GroupKeyEnvelope
        }
        let done = try GroupWire.decode(Done.self, response)
        guard done.state == "recoveryCommitted", done.deviceID == deviceID, done.previousHash == bundle.previousHash,
              done.revision > bundle.previousRevision, done.roster.roster.revision == done.revision else { throw Failure.invalidResponse }
        let verified = try GroupRosterVerifier.verifyHistoricalRecoveryRoster(done.roster, anchor: bundle.anchor)
        guard verified.hash == done.rosterHash, let member = verified.device(id: deviceID), member.member.personID == personID,
              member.device.signingPublicKey == draft.signingPublicKey, member.device.hpkePublicKey == draft.hpkePublicKey
        else { throw Failure.invalidResponse }
        let roomKey = try GroupHPKE.unwrap(done.envelopeForThisDevice, deviceID: deviceID, agreementKey: identity.agreementKey, roster: verified)
        try Task.checkCancellation()
        if let value = try secrets.read("identity") {
            let local = try GroupWire.decode(GroupDeviceIdentity.self, value)
            guard local.personPublicKey == identity.personPublicKey, try local.deviceID == deviceID else { throw Failure.invalidResponse }
        }
        var local = try secrets.read("window:" + draft.windowID).map { try GroupWire.decode(GroupLocalWindow.self, $0) } ?? .empty(anchor: bundle.anchor)
        guard local.anchor == bundle.anchor, !local.left, local.closed != true, local.pinnedRevision <= done.revision,
              local.pinnedRevision != done.revision || local.pinnedHash == verified.hash else { throw Failure.invalidResponse }
        local.packet = done.roster; local.pinnedRevision = done.revision; local.pinnedHash = verified.hash
        local.keys.merge(bundle.keys) { old, _ in old }; local.rosterHashes.merge(bundle.rosterHashes) { old, _ in old }
        local.keys[String(verified.roster.keyEpoch)] = roomKey.withUnsafeBytes { Data($0) }
        local.rosterHashes[String(done.revision)] = verified.hash
        local.minimumAdmissionRevision = bundle.admissionRevision; local.nameCheckpoint = nil
        var registered = identity; registered.registered = true
        try secrets.write(GroupWire.encode(registered), account: "identity", createOnly: false)
        try secrets.write(GroupWire.encode(local), account: "window:" + draft.windowID, createOnly: false)
        return Registration(state: .ready(operationID: draft.operationID, deviceID: deviceID), model: draft.model, registeredAt: nil)
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
            if verified != nil { heads[draft.windowID] = (packet, receipt.anchor) }
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
/// Keychain-backed P5 journal. Persist before network send; a receipt is returned
/// only after the decrypted key and receipt have been written together.
actor GroupRecoveryKeyJournal {
    struct Received: Codable, Sendable {
        let offer: GroupRecoveryKeyOffer
        let key: Data
        let receiptSignature: Data
    }
    private let store: any GroupSecretStore
    init(store: any GroupSecretStore) { self.store = store }
    private func account(_ direction: String, _ recipient: VerifiedGroupRecoveryRecipient, _ epoch: Int, _ hash: Data) throws -> String {
        let bytes = try GroupCanonical.fields([direction, recipient.environment, recipient.windowID, recipient.personID,
            recipient.deviceID, recipient.operationID, String(epoch)].map(GroupCanonical.text) + [hash])
        return "p5:" + GroupWire.base64(GroupCanonical.hash(bytes))
    }
    func offer(key: SymmetricKey, recipient: VerifiedGroupRecoveryRecipient, participation: VerifiedGroupParticipation,
               current: VerifiedGroupRoster, epoch: VerifiedGroupRoster, signerID: String,
               signingKey: Curve25519.Signing.PrivateKey, now: Int) throws -> GroupRecoveryKeyOffer {
        let slot = try account("send", recipient, epoch.roster.keyEpoch, current.hash)
        if let bytes = try store.read(slot) {
            let saved = try GroupWire.decode(GroupRecoveryKeyOffer.self, bytes)
            guard saved.senderDeviceID == signerID, saved.epochRosterHash == epoch.hash,
                  saved.recipientDeviceID == recipient.deviceID, saved.operationID == recipient.operationID,
                  participation.permits(epoch: epoch, current: current) else { throw GroupProtocolError.invalidEnvelope }
            // An expired attempt is replaced explicitly by the caller's next offer operation.
            if saved.expiresAt > now { return saved }
        }
        let offer = try GroupRecoveryKeyCrypto.wrap(key, recipient: recipient, participation: participation,
            current: current, epoch: epoch, signerID: signerID, signingKey: signingKey,
            offerID: UUID(), expiresAt: now + 86_400, now: now)
        try store.write(GroupWire.encode(offer), account: slot, createOnly: false)
        return offer
    }
    func offerExpiresAt(recipient: VerifiedGroupRecoveryRecipient, epoch: Int, head: Data) throws -> Int? {
        guard let bytes = try store.read(account("send", recipient, epoch, head)) else { return nil }
        return try GroupWire.decode(GroupRecoveryKeyOffer.self, bytes).expiresAt
    }
    func receive(_ offer: GroupRecoveryKeyOffer, recipient: VerifiedGroupRecoveryRecipient,
                 participation: VerifiedGroupParticipation, current: VerifiedGroupRoster, epoch: VerifiedGroupRoster,
                 agreementKey: Curve25519.KeyAgreement.PrivateKey, signingKey: Curve25519.Signing.PrivateKey,
                 now: Int) throws -> Received {
        guard signingKey.publicKey.rawRepresentation == recipient.signingPublicKey else { throw GroupProtocolError.invalidEnvelope }
        // Revalidate eligibility and signature even when a prior response was lost.
        let key = try GroupRecoveryKeyCrypto.unwrap(offer, recipient: recipient, participation: participation,
            current: current, epoch: epoch, key: agreementKey, now: now)
        let slot = try account("receive", recipient, epoch.roster.keyEpoch, current.hash)
        if let bytes = try store.read(slot) {
            let prior = try GroupWire.decode(Received.self, bytes)
            if prior.offer == offer { return prior }
            guard prior.offer.expiresAt <= now else { throw GroupProtocolError.invalidEnvelope }
        }
        let received = Received(offer: offer, key: key.withUnsafeBytes { Data($0) },
            receiptSignature: try signingKey.signature(for: offer.receiptBytes()))
        try store.write(GroupWire.encode(received), account: slot, createOnly: false)
        return received
    }
}
/// Existing-device P5 transport. It never creates an identity or owner role.
actor GroupRecoveryProviderClient {
    struct Pending: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            struct Receipt: Decodable, Sendable { let keyEpoch: Int; let personAuthorization: Data }
            let operationID: String; let personID: String; let deviceID: String
            let proof: GroupRecoveryRecipientProof; let participation: GroupParticipationBoundary?
            let state: String; let receipts: [Receipt]
        }
        let roster: SignedGroupRoster; let rosterHash: Data; let items: [Item]
        let participationProofs: [GroupParticipationBoundary]
    }
    private let endpoint: URL; private let environment: String; private let enabled: Bool
    private let secrets: any GroupSecretStore; private let transport: any GroupHTTPTransport
    init(endpoint: URL, environment: String, secrets: any GroupSecretStore, transport: any GroupHTTPTransport, enabled: Bool = false) throws {
        guard ["staging", "production"].contains(environment), endpoint.scheme == "https", endpoint.user == nil,
              endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil, endpoint.path.isEmpty || endpoint.path == "/"
        else { throw GroupRecoveryClient.Failure.invalidResponse }
#if os(iOS)
        guard endpoint == SharingAPIConfiguration.current.baseURL else { throw GroupRecoveryClient.Failure.invalidResponse }
#endif
        self.endpoint = endpoint; self.environment = environment; self.secrets = secrets; self.transport = transport; self.enabled = enabled
    }
    private func context(_ window: String) throws -> (GroupDeviceIdentity, GroupLocalWindow, VerifiedGroupRoster) {
        guard enabled, let id = try secrets.read("identity"), let w = try secrets.read("window:" + window) else { throw GroupRecoveryClient.Failure.disabled }
        let identity = try GroupWire.decode(GroupDeviceIdentity.self, id), local = try GroupWire.decode(GroupLocalWindow.self, w)
        guard identity.registered, !local.left, local.closed != true, let head = try local.verified(),
              let member = head.device(id: try identity.deviceID), member.member.personID == identity.personID
        else { throw GroupRecoveryClient.Failure.invalidResponse }; return (identity, local, head)
    }
    private func request(_ path: String, body: Data?, identity: GroupDeviceIdentity) async throws -> Data {
        guard enabled else { throw GroupRecoveryClient.Failure.disabled }
        let request = try GroupHTTPRequest.make(endpoint: endpoint, path: path, body: body, identity: identity)
        let reply = try await transport.send(request, maximumBytes: 1_500_000)
        guard reply.data.count <= 1_500_000 else { throw GroupRecoveryClient.Failure.invalidResponse }
        return try GroupHTTPRequest.check(reply)
    }
    func pending(windowID: String) async throws -> Pending {
        let (identity, _, head) = try context(windowID)
        let reply = try GroupWire.decode(Pending.self, await request("/v3/group-windows/" + windowID + "/recovery/pending", body: Data("{}".utf8), identity: identity))
        guard reply.rosterHash == head.hash, try GroupCanonical.hash(reply.roster.roster.canonicalBytes()) == head.hash,
              reply.items.count <= 18 else { throw GroupRecoveryClient.Failure.invalidResponse }
        for item in reply.items {
            guard let recipient = item.proof.verified(head: head, environment: environment), recipient.operationID == item.operationID,
                  recipient.personID == item.personID, recipient.deviceID == item.deviceID else { throw GroupRecoveryClient.Failure.invalidResponse }
        }
        return reply
    }
    /// Call for the locally held epochs only. Missing participation is an explicit wait.
    func offer(windowID: String, operationID: UUID, epoch: Int, now: Int = Int(Date().timeIntervalSince1970)) async throws -> String {
        let (identity, local, head) = try context(windowID), list = try await pending(windowID: windowID)
        guard let item = list.items.first(where: { $0.operationID == operationID.uuidString.lowercased() }) else { throw GroupRecoveryClient.Failure.invalidResponse }
        guard let boundary = item.participation?.verified(head: head, environment: environment, personID: item.personID) else { return "needsParticipationProof" }
        guard let bytes = local.keys[String(epoch)] else { return "keyNotHeld" }
        guard let recipient = item.proof.verified(head: head, environment: environment) else { throw GroupRecoveryClient.Failure.invalidResponse }
        struct Epoch: Decodable { let roster: SignedGroupRoster }
        let old = try GroupWire.decode(Epoch.self, await request("/v3/group-windows/" + windowID + "/keys/" + String(epoch), body: nil, identity: identity))
        let verified = try GroupRosterVerifier.verifyHistoricalRecoveryRoster(old.roster, anchor: local.anchor)
        guard verified.roster.keyEpoch == epoch else { throw GroupRecoveryClient.Failure.invalidResponse }
        guard boundary.permits(epoch: verified, current: head) else { return "outsideParticipation" }
        let offer = try await GroupRecoveryKeyJournal(store: secrets).offer(key: SymmetricKey(data: bytes), recipient: recipient,
            participation: boundary, current: head, epoch: verified, signerID: identity.deviceID, signingKey: identity.signingKey,
            now: now)
        struct Input: Encodable { let offer: GroupRecoveryKeyOffer }
        struct Reply: Decodable { let state: String; let operationID: String; let offerID: String }
        let reply = try GroupWire.decode(Reply.self, await request("/v3/group-windows/" + windowID + "/recovery/" + recipient.operationID + "/key-offers",
            body: GroupWire.encode(Input(offer: offer)), identity: identity))
        guard reply.operationID == recipient.operationID, reply.offerID == offer.offerID, reply.state == "waitingForReceipt"
        else { throw GroupRecoveryClient.Failure.invalidResponse }; return reply.state
    }
    /// One bounded step on the existing foreground/read cadence. The shared
    /// transport counts each call; no timer or UI action is introduced.
    func advanceAutomatically(window: GroupWindow, now: Int = Int(Date().timeIntervalSince1970)) async throws -> String {
        let (_, local, head) = try context(window.id)
        guard window.revision == head.roster.revision else { throw GroupRecoveryClient.Failure.invalidResponse }
        let list = try await pending(windowID: window.id)
        let eligible = list.items.filter {
            $0.participation?.verified(head: head, environment: environment, personID: $0.personID) != nil
        }.sorted { $0.operationID < $1.operationID }
        let cursorSlot = "p5-auto-next:" + GroupWire.base64(GroupCanonical.hash(Data((environment + window.id).utf8)))
        let lastOperation = try secrets.read(cursorSlot).flatMap { String(data: $0, encoding: .utf8) }
        guard let item = eligible.first(where: { $0.operationID > (lastOperation ?? "") }) ?? eligible.first,
              let operation = UUID(uuidString: item.operationID) else {
            return list.items.isEmpty ? "noPendingDevice" : "needsParticipationProof"
        }
        try secrets.write(Data(item.operationID.utf8), account: cursorSlot, createOnly: false)
        struct Progress: Codable { let head: Data; var visited: [Int]; var offered: [Int] }
        let slot = "p5-auto:" + GroupWire.base64(GroupCanonical.hash(Data((environment + window.id + item.operationID).utf8)))
        var progress = try secrets.read(slot).map { try GroupWire.decode(Progress.self, $0) }
            ?? Progress(head: head.hash, visited: [], offered: [])
        if progress.head != head.hash { progress = Progress(head: head.hash, visited: [], offered: []) }
        // Retry only unacknowledged expired offers, with the same bounded cadence.
        guard let recipient = item.proof.verified(head: head, environment: environment) else { throw GroupRecoveryClient.Failure.invalidResponse }
        let journal = GroupRecoveryKeyJournal(store: secrets)
        var expired: Set<Int> = []
        for epoch in progress.offered where !item.receipts.contains(where: { $0.keyEpoch == epoch }) {
            if try await journal.offerExpiresAt(recipient: recipient, epoch: epoch, head: head.hash).map({ $0 <= now }) != false {
                expired.insert(epoch)
            }
        }
        progress.visited.removeAll { expired.contains($0) }
        progress.offered.removeAll { expired.contains($0) }
        let epochs = local.keys.keys.compactMap(Int.init).sorted()
        if let epoch = epochs.first(where: { !progress.visited.contains($0) }) {
            let state = try await offer(windowID: window.id, operationID: operation, epoch: epoch, now: now)
            guard state == "waitingForReceipt" || state == "outsideParticipation" else { return state }
            progress.visited.append(epoch)
            if state == "waitingForReceipt" { progress.offered.append(epoch) }
            try secrets.write(GroupWire.encode(progress), account: slot, createOnly: false)
            return state
        }
        guard progress.offered.contains(head.roster.keyEpoch),
              progress.offered.allSatisfy({ epoch in item.receipts.contains { $0.keyEpoch == epoch } }) else { return "waitingForReceipt" }
        guard window.canManage else { return "receivedWaitingForOwner" }
        return try await complete(window: window, operationID: operation)
    }

    /// The window is the existing client's freshly verified names/membership view.
    /// Only its owner may rotate, and transport retries reuse the saved full body.
    func complete(window: GroupWindow, operationID: UUID) async throws -> String {
        let (identity, local, head) = try context(window.id)
        guard window.canManage, window.revision == head.roster.revision,
              head.device(id: try identity.deviceID)?.member.role == .owner else { throw GroupRecoveryClient.Failure.invalidResponse }
        let operation = operationID.uuidString.lowercased()
        let slot = "p5-complete:" + GroupWire.base64(GroupCanonical.hash(Data((environment + window.id + operation).utf8)))
        let body: Data
        if let saved = try secrets.read(slot) { body = saved }
        else {
            let list = try await pending(windowID: window.id)
            guard let item = list.items.first(where: { $0.operationID == operation }),
                  let recipient = item.proof.verified(head: head, environment: environment),
                  item.participation?.verified(head: head, environment: environment, personID: item.personID) != nil,
                  let receipt = item.receipts.first(where: { $0.keyEpoch == head.roster.keyEpoch }),
                  let original = head.roster.members.first(where: { $0.personID == recipient.personID })
            else { return "receivedWaitingForOwner" }
            let device = GroupRosterDevice(id: recipient.deviceID, signingPublicKey: recipient.signingPublicKey,
                hpkePublicKey: recipient.hpkePublicKey, personAuthorization: receipt.personAuthorization)
            let root = try Curve25519.Signing.PublicKey(rawRepresentation: original.identityPublicKey)
            guard root.isValidSignature(receipt.personAuthorization, for: try device.authorizationBytes(windowID: window.id, personID: original.personID))
            else { throw GroupRecoveryClient.Failure.invalidResponse }
            let active = Set(window.activeMembers.map(\.id))
            let deviceIDs = Set(window.activeMembers.flatMap { $0.devices.map(\.id) })
            var members = head.roster.members.filter { active.contains($0.participantID) }.map {
                GroupRosterMember(participantID: $0.participantID, personID: $0.personID, identityPublicKey: $0.identityPublicKey,
                    role: $0.role, devices: $0.devices.filter { deviceIDs.contains($0.id) })
            }
            guard let index = members.firstIndex(where: { $0.personID == original.personID }) else { throw GroupRecoveryClient.Failure.invalidResponse }
            let member = members[index]
            guard !member.devices.contains(where: { $0.id == device.id }) else { throw GroupRecoveryClient.Failure.invalidResponse }
            members[index] = .init(participantID: member.participantID, personID: member.personID, identityPublicKey: member.identityPublicKey,
                role: member.role, devices: member.devices + [device])
            let roster = GroupRoster(windowID: window.id, revision: head.roster.revision + 1, keyEpoch: head.roster.keyEpoch + 1,
                previousHash: head.hash, ownerPersonID: head.roster.ownerPersonID, members: members)
            let packet = try GroupRosterVerifier.sign(roster, deviceID: identity.deviceID, privateKey: identity.signingKey)
            let next = try GroupRosterVerifier.verify(packet, anchor: local.anchor, previous: head), key = SymmetricKey(size: .bits256)
            let envelopes = try members.flatMap(\.devices).map {
                try GroupHPKE.wrap(roomKey: key, for: $0.id, roster: next, signerID: identity.deviceID, signingKey: identity.signingKey)
            }
            var names: [String: Data] = [:]
            for member in window.activeMembers {
                names[member.id] = try GroupNameCrypto.seal(member.displayName, slot: "member:" + member.id, key: key,
                    roster: next, signerID: identity.deviceID, signingKey: identity.signingKey)
            }
            let encryptedName = try GroupNameCrypto.seal(window.name, slot: "window", key: key, roster: next,
                signerID: identity.deviceID, signingKey: identity.signingKey)
            let participationProofs = try list.participationProofs.map { proof -> GroupParticipationBoundary in
                guard let old = proof.verified(head: head, environment: environment, personID: proof.personID)
                else { throw GroupRecoveryClient.Failure.invalidResponse }
                return try GroupParticipationBoundary.carry(old, previous: head, next: next, signerID: identity.deviceID, key: identity.signingKey)
            }
            struct Input: Encodable {
                let operationID: String; let expectedRevision: Int; let packet: SignedGroupRoster; let envelopes: [GroupKeyEnvelope]
                let encryptedName: Data; let encryptedMemberNames: [String: Data]; let participationProofs: [GroupParticipationBoundary]
            }
            body = try GroupWire.encode(Input(operationID: operation, expectedRevision: head.roster.revision, packet: packet,
                envelopes: envelopes, encryptedName: encryptedName, encryptedMemberNames: names, participationProofs: participationProofs))
            try secrets.write(body, account: slot, createOnly: true)
        }
        struct Reply: Decodable { let state: String; let operationID: String; let windowID: String }
        let reply = try GroupWire.decode(Reply.self, await request("/v3/group-windows/" + window.id + "/recovery/" + operation + "/complete", body: body, identity: identity))
        guard reply.state == "recoveryCommitted", reply.operationID == operation, reply.windowID == window.id else { throw GroupRecoveryClient.Failure.invalidResponse }
        return reply.state
    }

}
#endif
