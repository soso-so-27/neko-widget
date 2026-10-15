import Foundation
import Combine
import SwiftUI
import AuthenticationServices
import ImageIO
import UIKit

extension Notification.Name {
    static let appRecordsCommitted = Notification.Name("neko.app-records.committed.v1")
    static let appRecordDatasetChanged = Notification.Name("neko.app-records.dataset.v1")
    static let appRecordEditingFinished = Notification.Name("neko.app-records.editing-finished.v1")
}

enum AppRecordEditingError: Error { case inProgress }

/// These leases outlive hidden editors and nested presentations. They protect
/// memory-only drafts, which a fingerprint of committed files cannot detect.
final class AppRecordEditingLease: ObservableObject, @unchecked Sendable {
    private let id = UUID()
    private static var editors = Set<UUID>()
    func acquire() {
        AppRecordDataset.writeLock.lock(); defer { AppRecordDataset.writeLock.unlock() }
        Self.editors.insert(id)
    }
    func release() {
        AppRecordDataset.writeLock.lock()
        let finished = Self.editors.remove(id) != nil && Self.editors.isEmpty
        AppRecordDataset.writeLock.unlock()
        if finished { NotificationCenter.default.post(name: .appRecordEditingFinished, object: nil) }
    }
    static func requireIdle() throws {
        AppRecordDataset.writeLock.lock(); defer { AppRecordDataset.writeLock.unlock() }
        guard editors.isEmpty else { throw AppRecordEditingError.inProgress }
    }
    deinit { release() }
}

private struct AppRecordEditingModifier: ViewModifier {
    @StateObject private var lease = AppRecordEditingLease()
    @State private var visible = false
    let retainWhileHidden: Bool
    func body(content: Content) -> some View {
        content
            .onAppear { visible = true; lease.acquire() }
            .onDisappear { visible = false; if !retainWhileHidden { lease.release() } }
            .onChange(of: retainWhileHidden) { _, retain in
                if !visible { if retain { lease.acquire() } else { lease.release() } }
            }
    }
}

extension View {
    func appRecordEditing(retainWhileHidden: Bool) -> some View {
        modifier(AppRecordEditingModifier(retainWhileHidden: retainWhileHidden))
    }
}

