import Foundation
import CryptoKit

// One bounded study, separate from the development batch. No images, scores or embeddings.
struct CandidateValidationStudy: Codable, Equatable {
    static let limit = 60
    static let protocolKey = "build23-fixed-identity-second-nearest-radius1.25-vision-r2-half-recovery-yolox-s640-gap-v1"
    var schema = 1
    let method: String
    let identityModel: String
    let objectModel: String
    let runtime: String
    let osVersion: String
    let referenceFingerprint: String
    let knownIdentifiers: [String]
    var identifiers: [String] = []
    var decisions: [String: CandidateReviewChoice] = [:]
    var assetStateFingerprint: String
    var sealed = false

    static func fingerprint(_ saved: [IdentityPhotoSlot: [String]]) throws -> String {
        let all = Dictionary(uniqueKeysWithValues: saved.map { ($0.key.rawValue, $0.value) })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return digest(try encoder.encode(all))
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
    var pending: [String] { identifiers.filter { decisions[$0] == nil } }
    func count(_ choice: CandidateReviewChoice) -> Int { decisions.values.filter { $0 == choice }.count }
    var compositionReady: Bool { count(.a) >= 20 && count(.b) >= 20 && count(.both) >= 10 && count(.other) >= 10 }
    var canSeal: Bool { identifiers.count == Self.limit && pending.isEmpty }
    var algorithmMatches: Bool {
        method == Self.protocolKey && identityModel == ProbeModelFile.sha256
            && objectModel == CandidateObjectDetector.modelSHA256 && runtime == IdentityEvaluationCore.expectedRuntimeVersion
            && osVersion == ProcessInfo.processInfo.operatingSystemVersionString
    }
    mutating func append(_ ids: [String], assetFingerprint: String) throws {
        guard !sealed, !ids.isEmpty, ids.count <= CandidateReviewSelection.limit,
              identifiers.count + ids.count <= Self.limit,
              Set(ids).isDisjoint(with: Set(knownIdentifiers + identifiers)) else { throw CocoaError(.fileWriteUnknown) }
        identifiers += ids; assetStateFingerprint = assetFingerprint
        try validate()
    }
    mutating func choose(_ choice: CandidateReviewChoice, id: String) throws {
        guard !sealed, identifiers.contains(id) else { throw CocoaError(.fileWriteUnknown) }
        decisions[id] = choice
    }
    mutating func seal() throws {
        guard !sealed, canSeal else { throw CocoaError(.fileWriteUnknown) }
        sealed = true
    }
    func validate() throws {
        func validIDs(_ ids: [String], limit: Int) -> Bool {
            ids.count <= limit && Set(ids).count == ids.count && ids.allSatisfy { !$0.isEmpty && $0.utf8.count <= 4096 }
        }
        guard schema == 1, !method.isEmpty, method.count <= 256, runtime.count <= 32, osVersion.count <= 256,
              [identityModel, objectModel, referenceFingerprint, assetStateFingerprint].allSatisfy(Self.isDigest),
              validIDs(knownIdentifiers, limit: 64), validIDs(identifiers, limit: Self.limit),
              Set(identifiers).isDisjoint(with: Set(knownIdentifiers)),
              Set(decisions.keys).isSubset(of: Set(identifiers)), !sealed || canSeal else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}

struct CandidateValidationArchive {
    let url: URL
    var writeData: ((Data, URL) throws -> Void)? = nil
    static var device: Self {
        .init(url: IdentitySelectionArchive.device.url.deletingLastPathComponent().appendingPathComponent("candidate-validation-v1.json"))
    }
    func load() throws -> CandidateValidationStudy? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_048_576 else { throw CocoaError(.fileReadCorruptFile) }
        let study = try JSONDecoder().decode(CandidateValidationStudy.self, from: Data(contentsOf: url))
        try study.validate(); return study
    }
    func save(_ study: CandidateValidationStudy) throws {
        try study.validate()
        let data = try JSONEncoder().encode(study)
        guard data.count <= 1_048_576 else { throw CocoaError(.fileWriteUnknown) }
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        try directory.setResourceValues(excluded)
        if let writeData { try writeData(data, url) }
        else { try data.write(to: url, options: IdentitySelectionArchive.writingOptions) }
        var file = url; try? file.setResourceValues(excluded)
    }
}

// Counts only; a fresh-photo check with blinded labels is NOT a general accuracy guarantee.
struct CandidateValidationReport: Encodable {
    let protocolIdentifier = "pet-candidate-blinded-study-v1"
    let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    let method = CandidateValidationStudy.protocolKey
    let identityModel = ProbeModelFile.sha256
    let objectModel = CandidateObjectDetector.modelSHA256
    let runtimeVersion = IdentityEvaluationCore.expectedRuntimeVersion
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    let rows = ["candidateA", "candidateB", "withheld"]
    let columns = ["a", "b", "both", "other", "unsure", "unreviewed"]
    let counts: [[Int]]
    let selected: Int
    let matchingProposals: Int
    let proposed: Int
    let compositionReady: Bool
    let duplicatePhotos: Int
    let duplicateSourcesUnavailable: Int
    let duplicateSourcesUnavailableScope = "unavailable-source-check-visits-summed-over-chunks;not-unique-photo-count"
    let unavailablePhotos: Int
    let labelsSealedBeforeInference = true
    let knownIdentifiersExcluded = true
    let duplicateScope = "known-current-registration-evaluation-development-and-earlier-study-photos;burst-or-dhash<=2;deleted-history-and-nonduplicate-dependence-not-proven"
    let inputFreeze = "saved-selection-and-PhotoKit-modification-metadata;not-byte-identity-proof"
    let manualTimeComparisonMeasured = false
    let independentAccuracyEvaluated = false
    let goalValidated = false
    let productValidated = false
    let productionDataChanged = false
    let photosIncluded = false
    let identifiersIncluded = false
    let embeddingsIncluded = false
    let individualPredictionsIncluded = false

    init(study: CandidateValidationStudy, photos: [CandidateReviewPhoto], duplicateSourcesUnavailable: Int) throws {
        try study.validate()
        guard study.sealed, study.algorithmMatches, photos.count == study.identifiers.count,
              photos.map(\.id) == Array(study.identifiers.indices), duplicateSourcesUnavailable >= 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var matrix = Array(repeating: Array(repeating: 0, count: 6), count: 3)
        let choices: [CandidateReviewChoice?] = [.a, .b, .both, .other, .unsure, nil]
        for photo in photos {
            let row = photo.batchSuggestion == .a ? 0 : photo.batchSuggestion == .b ? 1 : 2
            let column = choices.firstIndex(of: study.decisions[study.identifiers[photo.id]])!
            matrix[row][column] += 1
        }
        counts = matrix; selected = photos.count
        proposed = matrix[0].reduce(0, +) + matrix[1].reduce(0, +)
        matchingProposals = matrix[0][0] + matrix[1][1]
        compositionReady = study.compositionReady
        duplicatePhotos = photos.filter { $0.issue == .similarPhoto || $0.issue == .repeatedBurst }.count
        unavailablePhotos = photos.filter { $0.image == nil || $0.issue == .unavailable }.count
        self.duplicateSourcesUnavailable = duplicateSourcesUnavailable
    }
    var json: String? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
