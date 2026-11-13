#if DEBUG || INTERNAL_PRESENTATION
// Test builds only (InternalBuildPresentationAvailability). The App Store
// product compiles none of this: production_candidate.py rejects DEBUG and
// INTERNAL_PRESENTATION for that build.
//
// Explains why photos the owner linked to cats (one Photos album per cat)
// are missing from the app's cat photos. Every linked photo lands in exactly
// one bucket, mirroring the scanner's fetch and status rules and the
// presentation filters. Photos that were judged "no cat", never scanned, or
// not on this iPhone are run through the same animal recogniser again, from
// this iPhone only, to show what a lower line would recover.
// Everything stays in memory: no photo, identifier or result per photo is
// written, logged or sent. Only counts leave this file, as text.
import Foundation
import Photos
import UIKit
import Vision

// MARK: - Pure logic (unit-tested with synthetic facts)

/// Exactly one per linked photo. `group` is the numbered reason family.
enum CatPhotoCoverageBucket: String, CaseIterable, Sendable {
    case shown = "shown as a cat photo"
    case judgedNotCat = "scanned, judged not a cat"
    case notInPhotoKit = "not in this iPhone's photo list (deleted or limited access)"
    case notImage = "video or other non-photo (scan fetches photos only)"
    case hiddenInPhotos = "hidden in Photos (scan fetch skips hidden)"
    case burstNotPick = "burst frame that is not the pick (scan fetch skips)"
    case burstDuplicate = "burst duplicate (scan keeps one per burst)"
    case screenshot = "screenshot (scan skips)"
    case outsideScanSource = "outside the chosen photo source album"
    case notInScanFetchOther = "not in the scan fetch, other reason"
    case notYetScanned = "eligible, not yet scanned"
    case onlyInCloud = "only in iCloud on last scan"
    case loadFailed = "could not be read on last scan"
    case householdExcluded = "cat, but removed by the user"
    case hiddenBySourceAlbum = "cat, but outside the chosen photo source album"
    case olderSettings = "cat under older detector settings (needs rescan)"

    var group: Int {
        switch self {
        case .shown: 1
        case .judgedNotCat: 2
        case .notInPhotoKit, .notImage, .hiddenInPhotos, .burstNotPick, .burstDuplicate,
             .screenshot, .outsideScanSource, .notInScanFetchOther, .notYetScanned: 3
        case .onlyInCloud, .loadFailed: 4
        case .householdExcluded, .hiddenBySourceAlbum, .olderSettings: 5
        }
    }
}

/// What the scanner wrote for one photo (AssetAnalysisStatus, simplified).
enum CatPhotoCoverageRecordStatus: Equatable, Sendable {
    case cat
    case noCat
    case onlyInCloud
    case failed
    case screenshot
    case burstDuplicate

    init(_ record: AssetRecord) {
        switch record.analysisStatus {
        case .detected: self = record.isCatCandidate ? .cat : .noCat
        case .noCat: self = .noCat
        case .unavailableLocally: self = .onlyInCloud
        case .failed: self = .failed
        case .excludedScreenshot: self = .screenshot
        case .excludedBurstDuplicate: self = .burstDuplicate
        }
    }
}

/// Already-fetched facts about one linked photo. No identifiers.
struct CatPhotoCoverageFacts: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case image, video, other }

    var foundInPhotoKit = true
    var kind: Kind = .image
    var isHidden = false
    var isBurstNotPick = false
    var isScreenshot = false
    /// In the exact fetch the scanner makes (whole library or source album).
    var inScanFetch = true
    var usesSelectedSource = false
    var record: CatPhotoCoverageRecordStatus?
    var recordUsesCurrentSettings = true
    var householdExcluded = false
}

/// Best cat label of one recogniser run. Nil confidence = no cat label at all.
struct CatPhotoRecognitionSample: Equatable, Sendable {
    var bestCatConfidence: Float?
    /// Area of the best cat box as a share of the image (0...1).
    var bestCatArea: Double?
    var hasDogAtLeastHalf = false
}

