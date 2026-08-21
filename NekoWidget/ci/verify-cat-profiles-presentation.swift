import Foundation

@main
enum CatProfilesPresentationVerifier {
    static func main() throws {
        try verifiesEveryoneIsAlwaysTheDefaultScope()
        try verifiesIndividualRecognitionCopy()
        try verifiesManyToManyPhotoMembership()
        try verifiesSimilarityReviewKeepsCatInstancesSeparate()
        try verifiesMixedBatchAssignmentsArePreserved()
        try verifiesProfileOnlyTimePolicies()
        try verifiesProfileBoundingBoxSelection()
        try verifiesPostureDiagnosticStates()
        print("Cat profiles presentation verifier passed")
    }

    private static func verifiesIndividualRecognitionCopy() throws {
        try require(
            CatIndividualRecognitionCopy.unavailable
                == "いまは自動で見分けることができません。",
            "deprecated individual-recognition guidance changed"
        )
    }

    private static func verifiesEveryoneIsAlwaysTheDefaultScope() throws {
        let empty = CatProfilesPresentation()
        try require(
            empty.availableScopes == [.everyone],
            "empty profile setup stopped offering everyone as the only default scope"
        )
        try require(
            empty.timePolicy(for: .everyone)
                == CatProfileTimePolicyPresentation(
                    grouping: .calendarYears,
                    showsGrowthComparison: false
                ),
            "everyone began mixing profile growth or age albums"
        )

        let value = CatProfilesPresentation(profiles: [
            profile("mugi", name: " むぎ ", reference: nil),
            profile("ame", name: "", reference: nil)
        ])
        try require(
            value.availableScopes == [.everyone, .profile("mugi"), .profile("ame")],
            "everyone was not first after profiles were added"
        )
        try require(value.profiles[0].displayName == "むぎ", "profile name was not normalized")
        try require(value.profiles[1].displayName == "名前未設定", "optional name gained a requirement")
        try require(
            value.normalizedScope(.profile("deleted")) == .everyone,
            "a deleted album or Widget profile source did not fall back to everyone"
        )
    }

    private static func verifiesManyToManyPhotoMembership() throws {
        let photo = CatProfilePhotoPresentation(
            localIdentifier: "two-cats",
            assignedProfileIdentifiers: ["mugi", "ame"],
            detectedCatCount: 2
        )
        try require(
            photo.assignedProfileIdentifiers == ["mugi", "ame"],
            "one photo could not retain multiple confirmed cat memberships"
        )
        try require(photo.detectedCatCount == 2, "multiple cats in one photo were collapsed")
    }

    private static func verifiesSimilarityReviewKeepsCatInstancesSeparate() throws {
        let left = CatSimilarityCandidateInstance(
            assetLocalIdentifier: "two-cats",
            boundingBox: NormalizedRect(
                x: 0.05,
                y: 0.10,
                width: 0.35,
                height: 0.60
            )
        )
        let right = CatSimilarityCandidateInstance(
            assetLocalIdentifier: "two-cats",
            boundingBox: NormalizedRect(
                x: 0.60,
                y: 0.10,
                width: 0.35,
                height: 0.60
            )
        )
        let value = CatProfilesPresentation(similarityCandidates: [left, right])
        try require(
            value.similarityCandidates == [left, right],
            "two cat instances in one photo were collapsed before review"
        )
    }

    private static func verifiesMixedBatchAssignmentsArePreserved() throws {
        var batch = CatPhotoAssignmentBatchPresentation(
            photoIdentifiers: ["both", "mugi-only"],
            initialAssignmentsByPhotoIdentifier: [
                "both": ["mugi", "ame"],
                "mugi-only": ["mugi"]
            ]
        )
        try require(batch.state(for: "mugi") == .all, "common assignment was lost")
        try require(batch.state(for: "ame") == .some, "mixed assignment was flattened")

        batch.toggle(profileIdentifier: "ame")
        try require(batch.state(for: "ame") == .all, "mixed tap did not assign to all")
        try require(
            batch.assignmentsByPhotoIdentifier["mugi-only"] == ["mugi", "ame"],
            "assigning a second cat removed the first cat"
        )

        batch.toggle(profileIdentifier: "ame")
        try require(batch.state(for: "ame") == .none, "all tap did not remove from all")
        try require(
            batch.assignmentsByPhotoIdentifier["both"] == ["mugi"],
            "removing one cat changed the other cat"
        )
    }

