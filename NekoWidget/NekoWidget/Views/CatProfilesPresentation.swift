import CoreGraphics
import Foundation

enum CatIndividualRecognitionCopy {
    static let unavailable = "いまは自動で見分けることができません。"
}

enum CatProfileBoundingBoxSelector {
    static let minimumIntersectionOverUnion = 0.35

    /// Returns a box only when the membership identifies a current cat, or
    /// when the detector itself says the photo contains at most one cat.
    /// A multi-cat photo without a subject remains unclassified.
    static func select(
        from boundingBoxes: [NormalizedRect],
        detectedCatCount: Int,
        subjectBoundingBox: NormalizedRect?
    ) -> NormalizedRect? {
        if let subjectBoundingBox {
            let candidate = boundingBoxes.max {
                intersectionOverUnion($0, subjectBoundingBox)
                    < intersectionOverUnion($1, subjectBoundingBox)
            }
            guard let candidate,
                  intersectionOverUnion(candidate, subjectBoundingBox)
                    >= minimumIntersectionOverUnion else { return nil }
            return candidate
        }
        guard detectedCatCount <= 1, boundingBoxes.count == 1 else {
            return nil
        }
        return boundingBoxes[0]
    }

    private static func intersectionOverUnion(
        _ lhs: NormalizedRect,
        _ rhs: NormalizedRect
    ) -> Double {
        let intersection = lhs.cgRect.intersection(rhs.cgRect)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = Double(intersection.width * intersection.height)
        let union = lhs.area + rhs.area - intersectionArea
        return union > 0 ? intersectionArea / union : 0
    }
}

/// UI-only identifier for the optional household-cat scope. The app always
/// starts in `everyone`; creating profiles is an enhancement, never an
/// onboarding requirement.
enum CatProfileScopePresentation: Hashable, Identifiable {
    case everyone
    case profile(String)

    var id: String {
        switch self {
        case .everyone: "everyone"
        case let .profile(identifier): "profile:\(identifier)"
        }
    }
}

enum CatProfileLifeReferenceKindPresentation: String, CaseIterable, Identifiable {
    case birthday
    case adoptionDay

    var id: Self { self }

    var title: String {
        switch self {
        case .birthday: "誕生日"
        case .adoptionDay: "迎えた日"
        }
    }
}

struct CatProfileLifeReferencePresentation: Equatable {
    var kind: CatProfileLifeReferenceKindPresentation
    var date: Date
    var isApproximate: Bool
}

struct CatProfilePhotoPresentation: Identifiable, Equatable {
    var localIdentifier: String
    var creationDate: Date?
    var catBoundingBox: CGRect?
    /// A photo can belong to multiple cats. These are explicit assignments.
    var assignedProfileIdentifiers: Set<String>
    var detectedCatCount: Int

    var id: String { localIdentifier }

    init(
        localIdentifier: String,
        creationDate: Date? = nil,
        catBoundingBox: CGRect? = nil,
        assignedProfileIdentifiers: Set<String> = [],
        detectedCatCount: Int = 1
    ) {
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
        self.catBoundingBox = catBoundingBox
        self.assignedProfileIdentifiers = assignedProfileIdentifiers
        self.detectedCatCount = max(1, detectedCatCount)
    }
}

struct CatProfilePhotoAlbumOptionPresentation: Identifiable, Equatable {
    var identifier: String
    var title: String
    var accessiblePhotoCount: Int

    var id: String { identifier }
}

struct CatProfilePhotoAlbumLinkPresentation: Equatable {
    var identifier: String
    var title: String?
    var accessiblePhotoCount: Int?
    var profilePhotoCount: Int
    var isAvailable: Bool

    var displayTitle: String { title ?? "利用できないアルバム" }

    init(
        identifier: String,
        title: String?,
        accessiblePhotoCount: Int?,
        profilePhotoCount: Int,
        isAvailable: Bool = true
    ) {
        self.identifier = identifier
        self.title = title
        self.accessiblePhotoCount = accessiblePhotoCount
        self.profilePhotoCount = profilePhotoCount
        self.isAvailable = isAvailable
    }
}

struct CatProfilePresentation: Identifiable, Equatable {
    var identifier: String
    var name: String?
    var coverPhoto: CatProfilePhotoPresentation?
    var confirmedPhotos: [CatProfilePhotoPresentation]
    /// Every current library candidate not already confirmed for this profile.
    /// It intentionally includes photos assigned to another profile so a
    /// two-cat photo can be added from either cat's page.
    var manualCandidatePhotos: [CatProfilePhotoPresentation] = []
    var lifeReference: CatProfileLifeReferencePresentation?
    var photoAlbumLink: CatProfilePhotoAlbumLinkPresentation? = nil
    var similarityReferencePhotoCount: Int = 0

