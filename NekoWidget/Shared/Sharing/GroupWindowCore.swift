import CryptoKit
import Foundation

enum GroupProtocolError: Error {
    case invalidRoster, invalidSignature, invalidEnvelope, staleRevision, invalidPhoto
}

/// Length-prefixed fields, never ambiguous JSON or delimiter concatenation.
enum GroupCanonical {
    static func fields(_ fields: [Data]) throws -> Data {
        var result = Data()
        for field in fields {
            guard field.count <= Int(UInt16.max) else { throw GroupProtocolError.invalidRoster }
            result.append(UInt8(field.count >> 8)); result.append(UInt8(field.count & 255))
            result.append(field)
        }
        return result
    }
    static func text(_ text: String) -> Data { Data(text.utf8) }
    static func hash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    static func validID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

struct GroupRosterDevice: Codable, Equatable, Sendable {
    let id: String
    let signingPublicKey: Data
    let hpkePublicKey: Data
    /// Person identity signature, scoped to this exact window and both device keys.
    let personAuthorization: Data

    func authorizationBytes(windowID: String, personID: String) throws -> Data {
        try GroupCanonical.fields(["NW3.DEVICE", windowID, personID, id].map(GroupCanonical.text)
            + [signingPublicKey, hpkePublicKey])
    }
}

struct GroupRosterMember: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case owner, member }
    let participantID: String
    let personID: String
    let identityPublicKey: Data
    let role: Role
    let devices: [GroupRosterDevice]
}

/// Only active members/devices. Historical sender IDs remain in the relay's
/// separate membership/history records, never by rewriting old photo records.
struct GroupRoster: Codable, Equatable, Sendable {
    let windowID: String
    let revision: Int
    let keyEpoch: Int
    let previousHash: Data
    let ownerPersonID: String
    let members: [GroupRosterMember]

    /// Certificates are validated separately. Ordering or re-signing the same
    /// device authorization is not a membership/key change.
    fileprivate func membershipKeyBytes() throws -> Data {
        var fields = [GroupCanonical.text(ownerPersonID)]
        for member in members.sorted(by: { $0.participantID < $1.participantID }) {
            fields += [GroupCanonical.text(member.participantID), GroupCanonical.text(member.personID),
                       member.identityPublicKey, GroupCanonical.text(member.role.rawValue),
                       GroupCanonical.text(String(member.devices.count))]
            for device in member.devices.sorted(by: { $0.id < $1.id }) {
                fields += [GroupCanonical.text(device.id), device.signingPublicKey, device.hpkePublicKey]
            }
        }
        return try GroupCanonical.fields(fields)
    }

    func canonicalBytes() throws -> Data {
        guard GroupCanonical.validID(windowID), GroupCanonical.validID(ownerPersonID),
              (1...9_007_199_254_740_991).contains(revision), (1...9_007_199_254_740_991).contains(keyEpoch), previousHash.count == 32,
              (1...6).contains(members.count),
              Set(members.map(\.participantID)).count == members.count,
              Set(members.map(\.personID)).count == members.count,
              Set(members.map(\.identityPublicKey)).count == members.count,
              members.filter({ $0.role == .owner && $0.personID == ownerPersonID }).count == 1,
              members.filter({ $0.role == .owner }).count == 1 else { throw GroupProtocolError.invalidRoster }
        let allDevices = members.flatMap(\.devices)
        guard Set(allDevices.map(\.id)).count == allDevices.count,
              Set(allDevices.map(\.signingPublicKey)).count == allDevices.count,
              Set(allDevices.map(\.hpkePublicKey)).count == allDevices.count else { throw GroupProtocolError.invalidRoster }
        var fields = ["NW3.ROSTER", "3", windowID, String(revision)].map(GroupCanonical.text)
        fields += [previousHash, GroupCanonical.text(String(keyEpoch)), GroupCanonical.text(ownerPersonID),
                   GroupCanonical.text(String(members.count))]
        for member in members.sorted(by: { $0.participantID.utf8.lexicographicallyPrecedes($1.participantID.utf8) }) {
            guard GroupCanonical.validID(member.participantID), GroupCanonical.validID(member.personID),
                  member.identityPublicKey.count == 32, (1...3).contains(member.devices.count) else { throw GroupProtocolError.invalidRoster }
            let identity = try Curve25519.Signing.PublicKey(rawRepresentation: member.identityPublicKey)
            fields += [GroupCanonical.text(member.participantID), GroupCanonical.text(member.personID),
                       member.identityPublicKey, GroupCanonical.text(member.role.rawValue),
                       GroupCanonical.text(String(member.devices.count))]
            for device in member.devices.sorted(by: { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }) {
                guard GroupCanonical.validID(device.id), device.signingPublicKey.count == 32,
                      device.hpkePublicKey.count == 32, device.personAuthorization.count == 64,
                      identity.isValidSignature(device.personAuthorization,
                        for: try device.authorizationBytes(windowID: windowID, personID: member.personID))
                else { throw GroupProtocolError.invalidRoster }
                fields += [GroupCanonical.text(device.id), device.signingPublicKey,
                           device.hpkePublicKey, device.personAuthorization]
            }
        }
        let bytes = try GroupCanonical.fields(fields)
        guard bytes.count <= 65_536 else { throw GroupProtocolError.invalidRoster }
        return bytes
    }
}

