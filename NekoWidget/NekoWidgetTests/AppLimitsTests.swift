import XCTest
@testable import NekoWidget

/// 11/14: the limits the owner approved, and that each one says so instead
/// of failing silently. Synthetic data only: no photos, no PhotoKit, no network.
final class AppLimitsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-limits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - 1. At most 10 living cats

    func testLivingCatsCountWithoutDepartedOnes() {
        let ten = (0..<10).map { "cat-\($0)" }
        XCTAssertEqual(CatProfileLimit.maximumLiving, 10)
        XCTAssertFalse(CatProfileLimit.canAdd(ten, departed: []))
        // A cat whose farewell day is recorded does not count.
        XCTAssertTrue(CatProfileLimit.canAdd(ten, departed: ["cat-3"]))
        XCTAssertEqual(CatProfileLimit.livingCount(ten, departed: ["cat-3", "cat-4"]), 8)
        XCTAssertTrue(CatProfileLimit.canAdd(Array(ten.prefix(9)), departed: []))
        // In a tool, a cat without a profile is still a cat in the plan.
        XCTAssertEqual(CatProfileLimit.livingCount([nil, "a", "b"], departed: ["a"]), 2)
        // Existing data with more than 10 keeps working; only adding stops.
        let twelve = (0..<12).map { "cat-\($0)" }
        XCTAssertFalse(CatProfileLimit.canAdd(twelve, departed: ["cat-0"]))
        XCTAssertEqual(CatProfileLimit.room(existing: twelve, departed: []), 0)
        XCTAssertEqual(AppLimitCopy.catProfiles, "猫は10匹まで登録できます。")
        XCTAssertEqual(AppLimitCopy.catProfilesImported, "10匹まで読み込みました。")
    }

    private func profiles(_ count: Int) -> [CatProfile] {
        (0..<count).map { CatProfile(displayName: "猫\($0)") }
    }

    private func emptyState() -> CatHouseholdIdentityState {
        CatHouseholdIdentityState(mode: .profiled, profiles: [], memberships: [], globalExcludedAssets: [],
                                  legacyUnscoped: nil, createdAt: Date(timeIntervalSince1970: 1),
                                  updatedAt: Date(timeIntervalSince1970: 1))
    }

    func testImportBringsTheFirstTenCatsInFileOrder() throws {
        let cats = profiles(12)
        let metadata = CatProfileTransfer.PhotoMetadata(creationDate: Date(timeIntervalSince1970: 1_700_000_000),
                                                        width: 10, height: 10, mediaType: 1, duration: 0)
        let onlyEleventh = CatProfileTransfer.Photo(id: UUID(), metadata: metadata, profileIDs: [cats[10].id])
        let firstAndTwelfth = CatProfileTransfer.Photo(id: UUID(), metadata: metadata, profileIDs: [cats[0].id, cats[11].id])
        let file = try CatProfileTransfer(profiles: cats, photos: [onlyEleventh, firstAndTwelfth])
        let decoded = try CatProfileTransfer.decode(file.encoded())
        let (limited, wasLimited) = decoded.limitedToCatProfileLimit()
        XCTAssertTrue(wasLimited)
        XCTAssertEqual(limited.profiles.map(\.id), cats.prefix(10).map(\.id))
        XCTAssertEqual(limited.photos?.map(\.id), [firstAndTwelfth.id])
        XCTAssertEqual(limited.photos?.first?.profileIDs, [cats[0].id])
        XCTAssertNoThrow(try limited.validate())
        let applied = try limited.applying(to: emptyState(), expectedRevision: 0)
        XCTAssertEqual(applied.profiles.count, 10)
        XCTAssertEqual(applied.profiles.map(\.id), cats.prefix(10).map(\.id))
        // Reading the same file again changes nothing and duplicates nothing.
        XCTAssertEqual(try limited.applying(to: applied, expectedRevision: applied.mutationRevision), applied)

        let nine = try CatProfileTransfer(profiles: profiles(9))
        let (same, nineLimited) = nine.limitedToCatProfileLimit()
        XCTAssertFalse(nineLimited)
        XCTAssertEqual(same, nine)
    }

    func testRestoreKeepsEveryCatAndOnlyBlocksAdding() throws {
        // A restore writes the saved household as it was: twelve cats stay
        // twelve (normalized() and a JSON round trip do not drop any).
        var state = emptyState()
        state.profiles = profiles(12)
        let normalized = state.normalized()
        XCTAssertEqual(normalized.profiles.count, 12)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(CatHouseholdIdentityState.self, from: encoder.encode(normalized))
        XCTAssertEqual(restored.profiles.count, 12)
        XCTAssertEqual(restored, restored.normalized(), "a restored household must stay valid for the restore check")
        XCTAssertFalse(CatProfileLimit.canAdd(restored.profiles.map(\.id.uuidString), departed: []))
    }

    // MARK: - 2. Names

    func testCatNamesStopAtTwentyCharactersAsPeopleCountThem() {
        XCTAssertEqual(CatNameText.maximumCharacters, 20)
        XCTAssertEqual(CatCareLimits.nameCharacters, CatNameText.maximumCharacters)
        let pasted = CatNameText.accept(String(repeating: "猫", count: 25), previous: "")
        XCTAssertEqual(pasted.count, 20)
        let family = "👨‍👩‍👧"
        XCTAssertEqual(family.count, 1)
        XCTAssertEqual(VisibleText.cleaned(family), family, "a joined emoji stays one character")
        XCTAssertEqual(VisibleText.cleaned("むぎ🐈‍⬛"), "むぎ🐈‍⬛")
        XCTAssertEqual(VisibleText.cleaned("🏳️‍🌈"), "🏳️‍🌈")
        let emoji = CatNameText.accept(String(repeating: family, count: 25), previous: "")
        XCTAssertEqual(emoji.count, 20)
        XCTAssertEqual(emoji, String(repeating: family, count: 20))
        // Typing at the limit adds nothing.
        let full = String(repeating: "あ", count: 20)
        XCTAssertEqual(CatNameText.accept(full + "い", previous: full), full)
    }

    func testInvisibleCharactersAndLineBreaksAreTakenOut() {
        XCTAssertEqual(VisibleText.cleaned("む\u{200B}ぎ"), "むぎ")
        XCTAssertEqual(VisibleText.cleaned("\u{202E}むぎ\u{202C}"), "むぎ")
        XCTAssertEqual(VisibleText.cleaned("\u{2066}む\u{2069}ぎ\u{200F}"), "むぎ")
        XCTAssertEqual(VisibleText.cleaned("む\nぎ\r\t"), "むぎ")
        XCTAssertEqual(VisibleText.cleaned("\u{FEFF}む\u{2060}ぎ\u{00AD}"), "むぎ")
        XCTAssertEqual(VisibleText.cleaned("a\u{200D}b"), "ab", "a joiner outside an emoji is invisible")
        XCTAssertEqual(CatNameText.saving("  　む ぎ　 "), "む ぎ")
        XCTAssertNil(CatNameText.saving(" \u{200B}\n "), "a name that is empty after cleaning is not saved")
    }

    func testLongerNamesSavedBeforeAreKeptAndCanBeShortened() {
        let legacy = String(repeating: "猫", count: 30)
        XCTAssertEqual(CatNameText.accept(legacy + "犬", previous: legacy), legacy, "never grows past the limit")
        let shortened = String(legacy.dropLast())
        XCTAssertEqual(CatNameText.accept(shortened, previous: legacy), shortened)
        // The stored profile keeps it as it is (up to the old 80).
        let profile = CatProfile(displayName: legacy).normalized()
        XCTAssertEqual(profile.displayName, legacy)
        XCTAssertEqual(CatNameText.storedMaximumCharacters, 80)
    }

    // MARK: - 6. Telephone numbers

    func testPhoneFieldsTakeDigitsAndPhoneSignsOnly() {
        func type(_ new: String, after old: String) -> String {
            TextInputGate.accept(new, previous: old, limit: CatCareLimits.phoneCharacters,
                                 allow: CatCareLimits.isPhoneCharacter)
        }
        XCTAssertEqual(CatCareLimits.phoneCharacters, 20)
        XCTAssertEqual(type("03-1234a", after: "03-1234"), "03-1234")
        XCTAssertEqual(type("+81 (3) 1234-5678", after: ""), "+81 (3) 1234-5678")
        XCTAssertEqual(type("０３－１２３４", after: ""), "０３－１２３４")
        XCTAssertEqual(type("tel:0312345678", after: ""), "0312345678")
        XCTAssertEqual(type(String(repeating: "0", count: 25), after: "").count, 20)
        // A value saved before stays; deleting from it works.
        XCTAssertEqual(type("みどり 03-1", after: "みどり 03-12"), "みどり 03-1")
        XCTAssertEqual(type("みどり 03-12x", after: "みどり 03-12"), "みどり 03-12")
    }

    // MARK: - 4. Limits speak, in one wording

    func testLimitSentencesShareOneWording() {
        XCTAssertEqual(AppLimitCopy.items("体重", 500), "体重は500件までです。")
        XCTAssertEqual(AppLimitCopy.items("見せる写真", 9, unit: "枚"), "見せる写真は9枚までです。")
        XCTAssertEqual(AppLimitCopy.catsInTool, "猫は10匹までです。")
        XCTAssertEqual(CatCareListEditor.Kind.meal.limitSentence, "ごはんは8件までです。")
        XCTAssertEqual(CatCareListEditor.Kind.weight.limitSentence, "体重は500件までです。")
        XCTAssertEqual(PhotoMemoryNoteStoreError.limitReached.errorDescription, "写真のメモは3,000件までです。")
        XCTAssertEqual(PhotoMemoryNoteStore.maximumNotes, 3_000)
        XCTAssertEqual(VeterinaryVisitError.visitLimit.errorDescription, "診察メモは1,000件までです。")
        XCTAssertEqual(VeterinaryVisitStore.maximumFinishedPerCat, 1_000)
        XCTAssertEqual(GroupWindowPresentation.message(for: GroupClientError.dailyLimit),
                       "きょうはここまでです。あした、また届けられます。")
        XCTAssertEqual(GroupWindowPresentation.dailyHeartLimitMessage, "きょうのハートはここまでです。")
    }

    func testPhotoMemoStopsAtThreeThousandNewMemosOnly() async throws {
        struct Fixture: Encodable { let schemaVersion = 4; let notes: [String: PhotoMemoryNote] }
        var notes: [String: PhotoMemoryNote] = [:]
        for i in 0..<PhotoMemoryNoteStore.maximumNotes {
            notes["synthetic-photo-\(i)"] = PhotoMemoryNote(id: UUID(), text: "猫", updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                                           revision: UUID().uuidString)
        }
        let url = directory.appendingPathComponent("state.json")
        try JSONEncoder().encode(Fixture(notes: notes)).write(to: url)
        let store = PhotoMemoryNoteStore(fileURL: url)
        let isFull = try await store.isFull()
        XCTAssertTrue(isFull)
        do {
            _ = try await store.save(text: "新しいメモ", for: "synthetic-photo-new", expectedRevision: nil)
            XCTFail("a memo past 3,000 was added")
        } catch PhotoMemoryNoteStoreError.limitReached {}
        // A memo already there can still be changed.
        let existing = try await store.note(for: "synthetic-photo-7")
        let changed = try await store.save(text: "書き直し", for: "synthetic-photo-7", expectedRevision: existing?.revision)
        XCTAssertEqual(changed?.text, "書き直し")
        let count = try await store.records().count
        XCTAssertEqual(count, 3_000)
    }

    // MARK: - 8. Vet memos read what they can

    private func visitJSON(id: String = UUID().uuidString, cat: UUID, entries: Int = 0, finished: Bool = true) -> [String: Any] {
        var visit: [String: Any] = ["id": id, "catID": cat.uuidString, "catName": "むぎ", "revision": UUID().uuidString,
                                    "observations": "", "questions": "",
                                    "entries": (0..<entries).map { _ in
                                        ["id": UUID().uuidString, "sourceNoteID": UUID().uuidString,
                                         "sourceRevision": UUID().uuidString, "text": "記録"] as [String: Any]
                                    }]
        if finished { visit["completedAt"] = 784_000_000 }
        return visit
    }

    func testVetMemosOpenAroundOneTheyCannotReadAndKeepItOnDisk() async throws {
        let cat = UUID()
        let readable = visitJSON(cat: cat)
        let newer: [String: Any] = ["id": "not-a-uuid", "shape": "from a newer build"]
        let tooManyEntries = visitJSON(cat: cat, entries: VeterinaryVisitStore.maximumEntries + 1)
        let file: [String: Any] = ["schema": 1, "visits": [readable, newer, tooManyEntries]]
        let ledger = directory.appendingPathComponent("state.json")
        let original = try JSONSerialization.data(withJSONObject: file)
        try original.write(to: ledger)

        let store = VeterinaryVisitStore(directory: directory)
        let visits = try await store.visits()
        XCTAssertEqual(visits.map(\.id.uuidString), [readable["id"] as? String])
        XCTAssertEqual(try Data(contentsOf: ledger), original, "reading must not rewrite the file")

        // A new memo for another cat is saved; what could not be read stays.
        let started = try await store.current(catID: UUID(), catName: "そら") { try $0() }
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: ledger)) as? [String: Any]
        let ids = (saved?["visits"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        XCTAssertTrue(ids.contains("not-a-uuid"))
        XCTAssertTrue(ids.contains(tooManyEntries["id"] as! String))
        XCTAssertTrue(ids.contains(started.id.uuidString))
        let unread = (saved?["visits"] as? [[String: Any]] ?? []).first { $0["id"] as? String == "not-a-uuid" }
        XCTAssertEqual(unread?["shape"] as? String, "from a newer build")
        let reopened = try await VeterinaryVisitStore(directory: directory).visits()
        XCTAssertEqual(Set(reopened.map(\.id)), Set([UUID(uuidString: readable["id"] as! String)!, started.id]))
    }

    func testVetMemoLimitIsPerCatAndReadingHasNone() async throws {
        let cat = UUID()
        let visits = (0..<VeterinaryVisitStore.maximumFinishedPerCat).map { _ in visitJSON(cat: cat) }
        try JSONSerialization.data(withJSONObject: ["schema": 1, "visits": visits] as [String: Any])
            .write(to: directory.appendingPathComponent("state.json"))
        let store = VeterinaryVisitStore(directory: directory)
        let count = try await store.visits().count
        XCTAssertEqual(count, 1_000)
        do {
            _ = try await store.current(catID: cat, catName: "むぎ") { try $0() }
            XCTFail("an 1,001st memo started")
        } catch VeterinaryVisitError.visitLimit {}
        // Another cat is not affected.
        let other = try await store.current(catID: UUID(), catName: "そら") { try $0() }
        XCTAssertNil(other.completedAt)
    }

    // MARK: - 7. Lost-cat flyer: one set of limits

    @MainActor
    func testFlyerLimitsAreOneSetAndSavedTextIsNotCut() throws {
        XCTAssertEqual(LostCatFlyerRenderer.featuresLimit, 200)
        XCTAssertEqual(LostCatFlyerRenderer.collarLimit, 40)
        XCTAssertEqual(LostCatFlyerRenderer.adviceLimit, 80)
        XCTAssertEqual(LostCatFlyerRenderer.foundMessageLimit, 80)
        let store = CatPreparednessStore(directory: directory)
        var record = CatPreparednessRecord()
        record.identifyingFeatures = String(repeating: "白", count: 230)
        record.collar = String(repeating: "赤", count: 50)
        record.approachAdvice = String(repeating: "静", count: 100)
        try store.save(record, for: "new")
        XCTAssertEqual(store.record(for: "new").identifyingFeatures.count, 200)
        XCTAssertEqual(store.record(for: "new").collar.count, 40)
        XCTAssertEqual(store.record(for: "new").approachAdvice.count, 80)

        // Saved before 11/14 with the old, longer limits: kept as it is.
        var legacy = record
        legacy.identifyingFeatures = String(repeating: "黒", count: 230)
        let manifest = directory.appendingPathComponent("records.json")
        try JSONEncoder().encode(["old": legacy]).write(to: manifest)
        let reopened = CatPreparednessStore(directory: directory)
        var edited = reopened.record(for: "old")
        edited.name = "むぎ"
        try reopened.save(edited, for: "old")
        XCTAssertEqual(reopened.record(for: "old").identifyingFeatures.count, 230)
        XCTAssertNotNil(LostCatFlyerRenderer.lengthIssue(edited.identifyingFeatures, label: "見分ける特徴",
                                                         limit: LostCatFlyerRenderer.featuresLimit))
    }

    // MARK: - 3. Tools take as many cats as can exist

    func testToolPlansKeepTheirSavedCatsAndAddUpToTheLimit() throws {
        XCTAssertGreaterThanOrEqual(CareHandoffPlan.storedMaximumCats, CatProfileLimit.maximumLiving)
        XCTAssertGreaterThanOrEqual(EvacuationPlan.storedMaximumCats, CatProfileLimit.maximumLiving)
        XCTAssertEqual(EvacuationPlan.maximumSupplies, 200)
        XCTAssertEqual(EvacuationPlan.maximumDestinations, 30)
    }
}
