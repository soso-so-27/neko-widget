import Foundation
import CryptoKit

/// Device-local reference. Portable backups never contain an absolute path,
/// a keychain item, an HTTP journal, or an active participation reference.
struct FamilyNotebookLocalBinding: Codable {
    let relativeDirectory: String
    let familyID: UUID
    let deviceID: String
    let author: FamilyNotebookAuthor
    static let key = "familyNotebook.localBinding.v2"
    static let legacyKey = "familyNotebook.localBinding.v1"

    func directory(support: URL) throws -> URL {
        let parts = relativeDirectory.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0].range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              parts[1] == "notebooks", UUID(uuidString: String(parts[2])) == familyID,
              let generation = Int64(parts[3]), (1...1_000_000_000).contains(generation),
              String(generation) == parts[3], FamilyNotebookCore.validIdentifier(deviceID) else { throw FamilyNotebookError.unsafePath }
        return support.appendingPathComponent("FamilyNotebook-v1", isDirectory: true).appendingPathComponent(relativeDirectory, isDirectory: true)
    }
    init(directory: URL, support: URL, familyID: UUID, deviceID: String, author: FamilyNotebookAuthor) throws {
        let path = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let root = support.appendingPathComponent("FamilyNotebook-v1").standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard path.hasPrefix(root) else { throw FamilyNotebookError.unsafePath }
        relativeDirectory = String(path.dropFirst(root.count))
        self.familyID = familyID; self.deviceID = deviceID; self.author = author
        _ = try self.directory(support: support)
    }
    static func load(support: URL, defaults: UserDefaults = .standard) throws -> Self? {
        if let data = defaults.data(forKey: key) {
            let value = try JSONDecoder().decode(Self.self, from: data)
            _ = try value.directory(support: support); return value
        }
        guard let data = defaults.data(forKey: legacyKey) else { return nil }
        struct Legacy: Decodable { let directory: URL; let familyID: UUID; let deviceID: String; let author: FamilyNotebookAuthor }
        let old = try JSONDecoder().decode(Legacy.self, from: data)
        // Only the existing app-owned suffix is portable across iOS container
        // relocation. Validate all four components; never follow the old path.
        let marker = "/Library/Application Support/FamilyNotebook-v1/"
        let currentRoot = support.appendingPathComponent("FamilyNotebook-v1").standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = old.directory.standardizedFileURL.path
        let suffix: String
        if path.hasPrefix(currentRoot) { suffix = String(path.dropFirst(currentRoot.count)) }
        else if let range = path.range(of: marker, options: .backwards) { suffix = String(path[range.upperBound...]) }
        else { throw FamilyNotebookError.unsafePath }
        let value = try Self(directory: support.appendingPathComponent("FamilyNotebook-v1").appendingPathComponent(suffix),
                             support: support, familyID: old.familyID, deviceID: old.deviceID, author: old.author)
        defaults.set(try JSONEncoder().encode(value), forKey: key)
        // Leave the legacy record intact; it is not consulted once v2 exists.
        return value
    }
}