/// One pointer publishes a fully validated dataset. Prior roots are retained;
/// a stale screen cannot write into the dataset that has just been replaced.
enum AppRecordDataset {
    // Shared by every live store commit and final dataset publication. An
    // actor's executor alone does not serialize the other persistence actors.
    static let writeLock = NSRecursiveLock()
    struct Pointer: Codable, Equatable, Sendable {
        let version: Int
        let datasetID: UUID
        let owner: String
        let origin: String
        var manifests: [String]? = nil
    }
    #if DEBUG
    private static var fixtureSupport: URL? = CommandLine.arguments.contains("--app-records-ui-fixture")
        ? FileManager.default.temporaryDirectory.appendingPathComponent("app-records-fixture-" + UUID().uuidString, isDirectory: true) : nil
    @MainActor static func nextFixtureDevice() throws {
        guard fixtureSupport != nil else { throw ToolBackupError.invalid }
        fixtureSupport = FileManager.default.temporaryDirectory.appendingPathComponent("app-records-fixture-" + UUID().uuidString, isDirectory: true)
    }
    #endif
    static var support: URL {
#if DEBUG
        if let fixtureSupport { return fixtureSupport }
#endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    static var control: URL { support.appendingPathComponent("AppRecordPersistence", isDirectory: true) }
    static var datasets: URL { support.appendingPathComponent("AppRecordDatasets", isDirectory: true) }
    private static var pointerURL: URL { control.appendingPathComponent("active.json") }
    static func pointer() throws -> Pointer? {
        guard FileManager.default.fileExists(atPath: pointerURL.path) else { return nil }
        let value = try JSONDecoder().decode(Pointer.self, from: ToolBackupFiles.read(pointerURL, maximum: 4096))
        guard value.version == 1, !value.owner.isEmpty,
              URL(string: value.origin)?.scheme == "https" else { throw ToolBackupError.invalid }
        return value
    }
    static func root() throws -> URL {
        guard let pointer = try pointer() else { return support }
        let root = datasets.appendingPathComponent(pointer.datasetID.uuidString, isDirectory: true)
        let receipt = try JSONDecoder().decode(Pointer.self, from: ToolBackupFiles.read(root.appendingPathComponent("dataset.json"), maximum: 4096))
        guard receipt == pointer else { throw ToolBackupError.invalid }
        for path in receipt.manifests ?? [] {
            guard knownManifestPaths.contains(path), FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) else { throw ToolBackupError.invalid }
        }
        return root
    }
    static var knownManifestPaths: Set<String> {
        Set(ToolBackupIndex.manifests.map { $0.key + "/" + $0.value })
    }
    static func liveIdentityPolicy(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        return parent.hasPrefix(datasets.standardizedFileURL.path + "/")
            || parent == support.appendingPathComponent("CatIdentity").standardizedFileURL.path
    }
    static func requirePreviouslyPresentManifest(_ path: String, at url: URL) throws {
        // Bind additions since publication to this exact dataset. An old
        // binding must never impose its previous inventory on a new root.
        _ = try root()
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let binding = control.appendingPathComponent("binding.json")
        guard FileManager.default.fileExists(atPath: binding.path) else { return }
        let object = try JSONSerialization.jsonObject(with: ToolBackupFiles.read(binding, maximum: 8192)) as? [String: Any]
        let storedID = (object?["requiredDatasetID"] as? String).flatMap(UUID.init(uuidString:))
        guard storedID == (try pointer()?.datasetID) else { return }
        if (object?["requiredManifests"] as? [String] ?? []).contains(path) { throw ToolBackupError.invalid }
    }
    static func presentManifestPaths() throws -> [String] {
        try ToolBackupIndex.manifests.compactMap { tool, manifest in
            let url = tool == "CatIdentity" ? identityURL() : directory(tool).appendingPathComponent(manifest)
            guard let url else { throw ToolBackupError.invalid }
            return FileManager.default.fileExists(atPath: url.path) ? tool + "/" + manifest : nil
        }.sorted()
    }
    /// A corrupt pointer must not silently fall back to a fresh empty dataset.
    static func directory(_ name: String) -> URL {
        do { return try root().appendingPathComponent(name, isDirectory: true) }
        catch { return control.appendingPathComponent("unavailable/" + name, isDirectory: true) }
    }
    static func identityURL() -> URL? {
        do {
#if DEBUG
            if fixtureSupport != nil { return try root().appendingPathComponent("CatIdentity/state.json") }
#endif
            if try pointer() != nil { return try root().appendingPathComponent("CatIdentity/state.json") }
            return SharedContainer.containerURL?.appendingPathComponent(CatHouseholdIdentityStore.filename)
        } catch { return control.appendingPathComponent("unavailable/CatIdentity/state.json") }
    }
    static func requireWritable(_ url: URL) throws {
        let root = try root().standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        let legacy = support.standardizedFileURL.path + "/"
        let managed = ToolBackupIndex.manifests.keys.contains { path.hasPrefix(legacy + $0 + "/") }
            || path.hasPrefix(datasets.path + "/")
            || path.hasPrefix(control.appendingPathComponent("unavailable").path + "/")
        if managed && !path.hasPrefix(root) { throw ToolBackupError.changed }
        if url.lastPathComponent == CatHouseholdIdentityStore.filename,
           let active = try pointer(), active.version == 1 { throw ToolBackupError.changed }
    }
    static func requireScope(owner: String, origin: String) throws {
        if let pointer = try pointer() {
            guard pointer.owner == owner, pointer.origin == origin else { throw ManagedPreservationError.staleSession }
        }
        let claim = control.appendingPathComponent("owner.json")
        if FileManager.default.fileExists(atPath: claim.path) {
            let receipt = try JSONDecoder().decode(Pointer.self, from: ToolBackupFiles.read(claim, maximum: 4096))
            guard receipt.owner == owner, receipt.origin == origin else { throw ManagedPreservationError.staleSession }
        }
    }
    static func claim(owner: String, origin: String) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        try requireScope(owner: owner, origin: origin)
        let url = control.appendingPathComponent("owner.json")
        if !FileManager.default.fileExists(atPath: url.path) {
            try writeBackedUp(JSONEncoder().encode(Pointer(version: 1, datasetID: UUID(), owner: owner, origin: origin)), to: url)
        }
    }
    /// Live records and their owner/pointer remain eligible for the owner's OS
    /// backup. Private transfer staging uses ToolBackupFiles.protect instead.
    static func writeBackedUp(_ bytes: Data, to url: URL) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        try requireWritable(url)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: parent.path)
        var directory = parent; var values = URLResourceValues(); values.isExcludedFromBackup = false
        try directory.setResourceValues(values)
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
    }
    static func committed(_ url: URL) {
        NotificationCenter.default.post(name: .appRecordsCommitted, object: url)
    }
    static func fingerprint() throws -> String {
        writeLock.lock(); defer { writeLock.unlock() }
        _ = try root()
        var bytes = Data()
        for (tool, manifest) in ToolBackupIndex.manifests.sorted(by: { $0.key < $1.key }) {
            let url = tool == "CatIdentity" ? identityURL() : directory(tool).appendingPathComponent(manifest)
            bytes.append(Data((tool + "/" + manifest + "\n").utf8))
            if let url, FileManager.default.fileExists(atPath: url.path) {
                bytes.append(try ToolBackupFiles.read(url, maximum: 8 * 1024 * 1024))
            } else if let url {
                try requirePreviouslyPresentManifest(tool + "/" + manifest, at: url)
            }
            bytes.append(0)
        }
        return ToolBackupIndex.hash(bytes)
    }
    /// Only missing/valid empty stores count as empty. Unknown schemas and
    /// unreadable manifests never authorize replacing local records.
    static func isEmpty() throws -> Bool {
        _ = try root()
        for (tool, manifest) in ToolBackupIndex.manifests {
            let url = tool == "CatIdentity" ? identityURL() : directory(tool).appendingPathComponent(manifest)
            guard let url else { throw ToolBackupError.invalid }
            guard FileManager.default.fileExists(atPath: url.path) else {
                try requireMissingManifestIsEmpty(tool, at: url)
                continue
            }
            let data = try ToolBackupFiles.read(url, maximum: 8 * 1024 * 1024)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // The legacy Showcase array is recognized, but is not empty.
                throw ToolBackupError.invalid
            }
            switch tool {
            case "CatIdentity":
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let state = try decoder.decode(CatHouseholdIdentityState.self, from: data)
                guard (1...CatHouseholdIdentityState.currentSchemaVersion).contains(state.schemaVersion) else { throw ToolBackupError.invalid }
                if !state.profiles.isEmpty || !state.memberships.isEmpty || !state.globalExcludedAssets.isEmpty { return false }
                if let legacy = state.legacyUnscoped,
                   legacy.lifeReference != nil || legacy.sourceAlbumIdentifier != nil
                    || !(legacy.lastKnownSourceAssetIdentifiers ?? []).isEmpty || !legacy.legacyExcludedAssetIdentifiers.isEmpty { return false }
            case "PhotoMemoryNotes":
                guard let schema = object["schemaVersion"] as? Int, (2...4).contains(schema),
                      let notes = object["notes"] as? [String: Any] else { throw ToolBackupError.invalid }
                if !notes.isEmpty || !(object["archiveBindings"] as? [String: Any] ?? [:]).isEmpty { return false }
            case "CareHandoff", "EvacuationPreparation":
                // Even an empty plan may contain owner-authored contacts or lists.
                return false
            case "VeterinaryVisits":
                guard object["schema"] as? Int == 1, let visits = object["visits"] as? [Any] else { throw ToolBackupError.invalid }
                if !visits.isEmpty || !(object["retiredPhotoFiles"] as? [Any] ?? []).isEmpty { return false }
            case "ShowcasePhotos":
                guard let entries = object["entries"] as? [Any] else { throw ToolBackupError.invalid }
                if !entries.isEmpty || !(object["scopes"] as? [String: Any] ?? [:]).isEmpty { return false }
            default: if !object.isEmpty { return false }
            }
        }
        return true
    }
    static func requireMissingManifestIsEmpty(_ tool: String, at url: URL) throws {
        guard tool != "CatIdentity" else { return }
        let directory = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path),
           try !FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty { throw ToolBackupError.invalid }
    }
    @MainActor static func activate(_ saved: ToolBackupFiles.Saved, origin: String,
                                    expectedFingerprint: String, validateSession: ManagedPreservationClient.LocalSessionFence) async throws {
        try AppRecordEditingLease.requireIdle()
        guard try fingerprint() == expectedFingerprint else { throw ToolBackupError.changed }
        try requireScope(owner: saved.owner, origin: origin)
        let localIdentity: CatHouseholdIdentityState?
        if let url = identityURL(), FileManager.default.fileExists(atPath: url.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            localIdentity = try decoder.decode(CatHouseholdIdentityState.self, from: ToolBackupFiles.read(url, maximum: 8 * 1024 * 1024))
        } else { localIdentity = nil }
        let source = try ToolBackupFiles.restoredSource(saved.id, owner: saved.owner)
        try await ToolBackupValidation.validate(saved.index, at: source)
        let receipt = Pointer(version: 1, datasetID: UUID(), owner: saved.owner, origin: origin,
                              manifests: saved.index.files.map(\.path).filter { knownManifestPaths.contains($0) }.sorted())
        let destination = datasets.appendingPathComponent(receipt.datasetID.uuidString, isDirectory: true)
        try ToolBackupFiles.protect(destination)
        // All referenced bytes are verified before any live store sees this root.
        for file in saved.index.files {
            let data = try ToolBackupFiles.read(source.appendingPathComponent(file.path), maximum: 20 * 1024 * 1024)
            guard ToolBackupIndex.hash(data) == file.sha256 else { throw ToolBackupError.invalid }
            try ToolBackupFiles.write(data, to: destination.appendingPathComponent(file.path))
        }
        let identity = destination.appendingPathComponent("CatIdentity/state.json")
        if FileManager.default.fileExists(atPath: identity.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let remote = try decoder.decode(CatHouseholdIdentityState.self, from: ToolBackupFiles.read(identity, maximum: 8 * 1024 * 1024))
            let merged = try preservingLocalPhotoLinks(remote, local: localIdentity)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
            try ToolBackupFiles.write(encoder.encode(merged), to: identity)
        }
        // Restore creates these folders privately; publish them as live data
        // only after validation, preserving OS backup for future offline edits.
        for tool in Set(saved.index.files.map { String($0.path.split(separator: "/")[0]) }) {
            var directory = destination.appendingPathComponent(tool); var values = URLResourceValues()
            values.isExcludedFromBackup = false; try directory.setResourceValues(values)
        }
        try ToolBackupFiles.write(JSONEncoder().encode(receipt), to: destination.appendingPathComponent("dataset.json"))
        var workingRoot = destination; var backup = URLResourceValues(); backup.isExcludedFromBackup = false
        try workingRoot.setResourceValues(backup)
        try validateSession {
            try publish(receipt, expectedFingerprint: expectedFingerprint)
        }
        NotificationCenter.default.post(name: .appRecordDatasetChanged, object: receipt.datasetID)
    }
    /// PhotoKit relationships are device-local and are never uploaded. A
    /// remote name/date update must not erase this phone's existing curation.
    /// Carry links only by the exact profile UUID; names are not identities.
    static func preservingLocalPhotoLinks(_ remote: CatHouseholdIdentityState,
                                          local: CatHouseholdIdentityState?) throws -> CatHouseholdIdentityState {
        var portable = remote
        for i in portable.profiles.indices {
            portable.profiles[i].keyPhotoLocalIdentifier = nil
            portable.profiles[i].photoAlbumLink = nil
        }
        portable.memberships = []; portable.globalExcludedAssets = []
        portable.legacyUnscoped?.sourceAlbumIdentifier = nil
        portable.legacyUnscoped?.lastKnownSourceAssetIdentifiers = nil
        portable.legacyUnscoped?.legacyExcludedAssetIdentifiers = []
        portable.legacyUnscoped?.importedCurationMutationRevision = -1
        guard let local else { return portable.normalized() }
        guard (1...CatHouseholdIdentityState.currentSchemaVersion).contains(local.schemaVersion),
              Set(local.profiles.map(\.id)).count == local.profiles.count else { throw ToolBackupError.invalid }
        var result = portable
        let profiles = Dictionary(uniqueKeysWithValues: local.profiles.map { ($0.id, $0) })
        let ids = Set(remote.profiles.map(\.id))
        for i in result.profiles.indices {
            guard let own = profiles[result.profiles[i].id] else { continue }
            result.profiles[i].keyPhotoLocalIdentifier = own.keyPhotoLocalIdentifier
            result.profiles[i].photoAlbumLink = own.photoAlbumLink
        }
        result.memberships = local.memberships.filter { ids.contains($0.profileID) }
        result.globalExcludedAssets = local.globalExcludedAssets
        if let own = local.legacyUnscoped {
            if result.legacyUnscoped == nil {
                var photoLinks = own; photoLinks.lifeReference = nil; result.legacyUnscoped = photoLinks
            } else {
                result.legacyUnscoped?.sourceAlbumIdentifier = own.sourceAlbumIdentifier
                result.legacyUnscoped?.lastKnownSourceAssetIdentifiers = own.lastKnownSourceAssetIdentifiers
                result.legacyUnscoped?.legacyExcludedAssetIdentifiers = own.legacyExcludedAssetIdentifiers
                result.legacyUnscoped?.importedCurationMutationRevision = own.importedCurationMutationRevision
            }
        }
        return result.normalized()
    }
    private static func publish(_ receipt: Pointer, expectedFingerprint: String) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        try AppRecordEditingLease.requireIdle()
        guard try fingerprint() == expectedFingerprint else { throw ToolBackupError.changed }
        try requireScope(owner: receipt.owner, origin: receipt.origin)
        // No suspension between the last local fence and pointer publication.
        try writeBackedUp(JSONEncoder().encode(receipt), to: pointerURL)
    }
}

/// A small, ordinary encrypted record is the compare-and-swap head. Only its
/// acknowledged revision publishes a completed immutable snapshot to devices.
struct AppRecordHead: Codable, Equatable, Sendable {
    let kind: String
    let snapshotID: UUID
    let indexHash: String
    var retiring: [UUID]? = nil
    static func id(origin: String, owner: String) -> UUID {
        let hash = ToolBackupIndex.hash(Data(("app-records-v1\n" + origin + "\n" + owner).utf8))
        let value = Array(hash.prefix(32))
        return UUID(uuidString: String(value[0..<8]) + "-" + String(value[8..<12]) + "-" + String(value[12..<16]) + "-" + String(value[16..<20]) + "-" + String(value[20..<32]))!
    }
    static func decode(_ document: ManagedPreservationDocument) throws -> Self {
        guard document.toolBackup == nil, document.photoFile == nil,
              let data = document.text.data(using: .utf8) else { throw ToolBackupError.invalid }
        let head = try JSONDecoder().decode(Self.self, from: data)
        guard head.kind == "app-records-v1", head.indexHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw ToolBackupError.invalid }
        let retiring = head.retiring ?? []
        guard retiring.count <= 6, Set(retiring).count == retiring.count, !retiring.contains(head.snapshotID) else { throw ToolBackupError.invalid }
        return head
    }
}

