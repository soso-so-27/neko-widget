import Foundation

@main
enum CatCurationVerifier {
    static func main() throws {
        try verifiesExclusionLifecycle()
        try verifiesCandidateEligibility()
        try verifiesMutationRevisionOrdering()
        try verifiesDormantSourceCachePolicy()
        try verifiesColdLaunchDeepLinkFlow()
        try verifiesLegacyMigrationDefaults()
        try verifiesDiagnosticJSONRedaction()
        print("Cat candidate curation verifier passed")
    }

    private static func verifiesCandidateEligibility() throws {
        var state = CatCandidateCurationState.empty
        state.exclude(localIdentifiers: ["not-this-cat"])
        try require(
            !state.includesCandidate(
                localIdentifier: "not-this-cat",
                selectedSourceAssetIdentifiers: nil
            ),
            "an exclusion was allowed back into candidate surfaces"
        )

        state.selectSourceAlbum(localIdentifier: "source-album")
        let membership: Set<String> = ["in-source"]
        try require(
            state.includesCandidate(
                localIdentifier: "in-source",
                selectedSourceAssetIdentifiers: membership
            ),
            "an in-source photo was removed"
        )
        try require(
            !state.includesCandidate(
                localIdentifier: "outside-source",
                selectedSourceAssetIdentifiers: membership
            ),
            "an out-of-source photo remained eligible"
        )
        try require(
            !state.includesCandidate(
                localIdentifier: "unknown-source-photo",
                selectedSourceAssetIdentifiers: nil
            ),
            "a source with no durable membership broadened to all photos"
        )

        state.selectSourceAlbum(
            localIdentifier: "source-album",
            assetIdentifiers: ["previously-scoped", "in-source"]
        )
        try require(
            state.includesCandidate(
                localIdentifier: "previously-scoped",
                selectedSourceAssetIdentifiers: nil
            ),
            "temporarily unavailable source lost its durable membership"
        )
        try require(
            !state.includesCandidate(
                localIdentifier: "outside-source",
                selectedSourceAssetIdentifiers: nil
            ),
            "durable source fallback broadened to an outside photo"
        )
    }

    private static func verifiesMutationRevisionOrdering() throws {
        var older = CatCandidateCurationState.empty
        older.exclude(localIdentifiers: ["cat-a"])
        var newer = older
        newer.exclude(localIdentifiers: ["cat-b"])
        try require(
            newer.mutationRevision > older.mutationRevision,
            "curation mutations did not receive monotonic revisions"
        )
        newer.selectSourceAlbum(
            localIdentifier: "source",
            assetIdentifiers: ["member-b", "member-a", "member-b"]
        )
        try require(
            newer.lastKnownSourceAssetIdentifiers == ["member-a", "member-b"],
            "durable source membership was not normalized"
        )

        let roundTrip = try JSONDecoder().decode(
            CatCandidateCurationState.self,
            from: JSONEncoder().encode(newer)
        ).normalized()
        try require(roundTrip == newer.normalized(), "curation state round-trip lost data")
    }

    private static func verifiesDormantSourceCachePolicy() throws {
        let existing = ["source-a", "source-b", "outside-cached"]
        let active: Set<String> = ["source-a", "source-b"]
        try require(
            PhotoSourceCachePolicy.dormantIdentifiers(
                existingIdentifiers: existing,
                activeIdentifiers: active,
                usesSelectedSource: true
            ) == ["outside-cached"],
            "selected-source scan discarded or exposed the wrong dormant cache"
        )
        try require(
            PhotoSourceCachePolicy.dormantIdentifiers(
                existingIdentifiers: existing,
                activeIdentifiers: active,
                usesSelectedSource: false
            ).isEmpty,
            "full-library scan retained records outside its authoritative fetch"
        )
    }

