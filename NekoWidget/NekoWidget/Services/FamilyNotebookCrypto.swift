import CryptoKit
import Foundation

enum FamilyNotebookCryptoError: Error { case invalid, untrusted, stale, tooLarge }

/// No payer role here: the server's authenticated payer ledger controls
/// billing/administration. A retained, previously trusted family device signs
/// each encryption roster; changing the payer never transfers a private key.
struct FamilyNotebookCryptoMember: Codable, Equatable, Sendable {
    let personID: String
    let identityPublicKey: Data
    let devices: [GroupRosterDevice]
}

struct FamilyNotebookCryptoRoster: Codable, Equatable, Sendable {
    let familyID: UUID
    let epoch: Int
    let previousHash: Data
    let keyCommitment: Data
    let members: [FamilyNotebookCryptoMember]

    func canonicalBytes() throws -> Data {
        guard (1...1_000_000_000).contains(epoch), previousHash.count == 32, keyCommitment.count == 32,
              epoch != 1 || previousHash == Data(repeating: 0, count: 32),
              (1...64).contains(members.count), Set(members.map(\.personID)).count == members.count,
              Set(members.map(\.identityPublicKey)).count == members.count else { throw FamilyNotebookCryptoError.invalid }
        let devices = members.flatMap(\.devices)
        guard Set(devices.map(\.id)).count == devices.count,
              Set(devices.map(\.signingPublicKey)).count == devices.count,
              Set(devices.map(\.hpkePublicKey)).count == devices.count else { throw FamilyNotebookCryptoError.invalid }
        let family = familyID.uuidString.lowercased()
        var fields = [GroupCanonical.text("FNB1.ROSTER"), GroupCanonical.text(family), GroupCanonical.text(String(epoch)),
                      previousHash, keyCommitment, GroupCanonical.text(String(members.count))]
        for member in members.sorted(by: { $0.personID < $1.personID }) {
            guard GroupCanonical.validID(member.personID), member.identityPublicKey.count == 32,
                  (1...3).contains(member.devices.count) else { throw FamilyNotebookCryptoError.invalid }
            let identity = try Curve25519.Signing.PublicKey(rawRepresentation: member.identityPublicKey)
            fields += [GroupCanonical.text(member.personID), member.identityPublicKey, GroupCanonical.text(String(member.devices.count))]
            for device in member.devices.sorted(by: { $0.id < $1.id }) {
                guard GroupCanonical.validID(device.id), device.signingPublicKey.count == 32, device.hpkePublicKey.count == 32,
                      device.personAuthorization.count == 64,
                      identity.isValidSignature(device.personAuthorization,
                        for: try device.authorizationBytes(windowID: family, personID: member.personID)) else {
                    throw FamilyNotebookCryptoError.untrusted
                }
                fields += [GroupCanonical.text(device.id), device.signingPublicKey, device.hpkePublicKey, device.personAuthorization]
            }
        }
        let result = try GroupCanonical.fields(fields)
        guard result.count <= 65_535 else { throw FamilyNotebookCryptoError.tooLarge }
        return result
    }
    func device(_ id: String) -> (person: FamilyNotebookCryptoMember, device: GroupRosterDevice)? {
        for person in members { if let device = person.devices.first(where: { $0.id == id }) { return (person, device) } }
        return nil
    }
}

struct SignedFamilyNotebookRoster: Codable, Equatable, Sendable {
    let roster: FamilyNotebookCryptoRoster
    let signerDeviceID: String
    let signature: Data
    var participationProofs: [FamilyNotebookParticipationBoundary]? = nil
}

/// Must come from local creation, a verified invitation, or a previously
/// verified local checkpoint. Never construct this from untrusted relay JSON.
struct FamilyNotebookRosterPin: Codable, Equatable, Sendable {
    let familyID: UUID
    let epoch: Int
    let hash: Data
}

struct VerifiedFamilyNotebookRoster: Sendable {
    let packet: SignedFamilyNotebookRoster
    let hash: Data
    var roster: FamilyNotebookCryptoRoster { packet.roster }
    var pin: FamilyNotebookRosterPin { .init(familyID: roster.familyID, epoch: roster.epoch, hash: hash) }
    fileprivate init(_ packet: SignedFamilyNotebookRoster, hash: Data) { self.packet = packet; self.hash = hash }
}