@MainActor
final class AppRecordPersistence: ObservableObject {
    static let shared = AppRecordPersistence()
    struct Binding: Codable, Equatable, Sendable {
        let version: Int
        let origin: String
        let owner: String
        let consent: String
        var enabled: Bool
        var revision: Int?
        var snapshotID: UUID?
        var fingerprint: String?
        var pending: UUID?
        var pendingFingerprint: String?
        var pendingBase: Int?
        var pendingPrevious: UUID?
        var retiring: [UUID]?
        var requiredManifests: [String]? = nil
        var requiredDatasetID: UUID? = nil
    }
    static let consentVersion = "app-records-automatic-v1"
    @Published private(set) var title = "自動保存は未設定です"
    @Published private(set) var detail: String?
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var conflict = false
    @Published private(set) var datasetGeneration = UUID()
    private let configuration: ManagedPreservationConfiguration
    private let client: ManagedPreservationClient
    private let bindingURL: URL
    private var loop: Task<Void, Never>?
    private var active = false
    private var observer: NSObjectProtocol?
    private var datasetObserver: NSObjectProtocol?
    private var editingObserver: NSObjectProtocol?
    private var requested = true
    private var waitingForEditor = false
    private var nextAttempt = Date.distantPast

    init(configuration: ManagedPreservationConfiguration = .current, client: ManagedPreservationClient? = nil,
         bindingURL: URL = AppRecordDataset.control.appendingPathComponent("binding.json")) {
        self.configuration = configuration
        self.client = client ?? ManagedPreservationClient(configuration: configuration)
        self.bindingURL = bindingURL
        observer = NotificationCenter.default.addObserver(forName: .appRecordsCommitted, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                self?.requested = true
                if let self, self.enabled {
                    // A delayed notification (including a migration during
                    // restore) must not relabel already acknowledged bytes.
                    if let saved = try? self.binding(), let current = try? AppRecordDataset.fingerprint(), saved.fingerprint == current { return }
                    self.title = "変更を保存待ち"
                }
            }
        }
        datasetObserver = NotificationCenter.default.addObserver(forName: .appRecordDatasetChanged, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.datasetGeneration = UUID() }
        }
        editingObserver = NotificationCenter.default.addObserver(forName: .appRecordEditingFinished, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                self?.requested = true
                self?.nextAttempt = .distantPast
            }
        }
        do { enabled = try binding()?.enabled == true }
        catch { detail = "保存設定を読み込めません。端末の記録は残っています。" }
    }
    private func binding() throws -> Binding? {
        guard FileManager.default.fileExists(atPath: bindingURL.path) else { return nil }
        let value = try JSONDecoder().decode(Binding.self, from: ToolBackupFiles.read(bindingURL, maximum: 8192))
        guard value.version == 1, value.consent == Self.consentVersion,
              value.origin == configuration.origin?.absoluteString else { throw ToolBackupError.invalid }
        return value
    }
    private func write(_ value: Binding) throws {
        var secured = value
        let present = try AppRecordDataset.presentManifestPaths()
        // Within one dataset this is monotonic; pausing cannot forget a lost
        // file. A validated root switch starts that new root's own inventory.
        let datasetID = try AppRecordDataset.pointer()?.datasetID
        let existing = try binding()
        guard existing == nil || existing?.owner == value.owner else { throw ManagedPreservationError.staleSession }
        let previous = existing?.requiredDatasetID == datasetID ? existing?.requiredManifests ?? [] : []
        let proposed = value.requiredDatasetID == datasetID ? value.requiredManifests ?? [] : []
        secured.requiredManifests = Array(Set(previous + proposed + present)).sorted()
        secured.requiredDatasetID = datasetID
        try AppRecordDataset.writeBackedUp(JSONEncoder().encode(secured), to: bindingURL)
        enabled = value.enabled
    }
    /// Only disposable transport payloads of an acknowledged automatic upload
    /// are released. Live roots, previous roots, receipts and restored copies
    /// are outside this file list and remain intact.
    private func releaseUploadedPayload(_ id: UUID?, owner: String) {
        guard let id else { return }
        let folder = ToolBackupFiles.directory(id)
        let receipt = folder.appendingPathComponent("uploaded.json")
        guard let bytes = try? ToolBackupFiles.read(receipt, maximum: 512 * 1024),
              let saved = try? JSONDecoder().decode(ToolBackupFiles.Saved.self, from: bytes),
              saved.id == id, saved.owner == owner, saved.index.version == 3,
              (try? saved.index.validate()) != nil else { return }
        for file in saved.index.files {
            let url = folder.appendingPathComponent(file.path)
            if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
        }
    }
    private func collectParts(_ value: Binding,
                              checkpoint: ManagedPreservationClient.SessionCheckpoint) async throws {
        var after: UUID?
        for _ in 0..<4 {
            try await require(value, checkpoint)
            let candidates = try await client.toolCleanupCandidates(after: after, checkpoint: checkpoint)
            if candidates.items.isEmpty && candidates.nextCursor == nil { return }
            for item in candidates.items {
                try await require(value, checkpoint)
                do { try await client.deleteToolCleanupCandidate(item, checkpoint: checkpoint) }
                catch ManagedPreservationError.notFound { }
                catch ManagedPreservationError.toolPartReferenced { continue }
            }
            after = candidates.nextCursor
        }
        requested = true
    }
    func setActive(_ value: Bool) {
        active = value
        if !value { loop?.cancel(); loop = nil; return }
        guard loop == nil, configuration.isEnabled else { return }
        requested = true
        nextAttempt = .distantPast
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.active else { return }
                await self.synchronize()
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
            }
        }
    }
    func enable() async {
        guard !busy, let origin = configuration.origin?.absoluteString else { return }
        do {
            try await client.reloadSessionFromSecureStorage()
            let checkpoint = try await client.captureSessionCheckpoint()
            try AppRecordDataset.requireScope(owner: checkpoint.ownerID, origin: origin)
            try AppRecordDataset.claim(owner: checkpoint.ownerID, origin: origin)
            if let previous = try binding() {
                guard previous.owner == checkpoint.ownerID else { throw ManagedPreservationError.staleSession }
                var value = previous; value.enabled = true; try write(value)
            } else {
                try write(Binding(version: 1, origin: origin, owner: checkpoint.ownerID,
                    consent: Self.consentVersion, enabled: true))
            }
            requested = true; conflict = false; nextAttempt = .distantPast
            await synchronize()
        } catch { report(error) }
    }
    func pause() {
        do {
            guard var value = try binding() else { return }
            value.enabled = false; try write(value)
            title = "自動保存を停止しています"
        } catch { report(error) }
    }
    func retry() async { requested = true; conflict = false; nextAttempt = .distantPast; await synchronize() }
    func resolveConflict(useRemote: Bool) async {
        guard !busy else { return }
        busy = true
        do {
            guard var value = try binding(), value.enabled else { throw ManagedPreservationError.consentRequired }
            try await client.reloadSessionFromSecureStorage()
            let checkpoint = try await client.captureSessionCheckpoint()
            try await require(value, checkpoint)
            let headID = AppRecordHead.id(origin: value.origin, owner: value.owner)
            guard let remote = try await remoteHead(headID) else { throw ManagedPreservationError.conflict }
            let fingerprint = try AppRecordDataset.fingerprint()
            // Retain a complete remote copy even when choosing this device.
            let record = try await index(remote.1)
            let saved = try await ToolBackupTransfer.restore(record, client: client) { _, _ in }
            try await require(value, checkpoint)
            guard try await remoteHead(headID)?.0.revision == remote.0.revision else { throw ManagedPreservationError.conflict }
            if useRemote {
                let fence = try await client.localSessionFence(checkpoint)
                try await AppRecordDataset.activate(saved, origin: value.origin, expectedFingerprint: fingerprint, validateSession: fence)
                value.fingerprint = try AppRecordDataset.fingerprint()
                value.pending = nil; value.pendingFingerprint = nil; value.pendingBase = nil
            } else {
                guard try AppRecordDataset.fingerprint() == fingerprint else { throw ToolBackupError.changed }
                // An earlier immutable snapshot may already have been retired
                // by another device. Rebase through a newly validated ID.
                value.pending = nil; value.pendingFingerprint = nil; value.pendingBase = nil; value.pendingPrevious = nil
                value.fingerprint = nil
            }
            value.revision = remote.0.revision; value.snapshotID = remote.1.snapshotID
            try await require(value, checkpoint); try write(value)
            conflict = false; requested = true; detail = "切替前の記録もこの端末に残しています。"
        } catch { report(error) }
        busy = false
        if !conflict { await synchronize() }
    }
    private func require(_ value: Binding, _ checkpoint: ManagedPreservationClient.SessionCheckpoint) async throws {
        try Task.checkCancellation()
        try await client.requireSessionCheckpoint(checkpoint)
        try AppRecordDataset.requireScope(owner: value.owner, origin: value.origin)
        guard checkpoint.ownerID == value.owner, let current = try binding(),
              current.owner == value.owner, current.origin == value.origin, current.enabled,
              current.consent == value.consent else { throw ManagedPreservationError.staleSession }
    }
    private func remoteHead(_ id: UUID) async throws -> (ManagedPreservationRecord, AppRecordHead)? {
        do {
            let snapshot = try await client.detail(id)
            return (snapshot.record, try AppRecordHead.decode(snapshot.document))
        } catch ManagedPreservationError.notFound { return nil }
    }
    private func index(_ head: AppRecordHead) async throws -> ManagedPreservationRecord {
        let record = try await client.detail(head.snapshotID).record
        guard record.revision == 1, let part = record.document.toolBackup,
              part.kind == "index", part.sha256 == head.indexHash,
              let bytes = Data(base64Encoded: part.payload), ToolBackupIndex.hash(bytes) == head.indexHash,
              try JSONDecoder().decode(ToolBackupIndex.self, from: bytes).version == 3 else { throw ToolBackupError.invalid }
        return record
    }
    private func synchronize() async {
        guard active || requested, !busy, !conflict, Date() >= nextAttempt else { return }
        busy = true
        defer { busy = false }
        var phase = "保存設定を確認"
        do {
            guard var value = try binding(), value.enabled else { title = "自動保存は未設定です"; return }
            try await client.reloadSessionFromSecureStorage()
            let checkpoint = try await client.captureSessionCheckpoint()
            try await require(value, checkpoint)
            let currentFingerprint = try AppRecordDataset.fingerprint()
            if waitingForEditor, currentFingerprint == value.fingerprint {
                // A long editing session must not poll the server every eight
                // seconds merely because a previously seen restore is waiting.
                try AppRecordEditingLease.requireIdle()
                waitingForEditor = false
            }
            releaseUploadedPayload(value.snapshotID, owner: value.owner)
            let headID = AppRecordHead.id(origin: value.origin, owner: value.owner)
            // No network polling for an unchanged dataset. Foreground entry and
            // commits request one check; conflict detection also occurs at CAS.
            guard requested || currentFingerprint != value.fingerprint || value.pending != nil || !(value.retiring ?? []).isEmpty else { return }
            requested = false
            let remote = try await remoteHead(headID)
            try await require(value, checkpoint)
            if let retiring = remote?.1.retiring {
                value.retiring = Array(Set((value.retiring ?? []) + retiring)); try write(value)
            }
            if remote?.0.revision != value.revision {
                if let pending = value.pending, remote?.1.snapshotID == pending {
                    // An acknowledged head whose response was lost is success,
                    // never a second snapshot or a blind overwrite.
                    value.revision = remote?.0.revision; value.snapshotID = pending
                    value.fingerprint = value.pendingFingerprint; value.pending = nil
                    if let previous = value.pendingPrevious { value.retiring = Array(Set((value.retiring ?? []) + [previous])) }
                    value.pendingPrevious = nil
                    value.pendingFingerprint = nil; value.pendingBase = nil; try write(value)
                    releaseUploadedPayload(pending, owner: value.owner)
                } else if let remote, try AppRecordDataset.isEmpty() || value.fingerprint == currentFingerprint {
                    try AppRecordEditingLease.requireIdle()
                    title = "記録を復元しています…"
                    let record = try await index(remote.1)
                    let saved = try await ToolBackupTransfer.restore(record, client: client) { _, _ in }
                    try await require(value, checkpoint)
                    guard try await remoteHead(headID)?.0.revision == remote.0.revision else { throw ManagedPreservationError.conflict }
                    let fence = try await client.localSessionFence(checkpoint)
                    try await AppRecordDataset.activate(saved, origin: value.origin, expectedFingerprint: currentFingerprint, validateSession: fence)
                    value.revision = remote.0.revision; value.snapshotID = saved.id
                    value.fingerprint = try AppRecordDataset.fingerprint(); value.pending = nil
                    value.pendingFingerprint = nil; value.pendingBase = nil; try write(value)
                    title = "復元しました"; detail = "いつもの画面で記録を使えます。"; return
                } else { throw ManagedPreservationError.conflict }
            }
            // Retry only queued, previously accepted automatic snapshots. The
            // server head reference refuses removal of the current snapshot.
            let retained: Set<UUID>
            if !(value.retiring ?? []).isEmpty, let remote {
                let current = try await index(remote.1)
                let decoded = try JSONDecoder().decode(ToolBackupIndex.self, from: Data(base64Encoded: current.document.toolBackup!.payload)!)
                retained = Set(decoded.files.flatMap(\.records))
            } else { retained = [] }
            for retiring in value.retiring ?? [] where retiring != remote?.1.snapshotID {
                do {
                    let pending = try ToolBackupFiles.pendingDeletions(owner: value.owner).first { $0.id == retiring }
                    let old: ToolBackupIndex
                    if let pending { old = pending.index }
                    else {
                        let snapshot = try await client.detail(retiring).record
                        guard let part = snapshot.document.toolBackup, let bytes = Data(base64Encoded: part.payload) else { throw ToolBackupError.invalid }
                        old = try JSONDecoder().decode(ToolBackupIndex.self, from: bytes)
                    }
                    guard old.version == 3 else { throw ToolBackupError.invalid }
                    try await ToolBackupTransfer.delete(old, client: client, retaining: retained) { _, _ in }
                } catch ManagedPreservationError.notFound { }
                try await require(value, checkpoint)
                value.retiring?.removeAll { $0 == retiring }; try write(value)
            }
            try await collectParts(value, checkpoint: checkpoint)
            if value.fingerprint == currentFingerprint, value.pending == nil {
                title = "保存済み"; detail = nil; return
            }
            let membership = try await client.membership()
            try await require(value, checkpoint)
            guard membership.canSave else { throw ManagedPreservationError.membershipRequired }
            let support = try await client.usage().toolSnapshots
            guard (support?.maximumIndexVersion ?? 0) >= 3 else { throw ManagedPreservationError.servicePaused }
            let previous: ToolBackupIndex?
            if let remote {
                let record = try await index(remote.1)
                previous = try JSONDecoder().decode(ToolBackupIndex.self, from: Data(base64Encoded: record.document.toolBackup!.payload)!)
            } else { previous = nil }
            let saved: ToolBackupFiles.Saved
            if let pending = value.pending,
               !FileManager.default.fileExists(atPath: ToolBackupFiles.directory(pending).appendingPathComponent("pending.json").path) {
                // OS backup deliberately excludes transport staging. A head
                // accepted before its reply was lost was reconciled above;
                // otherwise recapture current live records under a fresh ID.
                phase = "欠落した転送を整理"
                try await require(value, checkpoint)
                guard try AppRecordDataset.fingerprint() == currentFingerprint else { throw ToolBackupError.changed }
                try await client.abandonToolSnapshot(pending, checkpoint: checkpoint)
                try await require(value, checkpoint)
                value.pending = nil; value.pendingFingerprint = nil; value.pendingBase = nil; value.pendingPrevious = nil
                try write(value)
                try await collectParts(value, checkpoint: checkpoint)
            }
            if let pending = value.pending {
                saved = try JSONDecoder().decode(ToolBackupFiles.Saved.self, from: ToolBackupFiles.read(
                    ToolBackupFiles.directory(pending).appendingPathComponent("pending.json"), maximum: 512 * 1024))
                guard saved.owner == value.owner, value.pendingBase == value.revision else { throw ManagedPreservationError.conflict }
            } else {
                phase = "端末の記録から送信を準備"
                title = "保存の準備中…"
                saved = try await AppRecordCapture.prepare(owner: value.owner, origin: value.origin, previous: previous)
                guard try AppRecordDataset.fingerprint() == currentFingerprint else { throw ToolBackupError.changed }
                value.pending = saved.id; value.pendingFingerprint = currentFingerprint; value.pendingBase = value.revision
                value.pendingPrevious = remote?.1.snapshotID
                try await require(value, checkpoint); try write(value)
            }
            title = "保存中…"
            phase = "準備した記録を送信"
            do { try await ToolBackupTransfer.upload(saved, client: client) { _, _ in } }
            catch ManagedPreservationError.snapshotAbandoned {
                try await require(value, checkpoint)
                value.pending = nil; value.pendingFingerprint = nil; value.pendingBase = nil; value.pendingPrevious = nil
                try write(value)
                throw ToolBackupError.changed
            }
            try await require(value, checkpoint)
            let indexBytes = try ToolBackupFiles.read(ToolBackupFiles.directory(saved.id).appendingPathComponent("index-wire.json"), maximum: ToolBackupIndex.maximumIndexBytes)
            let retiring = Array(Set((value.retiring ?? []) + (value.pendingPrevious.map { [$0] } ?? []))).sorted { $0.uuidString < $1.uuidString }
            guard retiring.count <= 6 else { throw ManagedPreservationError.servicePaused }
            let head = AppRecordHead(kind: "app-records-v1", snapshotID: saved.id, indexHash: ToolBackupIndex.hash(indexBytes), retiring: retiring.isEmpty ? nil : retiring)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let document = ManagedPreservationDocument(formatVersion: 1,
                text: String(decoding: try encoder.encode(head), as: UTF8.self), capturedAt: nil,
                writtenAt: saved.index.createdAt, updatedAt: saved.index.createdAt, catNames: [], photoFile: nil)
            let revision = try await client.put(.init(recordID: headID, document: document, jpegData: nil),
                expectedRevision: value.pendingBase, consent: true, checkpoint: checkpoint)
            try await require(value, checkpoint)
            value.revision = revision; value.snapshotID = saved.id; value.fingerprint = value.pendingFingerprint
            if let previous = value.pendingPrevious { value.retiring = Array(Set((value.retiring ?? []) + [previous])) }
            value.pendingPrevious = nil
            value.pending = nil; value.pendingFingerprint = nil; value.pendingBase = nil; try write(value)
            releaseUploadedPayload(saved.id, owner: value.owner)
            title = try AppRecordDataset.fingerprint() == value.fingerprint ? "保存済み" : "変更を保存待ち"
            detail = nil
            // Reclaim only the previous automatically published index, after
            // the new CAS head is durable. Shared pieces are server-protected.
            if let previous {
                try await require(value, checkpoint)
                try await ToolBackupTransfer.delete(previous, client: client, retaining: Set(saved.index.files.flatMap(\.records))) { _, _ in }
                value.retiring?.removeAll { $0 == previous.snapshotID }; try write(value)
                try await collectParts(value, checkpoint: checkpoint)
            }
        } catch AppRecordEditingError.inProgress {
            waitingForEditor = true
            title = "入力中の内容を優先しています"
            detail = "入力を保存・終了すると、別の端末の記録の復元を続けます。"
            requested = true; nextAttempt = Date().addingTimeInterval(8)
        } catch ToolBackupError.changed {
            title = "変更を保存待ち"; requested = true; nextAttempt = .distantPast
#if DEBUG
            if CommandLine.arguments.contains("--app-records-ui-fixture") { detail = "再試行工程: " + phase }
#endif
        }
          catch is CancellationError { title = "未送信の変更があります" }
          catch { report(error) }
    }
    private func report(_ error: Error) {
        if error is AppRecordEditingError {
            title = "入力中の内容を優先しています"
            detail = "入力を保存・終了してから、復元を再開してください。"
            requested = true; nextAttempt = .distantPast; return
        }
        nextAttempt = Date().addingTimeInterval(60)
        if let failure = error as? ManagedPreservationError,
           [.membershipRequired, .servicePaused, .capacityReached, .authenticationRequired, .staleSession].contains(failure) {
            nextAttempt = Date().addingTimeInterval(300)
        }
        if error as? ManagedPreservationError == .conflict {
            conflict = true; title = "別の端末の記録と確認が必要です"
            detail = "両方の記録を残して停止しました。自動では上書きしません。"
        } else {
            title = "未送信の変更があります"
            detail = (error as? LocalizedError)?.errorDescription ?? "保存を完了できませんでした。端末の記録は残っています。"
        }
    }
