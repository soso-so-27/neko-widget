import CryptoKit
import Foundation
import Security

struct FamilyNotebookKeyMaterial: Sendable {
    let current: VerifiedFamilyNotebookRoster
    let history: [Int: SignedFamilyNotebookRoster]
    let keys: [Int: Data]
    let ready: Bool
    let moreWork: Bool
    /// 11/21: the roster is verified at the relay's epoch, this device is in
    /// it and every epoch's key is held: what the family wrote can be read
    /// even while writing waits (`ready` false). Never a reason to write.
    var readable = false
    /// 11/21: writing waits for someone the relay lists but the signed roster
    /// does not yet (a newly approved person who has not opened the app, or
    /// whose approving iPhone has not signed them in yet).
    var awaitsMember = false
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
    private let recoveryEnabled: Bool
    /// 11/19 (機種変更 水準2): the person's pin in iCloud Keychain, next to the
    /// person key. Nil in builds without that sync.
    private let pinSync: (any FamilyNotebookPinSync)?
    private var pinsOffered = Set<UUID>()
    private var working = false
    /// 11/15 (1115q): what the last pass saw (the relay's generation, epoch,
    /// devices, readiness, and the keys held). A pass that changes it moved;
    /// the notebook's one schedule waits longer after passes that did not.
    private(set) var observation = ""
    /// Key reads per pass, newest epoch first (11/15: up to 8 empty replies
    /// were read again on every pass while a key had not arrived).
    static let keyReadsPerPass = 2
    private func observe(_ state: State, keys: Int? = nil) {
        observation = "g\(state.generation)e\(state.currentEpoch)d\(state.devices.count)r\(state.ready)"
            + (keys.map { "k\($0)" } ?? "")
    }