enum FamilyNotebookRosterCrypto {
    private static func signedBytes(_ roster: FamilyNotebookCryptoRoster, signer: String) throws -> Data {
        try GroupCanonical.fields([GroupCanonical.text("FNB1.ROSTER.SIGN"), roster.canonicalBytes(), GroupCanonical.text(signer)])
    }
    static func sign(_ roster: FamilyNotebookCryptoRoster, deviceID: String,
                     signingKey: Curve25519.Signing.PrivateKey) throws -> SignedFamilyNotebookRoster {
        guard roster.device(deviceID)?.device.signingPublicKey == signingKey.publicKey.rawRepresentation else {
            throw FamilyNotebookCryptoError.untrusted
        }
        return .init(roster: roster, signerDeviceID: deviceID, signature: try signingKey.signature(for: signedBytes(roster, signer: deviceID)))
    }
    fileprivate static func verifySignature(_ packet: SignedFamilyNotebookRoster) throws -> Data {
        let bytes = try packet.roster.canonicalBytes()
        guard let signer = packet.roster.device(packet.signerDeviceID), packet.signature.count == 64,
              try Curve25519.Signing.PublicKey(rawRepresentation: signer.device.signingPublicKey).isValidSignature(packet.signature,
                for: signedBytes(packet.roster, signer: packet.signerDeviceID)) else { throw FamilyNotebookCryptoError.untrusted }
        return GroupCanonical.hash(bytes)
    }
    static func restore(_ packet: SignedFamilyNotebookRoster, trustedPin: FamilyNotebookRosterPin) throws -> VerifiedFamilyNotebookRoster {
        let hash = try verifySignature(packet)
        guard packet.roster.familyID == trustedPin.familyID, packet.roster.epoch == trustedPin.epoch,
              hash == trustedPin.hash else { throw FamilyNotebookCryptoError.untrusted }
        return .init(packet, hash: hash)
    }
    static func advance(_ packet: SignedFamilyNotebookRoster, previous: VerifiedFamilyNotebookRoster) throws -> VerifiedFamilyNotebookRoster {
        let hash = try verifySignature(packet), roster = packet.roster, old = previous.roster
        guard roster.familyID == old.familyID, roster.epoch == old.epoch + 1, roster.previousHash == previous.hash,
              roster.keyCommitment != old.keyCommitment else { throw FamilyNotebookCryptoError.stale }
        guard let before = old.device(packet.signerDeviceID), let after = roster.device(packet.signerDeviceID),
              before.person.personID == after.person.personID, before.device == after.device else {
            throw FamilyNotebookCryptoError.untrusted
        }
        for person in roster.members {
            if let prior = old.members.first(where: { $0.personID == person.personID }), prior.identityPublicKey != person.identityPublicKey {
                throw FamilyNotebookCryptoError.untrusted
            }
            for device in person.devices {
                if let prior = old.device(device.id), prior.person.personID != person.personID || prior.device != device {
                    throw FamilyNotebookCryptoError.untrusted
                }
            }
        }
        return .init(packet, hash: hash)
    }
}

/// An old key is usable only through a hash chain ending at the current pinned
/// roster. Two independently signed rosters from different forks are not enough.
struct FamilyNotebookKeyContext: Sendable {
    let current: VerifiedFamilyNotebookRoster
    let source: VerifiedFamilyNotebookRoster
    private init(current: VerifiedFamilyNotebookRoster, source: VerifiedFamilyNotebookRoster) { self.current = current; self.source = source }
    static func current(_ roster: VerifiedFamilyNotebookRoster) -> Self { .init(current: roster, source: roster) }
    func previous(_ packet: SignedFamilyNotebookRoster) throws -> Self {
        let hash = try FamilyNotebookRosterCrypto.verifySignature(packet)
        guard packet.roster.familyID == source.roster.familyID, packet.roster.epoch + 1 == source.roster.epoch,
              hash == source.roster.previousHash else { throw FamilyNotebookCryptoError.untrusted }
        let earlier = VerifiedFamilyNotebookRoster(packet, hash: hash)
        _ = try FamilyNotebookRosterCrypto.advance(source.packet, previous: earlier)
        return .init(current: current, source: earlier)
    }
}

