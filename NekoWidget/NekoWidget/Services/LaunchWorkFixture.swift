#if DEBUG
import Photos
import SwiftUI

/// 11/14 `--launch-work-fixture` (DEBUG only): the real AppViewModel,
/// AppRootView and stores with a library the size of the owner's (10,000
/// records, 2,500 cats, 2 cats each with a linked album of 500 photos).
/// Synthetic records only: no photo is read, and PhotoKit is replaced in two
/// places: photo access reads as allowed, and the scanner is
/// `LaunchWorkFixtureScanner`, which walks the stored records the way
/// PhotoLibraryScanner walks a library whose photos were all seen before
/// (same batches of 4, same progress cadence, same quick 500 and final
/// events, failed and iCloud-only photos sent back to "analysis").
/// Everything after the scanner (publication, saves, Widget authority,
/// views) is the app's own code.
enum LaunchWorkFixture {
    static let argument = "--launch-work-fixture"
    static var isOn: Bool { CommandLine.arguments.contains(argument) }

    static let recordCount = 10_000
    static let catEvery = 4            // 2,500 cats
    static let failedCount = 40        // failed on the last pass
    static let cloudCatCount = 30      // cats whose album traits never arrived (iCloud-only)
    static let linkedPerCat = 500
    static let identifierPrefix = "launch-work-photo-"
    static let profileIDs = [UUID(uuidString: "4C570000-0000-4000-8000-000000000001")!,
                             UUID(uuidString: "4C570000-0000-4000-8000-000000000002")!]

    /// First launch on a fresh Simulator: writes the synthetic library into
    /// the app's own stores. Later launches find it and keep what the app
    /// saved, as on a phone.
    static func prepare() async {
        UserDefaults.standard.set(OnboardingPresentationPersistence.currentCompletedVersion,
                                  forKey: OnboardingPresentationPersistence.completedVersionKey)
        UserDefaults.standard.set(true, forKey: "hasSeenInitialScanResult.v1")
        do {
            let store = try LibraryStore()
            let existing = try await store.load()
            guard existing.assets.first?.localIdentifier.hasPrefix(identifierPrefix) != true else { return }
            let snapshot = makeSnapshot()
            try await store.save(snapshot)
            let identities = try CatHouseholdIdentityStore()
            let current = try await identities.loadOrMigrate(legacyLifeReference: nil, legacyCuration: .empty)
            var seeded = makeIdentity(for: snapshot)
            seeded.mutationRevision = current.mutationRevision
            _ = try await identities.save(seeded, expectedMutationRevision: current.mutationRevision)
        } catch {
            NSLog("LAUNCHWORK fixture seed failed: %@", String(describing: error))
        }
    }

    static func identifier(_ index: Int) -> String {
        identifierPrefix + String(format: "%05d", index)
    }

    static func makeSnapshot() -> LibrarySnapshot {
        var result = LibrarySnapshot.empty
        let settings = AppSettings.default.normalized()
        result.settings = settings
        let newest = Date().addingTimeInterval(-3_600)
        let box = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        result.assets = (0..<recordCount).map { index in
            let created = newest.addingTimeInterval(-Double(index) * 3 * 3_600)
            let isCat = index % catEvery == 0
            let isCloudCat = isCat && index / catEvery < cloudCatCount
            let isFailed = !isCat && index % 97 == 1 && index / 97 < failedCount
            let detection = isCat
                ? CatDetection(detected: true, confidence: index % 3 == 0 ? 0.55 : 0.95, boundingBox: box,
                               areaRatio: 0.64, catCount: 1, instanceBoundingBoxes: [box])
                : CatDetection.none
            return AssetRecord(
                localIdentifier: identifier(index),
                creationDate: created,
                sourceModificationDate: created,
                sourceModificationDateWasCaptured: true,
                isFavorite: index % 50 == 0, isScreenshot: false, burstIdentifier: nil,
                cat: detection,
                analysisStatus: isCat ? .detected : (isFailed ? .failed : .noCat),
                analysisFingerprint: settings.analysisFingerprint,
                analyzedAt: created,
                albumAnalysisVersion: isCat && !isCloudCat ? CatAlbumTraits.currentAnalysisVersion : (isCat ? nil : CatAlbumTraits.currentAnalysisVersion),
                albumTraits: isCat && !isCloudCat
                    ? CatAlbumTraits(postures: [.curled], containsPerson: index % 5 == 0,
                                     isOuting: false, largestCatAreaRatio: 0.64, analyzedAt: created)
                    : nil
            )
        }
        result.scanState.phase = .completed
        result.scanState.resultKind = .final
        result.scanState.totalAssets = recordCount
        result.scanState.scannedAssets = recordCount
        result.scanState.catAssets = recordCount / catEvery
        result.scanState.lastScannedAt = newest
        result.updatedAt = newest
        return result
    }

