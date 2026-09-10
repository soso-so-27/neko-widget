import CoreGraphics
import Foundation

enum CandidateObjectStatus: String, CaseIterable { case noCatRegion, oneRegion, multipleRegions, unusableRegions, failed }

// Only counts leave the per-photo processing scope. Not Codable/persisted.
struct CandidateObjectCheck {
    let status: CandidateObjectStatus
    let detectedRegions: Int
    let usableRegions: Int
    var withholdsCandidate: Bool { status == .multipleRegions }
    static let failed = Self(status: .failed, detectedRegions: 0, usableRegions: 0)
}

enum CandidateObjectProbe {
    static func check(_ image: CGImage, detect: (CGImage) throws -> [CGRect]) throws -> CandidateObjectCheck {
        try Task.checkCancellation()
        do {
            let boxes = try detect(image)
            try Task.checkCancellation()
            return assess(boxes, width: image.width, height: image.height)
        } catch is CancellationError { throw CancellationError() }
        catch { return .failed } // No error strings/paths/photos in the report.
    }

    static func assess(_ boxes: [CGRect], width: Int, height: Int) -> CandidateObjectCheck {
        guard (32...1024).contains(width), (32...1024).contains(height), boxes.count <= 3549 else { return .failed }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var usable = 0
        for box in boxes {
            guard !box.isNull, !box.isInfinite, box.size.width > 0, box.size.height > 0,
                  [box.minX, box.minY, box.maxX, box.maxY, box.width, box.height].allSatisfy(\.isFinite) else { return .failed }
            // Object detectors may predict beyond the original edge. Keep their raw
            // output unchanged; count only regions centered inside the real photo
            // and with >=32px visible extent on each axis. Never alter identity crops.
            let visible = box.intersection(bounds)
            if bounds.contains(CGPoint(x: box.midX, y: box.midY)),
               !visible.isNull, visible.width >= 32, visible.height >= 32 { usable += 1 }
        }
        let status: CandidateObjectStatus
        if usable >= 2 { status = .multipleRegions }
        else if usable != boxes.count { status = .unusableRegions }
        else if usable == 1 { status = .oneRegion }
        else { status = .noCatRegion }
        return .init(status: status, detectedRegions: boxes.count, usableRegions: usable)
    }
}

struct CandidateObjectComparison: Encodable {
    let detector = "YOLOX-Nano-0.1.1rc0"
    let detectorSHA256 = CandidateObjectDetector.modelSHA256
    let method = "raw-single-distance-passed-only;whole-photo-416-BGR;score0.3;class-agnostic-nms0.45;center-inside-and-visible32px;two-regions-withhold-only"
    let scope = "fixed-saved-human-choices-not-training;no-cat-or-failure-keeps-baseline-not-single-cat-proof;no-new-identity-inference;not-independent-accuracy"
    let baselineProposals: Int
    let baselineMatchingProposals: Int
    let baselineBothInSingleProposals: Int
    let attemptedPhotos: Int
    let statuses: [String: Int]
    let withheldPhotos: Int
    let withheldMatchingAOrBChoices: Int
    let withheldDifferentCatProposals: Int
    let withheldBothPhotos: Int
    let withheldOtherPhotos: Int
    let withheldUnreviewedOrUnsurePhotos: Int
    let savedChoicesCompared: Int
    let goalValidated = false

    init(session: CandidateReviewSession) {
        let baseline = session.run.photos.filter { $0.batchSuggestionBeforeObjectCheck != nil }
        let checked = baseline.filter { $0.objectCheck != nil }
        let withheld = checked.filter { $0.objectCheck?.withholdsCandidate == true }
        baselineProposals = baseline.count
        baselineMatchingProposals = baseline.filter { session.decisions[$0.id] == $0.batchSuggestionBeforeObjectCheck }.count
        baselineBothInSingleProposals = baseline.filter { session.decisions[$0.id] == .both }.count
        attemptedPhotos = checked.count
        statuses = Dictionary(uniqueKeysWithValues: CandidateObjectStatus.allCases.map { status in
            (status.rawValue, checked.filter { $0.objectCheck?.status == status }.count)
        })
        withheldPhotos = withheld.count
        withheldMatchingAOrBChoices = withheld.filter { session.decisions[$0.id] == $0.batchSuggestionBeforeObjectCheck }.count
        withheldDifferentCatProposals = withheld.filter {
            guard let choice = session.decisions[$0.id], choice == .a || choice == .b else { return false }
            return choice != $0.batchSuggestionBeforeObjectCheck
        }.count
        withheldBothPhotos = withheld.filter { session.decisions[$0.id] == .both }.count
        withheldOtherPhotos = withheld.filter { session.decisions[$0.id] == .other }.count
        withheldUnreviewedOrUnsurePhotos = withheld.filter { session.decisions[$0.id] == nil || session.decisions[$0.id] == .unsure }.count
        savedChoicesCompared = checked.filter { session.restoredIDs.contains($0.id) && session.decisions[$0.id] != nil }.count
    }
}