struct FamilyNotebookKeyEnvelope: Codable, Equatable, Sendable {
    let familyID: UUID
    let keyEpoch: Int
    let keyRosterHash: Data
    let recipientRosterHash: Data
    let recipientDeviceID: String
    let signerDeviceID: String
    let encapsulatedKey: Data
    let ciphertext: Data
    let signature: Data
}

@available(iOS 17.0, macOS 14.0, *)
enum FamilyNotebookKeyCrypto {
    private static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    private static func info(_ context: FamilyNotebookKeyContext, recipient: String) throws -> Data {
        try GroupCanonical.fields([GroupCanonical.text("FNB1.KEY"), GroupCanonical.text(context.current.roster.familyID.uuidString.lowercased()),
            GroupCanonical.text(String(context.source.roster.epoch)), context.source.hash, context.current.hash, GroupCanonical.text(recipient)])
    }
    private static func signedBytes(info: Data, encapsulated: Data, ciphertext: Data, signer: String) throws -> Data {
        try GroupCanonical.fields([GroupCanonical.text("FNB1.KEY.SIGN"), info, encapsulated, ciphertext, GroupCanonical.text(signer)])
    }
    static func wrap(_ key: Data, context: FamilyNotebookKeyContext, recipientID: String, signerID: String,
                     signingKey: Curve25519.Signing.PrivateKey) throws -> FamilyNotebookKeyEnvelope {
        guard key.count == 32, GroupCanonical.hash(key) == context.source.roster.keyCommitment,
              let recipient = context.current.roster.device(recipientID), let signer = context.current.roster.device(signerID),
              signer.device.signingPublicKey == signingKey.publicKey.rawRepresentation else { throw FamilyNotebookCryptoError.untrusted }
        let info = try info(context, recipient: recipientID)
        var sender = try HPKE.Sender(recipientKey: Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient.device.hpkePublicKey),
                                    ciphersuite: suite, info: info)
        let ciphertext = try sender.seal(key, authenticating: info)
        let signature = try signingKey.signature(for: signedBytes(info: info, encapsulated: sender.encapsulatedKey, ciphertext: ciphertext, signer: signerID))
        return .init(familyID: context.current.roster.familyID, keyEpoch: context.source.roster.epoch, keyRosterHash: context.source.hash,
            recipientRosterHash: context.current.hash, recipientDeviceID: recipientID, signerDeviceID: signerID,
            encapsulatedKey: sender.encapsulatedKey, ciphertext: ciphertext, signature: signature)
    }
    static func unwrap(_ envelope: FamilyNotebookKeyEnvelope, context: FamilyNotebookKeyContext, recipientID: String,
                       agreementKey: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        guard envelope.familyID == context.current.roster.familyID, envelope.keyEpoch == context.source.roster.epoch,
              envelope.keyRosterHash == context.source.hash, envelope.recipientRosterHash == context.current.hash,
              envelope.recipientDeviceID == recipientID, let recipient = context.current.roster.device(recipientID),
              recipient.device.hpkePublicKey == agreementKey.publicKey.rawRepresentation,
              let signer = context.current.roster.device(envelope.signerDeviceID), envelope.encapsulatedKey.count == 32,
              envelope.ciphertext.count == 48, envelope.signature.count == 64 else { throw FamilyNotebookCryptoError.untrusted }
        let info = try info(context, recipient: recipientID)
        guard try Curve25519.Signing.PublicKey(rawRepresentation: signer.device.signingPublicKey).isValidSignature(envelope.signature,
          for: signedBytes(info: info, encapsulated: envelope.encapsulatedKey, ciphertext: envelope.ciphertext, signer: envelope.signerDeviceID)) else {
            throw FamilyNotebookCryptoError.untrusted
        }
        var recipientKey = try HPKE.Recipient(privateKey: agreementKey, ciphersuite: suite, info: info, encapsulatedKey: envelope.encapsulatedKey)
        let key = try recipientKey.open(envelope.ciphertext, authenticating: info)
        guard key.count == 32, GroupCanonical.hash(key) == context.source.roster.keyCommitment else { throw FamilyNotebookCryptoError.untrusted }
        return key
    }
}