enum FamilyNotebookBackup {
    struct Copy: Codable, Identifiable {
        let id: UUID
        var state: FamilyNotebookStore.State
        var isRestored: Bool? = nil
        var snapshot: FamilyNotebookSnapshot {
            var retained = state; retained.schemaVersion = 2; retained.sharingEnded = true
            return retained.snapshot
        }
    }
    struct Manifest: Codable { var version = 1; var copies: [Copy] }
    static func decode(_ data: Data) throws -> Manifest {
        let value = try JSONDecoder().decode(Manifest.self, from: data)
        guard value.version == 1, value.copies.count <= 1000,
              Set(value.copies.map(\.id)).count == value.copies.count else { throw FamilyNotebookError.corruptStorage }
        for copy in value.copies { try FamilyNotebookStore.validate(copy.state, familyID: copy.state.familyID) }
        return value
    }
    static func encode(_ value: Manifest) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value); _ = try decode(data); return data
    }
    /// A restore is a private retained copy. Keep the complete operation history
    /// and unsent text, while the terminal state prevents outbox transmission.
    static func restored(_ data: Data) throws -> Data {
        let value = try decode(data)
        let copies = value.copies.map { copy -> Copy in
            var state = copy.state; state.schemaVersion = 2; state.sharingEnded = true
            if copy.isRestored == true { return Copy(id: copy.id, state: state, isRestored: true) }
            let digest = Array(SHA256.hash(data: Data(("restored/" + copy.id.uuidString).utf8)))
            let id = UUID(uuid: (digest[0],digest[1],digest[2],digest[3],digest[4],digest[5],digest[6],digest[7],
                                 digest[8],digest[9],digest[10],digest[11],digest[12],digest[13],digest[14],digest[15]))
            return Copy(id: id, state: state, isRestored: true)
        }
        return try encode(.init(copies: copies))
    }
    #if os(iOS)
    static var url: URL { AppRecordDataset.directory("FamilyNotebook").appendingPathComponent("state.json") }
    static func copies() throws -> [Copy] {
        try AppRecordDataset.requirePreviouslyPresentManifest("FamilyNotebook/state.json", at: url)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try decode(AppRecordJSON.read(url)).copies
    }
    static func refresh() throws {
        AppRecordDataset.writeLock.lock(); defer { AppRecordDataset.writeLock.unlock() }
        let manager = FileManager.default, support = AppRecordDataset.support
        var retained = try copies()
        var sources: [(String, URL, UUID)] = []
        func children(_ root: URL) throws -> [URL] {
            guard manager.fileExists(atPath: root.path) else { return [] }
            let values = try root.resourceValues(forKeys: [.isDirectoryKey,.isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw FamilyNotebookError.unsafePath }
            return try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey,.isSymbolicLinkKey]).sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        let real = (Bundle.main.object(forInfoDictionaryKey: "FamilyNotebookProductionEnabled") as? String) == "YES"
        if real, let binding = try FamilyNotebookLocalBinding.load(support: support) {
            let selected = try binding.directory(support: support)
            guard manager.fileExists(atPath: selected.appendingPathComponent("family-notebook.json").path) else {
                throw FamilyNotebookError.storageUnavailable
            }
            let root = selected.deletingLastPathComponent().deletingLastPathComponent()
            // Only this endpoint/person/device scope, never neighboring scopes.
            for family in try children(root) {
                guard let familyID = UUID(uuidString: family.lastPathComponent) else { throw FamilyNotebookError.unsafePath }
                for generation in try children(family) {
                    guard let number = Int64(generation.lastPathComponent), (1...1_000_000_000).contains(number) else { throw FamilyNotebookError.unsafePath }
                    sources.append((String(binding.relativeDirectory.split(separator: "/")[0]) + "/" + family.lastPathComponent + "/" + generation.lastPathComponent,
                                    generation.appendingPathComponent("family-notebook.json"), familyID))
                }
            }
        } else if !real {
            for family in try children(support.appendingPathComponent("FamilyNotebookPrototype")) {
                guard let id = UUID(uuidString: family.lastPathComponent) else { throw FamilyNotebookError.unsafePath }
                sources.append(("prototype/" + family.lastPathComponent,family.appendingPathComponent("family-notebook.json"),id))
            }
        }
        for (key,file,familyID) in sources {
            guard manager.fileExists(atPath: file.path) else { continue }
            let data = try ToolBackupFiles.read(file, maximum: AppRecordJSON.maximumBytes)
            let state = try JSONDecoder().decode(FamilyNotebookStore.State.self, from: data)
            try FamilyNotebookStore.validate(state, familyID: familyID)
            let id = UUID(uuidString: String(AppRecordJSON.name(AppRecordJSON.hash(Data(key.utf8))).dropLast(5)))!
            retained.removeAll { $0.id == id }; retained.append(.init(id: id,state: state))
        }
        guard !retained.isEmpty else { return }
        let data = try encode(.init(copies: retained.sorted { $0.id.uuidString < $1.id.uuidString }))
        if manager.fileExists(atPath: url.path), try AppRecordJSON.read(url) == data { return }
        try AppRecordDataset.requireWritable(url)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AppRecordJSON.write(data, to: url, options: [.atomic,.completeFileProtection])
    }
    #endif
}
