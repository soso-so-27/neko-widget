import CryptoKit
import Foundation

private enum Failure: Error { case check(String) }
private func check(_ value: Bool, _ name: String) throws {
    if !value { throw Failure.check(name) }
}
private func rejects(_ name: String, _ operation: () throws -> Void) throws {
    var rejected = false
    do { try operation() } catch { rejected = true }
    try check(rejected, name)
}
private struct Person {
    let id: String
    let identity = Curve25519.Signing.PrivateKey()
}
private struct Device {
    let id: String
    let signing = Curve25519.Signing.PrivateKey()
    let agreement = Curve25519.KeyAgreement.PrivateKey()
    func rosterDevice(person: Person, window: String = "room-one") throws -> GroupRosterDevice {
        let value = GroupRosterDevice(id: id, signingPublicKey: signing.publicKey.rawRepresentation,
            hpkePublicKey: agreement.publicKey.rawRepresentation, personAuthorization: Data())
        return .init(id: id, signingPublicKey: value.signingPublicKey, hpkePublicKey: value.hpkePublicKey,
            personAuthorization: try person.identity.signature(for: value.authorizationBytes(windowID: window, personID: person.id)))
    }
}

@main
private enum GroupWindowChecks {
    static func main() async throws {
        let a = Person(id: "person-a"), b = Person(id: "person-b"), c = Person(id: "person-c")
        let a1 = Device(id: "a1"), b1 = Device(id: "b1"), b2 = Device(id: "b2"), c1 = Device(id: "c1")
        func member(_ person: Person, _ devices: [Device], owner: Bool = false) throws -> GroupRosterMember {
            .init(participantID: person.id + "-participant", personID: person.id,
                identityPublicKey: person.identity.publicKey.rawRepresentation, role: owner ? .owner : .member,
                devices: try devices.map { try $0.rosterDevice(person: person) })
        }
        let firstMembers = try [member(a, [a1], owner: true), member(b, [b1]), member(c, [c1])]
        let initial = GroupRoster(windowID: "room-one", revision: 1, keyEpoch: 1,
            previousHash: Data(repeating: 0, count: 32), ownerPersonID: a.id, members: firstMembers)
        let anchor = GroupTrustAnchor(windowID: "room-one", ownerPersonID: a.id,
            ownerIdentityPublicKey: a.identity.publicKey.rawRepresentation)
        let packet = try GroupRosterVerifier.sign(initial, deviceID: a1.id, privateKey: a1.signing)
        let one = try GroupRosterVerifier.verify(packet, anchor: anchor)
        let key1 = SymmetricKey(size: .bits256)
        let payload = Data("synthetic-group-photo".utf8)
        let photo = try GroupPhotoCrypto.seal(payload, clientMomentID: "photo-one", senderDeviceID: b1.id,
            roomKey: key1, signingKey: b1.signing, roster: one)
        for device in [a1, b1, c1] {
            let envelope = try GroupHPKE.wrap(roomKey: key1, for: device.id, roster: one, signerID: a1.id, signingKey: a1.signing)
            let recovered = try GroupHPKE.unwrap(envelope, deviceID: device.id, agreementKey: device.agreement, roster: one)
            let clear = try GroupPhotoCrypto.open(photo, roomKey: recovered, roster: one)
            try check(clear == payload, "three-person round trip")
        }
        let bEnvelope = try GroupHPKE.wrap(roomKey: key1, for: b1.id, roster: one, signerID: a1.id, signingKey: a1.signing)
        try rejects("wrong device") { _ = try GroupHPKE.unwrap(bEnvelope, deviceID: c1.id, agreementKey: c1.agreement, roster: one) }
        try rejects("wrong private key") { _ = try GroupHPKE.unwrap(bEnvelope, deviceID: b1.id, agreementKey: c1.agreement, roster: one) }
        let corruptEnvelope = GroupKeyEnvelope(windowID: bEnvelope.windowID, keyEpoch: 1, rosterHash: one.hash,
            deviceID: b1.id, encapsulatedKey: bEnvelope.encapsulatedKey, ciphertext: Data(repeating: 0, count: 48),
            signerDeviceID: a1.id, signature: bEnvelope.signature)
        try rejects("envelope tampering") { _ = try GroupHPKE.unwrap(corruptEnvelope, deviceID: b1.id, agreementKey: b1.agreement, roster: one) }
        try rejects("member may not wrap owner keys") { _ = try GroupHPKE.wrap(roomKey: key1, for: c1.id, roster: one, signerID: b1.id, signingKey: b1.signing) }
        try rejects("wrong owner anchor") {
            _ = try GroupRosterVerifier.verify(packet, anchor: .init(windowID: "room-one", ownerPersonID: a.id,
                ownerIdentityPublicKey: b.identity.publicKey.rawRepresentation))
        }
        let memberSigned = try GroupRosterVerifier.sign(initial, deviceID: b1.id, privateKey: b1.signing)
        try rejects("member roster signature") { _ = try GroupRosterVerifier.verify(memberSigned, anchor: anchor) }
        try rejects("photo impersonation") {
            _ = try GroupPhotoCrypto.seal(payload, clientMomentID: "forged", senderDeviceID: a1.id,
                roomKey: key1, signingKey: b1.signing, roster: one)
        }
        let forged = GroupEncryptedPhoto(clientMomentID: photo.clientMomentID, senderDeviceID: a1.id,
            ciphertext: photo.ciphertext, signature: photo.signature)
        try rejects("sender ID tampering") { _ = try GroupPhotoCrypto.open(forged, roomKey: key1, roster: one) }
        let renamed = GroupEncryptedPhoto(clientMomentID: "other-photo", senderDeviceID: photo.senderDeviceID,
            ciphertext: photo.ciphertext, signature: photo.signature)
        try rejects("photo ID replay") { _ = try GroupPhotoCrypto.open(renamed, roomKey: key1, roster: one) }
        let membersTwo = try [member(a, [a1], owner: true), member(b, [b1, b2]), member(c, [c1])]
        let second = GroupRoster(windowID: "room-one", revision: 2, keyEpoch: 2,
            previousHash: one.hash, ownerPersonID: a.id, members: membersTwo)
        let two = try GroupRosterVerifier.verify(GroupRosterVerifier.sign(second, deviceID: a1.id, privateKey: a1.signing), anchor: anchor, previous: one)
        try check(two.roster.members.count == 3 && two.roster.members.flatMap(\.devices).count == 4, "people and devices separate")
        let noRotation = GroupRoster(windowID: "room-one", revision: 2, keyEpoch: 1,
            previousHash: one.hash, ownerPersonID: a.id, members: membersTwo)
        try rejects("membership change must rotate") {
            _ = try GroupRosterVerifier.verify(GroupRosterVerifier.sign(noRotation, deviceID: a1.id, privateKey: a1.signing), anchor: anchor, previous: one)
        }
        let third = GroupRoster(windowID: "room-one", revision: 3, keyEpoch: 3,
            previousHash: two.hash, ownerPersonID: a.id, members: try [member(a, [a1], owner: true), member(c, [c1])])
        let three = try GroupRosterVerifier.verify(GroupRosterVerifier.sign(third, deviceID: a1.id, privateKey: a1.signing), anchor: anchor, previous: two)
        try check(three.device(id: b1.id) == nil && three.device(id: b2.id) == nil, "remove all devices of one person")
        let key3 = SymmetricKey(size: .bits256)
        try rejects("excluded device cannot receive new envelope") {
            _ = try GroupHPKE.wrap(roomKey: key3, for: b1.id, roster: three, signerID: a1.id, signingKey: a1.signing)
        }
        try rejects("old envelope rejected by new roster") { _ = try GroupHPKE.unwrap(bEnvelope, deviceID: b1.id, agreementKey: b1.agreement, roster: three) }
        let latest = try GroupPhotoCrypto.seal(payload, clientMomentID: "photo-three", senderDeviceID: a1.id,
            roomKey: key3, signingKey: a1.signing, roster: three)
        try rejects("old room key cannot open new photo") { _ = try GroupPhotoCrypto.open(latest, roomKey: key1, roster: three) }
        // Offline c1 verifies the skipped chain in order, then opens the latest epoch.
        let latestEnvelope = try GroupHPKE.wrap(roomKey: key3, for: c1.id, roster: three, signerID: a1.id, signingKey: a1.signing)
        let latestKey = try GroupHPKE.unwrap(latestEnvelope, deviceID: c1.id, agreementKey: c1.agreement, roster: three)
        let latestClear = try GroupPhotoCrypto.open(latest, roomKey: latestKey, roster: three)
        try check(latestClear == payload, "offline catch-up")
        try rejects("do not skip trust chain") {
            _ = try GroupRosterVerifier.verify(GroupRosterVerifier.sign(third, deviceID: a1.id, privateKey: a1.signing), anchor: anchor, previous: one)
        }
        try rejects("rollback") { _ = try GroupRosterVerifier.verify(packet, anchor: anchor, previous: two) }

        let sixPeople = [a, b, c, Person(id: "d"), Person(id: "e"), Person(id: "f")]
        let sixMembers = try sixPeople.map { person in
            try member(person, (1...3).map { Device(id: person.id + "-\($0)") }, owner: person.id == a.id)
        }
        let full = GroupRoster(windowID: "room-one", revision: 1, keyEpoch: 1,
            previousHash: Data(repeating: 0, count: 32), ownerPersonID: a.id, members: sixMembers)
        _ = try full.canonicalBytes()
        let seven = GroupRoster(windowID: "room-one", revision: 1, keyEpoch: 1, previousHash: one.roster.previousHash,
            ownerPersonID: a.id, members: try sixMembers + [member(Person(id: "g"), [Device(id: "g1")])])
        try rejects("seventh person") { _ = try seven.canonicalBytes() }
        let fourthDevice = try member(b, [b1, b2, Device(id: "b3"), Device(id: "b4")])
        let tooMany = GroupRoster(windowID: "room-one", revision: 1, keyEpoch: 1,
            previousHash: one.roster.previousHash, ownerPersonID: a.id, members: [firstMembers[0], fourthDevice])
        try rejects("fourth device") { _ = try tooMany.canonicalBytes() }
        let duplicate = GroupRoster(windowID: "room-one", revision: 1, keyEpoch: 1,
            previousHash: one.roster.previousHash, ownerPersonID: a.id, members: firstMembers + [firstMembers[1]])
        try rejects("duplicate person") { _ = try duplicate.canonicalBytes() }

        let ui = GroupWindowFixture()
        let window = try await ui.window(id: "fixture-window")
        try check(window.memberCount == 2 && window.deviceCount == 2, "fixture starts with two members")
        let operation = GroupOperation(expectedRevision: window.revision)
        let approved = try await ui.approve(requestID: "fixture-request", windowID: window.id, operation: operation)
        let retried = try await ui.approve(requestID: "fixture-request", windowID: window.id, operation: operation)
        try check(approved == retried && retried.memberCount == 3, "fixture approval replay")
        let fullUI = GroupWindowFixture(scenario: .sixPeople)
        var limitRejected = false
        do { _ = try await fullUI.approve(requestID: "fixture-request", windowID: "fixture-window", operation: .init(expectedRevision: 8)) }
        catch GroupClientError.memberLimit { limitRejected = true }
        try check(limitRejected, "fixture limit state")
        let offlineUI = GroupWindowFixture(scenario: .offline)
        var offlineRejected = false
        do { _ = try await offlineUI.windows() } catch GroupClientError.offline { offlineRejected = true }
        try check(offlineRejected, "fixture offline state")
        print("Group HPKE, roster, removal, sender integrity, limits and UI fixture checks passed")
    }
}
