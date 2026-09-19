import Foundation

// macOS: swiftc -parse-as-library NekoWidget/Services/PersonalArchiveStore.swift \
//   NekoWidget/Services/PersonalArchiveCloudClient.swift ci/verify-personal-archive.swift -o /tmp/verify-personal-archive
// The injected transport never constructs CKContainer or contacts an Apple account.
private actor ArchiveCloudFixture: PersonalArchiveTransport {
    enum Failure: Sendable { case none, beforeCommit, afterCommit, beforePreparation, duringPreparation, afterPreparation }
    private struct Zone {
        var generation: UUID?
        var entries: [UUID: PersonalArchiveRemoteRecord] = [:]
    }
    private var current = PersonalArchiveAccount(key: PersonalArchiveFiles.digest(Data("fixture-a".utf8)), generation: 0)
    private var zones: [String: Zone] = [:]
    private var failure = Failure.none
    private var pauseFetch = false
    private var paused: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var uploadCount = 0
    private var creations = 0
    private var commitHook: (@Sendable () throws -> Void)?
    private var pauseCommit = false
    private var pausedCommit: CheckedContinuation<Void, Never>?
    private var commitStarted: CheckedContinuation<Void, Never>?

    func account() -> PersonalArchiveAccount { current }
    func isCurrent(_ account: PersonalArchiveAccount) -> Bool { current == account }
    func switchAccount(_ name: String) {
        current = PersonalArchiveAccount(key: PersonalArchiveFiles.digest(Data(name.utf8)), generation: current.generation + 1)
    }
    func failNext(_ value: Failure) { failure = value }
    func afterCommit(_ hook: @escaping @Sendable () throws -> Void) { commitHook = hook }
    func prepareZone(for account: PersonalArchiveAccount, allowCreation: Bool, expectedGeneration: UUID?) throws -> UUID {
        guard isCurrent(account) else { throw PersonalArchiveError.accountChanged }
        if case .beforePreparation = failure { failure = .none; throw PersonalArchiveError.networkUnavailable }
        if zones[account.key] == nil {
            guard allowCreation, expectedGeneration == nil else { throw PersonalArchiveError.zoneMissing }
            zones[account.key] = Zone(generation: nil); creations += 1
        }
        if case .duringPreparation = failure { failure = .none; throw PersonalArchiveError.networkUnavailable }
        if zones[account.key]?.generation == nil, allowCreation, expectedGeneration == nil {
            zones[account.key]?.generation = UUID()
        }
        let generation = try checkedGeneration(account, expected: expectedGeneration)
        if case .afterPreparation = failure { failure = .none; throw PersonalArchiveError.networkUnavailable }
        return generation
    }
    func upload(_ payload: PersonalArchivePayload, jpegData: Data?, account: PersonalArchiveAccount, generation: UUID) async throws {
        try await commit(payload, jpegData: jpegData, precondition: .create, account: account, generation: generation)
    }
    func commit(_ payload: PersonalArchivePayload, jpegData: Data?, precondition: PersonalArchivePrecondition,
                account: PersonalArchiveAccount, generation: UUID) async throws {
        _ = try checkedGeneration(account, expected: generation)
        uploadCount += 1
        let mode = failure; failure = .none
        if case .beforeCommit = mode { throw PersonalArchiveError.networkUnavailable }
        if let existing = zones[account.key]?.entries[payload.id] {
            if existing.payload.isDeleted && payload.isDeleted { return }
            guard existing.payload.fingerprint == payload.fingerprint
                    || (!existing.payload.isDeleted && precondition.expectedRevisions.contains(existing.payload.fingerprint)) else { throw PersonalArchiveError.conflict }
            let retained = existing.payload.jpegSHA256 == payload.jpegSHA256 ? existing.jpegData : nil
            zones[account.key]?.entries[payload.id] = PersonalArchiveRemoteRecord(payload: payload,
                jpegData: payload.jpegSHA256 == nil ? nil : (jpegData ?? retained))
        } else {
            guard precondition.allowsCreation else { throw PersonalArchiveError.conflict }
            zones[account.key]?.entries[payload.id] = PersonalArchiveRemoteRecord(payload: payload, jpegData: jpegData)
        }
        if pauseCommit {
            pauseCommit = false
            await withCheckedContinuation { continuation in
                pausedCommit = continuation; commitStarted?.resume(); commitStarted = nil
            }
        }
        if let hook = commitHook { commitHook = nil; try hook() }
        if case .afterCommit = mode { throw PersonalArchiveError.networkUnavailable }
    }
    func fetch(account: PersonalArchiveAccount, expectedGeneration: UUID?) async throws -> PersonalArchiveRemoteSnapshot {
        let generation = try checkedGeneration(account, expected: expectedGeneration)
        let snapshot = PersonalArchiveRemoteSnapshot(generation: generation,
            records: Array(zones[account.key]!.entries.values), deletedIDs: [])
        if pauseFetch {
            pauseFetch = false
            await withCheckedContinuation { continuation in
                paused = continuation; started?.resume(); started = nil
            }
        }
        return snapshot // Intentionally allows a stale response; the store must reject it.
    }
    func suspendNextFetch() { pauseFetch = true }
    func waitForPausedFetch() async {
        if paused != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func resumeFetch() { paused?.resume(); paused = nil }
    func suspendNextCommit() { pauseCommit = true }
    func waitForPausedCommit() async {
        if pausedCommit != nil { return }
        await withCheckedContinuation { commitStarted = $0 }
    }
    func resumeCommit() { pausedCommit?.resume(); pausedCommit = nil }
    func replaceZone(withMarker: Bool = true) {
        zones[current.key] = Zone(generation: withMarker ? UUID() : nil)
    }
    func damageImage(_ id: UUID) {
        if let old = zones[current.key]?.entries[id] {
            zones[current.key]?.entries[id] = PersonalArchiveRemoteRecord(payload: old.payload, jpegData: Data([0]))
        }
    }
    func count() -> Int { zones[current.key]?.entries.values.filter { !$0.payload.isDeleted }.count ?? 0 }
    func payload(_ id: UUID) -> PersonalArchivePayload? { zones[current.key]?.entries[id]?.payload }
    func counts() -> (uploads: Int, creations: Int) { (uploadCount, creations) }
    private func checkedGeneration(_ account: PersonalArchiveAccount, expected: UUID?) throws -> UUID {
        guard isCurrent(account) else { throw PersonalArchiveError.accountChanged }
        guard let zone = zones[account.key] else { throw PersonalArchiveError.zoneMissing }
        guard let value = zone.generation else { throw PersonalArchiveError.archiveChanged }
        guard expected == nil || value == expected else { throw PersonalArchiveError.archiveChanged }
        return value
    }
}

@main
enum PersonalArchiveVerifier {
    // Synthetic JPEG-framed fixture; the UI's actual image encoding is tested separately.
    private static let jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 0xff, 0xd9])
    private static let date = Date(timeIntervalSince1970: 1_700_000_000)
    private struct Failure: Error { let message: String }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    private static func expect(_ expected: PersonalArchiveError, _ action: () async throws -> Void) async throws {
        do { try await action(); throw Failure(message: "Expected a protected boundary to reject the operation") }
        catch let error as PersonalArchiveError { try require(error == expected, "Wrong safe error category") }
    }
    private static func save(_ store: PersonalArchiveStore, id: UUID = UUID(), text: String = "窓辺で昼寝", photo: Data? = jpeg) async throws -> PersonalArchiveRecord {
        let account = try await store.accountContext()
        return try await store.save(id: id, jpegData: photo, text: text, capturedAt: date, expectedAccount: account)
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("personal-archive-verify-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try configurationBoundary()
        try await roundTrip(root.appendingPathComponent("roundtrip"))
        try await inputBoundaries(root.appendingPathComponent("input"))
        try await stableRetry(root.appendingPathComponent("retry"))
        try await accountIsolation(root.appendingPathComponent("accounts"))
        try await partialImages(root.appendingPathComponent("partial"))
        try await zoneGeneration(root.appendingPathComponent("generation"))
        try await localFailure(root.appendingPathComponent("failure"))
        try await sourcePreservation(root.appendingPathComponent("source"))
        try await mutations(root.appendingPathComponent("mutations"))
        try await staleResponses(root.appendingPathComponent("stale"))
        print("Personal archive verifier passed: 11 boundary groups; no CloudKit network or account access")
    }

    private static func configurationBoundary() throws {
        let identifier = "iCloud.example.personal"
        let configured: [String: Any] = [
            "PersonalArchiveEnabled": "YES", "PersonalArchiveContainerIdentifier": identifier
        ]
        try require(PersonalArchiveCloudConfiguration.containerIdentifier(in: configured) == identifier,
                    "Explicit pilot configuration was rejected")
        let invalidFlags: [Any] = ["NO", "", "yes", "true", "1", " YES", "YES ",
                                  "$(PERSONAL_ARCHIVE_ENABLED)", true, false, 1, 0, NSNull()]
        for flag in invalidFlags {
            var info = configured; info["PersonalArchiveEnabled"] = flag
            try require(PersonalArchiveCloudConfiguration.containerIdentifier(in: info) == nil,
                        "Implicit or malformed pilot flag enabled CloudKit")
        }
        try require(PersonalArchiveCloudConfiguration.containerIdentifier(in: [
            "PersonalArchiveContainerIdentifier": identifier
        ]) == nil, "Container alone enabled CloudKit")
        for value in ["", " ", "$(PERSONAL_ARCHIVE_CONTAINER_IDENTIFIER)"] {
            var info = configured; info["PersonalArchiveContainerIdentifier"] = value
            try require(PersonalArchiveCloudConfiguration.containerIdentifier(in: info) == nil,
                        "Missing or unresolved container enabled CloudKit")
        }
        try require(PersonalArchiveCloudConfiguration.containerIdentifier(in: [
            "PersonalArchiveEnabled": "YES"
        ]) == nil, "Pilot flag without a container enabled CloudKit")
    }

    private static func roundTrip(_ root: URL) async throws {
        let cloud = ArchiveCloudFixture(), first = PersonalArchiveStore(directory: root.appendingPathComponent("first"), transport: cloud)
        let original = try await save(first)
        try require(original.state == .stored, "Save acknowledged before upload completion")
        let onlyText = try await save(first, text: "言葉だけ", photo: nil)
        let onlyPhoto = try await save(first, text: "")
        let blank = PersonalArchiveStore(directory: root.appendingPathComponent("blank"), transport: cloud)
        try require(try await blank.records().isEmpty, "New client was not empty")
        let restored = try await blank.refresh()
        try require(restored.count == 3 && restored.first(where: { $0.id == original.id }) == original, "Blank client did not restore the stable ID, words and bytes")
        try require(restored.first(where: { $0.id == onlyText.id })?.jpegData == nil, "Text-only record invented a photo")
        try require(restored.first(where: { $0.id == onlyPhoto.id })?.text == "", "Photo-only record invented words")
        let reopened = PersonalArchiveStore(directory: root.appendingPathComponent("blank"), transport: cloud)
        try require(try await reopened.records() == restored, "Local JSON restart lost recovered data")
        let account = await cloud.account()
        let folder = root.appendingPathComponent("blank").appendingPathComponent(account.key)
        try require(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == false, "Private memories were excluded from OS backup")
    }

    private static func inputBoundaries(_ root: URL) async throws {
        let disabled = PersonalArchiveStore(directory: root, transport: nil)
        try await expect(.notConfigured) { _ = try await disabled.records() }
        let cloud = ArchiveCloudFixture(), store = PersonalArchiveStore(directory: root, transport: cloud)
        let account = try await store.accountContext()
        try await expect(.emptyRecord) { _ = try await store.save(id: UUID(), jpegData: nil, text: " \n", capturedAt: nil, expectedAccount: account) }
        try await expect(.invalidJPEG) { _ = try await save(store, photo: Data([1, 2, 3])) }
        try await expect(.textTooLong) { _ = try await save(store, text: String(repeating: "猫", count: 501), photo: nil) }
        for interval in [Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, .infinity] {
            try await expect(.corruptedState) {
                _ = try await store.save(id: UUID(), jpegData: nil, text: "言葉", capturedAt: Date(timeIntervalSince1970: interval), expectedAccount: account)
            }
            let invalid = PersonalArchivePayload(id: UUID(), text: "言葉", createdAt: Date(timeIntervalSince1970: interval), capturedAt: nil, jpegSHA256: nil, jpegByteCount: 0)
            try await expect(.corruptedState) { try invalid.validate() }
            _ = invalid.fingerprint // No numeric conversion trap, even before validation.
        }
        try require(await cloud.count() == 0, "Invalid input reached the remote archive")
        let boundary = try await save(store, text: String(repeating: "👨‍👩‍👧‍👦", count: 500), photo: nil)
        try require(boundary.text.count == 500 && boundary.state == .stored, "Valid grapheme boundary was rejected")
    }

    private static func stableRetry(_ root: URL) async throws {
        for (index, mode) in [ArchiveCloudFixture.Failure.beforeCommit, .afterCommit, .beforePreparation, .duringPreparation, .afterPreparation].enumerated() {
            let cloud = ArchiveCloudFixture(), directory = root.appendingPathComponent(String(index))
            let store = PersonalArchiveStore(directory: directory, transport: cloud), id = UUID()
            await cloud.failNext(mode)
            let pending = try await save(store, id: id)
            try require(pending.state == .pending && pending.jpegData == jpeg, "Failed upload discarded pending bytes")
            try await expect(.conflict) { _ = try await save(store, id: id, text: "別の入力") }
            let reopened = PersonalArchiveStore(directory: directory, transport: cloud)
            try await reopened.retryPending()
            let retried = try await save(reopened, id: id)
            try require(retried.id == pending.id && retried.createdAt == pending.createdAt && retried.state == .stored, "Retry replaced the draft identity or original date")
            try require(await cloud.count() == 1, "Ambiguous upload created duplicate records")
        }
    }

    private static func accountIsolation(_ root: URL) async throws {
        let cloud = ArchiveCloudFixture(), store = PersonalArchiveStore(directory: root, transport: cloud)
        _ = try await save(store)
        await cloud.failNext(.beforeCommit)
        let pending = try await save(store, text: "Aの未送信")
        let oldContext = try await store.accountContext()
        await cloud.suspendNextFetch()
        let response = Task { try await store.refresh() }
        await cloud.waitForPausedFetch(); await cloud.switchAccount("fixture-b"); await cloud.resumeFetch()
        try await expect(.accountChanged) { _ = try await response.value }
        try require(try await store.records().isEmpty, "Previous account's cache or pending entries leaked")
        try await expect(.accountChanged) {
            _ = try await store.save(id: UUID(), jpegData: jpeg, text: "旧画面の入力", capturedAt: date, expectedAccount: oldContext)
        }
        try await store.retryPending()
        try require(await cloud.count() == 0, "Previous account's draft uploaded to a new account")
        await cloud.switchAccount("fixture-a")
        let restored = try await store.records()
        try require(restored.first(where: { $0.id == pending.id })?.state == .pending, "Account switch discarded the isolated draft")
        try await expect(.accountChanged) { _ = try await store.save(id: UUID(), jpegData: nil, text: "旧世代", capturedAt: nil, expectedAccount: oldContext) }
    }

    private static func partialImages(_ root: URL) async throws {
        let cloud = ArchiveCloudFixture(), first = PersonalArchiveStore(directory: root.appendingPathComponent("first"), transport: cloud)
        let damaged = try await save(first), healthy = try await save(first, text: "別の健全な記録")
        await cloud.damageImage(damaged.id)
        let blank = PersonalArchiveStore(directory: root.appendingPathComponent("blank"), transport: cloud)
        let fresh = try await blank.refresh(), retained = try await first.refresh()
        try require(fresh.first(where: { $0.id == damaged.id })?.text == damaged.text, "Missing photo withheld its words")
        try require(fresh.first(where: { $0.id == damaged.id })?.state == .partial && fresh.first(where: { $0.id == damaged.id })?.jpegData == nil, "Damaged bytes counted as recovered")
        try require(fresh.first(where: { $0.id == healthy.id })?.jpegData == jpeg, "Damaged photo blocked a healthy record")
        try require(retained.first(where: { $0.id == damaged.id })?.jpegData == jpeg && retained.first(where: { $0.id == damaged.id })?.state == .partial, "Partial fetch discarded a verified local image or claimed remote completion")
    }

    private static func zoneGeneration(_ root: URL) async throws {
        let cloud = ArchiveCloudFixture(), source = root.appendingPathComponent("source")
        let old = PersonalArchiveStore(directory: source, transport: cloud)
        try await expect(.zoneMissing) { _ = try await old.refresh() }
        try require(await cloud.counts().creations == 0, "Fetch silently created a zone")
        await cloud.failNext(.beforeCommit)
        let pending = try await save(old)
        let snapshot = root.appendingPathComponent("snapshot")
        try FileManager.default.copyItem(at: source, to: snapshot)
        await cloud.replaceZone()
        let reopened = PersonalArchiveStore(directory: snapshot, transport: cloud)
        try await expect(.archiveChanged) { try await reopened.retryPending() }
        try await expect(.archiveChanged) { _ = try await reopened.refresh() }
        try require(await cloud.count() == 0, "Old snapshot republished into a replacement zone")
        try require(try await reopened.records().first?.id == pending.id, "Generation rejection erased the old pending record")
        let blank = PersonalArchiveStore(directory: root.appendingPathComponent("blank"), transport: cloud)
        try require(try await blank.refresh().isEmpty, "Fresh client could not bind to the current marker")
        _ = try await save(blank, text: "新しい保管先")
        try require(await cloud.count() == 1, "New explicit save failed in the current generation")
        await cloud.replaceZone(withMarker: false)
        try await expect(.archiveChanged) { _ = try await blank.refresh() }
        let noMarker = PersonalArchiveStore(directory: root.appendingPathComponent("missing-marker"), transport: cloud)
        let held = try await save(noMarker)
        try require(held.state == .stored, "Never-bound explicit enrollment could not finish marker initialization")
        try await expect(.archiveChanged) { try await reopened.retryPending() }
    }

    private static func localFailure(_ root: URL) async throws {
        let cloud = ArchiveCloudFixture(), store = PersonalArchiveStore(directory: root, transport: cloud)
        let account = await cloud.account(), id = UUID()
        let folder = root.appendingPathComponent(account.key), file = folder.appendingPathComponent("state.json")
        let preserved = folder.appendingPathComponent("preserved.json")
        await cloud.afterCommit {
            try FileManager.default.moveItem(at: file, to: preserved)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        }
        try await expect(.storageUnavailable) { _ = try await save(store, id: id) }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: preserved, to: file)
        let acknowledged = try await save(store, id: id)
        let remoteCount = await cloud.count()
        try require(acknowledged.state == .stored && remoteCount == 1, "Local acknowledgement failure duplicated an already committed upload")
        let invalid = Data("not a catalog".utf8)
        try invalid.write(to: file)
        try await expect(.corruptedState) { _ = try await store.records() }
        try await expect(.corruptedState) { _ = try await save(store) }
        try require(try Data(contentsOf: file) == invalid, "Corrupted catalog was overwritten")
    }

    private static func sourcePreservation(_ root: URL) async throws {
        let legacyJSON = Data(#"{"id":"00000000-0000-0000-0000-000000000001","text":"legacy","createdAt":721692800,"jpegByteCount":0}"#.utf8)
        let legacy = try JSONDecoder().decode(PersonalArchivePayload.self, from: legacyJSON)
        try require(legacy.context == nil && legacy.changeID == nil && !legacy.isDeleted
            && legacy.fingerprint == "8ce0043d15796e2f086ea8fedb952e98e5a25e7b2121bb164eba36f2cfa9adb0", "Legacy payload identity changed")

        let cloud = ArchiveCloudFixture(), folder = root.appendingPathComponent("first")
        let first = PersonalArchiveStore(directory: folder, transport: cloud)
        let source = PersonalArchiveSourceSnapshot(noteID: UUID(), revision: "private-note-revision", photoIdentifier: "private-photokit-id")
        let context = PersonalArchiveContext(writtenAt: date, updatedAt: date.addingTimeInterval(3), catNames: ["ミケ", "ソラ"])
        let account = try await first.accountContext()
        await cloud.failNext(.afterCommit)
        let pending = try await first.preserve(source: source, jpegData: jpeg, text: "はじめてのおふろ",
            capturedAt: date, context: context, expectedAccount: account)
        try require(pending.state == .pending, "Lost response counted as acknowledged preservation")
        let reopened = PersonalArchiveStore(directory: folder, transport: cloud)
        let saved = try await reopened.preserve(source: source, jpegData: jpeg, text: "はじめてのおふろ",
            capturedAt: date, context: context, expectedAccount: account)
        try require(saved.id == pending.id && saved.state == .stored && saved.context == context, "Source retry lost identity or context")
        try require(await cloud.count() == 1, "Source retry duplicated the archive")
        try require(try await reopened.preservationStatus(source: source, jpegData: jpeg, expectedAccount: account) == .stored, "Preserved source was not recognized")
        guard let payload = await cloud.payload(saved.id) else { throw Failure(message: "Missing fixture payload") }
        let encoded = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        try require(!encoded.contains(source.noteID.uuidString) && !encoded.contains(source.revision)
            && !encoded.contains(source.photoIdentifier!), "Local source identity entered the cloud payload")
        let changed = PersonalArchiveSourceSnapshot(noteID: source.noteID, revision: "next-private-revision", photoIdentifier: source.photoIdentifier)
        try require(try await reopened.preservationStatus(source: changed, expectedAccount: account) == .changed, "Local edit was mistaken for preserved content")
        let edited = try await reopened.preserve(source: changed, jpegData: jpeg, text: "おふろのあと",
            capturedAt: date, context: context, expectedAccount: account)
        try require(edited.id == saved.id && edited.revision != saved.revision, "Explicit preservation created a second source record")
        let blank = PersonalArchiveStore(directory: root.appendingPathComponent("blank"), transport: cloud)
        let restored = try await blank.refresh()
        try require(restored.count == 1 && restored[0].context == context && restored[0].text == edited.text
            && restored[0].jpegData == jpeg, "Blank restore lost words, context or bytes")
        _ = try await reopened.delete(id: edited.id, operationID: UUID(), expectedRevision: edited.revision, expectedAccount: account)
        try require(try await reopened.preservationStatus(source: changed, expectedAccount: account) == .deleted, "Deleted source lost its local link")
        try await expect(.conflict) {
            _ = try await reopened.preserve(source: changed, jpegData: jpeg, text: edited.text, capturedAt: date, context: context, expectedAccount: account)
        }
        let recreated = try await reopened.preserve(source: changed, jpegData: jpeg, text: edited.text,
            capturedAt: date, context: context, expectedAccount: account, recreateDeleted: true)
        try require(recreated.id != edited.id && recreated.state == .stored, "Explicit new preservation reused a tombstoned ID")
        await cloud.switchAccount("fixture-b")
        let otherAccount = try await reopened.accountContext()
        try require(try await reopened.preservationStatus(source: changed, expectedAccount: otherAccount) == .localOnly, "Source linkage crossed accounts")
    }

    private static func mutations(_ root: URL) async throws {
        let cloud = ArchiveCloudFixture(), folder = root.appendingPathComponent("first")
        let first = PersonalArchiveStore(directory: folder, transport: cloud)
        let original = try await save(first)
        guard let originalPayload = await cloud.payload(original.id) else { throw Failure(message: "Missing original payload") }
        let other = PersonalArchiveStore(directory: root.appendingPathComponent("other"), transport: cloud)
        _ = try await other.refresh()
        let account = try await first.accountContext(), operation = UUID()
        await cloud.failNext(.afterCommit)
        let pending = try await first.update(id: original.id, operationID: operation, expectedRevision: original.revision,
            text: "更新した言葉", capturedAt: original.capturedAt, context: original.context, expectedAccount: account)
        try require(pending.state == .pending, "Update response loss discarded the pending operation")
        let reopened = PersonalArchiveStore(directory: folder, transport: cloud)
        let edited = try await reopened.update(id: original.id, operationID: operation, expectedRevision: original.revision,
            text: "更新した言葉", capturedAt: original.capturedAt, context: original.context, expectedAccount: account)
        try require(edited.state == .stored && edited.id == original.id && edited.jpegData == jpeg, "Update retry changed identity or photo")
        try await expect(.conflict) {
            _ = try await reopened.update(id: original.id, operationID: operation, expectedRevision: original.revision,
                text: "同じ操作IDの別内容", capturedAt: original.capturedAt, context: nil, expectedAccount: account)
        }
        let conflict = try await other.update(id: original.id, operationID: UUID(), expectedRevision: original.revision,
            text: "別端末の未保存の言葉", capturedAt: original.capturedAt, context: nil, expectedAccount: account)
        try require(conflict.state == .conflict && conflict.text == "別端末の未保存の言葉", "Conflict silently discarded the local edit")
        let conflicted = try await other.refresh()
        try require(conflicted.first?.conflictingText == edited.text && conflicted.first?.text == conflict.text, "Conflict failed to retain both versions")

        let deletion = UUID()
        await cloud.failNext(.beforeCommit)
        try require(try await reopened.delete(id: edited.id, operationID: deletion, expectedRevision: edited.revision,
            expectedAccount: account) == .pending, "Offline delete was reported complete")
        let waiting = try await reopened.records()
        try require(waiting.first?.text == edited.text && waiting.first?.isDeletionPending == true, "Pending delete discarded the local words")
        let retry = PersonalArchiveStore(directory: folder, transport: cloud)
        try await retry.retryPending()
        try require(try await retry.records().isEmpty, "Acknowledged deletion remained visible")
        guard let tombstone = await cloud.payload(edited.id) else { throw Failure(message: "Deletion lost its revival guard") }
        try require(tombstone.isDeleted && tombstone.text.isEmpty && tombstone.context == nil
            && tombstone.capturedAt == nil && tombstone.jpegSHA256 == nil, "Deletion retained private payload content")
        let active = await cloud.account()
        let generation = try await cloud.prepareZone(for: active, allowCreation: false, expectedGeneration: nil)
        try await expect(.conflict) { try await cloud.upload(originalPayload, jpegData: jpeg, account: active, generation: generation) }
        try require(await cloud.count() == 0, "Old client's creation revived a deleted record")
        let blank = PersonalArchiveStore(directory: root.appendingPathComponent("deleted-restore"), transport: cloud)
        try require(try await blank.refresh().isEmpty, "Blank restore exposed deleted words or photo")
    }

    private static func staleResponses(_ root: URL) async throws {
        let cloud = ArchiveCloudFixture(), store = PersonalArchiveStore(directory: root, transport: cloud)
        let original = try await save(store), account = try await store.accountContext()
        await cloud.suspendNextFetch()
        let fetch = Task { try await store.refresh() }
        await cloud.waitForPausedFetch()
        let edited = try await store.update(id: original.id, operationID: UUID(), expectedRevision: original.revision,
            text: "取得開始より新しい内容", capturedAt: original.capturedAt, context: nil, expectedAccount: account)
        await cloud.resumeFetch()
        try require(try await fetch.value.first?.text == edited.text, "Stale refresh replaced a newer committed edit")

        await cloud.suspendNextCommit()
        let update = Task { try await store.update(id: original.id, operationID: UUID(), expectedRevision: edited.revision,
            text: "送信の応答待ち", capturedAt: original.capturedAt, context: nil, expectedAccount: account) }
        await cloud.waitForPausedCommit()
        guard let inFlight = try await store.records().first else { throw Failure(message: "Missing in-flight draft") }
        await cloud.failNext(.beforeCommit)
        _ = try await store.delete(id: inFlight.id, operationID: UUID(), expectedRevision: inFlight.revision, expectedAccount: account)
        await cloud.resumeCommit()
        _ = try await update.value
        let afterOldReply = try await store.records()
        try require(afterOldReply.first?.state == .pending && afterOldReply.first?.isDeletionPending == true,
            "Old update acknowledgement incorrectly completed a newer deletion")
        try await store.retryPending()
        try require(try await store.records().isEmpty, "Pending deletion did not survive the old response")
    }
}
