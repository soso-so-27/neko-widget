import CryptoKit
import Foundation

private enum Failure: Error { case check(String), lost }
private func check(_ value: Bool, _ message: String) throws {
    if !value { print("Synthetic key relay check failed: " + message); throw Failure.check(message) }
}
private func rejected(_ work: () async throws -> Void) async throws {
    do { try await work() } catch { return }
    throw Failure.check("expected rejection")
}
private actor Relay: GroupHTTPTransport {
    let family: UUID
    var identities: [String: GroupDeviceIdentity] = [:], members = Set<String>(), certificates: [String: GroupRosterDevice] = [:]
    var generation: Int64 = 1, head: VerifiedFamilyNotebookRoster?, history: [Int: SignedFamilyNotebookRoster] = [:]
    var envelopes: [String: FamilyNotebookKeyEnvelope] = [:], receipts: [String: (Data, Data)] = [:]
    var loseRoster = false, rejectRoster = false, loseKey = false, sentKeys: [FamilyNotebookKeyEnvelope] = []
    init(family: UUID, creator: GroupDeviceIdentity) throws { self.family = family; identities[try creator.deviceID] = creator; members.insert(creator.personID) }
    func loseNextRoster() { loseRoster = true }
    func rejectNextRoster() { rejectRoster = true }
    func loseNextKey() { loseKey = true }
    func admit(_ identity: GroupDeviceIdentity, certified: Bool = false) throws {
        identities[try identity.deviceID] = identity; members.insert(identity.personID); generation += 1
        if certified { certificates[try identity.deviceID] = try identity.certificate(windowID: family.uuidString.lowercased()) }
    }
    func remove(_ identity: GroupDeviceIdentity) { members.remove(identity.personID); generation += 1 }
    func epoch() -> Int { head?.roster.epoch ?? 0 }
    func delivered() -> [FamilyNotebookKeyEnvelope] { sentKeys }
    func isReady() -> Bool {
        guard let roster = head?.roster, Set(roster.members.map(\.personID)) == members else { return false }
        return Set(roster.members.flatMap(\.devices).map(\.id)) == Set(certificates.keys.filter { members.contains(identities[$0]!.personID) })
    }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        let deviceID = request.value(forHTTPHeaderField: "Neko-Device-Id")!, identity = identities[deviceID]!
        let path = request.url!.path, body = request.httpBody ?? Data(), method = request.httpMethod!
        let transcript = try GroupCanonical.fields(["NW3.REQUEST", "3", deviceID, request.value(forHTTPHeaderField: "Neko-Timestamp")!,
            request.value(forHTTPHeaderField: "Neko-Nonce")!, method, path].map(GroupCanonical.text) + [GroupCanonical.hash(body)])
        try check(try identity.signingKey.publicKey.isValidSignature(GroupWire.bytes(request.value(forHTTPHeaderField: "Neko-Signature")!, count: 64), for: transcript), "actual signature")
        func reply(_ object: [String: Any], _ status: Int = 200) throws -> GroupHTTPReply { .init(status: status, data: try JSONSerialization.data(withJSONObject: object)) }
        func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: GroupWire.encode(value)) }
        func failure(_ code: String, _ status: Int) throws -> GroupHTTPReply { try reply(["error": ["code": code]], status) }
        if method == "GET" {
            guard members.contains(identity.personID) else { return try failure("not_found", 404) }
            var result: [String: Any] = ["schemaVersion": 1, "familyId": family.uuidString.lowercased(), "generation": generation, "currentEpoch": head?.roster.epoch ?? 0]
            let last = path.split(separator: "/").last!.description
            if last == "state" {
                result["roster"] = try head.map { try object($0.packet) } ?? NSNull()
                result["people"] = members.sorted(); result["ready"] = isReady()
                result["devices"] = certificates.keys.sorted().filter { members.contains(identities[$0]!.personID) }.map { id in
                    let who = identities[id]!, cert = certificates[id]!
                    return ["person_id": who.personID, "device_id": id, "identity_public_key": GroupWire.base64(who.personPublicKey),
                        "signing_public_key": GroupWire.base64(cert.signingPublicKey), "hpke_public_key": GroupWire.base64(cert.hpkePublicKey), "person_authorization": GroupWire.base64(cert.personAuthorization)]
                }
            } else if path.contains("/rosters/"), let epoch = Int(last), let packet = history[epoch] { result["roster"] = try object(packet) }
            else if path.contains("/keys/"), let epoch = Int(last) {
                result["envelopes"] = try envelopes.values.filter { $0.recipientDeviceID == deviceID && $0.keyEpoch == epoch && $0.recipientRosterHash == head?.hash }.map { try object($0) }
            } else { return try failure("not_found", 404) }
            return try reply(result)
        }
        let value = try JSONSerialization.jsonObject(with: body) as! [String: Any], op = value["operationId"] as! String
        let receiptKey = deviceID + ":" + op
        if let saved = receipts[receiptKey] { try check(saved.0 == body, "durable resend uses exact ciphertext"); return .init(status: 200, data: saved.1) }
        guard members.contains(identity.personID) else { return try failure("not_found", 404) }
        let expectedEpoch = (value["expectedEpoch"] as! NSNumber).intValue
        guard (value["expectedGeneration"] as! NSNumber).int64Value == generation, expectedEpoch == (head?.roster.epoch ?? 0) else { return try failure("family_notebook_crypto_stale", 409) }
        let payload = try JSONSerialization.data(withJSONObject: value["payload"]!), action: String
        if path.hasSuffix("/devices") {
            action = "device"; let certificate = try identity.certificate(windowID: family.uuidString.lowercased())
            let authorization = (value["payload"] as! [String: Any])["personAuthorization"] as! String
            try check(authorization == GroupWire.base64(certificate.personAuthorization), "family-scoped device root authorization")
            certificates[deviceID] = certificate
        } else if path.hasSuffix("/rosters") {
            if rejectRoster { rejectRoster = false; return try failure("family_notebook_crypto_stale", 409) }
            action = "roster"
            let packet = try GroupWire.decode(SignedFamilyNotebookRoster.self, payload)
            let verified: VerifiedFamilyNotebookRoster
            if let old = head { verified = try FamilyNotebookRosterCrypto.advance(packet, previous: old) }
            else { verified = try FamilyNotebookRosterCrypto.restore(packet, trustedPin: .init(familyID: family, epoch: 1, hash: GroupCanonical.hash(packet.roster.canonicalBytes()))) }
            try check(Set(verified.roster.members.map(\.personID)) == members, "complete actual membership in roster")
            head = verified; history[verified.roster.epoch] = packet
        } else if path.hasSuffix("/keys") {
            action = "key"; let packet = try GroupWire.decode(FamilyNotebookKeyEnvelope.self, payload)
            try check(isReady() && packet.recipientRosterHash == head?.hash, "keys use ready current roster")
            envelopes["\(expectedEpoch):\(packet.keyEpoch):\(packet.recipientDeviceID):\(packet.signerDeviceID)"] = packet
            sentKeys.append(packet)
        } else { throw Failure.check("unexpected route") }
        let result = try reply(["schemaVersion": 1, "familyId": family.uuidString.lowercased(), "operationId": op, "action": action,
            "appliedEpoch": head?.roster.epoch ?? 0, "requestHash": GroupWire.base64(FamilyNotebookTransport.requestHash(path: path, body: body))])
        receipts[receiptKey] = (body, result.data)
        if action == "roster" && loseRoster { loseRoster = false; throw Failure.lost }
        if action == "key" && loseKey { loseKey = false; throw Failure.lost }
        return result
    }
}

