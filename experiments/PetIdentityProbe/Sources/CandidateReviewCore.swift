import CoreGraphics
import Foundation

enum CandidateReviewChoice: String, CaseIterable, Hashable, Codable {
    case a, b, both, other, unsure
    var title: String {
        switch self {
        case .a: "猫A"
        case .b: "猫B"
        case .both: "猫Aと猫B"
        case .other: "別の猫"
        case .unsure: "わからない"
        }
    }
}

enum CandidateReviewIssue: String, CaseIterable {
    case unavailable, noSingleCat, repeatedBurst, similarPhoto, equalScores, invalidEmbedding
    var title: String {
        switch self {
        case .unavailable: "写真を読み出せません"
        case .noSingleCat: "猫1匹の範囲を決められません"
        case .repeatedBurst: "見本・既選択と同じ連写です"
        case .similarPhoto: "見本・既選択にとても似た写真です"
        case .equalScores: "候補が同点です"
        case .invalidEmbedding: "特徴量を確認できません"
        }
    }
}

// Existing detector/crop outcomes, not a claim about how many cats are actually pictured.
// Kept on-screen only; the report exports counts grouped by these fixed categories.
struct CandidateCropDiagnostic {
    let originalIssue: IdentityInputIssue?
    let recoveryStatus: IdentityRecoveryStatus

    var title: String {
        switch recoveryStatus {
        case .noCandidate: "追加検出でも猫が見つかりません"
        case .multipleCandidates: "検出範囲が複数あります"
        case .invalidCrop: "検出した範囲を切り抜けません"
        case .conversionFailed: "検出用の画像を作れません"
        case .detectionFailed: "追加の検出処理でエラー"
        case .resultsUnavailable: "追加の検出結果がありません"
        case .noImage: "画像を読み出せません"
        case .originalIneligible:
            if originalIssue == .multipleCats { "検出範囲が複数あります" }
            else { originalIssue?.title ?? "検出の詳細を確認できません" }
        case .originalReused, .recovered: "検出の詳細を確認できません"
        }
    }
}

// Local-only, deliberately not Codable. No photo identifier leaves the service.
struct CandidateReviewPhoto: Identifiable {
    let id: Int
    let image: CGImage?
    let suggestion: CandidateReviewChoice?
    let issue: CandidateReviewIssue?
    var cropDiagnostic: CandidateCropDiagnostic? = nil
    var regionReview: CandidateRegionReview? = nil

    // Region-level suggestions must never enter a photo-level bulk confirmation.
    var batchSuggestion: CandidateReviewChoice? {
        guard image != nil, issue == nil, regionReview == nil,
              suggestion == .a || suggestion == .b else { return nil }
        return suggestion
    }

    var issueTitle: String? {
        if let regionReview { return regionReview.title }
        return issue == .noSingleCat ? (cropDiagnostic?.title ?? issue?.title) : issue?.title
    }
}

struct CandidateReviewRun {
    let photos: [CandidateReviewPhoto]
    let referenceA: CGImage?
    let referenceB: CGImage?
}

struct CandidateReviewSession {
    let run: CandidateReviewRun
    private(set) var decisions: [Int: CandidateReviewChoice] = [:]
    private(set) var excluded: Set<Int> = []
    private(set) var actions: [String: Int] = [:]
    struct UndoState {
        let decisions: [Int: CandidateReviewChoice]
        let restoredIDs: Set<Int>
    }
    private(set) var restoredIDs: Set<Int> = []
    private(set) var previous: UndoState?
    init(run: CandidateReviewRun, progress: CandidateSavedProgress? = nil, identifiers: [String] = []) {
        self.run = run
        if let progress {
            func mapped(_ values: [String: CandidateReviewChoice]) -> [Int: CandidateReviewChoice] {
                Dictionary(uniqueKeysWithValues: identifiers.enumerated().compactMap { index, id in
                    values[id].map { (index, $0) }
                })
            }
            decisions = mapped(progress.decisions)
            restoredIDs = Set(decisions.keys)
            excluded = Set(identifiers.enumerated().compactMap { progress.excluded.contains($0.element) ? $0.offset : nil })
            previous = progress.previousDecisions.map { values in
                let choices = mapped(values)
                return UndoState(decisions: choices, restoredIDs: Set(choices.keys))
            }
        }
    }
    var canUndo: Bool { previous != nil }
    var remaining: Int { run.photos.filter { decisions[$0.id] == nil }.count }

