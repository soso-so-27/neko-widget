import Foundation
import CryptoKit

// One current batch only. Human decisions are local; no images, model outputs or history.
struct CandidateSavedProgress: Codable, Equatable {
    let referenceFingerprint: String
    let decisions: [String: CandidateReviewChoice]
    let previousDecisions: [String: CandidateReviewChoice]?
    let excluded: Set<String>

    static func fingerprint(_ saved: [IdentityPhotoSlot: [String]]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let refs = ["a": saved[.referenceA] ?? [], "b": saved[.referenceB] ?? []]
        return SHA256.hash(data: try encoder.encode(refs)).map { String(format: "%02x", $0) }.joined()
    }
}

struct CandidateSavedBatch: Codable, Equatable {
    var schema = 2
    let identifiers: [String]
    var progress: CandidateSavedProgress? = nil
}

struct CandidateSelectionArchive {
    let url: URL
    var writeData: ((Data, URL) throws -> Void)? = nil // Injectable I/O failure for focused tests.
    static var device: Self {
        .init(url: IdentitySelectionArchive.device.url.deletingLastPathComponent().appendingPathComponent("candidate-selection-v1.json"))
    }
    func load() throws -> [String] { try loadBatch().identifiers }

    func loadBatch() throws -> CandidateSavedBatch {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init(identifiers: []) }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 524_288 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var batch = try JSONDecoder().decode(CandidateSavedBatch.self, from: Data(contentsOf: url))
        guard batch.schema == 1 || batch.schema == 2,
              batch.schema != 1 || batch.progress == nil else { throw CocoaError(.fileReadCorruptFile) }
        batch.schema = 2 // Read old ID-only selection without rewriting it or inventing decisions.
        try Self.validate(batch)
        return batch
    }

    func save(_ ids: [String]) throws {
        try saveBatch(.init(identifiers: ids))
    }

    func saveBatch(_ batch: CandidateSavedBatch) throws {
        try Self.validate(batch)
        let data = try JSONEncoder().encode(batch)
        guard data.count <= 524_288 else { throw CocoaError(.fileWriteUnknown) }
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        try directory.setResourceValues(excluded)
        if let writeData { try writeData(data, url) }
        else { try data.write(to: url, options: IdentitySelectionArchive.writingOptions) }
        // The parent directory is already excluded. Do not report a failed commit after atomic write.
        var file = url; try? file.setResourceValues(excluded)
    }

    private static func validate(_ batch: CandidateSavedBatch) throws {
        let ids = batch.identifiers
        guard batch.schema == 2, ids.count <= CandidateReviewSelection.limit, Set(ids).count == ids.count,
              ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 }) else { throw CocoaError(.fileReadCorruptFile) }
        if let progress = batch.progress {
            let allowed = Set(ids)
            guard !ids.isEmpty, progress.referenceFingerprint.count == 64,
                  progress.referenceFingerprint.allSatisfy({ "0123456789abcdef".contains($0) }),
                  Set(progress.decisions.keys).isSubset(of: allowed),
                  Set(progress.previousDecisions?.keys.map { $0 } ?? []).isSubset(of: allowed),
                  progress.excluded.isSubset(of: allowed) else { throw CocoaError(.fileReadCorruptFile) }
        }
    }
}