struct CatPhotoRecognitionHistogram: Equatable, Sendable {
    static let confidenceLabels = ["none", "<0.3", "0.3-0.5", "0.5-0.7", ">=0.7"]
    static let areaLabels = ["<2%", "2-5%", ">5%"]

    var total = 0
    var confidence = [0, 0, 0, 0, 0]
    var dogAtLeastHalf = 0
    var passAtHalf = 0
    var passAtPointThree = 0
    var area = [0, 0, 0]

    static func confidenceBin(_ value: Float?) -> Int {
        guard let value else { return 0 }
        if value < 0.3 { return 1 }
        if value < 0.5 { return 2 }
        if value < 0.7 { return 3 }
        return 4
    }

    static func areaBin(_ value: Double) -> Int {
        if value < 0.02 { return 0 }
        if value <= 0.05 { return 1 }
        return 2
    }

    mutating func add(_ sample: CatPhotoRecognitionSample) {
        total += 1
        confidence[Self.confidenceBin(sample.bestCatConfidence)] += 1
        if sample.hasDogAtLeastHalf { dogAtLeastHalf += 1 }
        if let best = sample.bestCatConfidence {
            if best >= 0.5 { passAtHalf += 1 }
            if best >= 0.3 { passAtPointThree += 1 }
            if let box = sample.bestCatArea { area[Self.areaBin(box)] += 1 }
        }
    }
}

/// How the local image came back now (same order as the scanner: 1024px,
/// then 512px when the full image is only in iCloud; never the network).
enum CatPhotoCoverageLoad: Int, CaseIterable, Sendable {
    case local1024 = 0
    case local512Only = 1
    case inCloud = 2
    case failed = 3

    static let labels = ["1024px on device", "512px only", "in iCloud", "failed"]
}

/// One recogniser group: loads plus the histogram of those that loaded.
struct CatPhotoCoverageRecheck: Equatable, Sendable {
    var loads = [0, 0, 0, 0]
    var histogram = CatPhotoRecognitionHistogram()

    mutating func add(load: CatPhotoCoverageLoad, sample: CatPhotoRecognitionSample?) {
        loads[load.rawValue] += 1
        if let sample { histogram.add(sample) }
    }
}

/// Library-wide context. Only numbers and enum words.
struct CatPhotoCoverageLibraryFacts: Equatable, Sendable {
    var limitedAccess = false
    var usesSelectedSource = false
    var assetsInScope = 0
    var records = 0
    var scannedAssets = 0
    var totalAssets = 0
    var catsShownCurrentSettings = 0
    var statusCounts = [0, 0, 0, 0, 0, 0]  // cat, no cat, iCloud, failed, screenshot, burst dup
    var phase = "idle"
    var resultKind = "none"
    var requiresFullRescan = false
    /// Whole hours since the last scan ended; nil = never.
    var hoursSinceLastScan: Int?
    /// Records by the best cat confidence the scan stored (bands in
    /// `storedConfidenceLabels`), for photos in a linked album and the rest.
    /// Only cat records keep a confidence; every other record is "none".
    var storedConfidenceLinked = [0, 0, 0]
    var storedConfidenceElsewhere = [0, 0, 0]

    static let storedConfidenceLabels = ["none", "0.5-0.7", ">=0.7"]

    static func storedConfidenceBand(_ record: AssetRecord) -> Int {
        guard record.isCatCandidate else { return 0 }
        return record.cat.confidence < 0.7 ? 1 : 2
    }
}

struct CatPhotoCoverageRunFacts: Equatable, Sendable {
    var deviceModel = ""
    var systemVersion = ""
    var library = CatPhotoCoverageLibraryFacts()
    var catsWithAlbum = 0
    var linkedPhotos = 0
    var linkedInSeveralAlbums = 0
    var buckets: [CatPhotoCoverageBucket: Int] = [:]
    var liveAmongNotShown = 0
    /// Recogniser groups: judged not cat, not yet scanned, not on device.
    var rechecks = [CatPhotoCoverageRecheck(), CatPhotoCoverageRecheck(), CatPhotoCoverageRecheck()]
    var seconds = 0.0
}

