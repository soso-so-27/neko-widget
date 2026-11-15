import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Re-encode pixels only after explicit selection. Source metadata is never copied.
enum FamilyNotebookRepresentativePhotoImage {
    struct Prepared: Sendable { let jpeg: Data; let width: Int; let height: Int }
    static func prepare(_ sourceData: Data) throws -> Prepared {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) > 0
        else { throw FamilyNotebookCryptoError.invalid }
        for edge in [1024, 768, 512, 384, 256] {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary) else { throw FamilyNotebookCryptoError.invalid }
            for quality in [0.85, 0.65, 0.45] {
                let output = NSMutableData()
                guard let encoder = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
                else { throw FamilyNotebookCryptoError.invalid }
                CGImageDestinationAddImage(encoder, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                if CGImageDestinationFinalize(encoder), output.length <= 200_000 {
                    return .init(jpeg: output as Data, width: image.width, height: image.height)
                }
            }
        }
        throw FamilyNotebookCryptoError.tooLarge
    }
    static func validate(_ jpeg: Data, reference: FamilyNotebookRepresentativePhotoReference) throws {
        guard jpeg.count <= 200_000, let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == reference.pixelWidth,
              properties[kCGImagePropertyPixelHeight] as? Int == reference.pixelHeight,
              properties[kCGImagePropertyGPSDictionary] == nil,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else { throw FamilyNotebookCryptoError.invalid }
    }
}