    private static func verifiesProfileOnlyTimePolicies() throws {
        let birthday = CatProfileLifeReferencePresentation(
            kind: .birthday,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            isApproximate: true
        )
        let adoption = CatProfileLifeReferencePresentation(
            kind: .adoptionDay,
            date: Date(timeIntervalSince1970: 1_710_000_000),
            isApproximate: false
        )
        let value = CatProfilesPresentation(profiles: [
            profile("mugi", name: "むぎ", reference: birthday),
            profile("ame", name: "あめ", reference: adoption)
        ])

        let everyone = value.timePolicy(for: .everyone)
        try require(everyone.grouping == .calendarYears, "everyone stopped using calendar years")
        try require(!everyone.showsGrowthComparison,
                    "everyone must not mix different cats into one growth comparison")

        let mugi = value.timePolicy(for: .profile("mugi"))
        try require(mugi.grouping == .age(reference: birthday), "birthday did not produce age grouping")
        try require(mugi.showsGrowthComparison, "profile growth disappeared")

        let ame = value.timePolicy(for: .profile("ame"))
        try require(
            ame.grouping == .yearsTogether(reference: adoption),
            "adoption day was incorrectly presented as biological age"
        )

        let missing = value.timePolicy(for: .profile("missing"))
        try require(
            missing == CatProfileTimePolicyPresentation(
                grouping: .calendarYears,
                showsGrowthComparison: false
            ),
            "a stale profile route gained mixed-cat growth"
        )
    }

    private static func verifiesPostureDiagnosticStates() throws {
        let complete = CatPostureDiagnosticsPresentation(
            targetPhotoCount: 896,
            validBoxPhotoCount: 896,
            classifiedPhotoCount: 508,
            fullyUnclassifiedPhotoCount: 388,
            multiAlbumPhotoCount: 8,
            sleepingPhotoCount: 133,
            curledPhotoCount: 121,
            sittingPhotoCount: 262
        )
        try require(
            complete.state == .completed,
            "complete bbox diagnostics were not presented as complete"
        )
        try require(
            complete.statusDetail.contains("再スキャンは不要"),
            "bbox diagnostics stopped explaining the no-rescan guarantee"
        )

        let missing = CatPostureDiagnosticsPresentation(
            targetPhotoCount: 100,
            validBoxPhotoCount: 98,
            classifiedPhotoCount: 60,
            fullyUnclassifiedPhotoCount: 38,
            missingBoxPhotoCount: 2
        )
        try require(
            missing.state == .completedWithMissingBoxes,
            "missing bbox assets were not disclosed"
        )
        try require(
            missing.statusDetail.contains("2枚"),
            "missing bbox count disappeared from the explanation"
        )

        let empty = CatPostureDiagnosticsPresentation()
        try require(empty.state == .noTargets, "empty bbox diagnostics changed")

        let noAlbumMatches = CatPostureDiagnosticsPresentation(
            targetPhotoCount: 20,
            validBoxPhotoCount: 20,
            fullyUnclassifiedPhotoCount: 20
        )
        try require(
            noAlbumMatches.statusTitle == "姿勢分類は完了しています",
            "completed-zero bbox diagnostics claimed an album was created"
        )
    }

    private static func verifiesProfileBoundingBoxSelection() throws {
        let left = NormalizedRect(x: 0.05, y: 0.20, width: 0.30, height: 0.40)
        let right = NormalizedRect(x: 0.60, y: 0.20, width: 0.30, height: 0.40)
        let rightSubject = NormalizedRect(
            x: 0.61,
            y: 0.21,
            width: 0.29,
            height: 0.39
        )
        try require(
            CatProfileBoundingBoxSelector.select(
                from: [left, right],
                detectedCatCount: 2,
                subjectBoundingBox: rightSubject
            ) == right,
            "profile subject did not select its matching cat box"
        )
        try require(
            CatProfileBoundingBoxSelector.select(
                from: [left],
                detectedCatCount: 1,
                subjectBoundingBox: nil
            ) == left,
            "single-cat safe fallback disappeared"
        )
        try require(
            CatProfileBoundingBoxSelector.select(
                from: [left],
                detectedCatCount: 2,
                subjectBoundingBox: nil
            ) == nil,
            "multi-cat photo guessed a profile subject from one surviving box"
        )
        try require(
            CatProfileBoundingBoxSelector.select(
                from: [left, right],
                detectedCatCount: 2,
                subjectBoundingBox: NormalizedRect(
                    x: 0,
                    y: 0.8,
                    width: 0.1,
                    height: 0.1
                )
            ) == nil,
            "stale profile subject was guessed instead of rejected"
        )
    }

    private static func profile(
        _ identifier: String,
        name: String?,
        reference: CatProfileLifeReferencePresentation?
    ) -> CatProfilePresentation {
        CatProfilePresentation(
            identifier: identifier,
            name: name,
            coverPhoto: nil,
            confirmedPhotos: [],
            lifeReference: reference
        )
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
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