struct EncryptedFamilyNotebookOperation: Codable, Equatable, Sendable {
    let familyID: UUID
    let keyEpoch: Int
    let rosterHash: Data
    let operationID: UUID
    let personID: String
    let deviceID: String
    let ciphertext: Data
    let signature: Data
}

enum FamilyNotebookOperationCrypto {
    static let maximumCiphertextBytes = 1_048_576
    private static func aad(familyID: UUID, epoch: Int, hash: Data, operationID: UUID, personID: String, deviceID: String, size: Int) throws -> Data {
        try GroupCanonical.fields([GroupCanonical.text("FNB1.OPERATION"), GroupCanonical.text(familyID.uuidString.lowercased()),
            GroupCanonical.text(String(epoch)), hash, GroupCanonical.text(operationID.uuidString.lowercased()),
            GroupCanonical.text(personID), GroupCanonical.text(deviceID), GroupCanonical.text(String(size))])
    }
    private static func signedBytes(_ aad: Data, ciphertext: Data) throws -> Data {
        try GroupCanonical.fields([GroupCanonical.text("FNB1.OPERATION.SIGN"), aad, GroupCanonical.hash(ciphertext)])
    }
    static func seal(_ operation: FamilyNotebookOperation, roster: VerifiedFamilyNotebookRoster, key: Data,
                     signingKey: Curve25519.Signing.PrivateKey) throws -> EncryptedFamilyNotebookOperation {
        try FamilyNotebookCore.validate(operation)
        guard operation.familyID == roster.roster.familyID, key.count == 32, GroupCanonical.hash(key) == roster.roster.keyCommitment,
              let author = roster.roster.device(operation.version.deviceID), author.person.personID == operation.author.personID,
              author.device.signingPublicKey == signingKey.publicKey.rawRepresentation else { throw FamilyNotebookCryptoError.untrusted }
        let plaintext = try GroupWire.encode(operation), size = plaintext.count + 28
        guard size <= maximumCiphertextBytes else { throw FamilyNotebookCryptoError.tooLarge }
        let aad = try aad(familyID: operation.familyID, epoch: roster.roster.epoch, hash: roster.hash, operationID: operation.id,
                          personID: operation.author.personID, deviceID: operation.version.deviceID, size: size)
        guard let ciphertext = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), authenticating: aad).combined else {
            throw FamilyNotebookCryptoError.invalid
        }
        return .init(familyID: operation.familyID, keyEpoch: roster.roster.epoch, rosterHash: roster.hash, operationID: operation.id,
                     personID: operation.author.personID, deviceID: operation.version.deviceID, ciphertext: ciphertext,
                     signature: try signingKey.signature(for: signedBytes(aad, ciphertext: ciphertext)))
    }
    static func open(_ packet: EncryptedFamilyNotebookOperation, roster: VerifiedFamilyNotebookRoster, key: Data) throws -> FamilyNotebookOperation {
        guard case .known(let operation) = try openRetaining(packet, roster: roster, key: key) else {
            throw FamilyNotebookCryptoError.untrusted
        }
        return operation
    }
    static func openRetaining(_ packet: EncryptedFamilyNotebookOperation, roster: VerifiedFamilyNotebookRoster, key: Data) throws -> FamilyNotebookReceivedOperation {
        guard packet.familyID == roster.roster.familyID, packet.keyEpoch == roster.roster.epoch, packet.rosterHash == roster.hash,
              (29...maximumCiphertextBytes).contains(packet.ciphertext.count), packet.signature.count == 64,
              key.count == 32, GroupCanonical.hash(key) == roster.roster.keyCommitment,
              let author = roster.roster.device(packet.deviceID), author.person.personID == packet.personID else { throw FamilyNotebookCryptoError.untrusted }
        let aad = try aad(familyID: packet.familyID, epoch: packet.keyEpoch, hash: packet.rosterHash, operationID: packet.operationID,
                          personID: packet.personID, deviceID: packet.deviceID, size: packet.ciphertext.count)
        guard try Curve25519.Signing.PublicKey(rawRepresentation: author.device.signingPublicKey).isValidSignature(packet.signature,
          for: signedBytes(aad, ciphertext: packet.ciphertext)) else { throw FamilyNotebookCryptoError.untrusted }
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: packet.ciphertext), using: SymmetricKey(data: key), authenticating: aad)
        let retained = FamilyNotebookOpaqueOperation(plaintext: plaintext)
        let header = try retained.header()
        guard header.familyID == packet.familyID, header.version.operationID == packet.operationID,
              header.version.deviceID == packet.deviceID, header.author.personID == packet.personID else {
            throw FamilyNotebookCryptoError.untrusted
        }
        return try FamilyNotebookReceivedOperation.decode(plaintext)
    }
}

