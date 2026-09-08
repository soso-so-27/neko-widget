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

        // Caption is additive to schema 1. Exercise an actual photo rather
        // than only the empty manifest used by the name migration above.
        struct PreCaptionPhoto: Codable {
            var sourceDigest: String
            var cacheFilenames: WidgetCacheFilenames
            var receivedAt: Date
            var freshUntil: Date
        }
        let oldPhoto = PreCaptionPhoto(
            sourceDigest: String(repeating: "a", count: 64),
            cacheFilenames: WidgetCacheFilenames(
                small: "s.jpg", medium: "m.jpg", large: "l.jpg"
            ),
            receivedAt: current.generatedAt,
            freshUntil: current.generatedAt.addingTimeInterval(3_600)
        )
        let oldPhotoData = try encoder.encode(oldPhoto)
        var upgraded = try decoder.decode(FamilyWidgetManifestItem.self, from: oldPhotoData)
        try require(upgraded.caption == nil, "old photo invented a caption")
        upgraded.caption = "窓辺でおひるね 🐈\nまたあとで"
        let upgradedData = try encoder.encode(upgraded)
        let roundTrip = try decoder.decode(FamilyWidgetManifestItem.self, from: upgradedData)
        let oldPhotoReader = try decoder.decode(PreCaptionPhoto.self, from: upgradedData)
        try require(roundTrip == upgraded, "photo and caption did not round trip together")
        try require(
            oldPhotoReader.sourceDigest == oldPhoto.sourceDigest
                && oldPhotoReader.cacheFilenames == oldPhoto.cacheFilenames,
            "old Widget could not read a captioned photo"
        )
        upgraded.caption = nil
        let noCaptionData = try encoder.encode(upgraded)
        let noCaptionJSON = try JSONSerialization.jsonObject(with: noCaptionData) as? [String: Any]
        try require(noCaptionJSON?["caption"] == nil, "photo-only manifest retained caption")

        print("Private window display name verifier passed")
    }
}
