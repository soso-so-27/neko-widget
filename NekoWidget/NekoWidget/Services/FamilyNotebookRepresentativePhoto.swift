import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// 11/18 (TestFlight 388): where a family photo delivery stopped, one line per
/// stage. Only a stage name, an HTTP status and a fixed error code: never a
/// photo, an identifier, a key or a URL.
enum FamilyPhotoDeliveryStage: String, Sendable {
    case sourceLoaded, sourceMissing
    case contextUnavailable, authorMissing, catNotInNotebook, keyMissing, keyReady
    case stateListed, stateListFailed
    case imagePrepared, prepareFailed
    case reserveSent, reserveStatus, uploadStatus, uploaded, commitStatus, committed
    case deliveryFailed, retryNothingPending
}

struct FamilyPhotoDeliveryNote: Sendable, Equatable {
    let stage: FamilyPhotoDeliveryStage
    /// The relay's HTTP status, when there was a reply.
    var status: Int? = nil
    /// FamilyPhotoDeliveryLog.code(of:) or the relay's code, from a fixed list.
    var code: String? = nil
}

typealias FamilyPhotoDeliveryTrace = @Sendable (FamilyPhotoDeliveryNote) -> Void

enum FamilyPhotoDeliveryLog {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NekoWidget", category: "family-photo")

    /// The unified log (Console, sysdiagnose). The app also keeps it in 診断ログ.
    static func system(_ note: FamilyPhotoDeliveryNote) {
        let status = note.status.map(String.init) ?? "-"
        let code = note.code ?? "-"
        logger.notice("family-photo stage \(note.stage.rawValue, privacy: .public) status \(status, privacy: .public) code \(code, privacy: .public)")
    }

    /// The relay's codes this client knows; anything else is 「server_other」.
    static let serverCodes: Set<String> = [
        "access_unavailable", "family_notebook_disabled", "family_notebook_quota_unavailable",
        "idempotency_conflict", "invalid_authentication", "invalid_photo_payload", "key_epoch_pending",
        "not_found", "owner_trial_unavailable", "photo_feature_disabled", "photo_moderated",
        "photo_protocol_upgrade_required", "photo_retired", "photo_slots_full", "rate_limited",
        "revision_conflict", "temporarily_unavailable", "upgrade_required",
    ]

    static func serverCode(_ code: String) -> String { serverCodes.contains(code) ? code : "server_other" }