    init(endpoint: URL, identity: GroupDeviceIdentity, network: FamilyNotebookTransport,
         secrets: any GroupSecretStore, journal: any GroupSecretStore, recoveryEnabled: Bool = false,
         pinSync: (any FamilyNotebookPinSync)? = nil) throws {
        guard identity.registered else { throw FamilyNotebookTransportError.authenticationRequired }
        self.endpoint = endpoint.absoluteString; self.identity = identity; self.network = network
        self.secrets = secrets; self.journal = journal; self.recoveryEnabled = recoveryEnabled
        self.pinSync = pinSync
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
        // Every pin this iPhone verified and kept also goes next to the person
        // key (only a newer epoch replaces it there). Best effort: a locked or
        // missing iCloud Keychain never stops the notebook.
        if let pin = value.pin { syncPin(pin) }
    }
    private func syncPin(_ pin: FamilyNotebookRosterPin) {
        try? pinSync?.write(pin, endpoint: endpoint, personID: identity.personID)
    }
    /// 11/19 (機種変更 水準2): a new iPhone of the same person has no trust of
    /// its own. It starts from the pin the person's other iPhone kept in iCloud
    /// Keychain and walks forward with the usual verification. A pin from the
    /// relay is never used; without a synced one this stays untrusted.
    private func adoptSyncedPin(_ family: UUID) throws {
        guard try secrets.read(account("trust", family)) == nil, let pinSync,
              let pin = try pinSync.read(endpoint: endpoint, personID: identity.personID, family: family) else { return }
        guard pin.familyID == family, pin.epoch >= 1, pin.hash.count == 32 else { throw FamilyNotebookCryptoError.untrusted }
        try save(.init(schemaVersion: 1, familyID: family, endpoint: endpoint, personID: identity.personID,
            deviceID: identity.deviceID, createdHere: false, pin: pin, approvedAdditions: [:]), createOnly: true)
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
        defer { observe(value) }
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
        let packet = try FamilyNotebookRosterCrypto.sign(roster, deviceID: identity.deviceID, signingKey: identity.signingKey)
#if (DEBUG || INTERNAL_PRESENTATION) && !NEKO_SHARE_EXTENSION
        var signed = packet
        if recoveryEnabled {
            let environment: String
            switch URL(string: endpoint)?.host {
            case "api.nekonomado.com": environment = "production"
            case "neko-window-sharing-staging.nakanishisoya.workers.dev", "recovery.invalid": environment = "staging"
            default: throw FamilyNotebookCryptoError.untrusted
            }
            let next = try previous.map { try FamilyNotebookRosterCrypto.advance(signed, previous: $0) }
                ?? FamilyNotebookRosterCrypto.restore(signed, trustedPin: .init(familyID: roster.familyID, epoch: roster.epoch,
                    hash: GroupCanonical.hash(roster.canonicalBytes())))
            signed.participationProofs = try roster.members.compactMap { member in
                if previous?.roster.members.contains(where: { $0.personID == member.personID }) != true {
                    return try FamilyNotebookParticipationBoundary.forNewAdmission(head: next, environment: environment,
                        personID: member.personID, signerID: identity.deviceID, key: identity.signingKey)
                }
                guard let previous, let old = previous.packet.participationProofs?.first(where: { $0.personID == member.personID }),
                      old.verifies(in: previous, environment: environment) else { return nil }
                return try FamilyNotebookParticipationBoundary.carry(old, previous: previous, next: next, environment: environment,
                    signerID: identity.deviceID, key: identity.signingKey)
            }
        }
#else
        let signed = packet
#endif
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
        try adoptSyncedPin(family)
        var trusted = try trust(family)
        // A pin kept before the sync existed reaches iCloud Keychain once.
        if let pin = trusted.pin, pinsOffered.insert(family).inserted { syncPin(pin) }
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
            guard keyRequests < Self.keyReadsPerPass else { continue }; keyRequests += 1
            let reply = try GroupWire.decode(KeysReply.self, await network.read(path(family) + "keys/" + String(epoch)))
            guard reply.schemaVersion == 1, reply.familyID == family, reply.currentEpoch == current.roster.epoch,
                  reply.generation == currentState.generation, reply.envelopes.count <= 192 else { throw FamilyNotebookTransportError.stale }
            for envelope in reply.envelopes {
                if let opened = try? FamilyNotebookKeyCrypto.unwrap(envelope, context: source, recipientID: identity.deviceID, agreementKey: identity.agreementKey) {
                    try secrets.write(opened, account: keyAccount(family, source.source.roster), createOnly: false); keys[epoch] = opened; break
                }
            }
        }
        observe(currentState, keys: keys.count)
        guard currentState.ready else {
            // 11/21: an approved person not in the signed roster yet stops
            // writing for everyone (the relay's `ready`); reading goes on with
            // the keys held. Only the approving iPhone can sign them in.
            let unsigned = !Set(currentState.people).isSubset(of: Set(current.roster.members.map(\.personID)))
            return .init(current: current, history: history, keys: keys, ready: false, moreWork: true,
                         readable: keys.count == contexts.count, awaitsMember: unsigned)
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
            do {
                try await post(family: family, action: "key", route: "keys", operation: operationID([intent]), intent: intent,
                    generation: currentState.generation, epoch: current.roster.epoch, payload: wrapped, replaceStale: true)
            } catch FamilyNotebookTransportError.idempotencyConflict {
                // 11/20 (入れ直し): the operation ID is this exact delivery (this
                // roster head, this epoch, this recipient, this signer), and the
                // relay keeps a receipt only for an envelope it accepted. Its
                // first body went with the app's files; HPKE wraps afresh, so
                // the resend differs and the relay answers idempotency_conflict.
                // That envelope was delivered: go on. Nothing new is trusted
                // here, and recipients verify every envelope as before.
            }
            dispatch.index += 1
            try journal.write(GroupWire.encode(dispatch), account: dispatchAccount, createOnly: false)
        }
        observe(currentState, keys: keys.count)
        let complete = keys.count == contexts.count
        return .init(current: current, history: history, keys: keys, ready: currentState.ready && complete,
                     moreWork: !complete || dispatch.index < total, readable: complete)
    }
}

/// 11/19 (機種変更 水準2): the notebook's roster pin of one person, kept in
/// iCloud Keychain next to the person key so a new iPhone of the same person
/// can verify the roster chain from it. Only this person's own iPhones write
/// it; the relay never supplies one.
protocol FamilyNotebookPinSync: Sendable {
    func read(endpoint: String, personID: String, family: UUID) throws -> FamilyNotebookRosterPin?
    func write(_ pin: FamilyNotebookRosterPin, endpoint: String, personID: String) throws
}