    private static func verifiesColdLaunchDeepLinkFlow() throws {
        var gate = CandidatePhotoRouteGate()
        let first = CandidatePhotoRoute(
            localIdentifier: "old-widget-photo",
            shownAt: Date(timeIntervalSince1970: 100)
        )
        let latest = CandidatePhotoRoute(
            localIdentifier: "latest-widget-photo",
            shownAt: Date(timeIntervalSince1970: 200)
        )
        try require(
            gate.receive(first, candidateStateIsReady: false) == nil,
            "cold-launch route opened before candidate state loaded"
        )
        try require(
            gate.receive(latest, candidateStateIsReady: false) == nil,
            "replacement cold-launch route opened before candidate state loaded"
        )
        try require(
            gate.finishLoading(succeeded: true) == latest,
            "cold-launch route queue was not latest-wins"
        )
        try require(!gate.hasPendingRoute, "opened cold-launch route remained pending")

        _ = gate.receive(first, candidateStateIsReady: false)
        try require(
            gate.finishLoading(succeeded: false) == nil && !gate.hasPendingRoute,
            "failed curation load retained a pending Widget route"
        )
        try require(
            gate.receive(latest, candidateStateIsReady: true) == latest,
            "ready candidate state unnecessarily deferred a Widget route"
        )
    }

    private static func verifiesExclusionLifecycle() throws {
        let firstDate = Date(timeIntervalSince1970: 100)
        var state = CatCandidateCurationState.empty
        state.exclude(localIdentifiers: ["cat-a", "cat-b", "cat-a", ""], at: firstDate)
        try require(
            state.excludedAssetIdentifiers == ["cat-a", "cat-b"],
            "exclusions were not unique"
        )

        state.exclude(
            localIdentifiers: ["cat-a"],
            at: Date(timeIntervalSince1970: 200)
        )
        try require(
            state.excludedAssets.first(where: { $0.localIdentifier == "cat-a" })?.excludedAt
                == firstDate,
            "repeated exclusion replaced the original user decision date"
        )

        state.restore(localIdentifiers: ["cat-a"])
        try require(
            state.excludedAssetIdentifiers == ["cat-b"],
            "restoring one exclusion changed the wrong records"
        )
        state.selectSourceAlbum(localIdentifier: "source-album")
        try require(state.usesSelectedAlbum, "selected source was not retained")
        state.selectSourceAlbum(localIdentifier: nil)
        try require(!state.usesSelectedAlbum, "all-library source was not restored")
    }

    private static func verifiesLegacyMigrationDefaults() throws {
        let legacy = Data(#"""
        {
            "excludedAssetIdentifiers":["legacy-b","legacy-a","legacy-b"],
            "sourceAlbumIdentifier":"legacy-source"
        }
        """#.utf8)
        let decoded = try JSONDecoder().decode(CatCandidateCurationState.self, from: legacy)
        let migrated = decoded.normalized()
        try require(
            migrated.schemaVersion == CatCandidateCurationState.currentSchemaVersion,
            "legacy schema did not migrate"
        )
        try require(
            migrated.excludedAssetIdentifiers == ["legacy-a", "legacy-b"],
            "legacy exclusions were not preserved"
        )
        try require(
            migrated.sourceAlbumIdentifier == "legacy-source",
            "legacy source selection was not preserved"
        )

        let empty = try JSONDecoder().decode(
            CatCandidateCurationState.self,
            from: Data("{}".utf8)
        ).normalized()
        try require(empty == .empty, "missing curation fields did not default safely")
    }

    private static func verifiesDiagnosticJSONRedaction() throws {
        var state = CatCandidateCurationState.empty
        state.exclude(localIdentifiers: ["private-photo-identifier"])
        state.selectSourceAlbum(
            localIdentifier: "private-album-identifier",
            assetIdentifiers: ["private-source-member-identifier"]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(CatCandidateCurationExportSummary(state: state))
        let json = String(decoding: data, as: UTF8.self)
        try require(!json.contains("private-photo-identifier"), "export leaked photo identifier")
        try require(!json.contains("private-album-identifier"), "export leaked album identifier")
        try require(
            !json.contains("private-source-member-identifier"),
            "export leaked source membership identifier"
        )
        try require(json.contains("\"excludedAssetCount\":1"), "export lost exclusion count")
        try require(json.contains("\"sourceAlbumConfigured\":true"), "export lost source flag")
        try require(
            json.contains("\"containsExcludedAssetIdentifiers\":false")
                && json.contains("\"containsSourceAlbumIdentifier\":false")
                && json.contains("\"containsSourceAssetIdentifiers\":false"),
            "export privacy declarations changed"
        )
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw VerificationError.failed(message) }
    }
}

private enum VerificationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): message
        }
    }
}