enum CatPhotoCoverageCore {
    static let requestPixels = 1_024
    static let recoveryPixels = 512
    static let concurrentPhotos = 2
    static let rechecked: [(group: String, buckets: [CatPhotoCoverageBucket])] = [
        ("2 judged not a cat", [.judgedNotCat]),
        ("3 eligible, not yet scanned", [.notYetScanned]),
        ("4 not on device at last scan", [.onlyInCloud, .loadFailed]),
    ]

    /// First matching rule wins, so every photo is counted once.
    static func bucket(_ facts: CatPhotoCoverageFacts) -> CatPhotoCoverageBucket {
        guard facts.foundInPhotoKit else { return .notInPhotoKit }
        if let record = facts.record {
            switch record {
            case .cat:
                if !facts.recordUsesCurrentSettings { return .olderSettings }
                if facts.householdExcluded { return .householdExcluded }
                if facts.usesSelectedSource, !facts.inScanFetch { return .hiddenBySourceAlbum }
                return .shown
            case .noCat: return .judgedNotCat
            case .onlyInCloud: return .onlyInCloud
            case .failed: return .loadFailed
            case .screenshot: return .screenshot
            case .burstDuplicate: return .burstDuplicate
            }
        }
        if facts.kind != .image { return .notImage }
        if facts.isHidden { return .hiddenInPhotos }
        if facts.isBurstNotPick { return .burstNotPick }
        if !facts.inScanFetch {
            return facts.usesSelectedSource ? .outsideScanSource : .notInScanFetchOther
        }
        if facts.isScreenshot { return .screenshot }
        return .notYetScanned
    }

    /// Index into `CatPhotoCoverageRunFacts.rechecks`, nil = not rechecked.
    static func recheckGroup(_ bucket: CatPhotoCoverageBucket) -> Int? {
        rechecked.firstIndex { $0.buckets.contains(bucket) }
    }

    static func count(_ facts: [CatPhotoCoverageFacts]) -> [CatPhotoCoverageBucket: Int] {
        var counts: [CatPhotoCoverageBucket: Int] = [:]
        for value in facts { counts[bucket(value), default: 0] += 1 }
        return counts
    }

    static func statusIndex(_ status: CatPhotoCoverageRecordStatus) -> Int {
        switch status {
        case .cat: 0
        case .noCat: 1
        case .onlyInCloud: 2
        case .failed: 3
        case .screenshot: 4
        case .burstDuplicate: 5
        }
    }

    /// Keeps only characters a device model or OS version can contain.
    static func plainToken(_ value: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789,._")
        let kept = String(value.filter { allowed.contains($0) }.prefix(24))
        return kept.isEmpty ? "unknown" : kept
    }