#if DEBUG
    func verifyEditingPublicationFences() async throws {
        guard let value = try binding(), let remote = try await remoteHead(AppRecordHead.id(origin: value.origin, owner: value.owner)) else { throw ToolBackupError.invalid }
        let record = try await index(remote.1)
        let saved = try await ToolBackupTransfer.restore(record, client: client) { _, _ in }
        let before = try AppRecordDataset.pointer(), fingerprint = try AppRecordDataset.fingerprint()
        let lease = AppRecordEditingLease()
        lease.acquire()
        do {
            try await AppRecordDataset.activate(saved, origin: value.origin, expectedFingerprint: fingerprint, validateSession: { try $0() })
            throw ToolBackupError.storage
        } catch AppRecordEditingError.inProgress { }
        lease.release()
        // Opening an editor while validation/network work is suspended must
        // also be refused at the synchronous pointer publication boundary.
        do {
            try await AppRecordDataset.activate(saved, origin: value.origin, expectedFingerprint: fingerprint, validateSession: { publish in
                lease.acquire(); defer { lease.release() }; try publish()
            })
            throw ToolBackupError.storage
        } catch AppRecordEditingError.inProgress { }
        guard try AppRecordDataset.pointer() == before, try AppRecordDataset.fingerprint() == fingerprint else { throw ToolBackupError.storage }
    }
    func verifyMissingStagingRecovery() async throws {
        guard CommandLine.arguments.contains("--app-records-ui-fixture"), var value = try binding() else { throw ToolBackupError.invalid }
        let originalBinding = try ToolBackupFiles.read(bindingURL, maximum: 8192)
        let missing = "VeterinaryVisits/state.json"
        var probe = value
        probe.requiredManifests = Array(Set((value.requiredManifests ?? []) + [missing]))
        probe.requiredDatasetID = try AppRecordDataset.pointer()?.datasetID
        try AppRecordDataset.writeBackedUp(JSONEncoder().encode(probe), to: bindingURL)
        do { _ = try AppRecordDataset.fingerprint(); throw ToolBackupError.storage }
        catch ToolBackupError.invalid { }
        pause()
        try write(value) // An older in-flight value cannot erase the durable requirement.
        do { _ = try AppRecordDataset.fingerprint(); throw ToolBackupError.storage }
        catch ToolBackupError.invalid { }
        probe.requiredDatasetID = UUID() // Another dataset's inventory is irrelevant.
        try AppRecordDataset.writeBackedUp(JSONEncoder().encode(probe), to: bindingURL)
        _ = try AppRecordDataset.fingerprint()
        try AppRecordDataset.writeBackedUp(originalBinding, to: bindingURL)
        enabled = value.enabled
        let priorID = value.snapshotID
        value.pending = UUID(); value.pendingFingerprint = try AppRecordDataset.fingerprint()
        value.pendingBase = value.revision; value.pendingPrevious = value.snapshotID
        try write(value)
        // The production foreground loop retries a changed capture or an
        // abandoned batch. Exercise that finite protocol, then require a new
        // durable acknowledgement instead of an instantaneous UI label.
        var accepted: Binding?
        for _ in 0..<3 {
            await retry()
            let current = try binding()
            if current?.pending == nil, current?.snapshotID != priorID,
               current?.fingerprint == (try AppRecordDataset.fingerprint()) { accepted = current; break }
            guard title == "変更を保存待ち" else { throw ToolBackupError.storage }
        }
        guard let accepted, let id = accepted.snapshotID else { throw ToolBackupError.storage }
        let uploaded = try JSONDecoder().decode(ToolBackupFiles.Saved.self, from: ToolBackupFiles.read(
            ToolBackupFiles.directory(id).appendingPathComponent("uploaded.json"), maximum: 512 * 1024))
        guard uploaded.index.files.allSatisfy({ !FileManager.default.fileExists(atPath: ToolBackupFiles.directory(id).appendingPathComponent($0.path).path) }) else { throw ToolBackupError.storage }
    }
