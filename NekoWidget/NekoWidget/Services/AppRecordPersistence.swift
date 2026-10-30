import Foundation
import Combine
import SwiftUI
import CryptoKit
import StoreKit
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
    private static var fixtureSupport: URL? = {
        guard CommandLine.arguments.contains("--app-records-ui-fixture") else { return nil }
        let name = "app-records-fixture-" + UUID().uuidString
        if CommandLine.arguments.contains("--app-records-journal-probe") {
            // Exercise an actual Application Support directory through a valid
            // base-relative URL. All files still belong to this isolated fixture.
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return URL(string: name + "/", relativeTo: support)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    }()
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
        do {
            let selected = try root().appendingPathComponent(name, isDirectory: true)
            // Existing datasets predate CatCare. Until the first new capture,
            // keep using that original store without copying or deleting it.
            if name == "CatCare", !FileManager.default.fileExists(atPath: selected.appendingPathComponent("state.json").path) {
                let original = support.appendingPathComponent(name, isDirectory: true)
                if FileManager.default.fileExists(atPath: original.appendingPathComponent("state.json").path) { return original }
            }
            return selected
        }
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
        let retainedCare = directory("CatCare").standardizedFileURL.path + "/"
        if managed && !path.hasPrefix(root) && !path.hasPrefix(retainedCare) { throw ToolBackupError.changed }
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
        try FamilyNotebookBackup.refresh()
        var digest = SHA256()
        for (tool, manifest) in ToolBackupIndex.manifests.sorted(by: { $0.key < $1.key }) {
            let url = tool == "CatIdentity" ? identityURL() : directory(tool).appendingPathComponent(manifest)
            digest.update(data: Data((tool + "/" + manifest + "\n").utf8))
            if let url, FileManager.default.fileExists(atPath: url.path) {
                digest.update(data: try AppRecordJSON.read(url))
            } else if let url {
                try requirePreviouslyPresentManifest(tool + "/" + manifest, at: url)
            }
            digest.update(data: Data([0]))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// Only missing/valid empty stores count as empty. Unknown schemas and
    /// unreadable manifests never authorize replacing local records.
    static func isEmpty() throws -> Bool {
        _ = try root()
        try FamilyNotebookBackup.refresh()
        for (tool, manifest) in ToolBackupIndex.manifests {
            let url = tool == "CatIdentity" ? identityURL() : directory(tool).appendingPathComponent(manifest)
            guard let url else { throw ToolBackupError.invalid }
            guard FileManager.default.fileExists(atPath: url.path) else {
                try requireMissingManifestIsEmpty(tool, at: url)
                continue
            }
            let data = try AppRecordJSON.read(url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // The legacy Showcase array is recognized, but is not empty.
                throw ToolBackupError.invalid
            }
            switch tool {
            case "CatCare":
                let state = try CatCareDecoding.backupState(data)
                if !state.cats.isEmpty || state.household != CatCareHousehold() { return false }
            case "FamilyNotebook":
                if !(try FamilyNotebookBackup.decode(data)).copies.isEmpty { return false }
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
            localIdentity = try decoder.decode(CatHouseholdIdentityState.self, from: AppRecordJSON.read(url))
        } else { localIdentity = nil }
        let source = try ToolBackupFiles.restoredSource(saved.id, owner: saved.owner)
        try await ToolBackupValidation.validate(saved.index, at: source)
        var receipt = Pointer(version: 1, datasetID: UUID(), owner: saved.owner, origin: origin,
                              manifests: saved.index.files.map(\.path).filter { knownManifestPaths.contains($0) }.sorted())
        let destination = datasets.appendingPathComponent(receipt.datasetID.uuidString, isDirectory: true)
        try ToolBackupFiles.protect(destination)
        // All referenced bytes are verified before any live store sees this root.
        for file in saved.index.files {
            let data = try ToolBackupFiles.read(source.appendingPathComponent(file.path), maximum: 20 * 1024 * 1024)
            guard ToolBackupIndex.hash(data) == file.sha256 else { throw ToolBackupError.invalid }
            try ToolBackupFiles.write(data, to: destination.appendingPathComponent(file.path))
        }
        // An old backup predates these tools. Preserve this phone's copies
        // instead of turning their absence in the old format into deletion.
        for tool in ["CatCare","FamilyNotebook"] {
            let target = destination.appendingPathComponent(tool + "/state.json")
            if !FileManager.default.fileExists(atPath: target.path) {
                let current = directory(tool).appendingPathComponent("state.json")
                if FileManager.default.fileExists(atPath: current.path) {
                    let data = try AppRecordJSON.read(current)
                    try ToolBackupFiles.write(data, to: target)
                    for name in try ToolBackupFiles.manifestPhotoNames(tool: tool, data: data) {
                        let source = ToolBackupFiles.sourcePhotoURL(tool: tool, directory: current.deletingLastPathComponent(), name: name)
                        try ToolBackupFiles.write(ToolBackupFiles.read(source, maximum: 20 * 1024 * 1024),
                            to: destination.appendingPathComponent(tool + "/" + name))
                    }
                    receipt.manifests?.append(tool + "/state.json")
                }
            } else if tool == "CatCare" {
                let local = directory(tool).appendingPathComponent("state.json")
                let ownDevice = FileManager.default.fileExists(atPath: local.path)
                    ? try CatCareDecoding.backupState(AppRecordJSON.read(local)).deviceID : UUID().uuidString.lowercased()
                try AppRecordJSON.write(CatCareDecoding.portable(AppRecordJSON.read(target), deviceID: ownDevice), to: target)
            } else {
                try AppRecordJSON.write(FamilyNotebookBackup.restored(AppRecordJSON.read(target)), to: target)
            }
        }
        receipt.manifests?.sort()
        let identity = destination.appendingPathComponent("CatIdentity/state.json")
        if FileManager.default.fileExists(atPath: identity.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let remote = try decoder.decode(CatHouseholdIdentityState.self, from: AppRecordJSON.read(identity))
            let merged = try preservingLocalPhotoLinks(remote, local: localIdentity)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
            try ToolBackupFiles.write(encoder.encode(merged), to: identity)
        }
        // Restore creates these folders privately; publish them as live data
        // only after validation, preserving OS backup for future offline edits.
        for tool in Set((receipt.manifests ?? []).map { String($0.split(separator: "/")[0]) }) {
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
    private struct AcceptedSave {
        let binding: Binding
        let fence: ManagedPreservationClient.LocalSessionFence
    }

    /// Capture only after the remote head and the durable local ACK agree.
    /// The catch path must not renew credentials or do network work.
    private func acceptedSave(_ value: Binding,
                              checkpoint: ManagedPreservationClient.SessionCheckpoint) async throws -> AcceptedSave? {
        guard value.revision != nil, value.snapshotID != nil, value.fingerprint != nil,
              value.pending == nil else { return nil }
        let fence = try await client.localSessionFence(checkpoint)
        guard let current = try binding(), current.owner == value.owner, current.origin == value.origin,
              current.revision == value.revision, current.snapshotID == value.snapshotID,
              current.fingerprint == value.fingerprint, current.pending == nil else { return nil }
        return AcceptedSave(binding: current, fence: fence)
    }

    private func stillSaved(_ accepted: AcceptedSave?) -> Bool {
        guard let accepted else { return false }
        do {
            try accepted.fence {
                AppRecordDataset.writeLock.lock(); defer { AppRecordDataset.writeLock.unlock() }
                let saved = accepted.binding
                try AppRecordDataset.requireScope(owner: saved.owner, origin: saved.origin)
                guard let current = try binding(), current.enabled,
                      current.owner == saved.owner, current.origin == saved.origin,
                      current.revision == saved.revision, current.snapshotID == saved.snapshotID,
                      current.fingerprint == saved.fingerprint, current.pending == nil,
                      current.requiredDatasetID == saved.requiredDatasetID,
                      try AppRecordDataset.pointer()?.datasetID == saved.requiredDatasetID,
                      try AppRecordDataset.fingerprint() == saved.fingerprint else { throw ToolBackupError.changed }
            }
            return true
        } catch { return false }
    }

    private func reportSyncFailure(_ error: Error, cleanup: Bool, accepted: AcceptedSave?) {
        // A cleanup failure is not an upload failure. Keep its retry scheduled,
        // including when the last retirement ID was already durably removed.
        requested = true
        if cleanup, stillSaved(accepted) {
            title = "保存済み"
            detail = "変更は保存されています。以前の保存データの整理は、アプリを開いている間に自動で再試行します。" +
                ((error as? ToolBackupJournalError).map { "（確認コード: \($0.rawValue)）" } ?? "")
            nextAttempt = Date().addingTimeInterval(60)
        } else if error is CancellationError {
            title = "未送信の変更があります"
            detail = "保存を中断しました。アプリを開いている間に自動で再開します。"
            nextAttempt = .distantPast
        } else {
            report(error)
            if cleanup, error is ToolBackupError || error is ToolBackupJournalError {
                detail = "以前の保存データの整理を確認できず、送信を待っています。端末の記録は残っています。" +
                    ((error as? ToolBackupJournalError).map { "（確認コード: \($0.rawValue)）" } ?? "")
            }
        }
    }

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
        guard let bytes = try? ToolBackupFiles.read(receipt, maximum: ToolBackupIndex.maximumReceiptBytes),
              let saved = try? JSONDecoder().decode(ToolBackupFiles.Saved.self, from: bytes),
              saved.id == id, saved.owner == owner, saved.index.version >= 3,
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
            let checkpoint = try await client.prepareSession(expectedOwner: try binding()?.owner)
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
            let checkpoint = try await client.prepareSession(expectedOwner: value.owner)
            try await require(value, checkpoint)
            let headID = AppRecordHead.id(origin: value.origin, owner: value.owner)
            guard let remote = try await remoteHead(headID) else { throw ManagedPreservationError.conflict }
            let fingerprint = try AppRecordDataset.fingerprint()
            // Retain a complete remote copy even when choosing this device.
            let record = try await index(remote.1)
            let restored = try await ToolBackupTransfer.restoreWithSession(record, client: client) { _, _ in }
            let saved = restored.saved
            let restoredCheckpoint = restored.checkpoint
            try await require(value, restoredCheckpoint)
            guard try await remoteHead(headID)?.0.revision == remote.0.revision else { throw ManagedPreservationError.conflict }
            if useRemote {
                let fence = try await client.localSessionFence(restoredCheckpoint)
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
            try await require(value, restoredCheckpoint); try write(value)
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
        struct Header: Decodable { let version: Int }
        let record = try await client.detail(head.snapshotID).record
        guard record.revision == 1, let part = record.document.toolBackup,
              part.kind == "index", part.sha256 == head.indexHash,
              let bytes = Data(base64Encoded: part.payload), ToolBackupIndex.hash(bytes) == head.indexHash,
              [3, 4].contains(try JSONDecoder().decode(Header.self, from: bytes).version) else { throw ToolBackupError.invalid }
        if try JSONDecoder().decode(Header.self, from: bytes).version == 4 {
            guard try ToolBackupTree.decode(part).prefix.isEmpty else { throw ToolBackupError.invalid }
        }
        return record
    }
    private func synchronize() async {
        guard active || requested, !busy, !conflict, Date() >= nextAttempt else { return }
        busy = true
        defer { busy = false }
        var phase = "保存設定を確認"
        var accepted: AcceptedSave?
        var cleanup = false
        do {
            guard var value = try binding(), value.enabled else { title = "自動保存は未設定です"; return }
            try AppRecordDataset.requireScope(owner: value.owner, origin: value.origin)
            // Every live store commit and foreground entry requests work. An
            // idle timer must not reassemble years of notes every eight seconds.
            guard requested || value.pending != nil || !(value.retiring ?? []).isEmpty || waitingForEditor else { return }
            let currentFingerprint = try AppRecordDataset.fingerprint()
            if waitingForEditor, currentFingerprint == value.fingerprint {
                // A long editing session must not poll the server every eight
                // seconds merely because a previously seen restore is waiting.
                try AppRecordEditingLease.requireIdle()
                waitingForEditor = false
            }
            // No network polling for an unchanged dataset. Foreground entry and
            // commits request one check; conflict detection also occurs at CAS.
            guard Self.needsAuthenticatedWork(value, fingerprint: currentFingerprint, requested: requested) else { return }
            // Only actual work/foreground checks may renew access. An unchanged
            // eight-second timer must not extend device idle expiry or call Apple.
            let checkpoint = try await client.prepareSession(expectedOwner: value.owner)
            try await require(value, checkpoint)
            releaseUploadedPayload(value.snapshotID, owner: value.owner)
            if let pending = value.pending {
                phase = "中断した送信を再開"
                try await ToolBackupTransfer.resumeMetadataBatchIfNeeded(snapshotID: pending, owner: value.owner,
                    client: client, checkpoint: checkpoint)
                try await require(value, checkpoint)
            }
            let headID = AppRecordHead.id(origin: value.origin, owner: value.owner)
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
                    let restored = try await ToolBackupTransfer.restoreWithSession(record, client: client) { _, _ in }
                    let saved = restored.saved
                    try await require(value, restored.checkpoint)
                    guard try await remoteHead(headID)?.0.revision == remote.0.revision else { throw ManagedPreservationError.conflict }
                    let fence = try await client.localSessionFence(restored.checkpoint)
                    try await AppRecordDataset.activate(saved, origin: value.origin, expectedFingerprint: currentFingerprint, validateSession: fence)
                    value.revision = remote.0.revision; value.snapshotID = saved.id
                    value.fingerprint = try AppRecordDataset.fingerprint(); value.pending = nil
                    value.pendingFingerprint = nil; value.pendingBase = nil; try write(value)
                    title = "復元しました"; detail = "いつもの画面で記録を使えます。"; return
                } else { throw ManagedPreservationError.conflict }
            }
            if remote?.0.revision == value.revision, remote?.1.snapshotID == value.snapshotID {
                accepted = try await acceptedSave(value, checkpoint: checkpoint)
            }
            // Retry only queued, previously accepted automatic snapshots. The
            // server head reference refuses removal of the current snapshot.
            cleanup = true
            let retained: Set<UUID>
            if !(value.retiring ?? []).isEmpty, let remote {
                let current = try await index(remote.1)
                let decoded = try await ToolBackupTransfer.loadIndex(current, client: client)
                retained = decoded.recordIDs
            } else { retained = [] }
            for retiring in value.retiring ?? [] where retiring != remote?.1.snapshotID {
                do {
                    let pending = try ToolBackupFiles.pendingDeletions(owner: value.owner).first { $0.id == retiring }
                    let old: ToolBackupIndex
                    if let pending { old = pending.index }
                    else {
                        let snapshot = try await client.detail(retiring).record
                        guard let part = snapshot.document.toolBackup, let bytes = Data(base64Encoded: part.payload) else { throw ToolBackupError.invalid }
                        old = try await ToolBackupTransfer.loadIndex(snapshot, client: client)
                    }
                    guard old.version >= 3 else { throw ToolBackupError.invalid }
                    try await ToolBackupTransfer.delete(old, client: client, retaining: retained) { _, _ in }
                } catch ManagedPreservationError.notFound { }
                try await require(value, checkpoint)
                value.retiring?.removeAll { $0 == retiring }; try write(value)
            }
            try await collectParts(value, checkpoint: checkpoint)
            if value.fingerprint == currentFingerprint, value.pending == nil {
                // Editing may have committed while cleanup was awaiting I/O.
                // Never overwrite its waiting state with an older fingerprint.
                guard stillSaved(accepted) else { throw ToolBackupError.changed }
                title = "保存済み"; detail = nil; return
            }
            cleanup = false; accepted = nil
            let membership = try await client.membership()
            try await require(value, checkpoint)
            guard membership.canSave else { throw ManagedPreservationError.membershipRequired }
            let support = try await client.usage().toolSnapshots
            guard (support?.maximumIndexVersion ?? 0) >= 3 else { throw ManagedPreservationError.servicePaused }
            let previous: ToolBackupIndex?
            if let remote {
                let record = try await index(remote.1)
                previous = try await ToolBackupTransfer.loadIndex(record, client: client)
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
                    ToolBackupFiles.directory(pending).appendingPathComponent("pending.json"), maximum: ToolBackupIndex.maximumReceiptBytes))
                guard saved.owner == value.owner, value.pendingBase == value.revision else { throw ManagedPreservationError.conflict }
            } else {
                phase = "端末の記録から送信を準備"
                title = "保存の準備中…"
                saved = try await AppRecordCapture.prepare(owner: value.owner, origin: value.origin, previous: previous, indexVersion: (support?.maximumIndexVersion ?? 0) >= 4 ? 4 : 3)
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
            // The publication is complete before any old snapshot is removed.
            accepted = try await acceptedSave(value, checkpoint: checkpoint)
            releaseUploadedPayload(saved.id, owner: value.owner)
            title = try AppRecordDataset.fingerprint() == value.fingerprint ? "保存済み" : "変更を保存待ち"
            detail = nil
            // Reclaim only the previous automatically published index, after
            // the new CAS head is durable. Shared pieces are server-protected.
            cleanup = true
            if let previous {
                try await require(value, checkpoint)
                try await ToolBackupTransfer.delete(previous, client: client, retaining: saved.index.recordIDs) { _, _ in }
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
            detail = "保存の処理中に記録が変わりました。端末の記録を残して、自動で続きを保存します。"
#if DEBUG
            if CommandLine.arguments.contains("--app-records-ui-fixture") { detail = "再試行工程: " + phase }
#endif
        }
          catch { reportSyncFailure(error, cleanup: cleanup, accepted: accepted) }
    }
    static func needsAuthenticatedWork(_ value: Binding, fingerprint: String, requested: Bool) -> Bool {
        requested || fingerprint != value.fingerprint || value.pending != nil || !(value.retiring ?? []).isEmpty
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

    func appleCredentialRevoked() async {
        // Preserve owner-bound consent, pending bytes and all normal records.
        do { guard try await client.appleAuthorizationDidChange() else { return } }
        catch { return /* Unknown status or a newer login must remain intact. */ }
        requested = true; nextAttempt = .distantPast
        title = "未送信の変更があります"
        detail = ManagedPreservationError.authenticationRequired.errorDescription
    }
#if DEBUG
    func verifyAcceptedSaveFences() async throws {
        guard let value = try binding() else { throw ToolBackupError.storage }
        let checkpoint = try await client.prepareSession(expectedOwner: value.owner)
        guard let accepted = try await acceptedSave(value, checkpoint: checkpoint), stillSaved(accepted) else { throw ToolBackupError.storage }
        let original = try ToolBackupFiles.read(bindingURL, maximum: 8192)
        defer { try? AppRecordDataset.writeBackedUp(original, to: bindingURL) }
        for mutation in 0..<5 {
            var changed = value
            switch mutation {
            case 0: changed.enabled = false
            case 1: changed.pending = UUID()
            case 2:
                changed = Binding(version: value.version, origin: value.origin, owner: UUID().uuidString.lowercased(),
                    consent: value.consent, enabled: value.enabled, revision: value.revision,
                    snapshotID: value.snapshotID, fingerprint: value.fingerprint,
                    requiredManifests: value.requiredManifests, requiredDatasetID: value.requiredDatasetID)
            case 3: changed.snapshotID = UUID()
            default: changed.requiredDatasetID = UUID()
            }
            try AppRecordDataset.writeBackedUp(JSONEncoder().encode(changed), to: bindingURL)
            guard !stillSaved(accepted) else { throw ToolBackupError.storage }
        }
        try AppRecordDataset.writeBackedUp(original, to: bindingURL)
        let note = AppRecordDataset.directory("CareHandoff").appendingPathComponent("plan.json")
        let bytes = try Data(contentsOf: note)
        try AppRecordDataset.writeBackedUp(bytes + Data("\n".utf8), to: note)
        let changedWasSaved = stillSaved(accepted)
        try AppRecordDataset.writeBackedUp(bytes, to: note)
        guard !changedWasSaved, stillSaved(accepted) else { throw ToolBackupError.storage }
        let store = ManagedPreservationSessionStore(origin: value.origin)
        guard let credential = try store.load() else { throw ToolBackupError.storage }
        let replacement = ManagedPreservationSessionStore.Credential(token: String(repeating: "r", count: 43),
            ownerId: credential.ownerId, expiresAt: credential.expiresAt)
        guard try store.save(replacement, replacing: credential) else { throw ToolBackupError.storage }
        let replacedWasSaved = stillSaved(accepted)
        guard try store.save(credential, replacing: replacement), !replacedWasSaved else { throw ToolBackupError.storage }
    }

    func verifyCleanupAcknowledgedState() throws {
        guard let value = try binding(), value.pending == nil,
              value.fingerprint == (try AppRecordDataset.fingerprint()),
              !(value.retiring ?? []).isEmpty, requested, title == "保存済み",
              detail?.contains("以前の保存データの整理") == true else { throw ToolBackupError.storage }
    }

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
            ToolBackupFiles.directory(id).appendingPathComponent("uploaded.json"), maximum: ToolBackupIndex.maximumReceiptBytes))
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
    @State private var showsSubscriptionManagement = false
    init(configuration: ManagedPreservationConfiguration = .current, client: ManagedPreservationClient? = nil,
         persistence: AppRecordPersistence = .shared) {
        _authentication = StateObject(wrappedValue: ManagedPreservationCoordinator(configuration: configuration, client: client, purpose: .account))
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
                    if authentication.membership?.linked == true {
                        Button("Appleの契約を確認") { showsSubscriptionManagement = true }
                            .disabled(authentication.isBusy)
                            .accessibilityIdentifier("app-record-membership-manage")
                    }
                } header: { Text("会員情報") }
            }
            Section {
                NavigationLink("以前の保管記録・書き出し・アカウント管理") { ManagedPreservationView() }
            } footer: {
                Text("以前に保存したコピーは残っています。会員終了後も既存記録の取り出しはできます。")
            }
        }
        .navigationTitle("保存・復元")
        .manageSubscriptionsSheet(isPresented: $showsSubscriptionManagement)
        .onChange(of: showsSubscriptionManagement) { _, presented in
            if !presented { authentication.checkMembership() }
        }
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
            .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)
                .receive(on: DispatchQueue.main)) { _ in
                    Task { await persistence.appleCredentialRevoked() }
                }
    }
}

