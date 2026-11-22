import Foundation
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

private enum Failure: Error { case failed(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ description: String) throws {
    if try !value() { throw Failure.failed(description) }
}
private let baseline = ISO8601DateFormatter().date(from: "2026-10-24T14:59:00Z")!
private let day: TimeInterval = 86_400

private struct Fixture {
    let directory: URL
    let authority: PersonalRediscoveryStore
    let store: CloudyWindowStore
    let candidates: [PersonalRediscoveryCandidate]
    let prepared: [CloudyWindowPreparedPhoto]
    var metadata: [String: CloudyWindowPhotoMetadata]
    let profiles: [String: String]
    let revision: String

    init(count: Int, cats: Int = 0, burstPair: Bool = false, installed: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cloudy-check-\(UUID().uuidString)")
        authority = PersonalRediscoveryStore(containerURL: directory)
        store = CloudyWindowStore(containerURL: directory, internalPresentation: true)
        profiles = Dictionary(uniqueKeysWithValues: (0..<cats).map { ("cat-\($0)", "猫\($0)") })
        let image: Data
#if canImport(ImageIO)
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        try check(CGImageDestinationFinalize(destination), "fixture JPEG")
        image = data as Data
#else
        image = Data([0xff, 0xd8, 0xff, 0xe0, 0, 2, 0xff, 0xd9])
#endif
        candidates = (0..<count).map { index in
            let filenames = WidgetCacheFilenames(small: "photo-\(index)-small.jpg",
                medium: "photo-\(index)-medium.jpg", large: "photo-\(index)-large.jpg")
            return .init(item: .init(localIdentifier: String(format: "photo-%02d", index),
                cacheFilename: filenames.small, cacheFilenames: filenames, scheduledDate: baseline,
                sourceModificationDate: baseline), creationDate: baseline.addingTimeInterval(-Double(index + 1) * day),
                preparedAt: baseline)
        }
        let cache = directory.appendingPathComponent("widget-cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        for filename in candidates.flatMap({ $0.item.allCacheFilenames }) {
            try image.write(to: cache.appendingPathComponent(filename))
        }
        revision = try authority.updateEligibility(photoIDs: Set(candidates.map { $0.item.localIdentifier }),
            scopeIdentifier: "fixture", isAuthorized: true, now: baseline,
            photoModificationDates: Dictionary(uniqueKeysWithValues: candidates.map { ($0.item.localIdentifier, baseline) }))
        try authority.publish(candidates: candidates, expectedRevision: revision, now: baseline)
        metadata = Dictionary(uniqueKeysWithValues: candidates.enumerated().map { index, candidate in
            (candidate.item.localIdentifier, .init(creationDate: candidate.creationDate,
                burstIdentifier: burstPair && index < 2 ? "burst" : nil,
                profileIDs: cats > 0 ? ["cat-\(index % cats)"] : [], previouslyShown: false))
        })
        try store.configure(strength: .strong)
        try store.synchronize(metadata: metadata, profiles: profiles, now: baseline)
        if installed {
            try store.synchronizeInstalledSources(Set([CloudyWindowStore.personalScope]
                + profiles.keys.map { CloudyWindowStore.profilePrefix + $0 }))
        }
        let configuration = store.configuration()
        prepared = candidates.enumerated().map { index, candidate in
            func files(_ kind: String) -> WidgetCacheFilenames {
                .init(small: "cloudy-\(kind)-\(index)-small.jpg", medium: "cloudy-\(kind)-\(index)-medium.jpg",
                      large: "cloudy-\(kind)-\(index)-large.jpg")
            }
            return .init(source: candidate.item, clear: files("clear"), cloudy: files("blur"),
                         strength: .strong, visualHash: UInt64(index), preparedAt: baseline)
        }
        for photo in prepared.prefix(installed ? CloudyWindowStore.maximumPhotoCount : 0) {
            try store.publish(photo, files: Dictionary(uniqueKeysWithValues: photo.filenames.map { ($0, image) }),
                              authorityRevision: revision, configurationRevision: configuration.revision, now: baseline)
        }
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

@main
private enum CloudyWindowVerifier {
    /// 11/20: 「◯年前のきょう」 and the day boundary follow the iPhone's own
    /// day, as the app's 写真 tab does; in Japan that is the JST day as before.
    static func daysFollowTheIPhone() throws {
        let iso = ISO8601DateFormatter()
        let taken = iso.date(from: "2025-11-20T20:00:00Z")!   // 10:00 in Honolulu, 05:00 the 21st in Tokyo
        let today = iso.date(from: "2026-11-20T12:00:00Z")!   // the 20th in both: 02:00 Honolulu, 21:00 Tokyo
        CloudyWindowStore.timeZoneOverride = TimeZone(identifier: "Pacific/Honolulu")!
        let honolulu = CloudyWindowStore.dateMatch(takenAt: taken, on: today)
        try check(honolulu?.offset == 0 && honolulu?.yearsAgo == 1, "the same day a year ago in Honolulu")
        try check(CloudyWindowStore.nextDay(after: today) == iso.date(from: "2026-11-21T10:00:00Z")!, "Honolulu midnight")
        CloudyWindowStore.timeZoneOverride = TimeZone(secondsFromGMT: 9 * 3_600)!
        let tokyo = CloudyWindowStore.dateMatch(takenAt: taken, on: today)
        try check(tokyo?.offset == 1, "a day apart in Tokyo")
        try check(CloudyWindowStore.nextDay(after: today) == iso.date(from: "2026-11-20T15:00:00Z")!, "midnight JST")
        CloudyWindowStore.timeZoneOverride = nil
        try check(CloudyWindowStore.calendar.timeZone == TimeZone.current, "the iPhone's zone by default")
    }

    static func main() throws {
        try daysFollowTheIPhone()
        // The checks below were written for an iPhone in Japan.
        CloudyWindowStore.timeZoneOverride = TimeZone(secondsFromGMT: 9 * 3_600)!
        try dailyReveal()
        try freeWindowGetsItsFirstPhotoOnce()
        try staleDisplayReveal()
        try cacheReleaseKeepsSelection()
        try widgetSelectionWithoutSwitch()
        try beforePlacementPreparesTheNewestFew()
        try rotationAndSmallPools()
        try catScopesAndExpiry()
        try manyCatsWithUnassignedPhotos()
        try permissionAndPublicBoundary()
        try preparationRaces()
        try preparationRetainsPlannedAndFrozenPhotos()
        try albumArrival()
        try albumArrivalGates()
        try albumArrivalFrozenAfterExpiry()
        try albumCoverBeyondPreparationBounds()
        try probableCatsOnlyWhenNothingElse()
        try newPhotoGoesOutTomorrow()
        try dateDays()
        try fewPhotosKeepOneRotation()
        try olderSavesRead()
        try dailyShooterSixtyDays()
        try milestoneDays()
        try dayWords()
        try departedCatsAndDateDays()
        try readFailureFailsClosed()
        try olderSwitchOffIsMigrated()
        try takenTodayWaitsWhenChosenLate()
        try appViewKeepsTheNewDay()
        try editedPhotoKeepsItsDay()
        try timeZoneChangeKeepsTheDay()
        try replacedSelectionTapClearsToday()
        try oneEmptyAnswerKeepsImages()
        try releasingImagesKeepsSelections()
        print("Cloudy window: daily reveal, stale actions, restart, rotation, cats, permission, public mode and publication checks passed")
    }

    /// 11/20: WidgetKit says "no Widget" twice, an hour apart.
    private static func removeEveryWidget(_ f: Fixture, now: Date) throws {
        try f.store.synchronizeInstalledSources([], now: now)
        try f.store.synchronizeInstalledSources([], now: now.addingTimeInterval(CloudyWindowStore.uninstallConfirmationInterval))
    }

    private static var closing: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 1))!
    }

    private static func widgetSelectionWithoutSwitch() throws {
        let f = try Fixture(count: 6, cats: 2, installed: false)
        defer { f.cleanup() }
        let scope = CloudyWindowStore.profilePrefix + "cat-1"
        try check(f.store.profiles().count == 2, "all cats listed before installing a cloudy Widget")
        try check(f.store.preparation(now: baseline) == nil, "no blur preparation before installation")
        try f.store.synchronizeInstalledSources([scope])
        let plan = try f.store.preparation(now: baseline)!
        try check(plan.configuration.enabled && plan.configuration.strength == .strong,
                  "cat Widget works at fixed strength without the personal Widget")
        let baseURL = f.directory.appendingPathComponent("widget-cache").appendingPathComponent(f.candidates[0].item.cacheFilename)
        let image = try Data(contentsOf: baseURL)
        for photo in f.prepared {
            try f.store.publish(photo, files: Dictionary(uniqueKeysWithValues: photo.filenames.map { ($0, image) }),
                authorityRevision: plan.authorityRevision, configurationRevision: plan.configuration.revision, now: baseline)
        }
        try deliver(f, now: closing)
        let first = try f.store.timeline(scopeID: scope, now: closing)[0]
        try check(first.photo.photoID == "photo-05" && first.selection.albumPeriod == "2026-10",
                  "cat's monthly cover arrives without the app switch")
        try check(f.store.reveal(selectionID: first.selection.id, scopeID: scope, photoID: first.photo.photoID,
                               now: closing), "cat Widget reveals without legacy switch")
        try check(f.store.albumPeriod(for: .init(selectionID: first.selection.id), now: closing) == "2026-10",
                  "revealed cat cover opens the monthly work")
        try removeEveryWidget(f, now: closing)
        try check(f.store.preparation(now: closing) == nil, "last Widget removal stops preparation")
        try check(f.store.imageURL(filename: first.photo.clear.small, scopeID: scope) == nil,
                  "last Widget removal releases derived cache")
        try check(FileManager.default.fileExists(atPath: baseURL.path), "base photo cache preserved")
        do {
            try f.store.publish(f.prepared[0], files: [:], authorityRevision: plan.authorityRevision,
                configurationRevision: plan.configuration.revision, now: closing)
            throw Failure.failed("removed Widget's in-flight render accepted")
        } catch PersonalRediscoveryStore.Error.staleRevision { }
    }

