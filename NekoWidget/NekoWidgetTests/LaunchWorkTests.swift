import XCTest
@testable import NekoWidget

/// 11/14: the decisions that keep the first seconds after opening the app
/// light. Synthetic records only: no photos, no PhotoKit, no network.
final class LaunchWorkTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Library verification (Photos' change token)

    private func record(_ id: String, favorite: Bool = false, modified: Date? = nil) -> AssetRecord {
        AssetRecord(localIdentifier: id, creationDate: Date(timeIntervalSince1970: 1_700_000_000),
                    sourceModificationDate: modified ?? Date(timeIntervalSince1970: 1_700_000_100),
                    sourceModificationDateWasCaptured: true, isFavorite: favorite, isScreenshot: false,
                    burstIdentifier: nil, cat: .none, analysisStatus: .noCat,
                    analysisFingerprint: AppSettings.default.normalized().analysisFingerprint)
    }

    private func completedSnapshot(lastScannedAt: Date? = nil) -> LibrarySnapshot {
        var value = LibrarySnapshot.empty
        value.settings = AppSettings.default.normalized()
        value.assets = (0..<5).map { record("photo-\($0)") }
        value.scanState.phase = .completed
        value.scanState.resultKind = .final
        value.scanState.requiresFullRescan = false
        value.scanState.purpose = nil
        value.scanState.lastScannedAt = lastScannedAt ?? now.addingTimeInterval(-3_600)
        return value
    }

    private func receipt(for snapshot: LibrarySnapshot, source: String? = nil) -> LibraryVerificationReceipt {
        LibraryVerificationReceipt(token: Data("token".utf8),
                                   analysisFingerprint: snapshot.settings.analysisFingerprint,
                                   sourceAlbumIdentifier: source,
                                   lastScannedAt: snapshot.scanState.lastScannedAt!,
                                   recordCount: snapshot.assets.count)
    }

    private func decide(
        _ snapshot: LibrarySnapshot,
        receipt: LibraryVerificationReceipt?,
        source: String? = nil,
        limited: Bool = false,
        force: Bool = false,
        at date: Date? = nil,
        _ check: PhotoLibraryChangeCheck = .changes(PhotoLibraryChangeSummary())
    ) -> LibraryVerificationPolicy.Decision {
        LibraryVerificationPolicy.decide(receipt: receipt, snapshot: snapshot, sourceAlbumIdentifier: source,
                                         isLimitedAccess: limited, forceFullAnalysis: force,
                                         now: date ?? now, check: check)
    }

    func testUnchangedLibrarySkipsThePass() {
        let snapshot = completedSnapshot()
        XCTAssertEqual(decide(snapshot, receipt: receipt(for: snapshot)), .skip)
    }

    func testNewPhotoTakenWhileClosedMakesAPass() {
        let snapshot = completedSnapshot()
        var summary = PhotoLibraryChangeSummary()
        summary.insertedAssets = 1
        XCTAssertEqual(decide(snapshot, receipt: receipt(for: snapshot), .changes(summary)), .verify("inserted"))
    }

    func testPhotoDeletedInPhotosMakesAPass() {
        let snapshot = completedSnapshot()
        var summary = PhotoLibraryChangeSummary()
        summary.deletedAssets = 1
        XCTAssertEqual(decide(snapshot, receipt: receipt(for: snapshot), .changes(summary)), .verify("deleted"))
    }

    func testExpiredTokenMakesAFullPass() {
        let snapshot = completedSnapshot()
        XCTAssertEqual(decide(snapshot, receipt: receipt(for: snapshot), .unavailable), .verify("no-history"))
        XCTAssertEqual(decide(snapshot, receipt: nil), .verify("no-receipt"))
    }

    func testDetectorSettingsChangeMakesAPass() {
        let snapshot = completedSnapshot()
        var old = receipt(for: snapshot)
        old.analysisFingerprint = "an-older-detector"
        XCTAssertEqual(decide(snapshot, receipt: old), .verify("settings"))
        // A full rescan request always passes.
        XCTAssertEqual(decide(snapshot, receipt: receipt(for: snapshot), force: true), .verify("full-rescan"))
        var pending = snapshot
        pending.scanState.requiresFullRescan = true
        XCTAssertEqual(decide(pending, receipt: receipt(for: snapshot)), .verify("no-completed-pass"))
    }

    func testUnfinishedPassOrOtherSnapshotMakesAPass() {
        var stopped = completedSnapshot()
        stopped.scanState.phase = .cancelled
        XCTAssertEqual(decide(stopped, receipt: receipt(for: completedSnapshot())), .verify("no-completed-pass"))
        let snapshot = completedSnapshot()
        var other = receipt(for: snapshot)
        other.recordCount += 1
        XCTAssertEqual(decide(snapshot, receipt: other), .verify("other-snapshot"))
        var older = receipt(for: snapshot)
        older.lastScannedAt = older.lastScannedAt.addingTimeInterval(-60)
        XCTAssertEqual(decide(snapshot, receipt: older), .verify("other-snapshot"))
        // The snapshot file keeps whole seconds; the receipt keeps more.
        var precise = receipt(for: snapshot)
        precise.lastScannedAt = precise.lastScannedAt.addingTimeInterval(0.4)
        XCTAssertEqual(decide(snapshot, receipt: precise), .skip)
    }

    func testLimitedAccessAndDailyPassStillPass() {
        let snapshot = completedSnapshot()
        XCTAssertEqual(decide(snapshot, receipt: receipt(for: snapshot), limited: true), .verify("limited-access"))
        let dayOld = completedSnapshot(lastScannedAt: now.addingTimeInterval(-LibraryVerificationPolicy.maximumAge - 1))
        XCTAssertEqual(decide(dayOld, receipt: receipt(for: dayOld)), .verify("daily"))
    }

    func testAlbumScopedSourceWatchesAlbumChanges() {
        let snapshot = completedSnapshot()
        var summary = PhotoLibraryChangeSummary()
        summary.collectionsChanged = true
        XCTAssertEqual(decide(snapshot, receipt: receipt(for: snapshot), .changes(summary)), .skip)
        XCTAssertEqual(decide(snapshot, receipt: receipt(for: snapshot, source: "album"), source: "album",
                              .changes(summary)), .verify("source-album"))
        XCTAssertEqual(decide(snapshot, receipt: receipt(for: snapshot, source: "album")), .verify("source"))
    }

    func testUpdatesThatChangeNoStoredFactAreSkipped() {
        let snapshot = completedSnapshot()
        let stored = snapshot.assets[2]
        var summary = PhotoLibraryChangeSummary()
        // Photos' own analysis touched the photo: same facts (sub-second
        // modification dates are stored in whole seconds).
        summary.updatedAssets = ["photo-2": LibraryAssetFacts(
            creationDate: stored.creationDate,
            modificationDate: stored.sourceModificationDate!.addingTimeInterval(0.3),
            isFavorite: false, isScreenshot: false, burstIdentifier: nil),
                                 // A video the scan never stored.
                                 "video-1": nil]
        XCTAssertEqual(decide(snapshot, receipt: receipt(for: snapshot), .changes(summary)), .skip)

        var favorite = summary
        favorite.updatedAssets["photo-2"] = LibraryAssetFacts(
            creationDate: stored.creationDate, modificationDate: stored.sourceModificationDate,
            isFavorite: true, isScreenshot: false, burstIdentifier: nil)
        XCTAssertEqual(decide(snapshot, receipt: receipt(for: snapshot), .changes(favorite)), .verify("updated"))

        var edited = summary
        edited.updatedAssets["photo-2"] = LibraryAssetFacts(
            creationDate: stored.creationDate, modificationDate: now,
            isFavorite: false, isScreenshot: false, burstIdentifier: nil)
        XCTAssertEqual(decide(snapshot, receipt: receipt(for: snapshot), .changes(edited)), .verify("updated"))

        var unknown = PhotoLibraryChangeSummary()
        unknown.updatedAssets = ["not-stored": LibraryAssetFacts(
            creationDate: nil, modificationDate: nil, isFavorite: false, isScreenshot: false, burstIdentifier: nil)]
        XCTAssertEqual(decide(snapshot, receipt: receipt(for: snapshot), .changes(unknown)), .verify("updated-unknown"))

        var gone = PhotoLibraryChangeSummary()
        gone.updatedAssets = ["photo-1": nil]
        XCTAssertEqual(decide(snapshot, receipt: receipt(for: snapshot), .changes(gone)), .verify("updated-unreadable"))

        var many = PhotoLibraryChangeSummary()
        many.isTruncated = true
        XCTAssertEqual(decide(snapshot, receipt: receipt(for: snapshot), .changes(many)), .verify("many-updates"))
    }

    func testReceiptAndRetryDateSurviveInTheirFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("verification-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LibraryVerificationStore(url: url)
        XCTAssertNil(store.receipt)
        let value = receipt(for: completedSnapshot())
        store.saveReceipt(value)
        store.noteAlbumTraitRetry(at: now)
        let reopened = LibraryVerificationStore(url: url)
        XCTAssertEqual(reopened.receipt, value)
        XCTAssertEqual(reopened.albumTraitRetryAt, now)
    }

    // MARK: - Retry of failed and iCloud-only photos

    func testFailedAndTraitlessPhotosAreRetriedOnceADay() {
        XCTAssertFalse(ScanRetryPolicy.retriesFailedPhoto(lastAttempt: now.addingTimeInterval(-3_600), now: now))
        XCTAssertTrue(ScanRetryPolicy.retriesFailedPhoto(lastAttempt: now.addingTimeInterval(-86_400), now: now))
        // A clock moved backwards does not freeze the retry.
        XCTAssertTrue(ScanRetryPolicy.retriesFailedPhoto(lastAttempt: now.addingTimeInterval(60), now: now))
        XCTAssertTrue(ScanRetryPolicy.retriesMissingAlbumTraits(lastRetry: nil, now: now))
        XCTAssertFalse(ScanRetryPolicy.retriesMissingAlbumTraits(lastRetry: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(ScanRetryPolicy.retriesMissingAlbumTraits(lastRetry: now.addingTimeInterval(-86_401), now: now))
    }

    // MARK: - Widget authority sync: reuse while nothing changed

    func testSyncIsReusedOnlyForTheSameInputsAndForAWhile() {
        var gate = ReuseGate<String, String>(reuseSeconds: 600)
        XCTAssertNil(gate.reusable(for: "inputs-1", uptime: 10))
        gate.record("revision-1", for: "inputs-1", uptime: 10)
        // The burst after launch: same inputs, same answer, no work.
        XCTAssertEqual(gate.reusable(for: "inputs-1", uptime: 11), "revision-1")
        XCTAssertEqual(gate.reusable(for: "inputs-1", uptime: 609), "revision-1")
        // Changed inputs, an old result, or a forced forget run it again.
        XCTAssertNil(gate.reusable(for: "inputs-2", uptime: 11))
        XCTAssertNil(gate.reusable(for: "inputs-1", uptime: 611))
        gate.forget()
        XCTAssertNil(gate.reusable(for: "inputs-1", uptime: 12))
        // A sync of another value (no key) never reuses and replaces the last.
        gate.record("revision-2", for: "inputs-1", uptime: 20)
        XCTAssertNil(gate.reusable(for: nil, uptime: 21))
        gate.record("revision-3", for: nil, uptime: 21)
        XCTAssertNil(gate.reusable(for: "inputs-1", uptime: 22))
    }

    // MARK: - No publication when a pass changes nothing

    func testMergingKnownRecordsChangesNothing() {
        var assets = (0..<4).map { record("photo-\($0)") }
        assets[1].liked = true
        assets[1].shownCount = 3
        var index = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($1.localIdentifier, $0) })
        let before = assets
        // The scanner hands back what it read; user state comes from the app.
        var reread = assets.map { value -> AssetRecord in
            var copy = value
            copy.liked = false
            copy.shownCount = 0
            return copy
        }
        XCTAssertFalse(ScanProgressMerge.merge(reread, into: &assets, index: &index, likes: [:]))
        XCTAssertEqual(assets, before)

        reread[2].isFavorite = true
        XCTAssertTrue(ScanProgressMerge.merge(reread, into: &assets, index: &index, likes: [:]))
        XCTAssertTrue(assets[2].isFavorite)
        XCTAssertTrue(assets[1].liked, "user state is kept")

        XCTAssertTrue(ScanProgressMerge.merge([record("photo-new")], into: &assets, index: &index, likes: [:]))
        XCTAssertEqual(assets.count, 5)
        XCTAssertEqual(index["photo-new"], 4)
    }

    func testSavingTheSameSnapshotWritesOnce() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try LibraryStore(snapshotURL: url)
        let snapshot = completedSnapshot()
        let first = try await store.save(snapshot)
        let second = try await store.save(snapshot)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        var changed = snapshot
        changed.assets[0].isFavorite = true
        let third = try await store.save(changed)
        XCTAssertTrue(third)
        let loaded = try await store.load()
        XCTAssertTrue(loaded.assets[0].isFavorite)
    }

    // MARK: - Cats per photo, built once

    func testConfirmationIndexAnswersLikeTheLedger() {
        let cats = [UUID(), UUID(), UUID()]
        let photos = (0..<60).map { "p\($0)" }
        var memberships: [CatAssetProfileMembership] = []
        for (offset, photo) in photos.enumerated() {
            switch offset % 7 {
            case 0: memberships.append(.init(assetLocalIdentifier: photo, profileID: cats[offset % 3], decision: .included))
            case 1: memberships.append(.init(assetLocalIdentifier: photo, profileID: cats[offset % 3], decision: .excluded))
            case 2:
                // Two decisions for one pair: the first one counts.
                memberships.append(.init(assetLocalIdentifier: photo, profileID: cats[0], decision: .excluded))
                memberships.append(.init(assetLocalIdentifier: photo, profileID: cats[0], decision: .included))
            case 3: memberships.append(.init(assetLocalIdentifier: photo, profileID: cats[1], decision: .unknown))
            default: break
            }
        }
        let profiles = cats.enumerated().map { offset, id in
            CatProfile(id: id, displayName: "猫\(offset)",
                       photoAlbumLink: offset == 2 ? nil : CatProfilePhotoAlbumLink(
                           localIdentifier: "album-\(offset)",
                           lastKnownAssetLocalIdentifiers: photos.enumerated()
                               .filter { $0.offset % (offset + 2) == 0 }.map(\.element)))
        }
        let state = CatHouseholdIdentityState(
            mode: .profiled, profiles: profiles, memberships: memberships,
            globalExcludedAssets: [ExcludedCatAsset(localIdentifier: "p10", excludedAt: now),
                                   ExcludedCatAsset(localIdentifier: "p21", excludedAt: now)],
            legacyUnscoped: nil)
        let index = CatProfileConfirmationIndex(state)
        for photo in photos + ["not-a-photo"] {
            XCTAssertEqual(index.confirmedProfileIDs(for: photo), state.confirmedProfileIDs(for: photo), photo)
        }
    }
}