struct GroupTrustAnchor: Codable, Equatable, Sendable {
    /// Obtained from local creation or the invitation, never replaced by relay JSON.
    let windowID: String
    let ownerPersonID: String
    let ownerIdentityPublicKey: Data
}

struct SignedGroupRoster: Codable, Equatable, Sendable {
    let roster: GroupRoster
    let signerDeviceID: String
    let signature: Data
}

/// Construction is restricted to signature/chain validation. Crypto methods
/// accept this type, not an arbitrary server-provided GroupRoster.
struct VerifiedGroupRoster: Sendable {
    let roster: GroupRoster
    let hash: Data
    let signerDeviceID: String
    let signerPublicKey: Data
    fileprivate init(roster: GroupRoster, hash: Data, signerDeviceID: String, signerPublicKey: Data) {
        self.roster = roster; self.hash = hash
        self.signerDeviceID = signerDeviceID; self.signerPublicKey = signerPublicKey
    }
    func device(id: String) -> (member: GroupRosterMember, device: GroupRosterDevice)? {
        for member in roster.members {
            if let device = member.devices.first(where: { $0.id == id }) { return (member, device) }
        }
        return nil
    }
}

enum GroupRosterVerifier {
    static func verify(_ packet: SignedGroupRoster, anchor: GroupTrustAnchor,
                       previous: VerifiedGroupRoster? = nil) throws -> VerifiedGroupRoster {
        try verifyPacket(packet, anchor: anchor, previous: previous, restoredPin: nil)
    }

    /// These pins MUST come from this iPhone's Keychain record written after
    /// verification, never from relay JSON. Restoring the saved head avoids
    /// retaining/replaying an ever-growing roster chain on every app launch.
    static func restoreLocalCheckpoint(_ packet: SignedGroupRoster, anchor: GroupTrustAnchor,
                                       pinnedRevision: Int, pinnedHash: Data) throws -> VerifiedGroupRoster {
        guard pinnedRevision > 0, pinnedHash.count == 32,
              packet.roster.revision == pinnedRevision,
              GroupCanonical.hash(try packet.roster.canonicalBytes()) == pinnedHash
        else { throw GroupProtocolError.staleRevision }
        return try verifyPacket(packet, anchor: anchor, previous: nil, restoredPin: pinnedHash)
    }