    /// 11/10: a Widget placed during the first run draws the cloudy window at
    /// once. Before any Widget, the newest few cats are prepared; once a
    /// window was drawn, removing every Widget still releases everything.
    private static func beforePlacementPreparesTheNewestFew() throws {
        let f = try Fixture(count: 6, installed: false)
        defer { f.cleanup() }
        try check(f.store.preparation(now: baseline) == nil, "no preparation before WidgetKit answered")
        try f.store.synchronizeInstalledSources([])
        let plan = try f.store.preparation(now: baseline)!
        let newest = ["photo-00", "photo-01", "photo-02"]
        try check(plan.candidates.map { $0.item.localIdentifier } == newest
                  && CloudyWindowStore.prePlacementPhotoCount == 3, "the newest three cats are prepared before placement")
        let image = try Data(contentsOf: f.directory.appendingPathComponent("widget-cache")
            .appendingPathComponent(f.candidates[0].item.cacheFilename))
        for photo in f.prepared where newest.contains(photo.photoID) {
            try f.store.publish(photo, files: Dictionary(uniqueKeysWithValues: photo.filenames.map { ($0, image) }),
                authorityRevision: plan.authorityRevision, configurationRevision: plan.configuration.revision,
                protectedPhotoIDs: plan.protectedPhotoIDs, now: baseline)
        }
        try check(!f.store.hasRevealedAnyWindow(), "nothing cleared yet")
        // The Widget is placed while the app is in the background: its first
        // drawing is the cloudy window, never an empty 「アプリを開いて」.
        let first = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: baseline)
        try check(!first.isEmpty && first[0].isCloudy && newest.contains(first[0].photo.photoID),
                  "the first drawing after placement is cloudy and ready")
        try check(f.store.reveal(selectionID: first[0].selection.id, scopeID: first[0].selection.scopeID,
            photoID: first[0].photo.photoID, now: baseline), "only the tag clears it")
        try check(f.store.hasRevealedAnyWindow(), "a cleared window is known for the first Plus offer")
        try check(f.store.preparation(now: baseline) == nil, "after the first drawing, no Widget means no preparation")
        try f.store.synchronizeInstalledSources([CloudyWindowStore.personalScope])
        try removeEveryWidget(f, now: baseline)
        try check(f.store.imageURL(filename: first[0].photo.clear.small) == nil, "removal still releases derived cache")
        try check(f.store.preparation(now: baseline) == nil, "removal stops preparation")
    }

    private static func deliver(_ f: Fixture, photoID: String = "photo-05", now: Date = closing,
                                enabled: Bool = true, opened: Set<String> = [],
                                enabledAt: Date = baseline) throws {
        try f.store.synchronizeAlbumArrival(enabled: enabled, enabledAt: enabledAt, openedPeriods: opened,
            arrival: .init(period: "2026-10", availableAt: closing, photoID: photoID), now: now)
    }

    private static func albumArrival() throws {
        let f = try Fixture(count: 6, cats: 2)
        defer { f.cleanup() }
        try deliver(f, now: baseline)
        try check(f.store.albumPriorityPhotoIDs(now: baseline) == ["photo-05"], "prewarm throughout current month")
        let early = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: baseline)
        try check(early.allSatisfy { $0.selection.albumPeriod == nil }, "future parcel is never announced early")
        let beforeClosing = closing.addingTimeInterval(-60)
        try check(f.store.nextRefresh(after: beforeClosing) == min(closing, CloudyWindowStore.nextDay(after: beforeClosing)),
                  "provider wakes at local-month closing even within a JST day")
        let prior = closing.addingTimeInterval(-day)
        _ = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: prior)
        let arrived = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: closing)[0]
        try check(arrived.photo.photoID == "photo-05" && arrived.selection.albumPeriod == "2026-10",
                  "arrival replaces an unrevealed ordinary tomorrow selection with exact cover")
        let route = CloudyWindowAlbumRoute(selectionID: arrived.selection.id)
        try check(CloudyWindowAlbumRoute(url: route.url) == route, "selection route roundtrip")
        try check(f.store.albumPeriod(for: route, now: closing) == nil, "unrevealed parcel cannot open story")
        let cat = try f.store.timeline(scopeID: CloudyWindowStore.profilePrefix + "cat-0", now: closing)[0]
        try check(cat.selection.albumPeriod == nil, "individual cat scope keeps its own cat")
        try check(f.store.reveal(selectionID: arrived.selection.id, scopeID: arrived.selection.scopeID,
            photoID: arrived.photo.photoID, now: closing), "first tap only reveals committed parcel")
        let restarted = CloudyWindowStore(containerURL: f.directory, internalPresentation: true)
        try check(restarted.albumPeriod(for: route, now: closing) == "2026-10", "revealed route survives process restart")
        try deliver(f, photoID: "photo-04", now: closing)
        let same = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: closing)[0]
        try check(same.selection.id == arrived.selection.id && same.photo.photoID == "photo-05",
                  "new album ranking cannot reroll a revealed window")
        try deliver(f, now: closing, opened: ["2026-10"])
        try check(restarted.albumPeriod(for: route, now: closing) == "2026-10", "opened parcel may reopen same revealed story")
        try deliver(f, now: closing, enabled: false)
        let ordinary = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: closing)[0]
        try check(ordinary.selection.albumPeriod == nil && ordinary.selection.revealedAt != nil
            && ordinary.photo.photoID == "photo-05", "switch off restores ordinary route without reroll")
        try check(restarted.albumPeriod(for: route, now: closing) == nil, "switch off rejects stale parcel URL")
        try deliver(f, now: closing)
        try check(restarted.albumPeriod(for: route, now: closing.addingTimeInterval(day)) == nil, "yesterday route rejected")
        try f.authority.suspend(now: closing)
        try check(restarted.albumPeriod(for: route, now: closing) == nil, "revoked Photos authority rejects route")
        try check(CloudyWindowAlbumRoute(url: URL(string: "nekowidget://album-arrival?month=2099-01")!) == nil,
                  "arbitrary future month URL rejected")
        try check(CloudyWindowAlbumRoute(url: URL(string: route.url.absoluteString + "&month=2099-01")!) == nil,
                  "extra route input rejected")
    }

    private static func albumArrivalGates() throws {
        let f = try Fixture(count: 6)
        defer { f.cleanup() }
        try deliver(f, now: closing, enabledAt: closing)
        try check(f.store.albumPriorityPhotoIDs(now: closing).isEmpty, "archive closed before enabling is not new")
        try deliver(f, now: closing, opened: ["2026-10"])
        try check(f.store.albumPriorityPhotoIDs(now: closing).isEmpty, "opened month cannot announce")
        try deliver(f, photoID: "foreign-photo", now: closing)
        try check(f.store.albumPriorityPhotoIDs(now: closing).isEmpty, "non-authorized cover never enters preparation")
        let oldClosing = Calendar.current.date(byAdding: .month, value: -1, to: closing)!
        try f.store.synchronizeAlbumArrival(enabled: true, enabledAt: baseline.addingTimeInterval(-90 * day),
            openedPeriods: [], arrival: .init(period: "2026-09", availableAt: oldClosing, photoID: "photo-05"),
            now: closing)
        try check(f.store.albumPriorityPhotoIDs(now: closing).isEmpty, "unread old archive is not a new delivery")
        let future = Calendar.current.date(byAdding: .month, value: 2, to: closing)!
        try f.store.synchronizeAlbumArrival(enabled: true, enabledAt: baseline, openedPeriods: [],
            arrival: .init(period: "2026-12", availableAt: future, photoID: "photo-05"), now: closing)
        try check(f.store.albumPriorityPhotoIDs(now: closing).isEmpty, "only current or next closing accepted")
        try deliver(f, now: closing)
        let delivered = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: closing)[0]
        try f.store.synchronizeAlbumArrival(enabled: true, enabledAt: baseline,
            openedPeriods: [], arrival: nil, now: closing)
        let unavailable = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: closing)[0]
        try check(unavailable.selection.albumPeriod == nil && unavailable.photo.photoID == delivered.photo.photoID,
                  "resolved unavailable story clears only its unrevealed label")
        try deliver(f, now: closing)
        _ = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: closing)
        try deliver(f, now: closing, opened: ["2026-10"])
        let readElsewhere = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: closing)[0]
        try check(readElsewhere.selection.albumPeriod == nil && readElsewhere.photo.photoID == delivered.photo.photoID,
                  "opening in album clears unrevealed delivery label without changing photo")
        let publicStore = CloudyWindowStore(containerURL: f.directory, internalPresentation: false)
        try check(publicStore.albumPriorityPhotoIDs(now: closing).isEmpty, "public build cannot prepare album delivery")
        try check(publicStore.albumPeriod(for: .init(selectionID: delivered.selection.id), now: closing) == nil,
                  "public build cannot resolve story route")
    }

    private static func albumCoverBeyondPreparationBounds() throws {
        let f = try Fixture(count: 100)
        defer { f.cleanup() }
        try deliver(f, photoID: "photo-99", now: baseline)
        let plan = try f.store.preparation(now: baseline)!
        try check(plan.candidates.first?.item.localIdentifier == "photo-99", "cover beyond 32 gets first preparation slot")
        let photo = f.prepared[99]
        let image = try Data(contentsOf: f.directory.appendingPathComponent("widget-cache")
            .appendingPathComponent(f.candidates[0].item.cacheFilename))
        try f.store.publish(photo, files: Dictionary(uniqueKeysWithValues: photo.filenames.map { ($0, image) }),
            authorityRevision: plan.authorityRevision, configurationRevision: plan.configuration.revision,
            protectedPhotoIDs: plan.protectedPhotoIDs, now: baseline)
        let arrived = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: closing)[0]
        try check(arrived.photo.photoID == "photo-99", "prepared cover outside original 32 is actually delivered")

        var added = f.candidates[0]
        added.item.localIdentifier = "photo-100"
        added.item.cacheFilename = "photo-100-small.jpg"
        added.item.cacheFilenames = .init(small: "photo-100-small.jpg", medium: "photo-100-medium.jpg", large: "photo-100-large.jpg")
        for name in added.item.allCacheFilenames {
            try image.write(to: f.directory.appendingPathComponent("widget-cache").appendingPathComponent(name))
        }
        let all = f.candidates + [added]
        let revision = try f.authority.updateEligibility(photoIDs: Set(all.map { $0.item.localIdentifier }),
            scopeIdentifier: "fixture", isAuthorized: true, now: closing,
            photoModificationDates: Dictionary(uniqueKeysWithValues: all.map { ($0.item.localIdentifier, baseline) }))
        let published = try f.authority.publish(candidates: [added], expectedRevision: revision,
            now: closing, priorityPhotoIDs: ["photo-100"])
        try check(published.candidates.contains { $0.item.localIdentifier == "photo-100" },
                  "exact cover beyond full 100 pool may replace an unissued candidate")
        try check(published.candidates.contains { $0.item.localIdentifier == arrived.photo.photoID },
                  "cover refill preserves issued photograph")
        try check(published.candidates.count == 100, "cover priority preserves preparation budget")
    }

    private static func albumArrivalFrozenAfterExpiry() throws {
        let f = try Fixture(count: 6)
        defer { f.cleanup() }
        try deliver(f, now: closing)
        let arrived = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: closing)[0]
        let frozen = try f.store.timeline(scopeID: CloudyWindowStore.personalScope,
            now: closing.addingTimeInterval(day), allowsSelection: false,
            selectionValidUntil: closing.addingTimeInterval(60))
        try check(frozen.allSatisfy { $0.selection.id == arrived.selection.id && $0.isCloudy
            && $0.selection.albumPeriod == nil }, "membership freeze keeps photograph and reveal, not yesterday's delivery label")
    }

    private static func freeWindowGetsItsFirstPhotoOnce() throws {
        let f = try Fixture(count: 6)
        defer { f.cleanup() }
        let cutoff = baseline.addingTimeInterval(-60)
        let first = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: baseline,
            allowsSelection: false, selectionValidUntil: cutoff)
        try check(!first.isEmpty, "a never-paid window still shows its first photo")
        let later = try f.store.timeline(scopeID: CloudyWindowStore.personalScope,
            now: baseline.addingTimeInterval(3 * day), allowsSelection: false, selectionValidUntil: cutoff)
        try check(later.first?.selection.id == first[0].selection.id, "the first photo stays; no new day without Plus")
    }

    private static func dailyReveal() throws {
        let f = try Fixture(count: 6)
        defer { f.cleanup() }
        let entries = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: baseline)
        try check(entries.count == 2, "today and tomorrow only")
        try check(entries[1].date == ISO8601DateFormatter().date(from: "2026-10-24T15:00:00Z")!, "midnight JST")
        let first = entries[0].selection
        try check(entries[0].isCloudy && entries[1].isCloudy, "no automatic reveal")
        try check(f.store.reveal(selectionID: first.id, scopeID: first.scopeID, photoID: first.photoID, now: baseline), "reveal succeeds")
        let reopened = CloudyWindowStore(containerURL: f.directory, internalPresentation: true)
        let clear = try reopened.timeline(scopeID: first.scopeID, now: baseline.addingTimeInterval(1))
        try check(!clear[0].isCloudy && clear[0].selection.photoID == first.photoID, "restart keeps the same clear photo")
        try check(reopened.reveal(selectionID: first.id, scopeID: first.scopeID, photoID: first.photoID,
                                 now: baseline.addingTimeInterval(2)), "repeat action is idempotent")
        let later = try reopened.timeline(scopeID: first.scopeID, now: baseline.addingTimeInterval(3))
        try check(later[0].selection.revealedAt == baseline, "duplicate action does not rewrite reveal time")
        let tomorrow = entries[1].date.addingTimeInterval(1)
        try check(!reopened.reveal(selectionID: first.id, scopeID: first.scopeID, photoID: first.photoID, now: tomorrow), "stale action cannot reveal next day")
        let next = try reopened.timeline(scopeID: first.scopeID, now: tomorrow)
        try check(next[0].isCloudy && next[0].selection.photoID != first.photoID, "next day changes photo and resets cloud")
        try check(!reopened.reveal(selectionID: next[0].selection.id, scopeID: first.scopeID,
            photoID: first.photoID, now: tomorrow), "wrong exact photo rejected")
        try f.store.configure(strength: .light)
        try check(f.store.timeline(scopeID: first.scopeID, now: tomorrow)[0].selection.id == next[0].selection.id,
                  "a strength change does not reroll today's photograph")
    }

    private static func staleDisplayReveal() throws {
        let f = try Fixture(count: 6)
        defer { f.cleanup() }
        let issued = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: baseline)
        // Tomorrow's cloudy photo is still on screen two days later because
        // iOS skipped the midnight reload.
        let shown = issued[1].selection
        let later = issued[1].date.addingTimeInterval(day + 3_600)
        try check(!f.store.reveal(selectionID: issued[0].selection.id, scopeID: shown.scopeID,
            photoID: issued[0].photo.photoID, now: later), "an older display cannot clear anything")
        try check(f.store.reveal(selectionID: shown.id, scopeID: shown.scopeID, photoID: shown.photoID, now: later),
                  "tapping the photo on a display iOS never refreshed clears that photo")
        let today = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: later)
        try check(!today[0].isCloudy && today[0].selection.id == shown.id && today[0].photo.photoID == shown.photoID,
                  "the cleared photo becomes today's instead of a different one")
        try check(today[1].isCloudy && today[1].photo.photoID != shown.photoID, "tomorrow is a new cloudy photo")
        try check(!f.store.reveal(selectionID: shown.id, scopeID: shown.scopeID, photoID: shown.photoID,
            now: today[1].date.addingTimeInterval(1)), "a cleared photo cannot be carried into the next day")
    }

    private static func cacheReleaseKeepsSelection() throws {
        let f = try Fixture(count: 6)
        defer { f.cleanup() }
        let shown = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: baseline)[0]
        try check(f.store.reveal(selectionID: shown.selection.id, scopeID: shown.selection.scopeID,
            photoID: shown.photo.photoID, now: baseline), "reveal before removal")
        try f.store.synchronizeInstalledSources([], now: baseline.addingTimeInterval(-2 * CloudyWindowStore.uninstallConfirmationInterval))
        try f.store.synchronizeInstalledSources([], now: baseline)
        try check(f.store.imageURL(filename: shown.photo.clear.small) == nil, "removal still releases derived cache")
        try f.store.synchronizeInstalledSources([CloudyWindowStore.personalScope])
        // The fixture baseline is 23:59 JST, so stay inside that minute.
        let again = baseline.addingTimeInterval(10)
        let plan = try f.store.preparation(now: again)!
        try check(plan.candidates.contains { $0.item.localIdentifier == shown.photo.photoID }
                  && plan.protectedPhotoIDs.contains(shown.photo.photoID), "today's photo is rendered again")
        try check(f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: again).isEmpty,
                  "no other photo is shown while today's is being rendered")
        let image = try Data(contentsOf: f.directory.appendingPathComponent("widget-cache")
            .appendingPathComponent(f.candidates[0].item.cacheFilename))
        let photo = f.prepared.first { $0.photoID == shown.photo.photoID }!
        try f.store.publish(photo, files: Dictionary(uniqueKeysWithValues: photo.filenames.map { ($0, image) }),
            authorityRevision: plan.authorityRevision, configurationRevision: plan.configuration.revision, now: again)
        let back = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: again.addingTimeInterval(10))
        try check(back[0].selection.id == shown.selection.id && !back[0].isCloudy,
                  "re-adding the Widget keeps the same cleared photo")
    }

    /// 11/14: たぶん猫 are chosen only when the scope has no 確かな猫; a cat
    /// whose photos are all たぶん猫 still gets its turn.
    private static func probableCatsOnlyWhenNothingElse() throws {
        var household = try Fixture(count: 4)
        defer { household.cleanup() }
        for id in ["photo-00", "photo-01", "photo-02"] { household.metadata[id]?.isProbableCat = true }
        try household.store.synchronize(metadata: household.metadata, profiles: household.profiles, now: baseline)
        for offset in 0..<4 {
            let entry = try household.store.timeline(scopeID: CloudyWindowStore.personalScope,
                now: baseline.addingTimeInterval(Double(offset) * day))[0]
            try check(entry.selection.photoID == "photo-03", "the one 確かな猫 is chosen every day")
        }
        var cats = try Fixture(count: 6, cats: 2)
        defer { cats.cleanup() }
        // cat-0: photo-00, 02, 04 (00 is たぶん猫); cat-1: 01, 03, 05 (all たぶん猫).
        for id in ["photo-00", "photo-01", "photo-03", "photo-05"] { cats.metadata[id]?.isProbableCat = true }
        try cats.store.synchronize(metadata: cats.metadata, profiles: cats.profiles, now: baseline)
        for offset in 0..<4 {
            let entry = try cats.store.timeline(scopeID: CloudyWindowStore.profilePrefix + "cat-0",
                now: baseline.addingTimeInterval(Double(offset) * day))[0]
            try check(entry.selection.photoID != "photo-00", "a cat with 確かな猫 never shows its たぶん猫")
        }
        let onlyProbable = try cats.store.timeline(scopeID: CloudyWindowStore.profilePrefix + "cat-1", now: baseline)
        try check(!onlyProbable.isEmpty, "a cat with only たぶん猫 still gets a photo")
    }

    /// 11/15 毎日の1枚の決まり v2: a new day at most once in 3 days (the
    /// newest new photo; within a capture day ハート first), ordinary days
    /// only older photos when there are enough, today's photo never swapped,
    /// and new photos enter the 32 (8 at most).
    private static func newPhotoGoesOutTomorrow() throws {
        let d = baseline
        try check(CloudyWindowStore.newPhotoDays == 30 && CloudyWindowStore.newDayGap == 3
                  && CloudyWindowStore.dateDayGap == 7 && CloudyWindowStore.dateWindowDays == 3
                  && CloudyWindowStore.splitPhotoCount == 30 && CloudyWindowStore.preparedNewPhotoCount == 8,
                  "the day rules keep their numbers")
        try check(CloudyWindowStore.isNewPhoto(takenAt: d.addingTimeInterval(-29 * day), previouslyShown: false, at: d)
                  && !CloudyWindowStore.isNewPhoto(takenAt: d.addingTimeInterval(-31 * day), previouslyShown: false, at: d)
                  && !CloudyWindowStore.isNewPhoto(takenAt: d.addingTimeInterval(-3_600), previouslyShown: true, at: d)
                  && !CloudyWindowStore.isNewPhoto(takenAt: nil, previouslyShown: false, at: d),
                  "new means taken within 30 days and never shown")
        try check(CloudyWindowStore.isOldPhoto(takenAt: d.addingTimeInterval(-31 * day), at: d)
                  && !CloudyWindowStore.isOldPhoto(takenAt: d.addingTimeInterval(-29 * day), at: d)
                  && CloudyWindowStore.isOldPhoto(takenAt: nil, at: d), "old means taken more than 30 days ago")
        let taken = (0..<10).map { (id: "p\($0)", date: d.addingTimeInterval(-Double($0) * 3_600)) }
            + [(id: "old", date: d.addingTimeInterval(-31 * day))]
        let priority = CloudyWindowStore.newPhotoIDs(taken, now: d, id: { $0.id }, takenAt: { Optional($0.date) })
        try check(priority == Set((0..<8).map { "p\($0)" }), "the host asks for the newest 8 new photos only")

        var f = try Fixture(count: 40, cats: 2)
        defer { f.cleanup() }
        takenLongAgo(&f)
        try f.store.synchronize(metadata: f.metadata, profiles: f.profiles, now: d)
        let before = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: d)
        try check(before.count == 2 && before.allSatisfy { $0.selection.kind == .ordinary },
                  "older photos only: ordinary days")
        // Three photos of cat-0 are found on opening the app: two taken
        // today (the earlier one with the app's heart, the later one a
        // Photos favorite) and one yesterday.
        f.metadata["photo-06"]?.creationDate = d.addingTimeInterval(-3_600)
        f.metadata["photo-06"]?.isPhotosFavorite = true
        f.metadata["photo-04"]?.creationDate = d.addingTimeInterval(-7_200)
        f.metadata["photo-04"]?.isLiked = true
        f.metadata["photo-02"]?.creationDate = d.addingTimeInterval(-day)
        f.metadata["photo-02"]?.isLiked = true
        try f.store.synchronize(metadata: f.metadata, profiles: f.profiles, now: d.addingTimeInterval(5))
        let found = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: d.addingTimeInterval(10))
        try check(found[0].selection.id == before[0].selection.id && found[0].photo.photoID == before[0].photo.photoID,
                  "today's photo is never swapped")
        try check(found[1].photo.photoID == "photo-04" && found[1].isCloudy && found[1].selection.kind == .new,
                  "tomorrow is chosen again: the newest day's photo, the app's heart before a Photos favorite")
        var kinds: [CloudyWindowDayKind?] = []
        var photos: [String] = []
        var date = found[1].date
        for _ in 0..<7 {
            let entry = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: date.addingTimeInterval(1))[0]
            kinds.append(entry.selection.kind)
            photos.append(entry.photo.photoID)
            if entry.selection.kind == .ordinary {
                try check(CloudyWindowStore.isOldPhoto(takenAt: f.metadata[entry.photo.photoID]?.creationDate, at: date),
                          "an ordinary day never shows a photo of the last 30 days")
            }
            date = CloudyWindowStore.nextDay(after: date)
        }
        try check(kinds == [.new, .ordinary, .ordinary, .new, .ordinary, .ordinary, .new],
                  "a new day at most once in 3 days")
        try check(photos[0] == "photo-04" && photos[3] == "photo-06" && photos[6] == "photo-02",
                  "new photos go out newest day first, each once")

        // The 32 take the new photos first, 8 at most; the rest stays older.
        var many = try Fixture(count: 60)
        defer { many.cleanup() }
        takenLongAgo(&many)
        for index in 40..<60 {
            many.metadata[String(format: "photo-%02d", index)]?.creationDate = d.addingTimeInterval(-Double(index) * 3_600)
        }
        try many.store.synchronize(metadata: many.metadata, profiles: many.profiles, now: d)
        let plan = try many.store.preparation(now: d)!
        let planned = plan.candidates.map { $0.item.localIdentifier }
        try check(planned.first == "photo-40" && plan.protectedPhotoIDs.contains("photo-40"),
                  "the newest new photo, outside the old 32, is prepared first")
        try check(planned.filter { Int($0.dropFirst(6))! >= 40 }.count == 8 && planned.count == 32,
                  "the 32 hold 8 new photos and older photos")
    }

    /// 11/15: a date day at most once a week; the same month and day before
    /// within 3 days; only with enough older photos.
    private static func dateDays() throws {
        func match(_ taken: String, _ day: String) -> (offset: Int, yearsAgo: Int)? {
            let formatter = ISO8601DateFormatter()
            return CloudyWindowStore.dateMatch(takenAt: formatter.date(from: taken), on: formatter.date(from: day)!)
        }
        let sameDay = match("2025-10-24T12:00:00+09:00", "2026-10-24T00:00:00+09:00")
        try check(sameDay?.offset == 0 && sameDay?.yearsAgo == 1, "date match: the same month and day a year ago")
        let acrossNewYear = match("2023-12-30T12:00:00+09:00", "2026-01-02T00:00:00+09:00")
        try check(acrossNewYear?.offset == 3 && acrossNewYear?.yearsAgo == 2, "date match: within 3 days across a new year")
        let leapDay = match("2024-02-28T12:00:00+09:00", "2028-02-29T00:00:00+09:00")
        try check(leapDay?.offset == 1, "date match: 2/29")
        try check(match("2025-10-20T12:00:00+09:00", "2026-10-24T00:00:00+09:00") == nil
                  && match("2026-10-23T12:00:00+09:00", "2026-10-24T00:00:00+09:00") == nil,
                  "date match: not 4 days apart, not this year")
        let hostPicks = CloudyWindowStore.datePhotoIDs(
            [(id: "year-ago", date: baseline.addingTimeInterval(-365 * day + 2 * day)),
             (id: "spring", date: baseline.addingTimeInterval(-200 * day)),
             (id: "recent", date: baseline.addingTimeInterval(-2 * day))],
            now: baseline, id: { $0.id }, takenAt: { Optional($0.date) })
        try check(hostPicks == ["year-ago"], "the host asks for the coming week's date photos only")

        var f = try Fixture(count: 40)
        defer { f.cleanup() }
        takenLongAgo(&f)
        let formatter = ISO8601DateFormatter()
        for (id, text) in [("photo-10", "2025-10-24T12:00:00+09:00"), ("photo-13", "2025-10-23T12:00:00+09:00"),
                           ("photo-11", "2024-10-26T12:00:00+09:00"), ("photo-12", "2024-10-31T12:00:00+09:00"),
                           ("photo-14", "2023-11-02T12:00:00+09:00")] {
            f.metadata[id]?.creationDate = formatter.date(from: text)
        }
        try f.store.synchronize(metadata: f.metadata, profiles: f.profiles, now: baseline)
        var date = CloudyWindowStore.calendar.startOfDay(for: baseline)
        var dateDays: [Int] = []
        for offset in 0..<14 {
            let entry = try f.store.timeline(scopeID: CloudyWindowStore.personalScope,
                now: offset == 0 ? baseline : date.addingTimeInterval(1))[0]
            if offset == 0 {
                try check(entry.selection.kind == .date && entry.photo.photoID == "photo-10"
                          && entry.selection.dateSameDay == true && entry.selection.dateYearsAgo == 1,
                          "the same month and day comes before one within 3 days")
            }
            if entry.selection.kind == .date {
                dateDays.append(offset)
                try check(CloudyWindowStore.dateMatch(takenAt: f.metadata[entry.photo.photoID]?.creationDate,
                                                      on: date) != nil, "a date day shows a photo of that date")
            }
            date = CloudyWindowStore.nextDay(after: date)
        }
        try check(dateDays.first == 0 && dateDays.contains(7)
                  && zip(dateDays, dateDays.dropFirst()).allSatisfy { $0.1 - $0.0 >= 7 },
                  "a date day at most once a week")

        // Fewer than 30 older photos: no date days.
        var few = try Fixture(count: 20)
        defer { few.cleanup() }
        takenLongAgo(&few)
        few.metadata["photo-10"]?.creationDate = formatter.date(from: "2025-10-24T12:00:00+09:00")
        try few.store.synchronize(metadata: few.metadata, profiles: few.profiles, now: baseline)
        let fewToday = try few.store.timeline(scopeID: CloudyWindowStore.personalScope, now: baseline)[0]
        try check(fewToday.selection.kind != .date, "few photos: the kinds of day do not apply")
    }

    /// 11/15: under 30 older photos, one rotation; a new photo the next day,
    /// never two days running, and recent photos stay in the rotation.
    private static func fewPhotosKeepOneRotation() throws {
        let f = try Fixture(count: 6)
        defer { f.cleanup() }
        var kinds: [CloudyWindowDayKind?] = []
        var recentOnOrdinary = false
        for offset in 0..<6 {
            let now = baseline.addingTimeInterval(Double(offset) * day)
            let entry = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: now)[0]
            kinds.append(entry.selection.kind)
            if entry.selection.kind == .ordinary,
               !CloudyWindowStore.isOldPhoto(takenAt: f.metadata[entry.photo.photoID]?.creationDate, at: now) {
                recentOnOrdinary = true
            }
        }
        try check(kinds[0] == .new && zip(kinds, kinds.dropFirst()).allSatisfy { !($0.0 == .new && $0.1 == .new) },
                  "few photos: a new photo comes, never two days running")
        try check(recentOnOrdinary && !kinds.contains(.date), "few photos: the days are not split")
    }

    /// 11/15: saves from older builds read; a kind added later does not
    /// break reading.
    private static func olderSavesRead() throws {
        let selection = try JSONDecoder().decode(CloudyWindowSelection.self, from: Data(
            #"{"id":"a","scopeID":"personal-library","day":0,"photoID":"p"}"#.utf8))
        try check(selection.dayKind == nil && selection.kind == nil && selection.chosenAt == nil
                  && selection.dateYearsAgo == nil, "an older selection reads without a kind")
        let later = try JSONDecoder().decode(CloudyWindowSelection.self, from: Data(
            #"{"id":"a","scopeID":"personal-library","day":0,"photoID":"p","dayKind":"later-kind"}"#.utf8))
        try check(later.dayKind == "later-kind" && later.kind == nil && later.milestone == nil,
                  "a later kind reads as unknown")
        let marks = try JSONDecoder().decode([String: [CloudyWindowMilestoneDay]].self, from: Data(
            #"{"cat":[{"day":0,"kind":"birthday","years":5}]}"#.utf8))
        try check(marks["cat"]?.first?.years == 5, "a cat's days read")
        let metadata = try JSONDecoder().decode(CloudyWindowPhotoMetadata.self, from: Data(
            #"{"creationDate":0,"profileIDs":[],"previouslyShown":false}"#.utf8))
        try check(metadata.isLiked == nil && metadata.isPhotosFavorite == nil, "older photo details read")
        let encoded = try JSONEncoder().encode(CloudyWindowSelection(scopeID: "s", day: baseline, photoID: "p",
            profileID: nil, dayKind: CloudyWindowDayKind.date.rawValue, dateYearsAgo: 2, dateSameDay: false))
        let back = try JSONDecoder().decode(CloudyWindowSelection.self, from: encoded)
        try check(back.kind == .date && back.dateYearsAgo == 2 && back.dateSameDay == false, "the kind is kept")
    }

    /// 11/15: someone who takes a cat photo every day, for 60 days: about a
    /// third are new days, and ordinary days never show the last 30 days.
    private static func dailyShooterSixtyDays() throws {
        var f = try Fixture(count: 100)
        defer { f.cleanup() }
        takenLongAgo(&f)
        let start = CloudyWindowStore.nextDay(after: baseline)
        for index in 0..<60 {
            f.metadata[String(format: "photo-%02d", index)]?.creationDate =
                start.addingTimeInterval(Double(index) * day + 8 * 3_600)
        }
        let image = try Data(contentsOf: f.directory.appendingPathComponent("widget-cache")
            .appendingPathComponent(f.candidates[0].item.cacheFilename))
        var newDays: [Int] = []
        for offset in 0..<60 {
            let now = start.addingTimeInterval(Double(offset) * day + 12 * 3_600)
            let known = f.metadata.filter { entry in
                let index = Int(entry.key.dropFirst(6))!
                return index >= 60 || index <= offset
            }
            try f.store.synchronize(metadata: known, profiles: f.profiles, now: now)
            let plan = try f.store.preparation(now: now)!
            for candidate in plan.candidates where !plan.existing.contains(where: {
                $0.photoID == candidate.item.localIdentifier
            }) {
                let photo = f.prepared[Int(candidate.item.localIdentifier.dropFirst(6))!]
                try f.store.publish(photo, files: Dictionary(uniqueKeysWithValues: photo.filenames.map { ($0, image) }),
                    authorityRevision: plan.authorityRevision, configurationRevision: plan.configuration.revision,
                    protectedPhotoIDs: plan.protectedPhotoIDs, now: now)
            }
            let entry = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: now)[0]
            switch entry.selection.kind {
            case .new?: newDays.append(offset)
            case .ordinary?:
                try check(CloudyWindowStore.isOldPhoto(takenAt: known[entry.photo.photoID]?.creationDate, at: now),
                          "a daily photographer's ordinary days stay older photos")
            default: break
            }
        }
        try check((18...22).contains(newDays.count) && zip(newDays, newDays.dropFirst()).allSatisfy { $0.1 - $0.0 >= 3 },
                  "a daily photographer gets a new day about one day in three")
    }

    /// 11/15 節目: a cat's birthday or day it came home comes first; one
    /// photo with every such cat, else the cat shown least lately; never a
    /// first-year day; the monthly work comes before it.
    private static func milestoneDays() throws {
        let d = baseline
        let tomorrow = CloudyWindowStore.nextDay(after: d)
        func mark(_ kind: CloudyWindowMilestoneKind, _ years: Int, on day: Date? = nil) -> CloudyWindowMilestoneDay {
            CloudyWindowMilestoneDay(day: day ?? tomorrow, kind: kind.rawValue, years: years)
        }
        let household = CloudyWindowStore.personalScope

        var f = try Fixture(count: 40, cats: 2)
        defer { f.cleanup() }
        takenLongAgo(&f)
        try f.store.synchronize(metadata: f.metadata, profiles: f.profiles,
                                milestones: ["cat-0": [mark(.birthday, 5)], "cat-1": [mark(.birthday, 0)]], now: d)
        let one = try f.store.timeline(scopeID: household, now: d)
        try check(one[0].selection.kind == .ordinary && one[1].selection.kind == .milestone,
                  "a 節目 day comes first")
        try check(f.metadata[one[1].photo.photoID]?.profileIDs.contains("cat-0") == true
                  && one[1].selection.milestone?.cats.map(\.id) == ["cat-0"],
                  "the birthday cat's photo; a first-year day is not a 節目")
        try check(CloudyWindowDayText.tag(one[1].selection) == ["きょうは 猫0の誕生日", "猫0の誕生日", "きょうは 誕生日", "誕生日"],
                  "the tag names the cat")
        let own = try f.store.timeline(scopeID: CloudyWindowStore.profilePrefix + "cat-0", now: d)
        let other = try f.store.timeline(scopeID: CloudyWindowStore.profilePrefix + "cat-1", now: d)
        try check(own[1].selection.kind == .milestone && other[1].selection.kind != .milestone,
                  "a cat's own window keeps only its own day")

        var both = try Fixture(count: 40, cats: 2)
        defer { both.cleanup() }
        takenLongAgo(&both)
        both.metadata["photo-07"]?.profileIDs = ["cat-0", "cat-1"]
        try both.store.synchronize(metadata: both.metadata, profiles: both.profiles,
                                   milestones: ["cat-0": [mark(.birthday, 5)], "cat-1": [mark(.birthday, 3)]], now: d)
        let together = try both.store.timeline(scopeID: household, now: d)[1]
        try check(together.photo.photoID == "photo-07"
                  && CloudyWindowDayText.tag(together.selection) == ["きょうは 猫0と猫1の誕生日", "きょうは 誕生日", "誕生日"],
                  "two cats on the same birthday: the photo with both")
        var cleared = together.selection
        cleared.revealedAt = d
        try check(CloudyWindowDayText.revealedLine(cleared) == ["猫0 5歳・猫1 3歳", "きょうは 誕生日"],
                  "after clearing: each cat in the photo and its age")

        var apart = try Fixture(count: 40, cats: 2)
        defer { apart.cleanup() }
        takenLongAgo(&apart)
        try apart.store.synchronize(metadata: apart.metadata, profiles: apart.profiles,
                                    milestones: ["cat-0": [mark(.birthday, 5)], "cat-1": [mark(.birthday, 3)]], now: d)
        let pair = try apart.store.timeline(scopeID: household, now: d)
        try check(apart.metadata[pair[0].photo.photoID]?.profileIDs == ["cat-0"]
                  && apart.metadata[pair[1].photo.photoID]?.profileIDs == ["cat-1"]
                  && pair[1].selection.milestone?.cats.map(\.inPhoto) == [false, true],
                  "no photo with both: the cat shown least lately")
        var apartCleared = pair[1].selection
        apartCleared.revealedAt = d
        try check(CloudyWindowDayText.revealedLine(apartCleared) == ["猫1 3歳", "3歳の誕生日"],
                  "after clearing: only the cat in the photo")

        var mixed = try Fixture(count: 40, cats: 2)
        defer { mixed.cleanup() }
        takenLongAgo(&mixed)
        try mixed.store.synchronize(metadata: mixed.metadata, profiles: mixed.profiles,
                                    milestones: ["cat-0": [mark(.adoption, 4)], "cat-1": [mark(.birthday, 2)]], now: d)
        let birthdayFirst = try mixed.store.timeline(scopeID: household, now: d)[1].selection
        try check(birthdayFirst.milestone?.kind == "birthday" && birthdayFirst.milestone?.cats.map(\.id) == ["cat-1"],
                  "a birthday comes before a day a cat came home")

        // The monthly work's day keeps the work.
        let work = try Fixture(count: 6, cats: 2)
        defer { work.cleanup() }
        try deliver(work, now: baseline)
        let workDay = CloudyWindowStore.calendar.startOfDay(for: closing)
        try work.store.synchronize(metadata: work.metadata, profiles: work.profiles,
                                   milestones: ["cat-1": [mark(.birthday, 2, on: workDay)]], now: baseline)
        _ = try work.store.timeline(scopeID: household, now: closing.addingTimeInterval(-day))
        let arrived = try work.store.timeline(scopeID: household, now: closing)[0]
        try check(arrived.selection.albumPeriod == "2026-10" && arrived.selection.kind != .milestone
                  && CloudyWindowDayText.tag(arrived.selection) == nil, "the monthly work comes before a 節目")
    }

    /// 11/15: the words of a date day and a 節目 day, and what VoiceOver adds.
    private static func dayWords() throws {
        let d = baseline
        func selection(_ kind: String?, revealed: Bool = true, years: Int? = nil, sameDay: Bool? = nil,
                       milestone: CloudyWindowMilestone? = nil, album: String? = nil) -> CloudyWindowSelection {
            CloudyWindowSelection(scopeID: "s", day: d, photoID: "p", profileID: nil, revealedAt: revealed ? d : nil,
                                  albumPeriod: album, dayKind: kind, dateYearsAgo: years, dateSameDay: sameDay,
                                  milestone: milestone)
        }
        func cats(_ kind: CloudyWindowMilestoneKind, _ values: [(String, Int, Bool)]) -> CloudyWindowMilestone {
            CloudyWindowMilestone(kind: kind.rawValue, cats: values.map {
                CloudyWindowMilestone.Cat(id: $0.0, name: $0.0, years: $0.1, inPhoto: $0.2)
            })
        }
        try check(CloudyWindowDayText.revealedLine(selection("date", years: 1, sameDay: true)) == ["1年前のきょう"],
                  "date day: the same month and day says きょう")
        try check(CloudyWindowDayText.revealedLine(selection("date", years: 3, sameDay: false)) == ["3年前の今ごろ"],
                  "date day: within 3 days says 今ごろ")
        try check(CloudyWindowDayText.revealedLine(selection("date", revealed: false, years: 1, sameDay: true)) == nil
                  && CloudyWindowDayText.revealedLine(selection("date", years: 1, sameDay: true, album: "2026-10")) == nil
                  && CloudyWindowDayText.revealedLine(selection("ordinary")) == nil
                  && CloudyWindowDayText.revealedLine(selection("new")) == nil
                  && CloudyWindowDayText.revealedLine(selection(nil)) == nil,
                  "no line while cloudy, on a work's day, or on other days")
        try check(CloudyWindowDayText.spokenPhotoSuffix(selection("date", years: 1, sameDay: true)) == "、1年前のきょう"
                  && CloudyWindowDayText.spokenPhotoSuffix(nil) == ""
                  && CloudyWindowDayText.spokenTagPrefix(selection("ordinary", revealed: false)) == "",
                  "VoiceOver adds the line only when there is one")
        let single = cats(.birthday, [("猫0", 5, true)])
        try check(CloudyWindowDayText.revealedLine(selection("milestone", milestone: single)) == ["猫0 5歳", "5歳の誕生日"]
                  && CloudyWindowDayText.spokenPhotoSuffix(selection("milestone", milestone: single)) == "、猫0 5歳"
                  && CloudyWindowDayText.spokenTagPrefix(selection("milestone", revealed: false, milestone: single))
                    == "きょうは 猫0の誕生日。", "a birthday's words and VoiceOver")
        let three = selection("milestone", revealed: false,
                              milestone: cats(.birthday, [("猫0", 5, true), ("猫1", 3, false), ("猫2", 2, false)]))
        try check(CloudyWindowDayText.tag(three) == ["きょうは 3匹の誕生日", "3匹の誕生日", "誕生日"], "three cats: the count")
        try check(CloudyWindowDayText.tag(selection("milestone", revealed: false,
                                                    milestone: cats(.adoption, [("猫0", 4, true)])))
                  == ["猫0が来て 4年", "うちに来て 4年", "うちに来た日"], "a day a cat came home")
        let sameYears = cats(.adoption, [("猫0", 4, true), ("猫1", 4, true)])
        try check(CloudyWindowDayText.tag(selection("milestone", revealed: false, milestone: sameYears))
                  == ["うちに来て 4年", "うちに来た日"]
                  && CloudyWindowDayText.revealedLine(selection("milestone", milestone: sameYears)) == ["うちに来て 4年"],
                  "two cats home the same years")
        let otherYears = cats(.adoption, [("猫0", 4, true), ("猫1", 2, true)])
        try check(CloudyWindowDayText.tag(selection("milestone", revealed: false, milestone: otherYears)) == ["うちに来た日"]
                  && CloudyWindowDayText.revealedLine(selection("milestone", milestone: otherYears)) == ["うちに来た日"],
                  "two cats home different years")
        let long = String(repeating: "な", count: 25)
        try check(CloudyWindowDayText.tag(selection("milestone", revealed: false,
                                                    milestone: cats(.birthday, [(long, 5, true)])))?.first
                  == "きょうは " + String(repeating: "な", count: 20) + "の誕生日", "a name is 20 letters at most")
        try check(CloudyWindowDayText.tag(selection("milestone", revealed: false, milestone: single, album: "2026-10")) == nil,
                  "a monthly work's tag stays the work's")
        try check(CloudyWindowDayText.revealForms(selection("ordinary", revealed: false)) == ["タップで、きょうの1枚", "きょうの1枚"]
                  && CloudyWindowDayText.revealForms(selection("date", revealed: false, years: 1, sameDay: true))
                    == ["タップで、きょうの1枚", "きょうの1枚"]
                  && CloudyWindowDayText.revealForms(selection("milestone", revealed: false, milestone: single, album: "2026-10"))
                    == ["作品がとどきました", "作品がとどいた"]
                  && CloudyWindowDayText.revealForms(selection("milestone", revealed: false, milestone: single))
                    == CloudyWindowDayText.tag(selection("milestone", revealed: false, milestone: single)),
                  "every tag has a shorter form: other days and a work's day too")
        // 11/22: the tag's symbol follows the same day as its words.
        try check(CloudyWindowDayText.tagSymbol(selection("ordinary", revealed: false)) == "hand.tap.fill"
                  && CloudyWindowDayText.tagSymbol(selection("date", revealed: false, years: 1, sameDay: true)) == "hand.tap.fill"
                  && CloudyWindowDayText.tagSymbol(selection("milestone", revealed: false, milestone: single)) == "birthday.cake.fill"
                  && CloudyWindowDayText.tagSymbol(selection("milestone", revealed: false, milestone: sameYears)) == "house.fill"
                  && CloudyWindowDayText.tagSymbol(selection("milestone", revealed: false, milestone: single, album: "2026-10"))
                    == "book.closed.fill",
                  "the tag's symbol: hand, cake, house, closed book")
    }

    /// 11/15: a photo of only cats that have died never makes a date day; one
    /// with a living cat too may; a dead cat's own window has no date day.
    private static func departedCatsAndDateDays() throws {
        let formatter = ISO8601DateFormatter()
        let household = CloudyWindowStore.personalScope

        var only = try Fixture(count: 40, cats: 2)
        defer { only.cleanup() }
        takenLongAgo(&only)
        only.metadata["photo-10"]?.creationDate = formatter.date(from: "2025-10-24T12:00:00+09:00")
        only.metadata["photo-12"]?.creationDate = formatter.date(from: "2025-10-25T12:00:00+09:00")
        only.metadata["photo-13"]?.creationDate = formatter.date(from: "2025-10-26T12:00:00+09:00")
        try only.store.synchronize(metadata: only.metadata, profiles: only.profiles, departed: ["cat-0"], now: baseline)
        let skipped = try only.store.timeline(scopeID: household, now: baseline)[0]
        try check(skipped.selection.kind == .date && skipped.photo.photoID == "photo-13",
                  "a photo of only a cat that has died is not a date day's")

        var together = try Fixture(count: 40, cats: 2)
        defer { together.cleanup() }
        takenLongAgo(&together)
        together.metadata["photo-10"]?.creationDate = formatter.date(from: "2025-10-24T12:00:00+09:00")
        together.metadata["photo-12"]?.creationDate = formatter.date(from: "2025-10-25T12:00:00+09:00")
        together.metadata["photo-12"]?.profileIDs = ["cat-0", "cat-1"]
        try together.store.synchronize(metadata: together.metadata, profiles: together.profiles,
                                       departed: ["cat-0"], now: baseline)
        let shared = try together.store.timeline(scopeID: household, now: baseline)[0]
        try check(shared.selection.kind == .date && shared.photo.photoID == "photo-12",
                  "a photo with a living cat too may be a date day's")

        func catWindow(departed: Set<String>) throws -> CloudyWindowSelection {
            var f = try Fixture(count: 70, cats: 2)
            defer { f.cleanup() }
            takenLongAgo(&f)
            f.metadata["photo-10"]?.creationDate = formatter.date(from: "2025-10-24T12:00:00+09:00")
            try f.store.synchronize(metadata: f.metadata, profiles: f.profiles, departed: departed, now: baseline)
            return try f.store.timeline(scopeID: CloudyWindowStore.profilePrefix + "cat-0", now: baseline)[0].selection
        }
        try check(try catWindow(departed: []).kind == .date, "a living cat's own window has date days")
        try check(try catWindow(departed: ["cat-0"]).kind != .date, "a cat that has died: no date day in its window")
    }

    /// Long ago, a day apart each, so nearby captures are not taken as one.
    private static func takenLongAgo(_ f: inout Fixture) {
        for key in f.metadata.keys {
            f.metadata[key]?.creationDate = baseline.addingTimeInterval(-Double(60 + Int(key.dropFirst(6))!) * day)
        }
    }

    private static func rotationAndSmallPools() throws {
        // Older photos: ordinary days only, so each one waits its turn.
        var f = try Fixture(count: 32)
        defer { f.cleanup() }
        takenLongAgo(&f)
        try f.store.synchronize(metadata: f.metadata, profiles: f.profiles, now: baseline)
        var seen: [String] = []
        for offset in 0..<35 {
            let entry = try f.store.timeline(scopeID: CloudyWindowStore.personalScope,
                now: baseline.addingTimeInterval(Double(offset) * day))[0]
            try check(!seen.suffix(30).contains(entry.selection.photoID), "avoid the previous 30 days with enough photos")
            seen.append(entry.selection.photoID)
        }
        let small = try Fixture(count: 2)
        defer { small.cleanup() }
        let first = try small.store.timeline(scopeID: CloudyWindowStore.personalScope, now: baseline)[0].selection.photoID
        let second = try small.store.timeline(scopeID: CloudyWindowStore.personalScope, now: baseline.addingTimeInterval(day))[0].selection.photoID
        try check(first != second, "small pools still alternate")
        let single = try Fixture(count: 1)
        defer { single.cleanup() }
        try check(single.store.timeline(scopeID: CloudyWindowStore.personalScope, now: baseline).count == 2,
                  "one photo remains usable")
        let burst = try Fixture(count: 4, burstPair: true)
        defer { burst.cleanup() }
        var burstSeen = Set<String>()
        for offset in 0..<8 {
            burstSeen.insert(try burst.store.timeline(scopeID: CloudyWindowStore.personalScope,
                now: baseline.addingTimeInterval(Double(offset) * day))[0].selection.photoID)
        }
        try check(!burstSeen.contains("photo-00") || !burstSeen.contains("photo-01"), "one representative per burst")
    }

    private static func catScopesAndExpiry() throws {
        var f = try Fixture(count: 6, cats: 3)
        defer { f.cleanup() }
        var cats: [String] = []
        for offset in 0..<6 {
            let entry = try f.store.timeline(scopeID: CloudyWindowStore.personalScope,
                now: baseline.addingTimeInterval(Double(offset) * day))[0]
            cats.append(entry.selection.profileID!)
        }
        try check(Set(cats.prefix(3)).count == 3 && Set(cats.suffix(3)).count == 3, "three cats all get turns")
        let scope = CloudyWindowStore.profilePrefix + "cat-0"
        let first = try f.store.timeline(scopeID: scope, now: baseline)[0]
        try check(f.metadata[first.photo.photoID]?.profileIDs.contains("cat-0") == true, "pinned cat is respected")
        let cutoff = baseline.addingTimeInterval(30)
        let frozen = try f.store.timeline(scopeID: scope, now: baseline.addingTimeInterval(day),
                                         allowsSelection: false, selectionValidUntil: cutoff)
        try check(frozen[0].selection.id == first.selection.id && frozen[0].isCloudy, "expiry preserves photo and cloud")
        f.metadata[first.photo.photoID]?.profileIDs = ["cat-1"]
        try f.store.synchronize(metadata: f.metadata, profiles: f.profiles, now: baseline.addingTimeInterval(day))
        try check(f.store.imageURL(filename: first.photo.clear.small, scopeID: scope) == nil, "removed cat membership blocks cached image")
        try check(f.store.timeline(scopeID: scope, now: baseline.addingTimeInterval(day), allowsSelection: false,
                                  selectionValidUntil: cutoff).isEmpty, "expired cat scope does not keep a reassigned photo")

        var uneven = try Fixture(count: 5, cats: 2)
        defer { uneven.cleanup() }
        for key in uneven.metadata.keys { uneven.metadata[key]?.profileIDs = key == "photo-00" ? ["cat-0"] : ["cat-1"] }
        // Photos taken long ago: a new photo goes ahead of the cats' turns
        // for its day (newPhotoGoesOutTomorrow), so this checks the turns alone.
        takenLongAgo(&uneven)
        try uneven.store.synchronize(metadata: uneven.metadata, profiles: uneven.profiles, now: baseline)
        let rotation = try (0..<5).map { offset in
            try uneven.store.timeline(scopeID: CloudyWindowStore.personalScope,
                now: baseline.addingTimeInterval(Double(offset) * day))[0].selection.profileID!
        }
        // 11/22: the one-photo cat gets its turn, then sits out while its
        // only photo was shown in the last 30 days.
        try check(rotation.filter { $0 == "cat-0" }.count == 1 && rotation.contains("cat-1"),
                  "a one-photo cat gets one turn, then waits out the 30 days")
    }

    /// 11/22: three cats with 1, 4 and 10 photos given to them, and many
    /// photos given to no cat. Those take turns as one group, and no photo
    /// comes back within 30 days.
    private static func manyCatsWithUnassignedPhotos() throws {
        var f = try Fixture(count: 32, cats: 3)
        defer { f.cleanup() }
        takenLongAgo(&f)
        for key in f.metadata.keys {
            let index = Int(key.dropFirst(6))!
            f.metadata[key]?.profileIDs = index < 1 ? ["cat-0"] : index < 5 ? ["cat-1"] : index < 15 ? ["cat-2"] : []
        }
        try f.store.synchronize(metadata: f.metadata, profiles: f.profiles, now: baseline)
        var shown: [String] = []
        var cats: [String?] = []
        for offset in 0..<30 {
            let entry = try f.store.timeline(scopeID: CloudyWindowStore.personalScope,
                now: baseline.addingTimeInterval(Double(offset) * day))[0]
            try check(entry.selection.kind == .ordinary, "many cats: ordinary days")
            shown.append(entry.selection.photoID)
            cats.append(entry.selection.profileID)
        }
        try check(Set(shown).count == shown.count, "many cats: no photo twice within 30 days")
        let unassigned = shown.filter { f.metadata[$0]?.profileIDs.isEmpty == true }
        try check(unassigned.count >= 10 && cats.filter { $0 == nil }.count == unassigned.count,
                  "many cats: photos given to no cat take turns")
        try check(["cat-0", "cat-1", "cat-2"].allSatisfy { id in cats.contains(id) }, "many cats: every cat gets a turn")
        try check(cats.filter { $0 == "cat-0" }.count == 1, "many cats: a one-photo cat waits out the 30 days")
    }

    private static func permissionAndPublicBoundary() throws {
        let f = try Fixture(count: 3)
        defer { f.cleanup() }
        let selected = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: baseline)[0]
        let publicStore = CloudyWindowStore(containerURL: f.directory, internalPresentation: false)
        try check(!publicStore.configuration().enabled && publicStore.profiles().isEmpty, "public build hides stored experiment state")
        try check(publicStore.timeline(scopeID: CloudyWindowStore.personalScope, now: baseline).isEmpty, "public build never presents cloudy photo")
        try check(publicStore.imageURL(filename: selected.photo.clear.small) == nil, "public build cannot read cloudy output")
        try f.authority.suspend(now: baseline)
        try check(f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: baseline).isEmpty, "permission suspension blocks timeline")
        try check(f.store.imageURL(filename: selected.photo.clear.small) == nil, "permission suspension blocks images immediately")
        try check(!f.store.reveal(selectionID: selected.selection.id, scopeID: selected.selection.scopeID,
            photoID: selected.photo.photoID, now: baseline), "permission suspension blocks stale tap")
    }

    private static func preparationRaces() throws {
        let f = try Fixture(count: 2)
        defer { f.cleanup() }
        let plan = try f.store.preparation(now: baseline)!
        try f.store.configure(strength: .light)
        do {
            try f.store.publish(f.prepared[0], files: [:], authorityRevision: f.revision,
                                configurationRevision: plan.configuration.revision, now: baseline)
            throw Failure.failed("stale strength publication accepted")
        } catch PersonalRediscoveryStore.Error.staleRevision { }
        try check(f.store.imageURL(filename: "../state.json") == nil, "cache traversal rejected")
        try check(f.store.imageURL(filename: "cloudy-unknown.jpg") == nil, "unpublished image rejected")
    }

    private static func preparationRetainsPlannedAndFrozenPhotos() throws {
        let f = try Fixture(count: 60, cats: 3)
        defer { f.cleanup() }
        let scope = CloudyWindowStore.profilePrefix + "cat-0"
        let cutoff = baseline.addingTimeInterval(30)
        let first = try f.store.timeline(scopeID: scope, now: baseline)[0]
        let later = baseline.addingTimeInterval(3 * day)
        let stopped = try f.store.timeline(scopeID: scope, now: later, allowsSelection: false, selectionValidUntil: cutoff)
        try check(stopped.first?.selection.id == first.selection.id, "shortened expiry freezes the allowed previous day")
        try check(f.store.reveal(selectionID: first.selection.id, scopeID: scope, photoID: first.photo.photoID,
            now: later, allowsSelection: false, selectionValidUntil: cutoff), "shortened expiry still permits revealing the frozen photo")
        try check(f.authority.snapshot(now: later)!.retirableCandidateCount > 0,
                  "cloudy usage allows the base cache to refill")
        for photo in f.prepared.prefix(32) { f.store.noteViewed(photoID: photo.photoID) }
        let plan = try f.store.preparation(now: later)!
        try check(plan.candidates.contains { candidate in
            !plan.existing.contains { $0.photoID == candidate.item.localIdentifier }
        }, "preparation brings in unseen candidates beyond the old 32")
        let image = try Data(contentsOf: f.directory.appendingPathComponent("widget-cache")
            .appendingPathComponent(f.candidates[0].item.cacheFilename))
        for candidate in plan.candidates where !plan.existing.contains(where: { $0.photoID == candidate.item.localIdentifier }) {
            let photo = f.prepared.first { $0.photoID == candidate.item.localIdentifier }!
            try f.store.publish(photo, files: Dictionary(uniqueKeysWithValues: photo.filenames.map { ($0, image) }),
                authorityRevision: plan.authorityRevision, configurationRevision: plan.configuration.revision,
                protectedPhotoIDs: plan.protectedPhotoIDs, now: later)
        }
        let after = try f.store.preparation(now: later)!
        try check(plan.candidates.allSatisfy { candidate in
            after.existing.contains { $0.photoID == candidate.item.localIdentifier }
        }, "new publications keep earlier skipped candidates")
        let frozen = try f.store.timeline(scopeID: scope, now: later, allowsSelection: false, selectionValidUntil: cutoff)
        try check(frozen.first?.selection.id == first.selection.id, "refill keeps the frozen last issued photograph")
    }

    /// Writes the saved state as an older build or a damaged disk left it.
    private static func writeState(_ f: Fixture, _ text: String) throws {
        let url = f.directory.appendingPathComponent("cloudy-window.v1/state.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// 11/20 (1, 2): a state that cannot be read is neither "not cloudy"
    /// (the clear legacy photo) nor "this cat was removed". The app's next
    /// save starts a damaged file again.
    private static func readFailureFailsClosed() throws {
        let f = try Fixture(count: 6, cats: 2)
        defer { f.cleanup() }
        let cat = CloudyWindowStore.profilePrefix + "cat-0"
        try check(f.store.sourceStatus(CloudyWindowStore.personalScope) == .cloudy && f.store.sourceStatus(cat) == .cloudy,
                  "a read state: both windows are cloudy")
        try check(f.store.sourceStatus(CloudyWindowStore.profilePrefix + "gone") == .notCloudy,
                  "a cat missing from a read state is the only removed window")
        let fresh = try Fixture(count: 1, installed: false)
        defer { fresh.cleanup() }
        try FileManager.default.removeItem(at: fresh.directory.appendingPathComponent("cloudy-window.v1/state.json"))
        try check(fresh.store.sourceStatus(cat) == .notReady
                  && fresh.store.sourceStatus(CloudyWindowStore.personalScope) == .cloudy,
                  "nothing saved yet: a cat's window waits, it is not removed")
        try writeState(f, "{ not json")
        try check(f.store.sourceStatus(CloudyWindowStore.personalScope) == .unreadable,
                  "a damaged state: the personal window fails closed")
        try check(f.store.sourceStatus(cat) == .unreadable, "a damaged state: a cat's window is not called removed")
        do {
            _ = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: baseline)
            throw Failure.failed("a damaged state produced a timeline")
        } catch PersonalRediscoveryStore.Error.corrupted { }
        try f.store.synchronize(metadata: f.metadata, profiles: f.profiles, now: baseline)
        try check(f.store.sourceStatus(cat) == .cloudy, "the app's next save starts a damaged state again")
        let publicStore = CloudyWindowStore(containerURL: f.directory, internalPresentation: false)
        try check(publicStore.sourceStatus(CloudyWindowStore.personalScope) == .notCloudy,
                  "outside Version1 the personal photos keep their own Widget")
    }

    /// 11/20 (1): an older build's saved 「くもりのまど」 switch turned off
    /// is read as on; there is no screen to turn it off any more.
    private static func olderSwitchOffIsMigrated() throws {
        let f = try Fixture(count: 6, installed: false)
        defer { f.cleanup() }
        try writeState(f, #"{"version":1,"configuration":{"enabled":false,"strength":"light","revision":"old"},"profiles":{},"metadata":{},"photos":[],"selections":[],"seenPhotoIDs":[]}"#)
        try check(f.store.configuration().enabled && f.store.sourceStatus(CloudyWindowStore.personalScope) == .cloudy,
                  "a saved switch-off reads as cloudy")
        try f.store.synchronize(metadata: f.metadata, profiles: f.profiles, now: baseline)
        try f.store.synchronizeInstalledSources([CloudyWindowStore.personalScope])
        try check(f.store.preparation(now: baseline) != nil, "the personal window is prepared again")
    }

    /// 11/20 (3): a photo taken today goes out tomorrow, also when today's
    /// photo is first chosen late in the day (a new Widget, a missed reload).
    private static func takenTodayWaitsWhenChosenLate() throws {
        let d = baseline  // 23:59 JST
        var f = try Fixture(count: 40)
        defer { f.cleanup() }
        takenLongAgo(&f)
        f.metadata["photo-05"]?.creationDate = d.addingTimeInterval(-3_600)
        try f.store.synchronize(metadata: f.metadata, profiles: f.profiles, now: d)
        let entries = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: d)
        try check(entries[0].photo.photoID != "photo-05" && entries[0].selection.kind != .new,
                  "today's photo chosen at 23:59 is not a photo taken today")
        try check(entries[1].photo.photoID == "photo-05" && entries[1].selection.kind == .new,
                  "the photo taken today is tomorrow's new photo")
        try check(!CloudyWindowStore.isNewPhoto(takenAt: d.addingTimeInterval(-3_600), previouslyShown: false,
                                                at: CloudyWindowStore.calendar.startOfDay(for: d))
                  && CloudyWindowStore.isNewPhoto(takenAt: d.addingTimeInterval(-3_600), previouslyShown: false,
                                                  at: CloudyWindowStore.nextDay(after: d)),
                  "new from the next day on")

        var few = try Fixture(count: 6)
        defer { few.cleanup() }
        for key in few.metadata.keys { few.metadata[key]?.creationDate = d.addingTimeInterval(-1_800) }
        few.metadata["photo-03"]?.creationDate = d.addingTimeInterval(-3 * day)
        try few.store.synchronize(metadata: few.metadata, profiles: few.profiles, now: d)
        let today = try few.store.timeline(scopeID: CloudyWindowStore.personalScope, now: d)[0]
        try check(today.photo.photoID == "photo-03", "few photos: today's is the one taken before today")
    }

    /// 11/20 (3): opening a photo in the app does not take away its
    /// new-photo day; being shown in the Widget does.
    private static func appViewKeepsTheNewDay() throws {
        let d = baseline
        var f = try Fixture(count: 40)
        defer { f.cleanup() }
        takenLongAgo(&f)
        f.metadata["photo-05"]?.creationDate = d.addingTimeInterval(-3_600)
        try f.store.synchronize(metadata: f.metadata, profiles: f.profiles, now: d)
        f.store.noteViewed(photoID: "photo-05")
        let entries = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: d)
        try check(entries[1].photo.photoID == "photo-05" && entries[1].selection.kind == .new,
                  "a photo opened in the app right after shooting still gets its new day")
        let shown = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: entries[1].date.addingTimeInterval(1))
        try check(shown[0].photo.photoID == "photo-05", "it is shown the next day")
        let later = try f.store.timeline(scopeID: CloudyWindowStore.personalScope,
                                         now: entries[1].date.addingTimeInterval(4 * day))
        try check(later.allSatisfy { $0.photo.photoID != "photo-05" || $0.selection.kind != .new },
                  "once shown in the Widget it is no longer new")
    }

    /// 11/20 (5): today's photo edited in Photos keeps drawing its last
    /// prepared image, cloudy as it was; never an empty or later-only plan;
    /// it is not chosen again for another day.
    /// 11/21: a time-zone change neither chooses today's photo again nor
    /// clouds it again. Flying west (the local date goes back), the photo
    /// already given stays until the local day passes it.
    private static func timeZoneChangeKeepsTheDay() throws {
        let tokyo = TimeZone(secondsFromGMT: 9 * 3_600)!
        defer { CloudyWindowStore.timeZoneOverride = tokyo }
        let iso = ISO8601DateFormatter()
        let scope = CloudyWindowStore.personalScope
        let morning = iso.date(from: "2026-10-25T01:00:00Z")!   // 10:00 the 25th in Tokyo
        for (arrival, sameDay) in [(iso.date(from: "2026-10-25T13:00:00Z")!, true),   // 03:00 the 25th in Honolulu
                                   (iso.date(from: "2026-10-25T02:00:00Z")!, false)] { // 16:00 the 24th in Honolulu
            CloudyWindowStore.timeZoneOverride = tokyo
            let f = try Fixture(count: 6)
            defer { f.cleanup() }
            let first = try f.store.timeline(scopeID: scope, now: morning)[0]
            try check(f.store.reveal(selectionID: first.selection.id, scopeID: scope,
                                     photoID: first.photo.photoID, now: morning), "cleared in Tokyo")
            CloudyWindowStore.timeZoneOverride = TimeZone(identifier: "Pacific/Honolulu")!
            let after = try f.store.timeline(scopeID: scope, now: arrival)[0]
            try check(after.photo.photoID == first.photo.photoID && !after.isCloudy,
                      sameDay ? "the same date keeps its cleared photo" : "flying west keeps the cleared photo")
            try check(after.selection.day == CloudyWindowStore.calendar.startOfDay(for: arrival),
                      "the kept photo is today's in the new zone")
            let again = try f.store.timeline(scopeID: scope, now: arrival.addingTimeInterval(3_600))[0]
            try check(again.selection.id == after.selection.id, "nothing moves again in the same zone")
            let nextDay = CloudyWindowStore.nextDay(after: arrival).addingTimeInterval(3_600)
            let next = try f.store.timeline(scopeID: scope, now: nextDay)[0]
            try check(next.selection.id != after.selection.id && next.isCloudy, "the next local day brings its own photo")
        }
    }

    private static func editedPhotoKeepsItsDay() throws {
        let f = try Fixture(count: 6)
        defer { f.cleanup() }
        let shown = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: baseline)
        let photoID = shown[0].photo.photoID
        var dates = Dictionary(uniqueKeysWithValues: f.candidates.map { ($0.item.localIdentifier, baseline) })
        dates[photoID] = baseline.addingTimeInterval(30)
        _ = try f.authority.updateEligibility(photoIDs: Set(dates.keys), scopeIdentifier: "fixture",
            isAuthorized: true, now: baseline.addingTimeInterval(30), photoModificationDates: dates)
        let now = baseline.addingTimeInterval(40)
        let after = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: now)
        try check(!after.isEmpty && after[0].date <= now && after[0].photo.photoID == photoID
                  && after[0].selection.id == shown[0].selection.id && after[0].isCloudy,
                  "the edited photo stays today's, cloudy, from now")
        try check(f.store.imageURL(filename: after[0].photo.cloudy.small) != nil,
                  "its last prepared image is still drawn")
        try check(after.count < 2 || after[1].photo.photoID != photoID, "it is not chosen for tomorrow")
        try check(f.store.reveal(selectionID: after[0].selection.id, scopeID: CloudyWindowStore.personalScope,
                                 photoID: photoID, now: now), "its tag still clears it")
    }

    /// 11/20 (4): a tag tapped on an entry whose selection was replaced
    /// clears today's photo, which the reload then shows.
    private static func replacedSelectionTapClearsToday() throws {
        var f = try Fixture(count: 40)
        defer { f.cleanup() }
        takenLongAgo(&f)
        try f.store.synchronize(metadata: f.metadata, profiles: f.profiles, now: baseline)
        let issued = try f.store.timelineReportingReplacement(scopeID: CloudyWindowStore.personalScope, now: baseline)
        try check(!issued.replacedSelection, "a first timeline replaces nothing")
        let promised = issued.entries[1].selection
        f.metadata["photo-06"]?.creationDate = baseline.addingTimeInterval(-3_600)
        try f.store.synchronize(metadata: f.metadata, profiles: f.profiles, now: baseline.addingTimeInterval(5))
        // Another Widget (or a snapshot) asks: tomorrow is chosen again.
        let other = try f.store.timelineReportingReplacement(scopeID: CloudyWindowStore.personalScope,
                                                             now: baseline.addingTimeInterval(10))
        try check(other.replacedSelection && other.entries[1].selection.id != promised.id,
                  "replacing a promised selection is reported, so every timeline reloads")
        let again = try f.store.timelineReportingReplacement(scopeID: CloudyWindowStore.personalScope,
                                                             now: baseline.addingTimeInterval(20))
        try check(!again.replacedSelection, "the reload does not replace again")
        // Midnight: the first Widget still shows its old entry for tomorrow.
        let midnight = promised.day.addingTimeInterval(60)
        try check(f.store.reveal(selectionID: promised.id, scopeID: promised.scopeID, photoID: promised.photoID,
                                 now: midnight), "the old entry's tap clears today's photo")
        let now = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: midnight.addingTimeInterval(1))
        try check(now[0].selection.id == other.entries[1].selection.id && !now[0].isCloudy,
                  "the reload shows today's photo cleared")
    }

    /// 11/20 (9): one "no Widget" answer keeps the prepared images; the same
    /// answer an hour later releases them; a Widget seen again cancels it.
    private static func oneEmptyAnswerKeepsImages() throws {
        let f = try Fixture(count: 6)
        defer { f.cleanup() }
        let shown = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: baseline)[0]
        try f.store.synchronizeInstalledSources([], now: baseline)
        try check(f.store.imageURL(filename: shown.photo.cloudy.small) != nil, "one empty answer keeps the images")
        try check(f.store.preparation(now: baseline) != nil, "and preparation goes on")
        try f.store.synchronizeInstalledSources([CloudyWindowStore.personalScope], now: baseline.addingTimeInterval(60))
        try f.store.synchronizeInstalledSources([], now: baseline.addingTimeInterval(CloudyWindowStore.uninstallConfirmationInterval))
        try check(f.store.imageURL(filename: shown.photo.cloudy.small) != nil, "a Widget seen again starts the wait over")
        try f.store.synchronizeInstalledSources([], now: baseline.addingTimeInterval(2 * CloudyWindowStore.uninstallConfirmationInterval))
        try check(f.store.imageURL(filename: shown.photo.cloudy.small) == nil, "a confirmed empty answer releases them")
    }

    /// 11/20 (9): Photos access taken away: the derived images go at once,
    /// the day's selection stays.
    private static func releasingImagesKeepsSelections() throws {
        let f = try Fixture(count: 6)
        defer { f.cleanup() }
        let shown = try f.store.timeline(scopeID: CloudyWindowStore.personalScope, now: baseline)[0]
        try f.store.releasePreparedImages()
        let images = f.directory.appendingPathComponent("cloudy-window.v1/images")
        try check((try FileManager.default.contentsOfDirectory(atPath: images.path)).isEmpty, "no derived image is left")
        try check(f.store.preparation(now: baseline)?.protectedPhotoIDs.contains(shown.photo.photoID) == true,
                  "the day's photo is prepared again when allowed")
    }
}
