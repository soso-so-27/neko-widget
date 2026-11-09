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

/// 写真のメモとひとことのあいだの決まり（MemoCaptionBridge）。メモは「メモから入れる」で
/// だけひとことに入り、届けたひとことはメモを持てるときだけ、重ねずに、上限内で残る。
private func checkMemoCaptionBridge() throws {
    typealias Bridge = MemoCaptionBridge
    let limit = 500
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func decision(enforced: Bool, _ personal: MembershipPersonalState) -> MembershipAccessDecision {
        MembershipAccessPolicy.decision(for: .createPersonalMemo, enforcementEnabled: enforced,
                                        personal: personal, window: .checking, now: now)
    }
    let plus = decision(enforced: true, .verified(validUntil: now.addingTimeInterval(3_600)))
    let free = decision(enforced: true, .inactive)
    let beta = decision(enforced: false, .inactive)
    try check(plus == .allowed && free == .membershipRequired && beta == .allowed, "memo bridge uses the Plus rule for new memos")

    // メモ → ひとこと: cut at the caption limits, always a valid caption.
    let long = String(repeating: "ね", count: 130)
    let longDraft = Bridge.captionDraft(fromMemo: long)
    try check(longDraft == String(repeating: "ね", count: GroupPhotoCaption.maximumCharacters), "memo draft keeps the first 100 characters")
    let lines = Bridge.captionDraft(fromMemo: "一\n二\r\n三\n四\n五")
    try check(lines == "一\n二\n三", "memo draft keeps at most two line breaks")
    try check(Bridge.captionDraft(fromMemo: "  窓辺で眠った日\n\n") == "窓辺で眠った日", "memo draft trims like a caption")
    try check(Bridge.captionDraft(fromMemo: "短いメモ") == "短いメモ", "a short memo is taken as is")
    let edge = String(repeating: "あ", count: 99) + "\nい"
    try check(Bridge.captionDraft(fromMemo: edge) == String(repeating: "あ", count: 99), "a cut never ends on a line break")
    for memo in [long, "一\n二\n三\n四", edge, String(repeating: "🐈‍⬛", count: 120), String(repeating: "a\n", count: 80)] {
        let draft = Bridge.captionDraft(fromMemo: memo)
        try check(GroupPhotoCaption.validationMessage(for: draft) == nil && !draft.isEmpty, "memo draft is always a valid caption")
    }

    // Who may keep: an existing memo is editing (free); a new memo is Plus.
    try check(Bridge.canKeepMemo(hasExistingMemo: true, createDecision: free), "adding to an existing memo is free")
    try check(!Bridge.canKeepMemo(hasExistingMemo: false, createDecision: free), "a new memo needs Plus")
    try check(Bridge.canKeepMemo(hasExistingMemo: false, createDecision: plus), "Plus keeps a new memo")
    try check(!Bridge.canKeepMemo(hasExistingMemo: false, createDecision: .verificationRequired), "an unconfirmed Plus does not create a memo")

    // ひとこと → メモ after sending.
    func keep(_ caption: String, _ memo: String?, _ decision: MembershipAccessDecision) -> Bridge.Keeping {
        Bridge.keeping(caption: caption, existingMemo: memo, createDecision: decision, maximumMemoCharacters: limit)
    }
    try check(keep("おなかを見せて寝ていた", nil, plus) == .save("おなかを見せて寝ていた"), "Plus keeps the words as a new memo")
    try check(keep("おなかを見せて寝ていた", nil, free) == .notAllowed, "no new memo without Plus")
    try check(keep("おなかを見せて寝ていた", "窓辺で眠った日", free) == .save("窓辺で眠った日\nおなかを見せて寝ていた"), "words are added to an existing memo without Plus")
    try check(keep("ねむい", "", free) == .save("ねむい"), "a memo with only a weight takes the words alone")
    try check(keep("  \n ", nil, plus) == .nothingToKeep && keep("", "メモ", plus) == .nothingToKeep, "an empty ひとこと keeps nothing")
    let fromMemo = Bridge.captionDraft(fromMemo: "窓辺で眠った日\nしっぽが長い")
    try check(keep(fromMemo, "窓辺で眠った日\nしっぽが長い", plus) == .alreadyKept, "words from the memo are not added again")
    try check(keep("眠った", "窓辺で眠った日", free) == .alreadyKept, "words already in the memo are not added again")
    try check(keep("一\r\n二", "一\n二", free) == .alreadyKept, "line breaks are read the same way")
    let nearlyFull = String(repeating: "あ", count: 497)
    try check(keep("いいい", nearlyFull, plus) == .tooLong, "a memo past 500 characters stays as it was")
    try check(keep("いいい", String(repeating: "あ", count: 496), plus) == .save(String(repeating: "あ", count: 496) + "\nいいい"),
              "a memo of exactly 500 characters is kept")

    // The footer promises a memo only when the words will really stay.
    func footer(_ caption: String, _ memo: String?, _ decision: MembershipAccessDecision) -> Bool {
        Bridge.footerSaysKept(caption: caption, existingMemo: memo, createDecision: decision, maximumMemoCharacters: limit)
    }
    try check(footer("", nil, plus) && footer("ねむい", nil, plus), "Plus: the footer says the memo keeps the words")
    try check(!footer("", nil, free) && !footer("ねむい", nil, free), "no Plus and no memo: the footer promises nothing")
    try check(footer("", "メモ", free) && footer("ねむい", "メモ", free), "an existing memo keeps the words without Plus")
    try check(footer("メモ", "メモ", free), "words already in the memo stay there")
    try check(!footer("いいい", nearlyFull, plus), "a memo that cannot take the words is not promised")

    // 届いたひとこと → the new Photos copy's memo: Plus only, never empty.
    try check(Bridge.keepsReceivedCaption("いい顔", createDecision: plus), "Plus keeps a received ひとこと")
    try check(!Bridge.keepsReceivedCaption("いい顔", createDecision: free), "no Plus: a received ひとこと is not kept")
    try check(!Bridge.keepsReceivedCaption(nil, createDecision: plus) && !Bridge.keepsReceivedCaption(" ", createDecision: plus),
              "no ひとこと: nothing to keep")
    print("Memo and ひとこと bridge checks passed")
}

@main
private enum GroupWindowChecks {
    static func main() async throws {
        if CommandLine.arguments.count > 1 { try checkWireVector(path: CommandLine.arguments[1]) }
        try checkMemoCaptionBridge()
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
