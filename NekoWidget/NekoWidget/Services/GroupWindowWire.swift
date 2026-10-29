import CryptoKit
import Foundation

enum GroupWire {
    static func base64(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func bytes(_ text: String, count: Int? = nil) throws -> Data {
        guard text.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 })
        else { throw GroupClientError.invalidResponse }
        let padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), base64(data) == text,
              count.map({ $0 == data.count }) ?? true else { throw GroupClientError.invalidResponse }
        return data
    }
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ text: String) { stringValue = text }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    static func encoder() -> JSONEncoder {
        let value = JSONEncoder()
        value.outputFormatting = [.sortedKeys]
        value.keyEncodingStrategy = .custom { path in
            let key = path.last!.stringValue
            return Key(key.hasSuffix("ID") ? String(key.dropLast(2)) + "Id" : key)
        }
        value.dataEncodingStrategy = .custom { bytes, encoder in
            var container = encoder.singleValueContainer(); try container.encode(base64(bytes))
        }
        return value
    }
    static func decoder() -> JSONDecoder {
        let value = JSONDecoder()
        value.keyDecodingStrategy = .custom { path in
            let key = path.last!.stringValue
            return Key(key.hasSuffix("Id") ? String(key.dropLast(2)) + "ID" : key)
        }
        value.dataDecodingStrategy = .custom { decoder in
            try bytes(decoder.singleValueContainer().decode(String.self))
        }
        return value
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data { try encoder().encode(value) }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T { try decoder().decode(type, from: data) }
    static func randomID() -> String { base64(SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }) }
    static func name(_ value: String) throws -> String {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 80,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw GroupClientError.invalidResponse }
        return value
    }
    static func phrase(_ identity: Data) -> String {
        let text = GroupCanonical.hash(identity).prefix(6).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: 12, by: 4).map {
            let start = text.index(text.startIndex, offsetBy: $0)
            return String(text[start..<text.index(start, offsetBy: 4)])
        }.joined(separator: " ")
    }
}

enum GroupManagementCanonical {
    static func rename(windowID: String, revision: Int, keyEpoch: Int, rosterHash: Data,
                       nameRevision: Int, operationID: String, ciphertextHash: Data) throws -> Data {
        try GroupCanonical.fields(["NW3.WINDOW-NAME", windowID, String(revision), String(keyEpoch)].map(GroupCanonical.text)
            + [rosterHash, GroupCanonical.text(String(nameRevision)), GroupCanonical.text(operationID), ciphertextHash])
    }
    static func close(windowID: String, revision: Int, keyEpoch: Int, rosterHash: Data, operationID: String) throws -> Data {
        try GroupCanonical.fields(["NW3.WINDOW-CLOSE", windowID, String(revision), String(keyEpoch)].map(GroupCanonical.text)
            + [rosterHash, GroupCanonical.text(operationID)])
    }
}

