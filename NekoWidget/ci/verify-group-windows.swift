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

private func checkWireVector(path: String) throws {
    func bytes(_ value: Any?) throws -> Data {
        guard let text = value as? String else { throw Failure.check("wire vector binary field") }
        let raw = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let result = Data(base64Encoded: raw + String(repeating: "=", count: (4 - raw.count % 4) % 4))
        else { throw Failure.check("wire vector base64url") }
        return result
    }
    let value = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
    let packet = value["packet"] as! [String: Any]
    let r = packet["roster"] as! [String: Any]
    let members = try (r["members"] as! [[String: Any]]).map { member in
        GroupRosterMember(participantID: member["participantId"] as! String, personID: member["personId"] as! String,
            identityPublicKey: try bytes(member["identityPublicKey"]), role: GroupRosterMember.Role(rawValue: member["role"] as! String)!,
            devices: try (member["devices"] as! [[String: Any]]).map { d in
                GroupRosterDevice(id: d["id"] as! String, signingPublicKey: try bytes(d["signingPublicKey"]),
                    hpkePublicKey: try bytes(d["hpkePublicKey"]), personAuthorization: try bytes(d["personAuthorization"]))
            })
    }
    let roster = GroupRoster(windowID: r["windowId"] as! String, revision: r["revision"] as! Int,
        keyEpoch: r["keyEpoch"] as! Int, previousHash: try bytes(r["previousHash"]),
        ownerPersonID: r["ownerPersonId"] as! String, members: members)
    let signed = SignedGroupRoster(roster: roster, signerDeviceID: packet["signerDeviceId"] as! String, signature: try bytes(packet["signature"]))
    let a = value["anchor"] as! [String: Any]
    let anchor = GroupTrustAnchor(windowID: a["windowId"] as! String, ownerPersonID: a["ownerPersonId"] as! String,
        ownerIdentityPublicKey: try bytes(a["ownerIdentityPublicKey"]))
    let verified = try GroupRosterVerifier.verify(signed, anchor: anchor)
    try check(verified.hash == bytes(value["canonicalSHA256"]), "native and relay canonical bytes agree")
    print("GROUP public wire vector signature and canonical bytes passed")
}

/// ひとことは一方向（11/9）：欄のすぐ下に、見える人と上限だけを書く。
/// メモのページの「まどに届ける」はメモの文を上限で切って欄に入れるだけ。
private func checkCaptionVisibilityFooter() throws {
    try check(GroupPhotoCaption.visibilityFooter == "まどのみんなに見えます（100文字まで）",
              "the ひとこと field says who sees it and the limit")
    try check(GroupPhotoCaption.visibilityFooter.contains("\(GroupPhotoCaption.maximumCharacters)文字"),
              "the footer limit follows the caption rule")
    try check(!GroupPhotoCaption.visibilityFooter.contains("メモ"), "the ひとこと footer never promises a memo")

    // メモ → ひとこと (memo page's 「まどに届ける」): cut at the caption limits, always valid.
    typealias Caption = GroupPhotoCaption
    let long = String(repeating: "ね", count: 130)
    try check(Caption.draft(fromMemo: long) == String(repeating: "ね", count: Caption.maximumCharacters),
              "memo draft keeps the first 100 characters")
    try check(Caption.draft(fromMemo: "一\n二\r\n三\n四\n五") == "一\n二\n三", "memo draft keeps at most two line breaks")
    try check(Caption.draft(fromMemo: "  窓辺で眠った日\n\n") == "窓辺で眠った日", "memo draft trims like a caption")
    try check(Caption.draft(fromMemo: "短いメモ") == "短いメモ", "a short memo is taken as is")
    try check(Caption.draft(fromMemo: "") == "" && Caption.draft(fromMemo: " \n ") == "", "an empty memo starts an empty ひとこと")
    let edge = String(repeating: "あ", count: 99) + "\nい"
    try check(Caption.draft(fromMemo: edge) == String(repeating: "あ", count: 99), "a cut never ends on a line break")
    for memo in [long, "一\n二\n三\n四", edge, String(repeating: "🐈‍⬛", count: 120), String(repeating: "a\n", count: 80)] {
        let draft = Caption.draft(fromMemo: memo)
        try check(Caption.validationMessage(for: draft) == nil && !draft.isEmpty, "memo draft is always a valid caption")
    }
    print("ひとこと visibility footer checks passed")
}