/// Dedicated family ciphertext cache. Never enters PersonalArchive or PhotoKit.
/// The caller supplies only a reference obtained from verified notebook history.
actor FamilyNotebookRepresentativePhotoClient {
    struct Slot: Codable, Equatable, Sendable {
        let slotID: UUID; let revision: Int; let assetID: UUID?
        let ciphertextSHA256: Data?; let ciphertextBytes: Int?; let keyEpoch: Int?; let authorID: String?
    }
    struct Reservation: Codable, Sendable {
        let schemaVersion: Int; let operationID: UUID; let slotID: UUID; let assetID: UUID
        let expectedRevision: Int; let expectedGeneration: Int64; let keyEpoch: Int
        let rosterHash: Data; let ciphertextBytes: Int; let ciphertextSHA256: Data
    }
    /// Safe to persist in the operation journal: contains ciphertext, not content keys.
    struct Pending: Codable, Sendable {
        let reservation: Reservation
        let ciphertext: Data
        let operation: EncryptedFamilyNotebookOperation
    }
    /// Does not edit the text outbox or send anything. UI calls this after consent.
    static func prepare(source: Data, familyID: UUID, catID: UUID, expectedRevision: Int,
                        generation: Int64, nextClock: UInt64, author: FamilyNotebookAuthor,
                        identity: GroupDeviceIdentity, roster: VerifiedFamilyNotebookRoster,
                        epochKey: Data, observedOperationIDs: [UUID]) throws -> Pending {
        guard expectedRevision >= 0, expectedRevision < 1_000_000_000, generation > 0 else { throw FamilyNotebookCryptoError.invalid }
        let pixels = try FamilyNotebookRepresentativePhotoImage.prepare(source)
        let assetID = UUID()
        let encrypted = try FamilyNotebookRepresentativePhotoCrypto.seal(jpeg: pixels.jpeg, width: pixels.width,
            height: pixels.height, familyID: familyID, slotID: catID, assetID: assetID,
            revision: expectedRevision + 1, roster: roster)
        guard let field = FamilyNotebookField(rawValue: "representativePhoto"), expectedRevision >= 0,
              expectedRevision < 1_000_000_000, generation > 0 else { throw FamilyNotebookCryptoError.invalid }
        let operation = FamilyNotebookOperation(familyID: familyID, target: .init(familyCatID: catID, field: field),
            value: .text(String(decoding: try GroupWire.encode(encrypted.reference), as: UTF8.self)),
            version: .init(clock: nextClock, deviceID: try identity.deviceID, operationID: UUID()), author: author,
            editedAt: Date(), observedOperationIDs: observedOperationIDs)
        let packet = try FamilyNotebookOperationCrypto.seal(operation, roster: roster, key: epochKey, signingKey: identity.signingKey)
        return .init(reservation: .init(schemaVersion: 1, operationID: UUID(), slotID: catID, assetID: assetID,
            expectedRevision: expectedRevision, expectedGeneration: generation, keyEpoch: roster.roster.epoch,
            rosterHash: roster.hash, ciphertextBytes: encrypted.ciphertext.count,
            ciphertextSHA256: encrypted.reference.ciphertextSHA256), ciphertext: encrypted.ciphertext, operation: packet)
    }
    private let familyID: UUID, endpoint: URL, identity: GroupDeviceIdentity
    private let transport: any GroupHTTPTransport
    private let journal: any GroupSecretStore
    private let runtimeEnabled: Bool
    private var inFlight = false

    init(familyID: UUID, endpoint: URL, identity: GroupDeviceIdentity,
         transport: any GroupHTTPTransport = GroupURLSessionTransport(), journal: any GroupSecretStore,
         runtimeEnabled: Bool = false) {
        self.familyID = familyID; self.endpoint = endpoint; self.identity = identity
        self.transport = transport; self.journal = journal; self.runtimeEnabled = runtimeEnabled
    }
    private var endpointKey: String { GroupWire.base64(GroupCanonical.hash(Data(endpoint.absoluteString.utf8))) }
    private var base: String { "/v3/family-notebooks/" + familyID.uuidString.lowercased() + "/representative-photos" }
    private func call(_ suffix: String, body: Data? = nil, method: String? = nil, maximum: Int = 262_144) async throws -> Data {
        guard runtimeEnabled else { throw FamilyNotebookTransportError.unavailable }
        var request = try GroupHTTPRequest.make(endpoint: endpoint, path: base + suffix, body: body, identity: identity, method: method)
        if method == "PUT" { request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
        let response = try await transport.send(request, maximumBytes: maximum)
        guard response.status == 200 || response.status == 201 else {
            struct Failure: Decodable { struct Detail: Decodable { let code: String }; let error: Detail }
            guard let failure = try? GroupWire.decode(Failure.self, response.data) else { throw FamilyNotebookTransportError.unknownOutcome }
            if response.status == 409 && failure.error.code == "photo_protocol_upgrade_required" { throw FamilyNotebookTransportError.upgradeRequired }
            throw FamilyNotebookTransportError.server(code: failure.error.code, status: response.status)
        }
        return response.data
    }
    func slots() async throws -> [Slot] {
        struct Reply: Decodable { let schemaVersion: Int; let slots: [Slot] }
        let reply = try GroupWire.decode(Reply.self, await call("/slots"))
        guard reply.schemaVersion == 1, reply.slots.count <= 10,
              Set(reply.slots.map(\.slotID)).count == reply.slots.count else { throw FamilyNotebookTransportError.invalidResponse }
        return reply.slots
    }
    /// Invoke only after explicit consent; caller retains the Pending value for retries.
    /// This operation bypasses the ordinary text outbox: publish the reference atomically with the asset.
    func deliver(_ pending: Pending) async throws {
        guard !inFlight else { throw FamilyNotebookTransportError.operationInFlight }
        inFlight = true; defer { inFlight = false }
        let r = pending.reservation
        guard r.schemaVersion == 1, pending.operation.familyID == familyID,
              pending.operation.personID == identity.personID, pending.operation.deviceID == (try identity.deviceID),
              pending.ciphertext.count == r.ciphertextBytes, pending.ciphertext.count <= 200_028,
              GroupCanonical.hash(pending.ciphertext) == r.ciphertextSHA256 else { throw FamilyNotebookCryptoError.invalid }
        let account = "family-photo-pending-" + endpointKey + "-" + r.operationID.uuidString.lowercased()
        let bytes = try GroupWire.encode(pending)
        if let stored = try journal.read(account: account) {
            guard stored == bytes else { throw FamilyNotebookTransportError.idempotencyConflict }
        } else { try journal.write(bytes, account: account, createOnly: true) }
        struct Lease: Decodable { let schemaVersion: Int; let assetID: UUID; let uploadID: UUID; let reservedRevision: Int; let state: String }
        let lease = try GroupWire.decode(Lease.self, await call("/uploads", body: GroupWire.encode(r)))
        guard lease.schemaVersion == 1, lease.assetID == r.assetID, lease.uploadID == r.assetID,
              lease.reservedRevision == r.expectedRevision + 1 else { throw FamilyNotebookTransportError.invalidResponse }
        let path = "/uploads/" + r.assetID.uuidString.lowercased()
        guard ["reserved", "uploaded", "active", "retired", "deleted"].contains(lease.state) else { throw FamilyNotebookTransportError.invalidResponse }
        if lease.state == "reserved" || lease.state == "uploaded" {
            _ = try await call(path, body: pending.ciphertext, method: "PUT")
        }
        struct Commit: Encodable {
            let operationID: UUID; let expectedGeneration: Int64; let expectedRevision: Int; let payload: EncryptedFamilyNotebookOperation
        }
        struct Receipt: Decodable { let schemaVersion: Int; let assetID: UUID; let revision: Int; let operationID: UUID }
        let receipt = try GroupWire.decode(Receipt.self, await call(path + "/commit", body: GroupWire.encode(
            Commit(operationID: pending.operation.operationID, expectedGeneration: r.expectedGeneration,
                   expectedRevision: r.expectedRevision, payload: pending.operation))))
        guard receipt.schemaVersion == 1, receipt.assetID == r.assetID, receipt.revision == r.expectedRevision + 1,
              receipt.operationID == pending.operation.operationID else { throw FamilyNotebookTransportError.invalidResponse }
        // Keep the encrypted journal so a lost local completion cannot create a second upload.
    }
    func image(slot: Slot, reference: FamilyNotebookRepresentativePhotoReference,
               roster: VerifiedFamilyNotebookRoster, verifiedAuthorID: String, hiddenAuthors: Set<String> = []) async throws -> Data? {
        guard runtimeEnabled else { throw FamilyNotebookTransportError.unavailable }
        guard !hiddenAuthors.contains(verifiedAuthorID) else { return nil }
        guard slot.authorID == verifiedAuthorID else { throw FamilyNotebookCryptoError.untrusted }
        try reference.validate()
        guard slot.slotID == reference.slotID, slot.assetID == reference.assetID, slot.revision == reference.revision,
              slot.ciphertextSHA256 == reference.ciphertextSHA256 else { throw FamilyNotebookCryptoError.untrusted }
        let cacheKey = "family-photo-cipher-" + endpointKey + "-" + familyID.uuidString.lowercased() + "-" + reference.assetID.uuidString.lowercased()
            + "-" + GroupWire.base64(reference.ciphertextSHA256)
        let ciphertext: Data
        if let cached = try journal.read(account: cacheKey), GroupCanonical.hash(cached) == reference.ciphertextSHA256 { ciphertext = cached }
        else {
            ciphertext = try await call("/assets/" + reference.assetID.uuidString.lowercased(), maximum: 200_028)
            guard GroupCanonical.hash(ciphertext) == reference.ciphertextSHA256 else { throw FamilyNotebookCryptoError.untrusted }
            try journal.write(ciphertext, account: cacheKey, createOnly: false)
        }
        let jpeg = try FamilyNotebookRepresentativePhotoCrypto.open(ciphertext, reference: reference, familyID: familyID, roster: roster)
        try FamilyNotebookRepresentativePhotoImage.validate(jpeg, reference: reference)
        return jpeg
    }
}