    private static func verifyPacket(_ packet: SignedGroupRoster, anchor: GroupTrustAnchor,
                                     previous: VerifiedGroupRoster?, restoredPin: Data?) throws -> VerifiedGroupRoster {
        let roster = packet.roster
        let bytes = try roster.canonicalBytes()
        guard roster.windowID == anchor.windowID, roster.ownerPersonID == anchor.ownerPersonID,
              let owner = roster.members.first(where: { $0.role == .owner }),
              owner.identityPublicKey == anchor.ownerIdentityPublicKey,
              let signingDevice = owner.devices.first(where: { $0.id == packet.signerDeviceID }),
              packet.signature.count == 64 else { throw GroupProtocolError.invalidSignature }
        if let previous {
            let old = previous.roster
            guard old.windowID == roster.windowID, roster.revision > old.revision,
                  roster.revision - old.revision == 1, roster.previousHash == previous.hash,
                  roster.keyEpoch >= old.keyEpoch, roster.keyEpoch - old.keyEpoch <= 1
            else { throw GroupProtocolError.staleRevision }
            // Previously authorized owner devices are the only transition signers.
            guard let oldSigner = previous.device(id: packet.signerDeviceID),
                  oldSigner.member.role == .owner,
                  oldSigner.device.id == signingDevice.id,
                  oldSigner.device.signingPublicKey == signingDevice.signingPublicKey,
                  oldSigner.device.hpkePublicKey == signingDevice.hpkePublicKey else { throw GroupProtocolError.invalidSignature }
            let oldKeys = try old.membershipKeyBytes()
            let newKeys = try roster.membershipKeyBytes()
            if oldKeys != newKeys && roster.keyEpoch == old.keyEpoch { throw GroupProtocolError.invalidRoster }
        } else if restoredPin == nil {
            guard roster.revision == 1, roster.keyEpoch == 1,
                  roster.previousHash == Data(repeating: 0, count: 32) else { throw GroupProtocolError.staleRevision }
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: signingDevice.signingPublicKey)
        let signed = try GroupCanonical.fields([GroupCanonical.text("NW3.ROSTER.SIGN"), bytes,
                                               GroupCanonical.text(packet.signerDeviceID)])
        guard publicKey.isValidSignature(packet.signature, for: signed) else { throw GroupProtocolError.invalidSignature }
        return .init(roster: roster, hash: GroupCanonical.hash(bytes), signerDeviceID: packet.signerDeviceID,
                     signerPublicKey: signingDevice.signingPublicKey)
    }

    static func sign(_ roster: GroupRoster, deviceID: String,
                     privateKey: Curve25519.Signing.PrivateKey) throws -> SignedGroupRoster {
        let bytes = try roster.canonicalBytes()
        let message = try GroupCanonical.fields([GroupCanonical.text("NW3.ROSTER.SIGN"), bytes, GroupCanonical.text(deviceID)])
        return .init(roster: roster, signerDeviceID: deviceID, signature: try privateKey.signature(for: message))
    }
}

struct GroupKeyEnvelope: Codable, Equatable, Sendable {
    let windowID: String
    let keyEpoch: Int
    let rosterHash: Data
    let deviceID: String
    let encapsulatedKey: Data
    let ciphertext: Data
    let signerDeviceID: String
    let signature: Data
}

@available(iOS 17.0, macOS 14.0, *)
enum GroupHPKE {
    private static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    private static func context(_ roster: VerifiedGroupRoster, deviceID: String) throws -> Data {
        try GroupCanonical.fields(["NW3.KEY", roster.roster.windowID, String(roster.roster.keyEpoch)].map(GroupCanonical.text)
            + [roster.hash, GroupCanonical.text(deviceID)])
    }
    private static func signatureBytes(info: Data, encapsulatedKey: Data, ciphertext: Data, signer: String) throws -> Data {
        try GroupCanonical.fields([GroupCanonical.text("NW3.KEY.SIGN"), info, encapsulatedKey, ciphertext, GroupCanonical.text(signer)])
    }
    static func wrap(roomKey: SymmetricKey, for deviceID: String, roster: VerifiedGroupRoster,
                     signerID: String, signingKey: Curve25519.Signing.PrivateKey) throws -> GroupKeyEnvelope {
        guard roomKey.bitCount == 256, let target = roster.device(id: deviceID),
              let signer = roster.device(id: signerID), signer.member.role == .owner,
              signer.device.signingPublicKey == signingKey.publicKey.rawRepresentation else { throw GroupProtocolError.invalidEnvelope }
        let info = try context(roster, deviceID: deviceID)
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: target.device.hpkePublicKey)
        var sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: suite, info: info)
        let cipher = try sender.seal(roomKey.withUnsafeBytes { Data($0) }, authenticating: info)
        let signature = try signingKey.signature(for: signatureBytes(info: info, encapsulatedKey: sender.encapsulatedKey, ciphertext: cipher, signer: signerID))
        return .init(windowID: roster.roster.windowID, keyEpoch: roster.roster.keyEpoch, rosterHash: roster.hash,
            deviceID: deviceID, encapsulatedKey: sender.encapsulatedKey, ciphertext: cipher, signerDeviceID: signerID, signature: signature)
    }
    static func unwrap(_ envelope: GroupKeyEnvelope, deviceID: String,
                       agreementKey: Curve25519.KeyAgreement.PrivateKey, roster: VerifiedGroupRoster) throws -> SymmetricKey {
        guard envelope.windowID == roster.roster.windowID, envelope.keyEpoch == roster.roster.keyEpoch,
              envelope.rosterHash == roster.hash, envelope.deviceID == deviceID,
              let target = roster.device(id: deviceID), target.device.hpkePublicKey == agreementKey.publicKey.rawRepresentation,
              let signer = roster.device(id: envelope.signerDeviceID), signer.member.role == .owner,
              envelope.encapsulatedKey.count == 32, envelope.ciphertext.count == 48, envelope.signature.count == 64 else { throw GroupProtocolError.invalidEnvelope }
        let info = try context(roster, deviceID: deviceID)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: signer.device.signingPublicKey)
        guard key.isValidSignature(envelope.signature,
            for: try signatureBytes(info: info, encapsulatedKey: envelope.encapsulatedKey, ciphertext: envelope.ciphertext, signer: envelope.signerDeviceID))
        else { throw GroupProtocolError.invalidSignature }
        var recipient = try HPKE.Recipient(privateKey: agreementKey, ciphersuite: suite, info: info, encapsulatedKey: envelope.encapsulatedKey)
        let bytes = try recipient.open(envelope.ciphertext, authenticating: info)
        guard bytes.count == 32 else { throw GroupProtocolError.invalidEnvelope }
        return SymmetricKey(data: bytes)
    }
}