#endif
}

/// Authentication and the one-time consent live in settings; ordinary tool
/// editing never presents a separate upload operation.
@MainActor
struct AppRecordSettingsView: View {
    @StateObject private var authentication: ManagedPreservationCoordinator
    @ObservedObject private var persistence: AppRecordPersistence
    @State private var consent = false
    @State private var confirmsLocal = false
    @State private var confirmsRemote = false
    @State private var confirmsMembership = false
    init(configuration: ManagedPreservationConfiguration = .current, client: ManagedPreservationClient? = nil,
         persistence: AppRecordPersistence = .shared) {
        _authentication = StateObject(wrappedValue: ManagedPreservationCoordinator(configuration: configuration, client: client))
        self.persistence = persistence
    }
    var body: some View {
        List {
            Section {
                Label(persistence.title, systemImage: "checkmark.icloud")
                    .accessibilityIdentifier("app-record-save-status")
                if let detail = persistence.detail { Text(detail).font(.footnote) }
                Text("月額980円の機能です。初回の設定後は、写真メモ・ツールの入力と添付写真、猫の名前・誕生日などの変更を自動で保存します。")
                Text("写真ライブラリ全体、写真原本、動画は対象ではありません。写真ライブラリの写真選びは、その端末に残します。共有相手には送られません。")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("記録の保存・復元") }
            if let error = authentication.errorMessage { Section { Text(error).foregroundStyle(.red) } }
            if authentication.accountDeletionState != nil {
                Section { Text("アカウントの削除状況を確認してください。自動保存は始めません。") }
            } else if !authentication.isSignedIn {
                Section {
                    if let challenge = authentication.preparedSignIn {
                        SignInWithAppleButton(.continue) { request in
                            request.requestedScopes = [.email]; request.nonce = challenge.nonce; request.state = challenge.state
                        } onCompletion: { authentication.completeSignIn($0) }
                            .frame(height: 48).accessibilityIdentifier("app-record-signin")
                    } else { Button("Appleで本人確認") { authentication.prepareSignIn() } }
                } footer: { Text("同じ本人の記録だけを読み込みます。ログインだけでは購入や自動保存を始めません。") }
            } else if !persistence.enabled {
                Section {
                    Toggle("保存方法を確認し、自動保存に同意する", isOn: $consent)
                        .accessibilityIdentifier("app-record-consent")
                    Text("連絡先・健康情報を含むアプリ内の記録を保存します。通信できない間は端末に残し、アプリを開くと再試行します。暗号化しますが、運営者は技術的に復号できます。エンドツーエンド暗号化ではありません。")
                        .font(.footnote)
                    Button("自動保存を使う") { Task { await persistence.enable() } }
                        .disabled(!consent || persistence.busy)
                        .accessibilityIdentifier("app-record-enable")
                } footer: { Text("有効な会員資格がある場合に送信します。この操作で購入は始まりません。") }
            } else {
                Section {
                    Text("通常の画面で記録すると、自動で保存されます。別の保管操作は不要です。")
                    if persistence.conflict {
                        Button("この端末の記録を続ける") { confirmsLocal = true }
                        Button("別の端末で保存した記録を使う") { confirmsRemote = true }
                    } else {
                        Button("保存状況を再確認") { Task { await persistence.retry() } }
                    }
                    Button("この端末の自動保存を停止") { persistence.pause() }
                }
            }
            if authentication.isSignedIn, authentication.accountDeletionState == nil {
                Section {
                    if authentication.membershipLoading { ProgressView("会員情報を確認中…") }
                    if let membership = authentication.membership {
                        if membership.canSave { Label("変更を保存できる会員情報です", systemImage: "checkmark.circle") }
                        else if !membership.linked {
                            Text("保存を始める前に、このiPhoneの会員情報を接続します。")
                            Button("会員情報を接続") { confirmsMembership = true }
                                .disabled(authentication.isBusy)
                                .accessibilityIdentifier("app-record-membership-connect")
                        } else { Text("会員の有効期間を確認できるまで、新しい変更の送信を待ちます。保存済みの記録は復元できます。") }
                    }
                    if let message = authentication.membershipMessage { Text(message).font(.footnote) }
                    Button("会員情報を確認") { authentication.checkMembership() }
                        .disabled(authentication.isBusy || authentication.membershipLoading)
                } header: { Text("会員情報") }
            }
            Section {
                NavigationLink("以前の保管記録・書き出し・アカウント管理") { ManagedPreservationView() }
            } footer: {
                Text("以前に保存したコピーは残っています。会員終了後も既存記録の取り出しはできます。")
            }
        }
        .navigationTitle("保存・復元")
        .task { authentication.start() }
        .onDisappear { authentication.stop() }
        .onChange(of: authentication.membership?.canSave) { _, canSave in
            if canSave == true, persistence.enabled { Task { await persistence.retry() } }
        }
        .confirmationDialog("この本人に会員情報を接続しますか？", isPresented: $confirmsMembership, titleVisibility: .visible) {
            Button("確認して接続する") { authentication.connectMembership(consent: true) }
        } message: {
            Text("Appleで本人確認した保存先に、このiPhoneの会員情報を結び付けます。あとから別の本人へ付け替えることはできません。この操作で購入は始まりません。")
        }
        .confirmationDialog("この端末の内容で続きを保存しますか？", isPresented: $confirmsLocal, titleVisibility: .visible) {
            Button("この端末の記録を続ける") { Task { await persistence.resolveConflict(useRemote: false) } }
        } message: { Text("別の端末の記録も、この端末にコピーを残してから切り替えます。") }
        .confirmationDialog("保存先の記録に切り替えますか？", isPresented: $confirmsRemote, titleVisibility: .visible) {
            Button("保存先の記録を使う") { Task { await persistence.resolveConflict(useRemote: true) } }
        } message: { Text("現在の端末の記録を残し、復元した内容をいつもの画面で開きます。") }
    }
}