    static func makeIdentity(for snapshot: LibrarySnapshot) -> CatHouseholdIdentityState {
        let cats = snapshot.assets.filter(\.isCatCandidate).map(\.localIdentifier)
        let now = Date()
        let profiles = profileIDs.enumerated().map { offset, id in
            let linked = Array(cats.enumerated().filter { $0.offset % 2 == offset }.map(\.element).prefix(linkedPerCat))
            return CatProfile(id: id, displayName: offset == 0 ? "むぎ" : "こむぎ",
                              keyPhotoLocalIdentifier: linked.first,
                              photoAlbumLink: CatProfilePhotoAlbumLink(
                                  localIdentifier: "launch-work-album-\(offset)",
                                  lastKnownAssetLocalIdentifiers: linked, linkedAt: now, refreshedAt: now),
                              createdAt: now, updatedAt: now)
        }
        // Explicit decisions beyond the albums: 300 includes per cat, 100 "not this cat".
        let tail = Array(cats.dropFirst(linkedPerCat * 2))
        var memberships: [CatAssetProfileMembership] = []
        for (index, photo) in tail.prefix(600).enumerated() {
            memberships.append(.init(assetLocalIdentifier: photo, profileID: profileIDs[index % 2],
                                     decision: .included, decidedAt: now))
        }
        for (index, photo) in cats.prefix(100).enumerated() {
            memberships.append(.init(assetLocalIdentifier: photo, profileID: profileIDs[(index + 1) % 2],
                                     decision: .excluded, decidedAt: now))
        }
        let excluded = cats.suffix(60).map { ExcludedCatAsset(localIdentifier: $0, excludedAt: now) }
        return CatHouseholdIdentityState(mode: .profiled, profiles: profiles, memberships: memberships,
                                         globalExcludedAssets: excluded, legacyUnscoped: nil,
                                         createdAt: now, updatedAt: now)
    }
}