    /// The text shown and copied by 「結果をコピー」: numbers, bucket names,
    /// enum words and the device model / OS only.
    static func summaryText(facts: CatPhotoCoverageRunFacts) -> String {
        let library = facts.library
        var lines: [String] = []
        lines.append("cat-photo-coverage v2")
        lines.append("device \(plainToken(facts.deviceModel)) iOS \(plainToken(facts.systemVersion))")
        lines.append("photo access \(library.limitedAccess ? "limited" : "full"), source \(library.usesSelectedSource ? "one album" : "whole library")")
        lines.append("library: photos in scan scope \(library.assetsInScope), records \(library.records), scanned \(library.scannedAssets)/\(library.totalAssets), cats shown \(library.catsShownCurrentSettings)")
        let status = library.statusCounts
        lines.append("records: cat \(status[0]), no cat \(status[1]), iCloud only \(status[2]), failed \(status[3]), screenshot \(status[4]), burst duplicate \(status[5])")
        let age = library.hoursSinceLastScan.map { "\($0) h ago" } ?? "never"
        lines.append("scan: phase \(library.phase), result \(library.resultKind), full rescan pending \(library.requiresFullRescan ? "yes" : "no"), last scan \(age)")
        let bands = CatPhotoCoverageLibraryFacts.storedConfidenceLabels
        lines.append("stored best cat, in linked albums: " + zip(bands, library.storedConfidenceLinked).map { "\($0) \($1)" }.joined(separator: ", "))
        lines.append("stored best cat, elsewhere: " + zip(bands, library.storedConfidenceElsewhere).map { "\($0) \($1)" }.joined(separator: ", "))
        lines.append("linked albums: cats \(facts.catsWithAlbum), photos \(facts.linkedPhotos) (deduplicated), in 2+ albums \(facts.linkedInSeveralAlbums)")
        lines.append("")
        lines.append("each linked photo in exactly one bucket")
        for group in 1...5 {
            let members = CatPhotoCoverageBucket.allCases.filter { $0.group == group }
            let subtotal = members.reduce(0) { $0 + (facts.buckets[$1] ?? 0) }
            lines.append("\(group) total \(subtotal)")
            for bucket in members {
                lines.append("  \(bucket.rawValue): \(facts.buckets[bucket] ?? 0)")
            }
        }
        lines.append("all \(facts.buckets.values.reduce(0, +))")
        lines.append("live photos among not shown \(facts.liveAmongNotShown) (scanned as photos, no special rule)")
        lines.append("")
        lines.append("recogniser now: animals request, \(requestPixels)px (\(recoveryPixels)px if only that is local), this iPhone only, \(concurrentPhotos) at a time")
        lines.append("note: the scan also retries \"no cat\" at 2048px; this recheck does not")
        for (index, entry) in rechecked.enumerated() {
            let recheck = facts.rechecks[index]
            let histogram = recheck.histogram
            lines.append("\(entry.group): " + zip(CatPhotoCoverageLoad.labels, recheck.loads).map { "\($0) \($1)" }.joined(separator: ", "))
            lines.append("  best cat: " + zip(CatPhotoRecognitionHistogram.confidenceLabels, histogram.confidence).map { "\($0) \($1)" }.joined(separator: ", "))
            lines.append("  pass at 0.5 \(histogram.passAtHalf), at 0.3 \(histogram.passAtPointThree), dog >=0.5 \(histogram.dogAtLeastHalf)")
            lines.append("  best cat box: " + zip(CatPhotoRecognitionHistogram.areaLabels, histogram.area).map { "\($0) \($1)" }.joined(separator: ", "))
        }
        lines.append("")
        lines.append(String(format: "time %.1f s", facts.seconds))
        return lines.joined(separator: "\n")
    }
}

// MARK: - On-device run

enum CatPhotoCoverageOutcome: Sendable {
    case blocked(String)
    case finished(String)
    case cancelled
}

enum CatPhotoCoverageRunner {
    struct Device: Sendable {
        var model: String
        var systemVersion: String
    }

    static func measure(
        device: Device,
        progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void
    ) async -> CatPhotoCoverageOutcome {
        let started = Date()
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            return .blocked("写真へのアクセスが許可されていません。")
        }
        let snapshot: LibrarySnapshot
        let identity: CatHouseholdIdentityState?
        let curation: CatCandidateCurationState
        do {
            snapshot = try await LibraryStore().load()
            identity = try await CatHouseholdIdentityStore().load()
            // Read the file directly: the store's load() may rewrite it.
            if let url = SharedContainer.catCandidateCurationURL,
               FileManager.default.fileExists(atPath: url.path) {
                curation = try AtomicJSON.read(CatCandidateCurationState.self, from: url).normalized()
            } else {
                curation = .empty
            }
        } catch {
            return .blocked("写真の記録を読めませんでした。")
        }
        guard let identity else { return .blocked("猫が登録されていません。") }

