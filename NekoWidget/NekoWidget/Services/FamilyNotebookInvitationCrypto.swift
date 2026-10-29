import CryptoKit
import Foundation

/// Bearer capability; secrets stay in the URL fragment and an app-private
/// secret store, never in the request path, UI preview or diagnostic text.
struct FamilyNotebookInvitationCapability: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let familyID: UUID
    let invitationID: UUID
    let secret: Data
    let inviterIdentityPublicKey: Data
    let pin: FamilyNotebookRosterPin
    var description: String { "FamilyNotebookInvitationCapability(secrets: redacted)" }
    var debugDescription: String { description }

    func validated() throws -> Self {
        guard secret.count == 32, inviterIdentityPublicKey.count == 32, pin.familyID == familyID,
              (1...1_000_000_000).contains(pin.epoch), pin.hash.count == 32 else { throw FamilyNotebookCryptoError.invalid }
        return self
    }
    private func derived(_ purpose: String) throws -> Data {
        _ = try validated()
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data(),
            info: Data(("FNB1.INVITE." + purpose).utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
    }
    var proofKey: Curve25519.Signing.PrivateKey { get throws { try .init(rawRepresentation: derived("PROOF")) } }
    fileprivate var previewKey: SymmetricKey { get throws { try .init(data: derived("PREVIEW")) } }
    fileprivate func context() throws -> Data {
        try GroupCanonical.fields([GroupCanonical.text("FNB1.INVITE.PREVIEW"), GroupCanonical.text(familyID.uuidString.lowercased()),
            GroupCanonical.text(invitationID.uuidString.lowercased()), inviterIdentityPublicKey,
            GroupCanonical.text(String(pin.epoch)), pin.hash, proofKey.publicKey.rawRepresentation])
    }
    func proof(personID: String, deviceID: String, action: String, operationID: UUID) throws -> Data {
        guard ["preview", "join"].contains(action), GroupCanonical.validID(personID), GroupCanonical.validID(deviceID) else { throw FamilyNotebookCryptoError.invalid }
        return try proofKey.signature(for: GroupCanonical.fields(["NW.FAMILY-NOTEBOOK.INVITATION.1", familyID.uuidString.lowercased(),
            invitationID.uuidString.lowercased(), personID, deviceID, action, operationID.uuidString.lowercased()].map(GroupCanonical.text)))
    }
    var url: URL { get throws {
        _ = try validated()
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = "nekonomado.com"; parts.path = "/family-join"
        parts.fragment = "v=1&f=\(familyID.uuidString.lowercased())&i=\(invitationID.uuidString.lowercased())&s=\(GroupWire.base64(secret))"
            + "&r=\(GroupWire.base64(inviterIdentityPublicKey))&e=\(pin.epoch)&h=\(GroupWire.base64(pin.hash))"
        guard let result = parts.url else { throw FamilyNotebookCryptoError.invalid }; return result
    } }
    init(familyID: UUID, invitationID: UUID, secret: Data, inviterIdentityPublicKey: Data, pin: FamilyNotebookRosterPin) {
        self.familyID = familyID; self.invitationID = invitationID; self.secret = secret
        self.inviterIdentityPublicKey = inviterIdentityPublicKey; self.pin = pin
    }
    init(url: URL) throws {
        guard url.absoluteString.utf8.count <= 2048, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "nekonomado.com", parts.path == "/family-join",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil,
              let fragment = parts.percentEncodedFragment, !fragment.contains("%") else { throw FamilyNotebookCryptoError.invalid }
        var fields: [String: String] = [:]
        for pair in fragment.split(separator: "&", omittingEmptySubsequences: false) {
            let values = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard values.count == 2, !values[1].isEmpty, fields.updateValue(values[1], forKey: values[0]) == nil else { throw FamilyNotebookCryptoError.invalid }
        }
        guard Set(fields.keys) == ["v", "f", "i", "s", "r", "e", "h"], fields["v"] == "1",
              let family = UUID(uuidString: fields["f"]!), family.uuidString.lowercased() == fields["f"],
              let invitation = UUID(uuidString: fields["i"]!), invitation.uuidString.lowercased() == fields["i"],
              let epoch = Int(fields["e"]!), String(epoch) == fields["e"] else { throw FamilyNotebookCryptoError.invalid }
        self.init(familyID: family, invitationID: invitation, secret: try GroupWire.bytes(fields["s"]!, count: 32),
            inviterIdentityPublicKey: try GroupWire.bytes(fields["r"]!, count: 32),
            pin: .init(familyID: family, epoch: epoch, hash: try GroupWire.bytes(fields["h"]!, count: 32)))
        _ = try validated()
    }
}