/// The record over a store: bound to the endpoint, the person and the family;
/// a newer epoch replaces it, an older or equal one never does.
struct FamilyNotebookStoredPinSync: FamilyNotebookPinSync {
    let store: any GroupSecretStore
    private struct Record: Codable { let version: Int; let endpoint: String; let personID: String; let pin: FamilyNotebookRosterPin }
    static func account(endpoint: String, personID: String, family: UUID) -> String {
        "fnb-pin:" + GroupCanonical.hash(Data((endpoint + "|" + personID + "|" + family.uuidString.lowercased()).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    func read(endpoint: String, personID: String, family: UUID) throws -> FamilyNotebookRosterPin? {
        guard let bytes = try store.read(Self.account(endpoint: endpoint, personID: personID, family: family)) else { return nil }
        let record = try GroupWire.decode(Record.self, bytes)
        guard record.version == 1, record.endpoint == endpoint, record.personID == personID,
              record.pin.familyID == family, record.pin.epoch >= 1, record.pin.hash.count == 32 else {
            throw FamilyNotebookCryptoError.untrusted
        }
        return record.pin
    }
    func write(_ pin: FamilyNotebookRosterPin, endpoint: String, personID: String) throws {
        guard pin.epoch >= 1, pin.hash.count == 32 else { throw FamilyNotebookCryptoError.untrusted }
        if let saved = try? read(endpoint: endpoint, personID: personID, family: pin.familyID), saved.epoch >= pin.epoch { return }
        try store.write(GroupWire.encode(Record(version: 1, endpoint: endpoint, personID: personID, pin: pin)),
                        account: Self.account(endpoint: endpoint, personID: personID, family: pin.familyID), createOnly: false)
    }
}

/// 11/19 (機種変更 水準2): which identity the family notebook uses. The one
/// place this is decided (FamilyNotebookServiceFactory asks here).
enum FamilyNotebookIdentityChoice {
    /// Written by the recovery screen after the person confirmed the notebook:
    /// the recovered person (its root's scope) and the notebooks the recovery
    /// catalog listed for it.
    struct Link: Codable, Equatable, Sendable {
        let version: Int
        let scope: String
        let personID: String
        let familyIDs: [UUID]
    }
    static let linkAccount = "notebook-recovery-link"

    /// The recovered person's identity when it is registered, is the person
    /// the link names, and the catalog listed a notebook; else nil (the
    /// iPhone's usual identity). The link is written only after the person
    /// confirmed the recovery on this iPhone, so the recovered device wins
    /// over a leftover usual device of the same person (11/19: the app
    /// deleted and installed again keeps the old device in the Keychain).
    /// An iPhone whose usual device already is the recovered one keeps it.
    static func recovered(link: Link?, recovered: GroupDeviceIdentity?, usualPersonID: String?,
                          usualDeviceID: String?) -> GroupDeviceIdentity? {
        guard let link, link.version == 1, !link.familyIDs.isEmpty, let recovered, recovered.registered,
              recovered.personPrivateKey != nil, recovered.personID == link.personID,
              let recoveredDeviceID = try? recovered.deviceID,
              usualPersonID != link.personID || usualDeviceID != recoveredDeviceID else { return nil }
        return recovered
    }

    /// The link and the recovered identity from their Keychain stores.
    /// 11/20: `revocations` (the usual identity's store): a recovered device
    /// the relay said was taken off is never picked.
    static func load(links: any GroupSecretStore, recoveryStore: (String) throws -> any GroupSecretStore,
                     usualPersonID: String?, usualDeviceID: String?,
                     revocations: (any GroupSecretStore)? = nil) throws -> GroupDeviceIdentity? {
        guard let bytes = try links.read(linkAccount) else { return nil }
        let link = try GroupWire.decode(Link.self, bytes)
        guard link.scope.utf8.count == 64,
              link.scope.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        let identity = try recoveryStore(link.scope).read("identity").map { try GroupWire.decode(GroupDeviceIdentity.self, $0) }
        if let identity, let revocations, try GroupDeviceRevocation.isMarked(identity, in: revocations) { return nil }
        return recovered(link: link, recovered: identity, usualPersonID: usualPersonID, usualDeviceID: usualDeviceID)
    }

    /// 11/20: the link goes when the recovered device it names is `pair`.
    static func forgetLink(links: any GroupSecretStore, pair: GroupDeviceRevocation.Pair,
                           recoveryStore: (String) throws -> any GroupSecretStore) throws {
        guard let bytes = try links.read(linkAccount), let link = try? GroupWire.decode(Link.self, bytes),
              link.personID == pair.personID,
              link.scope.utf8.count == 64,
              link.scope.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let saved = try recoveryStore(link.scope).read("identity"),
              (try? GroupWire.decode(GroupDeviceIdentity.self, saved).deviceID) == pair.deviceID else { return }
        try links.remove(linkAccount)
    }

    // The notebook row of the recovery screen (GroupRecoveryLiveModel.notebookSteps),
    // over the stores it is given: the app passes its Keychain namespaces, the
    // two-device test (ci/two-device) in-memory ones.

    /// This iPhone linked this person's notebook (one of `familyIDs`).
    static func isLinked(links: any GroupSecretStore, scope: String, personID: String, familyIDs: [UUID]) throws -> Bool {
        guard let bytes = try links.read(linkAccount) else { return false }
        let link = try GroupWire.decode(Link.self, bytes)
        return link.scope == scope && link.personID == personID && !Set(link.familyIDs).isDisjoint(with: familyIDs)
    }

    /// The identity kept in the root's own store is registered.
    static func recoveredRegistered(_ recovery: any GroupSecretStore) throws -> Bool {
        try recovery.read("identity").map { try GroupWire.decode(GroupDeviceIdentity.self, $0).registered } ?? false
    }

    /// 続ける: a まど being recovered registers this iPhone as the person; with
    /// none, `register` does it with the person key (the usual registration,
    /// over `recovery`). Then the link, which FamilyNotebookIdentityChoice reads.
    static func confirmLink(links: any GroupSecretStore, recovery: any GroupSecretStore, scope: String, personID: String,
                            familyIDs: [UUID], hasWindows: Bool, register: () async throws -> Void) async throws {
        if !hasWindows, try !recoveredRegistered(recovery) { try await register() }
        let link = Link(version: 1, scope: scope, personID: personID, familyIDs: familyIDs)
        try links.write(GroupWire.encode(link), account: linkAccount, createOnly: false)
    }
}

/// 11/20: 「通報への返答」 shows only on an iPhone that sent a family photo
/// report (a UserDefaults flag), but the relay answers replies by person.
/// Without the flag (機種変更, or deleting the app, which wipes UserDefaults)
/// the notebook asks once when it opens, so a report sent before still finds
/// its reply. "None" is remembered for the process (`checkedNone`), so an
/// iPhone that never reported reads once per launch, not on every open.
enum FamilyReportRepliesDiscovery {
    enum Outcome: Equatable { case skipped, found, noReplies, failed }
    static func shouldRead(flagSet: Bool, checkedNone: Bool, notebookLoaded: Bool, gateOpen: Bool) -> Bool {
        !flagSet && !checkedNone && notebookLoaded && gateOpen
    }
    /// `found`: set the flag. `noReplies`: remember it for the process. `failed`:
    /// the next open asks again.
    @MainActor static func discover(flagSet: Bool, checkedNone: Bool, notebookLoaded: Bool, gateOpen: Bool,
                         hasReplies: () async throws -> Bool) async -> Outcome {
        guard shouldRead(flagSet: flagSet, checkedNone: checkedNone, notebookLoaded: notebookLoaded, gateOpen: gateOpen)
        else { return .skipped }
        guard let found = try? await hasReplies() else { return .failed }
        return found ? .found : .noReplies
    }
}

/// 11/20: the family entries this iPhone chose not to show (「表示しない」).
/// The screens read UserDefaults (`defaultsKey`); a copy is kept in this
/// iPhone's device-only Keychain, as the remembered name is
/// (GroupRememberedName), so deleting the app does not show them again.
enum FamilyHiddenOperationsMemory {
    static let defaultsKey = "family.hiddenOperations.v1"
    static let account = "family-hidden-operations.v1"
    /// After GroupWindowClientProvider.namespace.
    static let namespaceSuffix = ".family-hidden"
    static func memory(defaults: @escaping () -> String?, setDefaults: @escaping (String) -> Void,
                       keychain: @escaping () -> (any GroupSecretStore)?) -> GroupRememberedName {
        GroupRememberedName(defaults: defaults, setDefaults: setDefaults, keychain: keychain, account: account)
    }
    static func ids(_ text: String) -> Set<String> { Set(text.split(separator: ",").map(String.init)) }
    static func text(_ ids: Set<String>) -> String { ids.sorted().joined(separator: ",") }
}

/// 11/20: the person's answers to 「同じ子ですか」 (FamilyNotebookCatLink.answerKey
/// per family cat). The screens read UserDefaults (`defaultsKey`, a sorted
/// array); a copy is kept in this iPhone's device-only Keychain, as
/// FamilyHiddenOperationsMemory is, so deleting the app does not ask again.
///
/// Only answers that left no link are kept there (「べつの子」, and
/// 「つながりを外す」): a 「同じ子」 link is this iPhone's local mapping, which
/// deleting the app removes with Application Support, so that cat is asked
/// about again and can be linked again. A Keychain failure leaves UserDefaults
/// as it was. Bound: the newest `limit` keys (the oldest is dropped first).
struct FamilyCatLinkAnswersMemory {
    static let defaultsKey = "familyNotebook.catLinkAnswered.v1"
    static let account = "family-cat-link-answers.v1"
    /// After GroupWindowClientProvider.namespace.
    static let namespaceSuffix = ".family-cat-links"
    static let limit = 200

    let defaults: () -> [String]?
    let setDefaults: ([String]) -> Void
    let keychain: () -> (any GroupSecretStore)?

    static func keys(_ data: Data?) -> [String] {
        guard let data, let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: ",").map(String.init)
    }

    /// Once per process (`checked`), when the questions are worked out after a
    /// read. UserDefaults empty (the app deleted and installed again): the
    /// kept answers come back. Otherwise answers from an install before the
    /// copy for which `keeps` holds (no link) are added to it once.
    @discardableResult
    func restore(checked: inout Bool, keeps: (String) -> Bool) -> [String] {
        let saved = defaults() ?? []
        guard !checked else { return saved }
        checked = true
        guard let store = keychain() else { return saved }
        let data: Data?
        do { data = try store.read(Self.account) } catch { return saved }
        let kept = Self.keys(data)
        if saved.isEmpty {
            guard !kept.isEmpty else { return [] }
            let restored = Array(Set(kept)).sorted()
            setDefaults(restored)
            return restored
        }
        let missing = saved.filter { !kept.contains($0) && keeps($0) }
        if !missing.isEmpty { keep(kept + missing, in: store, previous: data) }
        return saved
    }

    /// The person's answer for `key` (written once per answer, never while
    /// drawing). `linked`: 「同じ子」, kept in UserDefaults only and taken out
    /// of the Keychain copy.
    func remember(_ key: String, linked: Bool) {
        var saved = defaults() ?? []
        if !saved.contains(key) { saved.append(key); setDefaults(saved.sorted()) }
        guard let store = keychain() else { return }
        let data: Data?
        do { data = try store.read(Self.account) } catch { return }
        var kept = Self.keys(data).filter { $0 != key }
        if !linked { kept.append(key) }
        keep(kept, in: store, previous: data)
    }

    /// Writes only a changed list; empty removes the item.
    private func keep(_ keys: [String], in store: any GroupSecretStore, previous: Data?) {
        let bounded = Array(keys.suffix(Self.limit))
        if bounded.isEmpty {
            if previous != nil { try? store.remove(Self.account) }
            return
        }
        let next = Data(bounded.joined(separator: ",").utf8)
        guard next != previous else { return }
        try? store.write(next, account: Self.account, createOnly: false)
    }
}

/// The iCloud Keychain item of the pin: synchronizable, with the same access
/// class and group as the person key's item (available while unlocked).
struct FamilyNotebookSyncedKeychainStore: GroupSecretStore {
    let service: String
    let accessGroup: String?
    private func query(_ account: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecAttrSynchronizable as String: true]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }
    func read(_ account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw FamilyNotebookTransportError.unavailable }
        return data
    }
    func write(_ data: Data, account: String, createOnly: Bool) throws {
        var request = query(account)
        request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        request[kSecValueData as String] = data
        let status = SecItemAdd(request as CFDictionary, nil)
        if status == errSecDuplicateItem, !createOnly {
            guard SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess
            else { throw FamilyNotebookTransportError.unavailable }
            return
        }
        guard status == errSecSuccess else { throw FamilyNotebookTransportError.unavailable }
    }
    func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw FamilyNotebookTransportError.unavailable }
    }
}