    func pending(_ group: CandidateReviewChoice?) -> [CandidateReviewPhoto] {
        run.photos.filter { decisions[$0.id] == nil && $0.batchSuggestion == group }
    }

    mutating func toggleExcluded(_ id: Int) {
        guard let photo = run.photos.first(where: { $0.id == id }), photo.batchSuggestion != nil,
              photo.image != nil, decisions[id] == nil else { return }
        if !excluded.insert(id).inserted { excluded.remove(id) }
        record("excludeToggle")
    }

    mutating func confirmGroup(_ group: CandidateReviewChoice) {
        guard group == .a || group == .b else { return }
        let values = pending(group).filter { !excluded.contains($0.id) && $0.image != nil }
        guard !values.isEmpty else { return }
        previous = .init(decisions: decisions, restoredIDs: restoredIDs)
        for photo in values { decisions[photo.id] = group }
        record("batchConfirmation")
    }

    mutating func choose(_ choice: CandidateReviewChoice, for id: Int) {
        guard let photo = run.photos.first(where: { $0.id == id }),
              photo.image != nil || choice == .unsure else { return }
        record("individualChoice")
        guard decisions[id] != choice else { return }
        previous = .init(decisions: decisions, restoredIDs: restoredIDs)
        restoredIDs.remove(id)
        decisions[id] = choice
    }

    mutating func undo() {
        guard let previous else { return }
        decisions = previous.decisions
        restoredIDs = previous.restoredIDs
        self.previous = nil
        record("undo")
    }

    mutating func unconfirm(_ id: Int) {
        guard decisions[id] != nil else { return }
        previous = .init(decisions: decisions, restoredIDs: restoredIDs)
        decisions.removeValue(forKey: id); restoredIDs.remove(id)
        record("individualRemoval")
    }

    mutating func record(_ action: String) {
        guard ["excludeToggle", "batchConfirmation", "individualChoice", "individualRemoval", "undo", "openPhoto", "closePhoto"].contains(action) else { return }
        actions[action, default: 0] += 1
    }

    var report: CandidateReviewReport { .init(session: self) }
}

struct CandidateCropFailureCount: Encodable {
    let originalIssue: String
    let recoveryStatus: String
    let count: Int
}

struct CandidateReviewReport: Encodable {
    let protocolIdentifier = "pet-candidate-confirmation-usability-v4"
    let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    let modelSHA256 = ProbeModelFile.sha256
    let method = "second-nearest-of-five-per-cat;ranking-only;no-acceptance-or-online-learning"
    let scope = "self-reviewed-selected-photos;confirmation-bias-possible;not-independent-accuracy-or-manual-ab-test"
    let selected: Int
    let proposed: Int
    let confirmedAsSuggested: Int
    let changedSuggestion: Int
    let individuallyLabeledUnranked: Int
    let unsure: Int
    let remaining: Int
    let previouslyConfirmed: Int
    let progressScope = "human-decisions-restored-only;restored-excluded-from-current-suggestion-comparison;actions-since-open;not-accuracy"
    let inputIssues: [String: Int]
    let noSingleCatBreakdown: [CandidateCropFailureCount]
    let noSingleCatBreakdownScope = "existing-detector-and-crop-status-only;multiple-regions-not-confirmed-cat-count;no-additional-detection-or-identity-accuracy-claim"
    let multiRegionReview: CandidateRegionReviewCounts
    let reviewActions: [String: Int]
    let totalReviewActions: Int
    let hypotheticalManualLabelTaps: Int
    let manualComparison = "counterfactual-one-label-tap-per-photo;not-measured;excludes-selection-scrolling-and-viewing-time;not-evidence-of-effort-reduction"
    let photosIncluded = false
    let identifiersIncluded = false
    let embeddingsIncluded = false
    let individualPredictionsIncluded = false
    let productionDataChanged = false
    let accuracyEvaluated = false
    let productValidated = false