@MainActor
struct AppRecordProductionRoot: View {
    @ObservedObject private var persistence = AppRecordPersistence.shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ProductionAppRootView().id(persistence.datasetGeneration)
            .onAppear { persistence.setActive(scenePhase == .active) }
            .onChange(of: scenePhase) { _, value in persistence.setActive(value == .active) }
            .onDisappear { persistence.setActive(false) }
    }
}

@MainActor
enum AppRecordCapture {
    static func prepare(owner: String, origin: String, previous: ToolBackupIndex?) async throws -> ToolBackupFiles.Saved {
        try AppRecordDataset.requireScope(owner: owner, origin: origin)
        let source = AppRecordDataset.control.appendingPathComponent("preparing/" + UUID().uuidString, isDirectory: true)
        try ToolBackupFiles.protect(source)
        defer { try? FileManager.default.removeItem(at: source) }
        for (tool, manifest) in ToolBackupIndex.manifests {
            let live = tool == "CatIdentity" ? AppRecordDataset.identityURL() : AppRecordDataset.directory(tool).appendingPathComponent(manifest)
            guard let live else { throw ToolBackupError.invalid }
            guard FileManager.default.fileExists(atPath: live.path) else {
                try AppRecordDataset.requireMissingManifestIsEmpty(tool, at: live)
                continue
            }
            var bytes = try ToolBackupFiles.read(live, maximum: 8 * 1024 * 1024)
            if tool == "CatIdentity" {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                var state = try decoder.decode(CatHouseholdIdentityState.self, from: bytes)
                guard (1...CatHouseholdIdentityState.currentSchemaVersion).contains(state.schemaVersion) else { throw ToolBackupError.invalid }
                // PhotoKit identifiers are local links, not portable identities.
                for i in state.profiles.indices { state.profiles[i].keyPhotoLocalIdentifier = nil; state.profiles[i].photoAlbumLink = nil }
                state.memberships = []; state.globalExcludedAssets = []
                state.legacyUnscoped?.sourceAlbumIdentifier = nil
                state.legacyUnscoped?.lastKnownSourceAssetIdentifiers = nil
                state.legacyUnscoped?.legacyExcludedAssetIdentifiers = []
                state = state.normalized()
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
                bytes = try encoder.encode(state)
            } else if tool == "PhotoMemoryNotes" {
                guard var state = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw ToolBackupError.invalid }
                guard let notes = state["notes"] as? [String: [String: Any]] else { throw ToolBackupError.invalid }
                var portable: [String: Any] = [:]
                for (identifier, input) in notes {
                    var note = input
                    guard let rawID = note["id"] as? String, let id = UUID(uuidString: rawID) else { throw ToolBackupError.invalid }
                    let name = id.uuidString + ".jpg"
                    let cache = live.deletingLastPathComponent().appendingPathComponent(name)
                    if !FileManager.default.fileExists(atPath: cache.path), !identifier.hasPrefix("saved:") {
                        do {
                            let photo = try await PhotoLibraryJPEGExporter().export(localIdentifier: identifier)
                            try AppRecordDataset.writeBackedUp(photo.jpeg, to: cache)
                        } catch is MemoryPhotoJPEGExportError { /* Text survives an unavailable original. */ }
                    }
                    if FileManager.default.fileExists(atPath: cache.path) { note["photoFile"] = name }
                    portable["saved:" + id.uuidString] = note
                }
                state["notes"] = portable; state.removeValue(forKey: "archiveBindings")
                bytes = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
            } else if tool == "ShowcasePhotos" {
                let object = try JSONSerialization.jsonObject(with: bytes)
                var state = object as? [String: Any] ?? ["entries": object, "scopes": [:]]
                guard var entries = state["entries"] as? [[String: Any]] else { throw ToolBackupError.invalid }
                for i in entries.indices { entries[i]["isRestoredCopy"] = true }
                state["entries"] = entries
                bytes = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
            }
            let object = try JSONSerialization.jsonObject(with: bytes)
            for name in ToolBackupFiles.photoNames(object) {
                try ToolBackupIndex.validatePath(tool + "/" + name)
                let photo = try ToolBackupFiles.read(live.deletingLastPathComponent().appendingPathComponent(name), maximum: 20 * 1024 * 1024)
                try ToolBackupFiles.write(photo, to: source.appendingPathComponent(tool + "/" + name))
            }
            try ToolBackupFiles.write(bytes, to: source.appendingPathComponent(tool + "/" + manifest))
        }
        let reusable = previous?.files.map { file -> ToolBackupIndex.File in
            var value = file; value.sourceSnapshotID = file.sourceSnapshotID ?? previous!.snapshotID; return value
        } ?? []
        var saved = try ToolBackupFiles.capture(owner: owner, source: source, reusablePhotos: reusable, indexVersion: 3)
        if let previous {
            var index = saved.index; index.previousIndexID = previous.snapshotID
            saved = ToolBackupFiles.Saved(owner: saved.owner, index: index)
            try ToolBackupFiles.write(JSONEncoder().encode(saved), to: ToolBackupFiles.directory(saved.id).appendingPathComponent("pending.json"))
            try ToolBackupFiles.write(JSONEncoder().encode(index), to: ToolBackupFiles.directory(saved.id).appendingPathComponent("index-wire.json"))
        }
        try await ToolBackupValidation.validate(saved.index, at: ToolBackupFiles.directory(saved.id))
        return saved
    }
}

struct AppRecordSavedPhoto: View {
    let url: URL
    var maximumPixelSize = 512
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
        .task(id: url) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize] as CFDictionary) else { image = nil; return }
            image = UIImage(cgImage: thumbnail)
        }
    }
}

#if DEBUG
/// Isolated synthetic transport. The real D1/S3 reference graph is checked by
/// backend integration tests; this fixture drives the normal iPhone stores/UI.
private actor AppRecordFixtureServer {
    var records: [UUID: [String: Any]] = [:]
    var deleted = Set<UUID>()
    var claimed = Set<UUID>()
    var abandoned = Set<UUID>()
    var requests = 0
    var photoPuts = 0
    func counts() -> (Int, Int) { (requests, photoPuts) }
    func advanceHeadRevision() throws {
        guard let id = records.first(where: { _, row in
            guard let doc = row["document"] as? [String: Any], let text = doc["text"] as? String,
                  let bytes = text.data(using: .utf8), let head = try? JSONDecoder().decode(AppRecordHead.self, from: bytes) else { return false }
            return head.kind == "app-records-v1"
        })?.key, var row = records[id], let revision = row["revision"] as? Int else { throw ToolBackupError.invalid }
        row["revision"] = revision + 1; records[id] = row
    }
    func request(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests += 1
        guard let url = request.url, url.host?.hasSuffix(".app-record-fixture.invalid") == true else { throw ToolBackupError.invalid }
        func response(_ json: [String: Any], _ code: Int = 200) throws -> (Data, URLResponse) {
            (try JSONSerialization.data(withJSONObject: json), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!)
        }
        func failure(_ code: String, _ status: Int) throws -> (Data, URLResponse) { try response(["error": ["code": code]], status) }
        func referenced(_ id: UUID) -> Bool {
            records.values.contains { record in
                guard let document = record["document"] as? [String: Any] else { return false }
                if let text = document["text"] as? String, let data = text.data(using: .utf8),
                   let head = try? JSONDecoder().decode(AppRecordHead.self, from: data), head.snapshotID == id { return true }
                if let part = document["toolBackup"] as? [String: Any], part["kind"] as? String == "index",
                   let payload = part["payload"] as? String, let data = Data(base64Encoded: payload),
                   let index = try? JSONDecoder().decode(ToolBackupIndex.self, from: data) { return index.files.contains { $0.records.contains(id) } }
                return false
            }
        }
        if url.path == "/v1/tool-cleanup" {
            let items = claimed.compactMap { id -> [String: Any]? in
                guard let record = records[id], !referenced(id), let document = record["document"] as? [String: Any],
                      let part = document["toolBackup"] as? [String: Any], let kind = part["kind"] as? String else { return nil }
                if kind != "index", let source = part["snapshotId"] as? String, let snapshot = UUID(uuidString: source), records[snapshot] != nil { return nil }
                return ["recordId": id.uuidString.lowercased(), "kind": kind]
            }
            return try response(["items": Array(items.prefix(50)), "hasMore": items.count > 50])
        }
        if request.httpMethod == "POST", url.path.hasPrefix("/v1/tool-snapshots/"),
           let id = UUID(uuidString: url.pathComponents.dropLast().last ?? "") {
            guard !referenced(id) else { return try failure("REVISION_CONFLICT", 409) }
            abandoned.insert(id)
            for (partID, record) in records {
                guard let document = record["document"] as? [String: Any], let part = document["toolBackup"] as? [String: Any],
                      let source = part["snapshotId"] as? String, UUID(uuidString: source) == id, !referenced(partID) else { continue }
                claimed.insert(partID)
            }
            return try response(["snapshotId": id.uuidString.lowercased()])
        }
        if url.path == "/v1/membership" { return try response(["linked": true, "status": "active"]) }
        if url.path == "/v1/notice-contact" { return try response(["version": 1, "email": "synthetic@example.invalid", "source": "apple"]) }
        if url.path == "/v1/retention" { return try response(["version": 1, "status": "active", "dueAt": NSNull(), "paused": false]) }
        if url.path == "/v1/usage" {
            return try response(["version": 1, "accounting": "encrypted-records-v1",
                "toolSnapshots": ["maximumIndexVersion": 3, "strictPartDeletion": true],
                "storage": ["usedBytes": 0, "reservedBytes": 0, "limitBytes": 100000000,
                    "availableBytes": 100000000, "overLimit": false],
                "records": ["saved": records.count, "pending": 0, "maximumRecords": 200, "creationLimitReached": false]])
        }
        if url.path == "/v1/records" {
            let items = records.values.sorted { ($0["recordId"] as! String) < ($1["recordId"] as! String) }
            return try response(["items": items, "nextCursor": NSNull(), "generation": requests])
        }
        guard let id = UUID(uuidString: url.lastPathComponent) else { throw ToolBackupError.invalid }
        if request.httpMethod == "PUT" {
            guard !deleted.contains(id), let body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any],
                  let document = body["document"] as? [String: Any] else { return try failure("REVISION_CONFLICT", 409) }
            if let part = document["toolBackup"] as? [String: Any], let source = part["snapshotId"] as? String,
               let snapshot = UUID(uuidString: source), abandoned.contains(snapshot) { return try failure("TOOL_SNAPSHOT_ABANDONED", 409) }
            let expected = body["expectedRevision"] as? Int
            let old = records[id]
            if let old, expected == nil {
                guard NSDictionary(dictionary: old["document"] as! [String: Any]).isEqual(to: document) else { return try failure("REVISION_CONFLICT", 409) }
                return try response(["recordId": id.uuidString.lowercased(), "revision": old["revision"]!])
            }
            guard (old?["revision"] as? Int) == expected else { return try failure("REVISION_CONFLICT", 409) }
            let revision = (expected ?? 0) + 1
            let photo = (body["photoBase64"] as? String).flatMap { Data(base64Encoded: $0) }
            if photo != nil { photoPuts += 1 }
            records[id] = ["recordId": id.uuidString.lowercased(), "revision": revision, "document": document,
                "photoBase64": body["photoBase64"] ?? NSNull(), "photoSHA256": photo.map { ToolBackupIndex.hash($0) as Any } ?? NSNull()]
            return try response(["recordId": id.uuidString.lowercased(), "revision": revision])
        }
        if request.httpMethod == "DELETE" {
            guard let old = records[id] else { return try failure("RECORD_NOT_FOUND", 404) }
            for record in records.values {
                guard let document = record["document"] as? [String: Any] else { continue }
                if let text = document["text"] as? String, let bytes = text.data(using: .utf8),
                   let head = try? JSONDecoder().decode(AppRecordHead.self, from: bytes), head.snapshotID == id {
                    return try failure("TOOL_PART_REFERENCED", 409)
                }
                if let part = document["toolBackup"] as? [String: Any], part["kind"] as? String == "index",
                   let payload = part["payload"] as? String, let bytes = Data(base64Encoded: payload),
                   let index = try? JSONDecoder().decode(ToolBackupIndex.self, from: bytes),
                   index.files.contains(where: { $0.records.contains(id) }) { return try failure("TOOL_PART_REFERENCED", 409) }
            }
            records.removeValue(forKey: id); deleted.insert(id)
            if let document = old["document"] as? [String: Any], let part = document["toolBackup"] as? [String: Any],
               part["kind"] as? String == "index", let payload = part["payload"] as? String, let data = Data(base64Encoded: payload),
               let index = try? JSONDecoder().decode(ToolBackupIndex.self, from: data) {
                for partID in index.files.flatMap(\.records) where !referenced(partID) { claimed.insert(partID) }
            }
            return try response(["recordId": id.uuidString.lowercased(), "revision": (old["revision"] as! Int) + 1])
        }
        guard let record = records[id] else { return try failure("RECORD_NOT_FOUND", 404) }
        return try response(record)
    }
}

