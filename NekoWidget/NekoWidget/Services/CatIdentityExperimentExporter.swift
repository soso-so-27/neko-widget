import Foundation

enum CatIdentityExperimentExporterError: Error, Equatable, Sendable {
    case privacyInvariantFailed
}

/// Writes only the aggregate report schema. The timestamp is used for the
/// temporary filename and is not encoded; it cannot be confused with a photo
/// creation date or become an identity signal in the payload.
struct CatIdentityExperimentExporter {
    func export(
        _ report: CatIdentityExperimentReport,
        exportedAt: Date = .now
    ) throws -> URL {
        guard !report.containsPhotoData,
              !report.containsFeatureData,
              !report.containsPhotoIdentifiers,
              !report.containsProfileIdentifiersOrNames,
              !report.containsPhotoDatesOrBoundingBoxes else {
            throw CatIdentityExperimentExporterError.privacyInvariantFailed
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cat-identity-experiment-\(formatter.string(from: exportedAt)).json",
            isDirectory: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: url, options: [.atomic])
        return url
    }
}
