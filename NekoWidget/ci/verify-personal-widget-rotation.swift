import Foundation

private enum VerificationError: Error {
    case failed(String)
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw VerificationError.failed(message) }
}

private let anchor = Date(timeIntervalSince1970: 1_800_000_000)

private func item(_ photo: Int, slot: Int) -> WidgetManifestItem {
    WidgetManifestItem(
        localIdentifier: "photo-\(photo)",
        cacheFilename: "photo-\(photo)-small.jpg",
        cacheFilenames: WidgetCacheFilenames(
            small: "photo-\(photo)-small.jpg",
            medium: "photo-\(photo)-medium.jpg",
            large: "photo-\(photo)-large.jpg"
        ),
        scheduledDate: anchor.addingTimeInterval(TimeInterval(slot * 20 * 60))
    )
}

@main
private enum PersonalWidgetRotationVerifier {
    static func main() throws {
        try require(PersonalWidgetRotationPolicy.orderedUniqueItems(from: []).isEmpty,
                    "an empty library gained a photo")

        // Frozen shape of the old writer: a short local library was repeated
        // until there were 20 slots. With 19 photos this ends AND starts on A;
        // with 3 it gives A and B more slots than C on every cycle.
        let legacyNineteen = (0..<20).map { item($0 % 19, slot: $0) }
        try require(legacyNineteen.first?.localIdentifier == legacyNineteen.last?.localIdentifier,
                    "legacy boundary-repeat fixture no longer reproduces")

        for count in 1...20 {
            let expected = (0..<count).map { item($0, slot: $0) }
            let legacy = (0..<20).map { item($0 % count, slot: $0) }
            let decoded = try JSONDecoder().decode(
                WidgetManifest.self,
                from: JSONEncoder().encode(WidgetManifest(items: legacy, generatedAt: anchor))
            )
            let rotation = PersonalWidgetRotationPolicy.orderedUniqueItems(from: decoded.items)
            try require(rotation == expected,
                        "\(count)-photo legacy rotation lost order, cadence, cache identity or fairness")
            try require(PersonalWidgetRotationPolicy.orderedUniqueItems(from: rotation) == rotation,
                        "\(count)-photo current rotation changed during a reload")
            if count > 1 {
                try require(rotation.first?.localIdentifier != rotation.last?.localIdentifier,
                            "\(count)-photo cycle repeats the boundary photo")
            }
        }

        let unsorted = [item(2, slot: 2), item(0, slot: 0), item(1, slot: 1)]
        try require(PersonalWidgetRotationPolicy.orderedUniqueItems(from: unsorted)
                        == [item(0, slot: 0), item(1, slot: 1), item(2, slot: 2)],
                    "source order replaced the persisted schedule")

        // The reader may have removed unavailable or excluded photos already.
        // Normalization must never resurrect them from another source/cache.
        let filtered = [item(1, slot: 1), item(2, slot: 2), item(1, slot: 4)]
        try require(PersonalWidgetRotationPolicy.orderedUniqueItems(from: filtered)
                        == [item(1, slot: 1), item(2, slot: 2)],
                    "an unavailable photo reappeared or an available photo lost its binding")

        let oversized = (0..<25).map { item($0, slot: $0) }
        try require(PersonalWidgetRotationPolicy.orderedUniqueItems(from: oversized)
                        == Array(oversized.prefix(20)),
                    "the existing 20-photo rotation limit changed")
        print("Personal Widget rotation passed: 1–20 photos, legacy padding, cycle boundary, cache/date identity, filtering and 20-photo cap.")
    }
}
