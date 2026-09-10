import CoreGraphics
import Foundation

// Screen-only information. Neither geometry, crops nor individual rankings are Codable.
struct CandidateReviewRegion: Identifiable {
    let id: Int
    let box: CGRect // Actual crop, normalized in Vision's bottom-left coordinates.
    let image: CGImage
    let ranking: IdentityRankingOutcome

    var suggestion: CandidateReviewChoice? {
        switch ranking {
        case .a: .a
        case .b: .b
        default: nil
        }
    }
    var title: String {
        if let suggestion { return "\(suggestion.title)の候補" }
        return ranking == .equalScores ? "候補が同点" : "候補を出せません"
    }
}

struct CandidateRegionReview {
    enum Status: String, CaseIterable {
        case prepared, tooManyRegions, invalidRegions
    }
    let status: Status
    var regions: [CandidateReviewRegion] = []

    var title: String {
        switch status {
        case .prepared: "範囲ごとの候補を確認"
        case .tooManyRegions: "検出範囲が多いため、写真全体で確認"
        case .invalidRegions: "範囲を切り抜けないため、写真全体で確認"
        }
    }
}

enum CandidateRegionProbe {
    // A processing bound, not a supported-cat count. Never silently take the first N boxes.
    static let maximumRegions = 4

    static func review(image: CGImage?, originalIssue: IdentityInputIssue?,
                       recoveryStatus: IdentityRecoveryStatus,
                       diagnostic: IdentityAnimalDetectionDiagnostic?, boxes: [CGRect],
                       registrationA: [[Float]?], registrationB: [[Float]?],
                       embed: (CGImage) throws -> [Float]) throws -> CandidateRegionReview? {
        try Task.checkCancellation()
        guard originalIssue == .multipleCats, recoveryStatus == .originalIneligible else { return nil }
        guard let image, let diagnostic, diagnostic.resultsAvailable,
              diagnostic.acceptedCatObservationCount == boxes.count, boxes.count >= 2 else {
            return .init(status: .invalidRegions)
        }
        guard boxes.count <= maximumRegions else { return .init(status: .tooManyRegions) }

        var crops: [(box: CGRect, crop: CGImage, preview: CGImage)] = []
        for box in boxes {
            try Task.checkCancellation()
            guard let rect = IdentityImagePipeline.cropRect(box, width: image.width, height: image.height),
                  let crop = image.cropping(to: rect) else { return .init(status: .invalidRegions) }
            let scale = min(1, 160.0 / Double(max(crop.width, crop.height)))
            guard let preview = IdentityImagePipeline.resized(crop,
                width: max(1, Int(Double(crop.width) * scale)),
                height: max(1, Int(Double(crop.height) * scale))) else { return .init(status: .invalidRegions) }
            let width = CGFloat(image.width), height = CGFloat(image.height)
            let actualBox = CGRect(x: rect.minX / width, y: 1 - rect.maxY / height,
                                   width: rect.width / width, height: rect.height / height)
            crops.append((actualBox, crop, preview))
        }
        // Reuse the original detections exactly: no retries, box merging, largest-box selection,
        // threshold changes, or claim that a box represents a distinct cat.
        let vectors: [[Float]?] = try crops.map { item in
            try Task.checkCancellation()
            return try embed(item.crop)
        }
        let rankings = try IdentityEvaluationCore.reviewSuggestions(
            registrationA: registrationA, registrationB: registrationB, inputs: vectors)
        try Task.checkCancellation()
        return .init(status: .prepared, regions: zip(crops, rankings).enumerated().map { index, item in
            .init(id: index, box: item.0.box, image: item.0.preview, ranking: item.1)
        })
    }

    static func displayRect(_ box: CGRect, image: CGSize, container: CGSize) -> CGRect? {
        guard [image.width, image.height, container.width, container.height,
               box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite),
              image.width > 0, image.height > 0, container.width > 0, container.height > 0,
              box.width > 0, box.height > 0 else { return nil }
        let clipped = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        let scale = min(container.width / image.width, container.height / image.height)
        let width = image.width * scale, height = image.height * scale
        return CGRect(x: (container.width - width) / 2 + clipped.minX * width,
                      y: (container.height - height) / 2 + (1 - clipped.maxY) * height,
                      width: clipped.width * width, height: clipped.height * height)
    }
}

struct CandidateRegionReviewCounts: Encodable {
    let scope = "original-multiple-boxes-only;no-detection-retry-or-box-merging;per-region-ranking-not-cat-count-or-accuracy;individual-photo-confirmation-only"
    let maximumRegionsPerPhoto = CandidateRegionProbe.maximumRegions
    let attemptedPhotos: Int
    let photoStatuses: [String: Int]
    let photosWithSuggestions: Int
    let preparedRegions: Int
    let regionsWithSuggestions: Int
    let confirmedChoices: [String: Int]
    let remainingPhotos: Int

    init(session: CandidateReviewSession) {
        let photos = session.run.photos.filter { $0.regionReview != nil }
        let regions = photos.flatMap { $0.regionReview?.regions ?? [] }
        attemptedPhotos = photos.count
        photoStatuses = Dictionary(uniqueKeysWithValues: CandidateRegionReview.Status.allCases.map { status in
            (status.rawValue, photos.filter { $0.regionReview?.status == status }.count)
        })
        photosWithSuggestions = photos.filter {
            $0.regionReview?.regions.contains(where: { $0.suggestion != nil }) == true
        }.count
        preparedRegions = regions.count
        regionsWithSuggestions = regions.filter { $0.suggestion != nil }.count
        confirmedChoices = Dictionary(uniqueKeysWithValues: CandidateReviewChoice.allCases.map { choice in
            (choice.rawValue, photos.filter { session.decisions[$0.id] == choice }.count)
        })
        remainingPhotos = photos.filter { session.decisions[$0.id] == nil }.count
    }
}