@MainActor
enum AppRecordCapture {
    static func prepare(owner: String, origin: String, previous: ToolBackupIndex?, indexVersion: Int = 3) async throws -> ToolBackupFiles.Saved {
        guard indexVersion >= (previous?.version ?? 3) else { throw ManagedPreservationError.servicePaused }
        try AppRecordDataset.requireScope(owner: owner, origin: origin)
        try FamilyNotebookBackup.refresh()
        let source = AppRecordDataset.control.appendingPathComponent("preparing/" + UUID().uuidString, isDirectory: true)
        try ToolBackupFiles.protect(source)
        defer { try? FileManager.default.removeItem(at: source) }
        let previouslyStoredPhotos = Set(previous?.files.filter { $0.path.hasSuffix(".jpg") }.map(\.path) ?? [])
        for (tool, manifest) in ToolBackupIndex.manifests {
            let live = tool == "CatIdentity" ? AppRecordDataset.identityURL() : AppRecordDataset.directory(tool).appendingPathComponent(manifest)
            guard let live else { throw ToolBackupError.invalid }
            guard FileManager.default.fileExists(atPath: live.path) else {
                try AppRecordDataset.requireMissingManifestIsEmpty(tool, at: live)
                continue
            }
            var bytes = try AppRecordJSON.read(live)
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
                var state = try JSONDecoder().decode(PhotoMemoryNoteSnapshot.self, from: bytes)
                guard (2...4).contains(state.schemaVersion) else { throw ToolBackupError.invalid }
                var portable: [String: PhotoMemoryNote] = [:]
                for (identifier, input) in state.notes {
                    var note = input
                    let id = note.id
                    let name = id.uuidString + ".jpg"
                    if indexVersion == 4, previouslyStoredPhotos.contains(tool + "/" + name) {
                        // A missing local cache cannot authorize replacing the
                        // immutable saved copy with a newly edited PhotoKit asset.
                        note.photoFile = name; portable["saved:" + id.uuidString] = note; continue
                    }
                    let cache = live.deletingLastPathComponent().appendingPathComponent(name)
                    if !FileManager.default.fileExists(atPath: cache.path), !identifier.hasPrefix("saved:") {
                        do {
                            let photo = try await PhotoLibraryJPEGExporter().export(localIdentifier: identifier)
                            try AppRecordDataset.writeBackedUp(photo.jpeg, to: cache)
                        } catch is MemoryPhotoJPEGExportError { /* Text survives an unavailable original. */ }
                    }
                    if FileManager.default.fileExists(atPath: cache.path) { note.photoFile = name }
                    portable["saved:" + id.uuidString] = note
                }
                state.notes = portable
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                bytes = try encoder.encode(state)
            } else if tool == "CatCare" {
                bytes = try CatCareDecoding.portable(bytes)
            } else if tool == "ShowcasePhotos" {
                let object = try JSONSerialization.jsonObject(with: bytes)
                var state = object as? [String: Any] ?? ["entries": object, "scopes": [:]]
                guard var entries = state["entries"] as? [[String: Any]] else { throw ToolBackupError.invalid }
                for i in entries.indices { entries[i]["isRestoredCopy"] = true }
                state["entries"] = entries
                bytes = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
            }
            for name in try ToolBackupFiles.manifestPhotoNames(tool: tool, data: bytes) {
                try ToolBackupIndex.validatePath(tool + "/" + name)
                if indexVersion == 4, previouslyStoredPhotos.contains(tool + "/" + name) { continue }
                let photo = try ToolBackupFiles.read(ToolBackupFiles.sourcePhotoURL(tool: tool, directory: live.deletingLastPathComponent(), name: name), maximum: 20 * 1024 * 1024)
                try ToolBackupFiles.write(photo, to: source.appendingPathComponent(tool + "/" + name))
            }
            let destination = source.appendingPathComponent(tool + "/" + manifest)
            try ToolBackupFiles.protect(destination.deletingLastPathComponent())
            if indexVersion == 4 && ["PhotoMemoryNotes", "VeterinaryVisits", "CatCare", "FamilyNotebook"].contains(tool) {
                try AppRecordJSON.write(bytes, to: destination, options: [.atomic, .completeFileProtection])
            } else { try ToolBackupFiles.write(bytes, to: destination) }
        }
        let reusable = previous?.files.map { file -> ToolBackupIndex.File in
            var value = file; value.sourceSnapshotID = file.sourceSnapshotID ?? previous!.snapshotID; return value
        } ?? []
        var saved = try ToolBackupFiles.capture(owner: owner, source: source, reusablePhotos: reusable, indexVersion: indexVersion,
                                               previousIndex: previous, consumePreparedPhotos: true)
        if let previous, indexVersion == 3 {
            var index = saved.index; index.previousIndexID = previous.snapshotID
            saved = ToolBackupFiles.Saved(owner: saved.owner, index: index)
            try ToolBackupFiles.write(JSONEncoder().encode(saved), to: ToolBackupFiles.directory(saved.id).appendingPathComponent("pending.json"))
            try ToolBackupFiles.write(JSONEncoder().encode(index), to: ToolBackupFiles.directory(saved.id).appendingPathComponent("index-wire.json"))
        }
        try await ToolBackupValidation.validate(saved.index, at: ToolBackupFiles.directory(saved.id), authenticatedPhotos: reusable)
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
    private var rejectVisibleInventory = false
    func simulateArchiveListingConflict() { rejectVisibleInventory = true }
    private var maximumIndexVersion = 4
    func useIndexVersion(_ version: Int) { maximumIndexVersion = version }
    private var metadataBatchMode = false
    private var interruptMetadataPart = false
    private var metadataUncovered = false
    private var metadataManifest: [UUID: String] = [:]
    private var metadataBatchID: UUID?
    private var metadataBodies: [UUID: String] = [:]
    private var metadataFinishPending = false
    private var metadataPublications = 0
    private var metadataReplays = 0
    private var metadataRecoveries = 0
    func useMetadataBatches() { metadataBatchMode = true; interruptMetadataPart = true }
    func metadataCounts() -> (publications: Int, replays: Int, uncovered: Bool) {
        (metadataPublications, metadataReplays, metadataUncovered)
    }
    var records: [UUID: [String: Any]] = [:]
    var deleted = Set<UUID>()
    var claimed = Set<UUID>()
    var abandoned = Set<UUID>()
    var requests = 0
    var photoPuts = 0
    private var indexReads: [UUID: Int] = [:]
    private var indexRateLimitCountdown: Int?
    private var indexRateLimitResponses = 0
    private var generation = 0
    private var selectedPageSizes: [Int] = []
    private var payloadReads = 0
    func restoreReads() -> (pages: [Int], individualPayloads: Int) { (selectedPageSizes, payloadReads) }
    func indexReadCounts() -> [UUID: Int] { indexReads }
    func rateLimitIndexOnce(after successfulReads: Int) { indexRateLimitCountdown = successfulReads }
    func indexRateLimits() -> Int { indexRateLimitResponses }
    private var cancelNextDeletion = false
    private var cancelNextHead = false
    private var cleanupCommit: (@Sendable () throws -> Void)?
    func cancelDeletionOnce() { cancelNextDeletion = true }
    func cancelHeadOnce() { cancelNextHead = true }
    func commitDuringCleanup(_ commit: @escaping @Sendable () throws -> Void) { cleanupCommit = commit }
    func counts() -> (Int, Int) { (requests, photoPuts) }
    func advanceHeadRevision() throws {
        guard let id = records.first(where: { _, row in
            guard let doc = row["document"] as? [String: Any], let text = doc["text"] as? String,
                  let bytes = text.data(using: .utf8), let head = try? JSONDecoder().decode(AppRecordHead.self, from: bytes) else { return false }
            return head.kind == "app-records-v1"
        })?.key, var row = records[id], let revision = row["revision"] as? Int else { throw ToolBackupError.invalid }
        row["revision"] = revision + 1; records[id] = row; generation += 1
    }
    func request(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests += 1
        guard let url = request.url, url.host?.hasSuffix(".app-record-fixture.invalid") == true else { throw ToolBackupError.invalid }
        func response(_ json: [String: Any], _ code: Int = 200) throws -> (Data, URLResponse) {
            (try JSONSerialization.data(withJSONObject: json), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!)
        }
        func failure(_ code: String, _ status: Int) throws -> (Data, URLResponse) { try response(["error": ["code": code]], status) }
        if url.path == "/v1/tool-metadata-batches/recovery" {
            guard metadataBatchMode, metadataBatchID != nil else { return try failure("TOOL_METADATA_BATCH_NOT_FOUND", 404) }
            metadataUncovered = false; metadataRecoveries += 1
            return try response(["status": "inventory-ready"])
        }
        if metadataBatchMode, url.path == "/v1/tool-metadata-batches" {
            guard let body = request.httpBody,
                  let input = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let rawID = input["batchId"] as? String, let id = UUID(uuidString: rawID),
                  let entries = input["items"] as? [[String: String]], (1...16).contains(entries.count) else { throw ToolBackupError.invalid }
            var manifest: [UUID: String] = [:]
            for entry in entries {
                guard let raw = entry["recordId"], raw == raw.lowercased(), let record = UUID(uuidString: raw),
                      let hash = entry["bodySHA256"], hash.count == 64, manifest[record] == nil else { throw ToolBackupError.invalid }
                manifest[record] = hash
            }
            if metadataBatchID == id {
                guard metadataManifest == manifest else { throw ToolBackupError.invalid }
            } else {
                guard !metadataUncovered else { throw ToolBackupError.invalid }
                metadataBatchID = id; metadataManifest = manifest; metadataFinishPending = false
            }
            return try response(["batchId": rawID, "status": "open"])
        }
        if metadataBatchMode, url.path.hasPrefix("/v1/tool-metadata-batches/") {
            let path = url.pathComponents
            guard path.count >= 5, let batch = UUID(uuidString: path[3]), batch == metadataBatchID else { throw ToolBackupError.invalid }
            if path[4] == "finish" {
                guard metadataManifest.allSatisfy({ metadataBodies[$0.key] == $0.value }) else { throw ToolBackupError.invalid }
                if !metadataFinishPending {
                    metadataFinishPending = true
                    return try response(["batchId": batch.uuidString.lowercased(), "status": "pending"])
                }
                metadataUncovered = false; metadataPublications += 1
                return try response(["batchId": batch.uuidString.lowercased(), "status": "parts-ready"])
            }
            guard path.count == 6, path[4] == "parts", let id = UUID(uuidString: path[5]),
                  let body = request.httpBody, metadataManifest[id] == ToolBackupIndex.hash(body),
                  let input = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  input["photoBase64"] is NSNull, input["expectedRevision"] is NSNull,
                  let document = input["document"] as? [String: Any], document["toolBackup"] != nil else { throw ToolBackupError.invalid }
            if let old = records[id] {
                guard NSDictionary(dictionary: old["document"] as! [String: Any]).isEqual(to: document) else { throw ToolBackupError.invalid }
                metadataReplays += 1
            } else {
                records[id] = ["recordId": id.uuidString.lowercased(), "revision": 1, "document": document,
                    "photoBase64": NSNull(), "photoSHA256": NSNull()]
                generation += 1
            }
            metadataBodies[id] = ToolBackupIndex.hash(body); metadataUncovered = true
            if interruptMetadataPart { interruptMetadataPart = false; throw CancellationError() }
            return try response(["batchId": batch.uuidString.lowercased(), "recordId": id.uuidString.lowercased(), "revision": 1, "status": "part-staged"])
        }
        if metadataUncovered { return try failure("SESSION_INVALID", 401) }
        func references(_ record: [String: Any]) -> Set<UUID> {
            guard let document = record["document"] as? [String: Any] else { return [] }
            if let text = document["text"] as? String, let data = text.data(using: .utf8),
               let head = try? JSONDecoder().decode(AppRecordHead.self, from: data) { return [head.snapshotID] }
            guard let part = document["toolBackup"] as? [String: Any], part["kind"] as? String == "index",
                  let payload = part["payload"] as? String, let data = Data(base64Encoded: payload) else { return [] }
            if let node = try? JSONDecoder().decode(ToolBackupTree.Node.self, from: data), node.version == 4 {
                return Set((node.files ?? []).flatMap(\.records) + (node.children ?? []).map(\.snapshotID))
            }
            return Set((try? JSONDecoder().decode(ToolBackupIndex.self, from: data).files.flatMap(\.records)) ?? [])
        }
        func referenced(_ id: UUID) -> Bool { records.values.contains { references($0).contains(id) } }
        if url.path == "/v1/tool-cleanup" {
            if let commit = cleanupCommit { cleanupCommit = nil; try commit() }
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
                "toolSnapshots": ["maximumIndexVersion": maximumIndexVersion, "strictPartDeletion": true, "metadataBatchVersion": metadataBatchMode ? 1 : 0],
                "storage": ["usedBytes": 0, "reservedBytes": 0, "limitBytes": 100000000,
                    "availableBytes": 100000000, "overLimit": false],
                "records": ["saved": records.count, "pending": 0, "maximumRecords": 200, "creationLimitReached": false]])
        }
        if url.path == "/v1/records" {
            if rejectVisibleInventory,
               URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "view" && $0.value == "visible" }) == true {
                return try failure("ARCHIVE_CHANGED", 409)
            }
            let items = records.values.sorted { ($0["recordId"] as! String) < ($1["recordId"] as! String) }
            return try response(["items": items, "nextCursor": NSNull(), "generation": requests])
        }
        if request.httpMethod == "GET", url.path == "/v1/export-page" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let selection = query.first(where: { $0.name == "ids" })?.value else { throw ToolBackupError.invalid }
            let ids = selection.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            guard !ids.isEmpty, ids.count <= 50, Set(ids).count == ids.count,
                  ids.allSatisfy({ records[$0] != nil }) else { throw ToolBackupError.invalid }
            if let expected = query.first(where: { $0.name == "generation" })?.value, expected != String(generation) {
                return try failure("ARCHIVE_CHANGED", 409)
            }
            selectedPageSizes.append(ids.count)
            var lines: [[String: Any]] = [["version": 1, "type": "header", "generation": generation, "totalRecords": ids.count]]
            for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
                var row = records[id]!; row["type"] = "record"; lines.append(row)
            }
            lines.append(["type": "complete", "generation": generation, "recordCount": ids.count, "nextCursor": NSNull()])
            var bytes = Data()
            for line in lines { bytes.append(try JSONSerialization.data(withJSONObject: line)); bytes.append(10) }
            return (bytes, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/x-ndjson"])!)
        }
        guard let id = UUID(uuidString: url.lastPathComponent) else { throw ToolBackupError.invalid }
        if request.httpMethod == "PUT" {
            guard !deleted.contains(id), let body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any],
                  let document = body["document"] as? [String: Any] else { return try failure("REVISION_CONFLICT", 409) }
            if let part = document["toolBackup"] as? [String: Any], let source = part["snapshotId"] as? String,
               let snapshot = UUID(uuidString: source), abandoned.contains(snapshot) { return try failure("TOOL_SNAPSHOT_ABANDONED", 409) }
            let expected = body["expectedRevision"] as? Int
            if document["text"] is String, document["toolBackup"] == nil, cancelNextHead {
                cancelNextHead = false; throw CancellationError()
            }
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
            generation += 1
            return try response(["recordId": id.uuidString.lowercased(), "revision": revision])
        }
        if request.httpMethod == "DELETE" {
            if cancelNextDeletion { cancelNextDeletion = false; throw CancellationError() }
            guard let old = records[id] else { return try failure("RECORD_NOT_FOUND", 404) }
            guard !referenced(id) else { return try failure("TOOL_PART_REFERENCED", 409) }
            records.removeValue(forKey: id); deleted.insert(id)
            generation += 1
            for partID in references(old) where !referenced(partID) { claimed.insert(partID) }
            return try response(["recordId": id.uuidString.lowercased(), "revision": (old["revision"] as! Int) + 1])
        }
        guard let record = records[id] else { return try failure("RECORD_NOT_FOUND", 404) }
        if let document = record["document"] as? [String: Any],
           let part = document["toolBackup"] as? [String: Any], part["kind"] as? String == "index" {
            indexReads[id, default: 0] += 1
            if let remaining = indexRateLimitCountdown {
                if remaining == 0 {
                    indexRateLimitCountdown = nil; indexRateLimitResponses += 1
                    return try failure("RATE_LIMITED", 429)
                }
                indexRateLimitCountdown = remaining - 1
            }
        } else if let document = record["document"] as? [String: Any], document["toolBackup"] != nil { payloadReads += 1 }
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
    func verifyMetadataBatchResume() async throws {
        Self.preparationPhase = "集約保存を中断"
        await server.useMetadataBatches()
        await persistence.enable()
        let client = authenticationClient()
        guard let owner = try await client.sessionOwnerID(), let pending = try ToolBackupFiles.pending(owner: owner),
              persistence.title != "保存済み", await server.metadataCounts().uncovered else { throw ToolBackupError.storage }
        let journal = ToolBackupFiles.directory(pending.id).appendingPathComponent("metadata-batch.json")
        let batch = try JSONDecoder().decode(ManagedPreservationClient.MetadataBatch.self,
            from: ToolBackupFiles.read(journal, maximum: 12 * 1024 * 1024))
        guard try ToolBackupFiles.sent(pending).isDisjoint(with: Set(batch.items.map(\.recordID))) else { throw ToolBackupError.storage }
        Self.preparationPhase = "未ACKの送信を通常の同期から再開"
        await persistence.retry()
        let counts = await server.metadataCounts()
        guard persistence.title == "保存済み", counts.publications > 0, counts.replays > 0, !counts.uncovered,
              !FileManager.default.fileExists(atPath: journal.path) else { throw ToolBackupError.storage }
        Self.preparationPhase = "集約保存のheadと復元を照合"
        let headID = AppRecordHead.id(origin: configuration.origin!.absoluteString, owner: owner)
        let head = try AppRecordHead.decode(await client.detail(headID).document)
        let record = try await client.detail(head.snapshotID).record
        let restored = try await ToolBackupTransfer.restore(record, client: client) { _, _ in }
        guard restored.index.version == 4, restored.index.files.contains(where: { $0.path == "CareHandoff/plan.json" }),
              restored.index.files.contains(where: { $0.path.hasSuffix(".jpg") }) else { throw ToolBackupError.invalid }
        Self.preparationPhase = "端末移行による作業ファイル欠落を検査"
        let noteURL = AppRecordDataset.directory("PhotoMemoryNotes").appendingPathComponent("state.json")
        var notes = try JSONDecoder().decode(PhotoMemoryNoteSnapshot.self, from: AppRecordJSON.read(noteURL))
        guard let key = notes.notes.keys.first, let previous = notes.notes[key] else { throw ToolBackupError.invalid }
        var note = PhotoMemoryNote(id: previous.id, text: previous.text + " 集約保存の再構築", updatedAt: .now,
            revision: UUID().uuidString, writtenAt: previous.writtenAt, context: previous.context, weight: previous.weight)
        note.photoFile = previous.photoFile
        notes.notes[key] = note
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try AppRecordJSON.write(encoder.encode(notes), to: noteURL, options: [.atomic, .completeFileProtection])
        await server.useMetadataBatches()
        await persistence.retry()
        guard await server.metadataCounts().uncovered, let missing = try ToolBackupFiles.pending(owner: owner) else { throw ToolBackupError.storage }
        let staging = ToolBackupFiles.directory(missing.id)
        // Only this isolated DEBUG fixture's excluded transport files disappear;
        // the live notes/photos and last published head remain present.
        try FileManager.default.removeItem(at: staging.appendingPathComponent("metadata-batch.json"))
        try FileManager.default.removeItem(at: staging.appendingPathComponent("pending.json"))
        await persistence.retry()
        guard persistence.title == "保存済み", !(await server.metadataCounts().uncovered) else { throw ToolBackupError.storage }
        let rebuiltHead = try AppRecordHead.decode(await client.detail(headID).document)
        guard rebuiltHead.snapshotID != head.snapshotID,
              try AppRecordJSON.read(noteURL) == encoder.encode(notes) else { throw ToolBackupError.invalid }
    }
    func verifyPartitionedMigrationAndRestore() async throws {
        Self.preparationPhase = "旧形式を保存"
        await server.useIndexVersion(3)
        await persistence.enable()
        guard persistence.title == "保存済み" else { throw ToolBackupError.storage }
        let client = authenticationClient()
        guard let owner = try await client.sessionOwnerID() else { throw ToolBackupError.invalid }
        let headID = AppRecordHead.id(origin: configuration.origin!.absoluteString, owner: owner)
        let oldHead = try AppRecordHead.decode(await client.detail(headID).document)
        let oldIndex = try await ToolBackupTransfer.loadIndex(client.detail(oldHead.snapshotID).record, client: client)
        guard oldIndex.version == 3 else { throw ToolBackupError.invalid }
        let oldFolder = ToolBackupFiles.directory(oldIndex.snapshotID)
        let restoredMarker = oldFolder.appendingPathComponent("contents/restored.json")
        let oldReceipt = try ToolBackupFiles.read(oldFolder.appendingPathComponent("uploaded.json"), maximum: ToolBackupIndex.maximumReceiptBytes)
        try ToolBackupFiles.write(oldReceipt, to: restoredMarker)
        let restoredPayload = oldFolder.appendingPathComponent("contents/preserve-fixture.bin")
        try ToolBackupFiles.write(Data("original restored bytes".utf8), to: restoredPayload)
        let url = AppRecordDataset.directory("PhotoMemoryNotes").appendingPathComponent("state.json")
        var state = try JSONDecoder().decode(PhotoMemoryNoteSnapshot.self, from: AppRecordJSON.read(url))
        guard let oldNote = state.notes.values.first, let name = oldNote.photoFile else { throw ToolBackupError.invalid }
        let photo = try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(name))
        // Previous immutable photo must survive a missing local PhotoKit cache.
        try FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent(name))
        for i in 0..<400 {
            let id = UUID()
            var note = PhotoMemoryNote(id: id, text: String(repeating: "猫", count: 100) + "\(i)", updatedAt: .now, revision: UUID().uuidString)
            if i < 130 {
                note.photoFile = id.uuidString + ".jpg"
                try ToolBackupFiles.write(photo, to: url.deletingLastPathComponent().appendingPathComponent(note.photoFile!))
            }
            state.notes["saved:" + id.uuidString] = note
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try AppRecordJSON.write(encoder.encode(state), to: url, options: [.atomic, .completeFileProtection])
        Self.preparationPhase = "小分けの形式へ移行"
        await server.useIndexVersion(4)
        await persistence.retry()
        guard persistence.title == "保存済み" else { throw ToolBackupError.storage }
        try verifyRetiredMetadata(oldIndex.snapshotID)
        guard try Data(contentsOf: restoredMarker) == oldReceipt,
              try Data(contentsOf: restoredPayload) == Data("original restored bytes".utf8) else { throw ToolBackupError.invalid }
        let head = try AppRecordHead.decode(await client.detail(headID).document)
        let beforeWarmRead = await server.indexReadCounts()
        let index = try await ToolBackupTransfer.loadIndex(client.detail(head.snapshotID).record, client: client)
        let afterWarmRead = await server.indexReadCounts()
        guard index.version == 4, (index.nodes?.count ?? 0) > 1,
              afterWarmRead[head.snapshotID, default: 0] == beforeWarmRead[head.snapshotID, default: 0] + 1,
              afterWarmRead.filter({ $0.key != head.snapshotID }) == beforeWarmRead.filter({ $0.key != head.snapshotID }),
              index.files.contains(where: { $0.path.hasSuffix(".json") && $0.path != "PhotoMemoryNotes/state.json" && $0.path.hasPrefix("PhotoMemoryNotes/") }),
              index.files.first(where: { $0.path == "PhotoMemoryNotes/" + name }) == oldIndex.files.first(where: { $0.path == "PhotoMemoryNotes/" + name }).map({ file in
                  var value = file; value.sourceSnapshotID = value.sourceSnapshotID ?? oldIndex.snapshotID; return value
              }) else { throw ToolBackupError.invalid }
        Self.preparationPhase = "変更がない写真の再送を確認"
        let (_, before) = await server.counts()
        let selected = state.notes.first(where: { $0.key.hasPrefix("saved:") })!
        _ = try await PhotoMemoryNoteStore.shared.save(text: "編集した記録", for: selected.key, expectedRevision: selected.value.revision)
        await persistence.retry()
        let (_, after) = await server.counts()
        guard persistence.title == "保存済み", before == after else { throw ToolBackupError.storage }
        try verifyRetiredMetadata(index.snapshotID)
        let expected = try await PhotoMemoryNoteStore.shared.records()
        let original = try AppRecordJSON.read(url)
        Self.preparationPhase = "新しい端末で復元"
        persistence.setActive(false)
        try AppRecordDataset.nextFixtureDevice()
        let next = AppRecordFixture(configuration: configuration, server: server, profiles: profiles)
        // The new device has neither the upload receipt nor restored contents.
        // Interrupt the production 429 wait, then reuse only verified metadata
        // from the same owner and freshly fetched root on the next attempt.
        let nextClient = next.authenticationClient()
        let latestHead = try AppRecordHead.decode(await nextClient.detail(headID).document)
        let rootRecord = try await nextClient.detail(latestHead.snapshotID).record
        let coldBefore = await server.indexReadCounts()
        await server.rateLimitIndexOnce(after: 3)
        Self.preparationPhase = "一覧の通信待ちを中断"
        let interrupted = Task { try await ToolBackupTransfer.loadIndex(rootRecord, client: nextClient) }
        for _ in 0..<100 {
            if await server.indexRateLimits() == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard await server.indexRateLimits() == 1 else {
            interrupted.cancel(); throw ToolBackupError.invalid
        }
        interrupted.cancel()
        do { _ = try await interrupted.value; throw ToolBackupError.invalid }
        catch is CancellationError { }
        let interruptedReads = await server.indexReadCounts()
        let readIDs = interruptedReads.keys.filter { interruptedReads[$0, default: 0] > coldBefore[$0, default: 0] }
        guard readIDs.count == 4 else { throw ToolBackupError.invalid }
        Self.preparationPhase = "一覧を続きから再開して通信制限を待つ"
        let freshRoot = try await nextClient.detail(latestHead.snapshotID).record
        await server.rateLimitIndexOnce(after: 2)
        let resumed = try await ToolBackupTransfer.loadIndex(freshRoot, client: nextClient)
        let resumedReads = await server.indexReadCounts()
        // Three successful reads survive cancellation. The failed fourth read
        // is fetched again; the second 429 is retried by the real 60s policy.
        guard await server.indexRateLimits() == 2,
              readIDs.filter({ resumedReads[$0] == interruptedReads[$0] }).count == 3,
              resumed.version == 4, resumed.snapshotID == latestHead.snapshotID else { throw ToolBackupError.invalid }
        Self.preparationPhase = "壊れた一覧の一部分だけを再取得"
        let damagedID = readIDs.first!
        let damagedReceipt = ToolBackupFiles.root.appendingPathComponent("index-node-cache-v4/" + damagedID.uuidString + ".json")
        try ToolBackupFiles.write(Data("broken fixture receipt".utf8), to: damagedReceipt)
        let repaired = try await ToolBackupTransfer.loadIndex(nextClient.detail(latestHead.snapshotID).record, client: nextClient)
        let repairedReads = await server.indexReadCounts()
        guard repaired == resumed,
              repairedReads[damagedID, default: 0] == resumedReads[damagedID, default: 0] + 1,
              repairedReads[latestHead.snapshotID, default: 0] == resumedReads[latestHead.snapshotID, default: 0] + 1,
              repairedReads.filter({ $0.key != damagedID && $0.key != latestHead.snapshotID }) == resumedReads.filter({ $0.key != damagedID && $0.key != latestHead.snapshotID }) else { throw ToolBackupError.invalid }
        Self.preparationPhase = "検証済みの一覧から新しい端末へ復元"
        // Retain the interrupted/resumed metadata assertions above, then drive
        // a genuinely cold paged restore rather than hiding it behind that cache.
        for part in repaired.nodes ?? [] where part.snapshotId != latestHead.snapshotID.uuidString.lowercased() {
            let cache = ToolBackupFiles.root.appendingPathComponent("index-node-cache-v4/" + part.snapshotId.uppercased() + ".json")
            if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
        }
        let readsBefore = await server.restoreReads()
        await next.persistence.enable()
        guard next.persistence.title == "復元しました" else {
            Self.preparationPhase += " / \(next.persistence.title) / \(next.persistence.detail ?? "説明なし")"
            throw ToolBackupError.storage
        }
        let readsAfter = await server.restoreReads()
        let pages = Array(readsAfter.pages.dropFirst(readsBefore.pages.count))
        guard pages.count > 2, pages.allSatisfy({ (1...50).contains($0) }),
              pages.count < repaired.recordIDs.count / 10,
              readsAfter.individualPayloads == readsBefore.individualPayloads else { throw ToolBackupError.invalid }
        let restored = try await PhotoMemoryNoteStore.shared.records()
        let actual = Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0.note) })
        guard actual.count == expected.count, expected.allSatisfy({ actual[$0.id] == $0.note }),
              try AppRecordJSON.read(url) == original else { throw ToolBackupError.invalid }
        for record in restored where record.note.photoFile != nil {
            guard let file = try await PhotoMemoryNoteStore.shared.photoURL(for: record.id),
                  try Data(contentsOf: file) == photo else { throw ToolBackupError.invalid }
        }
    }
    private func verifyRetiredMetadata(_ id: UUID) throws {
        let folder = ToolBackupFiles.directory(id)
        for name in ["pending.json", "uploaded.json", "index-wire.json", "sent.json", "attempt.json"] {
            guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) else { throw ToolBackupError.storage }
        }
        let sent = folder.appendingPathComponent("sent-v4")
        if FileManager.default.fileExists(atPath: sent.path) {
            guard try FileManager.default.contentsOfDirectory(atPath: sent.path).isEmpty else { throw ToolBackupError.storage }
        }
    }
    func verifyCleanupFailureAndAutomaticResume() async throws {
        Self.preparationPhase = "初回保存"
        await persistence.enable()
        guard persistence.title == "保存済み" else { throw ToolBackupError.storage }
        Self.preparationPhase = "保存完了の境界"
        try await persistence.verifyAcceptedSaveFences()
        let repository = try CareHandoffRepository(directory: AppRecordDataset.directory("CareHandoff"))
        let url = AppRecordDataset.directory("CareHandoff").appendingPathComponent("plan.json")
        var plan = try JSONDecoder().decode(CareHandoffPlan.self, from: Data(contentsOf: url))
        await server.cancelDeletionOnce()
        Self.preparationPhase = "保存完了後の中断"
        plan.contact += " 整理中断後も保存完了"
        try repository.commit(plan, newPhotos: [:])
        await persistence.retry()
        try persistence.verifyCleanupAcknowledgedState()
        guard let owner = try await authenticationClient().sessionOwnerID(),
              !(try ToolBackupFiles.pendingDeletions(owner: owner)).isEmpty else { throw ToolBackupError.storage }
        // Foreground resume drives the production loop; no recheck button.
        persistence.setActive(true)
        Self.preparationPhase = "整理の自動再開"
        for _ in 0..<100 {
            if !persistence.busy, persistence.title == "保存済み", persistence.detail == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        persistence.setActive(false)
        guard persistence.title == "保存済み", persistence.detail == nil,
              try ToolBackupFiles.pendingDeletions(owner: owner).isEmpty else { throw ToolBackupError.storage }
        await server.cancelHeadOnce()
        Self.preparationPhase = "保存完了前の中断"
        plan.contact += " 送信中断"
        try repository.commit(plan, newPhotos: [:])
        await persistence.retry()
        guard persistence.title == "未送信の変更があります",
              persistence.detail?.contains("自動で再開") == true else { throw ToolBackupError.storage }
        persistence.setActive(true)
        Self.preparationPhase = "送信の自動再開"
        for _ in 0..<100 {
            if !persistence.busy, persistence.title == "保存済み", persistence.detail == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        persistence.setActive(false)
        guard persistence.title == "保存済み", persistence.detail == nil else { throw ToolBackupError.storage }
        plan.contact += " 整理と同時に編集"
        Self.preparationPhase = "整理中の新しい編集"
        let editedBytes = try JSONEncoder().encode(plan)
        await server.commitDuringCleanup {
            try AppRecordDataset.writeBackedUp(editedBytes, to: url)
            AppRecordDataset.committed(url)
        }
        await persistence.retry()
        guard persistence.title == "変更を保存待ち", persistence.detail != nil else { throw ToolBackupError.storage }
        await persistence.retry()
        guard persistence.title == "保存済み" else { throw ToolBackupError.storage }
    }
    static func verifyDeletionJournalRoundTrip() throws {
        let bytes = Data("{}".utf8)
        let owner = "deletion-journal-fixture-owner"
        let index = ToolBackupIndex(version: 3, snapshotID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_792_262_900.1234567),
            files: [.init(path: "CareHandoff/plan.json", bytes: bytes.count,
                          sha256: ToolBackupIndex.hash(bytes), records: [UUID()])])
        let saved = ToolBackupFiles.Saved(owner: owner, index: index)
        let journal = try ToolBackupFiles.deletionJournal(index, owner: owner)
        try ToolBackupFiles.write(JSONEncoder().encode(saved), to: journal)
        defer { try? FileManager.default.removeItem(at: journal) }
        let listed = try FileManager.default.contentsOfDirectory(at: ToolBackupFiles.root,
            includingPropertiesForKeys: nil).first { $0.lastPathComponent == journal.lastPathComponent }
        let decoded = try JSONDecoder().decode(ToolBackupFiles.Saved.self,
            from: ToolBackupFiles.read(journal, maximum: ToolBackupIndex.maximumReceiptBytes))
        let recomputed = try ToolBackupFiles.deletionJournal(decoded.index, owner: decoded.owner)
        preparationPhase = "基底付きURLと列挙されたURLの照合"
        guard let listed, listed != recomputed,
              listed.standardizedFileURL.path == recomputed.standardizedFileURL.path,
              try ToolBackupFiles.read(listed, maximum: ToolBackupIndex.maximumReceiptBytes) == ToolBackupFiles.read(recomputed, maximum: ToolBackupIndex.maximumReceiptBytes)
        else { throw ToolBackupError.storage }
        let relative = URL(string: journal.lastPathComponent, relativeTo: ToolBackupFiles.root)!
        let absolute = URL(fileURLWithPath: relative.path)
        guard relative != absolute, relative.standardizedFileURL.path == absolute.standardizedFileURL.path,
              try ToolBackupFiles.read(relative, maximum: ToolBackupIndex.maximumReceiptBytes) == ToolBackupFiles.read(absolute, maximum: ToolBackupIndex.maximumReceiptBytes)
        else { throw ToolBackupError.storage }
        preparationPhase = "urlEqual=\(listed == journal) pathEqual=\(listed.standardizedFileURL.path == journal.standardizedFileURL.path) indexEqual=\(decoded.index == index) hashEqual=\(recomputed.lastPathComponent == journal.lastPathComponent)"
        print("APP_RECORD_JOURNAL_PROBE \(preparationPhase)")
        guard try ToolBackupFiles.pendingDeletions(owner: owner).contains(where: { $0.id == index.snapshotID }) else {
            throw ToolBackupError.invalid
        }
        guard try ToolBackupFiles.pendingDeletions(owner: "another-owner").isEmpty else { throw ToolBackupError.storage }
        try ToolBackupFiles.write(Data("not-json".utf8), to: journal)
        do { _ = try ToolBackupFiles.pendingDeletions(owner: owner); throw ToolBackupError.storage }
        catch ToolBackupJournalError.decode { }
        let altered = ToolBackupFiles.Saved(owner: "altered-owner", index: index)
        try ToolBackupFiles.write(JSONEncoder().encode(altered), to: journal)
        do { _ = try ToolBackupFiles.pendingDeletions(owner: owner); throw ToolBackupError.storage }
        catch ToolBackupJournalError.identity { }
        let changedIndex = ToolBackupIndex(version: index.version, snapshotID: UUID(), createdAt: index.createdAt, files: index.files)
        try ToolBackupFiles.write(JSONEncoder().encode(ToolBackupFiles.Saved(owner: owner, index: changedIndex)), to: journal)
        do { _ = try ToolBackupFiles.pendingDeletions(owner: owner); throw ToolBackupError.storage }
        catch ToolBackupJournalError.identity { }
        guard FileManager.default.fileExists(atPath: journal.path) else { throw ToolBackupError.storage }
        // Restore the exact synthetic bytes; no malformed journal is ignored.
        try ToolBackupFiles.write(JSONEncoder().encode(saved), to: journal)
        guard try ToolBackupFiles.pendingDeletions(owner: owner).count == 1 else { throw ToolBackupError.storage }
        let wrongName = ToolBackupFiles.root.appendingPathComponent("deleting-" + String(repeating: "0", count: 64) + ".json")
        let wrongBytes = try JSONEncoder().encode(saved)
        try ToolBackupFiles.write(wrongBytes, to: wrongName)
        defer { try? FileManager.default.removeItem(at: wrongName) }
        do { _ = try ToolBackupFiles.pendingDeletions(owner: owner); throw ToolBackupError.storage }
        catch ToolBackupJournalError.identity { }
        guard try ToolBackupFiles.read(wrongName, maximum: ToolBackupIndex.maximumReceiptBytes) == wrongBytes
        else { throw ToolBackupError.storage }
        try FileManager.default.removeItem(at: wrongName)
        try FileManager.default.createSymbolicLink(at: wrongName, withDestinationURL: journal)
        do { _ = try ToolBackupFiles.pendingDeletions(owner: owner); throw ToolBackupError.storage }
        catch ToolBackupJournalError.read { }
        try FileManager.default.removeItem(at: wrongName)
        try FileManager.default.createDirectory(at: wrongName, withIntermediateDirectories: false)
        do { _ = try ToolBackupFiles.pendingDeletions(owner: owner); throw ToolBackupError.storage }
        catch ToolBackupJournalError.read { }
        try FileManager.default.removeItem(at: wrongName)
        guard try ToolBackupFiles.pendingDeletions(owner: owner).count == 1 else { throw ToolBackupError.storage }
        try verifyDeletionJournalIdentityInputs(index: index, owner: owner)
        journalIdentityProbe = "sameFileDifferentURL=true legacyJournalMatch=\(listed == recomputed) " + journalIdentityProbe
    }
    static var journalIdentityProbe = ""
    private static func verifyDeletionJournalIdentityInputs(index: ToolBackupIndex, owner: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var mismatches = 0
        // Exercise Date's actual Foundation encode/decode path, including adjacent
        // representable values rather than only the previous fixed timestamp.
        let epoch = Date(timeIntervalSince1970: 1_792_262_900).timeIntervalSinceReferenceDate
        for offset in 0..<4096 {
            let date = Date(timeIntervalSinceReferenceDate: Double(bitPattern: epoch.bitPattern + UInt64(offset)))
            let sample = ToolBackupIndex(version: 3, snapshotID: index.snapshotID, createdAt: date, files: index.files)
            let original = try encoder.encode(sample)
            let decoded = try JSONDecoder().decode(ToolBackupFiles.Saved.self,
                from: JSONEncoder().encode(ToolBackupFiles.Saved(owner: owner, index: sample)))
            if try encoder.encode(decoded.index) != original { mismatches += 1 }
        }
        var observations: [String] = ["dateMismatch=\(mismatches)/4096"]
        let roots = [FileManager.default.temporaryDirectory,
                     FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]]
        for (number, parent) in roots.enumerated() {
            let directory = parent.appendingPathComponent("journal probe 猫-" + UUID().uuidString, isDirectory: true)
            try ToolBackupFiles.protect(directory)
            defer { try? FileManager.default.removeItem(at: directory) }
            let expected = directory.appendingPathComponent("deleting-synthetic.json")
            try ToolBackupFiles.write(Data("{}".utf8), to: expected)
            let listed = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard listed.count == 1, let actual = listed.first else { throw ToolBackupError.storage }
            observations.append("root\(number):url=\(actual == expected),path=\(actual.standardizedFileURL.path == expected.standardizedFileURL.path),resolved=\(actual.resolvingSymlinksInPath().path == expected.resolvingSymlinksInPath().path)")
        }
        journalIdentityProbe = observations.joined(separator: " ")
    }
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
            else {
                VStack {
                    Text(result.isEmpty ? "自動保存の検査を準備中…" : result)
                    if !AppRecordFixture.journalIdentityProbe.isEmpty {
                        Text(AppRecordFixture.journalIdentityProbe).accessibilityIdentifier("journal-identity-probe")
                    }
                }
            }
        }
        .disabled(switching)
        .task {
            if CommandLine.arguments.contains("--app-records-metadata-batch-probe") {
                do {
                    let probe = try await AppRecordFixture.make()
                    try await probe.verifyMetadataBatchResume()
                    result = "集約保存・中断再開・復元を確認しました"
                } catch { result = "集約保存の検査に失敗: \(AppRecordFixture.preparationPhase)" }
                return
            }
            if CommandLine.arguments.contains("--app-records-capacity-probe") {
                do {
                    let probe = try await AppRecordFixture.make()
                    try await probe.verifyPartitionedMigrationAndRestore()
                    result = "容量対応・旧形式の移行・写真とメモの復元を確認しました"
                } catch { result = "容量の検査に失敗: \(AppRecordFixture.preparationPhase)" }
                return
            }
            if CommandLine.arguments.contains("--app-records-cleanup-probe") {
                do {
                    let probe = try await AppRecordFixture.make()
                    try await probe.verifyCleanupFailureAndAutomaticResume()
                    result = "保存完了・中断の区別と自動再開を確認しました"
                } catch { result = "整理の再開検査に失敗: \(AppRecordFixture.preparationPhase)" }
                return
            }
            if CommandLine.arguments.contains("--app-records-journal-probe") {
                do {
                    try AppRecordFixture.verifyDeletionJournalRoundTrip()
                    result = "途中の整理記録を読み直しました"
                } catch { result = "途中の整理記録を読み直せませんでした: \(AppRecordFixture.preparationPhase)" }
                return
            }
            do {
                let prepared = try await AppRecordFixture.make()
                if CommandLine.arguments.contains("--app-records-settings-conflict") {
                    await prepared.server.simulateArchiveListingConflict()
                }
                fixture = prepared; prepared.persistence.setActive(true)
            }
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