/// This reference is only serialized inside the E2EE notebook operation.
/// It must never be used as a plaintext request, URL, analytics event or log.
struct FamilyNotebookRepresentativePhotoReference: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let assetID: UUID
    let slotID: UUID
    let revision: Int
    let keyEpoch: Int
    let rosterHash: Data
    let ciphertextSHA256: Data
    let ciphertextBytes: Int
    let contentKey: Data
    let mediaType: String
    let pixelWidth: Int
    let pixelHeight: Int
    func validate() throws {
        guard schemaVersion == 1, (1...1_000_000_000).contains(revision),
              (1...1_000_000_000).contains(keyEpoch), rosterHash.count == 32,
              ciphertextSHA256.count == 32, contentKey.count == 32,
              (29...200_028).contains(ciphertextBytes), mediaType == "image/jpeg",
              (1...1024).contains(pixelWidth), (1...1024).contains(pixelHeight)
        else { throw FamilyNotebookCryptoError.invalid }
    }
}

enum FamilyNotebookRepresentativePhotoCrypto {
    /// Stable opaque slot across key epochs; never send the local or shared cat ID.
    static func slotID(familyID: UUID, catID: UUID) -> UUID {
        var bytes = Array(GroupCanonical.hash(Data(("FNB1.PHOTO-SLOT.1|" + familyID.uuidString.lowercased() + "|" + catID.uuidString.lowercased()).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 15) | 128; bytes[8] = (bytes[8] & 63) | 128
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }

    private static func aad(familyID: UUID, slotID: UUID, assetID: UUID, revision: Int,
                            keyEpoch: Int, rosterHash: Data, size: Int) throws -> Data {
        try GroupCanonical.fields([GroupCanonical.text("FNB1.REPRESENTATIVE-PHOTO.1"),
            GroupCanonical.text(familyID.uuidString.lowercased()), GroupCanonical.text(slotID.uuidString.lowercased()),
            GroupCanonical.text(assetID.uuidString.lowercased()), GroupCanonical.text(String(revision)),
            GroupCanonical.text(String(keyEpoch)), rosterHash, GroupCanonical.text(String(size))])
    }
    static func seal(jpeg: Data, width: Int, height: Int, familyID: UUID, slotID: UUID,
                     assetID: UUID, revision: Int, roster: VerifiedFamilyNotebookRoster) throws
        -> (reference: FamilyNotebookRepresentativePhotoReference, ciphertext: Data) {
        guard !jpeg.isEmpty, jpeg.count <= 200_000, (1...1024).contains(width), (1...1024).contains(height),
              roster.roster.familyID == familyID, (1...1_000_000_000).contains(revision)
        else { throw FamilyNotebookCryptoError.tooLarge }
        let key = SymmetricKey(size: .bits256)
        let context = try aad(familyID: familyID, slotID: slotID, assetID: assetID, revision: revision,
            keyEpoch: roster.roster.epoch, rosterHash: roster.hash, size: jpeg.count)
        guard let bytes = try AES.GCM.seal(jpeg, using: key, authenticating: context).combined
        else { throw FamilyNotebookCryptoError.invalid }
        let reference = FamilyNotebookRepresentativePhotoReference(schemaVersion: 1, assetID: assetID,
            slotID: slotID, revision: revision, keyEpoch: roster.roster.epoch, rosterHash: roster.hash,
            ciphertextSHA256: GroupCanonical.hash(bytes), ciphertextBytes: bytes.count,
            contentKey: key.withUnsafeBytes { Data($0) }, mediaType: "image/jpeg", pixelWidth: width, pixelHeight: height)
        try reference.validate()
        return (reference, bytes)
    }
    static func open(_ bytes: Data, reference: FamilyNotebookRepresentativePhotoReference,
                     familyID: UUID, roster: VerifiedFamilyNotebookRoster) throws -> Data {
        try reference.validate()
        guard roster.roster.familyID == familyID, roster.roster.epoch == reference.keyEpoch,
              roster.hash == reference.rosterHash, bytes.count == reference.ciphertextBytes,
              GroupCanonical.hash(bytes) == reference.ciphertextSHA256 else { throw FamilyNotebookCryptoError.untrusted }
        let context = try aad(familyID: familyID, slotID: reference.slotID, assetID: reference.assetID,
            revision: reference.revision, keyEpoch: reference.keyEpoch, rosterHash: reference.rosterHash, size: bytes.count - 28)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: SymmetricKey(data: reference.contentKey), authenticating: context)
    }
}

/// Participation evidence only. It does NOT restrict the notebook's existing
/// complete-history sharing with newly admitted family members.
struct FamilyNotebookParticipationBoundary: Codable, Equatable, Sendable {
    let environment: String; let familyID: UUID; let personID: String
    let admissionEpoch: Int; let rosterHash: Data; let signerDeviceID: String; let signature: Data
    func signedBytes() throws -> Data {
        try GroupCanonical.fields(["FNB1.RECOVERY.PARTICIPATION.V1", environment, familyID.uuidString.lowercased(),
            personID, String(admissionEpoch)].map(GroupCanonical.text) + [rosterHash, GroupCanonical.text(signerDeviceID)])
    }
    func verifies(in head: VerifiedFamilyNotebookRoster, environment: String) -> Bool {
        guard ["staging", "production"].contains(environment), self.environment == environment,
              familyID == head.roster.familyID, rosterHash == head.hash,
              (1...head.roster.epoch).contains(admissionEpoch),
              head.roster.members.contains(where: { $0.personID == personID }),
              signerDeviceID == head.packet.signerDeviceID,
              let signer = head.roster.device(signerDeviceID), let bytes = try? signedBytes(),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signer.device.signingPublicKey) else { return false }
        return key.isValidSignature(signature, for: bytes)
    }
    static func forNewAdmission(head: VerifiedFamilyNotebookRoster, environment: String, personID: String,
        signerID: String, key: Curve25519.Signing.PrivateKey) throws -> Self {
        try make(head: head, environment: environment, personID: personID, epoch: head.roster.epoch, signerID: signerID, key: key)
    }
    static func carry(_ proof: Self, previous: VerifiedFamilyNotebookRoster, next: VerifiedFamilyNotebookRoster,
        environment: String, signerID: String, key: Curve25519.Signing.PrivateKey) throws -> Self {
        guard proof.verifies(in: previous, environment: environment), next.roster.previousHash == previous.hash,
              next.roster.epoch == previous.roster.epoch + 1 else { throw FamilyNotebookCryptoError.untrusted }
        return try make(head: next, environment: environment, personID: proof.personID, epoch: proof.admissionEpoch, signerID: signerID, key: key)
    }
    private static func make(head: VerifiedFamilyNotebookRoster, environment: String, personID: String, epoch: Int,
        signerID: String, key: Curve25519.Signing.PrivateKey) throws -> Self {
        let value = Self(environment: environment, familyID: head.roster.familyID, personID: personID,
            admissionEpoch: epoch, rosterHash: head.hash, signerDeviceID: signerID, signature: Data())
        let signed = Self(environment: environment, familyID: value.familyID, personID: personID, admissionEpoch: epoch,
            rosterHash: head.hash, signerDeviceID: signerID, signature: try key.signature(for: value.signedBytes()))
        guard signed.verifies(in: head, environment: environment) else { throw FamilyNotebookCryptoError.untrusted }; return signed
    }
}
