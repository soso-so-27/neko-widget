import CryptoKit
import Foundation

/// Only an explicit addition from the same delivered moment uses this identity.
/// It never guesses a relationship to older randomly identified photo records.
enum FamilyRecordSourceIdentity {
    static func recordID(spaceID: String, momentID: String) throws -> String {
        guard PairingValidation.isOpaqueIdentifier(spaceID), PairingValidation.isOpaqueIdentifier(momentID) else {
            throw FamilyRecordError.invalid
        }
        let context = try PairingCanonicalEncoder.encode(["NW.FAMILY-RECORD.MOMENT.1", spaceID, momentID])
        var bytes = Array(SHA256.hash(data: context).prefix(16))
        // The existing relay accepts only the UUID-v4 spelling. This is an
        // opaque deterministic record key, never an authentication capability.
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
            .uuidString.lowercased()
    }

    static func existingPhoto(in catalog: FamilyRecordCatalog, momentID: String) throws -> FamilyRecordRow? {
        let id = try recordID(spaceID: catalog.spaceID, momentID: momentID)
        guard let row = catalog.records.first(where: { $0.id == id }) else { return nil }
        guard row.kind == .photo, row.entryID == id else { throw FamilyRecordError.invalid }
        // A tombstone is still an existing photo. It must never become a new upload.
        return row
    }
}

enum FamilyRecordError: Error, LocalizedError {
    case unavailable, changed, invalid, textTooLong
    var errorDescription: String? {
        switch self {
        case .unavailable: return "今は共有メモを開けません。まどの接続を確認してください。"
        case .changed: return "記録または共有先が変わりました。入力を確認してからやり直してください。"
        case .invalid: return "この記録を読み込めませんでした。別の写真で補うことはありません。"
        case .textTooLong: return "メモは500文字以内にしてください。"
        }
    }
}

struct FamilyRecordRow: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case photo, words }
    enum State: String, Codable, Sendable { case active, withdrawn }
    let id: String
    let entryID: String
    let kind: Kind
    let authorID: String
    let revision: Int
    let state: State
    let keyEpoch: Int
    let ciphertext: String?
    let createdAt: Double
    let updatedAt: Double

    func validated() throws -> Self {
        guard UUID(uuidString: id) != nil, UUID(uuidString: entryID) != nil,
              PairingValidation.isOpaqueIdentifier(authorID), revision > 0,
              keyEpoch == 1, createdAt.isFinite, updatedAt.isFinite, updatedAt >= createdAt,
              kind != .photo || entryID == id,
              state != .withdrawn || ciphertext == nil else { throw FamilyRecordError.invalid }
        return self
    }
}

struct FamilyRecordCatalog: Decodable, Sendable {
    let schemaVersion: Int
    let spaceID: String
    let participantID: String
    let maximumPhotos: Int
    let records: [FamilyRecordRow]

    func validated(spaceID: String, participantID: String) throws -> Self {
        guard schemaVersion == 1, self.spaceID == spaceID, self.participantID == participantID,
              records.count <= 1100, Set(records.map(\.id)).count == records.count,
              maximumPhotos == 100 else { throw FamilyRecordError.invalid }
        let photoIDs = Set(records.filter { $0.kind == .photo }.map(\.id))
        for row in records {
            _ = try row.validated()
            guard row.kind != .words || photoIDs.contains(row.entryID) else { throw FamilyRecordError.invalid }
        }
        return self
    }
}

struct FamilyRecordPayload: Codable, Sendable {
    let schemaVersion: Int
    let text: String?
    let jpeg: Data?
    let capturedAt: Date?

    static func words(_ text: String) throws -> Self {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw FamilyRecordError.invalid }
        guard value.count <= 500 else { throw FamilyRecordError.textTooLong }
        return Self(schemaVersion: 1, text: value, jpeg: nil, capturedAt: nil)
    }
    func validated(kind: FamilyRecordRow.Kind) throws -> Self {
        guard schemaVersion == 1 else { throw FamilyRecordError.invalid }
        switch kind {
        case .photo:
            guard text == nil, let jpeg, !jpeg.isEmpty, jpeg.count <= 1024 * 1024,
                  capturedAt?.timeIntervalSince1970.isFinite != false else { throw FamilyRecordError.invalid }
        case .words:
            guard jpeg == nil, capturedAt == nil, let text,
                  try Self.words(text).text == text else { throw FamilyRecordError.invalid }
        }
        return self
    }
}

enum FamilyRecordCrypto {
    private static func key(roomKey: Data, spaceID: String) throws -> SymmetricKey {
        guard roomKey.count == 32, PairingValidation.isOpaqueIdentifier(spaceID) else { throw FamilyRecordError.invalid }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: roomKey),
            salt: Data(spaceID.utf8), info: Data("NW.FAMILY-RECORD.1".utf8), outputByteCount: 32)
    }
    private static func context(spaceID: String, id: String, entryID: String,
                                kind: FamilyRecordRow.Kind, authorID: String, revision: Int) throws -> Data {
        try PairingCanonicalEncoder.encode(["NW.FAMILY-RECORD.1", spaceID, id, entryID,
            kind.rawValue, authorID, String(revision)])
    }
    static func seal(_ payload: FamilyRecordPayload, roomKey: Data, spaceID: String, id: String,
                     entryID: String, kind: FamilyRecordRow.Kind, authorID: String, revision: Int) throws -> Data {
        let encoded = try JSONEncoder().encode(payload.validated(kind: kind))
        guard let result = try AES.GCM.seal(encoded, using: key(roomKey: roomKey, spaceID: spaceID),
            authenticating: context(spaceID: spaceID, id: id, entryID: entryID, kind: kind,
                authorID: authorID, revision: revision)).combined else { throw FamilyRecordError.invalid }
        return result
    }
    static func open(_ data: Data, row: FamilyRecordRow, roomKey: Data, spaceID: String) throws -> FamilyRecordPayload {
        _ = try row.validated()
        guard row.state == .active, data.count <= 2 * 1024 * 1024 else { throw FamilyRecordError.invalid }
        let decoded = try AES.GCM.open(AES.GCM.SealedBox(combined: data),
            using: key(roomKey: roomKey, spaceID: spaceID),
            authenticating: context(spaceID: spaceID, id: row.id, entryID: row.entryID, kind: row.kind,
                authorID: row.authorID, revision: row.revision))
        return try JSONDecoder().decode(FamilyRecordPayload.self, from: decoded).validated(kind: row.kind)
    }
}
