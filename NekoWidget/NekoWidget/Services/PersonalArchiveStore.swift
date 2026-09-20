import Foundation
import CryptoKit

enum PersonalArchiveRecordState: String, Codable, Sendable {
    case pending, stored, partial, conflict
}

enum PersonalArchiveError: String, Error, Codable, LocalizedError, Sendable {
    case notConfigured, notSignedIn, accountChanged, quotaExceeded, networkUnavailable
    case zoneMissing, archiveChanged, conflict, corruptedState, storageUnavailable, invalidJPEG
    case textTooLong, emptyRecord, cancelled

    var errorDescription: String? {
        switch self {
        case .notConfigured: "記録の保管はまだ利用できません。"
        case .notSignedIn: "設定でiCloudへのサインインと、このアプリのiCloud利用を確認してください。"
        case .accountChanged: "iCloudのアカウントが変わりました。入力内容を控え、保管画面を開き直してください。"
        case .quotaExceeded: "iCloudの空き容量が不足しています。空き容量を確認して、もう一度お試しください。"
        case .networkUnavailable: "iCloudに接続できませんでした。通信を確認して、もう一度お試しください。"
        case .zoneMissing: "iCloudの保管先が見つかりません。以前の記録を守るため、自動では作り直していません。"
        case .archiveChanged: "iCloudの保管先が変更されています。以前の記録を戻さないよう、保存待ちの送信を止めました。"
        case .conflict: "同じ記録に異なる内容が見つかりました。手元の内容は残し、上書きしていません。"
        case .corruptedState: "記録の一部を読み込めません。手元にある内容は変更していません。"
        case .storageUnavailable: "このiPhoneに記録を保存できません。空き容量やロック状態を確認してください。"
        case .invalidJPEG: "この写真を保管できません。20MB以下の写真を選び直してください。"
        case .textTooLong: "言葉は500文字以内で入力してください。"
        case .emptyRecord: "写真か言葉を追加してください。"
        case .cancelled: "保管を中断しました。保存待ちの記録は残っています。"
        }
    }
}

struct PersonalArchiveRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let createdAt: Date
    let capturedAt: Date?
    let jpegData: Data?
    let state: PersonalArchiveRecordState
    let issue: PersonalArchiveError?
    let context: PersonalArchiveContext?
    let revision: String
    let conflictingText: String?
    let conflictingRevision: String?
    let isDeletionPending: Bool

    init(id: UUID, text: String, createdAt: Date, capturedAt: Date?, jpegData: Data?,
         state: PersonalArchiveRecordState, issue: PersonalArchiveError?,
         context: PersonalArchiveContext? = nil, revision: String = "", conflictingText: String? = nil,
         isDeletionPending: Bool = false, conflictingRevision: String? = nil) {
        self.id = id; self.text = text; self.createdAt = createdAt; self.capturedAt = capturedAt
        self.jpegData = jpegData; self.state = state; self.issue = issue
        self.context = context; self.revision = revision; self.conflictingText = conflictingText
        self.isDeletionPending = isDeletionPending
        self.conflictingRevision = conflictingRevision
    }
}

struct PersonalArchiveContext: Codable, Equatable, Sendable {
    let writtenAt: Date?
    let updatedAt: Date?
    let catNames: [String]

    func validate() throws {
        guard writtenAt.map(PersonalArchivePayload.validDate) ?? true,
              updatedAt.map(PersonalArchivePayload.validDate) ?? true,
              catNames.count <= 100,
              catNames.allSatisfy({ !$0.isEmpty && $0.count <= 200 && $0.utf8.count <= 800 }) else {
            throw PersonalArchiveError.corruptedState
        }
    }
}

/// Local-only linkage. None of these identifiers are fields in the cloud payload.
struct PersonalArchiveSourceSnapshot: Codable, Equatable, Sendable {
    let noteID: UUID
    let revision: String
    let photoIdentifier: String?
}

/// A local, explicit relationship, never inferred from text, dates or cat names.
struct PersonalArchiveReadingAssociation: Equatable, Sendable {
    let source: PersonalArchiveSourceSnapshot
    let recordID: UUID
}

struct PersonalArchiveReadingSnapshot: Equatable, Sendable {
    let account: PersonalArchiveAccount
    let records: [PersonalArchiveRecord]
    let associations: [PersonalArchiveReadingAssociation]

    /// The caller supplies its current notes. An edited or reassigned source
    /// must remain visible independently of the older preserved copy.
    func exactLinkedRecordIDs(matching sources: [PersonalArchiveSourceSnapshot]) -> [UUID: UUID] {
        let byNote = Dictionary(associations.map { ($0.source.noteID, $0) },
                                uniquingKeysWith: { first, _ in first })
        var result: [UUID: UUID] = [:]
        for source in sources {
            if let association = byNote[source.noteID], association.source == source {
                result[source.noteID] = association.recordID
            }
        }
        return result
    }
}

enum PersonalArchivePreservationStatus: String, Sendable {
    case localOnly, pending, stored, changed, partial, conflict, deleted
}

struct PersonalArchivePrecondition: Codable, Equatable, Sendable {
    let expectedRevisions: Set<String>
    let allowsCreation: Bool
    static let create = Self(expectedRevisions: [], allowsCreation: true)
}

/// Opaque account identity obtained by the transport, never supplied by record content.
struct PersonalArchiveAccount: Equatable, Sendable {
    let key: String
    let generation: UInt64
    var context: String { "\(key):\(generation)" }
}