    var id: String { identifier }

    var displayName: String {
        guard let normalized = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return "名前未設定"
        }
        return normalized
    }

    var confirmedPhotoCount: Int { confirmedPhotos.count }
}

struct LegacyExcludedCatPhotoPresentation: Identifiable, Equatable {
    var localIdentifier: String
    var creationDate: Date?
    var id: String { localIdentifier }
}

/// Count-only diagnostics for the active normalized bounding-box posture
/// policy. Feature vectors, profile names, and PhotoKit identifiers never
/// cross this presentation boundary.
struct CatPostureDiagnosticsPresentation: Equatable {
    var targetPhotoCount: Int
    var validBoxPhotoCount: Int
    var classifiedPhotoCount: Int
    var fullyUnclassifiedPhotoCount: Int
    var missingBoxPhotoCount: Int
    var multiAlbumPhotoCount: Int
    var sleepingPhotoCount: Int
    var curledPhotoCount: Int
    var sittingPhotoCount: Int

    init(
        targetPhotoCount: Int = 0,
        validBoxPhotoCount: Int = 0,
        classifiedPhotoCount: Int = 0,
        fullyUnclassifiedPhotoCount: Int = 0,
        missingBoxPhotoCount: Int = 0,
        multiAlbumPhotoCount: Int = 0,
        sleepingPhotoCount: Int = 0,
        curledPhotoCount: Int = 0,
        sittingPhotoCount: Int = 0
    ) {
        self.targetPhotoCount = max(0, targetPhotoCount)
        self.validBoxPhotoCount = max(0, validBoxPhotoCount)
        self.classifiedPhotoCount = max(0, classifiedPhotoCount)
        self.fullyUnclassifiedPhotoCount = max(0, fullyUnclassifiedPhotoCount)
        self.missingBoxPhotoCount = max(0, missingBoxPhotoCount)
        self.multiAlbumPhotoCount = max(0, multiAlbumPhotoCount)
        self.sleepingPhotoCount = max(0, sleepingPhotoCount)
        self.curledPhotoCount = max(0, curledPhotoCount)
        self.sittingPhotoCount = max(0, sittingPhotoCount)
    }

    var state: CatPostureDiagnosticsStatePresentation {
        if targetPhotoCount == 0 { return .noTargets }
        if missingBoxPhotoCount > 0 { return .completedWithMissingBoxes }
        return .completed
    }

    var statusTitle: String {
        switch state {
        case .noTargets: "確認する猫候補がありません"
        case .completed: "姿勢分類は完了しています"
        case .completedWithMissingBoxes: "姿勢分類は完了しています"
        }
    }

    var statusDetail: String {
        switch state {
        case .noTargets:
            "猫候補の写真が見つかると、ここに分類状況が表示されます。"
        case .completed:
            "保存済みの猫の検出枠から分類しています。再スキャンは不要です。"
        case .completedWithMissingBoxes:
            "保存済みの検出枠がある写真を分類しました。検出枠のない \(missingBoxPhotoCount.formatted())枚だけは対象外です。"
        }
    }
}

enum CatPostureDiagnosticsStatePresentation: Equatable {
    case noTargets
    case completed
    case completedWithMissingBoxes
}

enum CatProfileTimeGroupingPresentation: Equatable {
    case calendarYears
    case age(reference: CatProfileLifeReferencePresentation)
    case yearsTogether(reference: CatProfileLifeReferencePresentation)
}

struct CatProfileTimePolicyPresentation: Equatable {
    var grouping: CatProfileTimeGroupingPresentation
    /// Growth comparisons must never mix cats with different life references.
    var showsGrowthComparison: Bool
}

struct CatProfilesPresentation: Equatable {
    var profiles: [CatProfilePresentation]
    var photoAlbumOptions: [CatProfilePhotoAlbumOptionPresentation]
    var unassignedPhotos: [CatProfilePhotoPresentation]
    /// Exact unresolved cat instances. A multi-cat photo may occur more than
    /// once with a different detector box.
    var similarityCandidates: [CatSimilarityCandidateInstance]
    var legacyExcludedPhotos: [LegacyExcludedCatPhotoPresentation]
    /// Build 13's one household-wide date. It is offered only while creating
    /// the first profile and is never silently copied to every cat.
    var legacyLifeReference: CatProfileLifeReferencePresentation?
    var postureDiagnostics: CatPostureDiagnosticsPresentation

