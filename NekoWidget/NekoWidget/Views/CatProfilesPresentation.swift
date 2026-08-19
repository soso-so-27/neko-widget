import CoreGraphics
import Foundation

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

struct CatProfilePresentation: Identifiable, Equatable {
    var identifier: String
    var name: String?
    var coverPhoto: CatProfilePhotoPresentation?
    var confirmedPhotos: [CatProfilePhotoPresentation]
    var lifeReference: CatProfileLifeReferencePresentation?

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

/// The persisted aggregate deliberately contains only counts. Raw joints,
/// feature vectors, face rectangles, profile names, and PhotoKit identifiers
/// don't belong in diagnostics.
struct CatPostureDiagnosticsPresentation: Equatable {
    var targetPhotoCount: Int
    var rawPoseObservedPhotoCount: Int
    /// Nil represents a snapshot produced before match-stage instrumentation.
    var matchedPosePhotoCount: Int?
    var qualityPassedPhotoCount: Int?
    var geometryPassedPhotoCount: Int?
    var classifiedPhotoCount: Int
    var unclassifiedPhotoCount: Int
    var pendingPhotoCount: Int
    var sleepingPhotoCount: Int
    var bellyUpPhotoCount: Int
    var loafPhotoCount: Int

    init(
        targetPhotoCount: Int = 0,
        rawPoseObservedPhotoCount: Int = 0,
        matchedPosePhotoCount: Int? = nil,
        qualityPassedPhotoCount: Int? = nil,
        geometryPassedPhotoCount: Int? = nil,
        classifiedPhotoCount: Int = 0,
        unclassifiedPhotoCount: Int = 0,
        pendingPhotoCount: Int = 0,
        sleepingPhotoCount: Int = 0,
        bellyUpPhotoCount: Int = 0,
        loafPhotoCount: Int = 0
    ) {
        self.targetPhotoCount = max(0, targetPhotoCount)
        self.rawPoseObservedPhotoCount = max(0, rawPoseObservedPhotoCount)
        self.matchedPosePhotoCount = matchedPosePhotoCount.map { max(0, $0) }
        self.qualityPassedPhotoCount = qualityPassedPhotoCount.map { max(0, $0) }
        self.geometryPassedPhotoCount = geometryPassedPhotoCount.map { max(0, $0) }
        self.classifiedPhotoCount = max(0, classifiedPhotoCount)
        self.unclassifiedPhotoCount = max(0, unclassifiedPhotoCount)
        self.pendingPhotoCount = max(0, pendingPhotoCount)
        self.sleepingPhotoCount = max(0, sleepingPhotoCount)
        self.bellyUpPhotoCount = max(0, bellyUpPhotoCount)
        self.loafPhotoCount = max(0, loafPhotoCount)
    }

    var state: CatPostureDiagnosticsStatePresentation {
        if pendingPhotoCount > 0 { return .incomplete }
        if targetPhotoCount == 0 { return .noTargets }
        if classifiedPhotoCount > 0 { return .completedWithMatches }
        if rawPoseObservedPhotoCount == 0 { return .completedWithoutPoseObservations }
        if matchedPosePhotoCount == 0 { return .completedWithoutCatMatches }
        if qualityPassedPhotoCount == 0 { return .completedWithoutQualityMatches }
        if geometryPassedPhotoCount == 0 { return .completedWithoutGeometryMatches }
        if matchedPosePhotoCount != nil { return .completedWithoutRuleMatches }
        return .completedWithoutDetailedCause
    }

    var statusTitle: String {
        switch state {
        case .noTargets: "確認する猫候補がありません"
        case .incomplete: "姿勢分類に未完了があります"
        case .completedWithMatches: "姿勢分類は完了しています"
        case .completedWithoutPoseObservations: "骨格候補を取得できませんでした"
        case .completedWithoutCatMatches: "骨格候補を猫に対応付けられませんでした"
        case .completedWithoutQualityMatches: "関節の信頼度が判定条件に届きませんでした"
        case .completedWithoutGeometryMatches: "姿勢の形が判定条件に一致しませんでした"
        case .completedWithoutRuleMatches:
            "現在の判定条件に一致した写真がありません"
        case .completedWithoutDetailedCause:
            "姿勢分類は完了しましたが、分類結果は0件です"
        }
    }

    var statusDetail: String {
        switch state {
        case .noTargets:
            "猫候補の写真が見つかると、ここに分類状況が表示されます。"
        case .incomplete:
            "未完了の \(pendingPhotoCount.formatted())枚だけを再確認できます。最初から再スキャンする必要はありません。"
        case .completedWithMatches:
            "寝顔・へそ天・香箱は、判定できた写真が1枚以上ある場合だけアルバムに表示します。"
        case .completedWithoutPoseObservations:
            "対象写真の確認は完了しています。再スキャン待ちではありません。"
        case .completedWithoutCatMatches:
            "Visionは骨格候補を返しましたが、猫の検出枠との対応付けで分類できませんでした。"
        case .completedWithoutQualityMatches:
            "猫との対応付けはできましたが、判定に必要な関節を十分な信頼度で取得できませんでした。"
        case .completedWithoutGeometryMatches:
            "必要な関節は取得できましたが、寝顔・へそ天・香箱の形には一致しませんでした。"
        case .completedWithoutRuleMatches:
            "骨格候補を猫に対応付けましたが、寝顔・へそ天・香箱の条件を通った写真はありません。"
        case .completedWithoutDetailedCause:
            "対象写真の確認は完了しています。次回の解析では、対応付けと判定条件を分けて確認できます。"
        }
    }
}

enum CatPostureDiagnosticsStatePresentation: Equatable {
    case noTargets
    case incomplete
    case completedWithMatches
    case completedWithoutPoseObservations
    case completedWithoutCatMatches
    case completedWithoutQualityMatches
    case completedWithoutGeometryMatches
    case completedWithoutRuleMatches
    case completedWithoutDetailedCause
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
    var unassignedPhotos: [CatProfilePhotoPresentation]
    var legacyExcludedPhotos: [LegacyExcludedCatPhotoPresentation]
    /// Build 13's one household-wide date. It is offered only while creating
    /// the first profile and is never silently copied to every cat.
    var legacyLifeReference: CatProfileLifeReferencePresentation?
    var postureDiagnostics: CatPostureDiagnosticsPresentation

    init(
        profiles: [CatProfilePresentation] = [],
        unassignedPhotos: [CatProfilePhotoPresentation] = [],
        legacyExcludedPhotos: [LegacyExcludedCatPhotoPresentation] = [],
        legacyLifeReference: CatProfileLifeReferencePresentation? = nil,
        postureDiagnostics: CatPostureDiagnosticsPresentation = .init()
    ) {
        self.profiles = profiles
        self.unassignedPhotos = unassignedPhotos
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

    /// `everyone` remains calendar-based and intentionally has no mixed-cat
    /// growth comparison. Age and years-together groupings live only inside an
    /// individual cat profile.
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