@MainActor
private final class AppRecordFixture {
    let configuration: ManagedPreservationConfiguration
    let server: AppRecordFixtureServer
    let persistence: AppRecordPersistence
    let profiles: [CatProfile]
    init(configuration: ManagedPreservationConfiguration, server: AppRecordFixtureServer, profiles: [CatProfile]) {
        self.configuration = configuration; self.server = server; self.profiles = profiles
        persistence = AppRecordPersistence(configuration: configuration, client: ManagedPreservationClient(configuration: configuration,
            requestOverride: { request, _ in try await server.request(request) }))
    }
    func authenticationClient() -> ManagedPreservationClient {
        ManagedPreservationClient(configuration: configuration, requestOverride: { request, _ in try await self.server.request(request) })
    }
    static var preparationPhase = "開始"
    static func make() async throws -> AppRecordFixture {
        let cacheURL = AppRecordDataset.support.appendingPathComponent("cache-read-probe.json")
        let small = Data("{}".utf8), large = Data("{\"pending\":\"longer replacement\"}".utf8)
        try ToolBackupFiles.write(small, to: cacheURL)
        guard try ToolBackupFiles.read(cacheURL, maximum: 4096) == small else { throw ToolBackupError.storage }
        try ToolBackupFiles.write(large, to: cacheURL)
        var cached = cacheURL
        cached.setTemporaryResourceValue(small.count, forKey: .fileSizeKey)
        guard try ToolBackupFiles.read(cached, maximum: 4096) == large else { throw ToolBackupError.storage }
        try ToolBackupFiles.write(small, to: cacheURL)
        guard try ToolBackupFiles.read(cacheURL, maximum: 4096) == small else { throw ToolBackupError.storage }
        try FileManager.default.removeItem(at: cacheURL)
        // Unknown or incomplete stores never authorize replacing a device.
        preparationPhase = "空でない・不正なデータの保護"
        let vetURL = AppRecordDataset.directory("VeterinaryVisits").appendingPathComponent("state.json")
        try ToolBackupFiles.write(Data("{\"schema\":99,\"visits\":[]}".utf8), to: vetURL)
        do { _ = try AppRecordDataset.isEmpty(); throw ToolBackupError.storage }
        catch ToolBackupError.invalid { }
        try FileManager.default.removeItem(at: vetURL.deletingLastPathComponent())
        preparationPhase = "猫情報の保護"
        let identityEncoder = JSONEncoder(); identityEncoder.dateEncodingStrategy = .iso8601
        let legacy = CatHouseholdIdentityState.legacyUnscoped(lifeReference: nil, curation: .empty)
        var unknown = legacy; unknown.schemaVersion = 99
        try ToolBackupFiles.write(identityEncoder.encode(unknown), to: AppRecordDataset.identityURL()!)
        do { _ = try AppRecordDataset.isEmpty(); throw ToolBackupError.storage }
        catch ToolBackupError.invalid { }
        var withDate = legacy
        withDate.legacyUnscoped?.lifeReference = CatLifeReference(kind: .birthday, date: CatLifeDate(date: Date())!)
        try ToolBackupFiles.write(identityEncoder.encode(withDate), to: AppRecordDataset.identityURL()!)
        guard try !AppRecordDataset.isEmpty() else { throw ToolBackupError.storage }
        try FileManager.default.removeItem(at: AppRecordDataset.identityURL()!)
        preparationPhase = "検査用認証"
        let origin = URL(string: "https://" + UUID().uuidString.lowercased() + ".app-record-fixture.invalid")!
        let configuration = ManagedPreservationConfiguration(isEnabled: true, origin: origin, membershipAudience: "app-record.fixture")
        let credential = ManagedPreservationSessionStore.Credential(token: String(repeating: "t", count: 43), ownerId: UUID().uuidString.lowercased(),
            expiresAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 3600))
        guard try ManagedPreservationSessionStore(origin: origin.absoluteString).save(credential, replacing: nil) else { throw ToolBackupError.invalid }
        preparationPhase = "同名別猫の端末写真の保護"
        let state = CatHouseholdIdentityState(mode: .profiled, profiles: [CatProfile(displayName: "同じ名前"), CatProfile(displayName: "同じ名前")], memberships: [], globalExcludedAssets: [], legacyUnscoped: nil).normalized()
        let profiles = state.profiles
        var local = state
        local.profiles[0].keyPhotoLocalIdentifier = "local-first-cat"
        local.profiles[0].photoAlbumLink = CatProfilePhotoAlbumLink(localIdentifier: "local-album", lastKnownAssetLocalIdentifiers: ["local-first-cat"])
        local.memberships = [CatAssetProfileMembership(assetLocalIdentifier: "local-first-cat", profileID: profiles[0].id, decision: .included)]
        local = local.normalized()
        var remote = state
        remote.profiles[0].displayName = "保存先で変えた名前"
        remote.profiles.append(CatProfile(displayName: profiles[0].displayName))
        for i in remote.profiles.indices {
            remote.profiles[i].keyPhotoLocalIdentifier = "foreign-device-photo"
            remote.profiles[i].photoAlbumLink = CatProfilePhotoAlbumLink(localIdentifier: "foreign-device-album", lastKnownAssetLocalIdentifiers: [])
        }
        remote = remote.normalized()
        let merged = try AppRecordDataset.preservingLocalPhotoLinks(remote, local: local)
        let withoutLocal = try AppRecordDataset.preservingLocalPhotoLinks(remote, local: nil)
        guard merged.profiles.first(where: { $0.id == profiles[0].id })?.displayName == "保存先で変えた名前",
              merged.profiles.first(where: { $0.id == profiles[0].id })?.keyPhotoLocalIdentifier == "local-first-cat",
              merged.profiles.first(where: { $0.id == profiles[0].id })?.photoAlbumLink == local.profiles[0].photoAlbumLink,
              merged.profiles.filter({ $0.id != profiles[0].id }).allSatisfy({ $0.keyPhotoLocalIdentifier == nil }),
              merged.memberships == local.memberships,
              withoutLocal.profiles.allSatisfy({ $0.keyPhotoLocalIdentifier == nil && $0.photoAlbumLink == nil }),
              withoutLocal.memberships.isEmpty else { throw ToolBackupError.storage }
        preparationPhase = "猫情報の準備"
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try ToolBackupFiles.write(encoder.encode(state), to: AppRecordDataset.identityURL()!)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.systemOrange.setFill(); context.cgContext.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }.jpegData(compressionQuality: 0.9)!
        preparationPhase = "うちの子の写真の準備"
        let showcaseDirectory = AppRecordDataset.directory("ShowcasePhotos")
        let showcaseName = UUID().uuidString + ".jpg"
        let showcase = ShowcasePhotoStore.Entry(scopeID: "", photoIdentifier: "fixture-owned-showcase",
                                                imageFileName: showcaseName, isPinned: true, isRestoredCopy: true)
        try AppRecordDataset.writeBackedUp(JSONEncoder().encode([showcase]), to: showcaseDirectory.appendingPathComponent("selected.json"))
        try AppRecordDataset.writeBackedUp(image, to: showcaseDirectory.appendingPathComponent(showcaseName))
        preparationPhase = "預けるときの準備"
        var plan = CareHandoffPlan()
        var photos: [String: Data] = [:]
        for profile in profiles {
            var cat = CareCat(); cat.name = profile.displayName; cat.profileID = profile.id.uuidString
            let name = UUID().uuidString + ".jpg"; cat.photoName = name; photos[name] = image
            plan.cats.append(cat)
        }
        plan.contact = "保存の検査用"
        try CareHandoffRepository(directory: AppRecordDataset.directory("CareHandoff")).commit(plan, newPhotos: photos)
        preparationPhase = "写真メモの準備"
        let noteStore = PhotoMemoryNoteStore.shared
        guard let note = try await noteStore.save(text: "保存した写真メモ", for: "fixture-local-only", expectedRevision: nil) else { throw ToolBackupError.invalid }
        let noteURL = AppRecordDataset.directory("PhotoMemoryNotes").appendingPathComponent("state.json")
        var noteState = try JSONSerialization.jsonObject(with: Data(contentsOf: noteURL)) as! [String: Any]
        var notes = noteState["notes"] as! [String: [String: Any]]
        notes["fixture-local-only"]!["photoFile"] = note.id.uuidString + ".jpg"; noteState["notes"] = notes
        try ToolBackupFiles.write(JSONSerialization.data(withJSONObject: noteState), to: noteURL)
        try ToolBackupFiles.write(image, to: noteURL.deletingLastPathComponent().appendingPathComponent(note.id.uuidString + ".jpg"))
        return AppRecordFixture(configuration: configuration, server: AppRecordFixtureServer(), profiles: profiles)
    }
}