    init(
        profiles: [CatProfilePresentation] = [],
        photoAlbumOptions: [CatProfilePhotoAlbumOptionPresentation] = [],
        unassignedPhotos: [CatProfilePhotoPresentation] = [],
        similarityCandidates: [CatSimilarityCandidateInstance] = [],
        legacyExcludedPhotos: [LegacyExcludedCatPhotoPresentation] = [],
        legacyLifeReference: CatProfileLifeReferencePresentation? = nil,
        postureDiagnostics: CatPostureDiagnosticsPresentation = .init()
    ) {
        self.profiles = profiles
        self.photoAlbumOptions = photoAlbumOptions
        self.unassignedPhotos = unassignedPhotos
        self.similarityCandidates = similarityCandidates
        self.legacyExcludedPhotos = legacyExcludedPhotos
        self.legacyLifeReference = legacyLifeReference
        self.postureDiagnostics = postureDiagnostics
    }

    var availableScopes: [CatProfileScopePresentation] {
        [.everyone] + profiles.map { .profile($0.identifier) }
    }

    func profile(identifier: String) -> CatProfilePresentation? {
        profiles.first { $0.identifier == identifier }
    }

    /// Album and Widget callers can use this when a saved profile source was
    /// deleted. Falling back to everyone avoids an empty or broken surface.
    func normalizedScope(
        _ proposedScope: CatProfileScopePresentation
    ) -> CatProfileScopePresentation {
        availableScopes.contains(proposedScope) ? proposedScope : .everyone
    }

    /// `everyone` remains calendar-based. Growth comparisons belong to an
    /// individual cat, so callers must build one profile-scoped comparison per
    /// cat instead of mixing different cats into one household timeline.
    func timePolicy(
        for scope: CatProfileScopePresentation
    ) -> CatProfileTimePolicyPresentation {
        guard case let .profile(identifier) = scope,
              let profile = profile(identifier: identifier) else {
            return CatProfileTimePolicyPresentation(
                grouping: .calendarYears,
                showsGrowthComparison: false
            )
        }

        guard let reference = profile.lifeReference else {
            return CatProfileTimePolicyPresentation(
                grouping: .calendarYears,
                showsGrowthComparison: true
            )
        }
        switch reference.kind {
        case .birthday:
            return CatProfileTimePolicyPresentation(
                grouping: .age(reference: reference),
                showsGrowthComparison: true
            )
        case .adoptionDay:
            return CatProfileTimePolicyPresentation(
                grouping: .yearsTogether(reference: reference),
                showsGrowthComparison: true
            )
        }
    }
}

struct CatProfileDraftPresentation: Equatable {
    var name = ""
    var lifeReference: CatProfileLifeReferencePresentation?
    var referencePhotoIdentifier: String?
}

enum CatProfileBatchAssignmentStatePresentation: Equatable {
    case none
    case some
    case all
}

/// Pure batch-edit state used by the assignment sheet. Keeping assignments
/// per photo prevents a mixed selection from silently losing a cat that was
/// assigned to only some of the selected photos.
struct CatPhotoAssignmentBatchPresentation: Equatable {
    let photoIdentifiers: [String]
    private(set) var assignmentsByPhotoIdentifier: [String: Set<String>]

    init(
        photoIdentifiers: [String],
        initialAssignmentsByPhotoIdentifier: [String: Set<String>]
    ) {
        var seen = Set<String>()
        let normalizedIdentifiers = photoIdentifiers.filter { seen.insert($0).inserted }
        self.photoIdentifiers = normalizedIdentifiers
        assignmentsByPhotoIdentifier = Dictionary(
            uniqueKeysWithValues: normalizedIdentifiers.map {
                ($0, initialAssignmentsByPhotoIdentifier[$0] ?? Set<String>())
            }
        )
    }

    func state(
        for profileIdentifier: String
    ) -> CatProfileBatchAssignmentStatePresentation {
        let assignedCount = photoIdentifiers.reduce(into: 0) { count, photoIdentifier in
            if assignmentsByPhotoIdentifier[photoIdentifier]?
                .contains(profileIdentifier) == true {
                count += 1
            }
        }
        if assignedCount == 0 { return .none }
        if assignedCount == photoIdentifiers.count { return .all }
        return .some
    }

    mutating func toggle(profileIdentifier: String) {
        let shouldAssignToAll = state(for: profileIdentifier) != .all
        for photoIdentifier in photoIdentifiers {
            var assignments = assignmentsByPhotoIdentifier[photoIdentifier] ?? []
            if shouldAssignToAll {
                assignments.insert(profileIdentifier)
            } else {
                assignments.remove(profileIdentifier)
            }
            assignmentsByPhotoIdentifier[photoIdentifier] = assignments
        }
    }
}