@main private enum VerifyFamilyNotebookKeyDelivery {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("family-keys-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var a = GroupDeviceIdentity.firstDevice(), b = GroupDeviceIdentity.firstDevice(), c = GroupDeviceIdentity.firstDevice()
        a.registered = true; b.registered = true; c.registered = true
        let family = UUID(), relay = try Relay(family: family, creator: a), endpoint = URL(string: "https://family.invalid")!
        func coordinator(_ who: GroupDeviceIdentity) throws -> FamilyNotebookKeyCoordinator {
            let folder = directory.appendingPathComponent(who.personID)
            let journal = try GroupOperationStore(directory: folder.appendingPathComponent("journal"), maximumRecordBytes: 2_100_000)
            // Synthetic keys only. Production uses the separate Keychain.
            let secrets = try GroupOperationStore(directory: folder.appendingPathComponent("synthetic-secrets"))
            return try .init(endpoint: endpoint, identity: who, network: .init(endpoint: endpoint, identity: who, transport: relay, journal: journal), secrets: secrets, journal: journal)
        }
        let first = try coordinator(a)
        print("Key delivery stage: create and lost roster ACK")
        try await first.registerCreatedFamily(family)
        await relay.loseNextRoster()
        try await rejected { _ = try await first.prepare(family: family) }
        let restarted = try coordinator(a)
        print("Key delivery stage: restart creator")
        guard let original = try await restarted.prepare(family: family), original.ready else { throw Failure.check("creator restart failed") }
        try check(await relay.epoch() == 1, "lost roster ACK never creates a second epoch")
        let now = Date(), (capability, cipher) = try FamilyNotebookInvitationCrypto.create(roster: original.current, generation: 1, identity: a,
            payerPersonID: a.personID, invitationID: UUID(), inviterName: "synthetic", catNames: [], now: now)
        let invitation = try FamilyNotebookInvitationCrypto.open(cipher, capability: capability, serverInviterPersonID: a.personID,
            serverInviterDeviceID: a.deviceID, serverGeneration: 1, serverExpiresAt: Int64(now.timeIntervalSince1970) + 86400, now: now)
        let newcomer = try coordinator(b)
        print("Key delivery stage: admit and register newcomer")
        try await newcomer.registerInvitation(invitation); try await relay.admit(b)
        _ = try await newcomer.prepare(family: family) // Register own certificate, then wait for trusted rotation.
        let beforeApproval = await relay.delivered().count
        _ = try await restarted.prepare(family: family)
        let beforeEpoch = await relay.epoch(), afterUnapproved = await relay.delivered().count
        try check(beforeEpoch == 1 && afterUnapproved == beforeApproval, "relay cannot inject an unapproved person or receive old keys while roster is stale")
        try await restarted.confirmApprovedAddition(family: family, personID: b.personID, identityPublicKey: b.personPublicKey)
        print("Key delivery stage: approved rotation")
        _ = try await restarted.prepare(family: family)
        await relay.loseNextKey()
        print("Key delivery stage: lost key ACK and replay")
        try await rejected { _ = try await restarted.prepare(family: family) }
        _ = try await coordinator(a).prepare(family: family)
        print("Key delivery stage: newcomer receives history")
        guard let joined = try await newcomer.prepare(family: family), joined.ready else { throw Failure.check("new member keys unavailable") }
        try check(joined.keys[1] == original.keys[1] && joined.keys[2] != nil && joined.history[1] == original.current.packet, "new member receives verified pre-join key/history plus current key")
        await relay.remove(a)
        print("Key delivery stage: remaining member rotates")
        _ = try await newcomer.prepare(family: family)
        guard let remaining = try await newcomer.prepare(family: family), remaining.ready else { throw Failure.check("remaining member cannot rotate") }
        try check(remaining.current.roster.epoch == 3 && remaining.keys[3] != joined.keys[2], "departure rotates key without old payer")
        let departedID = try a.deviceID, sent = await relay.delivered()
        try check(!sent.contains(where: { $0.recipientRosterHash == remaining.current.hash && $0.recipientDeviceID == departedID }), "departed device never receives current-epoch envelopes")
        try await rejected { _ = try await restarted.prepare(family: family) }
        try await relay.admit(c, certified: true)
        try await newcomer.confirmApprovedAddition(family: family, personID: c.personID, identityPublicKey: c.personPublicKey)
        await relay.rejectNextRoster()
        print("Key delivery stage: rejected candidate and retry")
        try await rejected { _ = try await newcomer.prepare(family: family) }
        _ = try await coordinator(b).prepare(family: family)
        guard let recovered = try await coordinator(b).prepare(family: family), recovered.ready else { throw Failure.check("rejected proposal poisoned the key slot") }
        try check(recovered.current.roster.epoch == 4 && recovered.keys[1] == original.keys[1], "CAS-rejected key is separate from winning key; complete old history remains")
        print("Family notebook key delivery: real HPKE, pinned invitation, durable roster/key retry, explicit admission, pre-join keys, departure rotation and rejected-key isolation passed")
    }
}