struct FamilyNotebookInvitationContent: Codable, Equatable, Sendable {
    let generation: Int64
    let inviterName: String
    let catNames: [String]
    let expiresAt: Int64
    let inviterDevice: GroupRosterDevice
    let approvers: [FamilyNotebookCryptoMember]
}
struct VerifiedFamilyNotebookInvitation: Sendable {
    let capability: FamilyNotebookInvitationCapability
    let content: FamilyNotebookInvitationContent
    let expiresAt: Date
    fileprivate init(capability: FamilyNotebookInvitationCapability, content: FamilyNotebookInvitationContent, expiresAt: Date) {
        self.capability = capability; self.content = content; self.expiresAt = expiresAt
    }
}

enum FamilyNotebookInvitationCrypto {
    private struct SignedContent: Codable { let content: FamilyNotebookInvitationContent; let signature: Data }
    private static func signedBytes(_ content: FamilyNotebookInvitationContent, _ capability: FamilyNotebookInvitationCapability) throws -> Data {
        try GroupCanonical.fields([GroupCanonical.text("FNB1.INVITE.SIGN"), capability.context(), GroupWire.encode(content)])
    }
    static func create(roster: VerifiedFamilyNotebookRoster, generation: Int64, identity: GroupDeviceIdentity, payerPersonID: String?,
                       invitationID: UUID, inviterName: String, catNames: [String], now: Date = Date()) throws -> (FamilyNotebookInvitationCapability, Data) {
        guard let inviter = roster.roster.device(try identity.deviceID), inviter.person.personID == identity.personID,
              inviter.person.identityPublicKey == identity.personPublicKey,
              payerPersonID == nil || roster.roster.members.contains(where: { $0.personID == payerPersonID }) else { throw FamilyNotebookCryptoError.untrusted }
        let capability = FamilyNotebookInvitationCapability(familyID: roster.roster.familyID, invitationID: invitationID,
            secret: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, inviterIdentityPublicKey: identity.personPublicKey, pin: roster.pin)
        let content = try FamilyNotebookInvitationContent(generation: generation, inviterName: GroupWire.name(inviterName), catNames: catNames.map(GroupWire.name),
            expiresAt: Int64(now.timeIntervalSince1970) + 86400, inviterDevice: inviter.device,
            approvers: roster.roster.members.filter { $0.personID == identity.personID || $0.personID == payerPersonID })
        try validate(content, capability)
        let signed = try SignedContent(content: content, signature: identity.signingKey.signature(for: signedBytes(content, capability)))
        guard let encrypted = try AES.GCM.seal(GroupWire.encode(signed), using: capability.previewKey, authenticating: capability.context()).combined,
              encrypted.count <= 8192 else { throw FamilyNotebookCryptoError.tooLarge }
        return (capability, encrypted)
    }
    static func open(_ encrypted: Data, capability: FamilyNotebookInvitationCapability, serverInviterPersonID: String,
                     serverInviterDeviceID: String, serverGeneration: Int64, serverExpiresAt: Int64, now: Date = Date()) throws -> VerifiedFamilyNotebookInvitation {
        _ = try capability.validated()
        guard (29...8192).contains(encrypted.count), serverInviterPersonID == GroupWire.base64(GroupCanonical.hash(capability.inviterIdentityPublicKey)) else { throw FamilyNotebookCryptoError.untrusted }
        let plaintext = try AES.GCM.open(.init(combined: encrypted), using: capability.previewKey, authenticating: capability.context())
        let signed = try GroupWire.decode(SignedContent.self, plaintext)
        try validate(signed.content, capability)
        // Never encrypt a new request to an approver snapshot that predates a
        // departure/role change. The joining POST uses this same generation;
        // a change after preview is also rejected by the server's commit CAS.
        guard signed.content.generation == serverGeneration else { throw FamilyNotebookCryptoError.stale }
        guard signed.content.inviterDevice.id == serverInviterDeviceID, signed.signature.count == 64,
              try Curve25519.Signing.PublicKey(rawRepresentation: signed.content.inviterDevice.signingPublicKey)
                .isValidSignature(signed.signature, for: signedBytes(signed.content, capability)) else { throw FamilyNotebookCryptoError.untrusted }
        let expires = min(signed.content.expiresAt, serverExpiresAt)
        guard Double(expires) > now.timeIntervalSince1970 else { throw FamilyNotebookCryptoError.stale }
        return .init(capability: capability, content: signed.content, expiresAt: Date(timeIntervalSince1970: Double(expires)))
    }
    private static func validate(_ content: FamilyNotebookInvitationContent, _ capability: FamilyNotebookInvitationCapability) throws {
        _ = try GroupWire.name(content.inviterName)
        guard (1...1_000_000_000).contains(content.generation), content.catNames.count <= 64, content.expiresAt > 0, content.expiresAt <= 32_503_680_000,
              (1...2).contains(content.approvers.count), Set(content.approvers.map(\.personID)).count == content.approvers.count else { throw FamilyNotebookCryptoError.invalid }
        for name in content.catNames { _ = try GroupWire.name(name) }
        let inviterID = GroupWire.base64(GroupCanonical.hash(capability.inviterIdentityPublicKey))
        guard let inviter = content.approvers.first(where: { $0.personID == inviterID }),
              inviter.identityPublicKey == capability.inviterIdentityPublicKey, inviter.devices.contains(content.inviterDevice) else { throw FamilyNotebookCryptoError.untrusted }
        // Reuse root-signed device certificate validation, without treating
        // this limited approver subset as the family's current full roster.
        let subset = FamilyNotebookCryptoRoster(familyID: capability.familyID, epoch: 1, previousHash: Data(repeating: 0, count: 32),
            keyCommitment: Data(repeating: 0, count: 32), members: content.approvers)
        _ = try subset.canonicalBytes()
        guard content.approvers.allSatisfy({ $0.personID == GroupWire.base64(GroupCanonical.hash($0.identityPublicKey)) }) else { throw FamilyNotebookCryptoError.untrusted }
    }
}

