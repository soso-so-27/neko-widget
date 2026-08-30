import Foundation

private enum VerificationError: Error {
    case failed(String)
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else { throw VerificationError.failed(message) }
}

/// Models the pre-named-window reader. JSONDecoder must continue to ignore the
/// new optional presentation key during an app/Widget rolling upgrade.
private struct LegacyFamilyWidgetManifest: Decodable {
    let schemaVersion: Int
    let item: FamilyWidgetManifestItem?
    let generatedAt: Date
}

@main
private enum PrivateWindowDisplayNameVerifier {
    static func main() throws {
        try require(
            PrivateWindowCatalogState.maximumWindowCount == 20,
            "catalog compatibility limit changed"
        )
        try require(
            PrivateWindowCatalogState.maximumProductWindowCount == 3,
            "initial product window limit changed"
        )
        try require(
            PrivateWindowDisplayName.resolved(nil)
                == PrivateWindowDisplayName.fallback,
            "missing name did not use fallback"
        )
        try require(
            PrivateWindowDisplayName.normalized("  しずくのまど  ")
                == "しずくのまど",
            "name trimming changed"
        )
        try require(
            PrivateWindowDisplayName.isValid("しずくのまど"),
            "Japanese window name was rejected"
        )
        try require(
            PrivateWindowDisplayName.isValid(String(repeating: "a", count: 64)),
            "64-byte name was rejected"
        )
        try require(
            !PrivateWindowDisplayName.isValid(String(repeating: "a", count: 65)),
            "65-byte name was accepted"
        )
        try require(
            !PrivateWindowDisplayName.isValid("夜\nのまど"),
            "control character was accepted"
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacyJSON = Data("""
        {
          "schemaVersion": 1,
          "item": null,
          "generatedAt": "2026-08-23T00:00:00Z"
        }
        """.utf8)
        let migrated = try decoder.decode(FamilyWidgetManifest.self, from: legacyJSON)
        try require(
            PrivateWindowDisplayName.resolved(migrated.windowDisplayName)
                == PrivateWindowDisplayName.fallback,
            "legacy manifest did not fall back"
        )

        let current = FamilyWidgetManifest(
            item: nil,
            windowDisplayName: "しずくのまど",
            generatedAt: Date(timeIntervalSince1970: 1_777_070_400)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let currentData = try encoder.encode(current)
        let legacyReader = try decoder.decode(
            LegacyFamilyWidgetManifest.self,
            from: currentData
        )
        try require(
            legacyReader.schemaVersion == 1
                && legacyReader.item == nil
                && legacyReader.generatedAt == current.generatedAt,
            "legacy reader rejected the optional name key"
        )

        print("Private window display name verifier passed")
    }
}
