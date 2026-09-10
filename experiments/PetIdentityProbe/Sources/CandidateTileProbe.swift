import CoreGraphics
import Foundation

enum CandidateTileStatus: String, CaseIterable { case noSeparateRegions, separateRegions, incomplete }

// No geometry, images, model vectors or individual-photo identifiers are encoded.
struct CandidateTileCheck {
    let status: CandidateTileStatus
    let requests: Int
    let validRegions: Int
    var withholdsCandidate: Bool { status == .separateRegions }
}

enum CandidateTileProbe {
    // One fixed, bounded candidate-only check. Never searches alternate grids or
    // calibrates from saved human decisions. Detection regions are not cat counts.
    static func tileRects(width: Int, height: Int) -> [CGRect] {
        guard (64...1024).contains(width), (64...1024).contains(height) else { return [] }
        let w = Int(ceil(Double(width) * 0.6)), h = Int(ceil(Double(height) * 0.6))
        return [0, height - h].flatMap { y in
            [0, width - w].map { x in CGRect(x: x, y: y, width: w, height: h) }
        }
    }

    static func mappedBox(_ box: CGRect, tile: CGRect, width: Int, height: Int) -> CGRect? {
        guard (64...1024).contains(width), (64...1024).contains(height),
              !box.isNull, !box.isInfinite, !tile.isNull, !tile.isInfinite,
              [box.minX, box.minY, box.width, box.height, box.maxX, box.maxY,
               tile.minX, tile.minY, tile.width, tile.height, tile.maxX, tile.maxY].allSatisfy(\.isFinite),
              box.width > 0, box.height > 0, box.minX >= 0, box.minY >= 0,
              box.maxX <= 1, box.maxY <= 1,
              tile.width > 0, tile.height > 0, tile.minX >= 0, tile.minY >= 0,
              tile.maxX <= CGFloat(width), tile.maxY <= CGFloat(height),
              tile == tile.integral,
              let local = IdentityImagePipeline.cropRect(box, width: Int(tile.width), height: Int(tile.height)) else { return nil }
        // Cut edges are artificial. True outer edges of the original image may
        // contain an animal. A 2px exclusion is fixed before observing outcomes.
        if tile.minX > 0 && local.minX <= 2 { return nil }
        if tile.minY > 0 && local.minY <= 2 { return nil }
        if tile.maxX < CGFloat(width) && local.maxX >= tile.width - 2 { return nil }
        if tile.maxY < CGFloat(height) && local.maxY >= tile.height - 2 { return nil }
        return local.offsetBy(dx: tile.minX, dy: tile.minY)
    }

    static func hasSeparatedPair(_ boxes: [CGRect]) -> Bool {
        let valid = boxes.filter { box in
            !box.isNull && !box.isInfinite && box.width > 0 && box.height > 0 &&
            [box.minX, box.minY, box.maxX, box.maxY].allSatisfy(\.isFinite)
        }
        for i in valid.indices {
            for j in valid.indices where j > i {
                let a = valid[i], b = valid[j]
                // More than a pixel gap. Nested, intersecting and touching boxes
                // (including duplicate detections of one animal) are not a pair.
                if a.maxX + 1 < b.minX || b.maxX + 1 < a.minX ||
                   a.maxY + 1 < b.minY || b.maxY + 1 < a.minY { return true }
            }
        }
        return false
    }

    static func check(_ image: CGImage,
                      detect: (CGImage) throws -> (diagnostic: IdentityAnimalDetectionDiagnostic, boxes: [CGRect]) = {
                          let result = try IdentityImagePipeline.inspectCatCrop($0)
                          return (result.diagnostic, result.acceptedBoxes)
                      }) throws -> CandidateTileCheck {
        try Task.checkCancellation()
        let tiles = tileRects(width: image.width, height: image.height)
        guard tiles.count == 4, let normalized = IdentityImageFormatProbe.standardRGB(image) else {
            return .init(status: .incomplete, requests: 0, validRegions: 0)
        }
        var boxes: [CGRect] = [], requests = 0, complete = true
        for tile in tiles {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let crop = normalized.cropping(to: tile) else { complete = false; return }
                requests += 1
                do {
                    let result = try detect(crop)
                    try Task.checkCancellation()
                    guard result.diagnostic.resultsAvailable,
                          result.diagnostic.acceptedCatObservationCount == result.boxes.count,
                          result.boxes.count <= 4 else { complete = false; return }
                    for box in result.boxes {
                        guard !box.isNull, !box.isInfinite,
                              [box.minX, box.minY, box.width, box.height, box.maxX, box.maxY].allSatisfy(\.isFinite),
                              box.width > 0, box.height > 0, box.minX >= 0, box.minY >= 0,
                              box.maxX <= 1, box.maxY <= 1 else { complete = false; continue }
                        if let mapped = mappedBox(box, tile: tile, width: image.width, height: image.height) {
                            boxes.append(mapped)
                        }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { complete = false } // Do not expose error messages/paths.
            }
        }
        try Task.checkCancellation()
        return .init(status: complete ? (hasSeparatedPair(boxes) ? .separateRegions : .noSeparateRegions) : .incomplete,
                     requests: requests, validRegions: boxes.count)
    }
}

struct CandidateTileComparison: Encodable {
    let method = "raw-single-and-distance-passed-only;four-overlapping-60percent-tiles;vision-r2-cat-label0.5;cut-edge-2px-exclusion;original-pixel-mapping-min32;separated-gap-over1px;no-new-identity-inference"
    let scope = "candidate-withholding-only;regions-not-cat-count;incomplete-keeps-baseline;fixed-human-choices-not-training;restored-meaning-unchanged;not-independent-accuracy"
    let baselineProposals: Int
    let baselineMatchingProposals: Int
    let baselineBothInSingleProposals: Int
    let attemptedPhotos: Int
    let requestCount: Int
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
        let baseline = session.run.photos.filter { $0.batchSuggestionBeforeTileCheck != nil }
        let checked = baseline.filter { $0.tileCheck != nil }
        let withheld = checked.filter { $0.tileCheck?.withholdsCandidate == true }
        baselineProposals = baseline.count
        baselineMatchingProposals = baseline.filter { session.decisions[$0.id] == $0.batchSuggestionBeforeTileCheck }.count
        baselineBothInSingleProposals = baseline.filter { session.decisions[$0.id] == .both }.count
        attemptedPhotos = checked.count
        requestCount = checked.reduce(0) { $0 + ($1.tileCheck?.requests ?? 0) }
        statuses = Dictionary(uniqueKeysWithValues: CandidateTileStatus.allCases.map { status in
            (status.rawValue, checked.filter { $0.tileCheck?.status == status }.count)
        })
        withheldPhotos = withheld.count
        withheldMatchingAOrBChoices = withheld.filter { session.decisions[$0.id] == $0.batchSuggestionBeforeTileCheck }.count
        withheldDifferentCatProposals = withheld.filter {
            guard let choice = session.decisions[$0.id], choice == .a || choice == .b else { return false }
            return choice != $0.batchSuggestionBeforeTileCheck
        }.count
        withheldBothPhotos = withheld.filter { session.decisions[$0.id] == .both }.count
        withheldOtherPhotos = withheld.filter { session.decisions[$0.id] == .other }.count
        withheldUnreviewedOrUnsurePhotos = withheld.filter { session.decisions[$0.id] == nil || session.decisions[$0.id] == .unsure }.count
        savedChoicesCompared = checked.filter { session.restoredIDs.contains($0.id) && session.decisions[$0.id] != nil }.count
    }
}