        // Linked albums only (union over cats). Household exclusions are kept
        // in so they can be counted as their own bucket.
        var ownerCount: [String: Int] = [:]
        var catsWithAlbum = 0
        for profile in identity.profiles {
            guard let link = profile.photoAlbumLink else { continue }
            catsWithAlbum += 1
            for identifier in Set(link.lastKnownAssetLocalIdentifiers) {
                ownerCount[identifier, default: 0] += 1
            }
        }
        guard !ownerCount.isEmpty else {
            return .blocked("写真アプリのアルバムをつないだ猫がいません。")
        }
        progress(0, 0)

        var facts = CatPhotoCoverageRunFacts()
        facts.deviceModel = device.model
        facts.systemVersion = device.systemVersion
        facts.catsWithAlbum = catsWithAlbum
        facts.linkedPhotos = ownerCount.count
        facts.linkedInSeveralAlbums = ownerCount.values.filter { $0 > 1 }.count

        // The exact fetch the scanner makes (CatCandidateCurationStore.swift).
        let scanIdentifiers: Set<String>
        do {
            let options = PHFetchOptions()
            scanIdentifiers = Set(try PhotoSourceAlbumCatalog.fetchImageAssets(
                sourceAlbumIdentifier: curation.sourceAlbumIdentifier,
                options: options
            ).map(\.localIdentifier))
        } catch {
            return .blocked("選んだ写真の対象のアルバムを開けません。")
        }
        if Task.isCancelled { return .cancelled }

        let fingerprint = snapshot.settings.analysisFingerprint
        var recordsByIdentifier: [String: AssetRecord] = [:]
        for record in snapshot.assets { recordsByIdentifier[record.localIdentifier] = record }
        let excluded: Set<String> = identity.mode == .profiled
            ? Set(identity.globalExcludedAssets.map(\.localIdentifier))
            : curation.excludedAssetIdentifiers

        var library = CatPhotoCoverageLibraryFacts()
        library.limitedAccess = status == .limited
        library.usesSelectedSource = curation.usesSelectedAlbum
        library.assetsInScope = scanIdentifiers.count
        library.records = snapshot.assets.count
        library.scannedAssets = snapshot.scanState.scannedAssets
        library.totalAssets = snapshot.scanState.totalAssets
        for record in snapshot.assets {
            library.statusCounts[CatPhotoCoverageCore.statusIndex(CatPhotoCoverageRecordStatus(record))] += 1
            let band = CatPhotoCoverageLibraryFacts.storedConfidenceBand(record)
            if ownerCount[record.localIdentifier] != nil {
                library.storedConfidenceLinked[band] += 1
            } else {
                library.storedConfidenceElsewhere[band] += 1
            }
            if record.isCatCandidate, record.analysisFingerprint == fingerprint,
               !excluded.contains(record.localIdentifier),
               !curation.usesSelectedAlbum || scanIdentifiers.contains(record.localIdentifier) {
                library.catsShownCurrentSettings += 1
            }
        }
        library.phase = snapshot.scanState.phase.rawValue
        library.resultKind = snapshot.scanState.resultKind.rawValue
        library.requiresFullRescan = snapshot.scanState.requiresFullRescan
        library.hoursSinceLastScan = snapshot.scanState.lastScannedAt.map {
            max(0, Int(Date().timeIntervalSince($0) / 3_600))
        }
        facts.library = library

