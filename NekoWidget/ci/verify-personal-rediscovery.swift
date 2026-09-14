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
private let interval: TimeInterval = 20 * 60

private struct Fixture {
    let directory: URL
    let store: PersonalRediscoveryStore
    let candidates: [PersonalRediscoveryCandidate]
    let revision: String

    init(_ count: Int, at date: Date = baseline, legacyOnly: Bool = false) throws {
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
            revision = try store.updateEligibility(photoIDs: Set(candidates.map { $0.item.localIdentifier }), scopeIdentifier: "fixture", isAuthorized: true, now: date)
            if count > 0 { try store.publish(candidates: candidates, expectedRevision: revision, now: date) }
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
            bootstrapCandidates: seeds ?? candidates, interval: interval)
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
        try invalidCandidateDoesNotConsume()
        try authorityAndPublication()
        try upgradeBootstrap()
        try bootstrapRejections()
        try concurrentProcesses()
        print("Personal rediscovery passed: shared slots, bounded pool, cycles, leases, failures, quota, midnight/DST, stale requests, 48h history, source and authority isolation, atomic legacy bootstrap, cross-process race.")
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
        try require(first.entries[1].date == baseline.addingTimeInterval(30 * 60), "bootstrap ignored configured interval")
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
        try require(first.overrideUntil == time.addingTimeInterval(interval), "manual did not move boundary once")
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
        let dst = try Fixture(3, at: dstTime)
        defer { dst.cleanup() }
        let pacific = TimeZone(identifier: "America/Los_Angeles")!
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
        try require(rescheduled.entries[1].date == baseline.addingTimeInterval(30 * 60), "explicit interval ignored")
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
        let refillTime = baseline.addingTimeInterval(13 * 3_600)
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
