import Foundation

// 11/20: what 保存 carries of photo decisions, liked photos and 旅立った日,
// with synthetic identifiers only (no real photos, names or libraries).
// Compiled with the same sources as verify-cat-household-identity.swift.

@main
enum BackupPhotoLinksVerifier {
    static func main() throws {
        try roundTripsToAnotherIPhone()
        try keepsReferencesUntilPhotosArrive()
        try thisIPhoneDecisionsWin()
        try oldBackupsStillRestore()
        try previousBuildReadsNewBackup()
        try toleratesUnknownContent()
        try farewellDaysAgree()
        try sizeStaysInsideOneRecord()
        print("Backup photo links verifier passed")
    }

    // MARK: Fixtures

    static let decoder: JSONDecoder = {
        let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value
    }()
    static let encoder: JSONEncoder = {
        let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; value.outputFormatting = [.sortedKeys]; return value
    }()
    static let day = Date(timeIntervalSince1970: 1_790_000_000)
    static func cloudID(_ n: Int) -> String {
        // The shape of a PHCloudIdentifier string: UUID, a version and an opaque tail.
        String(format: "%08lX-0000-4000-8000-%012lX:001:AbCdEfGhIjKlMnOpQrStUvWxYz%02ld", n, n, n % 100)
    }
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }
    struct Failure: Error, CustomStringConvertible { let message: String; var description: String { message } }

    /// The saved copy exactly as AppRecordCapture writes it: PhotoKit local
    /// identifiers removed, decisions carried by iCloud identity, normalized.
    static func savedCopy(of state: CatHouseholdIdentityState, likes: [String: Date],
                          cloud: [String: String], albumCloud: [String: String]) throws -> Data {
        var saved = state
        let portable = CatPortablePhotoLinks.capturing(state, likes: likes, cloud: cloud, albumCloud: albumCloud)
        for i in saved.profiles.indices { saved.profiles[i].keyPhotoLocalIdentifier = nil; saved.profiles[i].photoAlbumLink = nil }
        saved.memberships = []; saved.globalExcludedAssets = []
        saved.portablePhotoLinks = portable
        saved = saved.normalized()
        return try encoder.encode(saved)
    }

    /// Device A: two cats, every kind of decision.
    static func deviceA() -> (CatHouseholdIdentityState, likes: [String: Date], cloud: [String: String], albumCloud: [String: String]) {
        let mike = CatProfile(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, displayName: "合成ねこA", createdAt: day, updatedAt: day)
        let tora = CatProfile(id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, displayName: "合成ねこB", createdAt: day, updatedAt: day)
        var state = CatHouseholdIdentityState(mode: .profiled, profiles: [mike, tora], memberships: [], globalExcludedAssets: [],
                                              legacyUnscoped: nil, createdAt: day, updatedAt: day)
        state.setManualMembership(assetLocalIdentifier: "a-local-1", profileID: mike.id, decision: .included,
                                  subjectBoundingBox: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                                  isSimilarityReference: true, at: day)
        state.setManualMembership(assetLocalIdentifier: "a-local-2", profileID: mike.id, decision: .excluded, at: day)
        state.setManualMembership(assetLocalIdentifier: "a-local-2", profileID: tora.id, decision: .included, at: day)
        state.setManualMembership(assetLocalIdentifier: "a-local-3", profileID: tora.id, decision: .included, at: day)
        state.setGloballyExcluded(true, assetLocalIdentifiers: ["a-local-4"], at: day)
        state.setProfilePhotoAlbumLink(profileID: tora.id, localIdentifier: "a-album-1",
                                       assetLocalIdentifiers: ["a-local-5", "a-local-6"], at: day)
        state.setProfileKeyPhoto(profileID: mike.id, assetLocalIdentifier: "a-local-1", at: day)
        state.setProfileKeyPhoto(profileID: tora.id, assetLocalIdentifier: "a-local-5", at: day)
        var cloud: [String: String] = [:]
        for n in 1...7 { cloud["a-local-\(n)"] = cloudID(n) }
        let likes = ["a-local-1": day, "a-local-7": day.addingTimeInterval(60)]
        return (state.normalized(), likes, cloud, ["a-album-1": "ALBUM-CLOUD-1:001:Zz"])
    }

    /// Device B: same iCloud library, different local identifiers.
    static func bAssets(_ numbers: ClosedRange<Int> = 1...7) -> [String: String] {
        Dictionary(uniqueKeysWithValues: numbers.map { (cloudID($0), "b-local-\($0)") })
    }

    // MARK: Checks

    static func roundTripsToAnotherIPhone() throws {
        let (a, likes, cloud, albumCloud) = deviceA()
        let bytes = try savedCopy(of: a, likes: likes, cloud: cloud, albumCloud: albumCloud)
        let saved = try decoder.decode(CatHouseholdIdentityState.self, from: bytes)
        // The restore validation every build runs.
        try check(saved == saved.normalized() && saved.schemaVersion == 3, "saved copy must be normalized, schema 3")
        try check(saved.memberships.isEmpty && saved.profiles.allSatisfy({ $0.keyPhotoLocalIdentifier == nil && $0.photoAlbumLink == nil }),
                  "no PhotoKit local identifier is saved")
        try check(!String(decoding: bytes, as: UTF8.self).contains("a-local-"), "local identifiers never leave the iPhone")

        let restored = CatPortablePhotoLinks.applying(saved.portablePhotoLinks, to: saved,
                                                      assets: bAssets(), albums: ["ALBUM-CLOUD-1:001:Zz": "b-album-1"])
        let mike = a.profiles[0].id, tora = a.profiles[1].id
        let first = restored.membership(for: "b-local-1", profileID: mike)
        try check(first?.decision == .included && first?.isSimilarityReference == true
                  && first?.subjectBoundingBox == NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
                  && first?.decidedAt == day, "an assignment comes back with its box, anchor and day")
        try check(restored.membershipDecision(for: "b-local-2", profileID: mike) == .excluded, "この子ではない comes back")
        try check(restored.membershipDecision(for: "b-local-2", profileID: tora) == .included, "one photo, two cats")
        try check(restored.membershipDecision(for: "b-local-3", profileID: tora) == .included, "assignment comes back")
        try check(restored.isGloballyExcluded("b-local-4"), "a hidden non-cat photo stays hidden")
        try check(restored.profiles.first(where: { $0.id == tora })?.photoAlbumLink?.localIdentifier == "b-album-1"
                  && restored.profiles.first(where: { $0.id == tora })?.photoAlbumLink?.lastKnownAssetLocalIdentifiers == ["b-local-5", "b-local-6"],
                  "the linked album comes back")
        try check(restored.profiles.first(where: { $0.id == mike })?.keyPhotoLocalIdentifier == "b-local-1", "key photo of an assigned photo")
        try check(restored.profiles.first(where: { $0.id == tora })?.keyPhotoLocalIdentifier == "b-local-5", "key photo of an album photo")
        let taken = CatPortablePhotoLinks.takingLikes(restored.portablePhotoLinks, assets: bAssets())
        try check(taken.likes == ["b-local-1": day, "b-local-7": day.addingTimeInterval(60)], "liked photos come back")
        try check(taken.remaining == nil, "nothing is left waiting once every photo is here")
    }

    static func keepsReferencesUntilPhotosArrive() throws {
        let (a, likes, cloud, albumCloud) = deviceA()
        let saved = try decoder.decode(CatHouseholdIdentityState.self,
                                       from: savedCopy(of: a, likes: likes, cloud: cloud, albumCloud: albumCloud))
        let mike = a.profiles[0].id, tora = a.profiles[1].id
        // Only photos 2 and 7 are here yet; no album; no Photos access gives nothing at all.
        let none = CatPortablePhotoLinks.applying(saved.portablePhotoLinks, to: saved, assets: [:], albums: [:])
        try check(none.portablePhotoLinks?.expanded() == saved.portablePhotoLinks?.expanded(), "a failed lookup drops nothing")
        let partial = CatPortablePhotoLinks.applying(saved.portablePhotoLinks, to: saved, assets: bAssets(2...2), albums: [:])
        try check(partial.membershipDecision(for: "b-local-2", profileID: tora) == .included, "a present photo is applied")
        guard let waiting = partial.portablePhotoLinks?.expanded() else { throw Failure(message: "nothing kept") }
        try check(waiting.memberships[.init(asset: cloudID(1), profile: mike)] != nil
                  && waiting.memberships[.init(asset: cloudID(3), profile: tora)] != nil, "absent photos keep waiting")
        try check(waiting.exclusions[cloudID(4)] != nil && waiting.albums[tora] != nil, "exclusion and album keep waiting")
        try check(waiting.keyPhotos[mike] == cloudID(1) && waiting.keyPhotos[tora] == cloudID(5), "key photos keep waiting")
        try check(waiting.likes.count == 2, "likes keep waiting")
        try check(waiting.memberships[.init(asset: cloudID(2), profile: tora)] == nil, "an applied decision stops waiting")

        // The waiting references survive the next save from this iPhone.
        let bCloud = ["b-local-2": cloudID(2)]
        let again = try decoder.decode(CatHouseholdIdentityState.self,
                                       from: savedCopy(of: partial, likes: [:], cloud: bCloud, albumCloud: [:]))
        try check(again.portablePhotoLinks?.expanded() == saved.portablePhotoLinks?.expanded(), "a save carries waiting references on")

        // Survives the live ledger's own encode/decode, then the photos arrive.
        let stored = try decoder.decode(CatHouseholdIdentityState.self, from: encoder.encode(partial))
        try check(stored == partial, "waiting references round-trip in the live ledger")
        let later = CatPortablePhotoLinks.applying(stored.portablePhotoLinks, to: stored, assets: bAssets(),
                                                   albums: ["ALBUM-CLOUD-1:001:Zz": "b-album-1"])
        try check(later.membershipDecision(for: "b-local-1", profileID: mike) == .included
                  && later.isGloballyExcluded("b-local-4")
                  && later.profiles.first(where: { $0.id == mike })?.keyPhotoLocalIdentifier == "b-local-1"
                  && later.profiles.first(where: { $0.id == tora })?.keyPhotoLocalIdentifier == "b-local-5",
                  "a later try applies the rest")
        try check(later.portablePhotoLinks?.expanded().likes.count == 2
                  && later.portablePhotoLinks?.expanded().memberships.isEmpty == true, "likes wait for the like store only")
    }

    static func thisIPhoneDecisionsWin() throws {
        let (a, likes, cloud, albumCloud) = deviceA()
        let saved = try decoder.decode(CatHouseholdIdentityState.self,
                                       from: savedCopy(of: a, likes: likes, cloud: cloud, albumCloud: albumCloud))
        let mike = a.profiles[0].id, tora = a.profiles[1].id
        var local = saved
        local.setManualMembership(assetLocalIdentifier: "b-local-1", profileID: mike, decision: .excluded, at: day.addingTimeInterval(10))
        local.setProfilePhotoAlbumLink(profileID: tora, localIdentifier: "b-own-album", assetLocalIdentifiers: ["b-local-9"], at: day)
        local.setManualMembership(assetLocalIdentifier: "b-local-4", profileID: tora, decision: .included, at: day.addingTimeInterval(20))
        let result = CatPortablePhotoLinks.applying(local.portablePhotoLinks, to: local, assets: bAssets(),
                                                    albums: ["ALBUM-CLOUD-1:001:Zz": "b-album-1"])
        try check(result.membershipDecision(for: "b-local-1", profileID: mike) == .excluded, "this iPhone's decision is kept")
        try check(result.profiles.first(where: { $0.id == tora })?.photoAlbumLink?.localIdentifier == "b-own-album", "this iPhone's album is kept")
        try check(!result.isGloballyExcluded("b-local-4") && result.membershipDecision(for: "b-local-4", profileID: tora) == .included,
                  "a later decision here wins over an older saved exclusion")
        // The like store merge never un-likes (SharedLikeStore.mergeRestoredLikes): checked by construction there.
    }

    static func oldBackupsStillRestore() throws {
        // Written by a build before 11/20: no portablePhotoLinks, no farewellDays.
        let old = """
        {"createdAt":"2026-09-01T00:00:00Z","globalExcludedAssets":[],"memberships":[],"mode":"profiled","mutationRevision":4,
         "profiles":[{"createdAt":"2026-09-01T00:00:00Z","displayName":"合成ねこ","id":"33333333-3333-4333-8333-333333333333",
         "lifeReferenceIsApproximate":false,"updatedAt":"2026-09-01T00:00:00Z"}],"schemaVersion":3,"updatedAt":"2026-09-01T00:00:00Z"}
        """
        let state = try decoder.decode(CatHouseholdIdentityState.self, from: Data(old.utf8))
        try check(state == state.normalized(), "an old saved copy passes the restore validation")
        try check(state.portablePhotoLinks == nil && state.farewellDays == nil, "nothing is invented")
        try check(CatPortablePhotoLinks.applying(state.portablePhotoLinks, to: state, assets: bAssets(), albums: [:]) == state,
                  "an old backup restores as before")
        let reencoded = String(decoding: try encoder.encode(state), as: UTF8.self)
        try check(!reencoded.contains("portablePhotoLinks") && !reencoded.contains("farewellDays"), "no new keys appear when empty")
    }

    /// The decoder of the builds before 11/20, unchanged: the same keys, each
    /// optional with the same default. Nested types are unchanged by this work.
    struct PreviousIdentity: Decodable {
        var schemaVersion: Int, mutationRevision: Int, mode: CatHouseholdIdentityMode
        var profiles: [CatProfile], memberships: [CatAssetProfileMembership], globalExcludedAssets: [ExcludedCatAsset]
        var legacyUnscoped: CatLegacyUnscopedIdentity?, createdAt: Date, updatedAt: Date
        enum CodingKeys: String, CodingKey {
            case schemaVersion, mutationRevision, mode, profiles, memberships, globalExcludedAssets, legacyUnscoped, createdAt, updatedAt
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            mutationRevision = try c.decodeIfPresent(Int.self, forKey: .mutationRevision) ?? 0
            mode = try c.decodeIfPresent(CatHouseholdIdentityMode.self, forKey: .mode) ?? .legacyUnscoped
            profiles = try c.decodeIfPresent([CatProfile].self, forKey: .profiles) ?? []
            memberships = try c.decodeIfPresent([CatAssetProfileMembership].self, forKey: .memberships) ?? []
            globalExcludedAssets = try c.decodeIfPresent([ExcludedCatAsset].self, forKey: .globalExcludedAssets) ?? []
            legacyUnscoped = try c.decodeIfPresent(CatLegacyUnscopedIdentity.self, forKey: .legacyUnscoped)
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
            updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        }
    }

    static func previousBuildReadsNewBackup() throws {
        let (a, likes, cloud, albumCloud) = deviceA()
        var withDays = a
        withDays.farewellDays = ["tool-44444444-4444-4444-8444-444444444444": CatFarewellDay(year: 2026, month: 10, day: 1)]
        let bytes = try savedCopy(of: withDays.normalized(), likes: likes, cloud: cloud, albumCloud: albumCloud)
        let previous = try decoder.decode(PreviousIdentity.self, from: bytes)
        let current = try decoder.decode(CatHouseholdIdentityState.self, from: bytes)
        try check(current.portablePhotoLinks != nil && current.farewellDays != nil, "the new build reads its fields")
        try check((1...3).contains(previous.schemaVersion), "a previous build accepts the schema")
        // What a previous build holds after decoding is exactly the new state
        // without the two optional fields; its normalization (the same code
        // for those fields) therefore accepts it as it accepted older copies.
        var seenByPrevious = CatHouseholdIdentityState(
            schemaVersion: previous.schemaVersion, mutationRevision: previous.mutationRevision, mode: previous.mode,
            profiles: previous.profiles, memberships: previous.memberships, globalExcludedAssets: previous.globalExcludedAssets,
            legacyUnscoped: previous.legacyUnscoped, createdAt: previous.createdAt, updatedAt: previous.updatedAt)
        try check(seenByPrevious == seenByPrevious.normalized(), "a previous build's restore validation passes")
        seenByPrevious.portablePhotoLinks = current.portablePhotoLinks
        seenByPrevious.farewellDays = current.farewellDays
        try check(seenByPrevious == current, "only the two optional fields are new")
    }

    static func toleratesUnknownContent() throws {
        let json = """
        {"version":9,"assets":["\(cloudID(1))","\(cloudID(2))",""],"profiles":["11111111-1111-4111-8111-111111111111"],
         "memberships":[{"a":0,"p":0,"d":"maybe-later","t":"2026-09-01T00:00:00Z"},{"a":7,"p":0,"d":"included","t":"2026-09-01T00:00:00Z"},
                        {"a":1,"p":0,"d":"included","t":"2026-09-01T00:00:00Z","future":true}],
         "likes":[{"a":2,"t":"2026-09-01T00:00:00Z"}],"somethingNew":[1,2,3]}
        """
        let links = try decoder.decode(CatPortablePhotoLinks.self, from: Data(json.utf8))
        let expanded = links.expanded()
        try check(expanded.memberships.count == 1 && expanded.likes.isEmpty, "unknown decisions and bad positions are skipped, not fatal")
        let empty = try decoder.decode(CatPortablePhotoLinks.self, from: Data("{}".utf8))
        try check(empty.expanded().isEmpty, "every field has a default")
    }

    static func farewellDaysAgree() throws {
        let d1 = CatFarewellDay(year: 2026, month: 3, day: 2), d2 = CatFarewellDay(year: 2025, month: 12, day: 24)
        // First run after the update: the iPhone's days join the record's.
        var r = CatFarewellMirror.reconcile(user: ["p1": d1], mirrored: nil, record: ["p2": d2])
        try check(r.agreed == ["p1": d1, "p2": d2] && r.writesUser && r.writesRecord, "first agreement adds, never removes")
        // New iPhone after restore: UserDefaults is empty, the record has the day.
        r = CatFarewellMirror.reconcile(user: [:], mirrored: nil, record: ["p1": d1])
        try check(r.agreed == ["p1": d1] && r.writesUser && !r.writesRecord, "a restored day reaches the screens")
        // A restore over agreed state: the record wins where the iPhone made no change.
        r = CatFarewellMirror.reconcile(user: ["p1": d1], mirrored: ["p1": d1], record: ["p1": d1, "p2": d2])
        try check(r.agreed == ["p1": d1, "p2": d2] && r.writesUser && !r.writesRecord, "restored days are added")
        // 「記録を消す」 on the iPhone reaches the record.
        r = CatFarewellMirror.reconcile(user: [:], mirrored: ["p1": d1], record: ["p1": d1])
        try check(r.agreed.isEmpty && r.writesRecord && !r.writesUser, "a removal is saved too")
        r = CatFarewellMirror.reconcile(user: ["p1": d1], mirrored: ["p1": d1], record: ["p1": d1])
        try check(!r.writesUser && !r.writesRecord, "agreement writes nothing")

        // Unreadable UserDefaults text is never replaced.
        try check(CatFarewellDay.decodeAll("not json") == nil, "unreadable text is reported, not read as empty")
        try check(CatFarewellDay.decodeAll("") == [:], "an empty value is empty")
        let mixed = #"{"p1":{"year":2026,"month":3,"day":2},"p9":"garbage"}"#
        try check(CatFarewellDay.decodeAll(mixed) == ["p1": d1], "one bad entry hides no other")
        let rewritten = CatFarewellDay.encodeAll(["p1": d1, "p2": d2], keepingUnreadableFrom: mixed)
        try check(rewritten.contains("\"p9\":\"garbage\"") && CatFarewellDay.decodeAll(rewritten) == ["p1": d1, "p2": d2],
                  "a bad entry is kept as it was")

        // The record keeps the day across the saved copy.
        var state = CatHouseholdIdentityState(mode: .profiled, profiles: [], memberships: [], globalExcludedAssets: [],
                                              legacyUnscoped: nil, createdAt: day, updatedAt: day)
        state.farewellDays = ["p1": d1, "": d2, "p3": CatFarewellDay(year: 2026, month: 13, day: 1)]
        state = state.normalized()
        try check(state.farewellDays == ["p1": d1], "invalid days and keys are not kept")
        let back = try decoder.decode(CatHouseholdIdentityState.self, from: encoder.encode(state))
        try check(back == state && back == back.normalized(), "farewell days round-trip")
    }

    static func sizeStaysInsideOneRecord() throws {
        // A heavy household: 30,000 decided photos, 3,000 hidden, 5,000 liked.
        var profiles: [CatProfile] = []
        for n in 0..<10 {
            profiles.append(CatProfile(id: UUID(uuidString: String(format: "%08lX-0000-4000-8000-000000000000", n + 1))!,
                                       displayName: "合成\(n)", createdAt: day, updatedAt: day))
        }
        var state = CatHouseholdIdentityState(mode: .profiled, profiles: profiles, memberships: [], globalExcludedAssets: [],
                                              legacyUnscoped: nil, createdAt: day, updatedAt: day)
        var cloud: [String: String] = [:]
        for n in 0..<33_000 { cloud["l\(n)"] = cloudID(n) }
        state.memberships = (0..<30_000).map {
            CatAssetProfileMembership(assetLocalIdentifier: "l\($0)", profileID: profiles[$0 % 10].id,
                                      decision: $0 % 7 == 0 ? .excluded : .included, decidedAt: day)
        }
        state.globalExcludedAssets = (30_000..<33_000).map { ExcludedCatAsset(localIdentifier: "l\($0)", excludedAt: day) }
        let likes = Dictionary(uniqueKeysWithValues: (0..<5_000).map { ("l\($0)", day) })
        let bytes = try savedCopy(of: state, likes: likes, cloud: cloud, albumCloud: [:])
        let perPhoto = Double(bytes.count) / 33_000
        print("size: 30,000 decisions + 3,000 exclusions + 5,000 likes = \(bytes.count) bytes (\(Int(perPhoto)) bytes a photo), \((bytes.count + 49_151) / 49_152) records of 48 KB")
        try check(bytes.count < 8 * 1024 * 1024, "a heavy household fits one 8 MB record file")
        let saved = try decoder.decode(CatHouseholdIdentityState.self, from: bytes)
        try check(saved == saved.normalized(), "the large saved copy passes validation")
        try check(saved.portablePhotoLinks?.expanded().memberships.count == 30_000, "no decision is cut to fit")
    }
}