        // Every linked photo, hidden and all burst frames included, so the
        // fetch's own skips can be named.
        let linkedIdentifiers = ownerCount.keys.sorted()
        let fetchOptions = PHFetchOptions()
        fetchOptions.includeHiddenAssets = true
        fetchOptions.includeAllBurstAssets = true
        var assetsByIdentifier: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: linkedIdentifiers, options: fetchOptions)
            .enumerateObjects { asset, _, _ in assetsByIdentifier[asset.localIdentifier] = asset }

        var recheckJobs: [(group: Int, identifier: String)] = []
        for identifier in linkedIdentifiers {
            var value = CatPhotoCoverageFacts()
            value.usesSelectedSource = curation.usesSelectedAlbum
            value.inScanFetch = scanIdentifiers.contains(identifier)
            value.householdExcluded = excluded.contains(identifier)
            var isLive = false
            if let asset = assetsByIdentifier[identifier] {
                switch asset.mediaType {
                case .image: value.kind = .image
                case .video: value.kind = .video
                default: value.kind = .other
                }
                value.isHidden = asset.isHidden
                value.isBurstNotPick = asset.burstIdentifier != nil && !asset.representsBurst
                value.isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
                isLive = asset.mediaSubtypes.contains(.photoLive)
            } else {
                value.foundInPhotoKit = false
            }
            if let record = recordsByIdentifier[identifier] {
                value.record = CatPhotoCoverageRecordStatus(record)
                value.recordUsesCurrentSettings = record.analysisFingerprint == fingerprint
            }
            let bucket = CatPhotoCoverageCore.bucket(value)
            facts.buckets[bucket, default: 0] += 1
            if bucket != .shown, isLive { facts.liveAmongNotShown += 1 }
            if let group = CatPhotoCoverageCore.recheckGroup(bucket) {
                recheckJobs.append((group: group, identifier: identifier))
            }
        }

        let total = recheckJobs.count
        progress(0, total)
        let checker = CatPhotoCoverageRecognizer()
        var done = 0
        await withTaskGroup(of: (Int, CatPhotoCoverageLoad, CatPhotoRecognitionSample?).self) { group in
            var next = 0
            while next < min(CatPhotoCoverageCore.concurrentPhotos, recheckJobs.count) {
                let job = recheckJobs[next]
                next += 1
                group.addTask {
                    let (load, sample) = await checker.check(localIdentifier: job.identifier)
                    return (job.group, load, sample)
                }
            }
            while let output = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                let (groupIndex, load, sample) = output
                done += 1
                facts.rechecks[groupIndex].add(load: load, sample: sample)
                progress(done, total)
                if next < recheckJobs.count {
                    let job = recheckJobs[next]
                    next += 1
                    group.addTask {
                        let (load, sample) = await checker.check(localIdentifier: job.identifier)
                        return (job.group, load, sample)
                    }
                }
            }
        }
        if Task.isCancelled { return .cancelled }
        facts.seconds = Date().timeIntervalSince(started)
        return .finished(CatPhotoCoverageCore.summaryText(facts: facts))
    }
}

/// Loads one photo from this iPhone only and runs the animal recogniser on
/// it. Nothing is kept after the numbers are made.
final class CatPhotoCoverageRecognizer: @unchecked Sendable {
    func check(localIdentifier: String) async -> (CatPhotoCoverageLoad, CatPhotoRecognitionSample?) {
        guard !Task.isCancelled,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
        else { return (.failed, nil) }
        let primary = await CatPhotoCoverageImageRequest(
            pixels: CatPhotoCoverageCore.requestPixels, acceptsDegraded: false
        ).load(asset)
        var load: CatPhotoCoverageLoad
        var image: UIImage?
        switch primary {
        case let .image(value):
            load = .local1024
            image = value
        case .failed:
            return (.failed, nil)
        case .inCloud:
            // Same as the scanner: a small local copy may still exist.
            let recovery = await CatPhotoCoverageImageRequest(
                pixels: CatPhotoCoverageCore.recoveryPixels, acceptsDegraded: true
            ).load(asset)
            if case let .image(value) = recovery {
                load = .local512Only
                image = value
            } else {
                load = .inCloud
            }
        }
        guard let image, !Task.isCancelled else { return (load, nil) }
        let sample = autoreleasepool { Self.recognize(image) }
        if sample == nil { load = .failed }
        return (load, sample)
    }

