import CryptoKit
import Foundation

private enum Failure: Error { case check(String) }
private func check(_ value: Bool, _ message: String) throws { if !value { throw Failure.check(message) } }
private func rejects(_ message: String, _ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw Failure.check(message)
}
private struct Person {
    let id: String
    let root = Curve25519.Signing.PrivateKey()
    let deviceID: String
    let signing = Curve25519.Signing.PrivateKey()
    let agreement = Curve25519.KeyAgreement.PrivateKey()
    func member(_ family: UUID) throws -> FamilyNotebookCryptoMember {
        let device = GroupRosterDevice(id: deviceID, signingPublicKey: signing.publicKey.rawRepresentation,
            hpkePublicKey: agreement.publicKey.rawRepresentation, personAuthorization: Data())
        let signed = GroupRosterDevice(id: deviceID, signingPublicKey: device.signingPublicKey, hpkePublicKey: device.hpkePublicKey,
            personAuthorization: try root.signature(for: device.authorizationBytes(windowID: family.uuidString.lowercased(), personID: id)))
        return .init(personID: id, identityPublicKey: root.publicKey.rawRepresentation, devices: [signed])
    }
}

@main
private enum VerifyFamilyNotebookCrypto {
    static let family = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let cat = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let target = FamilyNotebookTarget(familyCatID: cat, field: .name)
    static func operation(_ person: Person, clock: UInt64 = 1, observed: [UUID] = [], value: String = "合成のねこ") -> FamilyNotebookOperation {
        .init(familyID: family, target: target, value: .text(value),
            version: .init(clock: clock, deviceID: person.deviceID, operationID: UUID()),
            author: .init(personID: person.id, displayName: "合成の家族"), editedAt: Date(timeIntervalSince1970: 1_793_232_000),
            observedOperationIDs: observed)
    }
    static func main() throws {
        let a = Person(id: "person-a", deviceID: "device-a"), b = Person(id: "person-b", deviceID: "device-b")
        let ma = try a.member(family), mb = try b.member(family)
        let key1 = Data(repeating: 1, count: 32), key2 = Data(repeating: 2, count: 32), key3 = Data(repeating: 3, count: 32)
        let roster1 = FamilyNotebookCryptoRoster(familyID: family, epoch: 1, previousHash: Data(repeating: 0, count: 32),
            keyCommitment: GroupCanonical.hash(key1), members: [ma])
        let p1 = try FamilyNotebookRosterCrypto.sign(roster1, deviceID: a.deviceID, signingKey: a.signing)
        let r1 = try FamilyNotebookRosterCrypto.restore(p1,
            trustedPin: .init(familyID: family, epoch: 1, hash: GroupCanonical.hash(roster1.canonicalBytes())))
        let oldOperation = operation(a)
        let encrypted = try FamilyNotebookOperationCrypto.seal(oldOperation, roster: r1, key: key1, signingKey: a.signing)
        try check(try FamilyNotebookOperationCrypto.open(encrypted, roster: r1, key: key1) == oldOperation, "operation roundtrip")
        let roster2 = FamilyNotebookCryptoRoster(familyID: family, epoch: 2, previousHash: r1.hash,
            keyCommitment: GroupCanonical.hash(key2), members: [mb, ma])
        let p2 = try FamilyNotebookRosterCrypto.sign(roster2, deviceID: a.deviceID, signingKey: a.signing)
        let r2 = try FamilyNotebookRosterCrypto.advance(p2, previous: r1)
        let oldContext = try FamilyNotebookKeyContext.current(r2).previous(p1)
        let envelope = try FamilyNotebookKeyCrypto.wrap(key1, context: oldContext, recipientID: b.deviceID, signerID: a.deviceID, signingKey: a.signing)
        let recovered = try FamilyNotebookKeyCrypto.unwrap(envelope, context: oldContext, recipientID: b.deviceID, agreementKey: b.agreement)
        try check(try FamilyNotebookOperationCrypto.open(encrypted, roster: oldContext.source, key: recovered) == oldOperation,
                  "newly admitted member reads authenticated complete old history")
        let roster3 = FamilyNotebookCryptoRoster(familyID: family, epoch: 3, previousHash: r2.hash,
            keyCommitment: GroupCanonical.hash(key3), members: [mb])
        let p3 = try FamilyNotebookRosterCrypto.sign(roster3, deviceID: b.deviceID, signingKey: b.signing)
        let r3 = try FamilyNotebookRosterCrypto.advance(p3, previous: r2)
        let current = FamilyNotebookKeyContext.current(r3)
        let ownEnvelope = try FamilyNotebookKeyCrypto.wrap(key3, context: current, recipientID: b.deviceID, signerID: b.deviceID, signingKey: b.signing)
        try check(try FamilyNotebookKeyCrypto.unwrap(ownEnvelope, context: current, recipientID: b.deviceID, agreementKey: b.agreement) == key3,
                  "retained member continues without former payer's private keys")
        try rejects("departed member receives no next key") {
            _ = try FamilyNotebookKeyCrypto.wrap(key3, context: current, recipientID: a.deviceID, signerID: b.deviceID, signingKey: b.signing)
        }
        try rejects("departed signer") {
            _ = try FamilyNotebookKeyCrypto.wrap(key3, context: current, recipientID: b.deviceID, signerID: a.deviceID, signingKey: a.signing)
        }
        try rejects("wrong agreement key") {
            _ = try FamilyNotebookKeyCrypto.unwrap(envelope, context: oldContext, recipientID: b.deviceID, agreementKey: a.agreement)
        }
        try rejects("cross-generation envelope") {
            _ = try FamilyNotebookKeyCrypto.unwrap(envelope, context: current, recipientID: b.deviceID, agreementKey: b.agreement)
        }
        try rejects("wrong epoch key") { _ = try FamilyNotebookOperationCrypto.open(encrypted, roster: r1, key: key2) }
        try rejects("wrong signing author") { _ = try FamilyNotebookOperationCrypto.seal(operation(b), roster: r1, key: key1, signingKey: a.signing) }
        try rejects("roster rollback") { _ = try FamilyNotebookRosterCrypto.restore(p1, trustedPin: r2.pin) }
        try rejects("backward chain must not skip epochs") { _ = try current.previous(p1) }
        let fork = FamilyNotebookCryptoRoster(familyID: family, epoch: 1, previousHash: Data(repeating: 0, count: 32),
            keyCommitment: GroupCanonical.hash(key3), members: [ma])
        let forkPacket = try FamilyNotebookRosterCrypto.sign(fork, deviceID: a.deviceID, signingKey: a.signing)
        try rejects("independently signed old fork") { _ = try FamilyNotebookKeyContext.current(r2).previous(forkPacket) }
        let reused = FamilyNotebookCryptoRoster(familyID: family, epoch: 3, previousHash: r2.hash,
            keyCommitment: roster2.keyCommitment, members: [mb])
        try rejects("membership transition requires fresh key") {
            _ = try FamilyNotebookRosterCrypto.advance(FamilyNotebookRosterCrypto.sign(reused, deviceID: b.deviceID, signingKey: b.signing), previous: r2)
        }
        let replacement = Person(id: a.id, deviceID: "replacement-device")
        let replaced = FamilyNotebookCryptoRoster(familyID: family, epoch: 3, previousHash: r2.hash,
            keyCommitment: GroupCanonical.hash(key3), members: [try replacement.member(family), mb])
        try rejects("relay must not replace retained person's root") {
            _ = try FamilyNotebookRosterCrypto.advance(FamilyNotebookRosterCrypto.sign(replaced, deviceID: b.deviceID, signingKey: b.signing), previous: r2)
        }
        let wrongFamily = FamilyNotebookCryptoRoster(familyID: UUID(), epoch: 1, previousHash: Data(repeating: 0, count: 32),
            keyCommitment: GroupCanonical.hash(key1), members: [ma])
        try rejects("device certificate is family-bound") { _ = try wrongFamily.canonicalBytes() }
        try tampering(encrypted, envelope: envelope, roster: r1, context: oldContext, key: key1, person: b)
        try frontier(a, b)

        // Public synthetic fixture only: the fixed test key encrypts invented
        // data above. No identity private keys or application files are read.
        struct Vector: Encodable { let packet: SignedFamilyNotebookRoster; let hash: Data; let operation: EncryptedFamilyNotebookOperation }
        print(String(decoding: try GroupWire.encode(Vector(packet: p1, hash: r1.hash, operation: encrypted)), as: UTF8.self))
    }
    static func tampering(_ operation: EncryptedFamilyNotebookOperation, envelope: FamilyNotebookKeyEnvelope,
                          roster: VerifiedFamilyNotebookRoster, context: FamilyNotebookKeyContext, key: Data, person: Person) throws {
        let operationJSON = try JSONSerialization.jsonObject(with: GroupWire.encode(operation)) as! [String: Any]
        for (field, value) in ["signature": GroupWire.base64(Data(repeating: 0, count: 64)),
                               "ciphertext": GroupWire.base64(Data(repeating: 0, count: operation.ciphertext.count)),
                               "operationId": UUID().uuidString, "personId": person.id] {
            var json = operationJSON; json[field] = value
            let bad = try GroupWire.decode(EncryptedFamilyNotebookOperation.self, JSONSerialization.data(withJSONObject: json))
            try rejects("operation tamper " + field) { _ = try FamilyNotebookOperationCrypto.open(bad, roster: roster, key: key) }
        }
        let envelopeJSON = try JSONSerialization.jsonObject(with: GroupWire.encode(envelope)) as! [String: Any]
        for (field, value) in ["signature": GroupWire.base64(Data(repeating: 0, count: 64)),
                               "recipientRosterHash": GroupWire.base64(Data(repeating: 0, count: 32)),
                               "recipientDeviceId": "outsider", "ciphertext": GroupWire.base64(Data(repeating: 0, count: 48))] {
            var json = envelopeJSON; json[field] = value
            let bad = try GroupWire.decode(FamilyNotebookKeyEnvelope.self, JSONSerialization.data(withJSONObject: json))
            try rejects("envelope tamper " + field) {
                _ = try FamilyNotebookKeyCrypto.unwrap(bad, context: context, recipientID: person.deviceID, agreementKey: person.agreement)
            }
        }
    }
    static func frontier(_ a: Person, _ b: Person) throws {
        var history: [FamilyNotebookOperation] = []
        for index in 1...3_000 {
            history.append(operation(a, clock: UInt64(index), observed: history.last.map { [$0.id] } ?? [], value: "edit-\(index)"))
        }
        let concurrent = operation(b, clock: 3_000, observed: [history[2_998].id], value: "concurrent")
        history.append(concurrent)
        try check(FamilyNotebookCore.resolve(target: target, operations: history)?.status == .conflict, "concurrent edit remains visible")
        let frontier = FamilyNotebookCore.observedFrontier(target: target, operations: history)
        try check(frontier.count == 2, "three thousand edits produce two concurrent frontier IDs")
        let resolved = operation(a, clock: 3_001, observed: frontier, value: "resolved")
        history = try FamilyNotebookCore.merge(history, [resolved])
        let state = FamilyNotebookCore.resolve(target: target, operations: history)!
        try check(history.count == 3_002 && state.history.count == 3_001 && state.status != .conflict,
                  "transitive frontier resolves conflict without deleting history")
        try check(FamilyNotebookCore.observedFrontier(target: target, operations: history) == [resolved.id], "one new frontier")
    }
}
