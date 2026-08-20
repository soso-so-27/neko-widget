import CoreGraphics
import Foundation

/// A single cat-shaped subject presented to the reviewer.
///
/// `identifier` identifies the subject instance, not the photo. Two cats in
/// one photo therefore share `assetLocalIdentifier` but have different IDs
/// and bounding boxes. Nothing in this presentation type represents a saved
/// profile membership; membership is written only after an explicit action.
struct CatSimilarityReviewCandidatePresentation: Identifiable, Equatable {
    let identifier: String
    let assetLocalIdentifier: String
    let subjectBoundingBox: CGRect

    var id: String { identifier }
}

struct CatSimilarityReviewProfilePresentation: Identifiable, Equatable {
    let identifier: String
    let name: String
    let anchorPhotoCount: Int
    let coverCandidate: CatSimilarityReviewCandidatePresentation?

    var id: String { identifier }

    var displayName: String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "名前未設定" : normalized
    }

    var hasAnchor: Bool { anchorPhotoCount > 0 }

    init(
        identifier: String,
        name: String,
        anchorPhotoCount: Int,
        coverCandidate: CatSimilarityReviewCandidatePresentation? = nil
    ) {
        self.identifier = identifier
        self.name = name
        self.anchorPhotoCount = max(0, anchorPhotoCount)
        self.coverCandidate = coverCandidate
    }
}

/// A provisional similarity cluster. It has no authority to change profile
/// membership. `suggestedProfileIdentifier` only changes the question shown
/// to the user and the ordering of buttons.
struct CatSimilarityReviewGroupPresentation: Identifiable, Equatable {
    let identifier: String
    let candidates: [CatSimilarityReviewCandidatePresentation]
    let suggestedProfileIdentifier: String?

    var id: String { identifier }
}

enum CatSimilarityReviewUnavailableReason: Equatable {
    case noProfiles
}

enum CatSimilarityReviewPhase: Equatable {
    /// Profiles or their user-selected reference photos are not ready yet.
    case unavailable(CatSimilarityReviewUnavailableReason)
    /// Similarity calculation has not started. Counts are candidate instances,
    /// so two cats found in one photo count as two candidates.
    case ready(candidateCount: Int, targetGroupCount: Int)
    case grouping(completedCandidateCount: Int, totalCandidateCount: Int)
    case reviewing
    case empty
    case failed(message: String)
    case cancelled
    case completed(confirmedGroupCount: Int, deferredGroupCount: Int)
}

struct CatSimilarityReviewProgressPresentation: Equatable {
    let completedCount: Int
    let totalCount: Int

    var fraction: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }

    var label: String {
        "\(completedCount.formatted())/\(totalCount.formatted())"
    }
}

/// Read-only state consumed by `CatSimilarityReviewView`.
///
/// The service/store remains the source of truth and replaces this value after
/// each callback. The View never mutates a candidate into a profile by itself.
struct CatSimilarityReviewPresentation: Equatable {
    let phase: CatSimilarityReviewPhase
    let profiles: [CatSimilarityReviewProfilePresentation]
    let groups: [CatSimilarityReviewGroupPresentation]
    let currentGroupIndex: Int
    /// Instances whose image was no longer available locally or whose
    /// FeaturePrint could not be generated. They remain unassigned.
    let ungroupedCandidateCount: Int
    /// A recoverable review-state message. Unlike `.failed`, this keeps the
    /// current groups and progress intact so the user can choose another action.
    let inlineNotice: String?
    /// Profile choices rejected for only the current provisional group.
    let disabledProfileIdentifiers: Set<String>

    init(
        phase: CatSimilarityReviewPhase,
        profiles: [CatSimilarityReviewProfilePresentation] = [],
        groups: [CatSimilarityReviewGroupPresentation] = [],
        currentGroupIndex: Int = 0,
        ungroupedCandidateCount: Int = 0,
        inlineNotice: String? = nil,
        disabledProfileIdentifiers: Set<String> = []
    ) {
        self.phase = phase
        self.profiles = profiles
        self.groups = groups
        self.currentGroupIndex = max(0, currentGroupIndex)
        self.ungroupedCandidateCount = max(0, ungroupedCandidateCount)
        self.inlineNotice = inlineNotice
        self.disabledProfileIdentifiers = disabledProfileIdentifiers
    }

    /// A review without a destination profile cannot confirm anything. This
    /// is the only prerequisite that blocks unsupervised grouping.
    var displayPhase: CatSimilarityReviewPhase {
        guard !profiles.isEmpty else {
            return .unavailable(.noProfiles)
        }
        return phase
    }

    var currentGroup: CatSimilarityReviewGroupPresentation? {
        guard groups.indices.contains(currentGroupIndex) else { return nil }
        return groups[currentGroupIndex]
    }

    /// One profile membership stores one subject rectangle per photo. Two
    /// detector instances from the same photo therefore cannot be confirmed
    /// to one profile as a batch; the reviewer must split the group first.
    var currentGroupRequiresSplitBeforeConfirmation: Bool {
        guard let currentGroup else { return false }
        let assetIdentifiers = currentGroup.candidates.map(\.assetLocalIdentifier)
        return Set(assetIdentifiers).count != assetIdentifiers.count
    }

    func profileConfirmationIsDisabled(_ profileIdentifier: String) -> Bool {
        currentGroupRequiresSplitBeforeConfirmation
            || disabledProfileIdentifiers.contains(profileIdentifier)
    }

    var reviewProgress: CatSimilarityReviewProgressPresentation {
        guard !groups.isEmpty else {
            return CatSimilarityReviewProgressPresentation(
                completedCount: 0,
                totalCount: 0
            )
        }
        return CatSimilarityReviewProgressPresentation(
            completedCount: min(currentGroupIndex + 1, groups.count),
            totalCount: groups.count
        )
    }

    var generationProgress: CatSimilarityReviewProgressPresentation? {
        guard case let .grouping(completed, total) = phase else { return nil }
        let normalizedTotal = max(0, total)
        return CatSimilarityReviewProgressPresentation(
            completedCount: min(max(0, completed), normalizedTotal),
            totalCount: normalizedTotal
        )
    }

    var currentQuestion: String {
        guard let profile = suggestedProfile else {
            return "このグループはどの子？"
        }
        return "このグループは全部「\(profile.displayName)」？"
    }

    var suggestedProfile: CatSimilarityReviewProfilePresentation? {
        guard let identifier = currentGroup?.suggestedProfileIdentifier else {
            return nil
        }
        return profiles.first { $0.identifier == identifier }
    }

    /// Puts the proposal first without granting it any persistence authority.
    var profilesForCurrentQuestion: [CatSimilarityReviewProfilePresentation] {
        guard let suggestedProfile else { return profiles }
        return [suggestedProfile] + profiles.filter {
            $0.identifier != suggestedProfile.identifier
        }
    }

    /// Reference photos improve a future suggestion, but never gate the
    /// unsupervised grouping or confirmation flow.
    var profilesWithoutAnchors: [CatSimilarityReviewProfilePresentation] {
        profiles.filter { !$0.hasAnchor }
    }
}
