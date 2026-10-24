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

    init(count: Int, cats: Int = 0, burstPair: Bool = false) throws {
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
        try store.configure(enabled: true, strength: .light)
        try store.synchronize(metadata: metadata, profiles: profiles, now: baseline)
        let configuration = store.configuration()
        prepared = candidates.enumerated().map { index, candidate in
            func files(_ kind: String) -> WidgetCacheFilenames {
                .init(small: "cloudy-\(kind)-\(index)-small.jpg", medium: "cloudy-\(kind)-\(index)-medium.jpg",
                      large: "cloudy-\(kind)-\(index)-large.jpg")
            }
            return .init(source: candidate.item, clear: files("clear"), cloudy: files("blur"),
                         strength: .light, visualHash: UInt64(index), preparedAt: baseline)
        }
        for photo in prepared.prefix(CloudyWindowStore.maximumPhotoCount) {
            try store.publish(photo, files: Dictionary(uniqueKeysWithValues: photo.filenames.map { ($0, image) }),
                              authorityRevision: revision, configurationRevision: configuration.revision, now: baseline)
        }
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

@main
private enum CloudyWindowVerifier {
    static func main() throws {
        try dailyReveal()
        try rotationAndSmallPools()
        try catScopesAndExpiry()
        try permissionAndPublicBoundary()
        try preparationRaces()
        try preparationRetainsPlannedAndFrozenPhotos()
        print("Cloudy window: daily reveal, stale actions, restart, rotation, cats, permission, public mode and publication checks passed")
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
        try f.store.configure(enabled: false, strength: .light)
        try check(f.store.timeline(scopeID: first.scopeID, now: tomorrow).isEmpty, "off produces no cloudy timeline")
        try f.store.configure(enabled: true, strength: .light)
        try check(f.store.timeline(scopeID: first.scopeID, now: tomorrow)[0].selection.id == next[0].selection.id,
                  "on/off does not reroll today's photograph")
    }

    private static func rotationAndSmallPools() throws {
        let f = try Fixture(count: 32)
        defer { f.cleanup() }
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
        try uneven.store.synchronize(metadata: uneven.metadata, profiles: uneven.profiles, now: baseline)
        let rotation = try (0..<5).map { offset in
            try uneven.store.timeline(scopeID: CloudyWindowStore.personalScope,
                now: baseline.addingTimeInterval(Double(offset) * day))[0].selection.profileID!
        }
        try check(zip(rotation, rotation.dropFirst()).allSatisfy { $0.0 != $0.1 }, "one-photo cat still alternates with a larger cat pool")
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
        try f.store.configure(enabled: true, strength: .strong)
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
}
