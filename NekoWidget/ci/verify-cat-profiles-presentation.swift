import Foundation

@main
enum CatProfilesPresentationVerifier {
    static func main() throws {
        try verifiesEveryoneIsAlwaysTheDefaultScope()
        try verifiesManyToManyPhotoMembership()
        try verifiesMixedBatchAssignmentsArePreserved()
        try verifiesProfileOnlyTimePolicies()
        try verifiesPostureDiagnosticStates()
        print("Cat profiles presentation verifier passed")
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
        try require(!everyone.showsGrowthComparison, "everyone mixed two cats in growth")

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
        let build13 = CatPostureDiagnosticsPresentation(
            targetPhotoCount: 896,
            rawPoseObservedPhotoCount: 860,
            matchedPosePhotoCount: nil,
            classifiedPhotoCount: 0,
            unclassifiedPhotoCount: 896,
            pendingPhotoCount: 0
        )
        try require(
            build13.state == .completedWithoutDetailedCause,
            "legacy completed-zero diagnostics were presented as pending"
        )

        let noMatch = CatPostureDiagnosticsPresentation(
            targetPhotoCount: 100,
            rawPoseObservedPhotoCount: 90,
            matchedPosePhotoCount: 0,
            qualityPassedPhotoCount: 0,
            geometryPassedPhotoCount: 0,
            classifiedPhotoCount: 0,
            unclassifiedPhotoCount: 100,
            pendingPhotoCount: 0
        )
        try require(
            noMatch.state == .completedWithoutCatMatches,
            "pose-to-cat match failure was not distinguished from rule rejection"
        )

        let noRule = CatPostureDiagnosticsPresentation(
            targetPhotoCount: 100,
            rawPoseObservedPhotoCount: 90,
            matchedPosePhotoCount: 80,
            qualityPassedPhotoCount: 0,
            geometryPassedPhotoCount: 0,
            classifiedPhotoCount: 0,
            unclassifiedPhotoCount: 100,
            pendingPhotoCount: 0
        )
        try require(
            noRule.state == .completedWithoutQualityMatches,
            "matched poses rejected by joint quality were not distinguished"
        )

        let noGeometry = CatPostureDiagnosticsPresentation(
            targetPhotoCount: 100,
            rawPoseObservedPhotoCount: 90,
            matchedPosePhotoCount: 80,
            qualityPassedPhotoCount: 70,
            geometryPassedPhotoCount: 0,
            classifiedPhotoCount: 0,
            unclassifiedPhotoCount: 100,
            pendingPhotoCount: 0
        )
        try require(
            noGeometry.state == .completedWithoutGeometryMatches,
            "quality-pass geometry rejection was not distinguished"
        )

        let pending = CatPostureDiagnosticsPresentation(
            targetPhotoCount: 100,
            rawPoseObservedPhotoCount: 90,
            matchedPosePhotoCount: 80,
            qualityPassedPhotoCount: 70,
            geometryPassedPhotoCount: 60,
            classifiedPhotoCount: 12,
            unclassifiedPhotoCount: 68,
            pendingPhotoCount: 20
        )
        try require(pending.state == .incomplete, "pending analysis lost retry priority")
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
