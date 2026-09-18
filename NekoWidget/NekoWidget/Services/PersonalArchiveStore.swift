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

    func validate() throws {
        guard text.count <= 500, text.utf8.count <= 65_536, text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              Self.validDate(createdAt), capturedAt.map(Self.validDate) ?? true,
              jpegByteCount >= 0, jpegByteCount <= PersonalArchiveStore.maximumJPEGBytes,
              (jpegSHA256 == nil) == (jpegByteCount == 0),
              jpegSHA256.map(PersonalArchiveFiles.isDigest) ?? true,
              !text.isEmpty || jpegSHA256 != nil else { throw PersonalArchiveError.corruptedState }
    }

    static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && (-62_135_596_800.0...253_402_300_799.0).contains(date.timeIntervalSince1970)
    }

    var fingerprint: String {
        // Whole-second dates keep CloudKit's NSDate round trip stable.
        let parts = [id.uuidString, text, String(createdAt.timeIntervalSince1970),
                     capturedAt.map { String($0.timeIntervalSince1970) } ?? "",
                     jpegSHA256 ?? "", String(jpegByteCount)]
        return PersonalArchiveFiles.digest((try? JSONEncoder().encode(parts)) ?? Data())
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

/// Internal, append-only recovery trial. No PhotoKit IDs, shared captions or note-store writes.
/// OS backup remains eligible; this is not a promise of permanent retention or complete deletion.
actor PersonalArchiveStore {
    static let shared = PersonalArchiveStore(transport: PersonalArchiveCloudConfiguration.makeClient())
    nonisolated static var isConfigured: Bool { PersonalArchiveCloudConfiguration.containerIdentifier != nil }
    nonisolated static let maximumCharacters = 500
    nonisolated static let maximumJPEGBytes = 20 * 1024 * 1024

    private struct Entry: Codable {
        let payload: PersonalArchivePayload
        var state: PersonalArchiveRecordState
        var issue: PersonalArchiveError?
    }
    private struct State: Codable {
        var schema = 1
        let accountKey: String
        var zoneCreationAttempted = false
        var zoneConfirmed = false
        var zoneGeneration: UUID?
        var entries: [String: Entry] = [:]
    }
    private static let commitLock = NSLock()
    private let directory: URL?
    private let transport: (any PersonalArchiveTransport)?

    init(directory: URL? = nil, transport: (any PersonalArchiveTransport)?) {
        self.directory = directory; self.transport = transport
    }

    func accountContext() async throws -> String { try await currentAccount().context }

    func records() async throws -> [PersonalArchiveRecord] {
        let account = try await currentAccount()
        try await assertCurrent(account)
        return try readRecords(account)
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
            try recordFailure(issue, id: payload.id, account: account)
            if issue == .accountChanged || issue == .cancelled || issue == .storageUnavailable { throw issue }
        }
        guard let record = try readRecords(account).first(where: { $0.id == payload.id }) else {
            throw PersonalArchiveError.corruptedState
        }
        return record
    }

    func retryPending() async throws {
        let account = try await currentAccount()
        let pending = try readRecords(account).filter { $0.state == .pending }
        guard !pending.isEmpty else { return }
        do {
            let state = try readState(account)
            let initializing = state.zoneCreationAttempted && state.zoneGeneration == nil && !state.zoneConfirmed
                && state.entries.values.allSatisfy { $0.state == .pending }
            let generation = try await transport!.prepareZone(for: account, allowCreation: initializing,
                expectedGeneration: state.zoneGeneration)
            try await assertCurrent(account)
            try bind(generation, account: account)
            for record in pending { try await send(record.id, account: account) }
        } catch { try await assertCurrent(account); throw Self.safeError(error) }
    }

    func refresh() async throws -> [PersonalArchiveRecord] {
        let account = try await currentAccount()
        let snapshot: PersonalArchiveRemoteSnapshot
        do { snapshot = try await transport!.fetch(account: account, expectedGeneration: readState(account).zoneGeneration) }
        catch { try await assertCurrent(account); throw Self.safeError(error) }
        try await assertCurrent(account)
        try update(account) { state, folder in
            guard state.zoneGeneration == nil || state.zoneGeneration == snapshot.generation else { throw PersonalArchiveError.archiveChanged }
            state.zoneConfirmed = true
            state.zoneGeneration = snapshot.generation
            for remote in snapshot.records {
                try remote.payload.validate()
                let key = remote.payload.id.uuidString
                if let existing = state.entries[key], existing.payload.fingerprint != remote.payload.fingerprint {
                    state.entries[key]?.state = .conflict; state.entries[key]?.issue = .conflict
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
        if entry.payload.jpegSHA256 != nil && bytes == nil { throw PersonalArchiveError.corruptedState }
        do {
            try await transport!.upload(entry.payload, jpegData: bytes, account: account, generation: generation)
            try await assertCurrent(account)
            try update(account) { state, _ in
                guard state.entries[id.uuidString]?.state == .pending else { return }
                state.entries[id.uuidString]?.state = .stored
                state.entries[id.uuidString]?.issue = nil
            }
        } catch {
            try await assertCurrent(account)
            let issue = Self.safeError(error)
            try recordFailure(issue, id: id, account: account)
            throw issue
        }
    }

    private func recordFailure(_ issue: PersonalArchiveError, id: UUID, account: PersonalArchiveAccount) throws {
        try update(account) { state, _ in
            guard state.entries[id.uuidString]?.state == .pending else { return }
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
        let state = try readState(account), folder = try accountFolder(account)
        return try state.entries.values.map { entry in
            let bytes = try imageData(entry.payload, folder: folder)
            let missing = entry.payload.jpegSHA256 != nil && bytes == nil
            return PersonalArchiveRecord(id: entry.payload.id, text: entry.payload.text,
                createdAt: entry.payload.createdAt, capturedAt: entry.payload.capturedAt, jpegData: bytes,
                state: missing && entry.state == .stored ? .partial : entry.state,
                issue: missing ? .corruptedState : entry.issue)
        }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
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