/// Walks the stored records like PhotoLibraryScanner walks a library it has
/// seen before. Reading 4 photos' PhotoKit metadata is stood in for by a
/// 4 ms sleep per batch (about 10 s for 10,000 photos); one "analysis" of a
/// photo the real scanner would send to Vision is 300 ms per batch.
actor LaunchWorkFixtureScanner: LibraryScanning {
    func scan(
        existing: LibrarySnapshot,
        settings inputSettings: AppSettings,
        forceFullAnalysis: Bool,
        sourceAlbumIdentifier: String?,
        onEvent: @escaping @Sendable (ScanEvent) async -> Void
    ) async throws -> LibrarySnapshot {
        let settings = inputSettings.normalized()
        let started = Date()
        let purpose = existing.scanState.purpose ?? (forceFullAnalysis ? .manualRescan : .regular)
        let assets = existing.assets.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        var records = [AssetRecord?](repeating: nil, count: assets.count)
        let quickEnd = min(settings.quickScanLimit, assets.count)
        try await process(0..<quickEnd, assets, &records, settings, forceFullAnalysis, .quickScan, purpose, onEvent)
        var quick = existing
        quick.assets = records.compactMap { $0 } + assets[quickEnd...]
        quick.scanState = state(records, scanned: quickEnd, total: assets.count,
                                phase: assets.count > quickEnd ? .fullScan : .completed,
                                kind: assets.count > quickEnd ? .provisional : .final,
                                force: forceFullAnalysis && assets.count > quickEnd, purpose: purpose, settings: settings)
        quick.scanState.lastScannedAt = .now
        quick.settings = settings
        quick.updatedAt = .now
        await onEvent(.provisional(quick))
        try await process(quickEnd..<assets.count, assets, &records, settings, forceFullAnalysis, .fullScan, purpose, onEvent)
        try Task.checkCancellation()
        var final = existing
        final.assets = records.compactMap { $0 }
        final.scanState = state(records, scanned: assets.count, total: assets.count, phase: .completed,
                                kind: .final, force: false, purpose: purpose, settings: settings)
        final.scanState.lastScannedAt = .now
        final.scanState.scanDurationMilliseconds = Date().timeIntervalSince(started) * 1_000
        final.settings = settings
        final.updatedAt = .now
        return final
    }

    private func process(
        _ range: Range<Int>, _ assets: [AssetRecord], _ records: inout [AssetRecord?],
        _ settings: AppSettings, _ force: Bool, _ phase: ScanPhase, _ purpose: ScanPurpose,
        _ onEvent: @escaping @Sendable (ScanEvent) async -> Void
    ) async throws {
        var start = range.lowerBound
        var lastPublished = range.lowerBound
        var analyzedSinceReport = 0
        var lastReport = ProcessInfo.processInfo.systemUptime
        while start < range.upperBound {
            try Task.checkCancellation()
            let end = min(start + 4, range.upperBound)
            var pending = 0
            for index in start..<end {
                var record = assets[index]
                if force || Self.needsAnalysis(record, now: .now) {
                    pending += 1
                    record.analyzedAt = .now
                }
                records[index] = record
            }
            try await Task.sleep(nanoseconds: pending > 0 ? 300_000_000 : 4_000_000)
            start = end
            analyzedSinceReport += pending
            let now = ProcessInfo.processInfo.systemUptime
            if ScanProgressEventPolicy.shouldReport(
                batchEnd: end, rangeEnd: range.upperBound,
                isFirstQuickBatch: phase == .quickScan && end == min(range.lowerBound + 4, range.upperBound),
                analyzedSinceLastReport: analyzedSinceReport, secondsSinceLastReport: now - lastReport) {
                let value = state(records, scanned: end, total: assets.count, phase: phase, kind: .provisional,
                                  force: force, purpose: purpose, settings: settings)
                await onEvent(.progress(value, analyzedRecords: records[lastPublished..<end].compactMap { $0 }))
                lastPublished = end
                analyzedSinceReport = 0
                lastReport = ProcessInfo.processInfo.systemUptime
            }
            await Task.yield()
        }
    }

    /// The photos PhotoLibraryScanner sends to Vision on a pass that is not
    /// a full rescan: failed ones and cats still missing album traits.
    static func needsAnalysis(_ record: AssetRecord, now: Date) -> Bool {
        if record.analysisStatus == .failed { return true }
        return record.isCatCandidate && record.albumAnalysisVersion != CatAlbumTraits.currentAnalysisVersion
    }

    /// The same counts PhotoLibraryScanner.makeState derives (two passes over
    /// every finished record).
    private func state(
        _ records: [AssetRecord?], scanned: Int, total: Int, phase: ScanPhase, kind: ScanResultKind,
        force: Bool, purpose: ScanPurpose?, settings: AppSettings
    ) -> ScanState {
        let finished = records.compactMap { $0 }
        let cats = finished.filter(\.isCatCandidate)
        return ScanState(
            phase: phase, resultKind: kind, lastScannedAt: nil, totalAssets: total, scannedAssets: scanned,
            catAssets: cats.count,
            widgetEligibleAssets: cats.lazy.filter { $0.isWidgetEligible(settings: settings) }.count,
            oldestCatPhotoDate: cats.compactMap(\.creationDate).min(),
            deferredAssets: finished.filter { $0.analysisStatus == .unavailableLocally || $0.analysisStatus == .failed }.count,
            recoveryDiagnostics: .zero,
            postureSummary: PostureScanSummary(records: finished),
            requiresFullRescan: force,
            purpose: kind == .final ? nil : purpose,
            lastError: nil)
    }
}

/// The fixture's root: the app's own AppRootView over a view model whose
/// scanner and photo access are the fixture's.
struct LaunchWorkFixtureRoot: View {
    @State private var model: AppViewModel?

    var body: some View {
        Group {
            if let model {
                AppRootView(viewModel: model).appAppearance()
            } else {
                Color.clear
            }
        }
        .task {
            guard model == nil else { return }
            await LaunchWorkFixture.prepare()
            model = AppViewModel(scanner: LaunchWorkFixtureScanner())
        }
    }
}
#endif