struct EncryptedFamilyNotebookJoinName: Codable, Sendable {
    struct Recipient: Codable, Sendable { let deviceID: String; let encapsulatedKey: Data; let ciphertext: Data }
    let familyID: UUID, invitationID: UUID, requestID: UUID
    let personID: String, deviceID: String
    let recipients: [Recipient]
    let signature: Data
}

@available(iOS 17.0, macOS 14.0, *)
enum FamilyNotebookJoinNameCrypto {
    private static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    private static func context(family: UUID, invitation: UUID, request: UUID, person: String, device: String, recipient: String) throws -> Data {
        try GroupCanonical.fields(["FNB1.JOIN.NAME", family.uuidString.lowercased(), invitation.uuidString.lowercased(),
            request.uuidString.lowercased(), person, device, recipient].map(GroupCanonical.text))
    }
    private static func signedBytes(_ packet: EncryptedFamilyNotebookJoinName) throws -> Data {
        guard (1...6).contains(packet.recipients.count), Set(packet.recipients.map(\.deviceID)).count == packet.recipients.count,
              GroupCanonical.validID(packet.personID), GroupCanonical.validID(packet.deviceID) else { throw FamilyNotebookCryptoError.invalid }
        var fields = [GroupCanonical.text("FNB1.JOIN.NAME.SIGN")]
        for recipient in packet.recipients.sorted(by: { $0.deviceID < $1.deviceID }) {
            guard GroupCanonical.validID(recipient.deviceID), recipient.encapsulatedKey.count == 32,
                  (17...96).contains(recipient.ciphertext.count) else { throw FamilyNotebookCryptoError.invalid }
            fields += [try context(family: packet.familyID, invitation: packet.invitationID, request: packet.requestID,
                person: packet.personID, device: packet.deviceID, recipient: recipient.deviceID), recipient.encapsulatedKey, GroupCanonical.hash(recipient.ciphertext)]
        }
        return try GroupCanonical.fields(fields)
    }
    static func seal(_ name: String, invitation: VerifiedFamilyNotebookInvitation, identity: GroupDeviceIdentity,
                     requestID: UUID, now: Date = Date()) throws -> Data {
        guard now < invitation.expiresAt else { throw FamilyNotebookCryptoError.stale }
        let text = try Data(GroupWire.name(name).utf8), capability = invitation.capability
        var recipients: [EncryptedFamilyNotebookJoinName.Recipient] = []
        for device in invitation.content.approvers.flatMap(\.devices) {
            let info = try context(family: capability.familyID, invitation: capability.invitationID, request: requestID,
                person: identity.personID, device: identity.deviceID, recipient: device.id)
            var sender = try HPKE.Sender(recipientKey: Curve25519.KeyAgreement.PublicKey(rawRepresentation: device.hpkePublicKey), ciphersuite: suite, info: info)
            recipients.append(try .init(deviceID: device.id, encapsulatedKey: sender.encapsulatedKey, ciphertext: sender.seal(text, authenticating: info)))
        }
        let unsigned = try EncryptedFamilyNotebookJoinName(familyID: capability.familyID, invitationID: capability.invitationID,
            requestID: requestID, personID: identity.personID, deviceID: identity.deviceID, recipients: recipients, signature: Data())
        let signature = try identity.signingKey.signature(for: signedBytes(unsigned))
        let packet = EncryptedFamilyNotebookJoinName(familyID: unsigned.familyID, invitationID: unsigned.invitationID, requestID: requestID,
            personID: unsigned.personID, deviceID: unsigned.deviceID, recipients: recipients, signature: signature)
        let result = try GroupWire.encode(packet)
        guard result.count <= 8192 else { throw FamilyNotebookCryptoError.tooLarge }; return result
    }
    static func open(_ encrypted: Data, familyID: UUID, invitationID: UUID, requestID: UUID,
                     personID: String, deviceID: String, signingPublicKey: Data, recipient: GroupDeviceIdentity) throws -> String {
        guard encrypted.count <= 8192, signingPublicKey.count == 32 else { throw FamilyNotebookCryptoError.invalid }
        let packet = try GroupWire.decode(EncryptedFamilyNotebookJoinName.self, encrypted)
        guard packet.familyID == familyID, packet.invitationID == invitationID, packet.requestID == requestID,
              packet.personID == personID, packet.deviceID == deviceID, packet.signature.count == 64,
              try Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey).isValidSignature(packet.signature, for: signedBytes(packet)),
              let wrapped = packet.recipients.first(where: { $0.deviceID == (try? recipient.deviceID) }) else { throw FamilyNotebookCryptoError.untrusted }
        let info = try context(family: familyID, invitation: invitationID, request: requestID, person: personID, device: deviceID, recipient: recipient.deviceID)
        var receiver = try HPKE.Recipient(privateKey: recipient.agreementKey, ciphersuite: suite, info: info, encapsulatedKey: wrapped.encapsulatedKey)
        let bytes = try receiver.open(wrapped.ciphertext, authenticating: info)
        guard let name = String(data: bytes, encoding: .utf8) else { throw FamilyNotebookCryptoError.invalid }
        return try GroupWire.name(name)
    }
}