struct PersonalArchivePayload: Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    let createdAt: Date
    let capturedAt: Date?
    let jpegSHA256: String?
    let jpegByteCount: Int
    var context: PersonalArchiveContext? = nil
    var changeID: UUID? = nil
    var deletedAt: Date? = nil
    var isDeleted: Bool { deletedAt != nil }

    func validate() throws {
        guard text.count <= 500, text.utf8.count <= 65_536, text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              Self.validDate(createdAt), capturedAt.map(Self.validDate) ?? true,
              jpegByteCount >= 0, jpegByteCount <= PersonalArchiveStore.maximumJPEGBytes,
              (jpegSHA256 == nil) == (jpegByteCount == 0),
              jpegSHA256.map(PersonalArchiveFiles.isDigest) ?? true,
              deletedAt.map(Self.validDate) ?? true,
              isDeleted ? (text.isEmpty && jpegSHA256 == nil && capturedAt == nil && context == nil && changeID != nil)
                        : (!text.isEmpty || jpegSHA256 != nil) else { throw PersonalArchiveError.corruptedState }
        try context?.validate()
    }

    static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && (-62_135_596_800.0...253_402_300_799.0).contains(date.timeIntervalSince1970)
    }

    var fingerprint: String {
        // Whole-second dates keep CloudKit's NSDate round trip stable.
        let parts = [id.uuidString, text, String(createdAt.timeIntervalSince1970),
                     capturedAt.map { String($0.timeIntervalSince1970) } ?? "",
                     jpegSHA256 ?? "", String(jpegByteCount)]
        // Keep the exact legacy fingerprint for pre-context records and pending retries.
        if context == nil && changeID == nil && deletedAt == nil {
            return PersonalArchiveFiles.digest((try? JSONEncoder().encode(parts)) ?? Data())
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return PersonalArchiveFiles.digest((try? encoder.encode(self)) ?? Data())
    }

    func accepts(_ data: Data) -> Bool {
        data.count == jpegByteCount && PersonalArchiveFiles.validJPEG(data)
            && PersonalArchiveFiles.digest(data) == jpegSHA256
    }
}

struct PersonalArchiveRemoteRecord: Sendable {
    let payload: PersonalArchivePayload
    let jpegData: Data?
}

struct PersonalArchiveRemoteSnapshot: Sendable {
    let generation: UUID
    let records: [PersonalArchiveRemoteRecord]
    let deletedIDs: Set<UUID>
}

protocol PersonalArchiveTransport: Sendable {
    func account() async throws -> PersonalArchiveAccount
    func isCurrent(_ account: PersonalArchiveAccount) async -> Bool
    func prepareZone(for account: PersonalArchiveAccount, allowCreation: Bool, expectedGeneration: UUID?) async throws -> UUID
    func upload(_ payload: PersonalArchivePayload, jpegData: Data?, account: PersonalArchiveAccount, generation: UUID) async throws
    func fetch(account: PersonalArchiveAccount, expectedGeneration: UUID?) async throws -> PersonalArchiveRemoteSnapshot
    func commit(_ payload: PersonalArchivePayload, jpegData: Data?, precondition: PersonalArchivePrecondition,
                account: PersonalArchiveAccount, generation: UUID) async throws
}

extension PersonalArchiveTransport {
    func commit(_ payload: PersonalArchivePayload, jpegData: Data?, precondition: PersonalArchivePrecondition,
                account: PersonalArchiveAccount, generation: UUID) async throws {
        guard precondition == .create, !payload.isDeleted else { throw PersonalArchiveError.notConfigured }
        try await upload(payload, jpegData: jpegData, account: account, generation: generation)
    }
}

enum PersonalArchiveFiles {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func validJPEG(_ data: Data) -> Bool {
        data.count >= 5 && data.count <= PersonalArchiveStore.maximumJPEGBytes
            && data.starts(with: [0xff, 0xd8, 0xff]) && data.suffix(2).elementsEqual([0xff, 0xd9])
    }
    static func write(_ data: Data, to url: URL, excludedFromBackup: Bool = false) throws {
        do {
            var directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
#if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
#endif
            var values = URLResourceValues(); values.isExcludedFromBackup = excludedFromBackup
            try directory.setResourceValues(values)
            guard try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == excludedFromBackup else {
                throw PersonalArchiveError.storageUnavailable
            }
#if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
#else
            try data.write(to: url, options: [.atomic])
#endif
        } catch { throw PersonalArchiveError.storageUnavailable }
    }
}

