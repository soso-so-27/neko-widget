import Foundation
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

private enum CheckFailure: Error { case failed(String) }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw CheckFailure.failed(message) }
}

private let utc = TimeZone(secondsFromGMT: 0)!
private let baseline = ISO8601DateFormatter().date(from: "2026-09-14T10:00:00Z")!
private let interval: TimeInterval = 24 * 60 * 60

private func midnightAfter(_ date: Date, timeZone: TimeZone = utc) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
}

private struct Fixture {
    let directory: URL
    let store: PersonalRediscoveryStore
    let candidates: [PersonalRediscoveryCandidate]
    let revision: String

    init(_ count: Int, at date: Date = baseline, legacyOnly: Bool = false, timeZone: TimeZone = utc) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rediscovery-check-\(UUID().uuidString)")
        store = PersonalRediscoveryStore(containerURL: directory)
        candidates = (0..<count).map { index in
            let files = WidgetCacheFilenames(small: "photo-\(index)-small.jpg", medium: "photo-\(index)-medium.jpg", large: "photo-\(index)-large.jpg")
            return PersonalRediscoveryCandidate(item: WidgetManifestItem(
                localIdentifier: "photo-\(index)", cacheFilename: files.small,
                cacheFilenames: files, scheduledDate: date,
                sourceModificationDate: date
            ), creationDate: date.addingTimeInterval(-Double(index) * 3_600), preparedAt: date)
        }
        try Self.writeImages(candidates, directory: directory)
        if legacyOnly {
            revision = ""
            let manifest = WidgetManifest(items: candidates.map(\.item), generatedAt: date)
            try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("widget-manifest.json"), options: .atomic)
        } else {
            revision = try store.updateEligibility(photoIDs: Set(candidates.map { $0.item.localIdentifier }), scopeIdentifier: "fixture", isAuthorized: true, now: date, timeZone: timeZone)
            if count > 0 { try store.publish(candidates: candidates, expectedRevision: revision, now: date, timeZone: timeZone) }
        }
    }

    static func writeImages(_ candidates: [PersonalRediscoveryCandidate], directory: URL) throws {
        let cache = directory.appendingPathComponent("widget-cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let framedJPEG: Data
#if canImport(ImageIO)
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let bytes = NSMutableData()
        let destination = CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw CheckFailure.failed("JPEG fixture generation") }
        framedJPEG = bytes as Data
#else
        // Linux-only state-machine runs cannot test ImageIO. macOS checks above
        // execute the same complete-decode gate as production before a grant.
        framedJPEG = Data([0xff, 0xd8, 0xff, 0xe0, 0, 2, 0xff, 0xd9])
#endif
        for filename in candidates.flatMap({ $0.item.allCacheFilenames }) {
            try framedJPEG.write(to: cache.appendingPathComponent(filename), options: .atomic)
        }
    }

    func token(at date: Date = baseline, timeZone: TimeZone = utc) throws -> PersonalRediscoveryEntryToken {
        guard let entry = try store.currentEntry(now: date, timeZone: timeZone),
              case let .available(token) = entry.action else { throw CheckFailure.failed("missing available token") }
        return token
    }

    @discardableResult
    func bootstrap(
        candidates seeds: [PersonalRediscoveryCandidate]? = nil,
        photoIDs: Set<String>? = nil, isAuthorized: Bool = true,
        modificationDate: Date = baseline, interval: TimeInterval = 20 * 60
    ) throws -> String {
        try store.updateEligibility(
            photoIDs: photoIDs ?? Set(candidates.map { $0.item.localIdentifier }),
            scopeIdentifier: "fixture", isAuthorized: isAuthorized, now: baseline,
            photoModificationDates: Dictionary(uniqueKeysWithValues: candidates.map { ($0.item.localIdentifier, modificationDate) }),
            bootstrapCandidates: seeds ?? candidates, interval: interval, timeZone: utc)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

@main
private enum PersonalRediscoveryVerifier {
    static func main() throws {
        if CommandLine.arguments.count == 6, CommandLine.arguments[1] == "--turn" {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2])
            let token = try JSONDecoder().decode(PersonalRediscoveryEntryToken.self, from: Data(base64Encoded: CommandLine.arguments[3])!)
            let date = Date(timeIntervalSince1970: Double(CommandLine.arguments[4])!)
            let outcome = try PersonalRediscoveryStore(containerURL: directory).perform(token: token,
                operationID: CommandLine.arguments[5], operationCreatedAt: date, now: date, timeZone: utc)
            if case .committed = outcome { print("committed") } else { print("existing") }
            return
        }
        try poolAndTimeline()
        try dailyAndHistory()
        try dailyPhotoAndCadenceMigration()
        try invalidCandidateDoesNotConsume()
        try authorityAndPublication()
        try upgradeBootstrap()
        try bootstrapRejections()
        try membershipSelectionBoundary()
        try concurrentProcesses()
        print("Personal rediscovery passed: calendar-day photos, same-day hold after turning/refill/restart, legacy cadence migration, shared slots, bounded pool, cycles, leases, failures, quota, midnight/DST, stale requests, 48h history, source and authority isolation, atomic legacy bootstrap, cross-process race.")
    }

    private static func membershipSelectionBoundary() throws {
        let fixture = try Fixture(5)
        defer { fixture.cleanup() }
        let cutoff = baseline.addingTimeInterval(3_600)
        let timeline = try fixture.store.issueTimeline(now: baseline, variant: .small,
            timeZone: utc, selectionValidUntil: cutoff)!
        let original = timeline.entries[0].item!
        try require(timeline.entries.count == 2
            && timeline.entries[1].date == cutoff
            && timeline.entries[1].item == original
            && timeline.entries[1].action == .unavailable
            && timeline.reloadDate <= cutoff,
            "expiry must keep the known photo and stop the already issued control")
        guard case let .available(token) = timeline.entries[0].action else {
            throw CheckFailure.failed("missing pre-expiry control")
        }
        let denied = try fixture.store.perform(token: token, operationID: UUID().uuidString,
            operationCreatedAt: baseline, now: baseline, timeZone: utc, allowsSelection: { false })
        try require(denied == .unavailable, "old Widget control bypassed expired authority")
        var authorityReads = 0
        let raced = try fixture.store.perform(token: token, operationID: UUID().uuidString,
            operationCreatedAt: baseline, now: baseline, timeZone: utc, allowsSelection: {
                authorityReads += 1
                return authorityReads == 1
            })
        let afterDenied = try fixture.store.snapshot(now: baseline)!
        try require(raced == .unavailable && authorityReads == 2
            && afterDenied.history.isEmpty && afterDenied.nextAvailableAt == nil,
            "authority change during preparation committed or consumed a turn")

        let restarted = PersonalRediscoveryStore(containerURL: fixture.directory)
        for time in [cutoff, baseline.addingTimeInterval(35 * 86_400)] {
            let frozen = try restarted.issueTimeline(now: time, variant: .small, timeZone: utc,
                allowsSelection: false, selectionValidUntil: cutoff)!
            try require(frozen.entries.count == 1 && frozen.entries[0].item == original
                && frozen.entries[0].action == .unavailable,
                "expired/restarted timeline advanced or lost its known photo")
        }
        let unknown = try restarted.issueTimeline(now: cutoff, variant: .small, timeZone: utc,
            allowsSelection: false)!
        try require(unknown.entries.first?.item == original,
            "missing membership information must retain the issued photo")

        let missingFile = fixture.directory.appendingPathComponent("widget-cache")
            .appendingPathComponent(original.cacheFilename(for: .small))
        try FileManager.default.removeItem(at: missingFile)
        let missing = try restarted.issueTimeline(now: cutoff, variant: .small, timeZone: utc,
            allowsSelection: false, selectionValidUntil: cutoff)!
        try require(missing.entries.first?.item == nil,
            "missing held cache selected a different photo")
        try Fixture.writeImages(fixture.candidates, directory: fixture.directory)
        _ = try restarted.updateEligibility(
            photoIDs: Set(fixture.candidates.map { $0.item.localIdentifier }).subtracting([original.localIdentifier]),
            scopeIdentifier: "excluded-held-photo", isAuthorized: true, now: cutoff, timeZone: utc)
        try require(try restarted.issueTimeline(now: cutoff, variant: .small, timeZone: utc,
            allowsSelection: false, selectionValidUntil: cutoff)?.entries.isEmpty == true,
            "paused membership bypassed exclusion or selected a replacement")
        try restarted.invalidate(now: cutoff)
        try require(try restarted.issueTimeline(now: cutoff, variant: .small,
            allowsSelection: false)?.entries.isEmpty == true, "paused membership bypassed photo revocation")

        let future = try Fixture(5)
        defer { future.cleanup() }
        let tomorrow = midnightAfter(baseline)
        let laterCutoff = tomorrow.addingTimeInterval(3_600)
        let issued = try future.store.issueTimeline(now: baseline, variant: .small,
            timeZone: utc, selectionValidUntil: laterCutoff)!
        try require(issued.entries.count == 2 && issued.entries[1].date == laterCutoff
            && issued.entries[1].item == issued.entries[0].item
            && issued.entries[1].action == .unavailable && issued.reloadDate == tomorrow,
            "future expiry must retain the same photo; only a timely reload may select tomorrow's photo")
        let heldFuture = try future.store.issueTimeline(now: laterCutoff, variant: .small,
            timeZone: utc, allowsSelection: false, selectionValidUntil: laterCutoff)!
        try require(heldFuture.entries.first?.item == issued.entries.last?.item,
            "freeze ignored the latest photo already issued before expiry")

        let previouslyQueued = try Fixture(5)
        defer { previouslyQueued.cleanup() }
        let oldPlan = try previouslyQueued.store.issueTimeline(now: baseline, variant: .small, timeZone: utc)!
        for time in [tomorrow, tomorrow.addingTimeInterval(35 * 86_400)] {
            let bounded = try previouslyQueued.store.issueTimeline(now: time, variant: .small,
                timeZone: utc, allowsSelection: false, selectionValidUntil: tomorrow)!
            try require(bounded.entries.first?.item == oldPlan.entries.first?.item,
                "old future entry at expiry displaced the last authorized photo")
        }

        let manual = try Fixture(5)
        defer { manual.cleanup() }
        let manualToken = try manual.token()
        guard case let .committed(grant) = try manual.store.perform(token: manualToken,
            operationID: UUID().uuidString, operationCreatedAt: baseline,
            now: baseline, timeZone: utc) else { throw CheckFailure.failed("manual setup failed") }
        // No timeline was issued for this grant before the deadline. Its first
        // paused display must journal the original commit date, not the reload.
        for time in [cutoff, cutoff.addingTimeInterval(8 * 86_400), cutoff.addingTimeInterval(35 * 86_400)] {
            let paused = try PersonalRediscoveryStore(containerURL: manual.directory)
                .issueTimeline(now: time, variant: .small, timeZone: utc,
                    allowsSelection: false, selectionValidUntil: cutoff)!
            try require(paused.entries.first?.item?.localIdentifier == grant.photoID,
                "first paused reload lost an unissued manual grant after its history expired")
        }

        let unseen = try Fixture(3)
        defer { unseen.cleanup() }
        try require(try unseen.store.issueTimeline(now: baseline, variant: .small,
            allowsSelection: false)?.entries.isEmpty == true,
            "unknown membership selected a photo without an issued journal")
        try require(try unseen.store.issueTimeline(now: baseline, variant: .small,
            sourceID: "official-default", allowsSelection: false) == nil,
            "personal membership gate intercepted an official source")
    }

    private static func upgradeBootstrap() throws {
        let fixture = try Fixture(20, legacyOnly: true)
        defer { fixture.cleanup() }
        try require(try fixture.store.snapshot(now: baseline) == nil, "legacy fixture already created canonical state")
        let manifest = try JSONDecoder().decode(WidgetManifest.self,
            from: Data(contentsOf: fixture.directory.appendingPathComponent("widget-manifest.json")))
        let seeds = manifest.items.map { PersonalRediscoveryCandidate(item: $0, preparedAt: baseline) }
        let revision = try fixture.bootstrap(candidates: seeds, interval: 30 * 60)
        let first = try fixture.store.issueTimeline(now: baseline, variant: .small, timeZone: utc)!
        try require(first.entries.count == 2 && first.entries.allSatisfy { $0.item != nil }, "authority committed before legacy photos and plan")
        try require(first.entries[1].date == midnightAfter(baseline), "bootstrap did not schedule tomorrow's photo")
        let saved = try fixture.store.snapshot(now: baseline)!
        try require(saved.candidates.count == 20, "bootstrap lost prepared legacy candidates")
        do {
            try fixture.store.publish(candidates: [], expectedRevision: revision, now: baseline.addingTimeInterval(30)) { _ in
                throw CheckFailure.failed("initial async publication failed")
            }
            throw CheckFailure.failed("failed initial publication reported success")
        } catch CheckFailure.failed("initial async publication failed") {}
        try require(try fixture.store.snapshot(now: baseline) == saved, "failed asynchronous build replaced bootstrap state")
        let resumed = PersonalRediscoveryStore(containerURL: fixture.directory)
        for variant in WidgetImageVariant.allCases {
            let timeline = try resumed.issueTimeline(now: baseline, variant: variant, timeZone: utc)!
            try require(timeline.entries.map { $0.item?.localIdentifier } == first.entries.map { $0.item?.localIdentifier }, "upgrade restart or image size lost bootstrapped photo")
        }
        // Repeated authority refreshes are not a refill and must not reschedule
        // the existing plan, even when an alternate bootstrap is supplied.
        try fixture.bootstrap(candidates: Array(seeds.prefix(1)), interval: 10 * 60)
        try require(try fixture.store.snapshot(now: baseline)?.candidates == saved.candidates, "bootstrap replaced existing pool")
        let repeated = try fixture.store.issueTimeline(now: baseline, variant: .small, timeZone: utc)!
        try require(repeated.entries.map(\.slotID) == first.entries.map(\.slotID) && repeated.entries[1].date == first.entries[1].date, "bootstrap reset existing plan")

        let capped = try Fixture(21, legacyOnly: true)
        defer { capped.cleanup() }
        try capped.bootstrap()
        try require(try capped.store.snapshot(now: baseline)?.candidates.count == 20, "bootstrap exceeded legacy twenty-item bound")

        let used = try Fixture(3)
        defer { used.cleanup() }
        let token = try used.token()
        let operation = UUID().uuidString
        guard case let .committed(grant) = try used.store.perform(token: token,
            operationID: operation, operationCreatedAt: baseline, now: baseline, timeZone: utc) else {
            throw CheckFailure.failed("bootstrap quota fixture did not commit")
        }
        let before = try used.store.snapshot(now: baseline)!
        try used.store.publish(candidates: [], expectedRevision: used.revision, now: baseline,
            discardCandidateIDs: Set(used.candidates.map { $0.item.localIdentifier }))
        try require(try used.store.snapshot(now: baseline)?.candidates.isEmpty == true, "quota fixture did not empty pool")
        try used.bootstrap()
        let after = try used.store.snapshot(now: baseline)!
        try require(after.candidates.count == 3 && after.history == before.history
            && after.nextAvailableAt == before.nextAvailableAt && !after.canTurn, "bootstrap reset daily usage or history")
        guard case let .existing(replayed) = try used.store.perform(token: token,
            operationID: operation, operationCreatedAt: baseline, now: baseline, timeZone: utc) else {
            throw CheckFailure.failed("bootstrap lost committed operation")
        }
        try require(replayed.id == grant.id, "bootstrap replay chose a new photo")
    }

    private static func bootstrapRejections() throws {
        let authority = try Fixture(3, legacyOnly: true)
        defer { authority.cleanup() }
        try authority.bootstrap(isAuthorized: false)
        try require(try authority.store.snapshot(now: baseline)?.candidates.isEmpty == true, "unauthorized legacy cache was adopted")
        let allowed = Set(authority.candidates.dropFirst().map { $0.item.localIdentifier })
        try authority.bootstrap(photoIDs: allowed, modificationDate: baseline.addingTimeInterval(1))
        try require(try authority.store.snapshot(now: baseline)?.candidates.isEmpty == true, "stale source revision was adopted")
        try authority.bootstrap(photoIDs: allowed)
        try require(try Set(authority.store.snapshot(now: baseline)!.candidates.map { $0.item.localIdentifier }) == allowed, "excluded legacy photo returned")

        for variant in WidgetImageVariant.allCases {
            let missing = try Fixture(1, legacyOnly: true)
            defer { missing.cleanup() }
            let url = missing.directory.appendingPathComponent("widget-cache")
                .appendingPathComponent(missing.candidates[0].item.cacheFilename(for: variant))
            try FileManager.default.removeItem(at: url)
            try missing.bootstrap()
            try require(try missing.store.snapshot(now: baseline)?.candidates.isEmpty == true, "missing \(variant) image was adopted")
            try require(try missing.store.issueTimeline(now: baseline, variant: variant)?.entries.isEmpty == true, "invalid bootstrap created a photo slot")
        }
        let invalid = try Fixture(1, legacyOnly: true)
        defer { invalid.cleanup() }
        var seed = invalid.candidates[0]
        seed.item.cacheFilenames = nil
        try invalid.bootstrap(candidates: [seed])
        try require(try invalid.store.snapshot(now: baseline)?.candidates.isEmpty == true, "single-variant legacy item was adopted")
        let imageURL = invalid.directory.appendingPathComponent("widget-cache")
            .appendingPathComponent(invalid.candidates[0].item.cacheFilename(for: .large))
#if canImport(ImageIO)
        // A plausible JPEG header and footer must not bypass complete decode.
        try Data([0xff, 0xd8, 0xff, 0xe0, 0, 2, 0xff, 0xd9]).write(to: imageURL)
#else
        try Data([0, 0, 0, 0]).write(to: imageURL)
#endif
        try invalid.bootstrap()
        try require(try invalid.store.snapshot(now: baseline)?.candidates.isEmpty == true, "corrupt JPEG was adopted")
        for badInterval in [59.0, 86_401.0, Double.infinity, Double.nan] {
            do {
                try invalid.bootstrap(interval: badInterval)
                throw CheckFailure.failed("invalid bootstrap interval accepted")
            } catch PersonalRediscoveryStore.Error.invalidCandidate {}
        }
        let stateURL = invalid.directory.appendingPathComponent("personal-rediscovery.v1/state.json")
        let corrupted = Data("{ broken".utf8)
        try corrupted.write(to: stateURL)
        try Fixture.writeImages(invalid.candidates, directory: invalid.directory)
        do {
            try invalid.bootstrap()
            throw CheckFailure.failed("bootstrap silently replaced corrupt canonical state")
        } catch PersonalRediscoveryStore.Error.corrupted {}
        try require(try Data(contentsOf: stateURL) == corrupted, "bootstrap changed unreadable authority")
    }

    private static func invalidCandidateDoesNotConsume() throws {
        let fixture = try Fixture(2)
        defer { fixture.cleanup() }
        let token = try fixture.token()
        let other = fixture.candidates.first(where: { $0.item.localIdentifier != token.photoID })!
        let imageURL = fixture.directory.appendingPathComponent("widget-cache").appendingPathComponent(other.item.cacheFilename(for: .medium))
#if canImport(ImageIO)
        // Framing passes the cheap file check, but a complete decode must fail.
        try Data([0xff, 0xd8, 0xff, 0xe0, 0, 2, 0xff, 0xd9]).write(to: imageURL)
#else
        try Data([0, 0, 0, 0]).write(to: imageURL)
#endif
        let outcome = try fixture.store.perform(token: token, operationID: UUID().uuidString,
            operationCreatedAt: baseline, now: baseline, timeZone: utc)
        try require(outcome == .unavailable, "corrupt chosen JPEG consumed a turn")
        try require(try fixture.store.snapshot(now: baseline)?.nextAvailableAt == nil, "failed candidate stored daily consumption")
    }

    private static func poolAndTimeline() throws {
        for count in [0, 1, 2, 20, 21, 100] {
            let fixture = try Fixture(count)
            defer { fixture.cleanup() }
            let first = try fixture.store.issueTimeline(now: baseline, variant: .small, timeZone: utc)
            try require((first?.entries.count ?? 0) <= 2, "more than two entries")
            if count == 0 { continue }
            let medium = try fixture.store.issueTimeline(now: baseline, variant: .medium, timeZone: utc)
            try require(first?.entries.map { $0.item?.localIdentifier } == medium?.entries.map { $0.item?.localIdentifier }, "sizes consumed separate slots")
            let resumed = PersonalRediscoveryStore(containerURL: fixture.directory)
            try require(try resumed.currentEntry(now: baseline, timeZone: utc)?.item == first?.entries.first?.item, "restart changed current photo")
            let slots = try (0..<count).map { offset in
                try fixture.store.currentEntry(now: baseline.addingTimeInterval(Double(offset) * interval), timeZone: utc)?.item?.localIdentifier
            }
            try require(Set(slots.compactMap { $0 }).count == count, "first cycle repeated or lost an item at count \(count)")
            let previous = slots.last!
            let next = try fixture.store.currentEntry(now: baseline.addingTimeInterval(Double(count) * interval), timeZone: utc)?.item?.localIdentifier
            if count > 1 { try require(next != previous, "cycle boundary repeated") }
            let sameSlot = try fixture.store.currentEntry(now: baseline.addingTimeInterval(Double(count) * interval), timeZone: utc)
            try require(sameSlot?.item?.localIdentifier == next, "cycle seed changed on retry")
        }
        let fixture = try Fixture(4)
        defer { fixture.cleanup() }
        let before = try fixture.store.issueTimeline(now: baseline, variant: .small, timeZone: utc)!
        let current = before.entries[0].item!
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("widget-cache").appendingPathComponent(current.cacheFilename(for: .small)))
        let small = try fixture.store.issueTimeline(now: baseline, variant: .small, timeZone: utc)!
        let large = try fixture.store.issueTimeline(now: baseline, variant: .large, timeZone: utc)!
        try require(small.entries[0].item == nil && large.entries[0].item?.localIdentifier == current.localIdentifier, "variant miss substituted another photo")
        try require(try fixture.store.issueTimeline(now: baseline, variant: .small, sourceID: "official-default") == nil, "public source entered personal plan")
        try fixture.store.withProtectedCacheFiles(now: baseline) { protected in
            try require(Set(before.entries.flatMap { $0.item?.allCacheFilenames ?? [] }).isSubset(of: protected), "same-size reissue lost old leases")
        }
    }

    private static func dailyAndHistory() throws {
        let fixture = try Fixture(5)
        defer { fixture.cleanup() }
        let token = try fixture.token()
        let operation = UUID().uuidString
        let time = baseline.addingTimeInterval(19 * 60)
        guard case let .committed(first) = try fixture.store.perform(token: token, operationID: operation, operationCreatedAt: time, now: time, timeZone: utc) else {
            throw CheckFailure.failed("first turn did not commit")
        }
        try require(first.photoID != token.photoID && first.previousPhotoID == token.photoID, "manual source/result binding changed")
        try require(first.overrideUntil == midnightAfter(time), "manual photo did not stay until next midnight")
        let held = try fixture.store.currentEntry(now: baseline.addingTimeInterval(20 * 60), timeZone: utc)
        try require(held?.item?.localIdentifier == first.photoID, "manual vanished at old boundary")
        let nextDay = baseline.addingTimeInterval(24 * 60 * 60)
        let stale = try fixture.store.perform(token: token, operationID: UUID().uuidString, operationCreatedAt: nextDay, now: nextDay, timeZone: utc)
        try require(stale == .refreshRequired, "yesterday's entry consumed today")
        guard case let .existing(replayed) = try fixture.store.perform(token: token, operationID: operation, operationCreatedAt: time, now: nextDay, timeZone: utc) else {
            throw CheckFailure.failed("old invocation did not replay")
        }
        try require(replayed.id == first.id, "replay selected another result")
        let newToken = try fixture.token(at: nextDay)
        guard case let .committed(second) = try fixture.store.perform(token: newToken, operationID: UUID().uuidString, operationCreatedAt: nextDay, now: nextDay, timeZone: utc) else {
            throw CheckFailure.failed("today's new operation blocked")
        }
        try require(try fixture.store.snapshot(now: nextDay)?.history.count == 2, "next grant replaced previous 48h result")
        try require(try fixture.store.snapshot(now: first.resultExpiresAt)?.history.map(\.id) == [second.id], "48h result expiry incorrect")
        let remaining = Set(fixture.candidates.map { $0.item.localIdentifier }).subtracting([second.photoID])
        _ = try fixture.store.updateEligibility(photoIDs: remaining, scopeIdentifier: "result-deleted", isAuthorized: true, now: nextDay)
        let history = try fixture.store.snapshot(now: nextDay)!
        let partial = history.history.first(where: { $0.id == second.id })
        try require(partial?.resultIsAvailable == false && partial?.previousIsAvailable == true, "deleting result hid its valid preceding photo")
        try require(!history.canTurn, "deleting a result refunded quota")
        try require(try fixture.store.perform(token: token, operationID: operation, operationCreatedAt: time, now: time.addingTimeInterval(8 * 86_400), timeZone: utc) == .refreshRequired, "expired invocation became new turn")

        let midnight = ISO8601DateFormatter().date(from: "2026-09-14T23:59:00Z")!
        let midnightFixture = try Fixture(3, at: midnight)
        defer { midnightFixture.cleanup() }
        let midnightToken = try midnightFixture.token(at: midnight)
        _ = try midnightFixture.store.perform(token: midnightToken, operationID: UUID().uuidString, operationCreatedAt: midnight, now: midnight, timeZone: utc)
        let timeline = try midnightFixture.store.issueTimeline(now: midnight, variant: .small, timeZone: utc)!
        try require(timeline.entries.count == 2 && timeline.entries[1].date == midnight.addingTimeInterval(60), "next-day control not scheduled")
        if case .available = timeline.entries[1].action {} else { throw CheckFailure.failed("midnight control stayed used") }

        let dstTime = ISO8601DateFormatter().date(from: "2026-03-08T08:30:00Z")!
        let pacific = TimeZone(identifier: "America/Los_Angeles")!
        let dst = try Fixture(3, at: dstTime, timeZone: pacific)
        defer { dst.cleanup() }
        let dstToken = try dst.token(at: dstTime, timeZone: pacific)
        _ = try dst.store.perform(token: dstToken, operationID: UUID().uuidString, operationCreatedAt: dstTime, now: dstTime, timeZone: pacific)
        try require(try dst.store.snapshot(now: dstTime)?.nextAvailableAt == ISO8601DateFormatter().date(from: "2026-03-09T07:00:00Z"), "DST used fixed 86400 seconds")
    }

    private static func authorityAndPublication() throws {
        let fixture = try Fixture(20)
        defer { fixture.cleanup() }
        let before = try fixture.store.issueTimeline(now: baseline, variant: .small, timeZone: utc)!
        let removed = before.entries[0].item!.localIdentifier
        let originalToken = try fixture.token()
        try fixture.store.suspend(now: baseline)
        try require(try fixture.store.currentEntry(now: baseline) == nil, "suspended source still resolved")
        try fixture.store.withProtectedCacheFiles(now: baseline) { protected in
            try require(protected.count == 60, "suspend discarded retained cache")
        }
        let allowed = Set(fixture.candidates.map { $0.item.localIdentifier }).subtracting([removed])
        let revised = try fixture.store.updateEligibility(photoIDs: allowed, scopeIdentifier: "removed", isAuthorized: true, now: baseline)
        try require(try fixture.store.currentEntry(now: baseline, timeZone: utc)?.item != nil, "removed candidate left a blank slot")
        try require(try fixture.store.currentEntry(now: baseline, timeZone: utc)?.item?.localIdentifier != removed, "removed photo reappeared")
        try require(try fixture.store.perform(token: originalToken, operationID: UUID().uuidString, operationCreatedAt: baseline, now: baseline, timeZone: utc) == .unavailable, "old authority committed")
        do {
            try fixture.store.publish(candidates: [], expectedRevision: fixture.revision, now: baseline)
            throw CheckFailure.failed("stale publish accepted")
        } catch PersonalRediscoveryStore.Error.staleRevision {}
        let stable = try fixture.store.currentEntry(now: baseline, timeZone: utc)
        try fixture.store.publish(candidates: [], expectedRevision: revised, now: baseline.addingTimeInterval(30))
        try require(try fixture.store.currentEntry(now: baseline.addingTimeInterval(30), timeZone: utc)?.slotID == stable?.slotID, "refill reset anchor")
        try fixture.store.publish(candidates: [], expectedRevision: revised, now: baseline, interval: 30 * 60)
        let rescheduled = try fixture.store.issueTimeline(now: baseline, variant: .small, timeZone: utc)!
        try require(rescheduled.entries[1].date == midnightAfter(baseline), "old interval preference restarted automatic rotation")
        let saved = try fixture.store.snapshot(now: baseline)
        do {
            try fixture.store.publish(candidates: [], expectedRevision: revised, now: baseline) { _ in throw CheckFailure.failed("injected IO failure") }
            throw CheckFailure.failed("failed callback reported success")
        } catch CheckFailure.failed("injected IO failure") {}
        try require(try fixture.store.snapshot(now: baseline) == saved, "failed publication changed state")
        let restricted = try fixture.store.restrictEligibility(to: allowed.union(["unexpected-new-photo"]), expectedRevision: revised, now: baseline)
        try require(restricted == revised, "background widened eligibility")

        let full = try Fixture(100)
        defer { full.cleanup() }
        _ = try full.store.issueTimeline(now: baseline, variant: .small, timeZone: utc)
        let refillTime = baseline.addingTimeInterval(3 * 86_400)
        try require(try full.store.snapshot(now: baseline)?.retirableCandidateCount == 0,
                    "daily current/tomorrow photo was marked retirable")
        try require((try full.store.snapshot(now: refillTime)?.retirableCandidateCount ?? 0) > 0,
                    "daily replenishment must not wait for seventy consumed days")
        let newItem = WidgetManifestItem(localIdentifier: "new-photo", cacheFilename: "new-small.jpg", cacheFilenames: WidgetCacheFilenames(small: "new-small.jpg", medium: "new-medium.jpg", large: "new-large.jpg"), scheduledDate: refillTime)
        let addition = PersonalRediscoveryCandidate(item: newItem, preparedAt: refillTime)
        let expandedIDs = Set(full.candidates.map { $0.item.localIdentifier }).union(["new-photo"])
        let revision = try full.store.updateEligibility(photoIDs: expandedIDs, scopeIdentifier: "expanded", isAuthorized: true, now: refillTime)
        try Fixture.writeImages([addition], directory: full.directory)
        let updated = try full.store.publish(candidates: [addition], expectedRevision: revision, now: refillTime)
        try require(updated.candidates.count == 100 && updated.candidates.contains(where: { $0.item.localIdentifier == "new-photo" }), "full pool cannot retire used entries")
        for offset in 0..<110 {
            let entry = try full.store.currentEntry(now: refillTime.addingTimeInterval(Double(offset) * interval), timeZone: utc)
            try require(entry?.item != nil, "retired candidate left future blank slots")
        }

        let stateURL = fixture.directory.appendingPathComponent("personal-rediscovery.v1/state.json")
        try Data("{ broken".utf8).write(to: stateURL)
        do {
            _ = try fixture.store.snapshot(now: baseline)
            throw CheckFailure.failed("corrupt state silently reset quota")
        } catch PersonalRediscoveryStore.Error.corrupted {}
    }

    private static func dailyPhotoAndCadenceMigration() throws {
        let fixture = try Fixture(5)
        defer { fixture.cleanup() }
        let first = try fixture.store.issueTimeline(now: baseline, variant: .small, timeZone: utc)!
        let photo = first.entries[0].item!.localIdentifier
        let tomorrow = midnightAfter(baseline)
        try require(first.entries[1].date == tomorrow && first.reloadDate == midnightAfter(tomorrow),
                    "daily timeline must cover today and tomorrow only")
        for time in [baseline.addingTimeInterval(1_201), baseline.addingTimeInterval(4 * 3_600), tomorrow.addingTimeInterval(-1)] {
            let restarted = PersonalRediscoveryStore(containerURL: fixture.directory)
            try require(try restarted.currentEntry(now: time, timeZone: utc)?.item?.localIdentifier == photo,
                        "photo changed automatically inside a calendar day")
        }
        try fixture.store.publish(candidates: [], expectedRevision: fixture.revision,
                                  now: baseline.addingTimeInterval(3_600), interval: 10 * 60, timeZone: utc)
        try require(try fixture.store.currentEntry(now: baseline.addingTimeInterval(3_601), timeZone: utc)?.item?.localIdentifier == photo,
                    "refill/save changed today's photo")
        let turnTime = baseline.addingTimeInterval(4 * 3_600)
        let token = try fixture.token(at: turnTime)
        guard case let .committed(grant) = try fixture.store.perform(token: token, operationID: UUID().uuidString,
            operationCreatedAt: turnTime, now: turnTime, timeZone: utc) else { throw CheckFailure.failed("daily turn failed") }
        try fixture.store.publish(candidates: [], expectedRevision: fixture.revision, now: turnTime.addingTimeInterval(60), timeZone: utc)
        try require(try fixture.store.currentEntry(now: tomorrow.addingTimeInterval(-1), timeZone: utc)?.item?.localIdentifier == grant.photoID,
                    "manual result disappeared before midnight")
        let next = try fixture.store.currentEntry(now: tomorrow, timeZone: utc)!
        try require(next.item?.localIdentifier != grant.photoID, "tomorrow kept yesterday's manual photo")
        if case .available = next.action {} else { throw CheckFailure.failed("tomorrow did not restore daily action") }

        // Read a real v1 JSON shape without the new optional cadence field.
        // Keep the currently scheduled old photo, candidates, and used quota.
        let legacy = try Fixture(4)
        defer { legacy.cleanup() }
        let legacyToken = try legacy.token()
        let operation = UUID().uuidString
        guard case let .committed(oldGrant) = try legacy.store.perform(token: legacyToken, operationID: operation,
            operationCreatedAt: baseline, now: baseline, timeZone: utc) else { throw CheckFailure.failed("legacy turn fixture") }
        let url = legacy.directory.appendingPathComponent("personal-rediscovery.v1/state.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var oldPlan = json["plan"] as! [String: Any]
        oldPlan.removeValue(forKey: "calendarTimeZoneIdentifier")
        oldPlan["anchor"] = baseline.addingTimeInterval(1_200).timeIntervalSinceReferenceDate
        oldPlan["interval"] = 1_200
        json["plan"] = oldPlan
        var grants = json["grants"] as! [[String: Any]]
        grants[0]["overrideUntil"] = baseline.addingTimeInterval(1_200).timeIntervalSinceReferenceDate
        json["grants"] = grants
        try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)
        let migrated = try legacy.store.currentEntry(now: baseline.addingTimeInterval(60), timeZone: utc)!
        try require(migrated.item?.localIdentifier == oldGrant.photoID, "migration lost current manual photo")
        try require(try legacy.store.currentEntry(now: tomorrow.addingTimeInterval(-1), timeZone: utc)?.item?.localIdentifier == oldGrant.photoID,
                    "legacy manual photo resumed 20-minute cadence")
        let snapshot = try legacy.store.snapshot(now: baseline.addingTimeInterval(60))!
        try require(snapshot.candidates.count == 4 && !snapshot.canTurn && snapshot.history.first?.id == oldGrant.id,
                    "cadence migration reset pool, quota, or history")
        guard case let .existing(replay) = try legacy.store.perform(token: legacyToken, operationID: operation,
            operationCreatedAt: baseline, now: tomorrow, timeZone: utc) else { throw CheckFailure.failed("migration lost replay") }
        try require(replay.id == oldGrant.id, "migration replay picked another photo")

        let automatic = try Fixture(3)
        defer { automatic.cleanup() }
        let original = try automatic.store.currentEntry(now: baseline, timeZone: utc)!.item!.localIdentifier
        let automaticURL = automatic.directory.appendingPathComponent("personal-rediscovery.v1/state.json")
        var oldState = try JSONSerialization.jsonObject(with: Data(contentsOf: automaticURL)) as! [String: Any]
        var automaticPlan = oldState["plan"] as! [String: Any]
        automaticPlan.removeValue(forKey: "calendarTimeZoneIdentifier")
        automaticPlan["anchor"] = baseline.timeIntervalSinceReferenceDate
        automaticPlan["interval"] = 1_200
        oldState["plan"] = automaticPlan
        try JSONSerialization.data(withJSONObject: oldState).write(to: automaticURL, options: .atomic)
        try require(try automatic.store.currentEntry(now: baseline.addingTimeInterval(60), timeZone: utc)?.item?.localIdentifier == original,
                    "unused old plan migration switched the current photo")
        try require(try automatic.store.currentEntry(now: tomorrow.addingTimeInterval(-1), timeZone: utc)?.item?.localIdentifier == original,
                    "unused old plan resumed 20-minute rotation")
        try require(try automatic.store.snapshot(now: baseline)?.canTurn == true, "unused migration consumed a daily turn")

        let leased = try Fixture(100)
        defer { leased.cleanup() }
        let issued = try leased.store.issueTimeline(now: baseline, variant: .small, timeZone: utc)!
        let heldID = issued.entries[0].item!.localIdentifier
        let late = tomorrow.addingTimeInterval(-60)
        try leased.store.withProtectedCacheFiles(now: late) { protected in
            try require(Set(issued.entries[0].item!.allCacheFilenames).isSubset(of: protected), "daily photo lease expired before midnight")
        }
        let extra = PersonalRediscoveryCandidate(item: WidgetManifestItem(localIdentifier: "extra-daily",
            cacheFilename: "extra-daily-small.jpg", cacheFilenames: WidgetCacheFilenames(small: "extra-daily-small.jpg",
                medium: "extra-daily-medium.jpg", large: "extra-daily-large.jpg"), scheduledDate: late), preparedAt: late)
        let revised = try leased.store.updateEligibility(photoIDs: Set(leased.candidates.map { $0.item.localIdentifier }).union(["extra-daily"]),
            scopeIdentifier: "daily-expanded", isAuthorized: true, now: late, timeZone: utc)
        try Fixture.writeImages([extra], directory: leased.directory)
        _ = try leased.store.publish(candidates: [extra], expectedRevision: revised, now: late, timeZone: utc)
        try require(try leased.store.currentEntry(now: late, timeZone: utc)?.item?.localIdentifier == heldID,
                    "candidate refill retired today's displayed photo")

        let pacific = TimeZone(identifier: "America/Los_Angeles")!
        for (start, end, seconds) in [("2026-03-08T08:00:00Z", "2026-03-09T07:00:00Z", 23 * 3_600),
                                      ("2026-11-01T07:00:00Z", "2026-11-02T08:00:00Z", 25 * 3_600)] {
            let date = ISO8601DateFormatter().date(from: start)!
            let midnight = ISO8601DateFormatter().date(from: end)!
            let dst = try Fixture(3, at: date, timeZone: pacific)
            defer { dst.cleanup() }
            let day = try dst.store.issueTimeline(now: date, variant: .small, timeZone: pacific)!
            try require(day.entries[1].date == midnight && midnight.timeIntervalSince(date) == Double(seconds),
                        "automatic daily cadence used 86400 seconds across DST")
            try require(try dst.store.currentEntry(now: midnight.addingTimeInterval(-1), timeZone: pacific)?.item?.localIdentifier == day.entries[0].item?.localIdentifier,
                        "DST changed photo before local midnight")
        }
    }

    private static func concurrentProcesses() throws {
        let fixture = try Fixture(4)
        defer { fixture.cleanup() }
        let token = try fixture.token()
        let encoded = try JSONEncoder().encode(token).base64EncodedString()
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        var children: [(Process, Pipe)] = []
        for _ in 0..<8 {
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = ["--turn", fixture.directory.path, encoded, String(baseline.timeIntervalSince1970), UUID().uuidString]
            process.standardOutput = output
            process.standardError = FileHandle.standardError
            try process.run()
            children.append((process, output))
        }
        var committed = 0
        for (process, output) in children {
            process.waitUntilExit()
            try require(process.terminationStatus == 0, "concurrent child failed")
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if text.contains("committed") { committed += 1 }
        }
        try require(committed == 1, "cross-process calls committed \(committed) grants")
        try require(try fixture.store.snapshot(now: baseline)?.history.count == 1, "race produced multiple daily results")
    }
}