@MainActor
struct AppRecordPersistenceFixtureView: View {
    @State private var fixture: AppRecordFixture?
    @State private var result = ""
    @State private var counts = ""
    @State private var switching = false
    var body: some View {
        Group {
            if let fixture { AppRecordFixtureContent(fixture: fixture, result: result, counts: counts, switchDevice: { Task { await secondDevice() } }) }
            else { Text(result.isEmpty ? "自動保存の検査を準備中…" : result) }
        }
        .disabled(switching)
        .task {
            do { fixture = try await AppRecordFixture.make(); fixture?.persistence.setActive(true) }
            catch { result = "検査準備失敗: \(AppRecordFixture.preparationPhase)" }
            while !Task.isCancelled {
                if let fixture { let (_, photos) = await fixture.server.counts(); counts = "写真の送信 \(photos)回" }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    private func secondDevice() async {
        guard let previous = fixture else { return }
        switching = true; defer { switching = false }
        previous.persistence.setActive(false)
        let oldRoot = AppRecordDataset.support
        var phase = "元記録を読む"
        var target: AppRecordFixture?
        do {
            let old = try Data(contentsOf: oldRoot.appendingPathComponent("CareHandoff/plan.json"))
            phase = "新端末へ切替"
            try AppRecordDataset.nextFixtureDevice()
            let next = AppRecordFixture(configuration: previous.configuration, server: previous.server, profiles: previous.profiles)
            target = next
            phase = "復元を実行"
            await next.persistence.enable()
            phase = "通常ストアの件数を照合"
            guard try Data(contentsOf: oldRoot.appendingPathComponent("CareHandoff/plan.json")) == old,
                  CareHandoffStore.shared.plan.cats.count == 2,
                  try await PhotoMemoryNoteStore.shared.records().count == 1 else { throw ToolBackupError.invalid }
            let records = try await PhotoMemoryNoteStore.shared.records()
            phase = "復元した添付写真を照合"
            guard let first = records.first, let photo = try await PhotoMemoryNoteStore.shared.photoURL(for: first.id),
                  FileManager.default.fileExists(atPath: photo.path) else { throw ToolBackupError.invalid }
            phase = "猫情報のバックアップと旧日付を照合"
            let identityURL = AppRecordDataset.identityURL()!
            let originalIdentity = try ToolBackupFiles.read(identityURL, maximum: 8 * 1024 * 1024)
            let reference = CatLifeReference(kind: .birthday, date: CatLifeDate(date: Date(timeIntervalSince1970: 1_000_000_000))!)
            let legacy = CatHouseholdIdentityState.legacyUnscoped(lifeReference: reference, curation: .empty)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try AppRecordDataset.writeBackedUp(encoder.encode(legacy), to: identityURL)
            let identityStore = try CatHouseholdIdentityStore(stateURL: identityURL)
            for old in [nil, CatLifeReference(kind: .birthday, date: CatLifeDate(date: .now)!)] {
                let loaded = try await identityStore.loadOrMigrate(legacyLifeReference: old, legacyCuration: .empty)
                guard loaded.legacyUnscoped?.lifeReference == reference else { throw ToolBackupError.storage }
            }
            var freshIdentity = identityURL; freshIdentity.removeAllCachedResourceValues()
            guard try freshIdentity.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == false else { throw ToolBackupError.storage }
            try FileManager.default.removeItem(at: identityURL)
            do { _ = try AppRecordDataset.fingerprint(); throw ToolBackupError.storage }
            catch ToolBackupError.invalid { }
            do { _ = try await identityStore.load(); throw ToolBackupError.storage }
            catch ToolBackupError.invalid { }
            try originalIdentity.write(to: identityURL, options: [.atomic, .completeFileProtection])
            phase = "転送準備の欠落から再開"
            try await next.persistence.verifyMissingStagingRecovery()
            phase = "入力中の復元・公開直前の保護"
            try await next.persistence.verifyEditingPublicationFences()
            fixture = next; next.persistence.setActive(true)
            result = "自動復元・通常画面・元記録保全を確認"
        } catch {
            // Keep the failing fixture stage visible without raw error details.
            result = "自動復元の検査失敗: \(phase) / \(target?.persistence.title ?? "") / \(target?.persistence.detail ?? "")"
        }
    }
}

private enum AppRecordFixtureRoute: Hashable { case settings, care }
private enum AppRecordFixturePresentation: String, Identifiable {
    case draft, tools
    var id: String { rawValue }
}

@MainActor
private struct AppRecordFixtureContent: View {
    let fixture: AppRecordFixture
    let result: String
    let counts: String
    let switchDevice: () -> Void
    @State private var path = NavigationPath()
    @State private var presentation: AppRecordFixturePresentation?
    @ObservedObject private var persistence: AppRecordPersistence
    init(fixture: AppRecordFixture, result: String, counts: String, switchDevice: @escaping () -> Void) {
        self.fixture = fixture; self.result = result; self.counts = counts; self.switchDevice = switchDevice
        persistence = fixture.persistence
    }
    var body: some View {
        NavigationStack(path: $path) {
            List {
                Text(persistence.title).accessibilityIdentifier("app-record-fixture-status")
                Text(counts).accessibilityIdentifier("app-record-fixture-photo-count")
                if !result.isEmpty { Text(result).accessibilityIdentifier("app-record-fixture-result") }
                NavigationLink("保存・復元", value: AppRecordFixtureRoute.settings)
                NavigationLink("預けるとき", value: AppRecordFixtureRoute.care)
                NavigationLink("写真メモ", value: MemoriesRoute.memoryNotes)
                Button("入力中の復元を検査") { presentation = .draft }
                    .accessibilityIdentifier("app-record-open-draft")
                Button("通常のツール画面") { presentation = .tools }
                    .accessibilityIdentifier("app-record-open-tools")
                Button("別端末での自動復元を検査", action: switchDevice).disabled(persistence.busy || persistence.title != "保存済み")
            }.navigationTitle("自動保存の検査")
                .navigationDestination(for: AppRecordFixtureRoute.self) { route in
                    switch route {
                    case .settings: AppRecordSettingsView(configuration: fixture.configuration, client: fixture.authenticationClient(), persistence: persistence)
                    case .care: CareHandoffView(profiles: [], unregisteredPhotos: [], store: .shared, reuseStore: .shared)
                    }
                }
                .navigationDestination(for: MemoriesRoute.self) { route in
                    switch route {
                    case .memoryNotes: PhotoMemoryNotesListView(photos: [], store: .shared, openPhotos: {})
                    case let .memoryNote(id): PhotoMemoryNoteDetailView(recordID: id, photos: [], store: .shared)
                    case let .memoryNotePhoto(id):
                        PhotoMemoryNotePhotoDestination(recordID: id, photos: [], store: .shared) { _ in Text("元写真なし") }
                    default: Text("検査対象外")
                    }
                }
        }.id(persistence.datasetGeneration)
            .fullScreenCover(item: $presentation) { screen in
                switch screen {
                case .draft: NavigationStack { AppRecordDraftProtectionFixture(fixture: fixture) }
                case .tools: AppStoreScreenshotFixtureRootView(photoAccess: false)
                }
            }
    }
}

@MainActor
private struct AppRecordDraftProtectionFixture: View {
    let fixture: AppRecordFixture
    @ObservedObject private var persistence: AppRecordPersistence
    @State private var record: PhotoMemoryNoteRecord?
    init(fixture: AppRecordFixture) { self.fixture = fixture; persistence = fixture.persistence }
    var body: some View {
        Group {
            if let record {
                PhotoMemoryNoteEditor(record: record, photo: nil, store: .shared, onSaved: {})
                    .safeAreaInset(edge: .bottom) {
                        VStack {
                            Text(persistence.title).accessibilityIdentifier("draft-protection-status")
                            Button("別端末の変更を受信") {
                                Task {
                                    do { try await fixture.server.advanceHeadRevision(); await persistence.retry() }
                                    catch { }
                                }
                            }
                        }.padding(8).background(.regularMaterial)
                    }
            } else { ProgressView() }
        }
        .task { record = try? await PhotoMemoryNoteStore.shared.records().first }
    }
}
#endif