/// Explicit private preservation. Source linkage stays local; no shared captions or note-store writes.
/// OS backup remains eligible; this is not a promise of permanent retention or complete deletion.
actor PersonalArchiveStore {
    static let shared = PersonalArchiveStore(transport: PersonalArchiveCloudConfiguration.makeClient())
    nonisolated static var isConfigured: Bool { PersonalArchiveCloudConfiguration.containerIdentifier != nil }
    nonisolated static let maximumCharacters = 500
    nonisolated static let maximumJPEGBytes = 20 * 1024 * 1024

    private struct Entry: Codable {
        var payload: PersonalArchivePayload
        var state: PersonalArchiveRecordState
        var issue: PersonalArchiveError?
        var precondition: PersonalArchivePrecondition? = nil
        var conflictingPayload: PersonalArchivePayload? = nil
        var previousPayload: PersonalArchivePayload? = nil
    }
    private struct SourceLink: Codable {
        let source: PersonalArchiveSourceSnapshot
        let recordID: UUID
        let fingerprint: String
        // Local baseline for enrolled edits when a newer remote version has
        // already been fetched. Never encoded into a CloudKit payload.
        var payload: PersonalArchivePayload? = nil
    }
    private struct State: Codable {
        var schema = 1
        let accountKey: String
        var zoneCreationAttempted = false
        var zoneConfirmed = false
        var zoneGeneration: UUID?
        var entries: [String: Entry] = [:]
        var sources: [String: SourceLink]? = nil
    }
    private static let commitLock = NSLock()
    private let directory: URL?
    private let transport: (any PersonalArchiveTransport)?

    init(directory: URL? = nil, transport: (any PersonalArchiveTransport)?) {
        self.directory = directory; self.transport = transport
    }

    func accountContext() async throws -> String { try await currentAccount().context }

    func verifiedAccount(expectedAccount: String) async throws -> PersonalArchiveAccount {
        let account = try await checkedAccount(expectedAccount)
        try await assertCurrent(account)
        return account
    }

    /// Explicit local correspondence only, including divergent legacy copies.
    /// Returning a link does not grant permission to overwrite either side.
    func linkedRecord(noteID: UUID, expectedAccount: String) async throws -> PersonalArchiveRecord? {
        let account = try await checkedAccount(expectedAccount)
        let state = try readState(account)
        let result = try state.sources?[noteID.uuidString].flatMap { link in
            try readRecords(account, state: state).first { $0.id == link.recordID }
        }
        try await assertCurrent(account)
        return result
    }

    func sourceSnapshot(recordID: UUID, expectedAccount: String, matchingPayload: Bool = false) async throws -> PersonalArchiveSourceSnapshot? {
        let account = try await checkedAccount(expectedAccount)
        let state = try readState(account)
        let link = (state.sources ?? [:]).values.first { $0.recordID == recordID }
        let entry = state.entries[recordID.uuidString]
        let matches = entry.map { !$0.payload.isDeleted && $0.state != .conflict && link?.fingerprint == $0.payload.fingerprint } ?? false
        let source = matchingPayload && !matches ? nil : link?.source
        try await assertCurrent(account)
        return source
    }

    func retryRecord(id: UUID, expectedAccount: String) async throws -> PersonalArchiveRecord? {
        let account = try await checkedAccount(expectedAccount)
        try await attempt(id, account: account)
        try await assertCurrent(account)
        return try readRecords(account).first { $0.id == id }
    }

    /// Includes the private tombstone for the enrolled memo's status only.
    func memoRecord(id: UUID, expectedAccount: String) async throws -> PersonalArchiveRecord? {
        let account = try await checkedAccount(expectedAccount)
        let state = try readState(account)
        guard let entry = state.entries[id.uuidString] else { return nil }
        let record: PersonalArchiveRecord?
        if entry.payload.isDeleted {
            let p = entry.payload
            record = PersonalArchiveRecord(id: id, text: "", createdAt: p.createdAt, capturedAt: nil,
                jpegData: nil, state: entry.state, issue: entry.issue, revision: p.fingerprint, isDeletionPending: true)
        } else { record = try readRecords(account, state: state).first { $0.id == id } }
        try await assertCurrent(account)
        return record
    }

    /// Changes only the device-local alias after an enrolled memo accepts a
    /// fetched version. The payload and transport are not modified.
    func acknowledgeMemoSource(_ source: PersonalArchiveSourceSnapshot, recordID: UUID,
                               expectedRevision: String, expectedAccount: String) async throws {
        let account = try await checkedAccount(expectedAccount)
        try update(account) { state, _ in
            guard let entry = state.entries[recordID.uuidString], !entry.payload.isDeleted,
                  entry.state == .stored, entry.payload.fingerprint == expectedRevision,
                  state.sources?[source.noteID.uuidString]?.recordID == recordID else { throw PersonalArchiveError.conflict }
            state.sources?[source.noteID.uuidString] = SourceLink(source: source, recordID: recordID,
                fingerprint: expectedRevision, payload: entry.payload)
        }
        try await assertCurrent(account)
    }

    /// Actual payload metadata, not local JPEG availability, determines whether
    /// deleting words leaves a photo or removes a genuinely text-only record.
    func deleteWords(id: UUID, operationID: UUID, expectedRevision: String,
                     expectedAccount: String, sourceSnapshot: PersonalArchiveSourceSnapshot? = nil) async throws -> PersonalArchiveRecord {
        let account = try await checkedAccount(expectedAccount)
        guard let entry = try readState(account).entries[id.uuidString] else { throw PersonalArchiveError.conflict }
        if entry.payload.jpegSHA256 != nil {
            return try await update(id: id, operationID: operationID, expectedRevision: expectedRevision,
                text: "", capturedAt: entry.payload.capturedAt, context: entry.payload.context,
                expectedAccount: expectedAccount, sourceSnapshot: sourceSnapshot)
        }
        _ = try await delete(id: id, operationID: operationID, expectedRevision: expectedRevision, expectedAccount: expectedAccount)
        guard let record = try await memoRecord(id: id, expectedAccount: expectedAccount) else { throw PersonalArchiveError.corruptedState }
        return record
    }

    func records() async throws -> [PersonalArchiveRecord] {
        let account = try await currentAccount()
        try await assertCurrent(account)
        return try readRecords(account)
    }

    /// One local catalog/image read for the personal reading surface. This does
    /// not fetch records, retry pending operations, persist links or upload.
    func readingSnapshot(expectedAccount: String? = nil) async throws -> PersonalArchiveReadingSnapshot {
        let account: PersonalArchiveAccount
        if let expectedAccount { account = try await checkedAccount(expectedAccount) }
        else { account = try await currentAccount() }
        try await assertCurrent(account)
        let state = try readState(account)
        let records = try readRecords(account, state: state)
        let completeIDs = Set(records.filter { $0.state == .stored && !$0.isDeletionPending }.map(\.id))
        let associations = (state.sources ?? [:]).values.compactMap { link -> PersonalArchiveReadingAssociation? in
            guard let entry = state.entries[link.recordID.uuidString],
                  entry.state == .stored, !entry.payload.isDeleted,
                  completeIDs.contains(link.recordID),
                  link.fingerprint == entry.payload.fingerprint else { return nil }
            return PersonalArchiveReadingAssociation(source: link.source, recordID: link.recordID)
        }.sorted { $0.source.noteID.uuidString < $1.source.noteID.uuidString }
        // Account notifications may arrive while either identity check awaits.
        try await assertCurrent(account)
        return PersonalArchiveReadingSnapshot(account: account, records: records, associations: associations)
    }

    func pendingOperationCount() async throws -> Int {
        let account = try await currentAccount()
        return try readState(account).entries.values.filter { $0.state == .pending }.count
    }

    func preservationStatus(source: PersonalArchiveSourceSnapshot, jpegData: Data? = nil,
                            expectedAccount: String) async throws -> PersonalArchivePreservationStatus {
        let account = try await checkedAccount(expectedAccount)
        let state = try readState(account)
        guard let link = state.sources?[source.noteID.uuidString], let entry = state.entries[link.recordID.uuidString] else { return .localOnly }
        if entry.payload.isDeleted { return entry.state == .stored ? .deleted : (entry.state == .conflict ? .conflict : .pending) }
        if entry.state == .conflict { return .conflict }
        if link.source != source || link.fingerprint != entry.payload.fingerprint
            || jpegData.map({ PersonalArchiveFiles.digest($0) != entry.payload.jpegSHA256 }) == true { return .changed }
        let record = try readRecords(account).first { $0.id == link.recordID }
        switch record?.state {
        case .pending: return .pending
        case .partial: return .partial
        case .conflict: return .conflict
        case .stored: return .stored
        case nil: return .localOnly
        }
    }

    /// Only this explicit operation creates/updates a source link. Normal note edits never call it.
    @discardableResult
    func preserve(source: PersonalArchiveSourceSnapshot, jpegData: Data?, text: String,
                  capturedAt: Date?, context: PersonalArchiveContext?, expectedAccount: String,
                  recreateDeleted: Bool = false) async throws -> PersonalArchiveRecord {
        let account = try await checkedAccount(expectedAccount)
        let normalized = try validatedText(text, jpegData: jpegData, capturedAt: capturedAt, context: context)
        guard !source.revision.isEmpty, source.revision.utf8.count <= 1024,
              source.photoIdentifier.map({ $0.utf8.count <= 4096 }) ?? true else { throw PersonalArchiveError.corruptedState }
        let id: UUID = try update(account) { state, folder in
            var link = state.sources?[source.noteID.uuidString]
            var existing = link.flatMap { state.entries[$0.recordID.uuidString] }
            // A tombstone is not a license to silently recreate a previously deleted source.
            if existing?.payload.isDeleted == true {
                guard recreateDeleted, existing?.state == .stored else { throw PersonalArchiveError.conflict }
                link = nil; existing = nil // Explicit new preservation gets a new UUID; the old tombstone remains.
            }
            let id = link?.recordID ?? UUID()
            var payload = PersonalArchivePayload(id: id, text: normalized,
                createdAt: existing?.payload.createdAt ?? Self.wholeSecond(Date()), capturedAt: capturedAt.map(Self.wholeSecond),
                jpegSHA256: jpegData.map(PersonalArchiveFiles.digest), jpegByteCount: jpegData?.count ?? 0,
                context: context, changeID: existing?.payload.changeID)
            try payload.validate()
            if let existing, existing.payload == payload {
                guard existing.state != .conflict else { throw PersonalArchiveError.conflict }
                if let jpegData { try PersonalArchiveFiles.write(jpegData, to: self.imageURL(payload, folder)) }
            } else {
                guard existing == nil || (existing?.state != .pending && existing?.state != .conflict) else { throw PersonalArchiveError.conflict }
                if existing != nil { payload.changeID = UUID() }
                if let jpegData { try PersonalArchiveFiles.write(jpegData, to: self.imageURL(payload, folder)) }
                state.entries[id.uuidString] = Entry(payload: payload, state: .pending,
                    precondition: existing.map { PersonalArchivePrecondition(expectedRevisions: [$0.payload.fingerprint], allowsCreation: false) } ?? .create)
                state.zoneCreationAttempted = true
            }
            var links = state.sources ?? [:]
            links[source.noteID.uuidString] = SourceLink(source: source, recordID: id, fingerprint: payload.fingerprint, payload: payload)
            state.sources = links
            return id
        }
        try await attempt(id, account: account)
        return try requiredRecord(id, account: account)
    }

    @discardableResult
    func update(id: UUID, operationID: UUID, expectedRevision: String, text: String, capturedAt: Date?,
                context: PersonalArchiveContext?, expectedAccount: String,
                sourceSnapshot: PersonalArchiveSourceSnapshot? = nil) async throws -> PersonalArchiveRecord {
        let account = try await checkedAccount(expectedAccount)
        try update(account) { state, _ in
            guard let existing = state.entries[id.uuidString], !existing.payload.isDeleted else { throw PersonalArchiveError.conflict }
            let sourceLink = sourceSnapshot.flatMap { state.sources?[$0.noteID.uuidString] }
            if let sourceSnapshot {
                guard sourceLink?.recordID == id, sourceLink?.source.photoIdentifier == sourceSnapshot.photoIdentifier else {
                    throw PersonalArchiveError.conflict
                }
            }
            let base = sourceLink?.payload.flatMap { $0.fingerprint == expectedRevision ? $0 : nil } ?? existing.payload
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.count <= Self.maximumCharacters, normalized.utf8.count <= 65_536 else { throw PersonalArchiveError.textTooLong }
            guard !normalized.isEmpty || base.jpegSHA256 != nil else { throw PersonalArchiveError.emptyRecord }
            let payload = PersonalArchivePayload(id: id, text: normalized, createdAt: base.createdAt,
                capturedAt: capturedAt.map(Self.wholeSecond), jpegSHA256: base.jpegSHA256,
                jpegByteCount: base.jpegByteCount, context: context, changeID: operationID)
            try payload.validate()
            if existing.payload.changeID == operationID {
                guard existing.payload == payload, existing.state != .conflict else { throw PersonalArchiveError.conflict }
                return
            }
            guard existing.state != .pending && existing.state != .conflict else { throw PersonalArchiveError.conflict }
            if existing.payload.fingerprint != expectedRevision {
                guard sourceSnapshot != nil, base.fingerprint == expectedRevision else { throw PersonalArchiveError.conflict }
                state.entries[id.uuidString] = Entry(payload: payload, state: .conflict, issue: .conflict,
                    conflictingPayload: existing.payload, previousPayload: base)
            } else {
                state.entries[id.uuidString] = Entry(payload: payload, state: .pending,
                    precondition: PersonalArchivePrecondition(expectedRevisions: [expectedRevision], allowsCreation: false),
                    previousPayload: existing.payload)
            }
            if let sourceSnapshot {
                guard let link = state.sources?[sourceSnapshot.noteID.uuidString], link.recordID == id,
                      link.source.photoIdentifier == sourceSnapshot.photoIdentifier else { throw PersonalArchiveError.conflict }
                state.sources?[sourceSnapshot.noteID.uuidString] = SourceLink(
                    source: sourceSnapshot, recordID: id, fingerprint: payload.fingerprint, payload: payload)
            }
        }
        try await attempt(id, account: account)
        return try requiredRecord(id, account: account)
    }

    @discardableResult
    func delete(id: UUID, operationID: UUID, expectedRevision: String, expectedAccount: String) async throws -> PersonalArchiveRecordState {
        let account = try await checkedAccount(expectedAccount)
        try update(account) { state, _ in
            guard let existing = state.entries[id.uuidString] else { throw PersonalArchiveError.conflict }
            if existing.payload.isDeleted {
                guard existing.payload.changeID == operationID || existing.state == .stored else { throw PersonalArchiveError.conflict }
                return
            }
            guard existing.payload.fingerprint == expectedRevision, existing.state != .conflict else { throw PersonalArchiveError.conflict }
            // An unacknowledged request may already have committed. Both known revisions
            // are admissible for withdrawal, but an unrelated device's edit is not.
            var expected = existing.precondition?.expectedRevisions ?? []
            expected.insert(existing.payload.fingerprint)
            let payload = PersonalArchivePayload(id: id, text: "", createdAt: existing.payload.createdAt,
                capturedAt: nil, jpegSHA256: nil, jpegByteCount: 0,
                changeID: operationID, deletedAt: Self.wholeSecond(Date()))
            state.entries[id.uuidString] = Entry(payload: payload, state: .pending,
                precondition: PersonalArchivePrecondition(expectedRevisions: expected, allowsCreation: true),
                previousPayload: existing.payload)
            for key in Array((state.sources ?? [:]).keys) where state.sources?[key]?.recordID == id {
                state.sources?[key]?.payload = nil
            }
        }
        try await attempt(id, account: account)
        guard let entry = try readState(account).entries[id.uuidString] else { throw PersonalArchiveError.corruptedState }
        return entry.state
    }

    /// Explicit choice between two observed versions. The server CAS still
    /// rejects another device changing it after the confirmation was shown.
    func validateMemoConflict(id: UUID, localRevision: String, remoteRevision: String,
                              text: String, expectedAccount: String) async throws {
        let account = try await checkedAccount(expectedAccount)
        guard let entry = try readState(account).entries[id.uuidString], entry.state == .conflict,
              entry.payload.fingerprint == localRevision, let remote = entry.conflictingPayload,
              remote.fingerprint == remoteRevision, !entry.payload.isDeleted, !remote.isDeleted,
              entry.payload.jpegSHA256 == remote.jpegSHA256 else { throw PersonalArchiveError.conflict }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count <= Self.maximumCharacters, normalized.utf8.count <= 65_536 else { throw PersonalArchiveError.textTooLong }
        guard !normalized.isEmpty || entry.payload.jpegSHA256 != nil else { throw PersonalArchiveError.conflict }
        try await assertCurrent(account)
    }

    func resolveMemoConflict(id: UUID, operationID: UUID, localRevision: String, remoteRevision: String,
                             text: String, sourceSnapshot: PersonalArchiveSourceSnapshot? = nil,
                             expectedAccount: String) async throws -> PersonalArchiveRecord {
        let account = try await checkedAccount(expectedAccount)
        try update(account) { state, _ in
            guard let entry = state.entries[id.uuidString] else { throw PersonalArchiveError.conflict }
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if entry.payload.changeID == operationID {
                guard entry.payload.text == normalized, entry.state != .conflict else { throw PersonalArchiveError.conflict }
                return
            }
            guard entry.state == .conflict, entry.payload.fingerprint == localRevision,
                  let remote = entry.conflictingPayload, remote.fingerprint == remoteRevision,
                  !entry.payload.isDeleted, !remote.isDeleted,
                  entry.payload.jpegSHA256 == remote.jpegSHA256 else { throw PersonalArchiveError.conflict }
            let payload = PersonalArchivePayload(id: id, text: normalized, createdAt: entry.payload.createdAt,
                capturedAt: entry.payload.capturedAt, jpegSHA256: entry.payload.jpegSHA256,
                jpegByteCount: entry.payload.jpegByteCount, context: entry.payload.context, changeID: operationID)
            try payload.validate()
            state.entries[id.uuidString] = Entry(payload: payload, state: .pending,
                precondition: PersonalArchivePrecondition(expectedRevisions: [remoteRevision], allowsCreation: false),
                conflictingPayload: remote, previousPayload: entry.payload)
            if let sourceSnapshot {
                guard state.sources?[sourceSnapshot.noteID.uuidString]?.recordID == id else { throw PersonalArchiveError.conflict }
                state.sources?[sourceSnapshot.noteID.uuidString] = SourceLink(source: sourceSnapshot, recordID: id,
                    fingerprint: payload.fingerprint, payload: payload)
            }
        }
        try await attempt(id, account: account)
        return try requiredRecord(id, account: account)
    }

    private func checkedAccount(_ expected: String) async throws -> PersonalArchiveAccount {
        let account = try await currentAccount()
        guard account.context == expected else { throw PersonalArchiveError.accountChanged }
        return account
    }

    private func validatedText(_ text: String, jpegData: Data?, capturedAt: Date?, context: PersonalArchiveContext?) throws -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count <= Self.maximumCharacters, normalized.utf8.count <= 65_536 else { throw PersonalArchiveError.textTooLong }
        guard !normalized.isEmpty || jpegData != nil else { throw PersonalArchiveError.emptyRecord }
        if let jpegData, !PersonalArchiveFiles.validJPEG(jpegData) { throw PersonalArchiveError.invalidJPEG }
        guard capturedAt.map(PersonalArchivePayload.validDate) ?? true else { throw PersonalArchiveError.corruptedState }
        try context?.validate()
        return normalized
    }

    private func requiredRecord(_ id: UUID, account: PersonalArchiveAccount) throws -> PersonalArchiveRecord {
        guard let record = try readRecords(account).first(where: { $0.id == id }) else { throw PersonalArchiveError.corruptedState }
        return record
    }

    private func attempt(_ id: UUID, account: PersonalArchiveAccount) async throws {
        guard let operation = try readState(account).entries[id.uuidString], operation.state == .pending else { return }
        do {
            let state = try readState(account)
            let initializing = state.zoneGeneration == nil && !state.zoneConfirmed
                && state.entries.values.allSatisfy { $0.state == .pending }
            let generation = try await transport!.prepareZone(for: account, allowCreation: initializing, expectedGeneration: state.zoneGeneration)
            try await assertCurrent(account)
            try bind(generation, account: account)
            try await send(id, account: account)
        } catch {
            try await assertCurrent(account)
            let issue = Self.safeError(error)
            try recordFailure(issue, id: id, account: account, expectedFingerprint: operation.payload.fingerprint)
            if issue == .accountChanged || issue == .cancelled || issue == .storageUnavailable { throw issue }
        }
    }

    @discardableResult
    func save(id: UUID, jpegData: Data?, text: String, capturedAt: Date?, expectedAccount: String) async throws -> PersonalArchiveRecord {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count <= Self.maximumCharacters, normalized.utf8.count <= 65_536 else { throw PersonalArchiveError.textTooLong }
        guard !normalized.isEmpty || jpegData != nil else { throw PersonalArchiveError.emptyRecord }
        if let jpegData, !PersonalArchiveFiles.validJPEG(jpegData) { throw PersonalArchiveError.invalidJPEG }
        guard capturedAt.map(PersonalArchivePayload.validDate) ?? true else { throw PersonalArchiveError.corruptedState }
        let account = try await currentAccount()
        guard account.context == expectedAccount else { throw PersonalArchiveError.accountChanged }
        try await assertCurrent(account)
        let preparation = try update(account) { state, folder in
            // No upload can start before a durable generation binding. An unbound,
            // explicitly enrolled draft may therefore continue its first initialization.
            let allow = state.zoneGeneration == nil && !state.zoneConfirmed
                && state.entries.values.allSatisfy { $0.state == .pending }
            let existing = state.entries[id.uuidString]
            let payload = PersonalArchivePayload(id: id, text: normalized,
                createdAt: existing?.payload.createdAt ?? Self.wholeSecond(Date()), capturedAt: capturedAt.map(Self.wholeSecond),
                jpegSHA256: jpegData.map(PersonalArchiveFiles.digest), jpegByteCount: jpegData?.count ?? 0)
            try payload.validate()
            if let existing {
                guard existing.payload.fingerprint == payload.fingerprint, existing.state != .conflict else {
                    throw PersonalArchiveError.conflict
                }
                return (payload, allow, existing.state == .pending)
            }
            state.zoneCreationAttempted = true
            if let jpegData { try PersonalArchiveFiles.write(jpegData, to: self.imageURL(payload, folder)) }
            state.entries[payload.id.uuidString] = Entry(payload: payload, state: .pending)
            return (payload, allow, true)
        }
        let (payload, allowCreation, shouldSend) = preparation
        do {
            if shouldSend {
                let expectedGeneration = try readState(account).zoneGeneration
                guard allowCreation || expectedGeneration != nil else { throw PersonalArchiveError.archiveChanged }
                let generation = try await transport!.prepareZone(for: account, allowCreation: allowCreation,
                    expectedGeneration: expectedGeneration)
                try await assertCurrent(account)
                try bind(generation, account: account)
                try await send(payload.id, account: account)
            }
        } catch {
            let issue = Self.safeError(error)
            try await assertCurrent(account)
            try recordFailure(issue, id: payload.id, account: account, expectedFingerprint: payload.fingerprint)
            if issue == .accountChanged || issue == .cancelled || issue == .storageUnavailable { throw issue }
        }
        guard let record = try readRecords(account).first(where: { $0.id == payload.id }) else {
            throw PersonalArchiveError.corruptedState
        }
        return record
    }

    func retryPending() async throws {
        let account = try await currentAccount()
        let pending = try readState(account).entries.values.filter { $0.state == .pending }.map { $0.payload.id }
        guard !pending.isEmpty else { return }
        do {
            let state = try readState(account)
            let initializing = state.zoneCreationAttempted && state.zoneGeneration == nil && !state.zoneConfirmed
                && state.entries.values.allSatisfy { $0.state == .pending }
            let generation = try await transport!.prepareZone(for: account, allowCreation: initializing,
                expectedGeneration: state.zoneGeneration)
            try await assertCurrent(account)
            try bind(generation, account: account)
            for id in pending { try await send(id, account: account) }
        } catch { try await assertCurrent(account); throw Self.safeError(error) }
    }

    func refresh() async throws -> [PersonalArchiveRecord] {
        let account = try await currentAccount()
        let before = try readState(account)
        let snapshot: PersonalArchiveRemoteSnapshot
        do { snapshot = try await transport!.fetch(account: account, expectedGeneration: before.zoneGeneration) }
        catch { try await assertCurrent(account); throw Self.safeError(error) }
        try await assertCurrent(account)
        try update(account) { state, folder in
            guard state.zoneGeneration == nil || state.zoneGeneration == snapshot.generation else { throw PersonalArchiveError.archiveChanged }
            state.zoneConfirmed = true
            state.zoneGeneration = snapshot.generation
            for remote in snapshot.records {
                try remote.payload.validate()
                let key = remote.payload.id.uuidString
                let existing = state.entries[key]
                // A result started before a local edit/delete is not its acknowledgement.
                if existing?.payload.fingerprint != before.entries[key]?.payload.fingerprint { continue }
                if remote.payload.isDeleted {
                    for sourceKey in Array((state.sources ?? [:]).keys) where state.sources?[sourceKey]?.recordID == remote.payload.id {
                        state.sources?[sourceKey]?.payload = nil
                    }
                    if let existing, !existing.payload.isDeleted, existing.state == .pending || existing.state == .conflict {
                        state.entries[key] = Entry(payload: remote.payload, state: .conflict, issue: .conflict,
                            previousPayload: existing.payload)
                    } else {
                        state.entries[key] = Entry(payload: remote.payload, state: .stored)
                    }
                    continue
                }
                if let existing, existing.payload.fingerprint != remote.payload.fingerprint,
                   existing.state == .pending || existing.state == .conflict || existing.payload.isDeleted {
                    if existing.state == .pending,
                       existing.precondition?.expectedRevisions.contains(remote.payload.fingerprint) == true {
                        continue // The old server version is normal while an explicit operation is pending.
                    }
                    state.entries[key]?.state = .conflict
                    state.entries[key]?.issue = .conflict
                    state.entries[key]?.conflictingPayload = remote.payload
                    if let bytes = remote.jpegData, remote.payload.accepts(bytes) {
                        try PersonalArchiveFiles.write(bytes, to: self.imageURL(remote.payload, folder))
                    }
                    continue
                }
                let hasPhoto = remote.payload.jpegSHA256 != nil
                let complete = !hasPhoto || remote.jpegData.map(remote.payload.accepts) == true
                if let bytes = remote.jpegData, remote.payload.accepts(bytes) {
                    try PersonalArchiveFiles.write(bytes, to: self.imageURL(remote.payload, folder))
                }
                // A partial fetch never erases an already verified local image.
                let pending = state.entries[key]?.state == .pending
                state.entries[key] = Entry(payload: remote.payload,
                    state: complete ? .stored : (pending ? .pending : .partial),
                    issue: complete ? nil : .corruptedState)
            }
            for id in snapshot.deletedIDs where state.entries[id.uuidString] != nil {
                // Retain local words, but never automatically upload a remotely removed record.
                state.entries[id.uuidString]?.state = .conflict
                state.entries[id.uuidString]?.issue = .conflict
            }
        }
        try removeAcknowledgedImages(account)
        return try readRecords(account)
    }

    private func send(_ id: UUID, account: PersonalArchiveAccount) async throws {
        try await assertCurrent(account)
        let state = try readState(account)
        let entry = state.entries[id.uuidString]
        guard let entry, entry.state == .pending else { return }
        guard let generation = state.zoneGeneration else { throw PersonalArchiveError.zoneMissing }
        let folder = try accountFolder(account)
        let bytes = try imageData(entry.payload, folder: folder)
        let condition = entry.precondition ?? .create
        if entry.payload.jpegSHA256 != nil && bytes == nil && condition.expectedRevisions.isEmpty { throw PersonalArchiveError.corruptedState }
        do {
            try await transport!.commit(entry.payload, jpegData: bytes, precondition: condition, account: account, generation: generation)
            try await assertCurrent(account)
            try update(account) { state, _ in
                guard state.entries[id.uuidString]?.state == .pending,
                      state.entries[id.uuidString]?.payload.fingerprint == entry.payload.fingerprint else { return }
                state.entries[id.uuidString]?.state = .stored
                state.entries[id.uuidString]?.issue = nil
                state.entries[id.uuidString]?.precondition = nil
                state.entries[id.uuidString]?.previousPayload = nil
                state.entries[id.uuidString]?.conflictingPayload = nil
            }
            try removeAcknowledgedImages(account)
        } catch {
            try await assertCurrent(account)
            let issue = Self.safeError(error)
            try recordFailure(issue, id: id, account: account, expectedFingerprint: entry.payload.fingerprint)
            throw issue
        }
    }

    private func recordFailure(_ issue: PersonalArchiveError, id: UUID, account: PersonalArchiveAccount, expectedFingerprint: String) throws {
        try update(account) { state, _ in
            guard state.entries[id.uuidString]?.state == .pending,
                  state.entries[id.uuidString]?.payload.fingerprint == expectedFingerprint else { return }
            state.entries[id.uuidString]?.issue = issue
            if issue == .conflict { state.entries[id.uuidString]?.state = .conflict }
        }
    }
    private func bind(_ generation: UUID, account: PersonalArchiveAccount) throws {
        try update(account) { state, _ in
            guard state.zoneGeneration == nil || state.zoneGeneration == generation else { throw PersonalArchiveError.archiveChanged }
            state.zoneGeneration = generation; state.zoneConfirmed = true
        }
    }
    private func currentAccount() async throws -> PersonalArchiveAccount {
        guard let transport else { throw PersonalArchiveError.notConfigured }
        do {
            let account = try await transport.account()
            guard PersonalArchiveFiles.isDigest(account.key) else { throw PersonalArchiveError.accountChanged }
            try await assertCurrent(account)
            return account
        } catch { throw Self.safeError(error) }
    }
    private func assertCurrent(_ account: PersonalArchiveAccount) async throws {
        guard let transport, await transport.isCurrent(account) else { throw PersonalArchiveError.accountChanged }
        if Task.isCancelled { throw PersonalArchiveError.cancelled }
    }
    private static func safeError(_ error: Error) -> PersonalArchiveError {
        if error is CancellationError { return .cancelled }
        return error as? PersonalArchiveError ?? .networkUnavailable
    }
    private static func wholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
    private func accountFolder(_ account: PersonalArchiveAccount) throws -> URL {
        let root: URL
        if let directory { root = directory }
        else {
            do {
                root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: false).appendingPathComponent("PersonalArchive", isDirectory: true)
            } catch { throw PersonalArchiveError.storageUnavailable }
        }
        return root.appendingPathComponent(account.key, isDirectory: true)
    }
    private func imageURL(_ payload: PersonalArchivePayload, _ folder: URL) -> URL {
        folder.appendingPathComponent(payload.id.uuidString + "-" + (payload.jpegSHA256 ?? "none") + ".jpg")
    }
    private func imageData(_ payload: PersonalArchivePayload, folder: URL) throws -> Data? {
        guard payload.jpegSHA256 != nil else { return nil }
        let url = imageURL(payload, folder)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size == payload.jpegByteCount,
              let data = try? Data(contentsOf: url), payload.accepts(data) else { return nil }
        return data
    }
    private func readRecords(_ account: PersonalArchiveAccount) throws -> [PersonalArchiveRecord] {
        try readRecords(account, state: readState(account))
    }
    private func readRecords(_ account: PersonalArchiveAccount, state: State) throws -> [PersonalArchiveRecord] {
        let folder = try accountFolder(account)
        return try state.entries.values.compactMap { entry -> PersonalArchiveRecord? in
            let payload: PersonalArchivePayload
            if entry.payload.isDeleted {
                guard entry.state != .stored, let previous = entry.previousPayload else { return nil }
                payload = previous
            } else { payload = entry.payload }
            let bytes = try imageData(payload, folder: folder)
            let missing = payload.jpegSHA256 != nil && bytes == nil
            return PersonalArchiveRecord(id: payload.id, text: payload.text,
                createdAt: payload.createdAt, capturedAt: payload.capturedAt, jpegData: bytes,
                state: missing && entry.state == .stored ? .partial : entry.state,
                issue: missing ? .corruptedState : entry.issue, context: payload.context,
                revision: payload.fingerprint, conflictingText: entry.conflictingPayload?.text,
                isDeletionPending: entry.payload.isDeleted, conflictingRevision: entry.conflictingPayload?.fingerprint)
        }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
    }

    private func removeAcknowledgedImages(_ account: PersonalArchiveAccount) throws {
        let state = try readState(account), folder = try accountFolder(account)
        let removed = Set(state.entries.values.filter { $0.payload.isDeleted && $0.state == .stored }.map { $0.payload.id.uuidString })
        guard !removed.isEmpty else { return }
        do {
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                if file.pathExtension == "jpg", removed.contains(String(file.lastPathComponent.prefix(36))) {
                    try FileManager.default.removeItem(at: file)
                }
            }
        } catch { throw PersonalArchiveError.storageUnavailable }
    }
    private func readState(_ account: PersonalArchiveAccount) throws -> State {
        Self.commitLock.lock(); defer { Self.commitLock.unlock() }
        return try load(account, folder: accountFolder(account))
    }
    private func load(_ account: PersonalArchiveAccount, folder: URL) throws -> State {
        let data: Data
        do { data = try Data(contentsOf: folder.appendingPathComponent("state.json")) }
        catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain && [CocoaError.Code.fileReadNoSuchFile.rawValue, CocoaError.Code.fileNoSuchFile.rawValue].contains(failure.code) {
                return State(accountKey: account.key)
            }
            throw PersonalArchiveError.storageUnavailable
        }
        do {
            let state = try JSONDecoder().decode(State.self, from: data)
            guard state.schema == 1, state.accountKey == account.key,
                  state.zoneConfirmed == (state.zoneGeneration != nil),
                  state.zoneGeneration != nil || state.entries.values.allSatisfy({ $0.state == .pending }) else {
                throw PersonalArchiveError.corruptedState
            }
            for (key, entry) in state.entries {
                guard key == entry.payload.id.uuidString else { throw PersonalArchiveError.corruptedState }
                try entry.payload.validate()
                try entry.previousPayload?.validate()
                try entry.conflictingPayload?.validate()
                guard entry.previousPayload.map({ $0.id == entry.payload.id }) ?? true,
                      entry.conflictingPayload.map({ $0.id == entry.payload.id }) ?? true,
                      entry.precondition.map({ $0.expectedRevisions.allSatisfy(PersonalArchiveFiles.isDigest) }) ?? true else {
                    throw PersonalArchiveError.corruptedState
                }
            }
            for (key, link) in state.sources ?? [:] {
                guard key == link.source.noteID.uuidString, state.entries[link.recordID.uuidString] != nil,
                      PersonalArchiveFiles.isDigest(link.fingerprint) else { throw PersonalArchiveError.corruptedState }
                if let payload = link.payload {
                    try payload.validate()
                    guard payload.id == link.recordID, payload.fingerprint == link.fingerprint else { throw PersonalArchiveError.corruptedState }
                }
            }
            return state
        } catch { throw PersonalArchiveError.corruptedState }
    }
    private func update<T>(_ account: PersonalArchiveAccount, _ body: (inout State, URL) throws -> T) throws -> T {
        Self.commitLock.lock(); defer { Self.commitLock.unlock() }
        let folder = try accountFolder(account)
        var state = try load(account, folder: folder)
        let result = try body(&state, folder)
        do { try PersonalArchiveFiles.write(JSONEncoder().encode(state), to: folder.appendingPathComponent("state.json")) }
        catch { throw PersonalArchiveError.storageUnavailable }
        return result
    }
}
