import Foundation

/// Only the current selection's PhotoKit references are persisted. No images,
/// embeddings, timestamps, predictions, or growing history. Never exported.
struct IdentitySelectionArchive {
    let url: URL
    static let writingOptions: Data.WritingOptions = [.atomic, .completeFileProtection]

    static var device: IdentitySelectionArchive {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return IdentitySelectionArchive(url: base.appendingPathComponent("IdentityProbeSelection/selection-v1.json"))
    }

    private struct Payload: Codable {
        let schema: Int
        let slots: [String: [String]]
    }

    func load() throws -> [IdentityPhotoSlot: [String]] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 262_144 else { throw CocoaError(.fileReadCorruptFile) }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: url))
        guard payload.schema == 1,
              payload.slots.keys.allSatisfy({ IdentityPhotoSlot(rawValue: $0) != nil }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let values = Dictionary(uniqueKeysWithValues: payload.slots.map { (IdentityPhotoSlot(rawValue: $0.key)!, $0.value) })
        try Self.validate(values)
        return values
    }

    func save(_ selections: [IdentityPhotoSlot: [String]]) throws {
        try Self.validate(selections)
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        try directory.setResourceValues(excluded)
        let payload = Payload(schema: 1, slots: Dictionary(uniqueKeysWithValues: selections.map { ($0.key.rawValue, $0.value) }))
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url, options: Self.writingOptions)
        var file = url
        try file.setResourceValues(excluded)
    }

    func remove() throws {
        // This exact app-owned file only, invoked by the user's explicit clear action.
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private static func validate(_ selections: [IdentityPhotoSlot: [String]]) throws {
        let all = selections.values.flatMap { $0 }
        guard selections.allSatisfy({ $0.value.count <= $0.key.count }), all.count <= 40,
              Set(all).count == all.count,
              all.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}
