import Foundation

// One bounded selection, not a growing history. Never stores photos or decisions.
struct CandidateSelectionArchive {
    let url: URL
    static var device: Self {
        .init(url: IdentitySelectionArchive.device.url.deletingLastPathComponent().appendingPathComponent("candidate-selection-v1.json"))
    }
    private struct Payload: Codable { let schema: Int; let identifiers: [String] }

    func load() throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 131_072 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: url))
        guard payload.schema == 1 else { throw CocoaError(.fileReadCorruptFile) }
        try Self.validate(payload.identifiers)
        return payload.identifiers
    }

    func save(_ ids: [String]) throws {
        try Self.validate(ids)
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        try directory.setResourceValues(excluded)
        let data = try JSONEncoder().encode(Payload(schema: 1, identifiers: ids))
        try data.write(to: url, options: IdentitySelectionArchive.writingOptions)
        var file = url; try file.setResourceValues(excluded)
    }

    private static func validate(_ ids: [String]) throws {
        guard ids.count <= CandidateReviewSelection.limit, Set(ids).count == ids.count,
              ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 }) else { throw CocoaError(.fileReadCorruptFile) }
    }
}