struct GroupEncryptedPhoto: Codable, Equatable, Sendable {
    let clientMomentID: String
    let senderDeviceID: String
    let ciphertext: Data
    let signature: Data
}

enum GroupPhotoCrypto {
    private static let maximumCiphertextBytes = 1_048_576
    private static func aad(clientMomentID: String, senderDeviceID: String,
                            size: Int, roster: VerifiedGroupRoster) throws -> Data {
        guard GroupCanonical.validID(clientMomentID), let sender = roster.device(id: senderDeviceID),
              (29...maximumCiphertextBytes).contains(size) else { throw GroupProtocolError.invalidPhoto }
        return try GroupCanonical.fields(["NW3.PHOTO", roster.roster.windowID, clientMomentID,
            String(roster.roster.keyEpoch)].map(GroupCanonical.text) + [roster.hash]
            + [sender.member.participantID, senderDeviceID, String(size)].map(GroupCanonical.text))
    }
    private static func signed(aad: Data, ciphertext: Data) throws -> Data {
        try GroupCanonical.fields([GroupCanonical.text("NW3.PHOTO.SIGN"), aad, GroupCanonical.hash(ciphertext)])
    }
    static func seal(_ jpeg: Data, clientMomentID: String, senderDeviceID: String,
                     roomKey: SymmetricKey, signingKey: Curve25519.Signing.PrivateKey,
                     roster: VerifiedGroupRoster) throws -> GroupEncryptedPhoto {
        guard roomKey.bitCount == 256, !jpeg.isEmpty, jpeg.count <= maximumCiphertextBytes - 28,
              roster.device(id: senderDeviceID)?.device.signingPublicKey == signingKey.publicKey.rawRepresentation
        else { throw GroupProtocolError.invalidPhoto }
        let bytes = try aad(clientMomentID: clientMomentID, senderDeviceID: senderDeviceID,
                            size: jpeg.count + 28, roster: roster)
        let box = try AES.GCM.seal(jpeg, using: roomKey, authenticating: bytes)
        guard let cipher = box.combined else { throw GroupProtocolError.invalidPhoto }
        return .init(clientMomentID: clientMomentID, senderDeviceID: senderDeviceID,
            ciphertext: cipher, signature: try signingKey.signature(for: signed(aad: bytes, ciphertext: cipher)))
    }
    static func open(_ photo: GroupEncryptedPhoto, roomKey: SymmetricKey,
                     roster: VerifiedGroupRoster) throws -> Data {
        guard roomKey.bitCount == 256, photo.signature.count == 64,
              let sender = roster.device(id: photo.senderDeviceID) else { throw GroupProtocolError.invalidPhoto }
        let bytes = try aad(clientMomentID: photo.clientMomentID, senderDeviceID: photo.senderDeviceID,
                            size: photo.ciphertext.count, roster: roster)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: sender.device.signingPublicKey)
        guard publicKey.isValidSignature(photo.signature, for: try signed(aad: bytes, ciphertext: photo.ciphertext))
        else { throw GroupProtocolError.invalidSignature }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: photo.ciphertext), using: roomKey, authenticating: bytes)
    }
}