@main
private enum GroupWindowChecks {
    static func main() async throws {
        try checkRecoverySelection()
        try checkRecoveryProof()
        if CommandLine.arguments.count > 1 { try checkWireVector(path: CommandLine.arguments[1]) }
        try checkCaptionVisibilityFooter()
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
        print("GROUP stage initial roster verified")
        let reordered = GroupRoster(windowID: "room-one", revision: 2, keyEpoch: 1,
            previousHash: one.hash, ownerPersonID: a.id, members: Array(firstMembers.reversed()))
        let reorderedVerified = try GroupRosterVerifier.verify(
            GroupRosterVerifier.sign(reordered, deviceID: a1.id, privateKey: a1.signing), anchor: anchor, previous: one)
        try check(reorderedVerified.roster.keyEpoch == 1, "array order does not rotate keys")
        let key1 = SymmetricKey(size: .bits256)
        let payload = Data("synthetic-group-photo".utf8)
        let photo = try GroupPhotoCrypto.seal(payload, clientMomentID: "photo-one", senderDeviceID: b1.id,
            roomKey: key1, signingKey: b1.signing, roster: one)
        let caption = try GroupCaptionCrypto.seal("  きょうも一緒\r\nのんびり  ", photo: photo, roomKey: key1, signingKey: b1.signing, roster: one)!
        let openedCaption = try GroupCaptionCrypto.open(caption, photo: photo, roomKey: key1, roster: one)
        try check(openedCaption == "きょうも一緒\nのんびり", "caption normalization and encryption round trip")
        let legacyPhoto = try GroupPhotoCrypto.open(photo, roomKey: key1, roster: one)
        try check(legacyPhoto == payload, "legacy photo bytes unchanged")
        let emptyCaption = try GroupCaptionCrypto.seal(" \n ", photo: photo, roomKey: key1, signingKey: b1.signing, roster: one)
        try check(emptyCaption == nil, "empty caption remains photo-only")
        let maximumCaption = try GroupPhotoCaption.normalized(String(repeating: "猫", count: 100))
        try check(maximumCaption != nil, "100 characters accepted")
        try check(GroupPhotoCaption.validationMessage(for: String(repeating: "猫", count: 101)) != nil, "101 characters rejected")
        try check(GroupPhotoCaption.validationMessage(for: "a\nb\nc") == nil, "two line breaks accepted")
        try check(GroupPhotoCaption.validationMessage(for: "a\nb\nc\nd") != nil, "three line breaks rejected")
        let another = try GroupPhotoCrypto.seal(payload, clientMomentID: "photo-two", senderDeviceID: b1.id,
            roomKey: key1, signingKey: b1.signing, roster: one)
        var rejectedCaption = false
        do { _ = try GroupCaptionCrypto.open(caption, photo: another, roomKey: key1, roster: one) }
        catch GroupProtocolError.invalidSignature { rejectedCaption = true }
        try check(rejectedCaption, "caption transplant rejected")
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
        print("GROUP stage envelope and photo integrity checks passed")
        let second = GroupRoster(windowID: "room-one", revision: 2, keyEpoch: 2,
            previousHash: one.hash, ownerPersonID: a.id, members: membersTwo)
        let two = try GroupRosterVerifier.verify(GroupRosterVerifier.sign(second, deviceID: a1.id, privateKey: a1.signing), anchor: anchor, previous: one)
        print("GROUP stage additional device roster verified")
        try check(two.roster.members.count == 3 && two.roster.members.flatMap(\.devices).count == 4, "people and devices separate")
        let noRotation = GroupRoster(windowID: "room-one", revision: 2, keyEpoch: 1,
            previousHash: one.hash, ownerPersonID: a.id, members: membersTwo)
        try rejects("membership change must rotate") {
            _ = try GroupRosterVerifier.verify(GroupRosterVerifier.sign(noRotation, deviceID: a1.id, privateKey: a1.signing), anchor: anchor, previous: one)
        }
        let third = GroupRoster(windowID: "room-one", revision: 3, keyEpoch: 3,
            previousHash: two.hash, ownerPersonID: a.id, members: try [member(a, [a1], owner: true), member(c, [c1])])
        let three = try GroupRosterVerifier.verify(GroupRosterVerifier.sign(third, deviceID: a1.id, privateKey: a1.signing), anchor: anchor, previous: two)
        print("GROUP stage removal roster verified")
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

private func checkRecoverySelection() throws {
    func rootID(_ bytes: Data) -> String {
        GroupCanonical.hash(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    let root = Curve25519.Signing.PrivateKey(), owner = Curve25519.Signing.PrivateKey()
    let anchor = GroupTrustAnchor(windowID: "room", ownerPersonID: rootID(owner.publicKey.rawRepresentation),
        ownerIdentityPublicKey: owner.publicKey.rawRepresentation)
    let receipt = try GroupAnchorReceipt.make(environment: "staging", anchor: anchor, root: root)
    let publicRoot = root.publicKey.rawRepresentation
    try check(receipt == GroupAnchorReceipt.make(environment: "staging", anchor: anchor, root: root), "retry receipt is deterministic")
    try check(GroupAnchorReceipt.resolve([receipt, receipt], root: publicRoot, environment: "staging", windowID: "room", rootIsCurrent: true) == .trusted(anchor), "identical receipts have one anchor")
    try check(GroupAnchorReceipt.resolve([receipt], root: publicRoot, environment: "production", windowID: "room", rootIsCurrent: true) == .needsOriginalDeviceOrInvitation, "receipt is environment scoped")
    try check(GroupAnchorReceipt.resolve([receipt], root: publicRoot, environment: "staging", windowID: "other", rootIsCurrent: true) == .needsOriginalDeviceOrInvitation, "receipt is window scoped")
    try check(GroupAnchorReceipt.resolve([receipt], root: publicRoot, environment: "staging", windowID: "room", rootIsCurrent: false) == .revoked, "revoked root cannot recover")
    let replacement = GroupTrustAnchor(windowID: "room", ownerPersonID: rootID(publicRoot), ownerIdentityPublicKey: publicRoot)
    let conflicting = try GroupAnchorReceipt.make(environment: "staging", anchor: replacement, root: root)
    try check(GroupAnchorReceipt.resolve([receipt, conflicting], root: publicRoot, environment: "staging", windowID: "room", rootIsCurrent: true) == .conflictingAnchors, "two correctly signed different pins never select by date")
    let forged = GroupAnchorReceipt(environment: "staging", personID: receipt.personID, anchor: replacement, rootSignature: receipt.rootSignature)
    try check(!forged.verifies(root: publicRoot, environment: "staging", windowID: "room"), "relay cannot swap the owner key")
    let emptyA = GroupRootMembershipSummary(rootID: "a", windowIDs: [], notebookIDs: [])
    let emptyB = GroupRootMembershipSummary(rootID: "b", windowIDs: [], notebookIDs: [])
    try check(GroupRootSelectionPolicy.resolve(local: nil, sync: .checking, catalogs: [:]) == .checking, "no identity creation while sync is pending")
    try check(GroupRootSelectionPolicy.resolve(local: nil, sync: .unavailable, catalogs: [:]) == .unavailable, "sync failure is not empty")
    try check(GroupRootSelectionPolicy.resolve(local: nil, sync: .missing, catalogs: [:]) == .mayCreate, "creation only after confirmed absence")
    try check(GroupRootSelectionPolicy.resolve(local: "a", sync: .candidates(["b"]), catalogs: [:]) == .checking, "no choice before both catalogs arrive")
    try check(GroupRootSelectionPolicy.resolve(local: "a", sync: .candidates(["b"]), catalogs: ["a": emptyA, "b": emptyB]) == .use("b"), "both empty selects synced root")
    let joinedA = GroupRootMembershipSummary(rootID: "a", windowIDs: [], notebookIDs: ["family"])
    try check(GroupRootSelectionPolicy.resolve(local: "a", sync: .candidates(["b"]), catalogs: ["a": joinedA, "b": emptyB]) == .choose(["a", "b"]), "notebook membership requires user selection")
    try check(GroupRootSelectionPolicy.resolve(local: nil, sync: .candidates(["b", "a"]), catalogs: ["a": emptyA, "b": emptyB]) == .choose(["a", "b"]), "multiple synced roots never chosen by order")
    let id = UUID()
    try check(GroupRecoveryRegistrationState.checking(operationID: id).nextAction == .queryStatus(id), "lost response queries same operation first")
    try check(GroupRecoveryRegistrationState.notStarted(operationID: id).nextAction == .submitSameOperation(id), "retry keeps operation id")
    try check(GroupRecoveryRegistrationState.registeredWaitingForKeys(operationID: id, deviceID: "d").nextAction == .waitForKeys, "registration is not decryption")
    try check(GroupRecoveryRegistrationState.revoked(operationID: id).nextAction == .stop, "revocation cannot retry registration")
    try check(GroupRecoveryRegistrationState.needsOriginalDeviceOrInvitation(operationID: id).nextAction == .stop, "missing anchor never creates a new person")
    print("P3 root selection and recovery retry states passed")
}

private func checkRecoveryProof() throws {
    let golden = GroupRecoveryClaim(version: 1, environment: "staging", windowID: "room", personID: "owner", participantID: "p1",
        recoveryGeneration: 1, previousRevision: 1, previousHash: Data(repeating: 0, count: 32), nextHash: Data(repeating: 1, count: 32),
        newDevice: .init(id: "new", signingPublicKey: Data(repeating: 2, count: 32), hpkePublicKey: Data(repeating: 3, count: 32), personAuthorization: Data(repeating: 4, count: 64)),
        replacedDeviceIDs: ["b", "a"], operationID: "op1", challenge: Data(repeating: 5, count: 32), issuedAt: 1000, expiresAt: 1300)
    let hash = GroupCanonical.hash(try golden.canonicalBytes()).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    try check(hash == "VLXwWfoFfKC_21jMxc1todZ3QSB-uH-mO-JVFb9YMrw", "Swift/TS recovery canonical bytes")
    try check(GroupCanonical.hash(golden.signatureBytes(root: true)).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == "NV7JbqaSbEPsrqrsps4_VgJ-AY6aaUCuyqndzvzyLLo", "ROOT signature bytes match TS")
    try check(GroupCanonical.hash(golden.signatureBytes(root: false)).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == "2LXPNN6swU0VJdJqFCAqCOJtTult4_VSTOZqLAGTqqs", "DEVICE signature bytes match TS")
    var reordered = golden; reordered.replacedDeviceIDs.reverse()
    try check(golden.canonicalBytes() == reordered.canonicalBytes(), "recovery replacement order")
    var unknown = golden; unknown.version = 2
    do { _ = try unknown.canonicalBytes(); throw Failure.check("unknown recovery version accepted") }
    catch GroupRecoveryProofError.updateRequired { }
    try check(!GroupRecoveryProofVerifier.issuanceEnabled, "recovery issuance remains disabled")

    let person = Person(id: "owner"), family = Person(id: "family")
    let oldPhone = Device(id: "old"), newPhone = Device(id: "new"), familyPhone = Device(id: "family-phone")
    let oldDevice = try oldPhone.rosterDevice(person: person)
    let newDevice = try newPhone.rosterDevice(person: person)
    let owner = GroupRosterMember(participantID: "p1", personID: person.id, identityPublicKey: person.identity.publicKey.rawRepresentation, role: .owner, devices: [oldDevice])
    let other = GroupRosterMember(participantID: "p2", personID: family.id, identityPublicKey: family.identity.publicKey.rawRepresentation, role: .member, devices: [try familyPhone.rosterDevice(person: family)])
    let old = GroupRoster(windowID: "room-one", revision: 1, keyEpoch: 1, previousHash: Data(repeating: 0, count: 32), ownerPersonID: person.id, members: [owner, other])
    let signed = try GroupRosterVerifier.sign(old, deviceID: oldPhone.id, privateKey: oldPhone.signing)
    let previous = try GroupRosterVerifier.verify(signed, anchor: .init(windowID: old.windowID, ownerPersonID: person.id, ownerIdentityPublicKey: person.identity.publicKey.rawRepresentation))
    func nextRoster(devices: [GroupRosterDevice], familyMember: GroupRosterMember? = nil, revision: Int = 2, epoch: Int = 2) -> GroupRoster {
        .init(windowID: old.windowID, revision: revision, keyEpoch: epoch, previousHash: previous.hash, ownerPersonID: person.id,
              members: [.init(participantID: owner.participantID, personID: person.id, identityPublicKey: owner.identityPublicKey, role: .owner, devices: devices), familyMember ?? other])
    }
    func proof(_ next: GroupRoster, removed: [String] = []) throws -> GroupRecoveryProof {
        let c = GroupRecoveryClaim(version: 1, environment: "staging", windowID: old.windowID, personID: person.id, participantID: owner.participantID,
            recoveryGeneration: 1, previousRevision: 1, previousHash: previous.hash, nextHash: GroupCanonical.hash(try next.canonicalBytes()), newDevice: newDevice,
            replacedDeviceIDs: removed, operationID: "op1", challenge: Data(repeating: 7, count: 32), issuedAt: 1000, expiresAt: 1300)
        return .init(claim: c, rootSignature: try person.identity.signature(for: c.signatureBytes(root: true)), deviceSignature: try newPhone.signing.signature(for: c.signatureBytes(root: false)))
    }
    let next = nextRoster(devices: [oldDevice, newDevice]), p = try proof(next)
    let ledger = GroupRecoveryLedger(environment: "staging", windowID: old.windowID, personID: person.id, participantID: owner.participantID,
        identityPublicKey: owner.identityPublicKey, revision: 1, hash: previous.hash, recoveryGeneration: 1, state: .active, newDeviceWasRevoked: false,
        challenge: .init(value: p.claim.challenge, operationID: "op1", issuedAt: 1000, expiresAt: 1300, consumed: false))
    try GroupRecoveryProofVerifier.validate(p, previous: previous, next: next, ledger: ledger, now: 1100)
    let familyNew = try newPhone.rosterDevice(person: family)
    let memberNext = GroupRoster(windowID: old.windowID, revision: 2, keyEpoch: 2, previousHash: previous.hash, ownerPersonID: person.id,
        members: [owner, .init(participantID: other.participantID, personID: family.id, identityPublicKey: other.identityPublicKey, role: .member, devices: other.devices + [familyNew])])
    var memberClaim = p.claim; memberClaim.personID = family.id; memberClaim.participantID = other.participantID
    memberClaim.newDevice = familyNew; memberClaim.nextHash = GroupCanonical.hash(try memberNext.canonicalBytes())
    let memberProof = GroupRecoveryProof(claim: memberClaim, rootSignature: try family.identity.signature(for: memberClaim.signatureBytes(root: true)), deviceSignature: try newPhone.signing.signature(for: memberClaim.signatureBytes(root: false)))
    var memberLedger = ledger; memberLedger.personID = family.id; memberLedger.participantID = other.participantID; memberLedger.identityPublicKey = other.identityPublicKey
    try GroupRecoveryProofVerifier.validate(memberProof, previous: previous, next: memberNext, ledger: memberLedger, now: 1100)
    let replacement = nextRoster(devices: [newDevice])
    try GroupRecoveryProofVerifier.validate(proof(replacement, removed: [oldDevice.id]), previous: previous, next: replacement, ledger: ledger, now: 1100)
    for state in [GroupRecoveryLedger.State.closed, .deleted, .left, .removed, .rootRevoked] {
        var l = ledger; l.state = state
        try rejects("closed/revoked recovery") { try GroupRecoveryProofVerifier.validate(p, previous: previous, next: next, ledger: l, now: 1100) }
    }
    let mutations: [(inout GroupRecoveryLedger) -> Void] = [
        { $0.environment = "production" }, { $0.windowID = "other" }, { $0.personID = "other" }, { $0.participantID = "other" },
        { $0.revision += 1 }, { $0.hash = Data(repeating: 9, count: 32) }, { $0.recoveryGeneration += 1 },
        { $0.newDeviceWasRevoked = true }, { $0.challenge.consumed = true }, { $0.challenge.operationID = "other" },
        { $0.challenge.value = Data(repeating: 9, count: 32) }, { $0.challenge.issuedAt -= 1 }, { $0.challenge.expiresAt += 1 },
        { $0.identityPublicKey = Data(repeating: 9, count: 32) }
    ]
    for mutation in mutations { var l = ledger; mutation(&l)
        try rejects("ledger recovery binding") { try GroupRecoveryProofVerifier.validate(p, previous: previous, next: next, ledger: l, now: 1100) }
    }
    for now in [999, 1300] { try rejects("recovery expiry") { try GroupRecoveryProofVerifier.validate(p, previous: previous, next: next, ledger: ledger, now: now) } }
    var swapped = p; swapped.rootSignature = p.deviceSignature; swapped.deviceSignature = p.rootSignature
    try rejects("recovery signature domain") { try GroupRecoveryProofVerifier.validate(swapped, previous: previous, next: next, ledger: ledger, now: 1100) }
    let changedOther = GroupRosterMember(participantID: "different", personID: other.personID, identityPublicKey: other.identityPublicKey, role: other.role, devices: other.devices)
    for wrong in [nextRoster(devices: [oldDevice,newDevice], familyMember: changedOther), nextRoster(devices: [newDevice]), nextRoster(devices: [oldDevice,newDevice], revision: 3), nextRoster(devices: [oldDevice,newDevice], epoch: 1)] {
        let freshlySigned = try proof(wrong)
        try rejects("root cannot authorize other changes") { try GroupRecoveryProofVerifier.validate(freshlySigned, previous: previous, next: wrong, ledger: ledger, now: 1100) }
    }
    print("GROUP recovery P1 signatures, trusted ledger, immutable membership and canonical vector passed; issuance OFF")
}
