import CoreGraphics
import Foundation

enum CandidateReviewChoice: String, CaseIterable, Hashable {
    case a, b, other, unsure
    var title: String {
        switch self {
        case .a: "猫A"
        case .b: "猫B"
        case .other: "別の猫・両方"
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

// Local-only, deliberately not Codable. No photo identifier leaves the service.
struct CandidateReviewPhoto: Identifiable {
    let id: Int
    let image: CGImage?
    let suggestion: CandidateReviewChoice?
    let issue: CandidateReviewIssue?
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
    private var previous: [Int: CandidateReviewChoice]?
    init(run: CandidateReviewRun) { self.run = run }
    var canUndo: Bool { previous != nil }
    var remaining: Int { run.photos.filter { decisions[$0.id] == nil }.count }

    func pending(_ group: CandidateReviewChoice?) -> [CandidateReviewPhoto] {
        run.photos.filter { decisions[$0.id] == nil && $0.suggestion == group }
    }

    mutating func toggleExcluded(_ id: Int) {
        guard let photo = run.photos.first(where: { $0.id == id }), photo.suggestion != nil,
              photo.image != nil, decisions[id] == nil else { return }
        if !excluded.insert(id).inserted { excluded.remove(id) }
        record("excludeToggle")
    }

    mutating func confirmGroup(_ group: CandidateReviewChoice) {
        guard group == .a || group == .b else { return }
        let values = pending(group).filter { !excluded.contains($0.id) && $0.image != nil }
        guard !values.isEmpty else { return }
        previous = decisions
        for photo in values { decisions[photo.id] = group }
        record("batchConfirmation")
    }

    mutating func choose(_ choice: CandidateReviewChoice, for id: Int) {
        guard let photo = run.photos.first(where: { $0.id == id }),
              photo.image != nil || choice == .unsure else { return }
        record("individualChoice")
        guard decisions[id] != choice else { return }
        previous = decisions
        decisions[id] = choice
    }

    mutating func undo() {
        guard let previous else { return }
        decisions = previous
        self.previous = nil
        record("undo")
    }

    mutating func record(_ action: String) {
        guard ["excludeToggle", "batchConfirmation", "individualChoice", "undo", "openPhoto", "closePhoto"].contains(action) else { return }
        actions[action, default: 0] += 1
    }

    var report: CandidateReviewReport { .init(session: self) }
}

struct CandidateReviewReport: Encodable {
    let protocolIdentifier = "pet-candidate-confirmation-usability-v1"
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
    let inputIssues: [String: Int]
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
        proposed = photos.filter { $0.suggestion != nil }.count
        confirmedAsSuggested = photos.filter { $0.suggestion != nil && session.decisions[$0.id] == $0.suggestion }.count
        changedSuggestion = photos.filter {
            guard let suggestion = $0.suggestion, let choice = session.decisions[$0.id] else { return false }
            return choice != .unsure && choice != suggestion
        }.count
        individuallyLabeledUnranked = photos.filter {
            $0.suggestion == nil && session.decisions[$0.id] != nil && session.decisions[$0.id] != .unsure
        }.count
        unsure = session.decisions.values.filter { $0 == .unsure }.count
        remaining = session.remaining
        inputIssues = Dictionary(uniqueKeysWithValues: CandidateReviewIssue.allCases.map { issue in
            (issue.rawValue, photos.filter { $0.issue == issue }.count)
        })
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