    private static func recognize(_ image: UIImage) -> CatPhotoRecognitionSample? {
        guard let cgImage = image.cgImage else { return nil }
        let request = VNRecognizeAnimalsRequest()
#if targetEnvironment(simulator)
        request.usesCPUOnly = true
#endif
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation(image.imageOrientation), options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        var sample = CatPhotoRecognitionSample()
        for observation in request.results ?? [] {
            for label in observation.labels {
                if label.identifier.caseInsensitiveCompare("cat") == .orderedSame,
                   label.confidence > (sample.bestCatConfidence ?? -1) {
                    sample.bestCatConfidence = label.confidence
                    let box = observation.boundingBox
                    sample.bestCatArea = min(1, max(0, Double(box.width * box.height)))
                }
                if label.identifier.caseInsensitiveCompare("dog") == .orderedSame, label.confidence >= 0.5 {
                    sample.hasDogAtLeastHalf = true
                }
            }
        }
        return sample
    }

    private static func orientation(_ value: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch value {
        case .up: .up
        case .upMirrored: .upMirrored
        case .down: .down
        case .downMirrored: .downMirrored
        case .left: .left
        case .leftMirrored: .leftMirrored
        case .right: .right
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}

/// One PhotoKit request: this iPhone only (no iCloud download), bounded
/// wait, cancelled with the task. Reports iCloud the way the scanner does.
private final class CatPhotoCoverageImageRequest: @unchecked Sendable {
    enum Result: Sendable {
        case image(UIImage)
        case inCloud
        case failed
    }

    private let pixels: Int
    private let acceptsDegraded: Bool
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result, Never>?
    private var requestID: PHImageRequestID?
    private var timeout: Task<Void, Never>?
    private var finished = false
    private var sawCloudOrDegraded = false

    init(pixels: Int, acceptsDegraded: Bool) {
        self.pixels = pixels
        self.acceptsDegraded = acceptsDegraded
    }

    func load(_ asset: PHAsset) async -> Result {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
                lock.lock()
                if finished {
                    lock.unlock()
                    continuation.resume(returning: .failed)
                    return
                }
                self.continuation = continuation
                lock.unlock()

                let options = PHImageRequestOptions()
                options.version = .current
                options.deliveryMode = acceptsDegraded ? .fastFormat : .highQualityFormat
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = false
                options.isSynchronous = false
                let side = CGFloat(pixels)
                let identifier = PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: CGSize(width: side, height: side),
                    contentMode: .aspectFit,
                    options: options
                ) { [weak self] image, info in
                    self?.handle(image: image, info: info)
                }
                let timeout = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled, let self else { return }
                    self.finish(self.cloudSeen() ? .inCloud : .failed)
                }
                lock.lock()
                requestID = identifier
                let alreadyFinished = finished
                if alreadyFinished {
                    timeout.cancel()
                } else {
                    self.timeout = timeout
                }
                lock.unlock()
                if alreadyFinished { PHImageManager.default().cancelImageRequest(identifier) }
            }
        } onCancel: {
            self.finish(.failed)
        }
    }

    private func handle(image: UIImage?, info: [AnyHashable: Any]?) {
        let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
        let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
        let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
        let error = info?[PHImageErrorKey] as? NSError
        lock.lock()
        if inCloud || (degraded && image != nil) { sawCloudOrDegraded = true }
        let evidence = sawCloudOrDegraded
        lock.unlock()
        if degraded, !cancelled, error == nil {
            guard acceptsDegraded, image != nil else { return }
        }
        if !cancelled, error == nil, let image {
            finish(.image(image))
        } else {
            finish(inCloud || evidence ? .inCloud : .failed)
        }
    }

    private func cloudSeen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sawCloudOrDegraded
    }

    private func finish(_ result: Result) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        let timeout = timeout
        self.timeout = nil
        let identifier = requestID
        lock.unlock()
        timeout?.cancel()
        if let identifier { PHImageManager.default().cancelImageRequest(identifier) }
        continuation?.resume(returning: result)
    }
}

/// The last result text, in this app's caches only (survives relaunch,
/// never backed up or shared). Numbers only.
enum CatPhotoCoverageResultCache {
    private static var url: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("cat-photo-coverage-last.txt")
    }

    static func load() -> String? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ text: String) {
        guard let url else { return }
        try? Data(text.utf8).write(to: url, options: .atomic)
    }
}
#endif