/// 11/20: this iPhone's sharing state for one group namespace that is not
/// the person's own records: recovered devices (機種変更), family notebook
/// copies and the Keychain copies of the person's choices. Used by
/// 「まどと家族の手帳のデータを消す」 (GroupIdentityDeletionLocalData) and the
/// owner's trial reset. Every step is tried; a failure is reported at the
/// end, so running it again finishes what is left.
struct FamilySharingLocalData {
    /// GroupWindowClientProvider.namespace.
    let namespace: String
    /// Application Support.
    let support: URL
    /// The device-only store of one namespace (GroupKeychainStore(namespace:)).
    let store: (String) throws -> any GroupSecretStore
    /// The namespaces with an item that start with a prefix (GroupKeychainStore.namespaces).
    let namespaces: (String) throws -> [String]

    /// The notebook scope the provider (FamilyNotebookServiceFactory.make)
    /// gives an identity: its Application Support folder and `.family.` store.
    static func notebookScope(endpoint: URL, personID: String, deviceID: String) throws -> String {
        try GroupWire.base64(GroupCanonical.hash(GroupCanonical.fields([
            Data(endpoint.absoluteString.utf8), Data(personID.utf8), Data(deviceID.utf8)])))
    }
    static func validNotebookScope(_ scope: String) -> Bool {
        scope.utf8.count == 43 && scope.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
    /// The hex of a recovered person's root (`.recovery.<scope>`).
    static func validRecoveryScope(_ scope: String) -> Bool {
        scope.utf8.count == 64 && scope.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func clear(_ store: any GroupSecretStore) throws {
        for account in try store.accounts(prefix: "") { try store.remove(account) }
    }
    private func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// One notebook copy: its folder (the notebook, its journal and photo
    /// cache) first, then its Keychain (trust pin, epoch keys, invitations),
    /// which a second run uses to find the folder again.
    func forgetNotebook(scope: String) throws {
        guard Self.validNotebookScope(scope) else { throw GroupClientError.invalidResponse }
        try removeIfPresent(support.appendingPathComponent("FamilyNotebook-v1", isDirectory: true)
            .appendingPathComponent(scope, isDirectory: true))
        try Self.clear(store(namespace + ".family." + scope))
    }

    /// One recovered device on this iPhone: its notebook copy, its recovery
    /// Keychain and journal, and its outbox.
    func forgetRecoveredDevice(scope: String, endpoint: URL) throws {
        guard Self.validRecoveryScope(scope) else { throw GroupClientError.invalidResponse }
        var failure: Error?
        func attempt(_ step: () throws -> Void) {
            do { try step() } catch { if failure == nil { failure = error } }
        }
        let recovery = try store(namespace + ".recovery." + scope)
        attempt {
            if let saved = try recovery.read("identity") {
                let identity = try GroupWire.decode(GroupDeviceIdentity.self, saved)
                // The same scope the provider gives that device's notebook.
                try forgetNotebook(scope: Self.notebookScope(endpoint: endpoint, personID: identity.personID,
                                                             deviceID: identity.deviceID))
            }
        }
        let journal = try store(namespace + ".recovery-journal." + scope)
        for item in [recovery, journal] { attempt { try Self.clear(item) } }
        attempt {
            try removeIfPresent(support.appendingPathComponent("GroupTransport-v3", isDirectory: true)
                .appendingPathComponent("recovery-" + scope, isDirectory: true))
        }
        if let failure { throw failure }
    }

    /// What the clean-up after an accepted identity deletion did.
    struct DeletionCleanup: Equatable {
        /// Every step it took went.
        var complete = true
        /// Another person's identity may still be in use on this iPhone (a
        /// recovered device of another person, its recovery link, or nothing
        /// known about the deleted one): the copies every identity here shares
        /// (removeSharedCopies) stay.
        var otherIdentityRemains = false
    }

    /// A person's recovery scope (`.recovery.<scope>`): the hex of the hash
    /// its person ID is the base64 of.
    static func recoveryScope(personID: String) -> String? {
        guard let bytes = try? GroupWire.bytes(personID, count: 32) else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The notebook copies that provably are the deleted person's: the one of
    /// its device `deviceID`, and the one of its recovered device on this
    /// iPhone (機種変更), if there is one.
    func notebookScopes(endpoint: URL, personID: String, deviceID: String?) -> Set<String> {
        var result = Set<String>()
        if let deviceID, let scope = try? Self.notebookScope(endpoint: endpoint, personID: personID, deviceID: deviceID) {
            result.insert(scope)
        }
        if let scope = Self.recoveryScope(personID: personID),
           let saved = try? store(namespace + ".recovery." + scope).read("identity"),
           let identity = try? GroupWire.decode(GroupDeviceIdentity.self, saved), identity.personID == personID,
           let notebook = try? Self.notebookScope(endpoint: endpoint, personID: personID, deviceID: identity.deviceID) {
            result.insert(notebook)
        }
        return result
    }

    /// After the relay accepted the deletion of the person `personID` (its
    /// device `deviceID`): only what provably is that person's. The notebook's
    /// recovery link when it names that person (first, so the notebook stops
    /// opening that identity), that person's recovered device (its recovery
    /// scope), and the notebook copies of notebookScopes. Another person's
    /// recovered device, its link and notebook copy, and a notebook copy that
    /// cannot be told to be the deleted person's stay. nil `personID` (a
    /// record from before 11/20): nothing is removed here.
    func removeAfterIdentityDeletion(endpoint: URL, personID: String?, deviceID: String?,
                                     linkSuffix: String) -> DeletionCleanup {
        var result = DeletionCleanup()
        guard let personID, let deleted = Self.recoveryScope(personID: personID) else {
            result.otherIdentityRemains = true
            return result
        }
        let notebooks = notebookScopes(endpoint: endpoint, personID: personID, deviceID: deviceID)
        do {
            let links = try store(namespace + linkSuffix)
            if let bytes = try links.read(FamilyNotebookIdentityChoice.linkAccount) {
                if let link = try? GroupWire.decode(FamilyNotebookIdentityChoice.Link.self, bytes),
                   link.personID == personID || link.scope == deleted {
                    try links.remove(FamilyNotebookIdentityChoice.linkAccount)
                } else { result.otherIdentityRemains = true }
            }
        } catch { result.complete = false; result.otherIdentityRemains = true }
        var scopes = Set<String>()
        for suffix in [".recovery.", ".recovery-journal."] {
            let prefix = namespace + suffix
            do {
                scopes.formUnion(try namespaces(prefix).filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
            } catch { result.complete = false; result.otherIdentityRemains = true }
        }
        for scope in scopes.sorted() {
            guard scope == deleted else { result.otherIdentityRemains = true; continue }
            do { try forgetRecoveredDevice(scope: scope, endpoint: endpoint) } catch { result.complete = false }
        }
        for scope in notebooks.sorted() {
            do { try forgetNotebook(scope: scope) } catch { result.complete = false }
        }
        return result
    }

    /// The copies every identity on this iPhone shares, by namespace suffix
    /// and account prefix ("": all). Only when no other identity remains
    /// (DeletionCleanup.otherIdentityRemains). Returns whether every step went.
    func removeSharedCopies(_ choices: [(suffix: String, prefix: String)]) -> Bool {
        var complete = true
        for choice in choices {
            do {
                let kept = try store(namespace + choice.suffix)
                for account in try kept.accounts(prefix: choice.prefix) { try kept.remove(account) }
            } catch { complete = false }
        }
        return complete
    }
}
