import CryptoKit
import Foundation

struct FamilyNotebookKeyMaterial: Sendable {
    let current: VerifiedFamilyNotebookRoster
    let history: [Int: SignedFamilyNotebookRoster]
    let keys: [Int: Data]
    let ready: Bool
    let moreWork: Bool
}

/// App identity keys only. Production construction supplies an app-private
/// Keychain for secrets/trust and a separate SQLite operation journal. Neither
/// operator keys nor personal-photo keys are read or copied.
@available(iOS 17.0, macOS 14.0, *)
actor FamilyNotebookKeyCoordinator {
    private struct Trust: Codable {
        let schemaVersion: Int
        let familyID: UUID, endpoint: String, personID: String, deviceID: String
        let createdHere: Bool
        var pin: FamilyNotebookRosterPin?
        var approvedAdditions: [String: Data]
    }
    private struct Device: Decodable {
        let personID: String, deviceID: String
        let root: Data, signing: Data, agreement: Data, authorization: Data
        enum CodingKeys: String, CodingKey {
            case personID = "person_id", deviceID = "device_id", root = "identity_public_key"
            case signing = "signing_public_key", agreement = "hpke_public_key", authorization = "person_authorization"
        }
        var certificate: GroupRosterDevice { .init(id: deviceID, signingPublicKey: signing, hpkePublicKey: agreement, personAuthorization: authorization) }
    }
    private struct State: Decodable {
        let schemaVersion: Int, familyID: UUID, generation: Int64, currentEpoch: Int
        let roster: SignedFamilyNotebookRoster?, devices: [Device], people: [String], ready: Bool
    }
    private struct RosterReply: Decodable {
        let schemaVersion: Int, familyID: UUID, generation: Int64, currentEpoch: Int
        let roster: SignedFamilyNotebookRoster
    }
    private struct KeysReply: Decodable {
        let schemaVersion: Int, familyID: UUID, generation: Int64, currentEpoch: Int
        let envelopes: [FamilyNotebookKeyEnvelope]
    }
    private struct Candidate: Codable {
        let familyID: UUID, operationID: UUID, generation: Int64, expectedEpoch: Int
        let packet: SignedFamilyNotebookRoster
    }
    private struct Dispatch: Codable { let hash: Data; var index: Int }
    private struct Mutation<Payload: Encodable>: Encodable {
        let operationID: String, expectedGeneration: Int64, expectedEpoch: Int, payload: Payload
    }
    private let endpoint: String, identity: GroupDeviceIdentity, network: FamilyNotebookTransport
    private let secrets: any GroupSecretStore, journal: any GroupSecretStore
    private var working = false

    init(endpoint: URL, identity: GroupDeviceIdentity, network: FamilyNotebookTransport,
         secrets: any GroupSecretStore, journal: any GroupSecretStore) throws {
        guard identity.registered else { throw FamilyNotebookTransportError.authenticationRequired }
        self.endpoint = endpoint.absoluteString; self.identity = identity; self.network = network
        self.secrets = secrets; self.journal = journal
    }
    private func account(_ kind: String, _ family: UUID, _ epoch: Int? = nil) -> String {
        "op:fnb-" + kind + ":" + family.uuidString.lowercased() + (epoch.map { ":" + String($0) } ?? "")
    }
    private func path(_ family: UUID) -> String { "/v3/family-notebooks/" + family.uuidString.lowercased() + "/crypto/" }
    private func validateOwnCertificate(_ certificate: GroupRosterDevice, family: UUID) throws {
        guard certificate.id == (try identity.deviceID),
              certificate.signingPublicKey == (try identity.signingKey.publicKey.rawRepresentation),
              certificate.hpkePublicKey == (try identity.agreementKey.publicKey.rawRepresentation),
              certificate.personAuthorization.count == 64,
              try Curve25519.Signing.PublicKey(rawRepresentation: identity.personPublicKey).isValidSignature(
                certificate.personAuthorization,
                for: certificate.authorizationBytes(windowID: family.uuidString.lowercased(), personID: identity.personID)) else {
            throw FamilyNotebookCryptoError.untrusted
        }
    }
    private func registrationCertificate(_ family: UUID) throws -> GroupRosterDevice {
        let name = account("certificate", family)
        if let bytes = try journal.read(name) {
            let certificate = try GroupWire.decode(GroupRosterDevice.self, bytes)
            try validateOwnCertificate(certificate, family: family)
            return certificate
        }
        let certificate = try identity.certificate(windowID: family.uuidString.lowercased())
        try validateOwnCertificate(certificate, family: family)
        // Persist before sending. Signature bytes are opaque signed material,
        // not a deterministic identifier that can be recreated on retry.
        try journal.write(GroupWire.encode(certificate), account: name, createOnly: true)
        return certificate
    }
    private func trust(_ family: UUID) throws -> Trust {
        guard let bytes = try secrets.read(account("trust", family)) else { throw FamilyNotebookCryptoError.untrusted }
        let value = try GroupWire.decode(Trust.self, bytes)
        guard value.schemaVersion == 1, value.familyID == family, value.endpoint == endpoint,
              value.personID == identity.personID, value.deviceID == (try identity.deviceID),
              value.createdHere || value.pin != nil,
              value.pin == nil || value.pin?.familyID == family,
              value.approvedAdditions.count <= 64,
              value.approvedAdditions.allSatisfy({ $0.value.count == 32 && $0.key == GroupWire.base64(GroupCanonical.hash($0.value)) }) else {
            throw FamilyNotebookCryptoError.untrusted
        }
        return value
    }
    private func save(_ value: Trust, createOnly: Bool = false) throws {
        try secrets.write(GroupWire.encode(value), account: account("trust", value.familyID), createOnly: createOnly)
    }
    /// Call only after validating this device's persisted CREATE receipt.
    func registerCreatedFamily(_ family: UUID) throws {
        guard !working else { throw FamilyNotebookTransportError.operationInFlight }
        if try secrets.read(account("trust", family)) != nil {
            guard try trust(family).createdHere else { throw FamilyNotebookCryptoError.untrusted }; return
        }
        try save(.init(schemaVersion: 1, familyID: family, endpoint: endpoint, personID: identity.personID,
            deviceID: identity.deviceID, createdHere: true, pin: nil, approvedAdditions: [:]), createOnly: true)
    }
    /// This value can only be constructed by verified invitation decryption.
    func registerInvitation(_ invitation: VerifiedFamilyNotebookInvitation) throws {
        guard !working else { throw FamilyNotebookTransportError.operationInFlight }
        let family = invitation.capability.familyID
        if try secrets.read(account("trust", family)) != nil { _ = try trust(family); return }
        try save(.init(schemaVersion: 1, familyID: family, endpoint: endpoint, personID: identity.personID,
            deviceID: identity.deviceID, createdHere: false, pin: invitation.capability.pin, approvedAdditions: [:]), createOnly: true)
    }
    /// Call after a validated approval receipt for this explicitly selected
    /// person. Never feed this method every member returned by the relay.
    func confirmApprovedAddition(family: UUID, personID: String, identityPublicKey: Data) throws {
        guard !working else { throw FamilyNotebookTransportError.operationInFlight }
        guard identityPublicKey.count == 32, personID == GroupWire.base64(GroupCanonical.hash(identityPublicKey)) else { throw FamilyNotebookCryptoError.untrusted }
        var value = try trust(family)
        guard value.approvedAdditions.count < 64 || value.approvedAdditions[personID] != nil else { throw FamilyNotebookCryptoError.tooLarge }
        value.approvedAdditions[personID] = identityPublicKey; try save(value)
    }
    private func state(_ family: UUID) async throws -> State {
        let value = try GroupWire.decode(State.self, await network.read(path(family) + "state"))
        guard value.schemaVersion == 1, value.familyID == family, (1...1_000_000_000).contains(value.generation),
              (0...1_000_000_000).contains(value.currentEpoch), (value.currentEpoch == 0) == (value.roster == nil),
              (1...64).contains(value.people.count), Set(value.people).count == value.people.count,
              value.people.contains(identity.personID), value.devices.count <= 192,
              Set(value.devices.map(\.deviceID)).count == value.devices.count else { throw FamilyNotebookTransportError.invalidResponse }
        return value
    }
    private func operationID(_ fields: [Data]) throws -> UUID {
        var bytes = [UInt8](GroupCanonical.hash(try GroupCanonical.fields([GroupCanonical.text("FNB1.KEY.OP")] + fields)).prefix(16))
        bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    private func post<T: Encodable>(family: UUID, action: String, route: String, operation: UUID, intent: Data,
                                    generation: Int64, epoch: Int, payload: T, replaceStale: Bool = false) async throws {
        let routePath = path(family) + route
        let body = try GroupWire.encode(Mutation(operationID: operation.uuidString.lowercased(), expectedGeneration: generation, expectedEpoch: epoch, payload: payload))
        let validate: @Sendable (Data, Data) throws -> Void = { response, sent in
            try FamilyNotebookTransport.validateCryptoReceipt(response, body: sent, familyID: family, operationID: operation, action: action, path: routePath)
        }
        do { _ = try await network.mutate(operationID: operation, intent: intent, path: routePath, body: body, validate: validate) }
        catch FamilyNotebookTransportError.stale {
            guard replaceStale else { throw FamilyNotebookTransportError.stale }
            _ = try await network.mutate(operationID: operation, intent: intent, path: routePath, body: body, replaceAfterStale: true, validate: validate)
        }
    }
    private func savePacket(_ packet: SignedFamilyNotebookRoster) throws {
        try journal.write(GroupWire.encode(packet), account: account("roster", packet.roster.familyID, packet.roster.epoch), createOnly: false)
    }
    private func packet(_ family: UUID, _ epoch: Int) async throws -> SignedFamilyNotebookRoster {
        if let bytes = try journal.read(account("roster", family, epoch)) { return try GroupWire.decode(SignedFamilyNotebookRoster.self, bytes) }
        let reply = try GroupWire.decode(RosterReply.self, await network.read(path(family) + "rosters/" + String(epoch)))
        guard reply.schemaVersion == 1, reply.familyID == family, reply.currentEpoch >= epoch,
              reply.roster.roster.familyID == family, reply.roster.roster.epoch == epoch else { throw FamilyNotebookTransportError.invalidResponse }
        // Caller verifies against a pin/chain BEFORE accepting or saving it.
        return reply.roster
    }
    private func key(_ family: UUID, _ roster: VerifiedFamilyNotebookRoster) throws -> Data? {
        guard let value = try secrets.read(keyAccount(family, roster.roster)) else { return nil }
        guard value.count == 32, GroupCanonical.hash(value) == roster.roster.keyCommitment else { throw FamilyNotebookCryptoError.untrusted }
        return value
    }
    private func keyAccount(_ family: UUID, _ roster: FamilyNotebookCryptoRoster) throws -> String {
        // Concurrent/rejected proposals may use the same epoch with different
        // commitments. Never let an uncommitted candidate occupy that epoch's
        // only slot or overwrite the winning historical key.
        "op:fnb-key:" + GroupWire.base64(GroupCanonical.hash(try GroupCanonical.fields([
            GroupCanonical.text(family.uuidString.lowercased()), GroupCanonical.text(String(roster.epoch)), roster.keyCommitment])))
    }
    private func finishCandidate(_ family: UUID, trust value: inout Trust) async throws {
        let pendingAccount = account("candidate", family)
        guard let bytes = try journal.read(pendingAccount) else { return }
        let candidate = try GroupWire.decode(Candidate.self, bytes), roster = candidate.packet.roster
        guard candidate.familyID == family, roster.familyID == family, roster.epoch == candidate.expectedEpoch + 1,
              candidate.packet.signerDeviceID == (try identity.deviceID) else { throw FamilyNotebookCryptoError.untrusted }
        let local = try FamilyNotebookRosterCrypto.restore(candidate.packet, trustedPin: .init(familyID: family, epoch: roster.epoch, hash: GroupCanonical.hash(roster.canonicalBytes())))
        guard try key(family, local) != nil else { throw FamilyNotebookCryptoError.untrusted }
        do {
            try await post(family: family, action: "roster", route: "rosters", operation: candidate.operationID, intent: local.hash,
                           generation: candidate.generation, epoch: candidate.expectedEpoch, payload: candidate.packet)
        } catch FamilyNotebookTransportError.stale {
            // Definitive rejection, not an unknown outcome. A later call may
            // propose a fresh key/roster against the newly verified head.
            try journal.remove(pendingAccount); throw FamilyNotebookTransportError.stale
        }
        if let pin = value.pin {
            if pin.epoch < roster.epoch {
                let before = try FamilyNotebookRosterCrypto.restore(await packet(family, pin.epoch), trustedPin: pin)
                _ = try FamilyNotebookRosterCrypto.advance(candidate.packet, previous: before)
            } else if pin.epoch == roster.epoch, pin.hash != local.hash { throw FamilyNotebookCryptoError.untrusted }
        } else { guard value.createdHere, roster.epoch == 1 else { throw FamilyNotebookCryptoError.untrusted } }
        try savePacket(candidate.packet)
        if value.pin == nil || value.pin!.epoch <= roster.epoch {
            value.pin = local.pin
            for member in roster.members { value.approvedAdditions.removeValue(forKey: member.personID) }
            try save(value)
        }
        try journal.remove(pendingAccount)
    }
    private func propose(_ state: State, previous: VerifiedFamilyNotebookRoster?, trust value: inout Trust) async throws -> Bool {
        let people = state.people.sorted()
        // A current member without a registered certificate must open their
        // admitted app; do not silently leave them out of the signed roster.
        guard Set(state.devices.map(\.personID)) == Set(people) else { return false }
        var members: [FamilyNotebookCryptoMember] = []
        for person in people {
            let devices = state.devices.filter { $0.personID == person }
            guard let root = devices.first?.root, root.count == 32, person == GroupWire.base64(GroupCanonical.hash(root)),
                  devices.allSatisfy({ $0.root == root }), (1...3).contains(devices.count) else { throw FamilyNotebookCryptoError.untrusted }
            let known = previous?.roster.members.first(where: { $0.personID == person })?.identityPublicKey
            guard known == root || value.approvedAdditions[person] == root || (previous == nil && value.createdHere && person == identity.personID && root == identity.personPublicKey) else {
                return false // Unknown additions need explicit local approval or another trusted signer.
            }
            members.append(.init(personID: person, identityPublicKey: root, devices: devices.map(\.certificate)))
        }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let roster = FamilyNotebookCryptoRoster(familyID: state.familyID, epoch: state.currentEpoch + 1,
            previousHash: previous?.hash ?? Data(repeating: 0, count: 32), keyCommitment: GroupCanonical.hash(key), members: members)
        let signed = try FamilyNotebookRosterCrypto.sign(roster, deviceID: identity.deviceID, signingKey: identity.signingKey)
        if let previous { _ = try FamilyNotebookRosterCrypto.advance(signed, previous: previous) }
        else { _ = try roster.canonicalBytes() }
        // Secret first, pending body second, network last. Unknown outcomes
        // reuse this exact signed roster and key after process restart.
        try secrets.write(key, account: keyAccount(state.familyID, roster), createOnly: true)
        try journal.write(GroupWire.encode(Candidate(familyID: state.familyID, operationID: UUID(), generation: state.generation,
            expectedEpoch: state.currentEpoch, packet: signed)), account: account("candidate", state.familyID), createOnly: true)
        try await finishCandidate(state.familyID, trust: &value)
        return true
    }

    /// Bounded catch-up. Nil/moreWork keeps the service in waitingForKeys;
    /// callers schedule another pass rather than skipping old history.
    func prepare(family: UUID) async throws -> FamilyNotebookKeyMaterial? {
        guard !working else { throw FamilyNotebookTransportError.operationInFlight }
        working = true; defer { working = false }
        var trusted = try trust(family)
        try await finishCandidate(family, trust: &trusted)
        var currentState = try await state(family)
        if let registered = currentState.devices.first(where: { $0.deviceID == (try? identity.deviceID) }) {
            guard registered.personID == identity.personID, registered.root == identity.personPublicKey else { throw FamilyNotebookCryptoError.untrusted }
            try validateOwnCertificate(registered.certificate, family: family)
        } else {
            let certificate = try registrationCertificate(family)
            struct Payload: Encodable { let personAuthorization: Data }
            let intent = GroupCanonical.hash(try certificate.authorizationBytes(windowID: family.uuidString.lowercased(), personID: identity.personID))
            try await post(family: family, action: "device", route: "devices", operation: operationID([intent]), intent: intent,
                generation: currentState.generation, epoch: currentState.currentEpoch, payload: Payload(personAuthorization: certificate.personAuthorization), replaceStale: true)
            currentState = try await state(family)
        }
        if trusted.pin == nil {
            guard trusted.createdHere, currentState.currentEpoch == 0, currentState.people == [identity.personID] else { throw FamilyNotebookCryptoError.untrusted }
            guard try await propose(currentState, previous: nil, trust: &trusted) else { return nil }
            currentState = try await state(family)
        }
        guard let pin = trusted.pin, currentState.currentEpoch >= pin.epoch else { throw FamilyNotebookCryptoError.untrusted }
        var current = try FamilyNotebookRosterCrypto.restore(await packet(family, pin.epoch), trustedPin: pin)
        try savePacket(current.packet)
        for _ in 0..<8 where current.roster.epoch < currentState.currentEpoch {
            let next = try await packet(family, current.roster.epoch + 1)
            current = try FamilyNotebookRosterCrypto.advance(next, previous: current)
            try savePacket(next); trusted.pin = current.pin
            for member in current.roster.members { trusted.approvedAdditions.removeValue(forKey: member.personID) }
            try save(trusted)
        }
        guard current.roster.epoch == currentState.currentEpoch else {
            return .init(current: current, history: [:], keys: [:], ready: false, moreWork: true)
        }
        guard let serverPacket = currentState.roster else { throw FamilyNotebookCryptoError.untrusted }
        _ = try FamilyNotebookRosterCrypto.restore(serverPacket, trustedPin: current.pin)
        if !currentState.ready, current.roster.device(try identity.deviceID)?.person.personID == identity.personID {
            if try await propose(currentState, previous: current, trust: &trusted) { return nil }
        }
        guard current.roster.device(try identity.deviceID)?.person.personID == identity.personID else { return nil }
        var context = FamilyNotebookKeyContext.current(current), contexts = [current.roster.epoch: FamilyNotebookKeyContext.current(current)]
        var history: [Int: SignedFamilyNotebookRoster] = [:], downloads = 0
        while context.source.roster.epoch > 1 {
            let epoch = context.source.roster.epoch - 1
            if try journal.read(account("roster", family, epoch)) == nil {
                guard downloads < 8 else { return .init(current: current, history: history, keys: [:], ready: false, moreWork: true) }
                downloads += 1
            }
            let previous = try await packet(family, epoch)
            context = try context.previous(previous); try savePacket(previous)
            contexts[epoch] = context; history[epoch] = previous
        }
        var keys: [Int: Data] = [:], keyRequests = 0
        for epoch in contexts.keys.sorted(by: >) {
            let source = contexts[epoch]!
            if let saved = try key(family, source.source) { keys[epoch] = saved; continue }
            guard keyRequests < 8 else { continue }; keyRequests += 1
            let reply = try GroupWire.decode(KeysReply.self, await network.read(path(family) + "keys/" + String(epoch)))
            guard reply.schemaVersion == 1, reply.familyID == family, reply.currentEpoch == current.roster.epoch,
                  reply.generation == currentState.generation, reply.envelopes.count <= 192 else { throw FamilyNotebookTransportError.stale }
            for envelope in reply.envelopes {
                if let opened = try? FamilyNotebookKeyCrypto.unwrap(envelope, context: source, recipientID: identity.deviceID, agreementKey: identity.agreementKey) {
                    try secrets.write(opened, account: keyAccount(family, source.source.roster), createOnly: false); keys[epoch] = opened; break
                }
            }
        }
        guard currentState.ready else {
            return .init(current: current, history: history, keys: keys, ready: false, moreWork: true)
        }
        // Only fully verified keys are sent, and only to devices in the current
        // verified roster. An invalid envelope never overwrites a saved key.
        let recipients = current.roster.members.flatMap(\.devices).sorted { $0.id < $1.id }
        let epochs = contexts.keys.sorted()
        let dispatchAccount = account("dispatch", family)
        var dispatch = Dispatch(hash: current.hash, index: 0)
        if let bytes = try journal.read(dispatchAccount) {
            let saved = try GroupWire.decode(Dispatch.self, bytes)
            if saved.hash == current.hash { dispatch = saved }
        }
        let total = epochs.count * recipients.count
        guard (0...total).contains(dispatch.index) else { throw FamilyNotebookCryptoError.invalid }
        for _ in 0..<8 where dispatch.index < total {
            let epoch = epochs[dispatch.index / recipients.count], recipient = recipients[dispatch.index % recipients.count]
            guard let value = keys[epoch] else { break }
            let wrapped = try FamilyNotebookKeyCrypto.wrap(value, context: contexts[epoch]!, recipientID: recipient.id,
                signerID: identity.deviceID, signingKey: identity.signingKey)
            let intent = GroupCanonical.hash(try GroupCanonical.fields([current.hash, contexts[epoch]!.source.hash,
                GroupCanonical.text(recipient.id), GroupCanonical.text(identity.deviceID)]))
            try await post(family: family, action: "key", route: "keys", operation: operationID([intent]), intent: intent,
                generation: currentState.generation, epoch: current.roster.epoch, payload: wrapped, replaceStale: true)
            dispatch.index += 1
            try journal.write(GroupWire.encode(dispatch), account: dispatchAccount, createOnly: false)
        }
        let complete = keys.count == contexts.count
        return .init(current: current, history: history, keys: keys, ready: currentState.ready && complete,
                     moreWork: !complete || dispatch.index < total)
    }
}
