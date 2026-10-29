import CryptoKit
import Foundation

private enum Failure: Error { case check(String) }
private func check(_ value: Bool, _ text: String) throws { if !value { throw Failure.check(text) } }
private func rejects(_ work: () throws -> Void) throws {
    do { try work() } catch { return }
    throw Failure.check("untrusted or expired invitation was accepted")
}
@main private enum VerifyFamilyNotebookInvitation {
    static func main() throws {
        let family = UUID(), invitationID = UUID(), inviter = GroupDeviceIdentity.firstDevice(), payer = GroupDeviceIdentity.firstDevice()
        let joiner = GroupDeviceIdentity.firstDevice(), outsider = GroupDeviceIdentity.firstDevice(), now = Date(timeIntervalSince1970: 1_800_000_000)
        func member(_ identity: GroupDeviceIdentity) throws -> FamilyNotebookCryptoMember {
            try .init(personID: identity.personID, identityPublicKey: identity.personPublicKey, devices: [identity.certificate(windowID: family.uuidString.lowercased())])
        }
        let roster = try FamilyNotebookCryptoRoster(familyID: family, epoch: 1, previousHash: Data(repeating: 0, count: 32),
            keyCommitment: GroupCanonical.hash(Data(repeating: 7, count: 32)), members: [member(inviter), member(payer)])
        let packet = try FamilyNotebookRosterCrypto.sign(roster, deviceID: inviter.deviceID, signingKey: inviter.signingKey)
        let pin = try FamilyNotebookRosterPin(familyID: family, epoch: 1, hash: GroupCanonical.hash(roster.canonicalBytes()))
        let verified = try FamilyNotebookRosterCrypto.restore(packet, trustedPin: pin)
        let (capability, encrypted) = try FamilyNotebookInvitationCrypto.create(roster: verified, generation: 4, identity: inviter,
            payerPersonID: payer.personID, invitationID: invitationID, inviterName: "合成の招待者", catNames: ["合成のねこ"], now: now)
        let link = try capability.url, parsed = try FamilyNotebookInvitationCapability(url: link)
        try check(parsed == capability, "strict fragment capability round trip")
        try check(link.query == nil && link.path == "/family-join", "capability never enters URL path/query")
        try check(!capability.description.contains(GroupWire.base64(capability.secret)), "diagnostic description redacts secrets")
        for invalid in [link.absoluteString + "&v=1", link.absoluteString.replacingOccurrences(of: "https:", with: "http:"),
                        link.absoluteString.replacingOccurrences(of: "nekonomado.com", with: "untrusted.invalid"),
                        link.absoluteString.replacingOccurrences(of: "/family-join#", with: "/family-join?secret=x#"),
                        link.absoluteString.replacingOccurrences(of: "e=1", with: "e=01")] {
            try rejects { _ = try FamilyNotebookInvitationCapability(url: URL(string: invalid)!) }
        }
        func open(_ data: Data? = nil, _ cap: FamilyNotebookInvitationCapability? = nil,
                  generation: Int64 = 4, expiry: Int64 = 1_800_086_400) throws -> VerifiedFamilyNotebookInvitation {
            try FamilyNotebookInvitationCrypto.open(data ?? encrypted, capability: cap ?? capability, serverInviterPersonID: inviter.personID,
                serverInviterDeviceID: inviter.deviceID, serverGeneration: generation, serverExpiresAt: expiry, now: now)
        }
        let preview = try open()
        try check(preview.content.inviterName == "合成の招待者" && preview.content.catNames == ["合成のねこ"], "only chosen preview fields decrypt")
        try check(preview.capability.pin == pin && preview.content.approvers.count == 2, "verified invitation binds bootstrap pin and explicit approvers")
        try rejects { _ = try open(generation: 5) }
        try rejects { _ = try open(expiry: 1_799_999_999) }
        var damaged = encrypted; damaged[damaged.count - 1] ^= 1
        try rejects { _ = try open(damaged) }
        let swapped = FamilyNotebookInvitationCapability(familyID: family, invitationID: UUID(), secret: capability.secret,
            inviterIdentityPublicKey: capability.inviterIdentityPublicKey, pin: pin)
        try rejects { _ = try open(encrypted, swapped) }
        let wrongPin = FamilyNotebookInvitationCapability(familyID: family, invitationID: invitationID, secret: capability.secret,
            inviterIdentityPublicKey: capability.inviterIdentityPublicKey, pin: .init(familyID: family, epoch: 1, hash: Data(repeating: 9, count: 32)))
        try rejects { _ = try open(encrypted, wrongPin) }
        let proofOperation = UUID(), proof = try capability.proof(personID: joiner.personID, deviceID: joiner.deviceID, action: "join", operationID: proofOperation)
        let transcript = try GroupCanonical.fields(["NW.FAMILY-NOTEBOOK.INVITATION.1", family.uuidString.lowercased(), invitationID.uuidString.lowercased(),
            joiner.personID, joiner.deviceID, "join", proofOperation.uuidString.lowercased()].map(GroupCanonical.text))
        try check(try capability.proofKey.publicKey.isValidSignature(proof, for: transcript), "proof matches Worker canonical fields")
        let request = UUID(), joinName = try FamilyNotebookJoinNameCrypto.seal("合成の参加者", invitation: preview, identity: joiner, requestID: request, now: now)
        try check(!String(decoding: joinName, as: UTF8.self).contains("合成の参加者"), "join wire carries ciphertext, not display name")
        func name(_ recipient: GroupDeviceIdentity, requestID: UUID? = nil, signingKey: Data? = nil) throws -> String {
            try FamilyNotebookJoinNameCrypto.open(joinName, familyID: family, invitationID: invitationID, requestID: requestID ?? request,
                personID: joiner.personID, deviceID: joiner.deviceID, signingPublicKey: signingKey ?? joiner.signingKey.publicKey.rawRepresentation, recipient: recipient)
        }
        try check(try name(inviter) == "合成の参加者", "inviter decrypts authenticated applicant name")
        try check(try name(payer) == "合成の参加者", "payer decrypts authenticated applicant name")
        try rejects { _ = try name(outsider) }
        try rejects { _ = try name(inviter, requestID: UUID()) }
        try rejects { _ = try name(inviter, signingKey: outsider.signingKey.publicKey.rawRepresentation) }
        try rejects { _ = try FamilyNotebookJoinNameCrypto.seal("late", invitation: preview, identity: joiner, requestID: UUID(), now: preview.expiresAt) }
        print("Family notebook invitations: fragment-only capability, signed encrypted preview, pinned roster, generation/expiry, proof and recipient-only join names passed")
    }
}