    /// A fixed word for an error of the photo path (no text from the error itself).
    static func code(of error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? FamilyNotebookTransportError {
            switch error {
            case let .server(code, _): return serverCode(code)
            case .invalidResponse: return "invalid_response"
            case .authenticationRequired: return "authentication_required"
            case .notMember: return "not_member"
            case .paused: return "paused"
            case .unavailable: return "transport_unavailable"
            case .stale: return "stale"
            case .unknownOutcome: return "unknown_outcome"
            case .idempotencyConflict: return "local_idempotency_conflict"
            case .operationInFlight: return "operation_in_flight"
            case .upgradeRequired: return "client_upgrade_required"
            }
        }
        if let error = error as? GroupClientError {
            switch error {
            case .offline: return "offline"
            case .unavailable: return "client_unavailable"
            case .invalidResponse: return "client_invalid_response"
            case .authenticationRequired: return "client_authentication_required"
            default: return "client_other"
            }
        }
        if let error = error as? FamilyNotebookCryptoError {
            switch error {
            case .invalid: return "crypto_invalid"
            case .untrusted: return "crypto_untrusted"
            case .stale: return "crypto_stale"
            case .tooLarge: return "crypto_too_large"
            }
        }
        if error is DecodingError { return "decoding" }
        return "other"
    }
}

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
                    return .init(jpeg: try withoutMetadata(output as Data), width: image.width, height: image.height)
                }
            }
        }
        throw FamilyNotebookCryptoError.tooLarge
    }
    /// ImageIO can generate a fresh EXIF block even when source properties are
    /// not copied. Drop EXIF/XMP, IPTC and comments without touching scan bytes.
    private static func withoutMetadata(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8 else { throw FamilyNotebookCryptoError.invalid }
        var result = Data(bytes.prefix(2)), offset = 2
        while offset < bytes.count {
            let start = offset
            guard bytes[offset] == 0xff else { throw FamilyNotebookCryptoError.invalid }
            while offset < bytes.count && bytes[offset] == 0xff { offset += 1 }
            guard offset < bytes.count else { throw FamilyNotebookCryptoError.invalid }
            let marker = bytes[offset]; offset += 1
            if marker == 0xda || marker == 0xd9 {
                result.append(contentsOf: bytes[start...]); return result
            }
            guard offset + 1 < bytes.count else { throw FamilyNotebookCryptoError.invalid }
            let length = Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
            guard length >= 2, offset + length <= bytes.count else { throw FamilyNotebookCryptoError.invalid }
            offset += length
            if marker != 0xe1 && marker != 0xed && marker != 0xfe { result.append(contentsOf: bytes[start..<offset]) }
        }
        throw FamilyNotebookCryptoError.invalid
    }
    static func validate(_ jpeg: Data, reference: FamilyNotebookRepresentativePhotoReference) throws {
        try reference.validate()
        guard try withoutMetadata(jpeg) == jpeg else { throw FamilyNotebookCryptoError.invalid }
        guard jpeg.count <= 200_000, let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == reference.pixelWidth,
              properties[kCGImagePropertyPixelHeight] as? Int == reference.pixelHeight,
              properties[kCGImagePropertyGPSDictionary] == nil,
              properties[kCGImagePropertyExifDictionary] == nil,
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
        let assetID = UUID(), slotID = FamilyNotebookRepresentativePhotoCrypto.slotID(familyID: familyID, catID: catID)
        let encrypted = try FamilyNotebookRepresentativePhotoCrypto.seal(jpeg: pixels.jpeg, width: pixels.width,
            height: pixels.height, familyID: familyID, slotID: slotID, assetID: assetID,
            revision: expectedRevision + 1, roster: roster)
        guard let field = FamilyNotebookField(rawValue: "representativePhoto"), expectedRevision >= 0,
              expectedRevision < 1_000_000_000, generation > 0 else { throw FamilyNotebookCryptoError.invalid }
        let operation = FamilyNotebookOperation(familyID: familyID, target: .init(familyCatID: catID, field: field),
            value: .text(String(decoding: try GroupWire.encode(encrypted.reference), as: UTF8.self)),
            version: .init(clock: nextClock, deviceID: try identity.deviceID, operationID: UUID()), author: author,
            editedAt: Date(), observedOperationIDs: observedOperationIDs)
        let packet = try FamilyNotebookOperationCrypto.seal(operation, roster: roster, key: epochKey, signingKey: identity.signingKey)
        return .init(reservation: .init(schemaVersion: 1, operationID: UUID(), slotID: slotID, assetID: assetID,
            expectedRevision: expectedRevision, expectedGeneration: generation, keyEpoch: roster.roster.epoch,
            rosterHash: roster.hash, ciphertextBytes: encrypted.ciphertext.count,
            ciphertextSHA256: encrypted.reference.ciphertextSHA256), ciphertext: encrypted.ciphertext, operation: packet)
    }
    private let familyID: UUID, endpoint: URL, identity: GroupDeviceIdentity
    private let transport: any GroupHTTPTransport
    private let journal: any GroupSecretStore
    private let runtimeEnabled: Bool
    /// 11/20: the notebook's device-only Keychain (`.family.<scope>`). Deleting
    /// the app wipes `journal` (Application Support) but not this, so a copy of
    /// this person's 「表示しない」 and reported photos is kept here.
    private let kept: (any GroupSecretStore)?
    /// The kept copy was compared with the journal once (one Keychain read per client).
    private var keptChecked = false
    private var inFlight = false
    private struct Journal: Codable {
        let digest: Data
        let pending: Pending?
        let completed: Bool
    }

    init(familyID: UUID, endpoint: URL, identity: GroupDeviceIdentity,
         transport: any GroupHTTPTransport = GroupURLSessionTransport(), journal: any GroupSecretStore,
         runtimeEnabled: Bool = false, kept: (any GroupSecretStore)? = nil) {
        self.familyID = familyID; self.endpoint = endpoint; self.identity = identity
        self.transport = transport; self.journal = journal; self.runtimeEnabled = runtimeEnabled; self.kept = kept
    }
    private var contextKey: String {
        GroupWire.base64(Data(GroupCanonical.hash(Data((endpoint.absoluteString + "|" + familyID.uuidString + "|" + identity.personID).utf8)).prefix(16)))
    }
    private struct Visibility: Codable {
        var hiddenAuthors: Set<String> = []
        var reportedAssets: Set<UUID> = []
    }
    private var visibilityAccount: String {
        "op:fp:v:" + GroupWire.base64(GroupCanonical.hash(Data((endpoint.absoluteString + "|" + identity.personID).utf8)))
    }
    /// The Keychain copy's account (the same endpoint and person as the journal's).
    private var keptVisibilityAccount: String { "family-photo-visibility.v1:" + String(visibilityAccount.dropFirst("op:fp:v:".count)) }
    private func visibility() throws -> Visibility {
        let saved = try journal.read(visibilityAccount)
        if !keptChecked {
            // 11/20: once per client, never per photo: an empty journal (the
            // app was deleted) takes the kept copy; a journal from before
            // the copy existed is kept now. A Keychain failure changes nothing.
            keptChecked = true
            let copy = try? kept?.read(keptVisibilityAccount)
            if saved == nil, let copy, let value = try? GroupWire.decode(Visibility.self, copy) {
                try journal.write(copy, account: visibilityAccount, createOnly: false)
                return value
            }
            if let saved, saved != copy { keep(saved) }
        }
        guard let saved else { return Visibility() }
        return try GroupWire.decode(Visibility.self, saved)
    }
    /// The journal first (what this iPhone reads), then the kept copy, quietly.
    private func save(_ value: Visibility) throws {
        let data = try GroupWire.encode(value)
        try journal.write(data, account: visibilityAccount, createOnly: false)
        keep(data)
    }
    private func keep(_ data: Data) {
        try? kept?.write(data, account: keptVisibilityAccount, createOnly: false)
    }
    /// Local only: never changes notebook membership or text sharing.
    func hideAuthor(_ personID: String) throws {
        guard (try? GroupWire.bytes(personID, count: 32).count) == 32 else { throw FamilyNotebookCryptoError.invalid }
        var value = try visibility(); value.hiddenAuthors.insert(personID)
        try save(value)
        // Persist the deny rule before discarding caches. A failed removal must
        // not restore visibility after restart.
        for account in try journal.accounts(prefix: cachePrefix) { try journal.remove(account) }
    }
    func unhideAuthor(_ personID: String) throws {
        var value = try visibility(); value.hiddenAuthors.remove(personID)
        try save(value)
    }
    func hiddenAuthors() throws -> Set<String> { try visibility().hiddenAuthors }
    struct PendingReport: Codable, Sendable {
        let schemaVersion: Int
        let operationID: UUID
        let assetID: UUID
        let reasonCode: String
        let moderationKeyID: String
        let ciphertext: Data
        let ciphertextSHA256: Data
        let consentedAt: Int64
    }
    struct ReportReceipt: Decodable, Sendable {
        let schemaVersion: Int
        let reportID: String
        let familyID: UUID
        let assetID: UUID
        let state: String
        let committedAt: Int64
        let contentExpiresAt: Int64
    }
    /// Call only after displaying exactly this image and obtaining explicit consent.
    /// Persist the returned encrypted value for retries; no family key is included.
    func prepareReport(canonicalJPEG: Data, assetID: UUID, reasonCode: String,
                       moderationKeyID: String, moderationPublicKey: Data) throws -> PendingReport {
        // 11/19 (TestFlight 391): a received photo keeps ImageIO's JFIF APP0
        // (and may carry an ICC APP2): the save side drops only EXIF/XMP,
        // IPTC and comments. The report's check stays strict (no APPn, no
        // COM), so the same pixels go without every APPn/COM segment.
        guard let canonicalJPEG = JPEGPrivateMetadata.strippingAll(from: canonicalJPEG) else {
            throw GroupReportCryptoError.invalidCanonicalJPEG
        }
        let encrypted = try GroupReportCrypto.encryptFamilyPhoto(canonicalJPEG: canonicalJPEG,
            familyID: familyID, assetID: assetID, reporterPersonID: identity.personID,
            reasonCode: reasonCode, keyID: moderationKeyID, publicKey: moderationPublicKey)
        return PendingReport(schemaVersion: 1, operationID: UUID(), assetID: assetID,
            reasonCode: reasonCode, moderationKeyID: moderationKeyID, ciphertext: encrypted,
            ciphertextSHA256: GroupCanonical.hash(encrypted), consentedAt: Int64(Date().timeIntervalSince1970))
    }
    func report(_ pending: PendingReport) async throws -> ReportReceipt {
        guard pending.schemaVersion == 1, pending.ciphertext.count <= GroupReportCrypto.maximumEnvelopeBytes,
              GroupCanonical.hash(pending.ciphertext) == pending.ciphertextSHA256 else {
            throw FamilyNotebookCryptoError.invalid
        }
        let receipt = try GroupWire.decode(ReportReceipt.self, await call("/reports", body: GroupWire.encode(pending)))
        guard receipt.schemaVersion == 1, receipt.familyID == familyID, receipt.assetID == pending.assetID,
              receipt.state == "committed", receipt.committedAt > 0,
              receipt.committedAt <= Int64.max - 604_800,
              receipt.contentExpiresAt == receipt.committedAt + 604_800 else {
            throw FamilyNotebookTransportError.invalidResponse
        }
        try markReported(pending.assetID)
        return receipt
    }
    private func markReported(_ assetID: UUID) throws {
        var value = try visibility(); value.reportedAssets.insert(assetID)
        try save(value)
        for account in try journal.accounts(prefix: cachePrefix) { try journal.remove(account) }
    }
    private var pendingPrefix: String { "op:fp:p:" + contextKey + ":" }
    private var cachePrefix: String { "op:fp:c:" + contextKey + ":" }
    private func cacheAccount(assetID: UUID, hash: Data) -> String {
        cachePrefix + GroupWire.base64(GroupCanonical.hash(Data(assetID.uuidString.lowercased().utf8) + hash))
    }
    func pendingDeliveries() throws -> [Pending] {
        try journal.accounts(prefix: pendingPrefix).compactMap { account in
            guard let data = try journal.read(account) else { return nil }
            let stored = try GroupWire.decode(Journal.self, data)
            guard !stored.completed, let pending = stored.pending,
                  pending.operation.familyID == familyID, pending.operation.deviceID == (try identity.deviceID)
            else { return nil }
            guard GroupCanonical.hash(try GroupWire.encode(pending)) == stored.digest else { throw FamilyNotebookCryptoError.invalid }
            return pending
        }
    }
    private var base: String { "/v3/family-notebooks/" + familyID.uuidString.lowercased() + "/representative-photos" }
    /// `trace` (a delivery only): the reply's status as `traced`, or the
    /// fixed code of a send that got no reply.
    private func call(_ suffix: String, body: Data? = nil, method: String? = nil, maximum: Int = 262_144,
                      trace: FamilyPhotoDeliveryTrace? = nil, traced: FamilyPhotoDeliveryStage = .reserveStatus) async throws -> Data {
        guard runtimeEnabled else { throw FamilyNotebookTransportError.unavailable }
        var request = try GroupHTTPRequest.make(endpoint: endpoint, path: base + suffix, body: body, identity: identity, method: method)
        if method == "PUT" { request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
        let response: GroupHTTPReply
        do { response = try await transport.send(request, maximumBytes: maximum) }
        catch { trace?(.init(stage: traced, code: FamilyPhotoDeliveryLog.code(of: error))); throw error }
        guard response.status == 200 || response.status == 201 else {
            struct Failure: Decodable { struct Detail: Decodable { let code: String }; let error: Detail }
            let parsed = try? GroupWire.decode(Failure.self, response.data)
            trace?(.init(stage: traced, status: response.status,
                         code: parsed.map { FamilyPhotoDeliveryLog.serverCode($0.error.code) } ?? "unparsed_body"))
            guard let failure = parsed else { throw FamilyNotebookTransportError.unknownOutcome }
            if response.status == 409 && failure.error.code == "photo_protocol_upgrade_required" { throw FamilyNotebookTransportError.upgradeRequired }
            throw FamilyNotebookTransportError.server(code: failure.error.code, status: response.status)
        }
        trace?(.init(stage: traced, status: response.status))
        return response.data
    }
    func slots() async throws -> [Slot] {
        struct Reply: Decodable { let schemaVersion: Int; let slots: [Slot] }
        let reply = try GroupWire.decode(Reply.self, await call("/slots"))
        guard reply.schemaVersion == 1, reply.slots.count <= 10,
              Set(reply.slots.map(\.slotID)).count == reply.slots.count else { throw FamilyNotebookTransportError.invalidResponse }
        let keep = Set(reply.slots.compactMap { slot -> String? in
            guard let asset = slot.assetID, let hash = slot.ciphertextSHA256, hash.count == 32 else { return nil }
            return cacheAccount(assetID: asset, hash: hash)
        })
        for account in try journal.accounts(prefix: cachePrefix) where !keep.contains(account) { try journal.remove(account) }
        return reply.slots
    }
    /// Invoke only after explicit consent; caller retains the Pending value for retries.
    /// This operation bypasses the ordinary text outbox: publish the reference atomically with the asset.
    func deliver(_ pending: Pending, trace: FamilyPhotoDeliveryTrace? = nil) async throws {
        guard runtimeEnabled else { throw FamilyNotebookTransportError.unavailable }
        guard !inFlight else { throw FamilyNotebookTransportError.operationInFlight }
        inFlight = true; defer { inFlight = false }
        let r = pending.reservation
        guard r.schemaVersion == 1, pending.operation.familyID == familyID,
              pending.operation.personID == identity.personID, pending.operation.deviceID == (try identity.deviceID),
              pending.ciphertext.count == r.ciphertextBytes, pending.ciphertext.count <= 200_028,
              GroupCanonical.hash(pending.ciphertext) == r.ciphertextSHA256 else { throw FamilyNotebookCryptoError.invalid }
        let account = pendingPrefix + r.operationID.uuidString.lowercased()
        let bytes = try GroupWire.encode(pending)
        let digest = GroupCanonical.hash(bytes)
        if let stored = try journal.read(account) {
            let value = try GroupWire.decode(Journal.self, stored)
            guard value.digest == digest else { throw FamilyNotebookTransportError.idempotencyConflict }
            if value.completed { return }
        } else { try journal.write(GroupWire.encode(Journal(digest: digest, pending: pending, completed: false)), account: account, createOnly: true) }
        struct Lease: Decodable { let schemaVersion: Int; let assetID: UUID; let uploadID: UUID; let reservedRevision: Int; let state: String }
        trace?(.init(stage: .reserveSent))
        let lease = try GroupWire.decode(Lease.self, await call("/uploads", body: GroupWire.encode(r), trace: trace, traced: .reserveStatus))
        guard lease.schemaVersion == 1, lease.assetID == r.assetID, lease.uploadID == r.assetID,
              lease.reservedRevision == r.expectedRevision + 1 else { throw FamilyNotebookTransportError.invalidResponse }
        let path = "/uploads/" + r.assetID.uuidString.lowercased()
        guard ["reserved", "uploaded", "active", "retired", "deleted"].contains(lease.state) else { throw FamilyNotebookTransportError.invalidResponse }
        if lease.state == "reserved" || lease.state == "uploaded" {
            _ = try await call(path, body: pending.ciphertext, method: "PUT", trace: trace, traced: .uploadStatus)
        }
        trace?(.init(stage: .uploaded))
        struct Commit: Encodable {
            let operationID: UUID; let expectedGeneration: Int64; let expectedRevision: Int; let payload: EncryptedFamilyNotebookOperation
        }
        struct Receipt: Decodable { let schemaVersion: Int; let assetID: UUID; let revision: Int; let operationID: UUID }
        let receipt = try GroupWire.decode(Receipt.self, await call(path + "/commit", body: GroupWire.encode(
            Commit(operationID: pending.operation.operationID, expectedGeneration: r.expectedGeneration,
                   expectedRevision: r.expectedRevision, payload: pending.operation)), trace: trace, traced: .commitStatus))
        guard receipt.schemaVersion == 1, receipt.assetID == r.assetID, receipt.revision == r.expectedRevision + 1,
              receipt.operationID == pending.operation.operationID else { throw FamilyNotebookTransportError.invalidResponse }
        // Retain only the digest after completion. A lost local completion still retries the same ciphertext.
        try journal.write(GroupWire.encode(Journal(digest: digest, pending: nil, completed: true)), account: account, createOnly: false)
        trace?(.init(stage: .committed))
    }
    private func visiblePhotoBytes(_ suffix: String, maximum: Int = 262_144) async throws -> Data? {
        do { return try await call(suffix, maximum: maximum) }
        catch FamilyNotebookTransportError.server(let code, let status)
            where status == 410 && ["photo_moderated", "photo_retired"].contains(code) {
            for account in try journal.accounts(prefix: cachePrefix) { try journal.remove(account) }
            return nil
        }
    }
    func image(slot: Slot, reference: FamilyNotebookRepresentativePhotoReference,
               roster: VerifiedFamilyNotebookRoster, verifiedAuthorID: String, hiddenAuthors: Set<String> = []) async throws -> Data? {
        guard runtimeEnabled else { throw FamilyNotebookTransportError.unavailable }
        let local = try visibility()
        guard !hiddenAuthors.contains(verifiedAuthorID), !local.hiddenAuthors.contains(verifiedAuthorID),
              !local.reportedAssets.contains(reference.assetID) else { return nil }
        guard slot.authorID == verifiedAuthorID else { throw FamilyNotebookCryptoError.untrusted }
        try reference.validate()
        guard slot.slotID == reference.slotID, slot.assetID == reference.assetID, slot.revision == reference.revision,
              slot.ciphertextSHA256 == reference.ciphertextSHA256 else { throw FamilyNotebookCryptoError.untrusted }
        let cacheKey = cacheAccount(assetID: reference.assetID, hash: reference.ciphertextSHA256)
        let ciphertext: Data
        if let cached = try journal.read(cacheKey), GroupCanonical.hash(cached) == reference.ciphertextSHA256 {
            // Cached pixels are not authority to keep displaying a stopped asset.
            struct Status: Decodable { let schemaVersion: Int; let assetID: UUID; let available: Bool }
            guard let bytes = try await visiblePhotoBytes("/assets/" + reference.assetID.uuidString.lowercased() + "/status") else { return nil }
            let status = try GroupWire.decode(Status.self, bytes)
            guard status.schemaVersion == 1, status.assetID == reference.assetID, status.available else {
                throw FamilyNotebookTransportError.invalidResponse
            }
            ciphertext = cached
        }
        else {
            guard let bytes = try await visiblePhotoBytes("/assets/" + reference.assetID.uuidString.lowercased(), maximum: 200_028) else { return nil }
            ciphertext = bytes
            guard GroupCanonical.hash(ciphertext) == reference.ciphertextSHA256 else { throw FamilyNotebookCryptoError.untrusted }
            try journal.write(ciphertext, account: cacheKey, createOnly: false)
        }
        // A hide/report action may finish while the network request is pending.
        let latestVisibility = try visibility()
        guard !latestVisibility.hiddenAuthors.contains(verifiedAuthorID),
              !latestVisibility.reportedAssets.contains(reference.assetID) else { return nil }
        let jpeg = try FamilyNotebookRepresentativePhotoCrypto.open(ciphertext, reference: reference, familyID: familyID, roster: roster)
        try FamilyNotebookRepresentativePhotoImage.validate(jpeg, reference: reference)
        return jpeg
    }
}