@available(iOS 17.0, macOS 14.0, *)
enum GroupNameCrypto {
    private struct SignedName: Codable { let name: String; let signerDeviceID: String; let signature: Data }
    private static func context(_ roster: VerifiedGroupRoster, slot: String) throws -> Data {
        try GroupCanonical.fields(["NW3.NAME", roster.roster.windowID, String(roster.roster.keyEpoch), slot].map(GroupCanonical.text) + [roster.hash])
    }
    static func seal(_ name: String, slot: String, key: SymmetricKey, roster: VerifiedGroupRoster,
                     signerID: String, signingKey: Curve25519.Signing.PrivateKey) throws -> Data {
        let text = try GroupWire.name(name), aad = try context(roster, slot: slot)
        guard let signer = roster.device(id: signerID), signer.member.role == .owner,
              signer.device.signingPublicKey == signingKey.publicKey.rawRepresentation else { throw GroupProtocolError.invalidSignature }
        let signature = try signingKey.signature(for: GroupCanonical.fields([GroupCanonical.text("NW3.NAME.SIGN"), aad, Data(text.utf8)]))
        let plain = try GroupWire.encode(SignedName(name: text, signerDeviceID: signerID, signature: signature))
        guard let combined = try AES.GCM.seal(plain, using: key, authenticating: aad).combined else { throw GroupClientError.invalidResponse }
        return combined
    }
    static func open(_ ciphertext: Data, slot: String, key: SymmetricKey, roster: VerifiedGroupRoster) throws -> String {
        guard (29...8192).contains(ciphertext.count) else { throw GroupClientError.invalidResponse }
        let aad = try context(roster, slot: slot)
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key, authenticating: aad)
        let value = try GroupWire.decode(SignedName.self, plain)
        guard let signer = roster.device(id: value.signerDeviceID), signer.member.role == .owner,
              try Curve25519.Signing.PublicKey(rawRepresentation: signer.device.signingPublicKey)
                .isValidSignature(value.signature, for: GroupCanonical.fields([GroupCanonical.text("NW3.NAME.SIGN"), aad, Data(value.name.utf8)]))
        else { throw GroupProtocolError.invalidSignature }
        return try GroupWire.name(value.name)
    }

    struct JoinBox: Codable { let ownerDeviceID: String; let encapsulatedKey: Data; let ciphertext: Data }
    struct JoinName: Codable { let boxes: [JoinBox]; let signature: Data }
    private static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    private static func joinContext(windowID: String, invitationID: String, personID: String, deviceID: String, ownerDeviceID: String) throws -> Data {
        try GroupCanonical.fields(["NW3.JOIN.NAME", windowID, invitationID, personID, deviceID, ownerDeviceID].map(GroupCanonical.text))
    }
    private static func joinSignature(boxes: [JoinBox], windowID: String, invitationID: String, personID: String, deviceID: String) throws -> Data {
        try GroupCanonical.fields(["NW3.JOIN.NAME.SIGN", windowID, invitationID, personID, deviceID].map(GroupCanonical.text)
            + [GroupCanonical.hash(GroupWire.encode(boxes.sorted { $0.ownerDeviceID < $1.ownerDeviceID }))])
    }
    static func sealJoin(_ name: String, windowID: String, invitationID: String, personID: String, deviceID: String,
                         ownerPersonID: String, ownerRoot: Data, ownerDevices: [GroupRosterDevice], signingKey: Curve25519.Signing.PrivateKey) throws -> Data {
        guard (1...3).contains(ownerDevices.count), Set(ownerDevices.map(\.id)).count == ownerDevices.count else { throw GroupClientError.invalidResponse }
        let plain = Data(try GroupWire.name(name).utf8), root = try Curve25519.Signing.PublicKey(rawRepresentation: ownerRoot)
        let boxes = try ownerDevices.map { device -> JoinBox in
            guard root.isValidSignature(device.personAuthorization, for: try device.authorizationBytes(windowID: windowID, personID: ownerPersonID))
            else { throw GroupProtocolError.invalidSignature }
            let info = try joinContext(windowID: windowID, invitationID: invitationID, personID: personID, deviceID: deviceID, ownerDeviceID: device.id)
            var sender = try HPKE.Sender(recipientKey: Curve25519.KeyAgreement.PublicKey(rawRepresentation: device.hpkePublicKey), ciphersuite: suite, info: info)
            return try JoinBox(ownerDeviceID: device.id, encapsulatedKey: sender.encapsulatedKey, ciphertext: sender.seal(plain, authenticating: info))
        }
        let signature = try signingKey.signature(for: joinSignature(boxes: boxes, windowID: windowID, invitationID: invitationID, personID: personID, deviceID: deviceID))
        return try GroupWire.encode(JoinName(boxes: boxes, signature: signature))
    }
    static func openJoin(_ encrypted: Data, windowID: String, invitationID: String, personID: String, deviceID: String,
                         candidateSigningKey: Data, ownerDeviceID: String, agreementKey: Curve25519.KeyAgreement.PrivateKey) throws -> String {
        guard encrypted.count <= 4096 else { throw GroupClientError.invalidResponse }
        let value = try GroupWire.decode(JoinName.self, encrypted)
        guard (1...3).contains(value.boxes.count), Set(value.boxes.map(\.ownerDeviceID)).count == value.boxes.count,
              let box = value.boxes.first(where: { $0.ownerDeviceID == ownerDeviceID }), box.encapsulatedKey.count == 32,
              (16...96).contains(box.ciphertext.count),
              try Curve25519.Signing.PublicKey(rawRepresentation: candidateSigningKey).isValidSignature(value.signature,
                for: joinSignature(boxes: value.boxes, windowID: windowID, invitationID: invitationID, personID: personID, deviceID: deviceID))
        else { throw GroupProtocolError.invalidSignature }
        let info = try joinContext(windowID: windowID, invitationID: invitationID, personID: personID, deviceID: deviceID, ownerDeviceID: ownerDeviceID)
        var recipient = try HPKE.Recipient(privateKey: agreementKey, ciphersuite: suite, info: info, encapsulatedKey: box.encapsulatedKey)
        let plain = try recipient.open(box.ciphertext, authenticating: info)
        guard let name = String(data: plain, encoding: .utf8) else { throw GroupClientError.invalidResponse }
        return try GroupWire.name(name)
    }
}