    init(session: CandidateReviewSession) {
        let photos = session.run.photos
        selected = photos.count
        proposed = photos.filter { $0.batchSuggestion != nil }.count
        previouslyConfirmed = session.restoredIDs.count
        confirmedAsSuggested = photos.filter { !session.restoredIDs.contains($0.id) && $0.batchSuggestion != nil && session.decisions[$0.id] == $0.batchSuggestion }.count
        changedSuggestion = photos.filter {
            guard !session.restoredIDs.contains($0.id), let suggestion = $0.batchSuggestion, let choice = session.decisions[$0.id] else { return false }
            return choice != .unsure && choice != suggestion
        }.count
        individuallyLabeledUnranked = photos.filter {
            !session.restoredIDs.contains($0.id) && $0.batchSuggestion == nil && session.decisions[$0.id] != nil && session.decisions[$0.id] != .unsure
        }.count
        unsure = session.decisions.filter { !session.restoredIDs.contains($0.key) && $0.value == .unsure }.count
        remaining = session.remaining
        inputIssues = Dictionary(uniqueKeysWithValues: CandidateReviewIssue.allCases.map { issue in
            (issue.rawValue, photos.filter { $0.issue == issue }.count)
        })
        // Each noSingleCat photo appears in exactly one row, including missing diagnostics.
        let grouped = Dictionary(grouping: photos.filter { $0.issue == .noSingleCat }) { photo in
            (photo.cropDiagnostic?.originalIssue?.rawValue ?? "unrecorded") + "|"
                + (photo.cropDiagnostic?.recoveryStatus.rawValue ?? "unrecorded")
        }
        noSingleCatBreakdown = grouped.keys.sorted().compactMap { key in
            guard let group = grouped[key], let photo = group.first else { return nil }
            return CandidateCropFailureCount(
                originalIssue: photo.cropDiagnostic?.originalIssue?.rawValue ?? "unrecorded",
                recoveryStatus: photo.cropDiagnostic?.recoveryStatus.rawValue ?? "unrecorded",
                count: group.count)
        }
        multiRegionReview = .init(session: session)
        reviewActions = session.actions
        totalReviewActions = session.actions.values.reduce(0, +)
        hypotheticalManualLabelTaps = photos.count
    }

    var json: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

enum CandidateReviewSelection {
    static let limit = 24

    // Only the currently saved selection is known; this is not an all-time history.
    static func excludingSaved(_ ids: [String], saved: [IdentityPhotoSlot: [String]]) -> [String] {
        let known = Set(saved.values.flatMap { $0 })
        return ids.filter { !known.contains($0) }
    }

    static func filteringKnownPhotos(_ ids: [String], saved: [IdentityPhotoSlot: [String]]) throws -> [String] {
        try IdentityRecoveryComparisonCore.validateSelection(saved)
        guard saved[.referenceA]?.count == 5, saved[.referenceB]?.count == 5 else {
            throw IdentityPhotoFailure(message: "保存済みの猫A/Bの見本が各5枚必要です。「猫の検出を確認する」で不足分だけ追加できます。")
        }
        guard (1...limit).contains(ids.count), ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 }),
              Set(ids).count == ids.count else {
            throw IdentityPhotoFailure(message: "写真を1〜24枚選んでください。選択は消していません。")
        }
        return excludingSaved(ids, saved: saved)
    }

    static func validate(_ ids: [String], saved: [IdentityPhotoSlot: [String]]) throws {
        guard try filteringKnownPhotos(ids, saved: saved).count == ids.count else {
            throw IdentityPhotoFailure(message: "保存済みの見本・判定写真との重なりを確認できませんでした。この画面を開き直すと自動で外します。選択は消していません。")
        }
    }
}
