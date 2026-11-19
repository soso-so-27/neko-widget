import SwiftUI

/// Test builds only: the family notebook, working on this iPhone alone.
///
/// 「この子のこと」 stays the record every tool reads. The notebook is the
/// family's layer over it (Codex's local model): making the family copies
/// 「この子のこと」, 病院で見せる and 預けるとき in once (the originals stay as
/// they are); after that every save of 「この子のこと」 goes into the notebook,
/// and what the family writes comes back into 「この子のこと」. Nothing is sent:
/// there is no server yet, so "the family" is tried with the test buttons.
@MainActor
final class FamilyNotebookPrototype: ObservableObject {
    static let shared = FamilyNotebookPrototype()

    private static let familyKey = "debug.familyNotebook.familyID.v1"
    private static let deviceKey = "debug.familyNotebook.deviceID.v1"
    private static let seenKey = "debug.familyNotebook.seenClock.v1"
    private static let undoKey = "debug.familyNotebook.tryoutUndo.v1"
    private static let removedKey = "debug.familyNotebook.removedMembers.v1"
    private static let joinedKey = "debug.familyNotebook.joined.v1"

    @Published private(set) var snapshot: FamilyNotebookSnapshot?
    @Published var message: String?
    /// Counts each time the family's writing was put into 「この子のこと」,
    /// so an open page can show it instead of keeping what it had.
    @Published private(set) var familyWritesToCatCare = 0

    private var store: FamilyNotebookStore?
    private var realAuthor: FamilyNotebookAuthor?
    private var realMemberIDs: [String] = []
    private var applyingRemote = false
    private var notebookObserver: NSObjectProtocol?
    private var readableObserver: NSObjectProtocol?
    private static let bindingKey = FamilyNotebookLocalBinding.key
    var isReal: Bool { FamilyNotebookServiceFactory.productionRequested }
    var currentAuthor: FamilyNotebookAuthor? { isReal ? realAuthor : Self.me }
    func isMe(_ author: FamilyNotebookAuthor) -> Bool { author.personID == currentAuthor?.personID }
    private func writer() throws -> FamilyNotebookAuthor {
        guard let value = currentAuthor else { throw FamilySharingError.signInExpired }; return value
    }
    private var currentSeenKey: String {
        guard isReal, let id = snapshot?.familyID, let person = realAuthor?.personID else { return Self.seenKey }
        return "familyNotebook.seen.v1." + person + "." + id.uuidString.lowercased() + "." + (store?.localDirectory.lastPathComponent ?? "")
    }

    static let me = FamilyNotebookAuthor(personID: "this-iphone", displayName: "あなた")
    /// The other person in the test buttons. Not a real member.
    static let tryout = FamilyNotebookAuthor(personID: "tryout-family", displayName: "家族（試し）")
    private static let tryoutDevice = "tryout-device"

    /// The items of 「この子のこと」 that go back and forth one by one.
    static let catFields: [FamilyNotebookField] = [
        .name, .sex, .neutered, .indoorOnly, .birthday, .adoptionDay, .coat, .marks, .microchip,
        .conditions, .allergyStatus, .allergyText, .specialDiet, .water, .litter, .temperament,
        .vetName, .vetPhone, .vetNote]

    var hasFamily: Bool { snapshot.map { !$0.sharingEnded } ?? false }
    /// 11/18: ended without proof (FamilyNotebookEndReason.mayResume): the
    /// schedule still asks the family, and a verified answer reopens it.
    var mayResumeEndedNotebook: Bool {
        isReal && snapshot.map { $0.sharingEnded && FamilyNotebookEndReason.mayResume($0.endedReason) } == true
    }

    /// This iPhone joined someone's family instead of making one. Everyone
    /// can invite and leave; only the payer removes others or dissolves it.
    var joinedSomeonesFamily: Bool { hasFamily && UserDefaults.standard.bool(forKey: Self.joinedKey) }

    /// The cats an invitation shows (test builds: this iPhone's own).
    var catNames: [String] {
        if isReal { return familyCats.map(\.name) }
        return (CatCareStore.shared.state?.cats ?? []).compactMap { $0.name?.value }.filter { !$0.isEmpty }
    }

    struct FamilyCat: Identifiable { let id: UUID; let toolID: UUID; let name: String }
    var familyCats: [FamilyCat] {
#if DEBUG
        if let fixtureCats { return fixtureCats.map { FamilyCat(id: $0.id, toolID: $0.toolID, name: $0.name) } }
#endif
        guard let snapshot else { return [] }
        var seen = Set<UUID>()
        return snapshot.activeMappings.compactMap { mapping in
            guard mapping.recordID == nil, let toolID = mapping.toolCatID, seen.insert(mapping.familyCatID).inserted,
                  snapshot.fieldState(for: .init(familyCatID: mapping.familyCatID, field: nil))?.isDeleted != true else { return nil }
            return FamilyCat(id: mapping.familyCatID, toolID: toolID, name: name(of: mapping.familyCatID))
        }
    }

    /// 11/19: the notebook's list of cats in the family's order
    /// (FamilyNotebookCatOrder, worked out on each read), not in the order
    /// this iPhone happened to keep them.
    var orderedFamilyCats: [FamilyCat] {
        let cats = familyCats
        let places = Dictionary(familyOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return cats.enumerated().sorted { a, b in
            (places[a.element.id] ?? Int.max, a.offset) < (places[b.element.id] ?? Int.max, b.offset)
        }.map { $0.element }
    }

    /// The page of this iPhone a family cat is linked to, if any.
    func linkedProfile(of cat: UUID) -> UUID? {
        snapshot.flatMap { FamilyNotebookCatLink.linkedProfile(cat, in: $0) }
    }

    /// The family cats while this iPhone is in the family. 11/15: after
    /// leaving (or the family ending) the kept copy stays for the notebook's
    /// own screens, but no page of another home's cat stays in この子.
    var activeFamilyCats: [FamilyCat] {
#if DEBUG
        if fixtureCats != nil { return familyCats }
#endif
        return hasFamily ? familyCats : []
    }

    // MARK: The same cat on this iPhone (11/15, FamilyNotebookCatLink)

    private static let linkAnswersKey = "familyNotebook.catLinkAnswered.v1"
    /// Asked and closed without an answer: not asked again until next launch.
    private var closedLinkQuestions = Set<UUID>()
    /// This iPhone's cats as この子 last drew them (their photos), for the
    /// question asked from the notebook too. Not saved.
    var deviceCats: [CatProfilePresentation] = []
#if DEBUG
    /// Review captures only: family cats without a notebook (sample names).
    private(set) var fixtureCats: [FamilyNotebookCatLink.Unlinked]?
    func useFixtureFamilyCats(_ names: [String], scenario: Int) {
        fixtureCats = names.enumerated().map { index, name in
            let id = UUID(uuidString: String(format: "FA417000-%04X-4000-8000-%012X", scenario & 0xFFFF, index))!
            let tool = UUID(uuidString: String(format: "FA417001-%04X-4000-8000-%012X", scenario & 0xFFFF, index))!
            return .init(id: id, toolID: tool, name: name)
        }
        // A family-shared 旅立った日 for the first cat (review capture only).
        if CommandLine.arguments.contains("--cat-home-stress-family-farewell"), let first = fixtureCats?.first,
           let day = Calendar.nekoGregorian.date(byAdding: .day, value: -20, to: Date()).flatMap({ CatCareDay(date: $0) }) {
            familyFarewellDays = ["tool-" + first.toolID.uuidString: day]
            CatFarewell.familyDays = familyFarewellDays
        }
        objectWillChange.send()
    }
#endif

    /// Family cats with no cat of this iPhone (each shows as its own page).
    /// Worked out when the notebook or 「この子のこと」 is read again, never
    /// per drawing (the この子 pages are drawn while they move).
    @Published private(set) var unlinkedCats: [FamilyNotebookCatLink.Unlinked] = []
    var unlinkedFamilyCats: [FamilyNotebookCatLink.Unlinked] {
#if DEBUG
        if let fixtureCats { return fixtureCats }
#endif
        return unlinkedCats
    }

    private func refreshUnlinked() {
#if DEBUG
        if fixtureCats != nil { return }
#endif
        var next: [FamilyNotebookCatLink.Unlinked] = []
        var order: [UUID] = []
        var farewells: [String: CatCareDay] = [:]
        if isReal, hasFamily, let snapshot {
            next = FamilyNotebookCatLink.unlinked(snapshot, care: CatCareStore.shared.state) { name(of: $0) }
            let cats = familyCats
            order = FamilyNotebookCatOrder.ordered(cats.map(\.id), in: snapshot)
            for cat in cats {
                guard let day = FamilyNotebookCatOrder.sharedFarewell(cat.id, in: snapshot) else { continue }
                // The key the page reads (CatHomeCat.farewellKey).
                if let profile = FamilyNotebookCatLink.linkedProfile(cat.id, in: snapshot) {
                    farewells[profile.uuidString] = day
                } else {
                    farewells["tool-" + cat.toolID.uuidString] = day
                }
            }
        }
        if next != unlinkedCats { unlinkedCats = next }
        if order != familyOrder { familyOrder = order }
        if farewells != familyFarewellDays {
            familyFarewellDays = farewells
            CatFarewell.familyDays = farewells
        }
    }

    /// 11/15: the family's order of its cats (FamilyNotebookCatOrder), and the
    /// 旅立った日 the family shared, by the key the page reads. Worked out when
    /// the notebook is read again, never per drawing.
    @Published private(set) var familyOrder: [UUID] = []
    @Published private(set) var familyFarewellDays: [String: CatCareDay] = [:]

    /// This iPhone's cats in their order (registration order), for the first
    /// places of the cats this person put into the notebook. Set by AppRootView.
    var profileOrder: [UUID] = [] {
        didSet { if profileOrder != oldValue { relinkOwnCats(); writeInitialPositions() } }
    }

    /// The first places, once per cat and iPhone (a ledger key), and only by
    /// the person who put the cat into the notebook (FamilyNotebookCatOrder).
    /// Local writes only; they go out with the next pass of the family.
    private func writeInitialPositions() {
        guard isReal, hasFamily, let store, let snapshot, let author = realAuthor, !profileOrder.isEmpty else { return }
        let first = FamilyNotebookCatOrder.initialPositions(snapshot, person: author.personID, profileOrder: profileOrder)
        guard !first.isEmpty else { return }
        let entries = first.map { item in
            FamilyNotebookImportEntry(ledgerKey: "position-init:" + item.cat.uuidString.lowercased(),
                                      target: .init(familyCatID: item.cat, field: .position),
                                      value: .integer(item.position), editedAt: Date())
        }
        _ = try? store.applyImport(.init(familyID: snapshot.familyID, entries: entries, mappings: []), author: author)
        reload()
    }

    /// 並べ替え: the family's cats in a new order. One operation per cat whose
    /// place changed, written together when the person finishes; sent by the
    /// person's own pass, not one call per move.
    func reorderFamilyCats(_ order: [UUID]) throws {
        guard isReal, hasFamily, let store, let snapshot, let author = realAuthor else { throw FamilySharingError.notAllowed }
        let known = Set(familyCats.map(\.id))
        guard Set(order) == known, order.count == known.count else { throw FamilySharingError.notAllowed }
        for item in FamilyNotebookCatOrder.positions(for: order, in: snapshot) {
            _ = try store.edit(target: .init(familyCatID: item.cat, field: .position), value: .integer(item.position), author: author)
        }
        reload()
        Task { _ = await SharingPersonAction.run { await FamilyNotebookSharing.shared.refresh() } }
    }

    /// Whether linking would keep the family's value over something this
    /// iPhone wrote differently (then the question asks once more).
    func linkReplacesOwnWriting(_ cat: UUID, profile: String) -> Bool {
#if DEBUG
        if fixtureCats != nil { return CommandLine.arguments.contains("--cat-home-stress-link-differs") }
#endif
        guard isReal, let snapshot, let id = UUID(uuidString: profile),
              let tool = FamilyNotebookCatLink.catMapping(cat, in: snapshot)?.toolCatID,
              let care = CatCareStore.shared.state else { return false }
        return FamilyNotebookCatLink.differs(care, toolCatID: tool, profile: id)
    }

    /// The family cat a cat of this iPhone is linked to, if any.
    func linkedFamilyCat(profile: String) -> UUID? {
        guard hasFamily, let snapshot, let id = UUID(uuidString: profile) else { return nil }
        return snapshot.activeMappings.first { $0.recordID == nil && $0.profileID == id }?.familyCatID
    }

    /// 「家族の手帳とのつながりを外す」 is offered for a cat this iPhone linked
    /// by an answer (never for the creator's own cats, which went in whole).
    func unlinkOffered(profile: String) -> Bool {
        guard isReal, let cat = linkedFamilyCat(profile: profile), let key = answerKey(cat) else { return false }
        return answeredLinks.contains(key)
    }

    /// Profiles already linked to a family cat.
    var linkedProfiles: Set<UUID> {
        guard hasFamily, let snapshot else { return [] }
        return FamilyNotebookCatLink.linkedProfiles(in: snapshot)
    }

    private var answeredLinks: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.linkAnswersKey) ?? [])
    }

    private func answerKey(_ cat: UUID) -> String? {
#if DEBUG
        if fixtureCats != nil { return "fixture:" + cat.uuidString.lowercased() }
#endif
        return snapshot.map { FamilyNotebookCatLink.answerKey(family: $0.familyID, cat: cat) }
    }

    /// The person answered for this family cat (same cat, or another cat):
    /// it is never asked again. Written once per answer, never while drawing.
    func rememberLinkAnswer(_ cat: UUID) {
        guard let key = answerKey(cat), !answeredLinks.contains(key) else { return }
        UserDefaults.standard.set(Array(answeredLinks.union([key])).sorted(), forKey: Self.linkAnswersKey)
        objectWillChange.send()
    }

    func closeLinkQuestion(_ cat: UUID) {
        closedLinkQuestions.insert(cat)
        objectWillChange.send()
    }

    /// The one family cat to ask about now: arrived, not answered, and this
    /// iPhone has a cat it could be.
    func pendingLinkQuestion(profiles: [String]) -> FamilyNotebookCatLink.Unlinked? {
        let linked = linkedProfiles
        guard profiles.contains(where: { UUID(uuidString: $0).map { !linked.contains($0) } ?? false }) else { return nil }
        let answered = answeredLinks
        return unlinkedFamilyCats.first { cat in
            !closedLinkQuestions.contains(cat.id) && !(answerKey(cat.id).map { answered.contains($0) } ?? true)
        }
    }

    /// The profile's birthday is copied into 「この子のこと」 (CatCareStore.
    /// importBirthdays), so a linked profile without one takes the family's
    /// day; an empty one would clear it for everyone. Set by AppRootView.
    var fillProfileBirthday: ((UUID, CatCareDay) async -> Void)?

    /// Links a family cat to a cat of this iPhone: one page from now on.
    func link(_ cat: UUID, toProfile profile: UUID) async throws {
#if DEBUG
        if fixtureCats != nil { rememberLinkAnswer(cat); return }
#endif
        guard isReal, hasFamily, let store, let snapshot, let author = realAuthor,
              let mapping = FamilyNotebookCatLink.catMapping(cat, in: snapshot), mapping.profileID == nil,
              let tool = mapping.toolCatID, CatCareStore.shared.canSave else { throw FamilySharingError.notAllowed }
        // The family's writing is in the record before this iPhone fills it.
        applyFamilyWrites()
        guard CatCareStore.shared.state?.record(catID: tool) != nil else { throw FamilyNotebookError.storageUnavailable }
        _ = try store.setLocalProfile(profile, forFamilyCat: cat)
        reload()
        // A normal save: what this iPhone had written goes into the notebook
        // the way any edit of a shared cat does (willSave, saveRealChanges).
        let saved = CatCareStore.shared.update { state in
            if let next = try? FamilyNotebookCatLink.linking(state, toolCatID: tool, profile: profile, now: Date()) { state = next }
        }
        guard saved, CatCareStore.shared.state?.record(catID: tool)?.profileID == profile else {
            _ = try? store.setLocalProfile(nil, forFamilyCat: cat)
            reload()
            throw FamilyNotebookError.storageUnavailable
        }
        // 預けるとき and 病院 of the cat go in as when a cat is added to the
        // notebook. If that fails, they join with their next edit.
        do {
            var handoff = CareHandoffStore.shared.loadError == nil ? CareHandoffStore.shared.plan : nil
            handoff?.cats.removeAll { $0.familyDetached == true || $0.profileID.flatMap(UUID.init(uuidString:)) != profile }
            let visits = try await VeterinaryVisitStore.shared.visits().filter { $0.catID == profile && $0.familyDetached != true }
            if !(handoff?.cats.isEmpty ?? true) || !visits.isEmpty, let current = try? store.snapshot() {
                let source = try FamilyNotebookMigrationSource(handoff: handoff?.cats.isEmpty == false ? handoff : nil, visits: visits)
                let prepared = try FamilyNotebookMigration.prepare(source: source, familyID: current.familyID,
                                                                   mappings: current.activeMappings)
                _ = try store.applyImport(prepared.plan, author: author)
            }
        } catch {}
        rememberLinkAnswer(cat)
        reload(); applyFamilyWrites()
        if let birthday = CatCareStore.shared.state?.record(catID: tool)?.birthday?.value ?? nil {
            await fillProfileBirthday?(profile, birthday)
        }
    }

    /// 「家族の手帳とのつながりを外す」: the family cat is its own page again;
    /// this iPhone's cat keeps its photos and a copy of what was written.
    func unlink(profile: String) throws {
        guard isReal, hasFamily, let store, let snapshot, let id = UUID(uuidString: profile),
              let mapping = snapshot.activeMappings.first(where: { $0.recordID == nil && $0.profileID == id }),
              let tool = mapping.toolCatID, CatCareStore.shared.canSave else { throw FamilySharingError.notAllowed }
        _ = try store.setLocalProfile(nil, forFamilyCat: mapping.familyCatID)
        let saved = CatCareStore.shared.update { state in
            if let next = try? FamilyNotebookCatLink.unlinking(state, toolCatID: tool, profile: id) { state = next }
        }
        guard saved, CatCareStore.shared.state?.record(catID: tool)?.profileID == nil else {
            _ = try? store.setLocalProfile(id, forFamilyCat: mapping.familyCatID)
            reload()
            throw FamilyNotebookError.storageUnavailable
        }
        // Unlinked on purpose: not asked about again.
        rememberLinkAnswer(mapping.familyCatID)
        reload()
    }

    /// Called after a service pass, including a failed network pass when a
    /// retained local copy is available. No prototype store is consulted.
    /// A background pass stays quiet; only a check the person asked for says
    /// that something could not be read (11/5).
    func attachReal(_ service: ProductionFamilyNotebookSharingService, reportsFailure: Bool = false) {
        guard isReal else { return }
        if let liveStore = service.notebook { store = liveStore }
        if let author = service.author { realAuthor = author }
        realMemberIDs = service.lastMembers.map(\.personID)
        realMemberNames = service.memberNames
        if let store, let author = realAuthor, let saved = try? store.snapshot(),
           let binding = try? FamilyNotebookLocalBinding(directory: store.localDirectory, support: AppRecordDataset.support,
               familyID: saved.familyID, deviceID: store.localDeviceID, author: author),
           let bytes = try? JSONEncoder().encode(binding),
           UserDefaults.standard.data(forKey: Self.bindingKey) != bytes {
            // Runs on open and every 5 s while a tool is shown: write only a
            // changed binding, never during scrolling (11/8).
            UserDefaults.standard.set(bytes, forKey: Self.bindingKey)
        }
        reload()
        guard hasFamily, let store, let snapshot, let author = realAuthor else { return }
        do {
            let mappings = try FamilyNotebookCatCareBridge.mappings(for: snapshot,
                existingLocalIDs: Set(CatCareStore.shared.state?.cats.map(\.catID) ?? []),
                person: author.personID, profiles: profileOrder)
            if mappings != snapshot.activeMappings { _ = try store.applyImport(.init(familyID: snapshot.familyID, entries: [], mappings: mappings), author: author) }
            reload(); applyFamilyWrites(reportsFailure: reportsFailure)
            relinkOwnCats()
            writeInitialPositions()
        } catch { if reportsFailure { message = "家族の手帳を開けませんでした。少し待ってから、もう一度お試しください。" } }
    }

    /// Explicit personal-to-family boundary. Only the selected tool cats and
    /// their text records are copied; photos and farewell dates are excluded.
    func sharePersonalCats(_ selected: Set<UUID>) async throws {
        guard isReal, hasFamily, let store, let snapshot, var care = CatCareStore.shared.state,
              CatCareStore.shared.canSave else { throw FamilySharingError.notAllowed }
        care.cats = care.cats.filter { selected.contains($0.catID) && $0.deletedAt == nil }
        guard Set(care.cats.map(\.catID)) == selected else { throw FamilyNotebookMigrationError.unreadableSource }
        let author = try writer()
        let profiles = Set(care.cats.compactMap(\.profileID))
        // 11/19: a cat this person already put in from the same page (a new
        // store on this iPhone) is that cat again, never a second one.
        let origins = FamilyNotebookCatOrigin.cats(in: snapshot, person: author.personID, profiles: Array(profiles))
        let mappings = Self.catMappings(snapshot.activeMappings, care: care, handoff: nil, visits: [], origins: origins)
        var handoff = CareHandoffStore.shared.loadError == nil ? CareHandoffStore.shared.plan : nil
        if var plan = handoff {
            plan.cats = plan.cats.filter { cat in
                selected.contains(cat.toolCatID ?? cat.id) || cat.profileID.flatMap(UUID.init(uuidString:)).map(profiles.contains) == true
            }
            handoff = plan
        }
        let visits = try await VeterinaryVisitStore.shared.visits().filter { selected.contains($0.catID) }
        let source = try FamilyNotebookMigrationSource(catCare: .init(state: care, unreadableCatCount: 0), handoff: handoff, visits: visits)
        let prepared = try FamilyNotebookMigration.prepare(source: source, familyID: snapshot.familyID, mappings: mappings)
        let relinked = try FamilyNotebookCatRelink.preserving(prepared.plan, previous: snapshot)
        let marked = FamilyNotebookCatOrigin.marking(relinked, previous: snapshot, person: author.personID)
        _ = try store.applyImport(marked, author: author)
        reload()
    }

    /// 11/19: a family cat this person put in from a page of this iPhone
    /// (FamilyNotebookCatOrigin) is that page, also when this iPhone's store
    /// started empty (a reinstall, a new iPhone) and the cat came back as the
    /// family's own page. What the page's own record has joins it as with
    /// 「同じ子」 (FamilyNotebookCatLink.linking); nothing is erased.
    private func relinkOwnCats() {
        guard isReal, hasFamily, let store, let snapshot, let author = realAuthor,
              !profileOrder.isEmpty, CatCareStore.shared.canSave else { return }
        let own = FamilyNotebookCatOrigin.cats(in: snapshot, person: author.personID, profiles: profileOrder)
        guard !own.isEmpty else { return }
        var changed = false
        for (profile, cat) in own.sorted(by: { $0.value.uuidString < $1.value.uuidString }) {
            guard let current = try? store.snapshot(), !FamilyNotebookCatLink.linkedProfiles(in: current).contains(profile),
                  let mapping = FamilyNotebookCatLink.catMapping(cat, in: current), mapping.profileID == nil,
                  let tool = mapping.toolCatID, CatCareStore.shared.state?.record(catID: tool)?.profileID == nil,
                  (try? store.setLocalProfile(profile, forFamilyCat: cat)) != nil else { continue }
            changed = true
        }
        if changed { reload(); applyFamilyWrites() }
        guard let current = self.snapshot else { return }
        for (profile, cat) in own {
            guard let mapping = FamilyNotebookCatLink.catMapping(cat, in: current), mapping.profileID == profile,
                  let tool = mapping.toolCatID, let care = CatCareStore.shared.state,
                  let record = care.record(catID: tool), record.deletedAt == nil,
                  record.profileID == nil || record.profileID == profile,
                  record.profileID == nil || care.cats.contains(where: { $0.profileID == profile && $0.deletedAt == nil && $0.catID != tool })
            else { continue }
            _ = CatCareStore.shared.update { state in
                if let next = try? FamilyNotebookCatLink.linking(state, toolCatID: tool, profile: profile, now: Date()) { state = next }
            }
            changed = true
        }
        if changed { reload() }
    }

    func unshareCat(_ cat: UUID) throws {
        guard isReal, hasFamily, let store, let snapshot,
              snapshot.activeMappings.contains(where: { $0.familyCatID == cat && $0.recordID == nil })
        else { throw FamilySharingError.notAllowed }
        _ = try store.edit(target: .init(familyCatID: cat, field: .sharingEnded), value: nil, author: writer(),
                           expectedRevision: snapshot.revision)
        reload()
    }

    private init() {
        if !isReal, let id = UserDefaults.standard.string(forKey: Self.familyKey).flatMap(UUID.init(uuidString:)) { open(id) }
        if isReal { openRealBinding() }
        CatCareStore.shared.willSave = { [weak self] before, after in
            guard let self, self.isReal, !self.applyingRemote else { return }
            try self.saveRealChanges(before, after)
        }
        CatCareStore.shared.didSave = { [weak self] before, after in self?.catCareDidSave(before, after) }
        readableObserver = NotificationCenter.default.addObserver(forName: .appRecordsReadableAgain, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.reopenIfUnread() }
        }
        notebookObserver = NotificationCenter.default.addObserver(forName: .appRecordsCommitted, object: nil, queue: nil) { [weak self] note in
            guard (note.object as? URL)?.lastPathComponent == "family-notebook.json" else { return }
            Task { @MainActor in
                guard let self else { return }
                self.reload(); self.applyFamilyWrites()
                // 11/16: written here and not sent yet (「この子のこと」, 病院,
                // 預けるとき): sent by the one schedule soon, also when the
                // page closes right after.
                if self.isReal, self.hasFamily, self.snapshot?.outbox.isEmpty == false {
                    FamilyNotebookAutoCheck.shared.sendSoon()
                }
            }
        }
    }

    private func openRealBinding() {
        do {
            if let binding = try FamilyNotebookLocalBinding.load(support: AppRecordDataset.support) {
                store = try .init(directory: binding.directory(support: AppRecordDataset.support), familyID: binding.familyID, deviceID: binding.deviceID)
                realAuthor = binding.author; reload()
                if snapshot != nil, message == Self.unreadMessage { message = nil }
            }
        } catch { message = Self.unreadMessage }
    }
    private static let unreadMessage = "家族の手帳を読み込めませんでした。少し待ってから、もう一度お試しください。"

    /// 11/19 (build 394): a launch only for the family's silent push, or one
    /// before the first unlock, may find the notebook unread: it was kept
    /// unread for the whole launch. Opened again here (the push, unlock);
    /// an open notebook is left as it is.
    func reopenIfUnread() {
        guard isReal, store == nil else { return }
        openRealBinding()
    }

    private static var root: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FamilyNotebookPrototype", isDirectory: true)
    }

    private static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: deviceKey) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: deviceKey)
        return id
    }

    private func open(_ familyID: UUID) {
        guard let root = Self.root else { return }
        do {
            store = try FamilyNotebookStore(directory: root.appendingPathComponent(familyID.uuidString.lowercased(), isDirectory: true),
                                            familyID: familyID, deviceID: Self.deviceID)
            reload()
        } catch {
            store = nil; snapshot = nil
            message = "家族の手帳を読み込めませんでした。少し待ってから、もう一度お試しください。"
        }
    }

    private func reload() {
        // Each background pass reads the notebook again; the same one is not
        // published again, so the open list is not redrawn for nothing (11/5).
        do { let next = try store?.snapshot(); if next != snapshot { snapshot = next } }
        catch { message = "家族の手帳を読み込めませんでした。少し待ってから、もう一度お試しください。" }
        refreshUnlinked()
    }

    // MARK: Making the family, and copying the tools in

    func create() async {
        guard !isReal else { return }
        guard !hasFamily else { return }
        let retainedFamilyID = snapshot?.familyID
        let familyID = UUID()
        open(familyID)
        guard store != nil else {
            if let retainedFamilyID { open(retainedFamilyID) }
            return
        }
        do {
            try await copyTools()
            for key in [Self.seenKey, Self.undoKey, Self.removedKey, Self.joinedKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            UserDefaults.standard.set(familyID.uuidString, forKey: Self.familyKey)
            markSeen()
        } catch {
            discard(familyID)
            if let retainedFamilyID { open(retainedFamilyID) }
            message = "「この子のこと」を家族の手帳に入れられませんでした。元の記録はそのままです。"
        }
    }

    /// Test builds only: what joining from an invitation will do. With no
    /// server the family is made here, and the inviter is the tried member.
    func join() async {
        guard !isReal else { return }
        guard !hasFamily else { return }
        await create()
        guard hasFamily else { return }
        UserDefaults.standard.set(true, forKey: Self.joinedKey)
        objectWillChange.send()
    }

    /// Copies what the notebook does not have yet: new cats, entries, visits
    /// and care plans. Safe to run again: nothing is copied twice, and a cat
    /// is linked by its tool ID and profile, never by its name.
    func copyTools() async throws {
        guard !isReal else { return } // Real sharing starts only with explicit cat selection.
        let catCare = CatCareStore.shared
        guard catCare.loadError == nil, catCare.unreadableCatCount == 0 else { throw FamilyNotebookMigrationError.unreadableSource }
        let care = catCare.state
        let handoff = CareHandoffStore.shared.loadError == nil ? CareHandoffStore.shared.plan : nil
        let visits = try await VeterinaryVisitStore.shared.visits()
        guard let store, let snapshot else { return }
        let source = try FamilyNotebookMigrationSource(
            catCare: care.map { CatCareDecoding.Result(state: $0, unreadableCatCount: 0) }, handoff: handoff, visits: visits)
        let mappings = Self.catMappings(snapshot.activeMappings, care: care, handoff: handoff, visits: visits)
        let prepared = try FamilyNotebookMigration.prepare(source: source, familyID: snapshot.familyID, mappings: mappings)
        try store.applyImport(prepared.plan, author: Self.me)
        reload()
    }

    /// One family cat per cat the tools know, reusing the links already made.
    /// `origins`: family cats this person put in from these pages, by page
    /// (FamilyNotebookCatOrigin): reused, never a new family cat.
    private static func catMappings(_ existing: [FamilyNotebookLocalMapping], care: CatCareState?,
                                    handoff: CareHandoffPlan?, visits: [VeterinaryVisit],
                                    origins: [UUID: UUID] = [:]) -> [FamilyNotebookLocalMapping] {
        var mappings = existing
        func link(_ toolID: UUID, profile: UUID?) {
            let known = mappings.contains { mapping in
                mapping.recordID == nil && (mapping.toolCatID == toolID || mapping.profileID == toolID
                    || (profile != nil && (mapping.profileID == profile || mapping.toolCatID == profile)))
            }
            guard !known else { return }
            if let profile, let cat = origins[profile],
               !mappings.contains(where: { $0.familyCatID == cat && $0.recordID == nil }) {
                mappings.append(.init(sourceKey: "cat:" + toolID.uuidString.lowercased(), familyCatID: cat,
                                      profileID: profile, toolCatID: toolID))
                return
            }
            mappings.append(.init(sourceKey: "cat:" + toolID.uuidString.lowercased(), familyCatID: UUID(),
                                  profileID: profile, toolCatID: toolID))
        }
        for cat in care?.cats ?? [] { link(cat.catID, profile: cat.profileID) }
        for cat in handoff?.cats ?? [] { link(cat.toolCatID ?? cat.id, profile: cat.profileID.flatMap(UUID.init(uuidString:))) }
        for visit in visits { link(visit.catID, profile: nil) }
        return mappings
    }

    /// All participants, including the payer, may leave. Keep the notebook
    /// and personal copy unchanged; a failed durable stop leaves it active.
    /// The retained family pointer reopens the stopped copy after a restart.
    func leavePrototypeFamily() throws {
        guard !isReal else { throw FamilySharingError.notAllowed }
        guard let store, let snapshot else { throw FamilySharingError.notAllowed }
        if snapshot.sharingEnded { return }
        self.snapshot = try store.endSharing(reason: .left)
    }

    /// Test builds only: end the tried family on this iPhone. What the test
    /// buttons changed in 「この子のこと」 is put back; nothing else is touched.
    /// Never the real leaving: that keeps this person's copy and is the
    /// sharing service's (FamilyNotebookSharing).
    func endPrototypeFamily() {
        guard !isReal else { return }
        guard let familyID = snapshot?.familyID else { return }
        undoTryouts()
        discard(familyID)
    }

    private func discard(_ familyID: UUID) {
        guard !isReal else { return }
        store = nil; snapshot = nil
        if UserDefaults.standard.string(forKey: Self.familyKey).flatMap(UUID.init(uuidString:)) == familyID {
            for key in [Self.familyKey, Self.seenKey, Self.undoKey, Self.removedKey, Self.joinedKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        if let directory = Self.root?.appendingPathComponent(familyID.uuidString.lowercased(), isDirectory: true) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: 「この子のこと」 → the notebook

    /// Every save of 「この子のこと」 (the page, its lists, what the tools fill
    /// in) goes into the notebook as the items that changed.
    private func catCareDidSave(_ before: CatCareState, _ after: CatCareState) {
        guard !applyingRemote, hasFamily, let store, let snapshot else { return }
        if isReal { reload(); return }
        do {
            let mappings = Self.catMappings(snapshot.activeMappings, care: after, handoff: nil, visits: [])
            let now = try Self.plan(after, family: snapshot.familyID, mappings: mappings)
            // New cats, new entries and newly filled items come in whole.
            try store.applyImport(now, author: Self.me)
            let then = try Self.plan(before, family: snapshot.familyID, mappings: now.mappings)
            var oldValues: [FamilyNotebookTarget: FamilyNotebookValue] = [:]
            for entry in then.entries { if let value = entry.value { oldValues[entry.target] = value } }
            let oldDeleted = Set(then.entries.filter { $0.target.field == nil }.map(\.target))
            for entry in now.entries {
                let current = try store.snapshot().fieldState(for: entry.target)
                if entry.target.field == nil {
                    guard !oldDeleted.contains(entry.target), current?.isDeleted != true else { continue }
                } else {
                    guard let value = entry.value, let old = oldValues[entry.target], old != value,
                          current?.operation.value != value else { continue }
                }
                do { try store.edit(target: entry.target, value: entry.value, author: Self.me) }
                catch FamilyNotebookError.deletedTarget { continue }
            }
            reload()
        } catch {
            // 「この子のこと」 itself is saved; only the notebook fell behind.
            message = "「この子のこと」の一部を家族の手帳に入れられませんでした。"
        }
    }

    private func saveRealChanges(_ before: CatCareState, _ after: CatCareState) throws {
        guard hasFamily, let store, let snapshot else {
            // If a retained binding exists but could not be opened, do not let
            // a personal save hide an unresolved shared edit.
            if self.snapshot == nil && (UserDefaults.standard.data(forKey: Self.bindingKey) != nil
                || UserDefaults.standard.data(forKey: FamilyNotebookLocalBinding.legacyKey) != nil) {
                throw FamilyNotebookError.storageUnavailable
            }
            return
        }
        // 11/16: the same for a linked cat and a family cat shown on its own
        // (FamilyNotebookCatCareBridge.localChanges, checked with two phones).
        let local = try FamilyNotebookCatCareBridge.localChanges(before, after, snapshot: snapshot)
        if let initial = local.initial { try store.applyImport(initial, author: writer()) }
        try store.applyLocalChanges(local.changes, author: writer())
        reload()
    }

    private static func plan(_ state: CatCareState, family: UUID,
                             mappings: [FamilyNotebookLocalMapping]) throws -> FamilyNotebookImportPlan {
        let source = try FamilyNotebookMigrationSource(catCare: CatCareDecoding.Result(state: state, unreadableCatCount: 0))
        return try FamilyNotebookMigration.prepare(source: source, familyID: family, mappings: mappings).plan
    }

    // MARK: The notebook → 「この子のこと」

    /// Puts what someone else wrote into 「この子のこと」, so every tool reads it.
    /// Your own writes are already there. When two people changed an item at
    /// once, the newer one is kept without asking, as in shared Notes; the
    /// other stays in the item's history. Background passes stay quiet: a
    /// failure is said only when the person asked (11/5: the alert repeated).
    func applyFamilyWrites(reportsFailure: Bool = false) {
        if isReal {
            guard hasFamily, let snapshot, let care = CatCareStore.shared.state, CatCareStore.shared.canSave else { return }
            do {
                let next = try FamilyNotebookCatCareBridge.apply(snapshot, to: care)
                applyingRemote = true; defer { applyingRemote = false }
                if next != care {
                    guard CatCareStore.shared.update(familyProjection: true, { $0 = next }) else { throw FamilyNotebookError.storageUnavailable }
                    familyWritesToCatCare += 1
                }
                try CareHandoffStore.shared.receiveFamilyChanges()
                Task {
                    do { try await VeterinaryVisitStore.shared.receiveFamilyChanges() }
                    catch { if reportsFailure { message = "家族が書いた診察メモを取り込めませんでした。少し待ってから、もう一度お試しください。" } }
                }
            } catch { if reportsFailure { message = "家族が書いた内容を「この子のこと」に取り込めませんでした。少し待ってから、もう一度お試しください。" } }
            return
        }
        guard hasFamily, let snapshot, let care = CatCareStore.shared.state,
              let here = try? Self.plan(care, family: snapshot.familyID, mappings: snapshot.activeMappings) else { return }
        var current: [FamilyNotebookTarget: FamilyNotebookValue] = [:]
        for entry in here.entries { if let value = entry.value { current[entry.target] = value } }
        var changes: [(UUID, FamilyNotebookField, FamilyNotebookValue, FamilyNotebookOperation)] = []
        for mapping in snapshot.activeMappings where mapping.recordID == nil {
            guard let toolID = mapping.toolCatID, care.record(catID: toolID) != nil else { continue }
            for field in Self.catFields {
                let target = FamilyNotebookTarget(familyCatID: mapping.familyCatID, field: field)
                guard let state = snapshot.fieldState(for: target), !state.isDeleted, let value = state.operation.value,
                      state.operation.author != Self.me, current[target] != value else { continue }
                changes.append((toolID, field, value, state.operation))
            }
        }
        guard !changes.isEmpty else { return }
        CatCareStore.shared.update(familyProjection: true) { state in
            for (toolID, field, value, operation) in changes {
                guard let index = state.cats.firstIndex(where: { $0.catID == toolID }) else { continue }
                Self.put(value, field, into: &state.cats[index], household: &state.household,
                         by: "family:" + operation.author.personID, at: operation.editedAt)
            }
        }
        familyWritesToCatCare += 1
    }

    private static func put(_ value: FamilyNotebookValue, _ field: FamilyNotebookField, into record: inout CatCareRecord,
                            household: inout CatCareHousehold, by author: String, at date: Date) {
        var text = ""
        if case let .text(written) = value { text = written }
        func stamp<Value: Codable & Equatable & Sendable>(_ value: Value) -> CatCareStamped<Value> { CatCareStamped(value: value, editedAt: date, editedBy: author) }
        switch field {
        case .name: record.name = stamp(text)
        case .coat: record.coat = stamp(text)
        case .marks: record.marks = stamp(text)
        case .microchip: record.microchip = stamp(text)
        case .conditions: record.conditions = stamp(text)
        case .specialDiet: record.specialDiet = stamp(text)
        case .water: record.water = stamp(text)
        case .litter: record.litter = stamp(text)
        case .temperament: record.temperament = stamp(text)
        case .sex: record.sex = stamp(CatCareSex(rawValue: text) ?? .unknown)
        case .neutered: record.neutered = stamp(CatCareTriState(rawValue: text) ?? .unknown)
        case .indoorOnly: record.indoorOnly = stamp(CatCareTriState(rawValue: text) ?? .unknown)
        case .adoptionDay:
            if value == .clear { record.adoptionDay = stamp(nil) }
            else if let date = try? FamilyNotebookAdoptionDate.decode(value), let day = CatCareDay(isoDay: date.day) {
                record.adoptionDay = stamp(.init(day: day, isApproximate: date.isApproximate))
            }
        case .birthday:
            var day: CatCareDay?
            if case let .day(written) = value {
                let parts = written.split(separator: "-").compactMap { Int($0) }
                if parts.count == 3 { day = CatCareDay(year: parts[0], month: parts[1], day: parts[2]) }
            }
            record.birthday = stamp(day)
        case .allergyStatus, .allergyText:
            var allergy = record.allergy?.value ?? CatCareAllergy()
            if field == .allergyStatus { allergy.status = CatCareAllergy.Status(rawValue: text) ?? .unknown } else { allergy.text = text }
            record.allergy = stamp(allergy)
        case .vetName, .vetPhone, .vetNote:
            // The page writes the household's vet; a cat with its own keeps its own.
            var vet = (record.vetOverride?.value ?? nil) ?? household.vet?.value ?? CatCareVet()
            switch field {
            case .vetName: vet.name = text
            case .vetPhone: vet.phone = text
            default: vet.note = text
            }
            if record.vetOverride != nil { record.vetOverride = stamp(Optional(vet)) } else { household.vet = stamp(vet) }
        default: break
        }
    }

    // MARK: Reading

    struct Record: Identifiable {
        let id: UUID
        let states: [FamilyNotebookField: FamilyNotebookFieldState]
        var latest: FamilyNotebookOperation? { states.values.map(\.operation).max { $0.version < $1.version } }
        func value(_ field: FamilyNotebookField) -> FamilyNotebookValue? { states[field]?.operation.value }
    }

    /// The cat's name here, or the one written on a visit or a care plan.
    private func name(of cat: UUID) -> String {
        if case let .text(text)? = state(cat, .name)?.operation.value, !text.isEmpty { return text }
        for collection in [FamilyNotebookCollection.handoff, .visit] {
            for record in records(cat, collection) {
                if case let .text(text)? = record.value(.catName), !text.isEmpty { return text }
            }
        }
        return "名前なし"
    }

    func state(_ cat: UUID, _ field: FamilyNotebookField) -> FamilyNotebookFieldState? {
        snapshot?.fieldState(for: .init(familyCatID: cat, field: field))
    }

    /// The same item, from 「この子のこと」's side (a tool cat ID).
    func state(toolCatID: UUID?, _ field: FamilyNotebookField) -> FamilyNotebookFieldState? {
        guard let toolCatID, let cat = snapshot?.mappings.first(where: { $0.recordID == nil && $0.toolCatID == toolCatID })?.familyCatID
        else { return nil }
        return state(cat, field)
    }

    /// The entries of one list (weights, visits, …) that are not deleted.
    func records(_ cat: UUID, _ collection: FamilyNotebookCollection) -> [Record] {
        guard let snapshot else { return [] }
        let operations = snapshot.operations.filter { $0.target.familyCatID == cat && $0.target.collection == collection }
        var seen = Set<UUID>()
        let ids = operations.compactMap(\.target.recordID).filter { seen.insert($0).inserted }
        return ids.compactMap { id -> Record? in
            let mine = operations.filter { $0.target.recordID == id }
            let parent = mine.first?.target.parentRecordID
            if snapshot.fieldState(for: .init(familyCatID: cat, collection: collection, recordID: id,
                                              parentRecordID: parent, field: nil))?.isDeleted == true { return nil }
            var states: [FamilyNotebookField: FamilyNotebookFieldState] = [:]
            for field in Set(mine.compactMap(\.target.field)) {
                states[field] = snapshot.fieldState(for: .init(familyCatID: cat, collection: collection, recordID: id,
                                                               parentRecordID: parent, field: field))
            }
            return states.isEmpty ? nil : Record(id: id, states: states)
        }
    }

    /// What others wrote lately, newest first, one line per item.
    var recentFromFamily: [FamilyNotebookOperation] {
        guard let snapshot else { return [] }
        var seen = Set<FamilyNotebookTarget>()
        // 11/15: a new order of the cats is not a written item.
        return Array(snapshot.operations.filter { !isMe($0.author) && $0.target.field != nil && $0.target.field != .position
                && !snapshot.unsharedCatIDs.contains($0.target.familyCatID) }
            .sorted { $0.version > $1.version }
            .filter { seen.insert($0.target).inserted }
            .prefix(5))
    }

    /// 「ミケ・接し方」
    func place(of operation: FamilyNotebookOperation) -> String {
        name(of: operation.target.familyCatID) + "・" + FamilyNotebookWords.label(operation.target.field ?? .note)
    }

    /// The family, you first. Like Apple's family and shared lists, nobody
    /// is labelled; who can do what shows only on a person's own page.
    private var realMemberNames: [String: String] = [:]
    var members: [FamilyNotebookAuthor] {
        if isReal {
            if realMemberIDs.isEmpty, let shown { return shown.members }
            return realMemberIDs.map { id in
                if id == realAuthor?.personID, let realAuthor { return realAuthor }
                return snapshot?.operations.filter { $0.author.personID == id }.max { $0.version < $1.version }?.author
                    ?? .init(personID: id, displayName: realMemberNames[id] ?? "家族の人")
            }
        }
        let removed = Set(UserDefaults.standard.stringArray(forKey: Self.removedKey) ?? [])
        var people = [Self.me]
        if joinedSomeonesFamily { people.append(Self.tryout) }
        for operation in snapshot?.operations ?? []
        where !people.contains(operation.author) && !removed.contains(operation.author.personID) {
            people.append(operation.author)
        }
        return people
    }

    /// The family as last shown, kept on this iPhone only, so the notebook
    /// opens in its own layout at once instead of a placeholder swapped out
    /// when the server answers (11/5 on 331: slow, then it jolted).
    private struct ShownFamily: Codable, Equatable {
        let familyID: UUID, personID: String, isPayer: Bool, members: [FamilyNotebookAuthor]
    }
    private static let shownKey = "familyNotebook.lastShown.v1"
    private var shown: ShownFamily? {
        guard isReal, hasFamily, let id = snapshot?.familyID, let me = realAuthor?.personID,
              let data = UserDefaults.standard.data(forKey: Self.shownKey),
              let value = try? JSONDecoder().decode(ShownFamily.self, from: data),
              value.familyID == id, value.personID == me else { return nil }
        return value
    }
    var lastShownMembership: FamilyMembership? { shown.map { FamilyMembership(role: $0.isPayer ? .payer : .member) } }
    /// Written only when something changed, after a pass, never while scrolling.
    func rememberShown(_ membership: FamilyMembership) {
        guard isReal, hasFamily, !realMemberIDs.isEmpty, let id = snapshot?.familyID, let me = realAuthor?.personID else { return }
        let value = ShownFamily(familyID: id, personID: me, isPayer: membership.role == .payer, members: members)
        guard value != shown, let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: Self.shownKey)
    }

    /// 11/19 (UI/UX 整理): the family stopped listing this person (taken out
    /// by the payer, or the family ended), not this iPhone's own leaving or
    /// ending. Said in one line on the notebook for a week from when this
    /// iPhone first saw it, instead of quietly showing 「家族の手帳を作る」.
    private static let endedNoticeKey = "familyNotebook.endedNotice.v1"
    static let endedNoticeDays = 7
    /// After a read that found this iPhone outside the family. Written once
    /// per family, never while drawing.
    func noteEndedNotice(now: Date = .now) {
        guard isReal, let snapshot, snapshot.sharingEnded, snapshot.endedReason == .absentFromDirectory else { return }
        let id = snapshot.familyID.uuidString.lowercased()
        if UserDefaults.standard.string(forKey: Self.endedNoticeKey)?.hasPrefix(id + "|") == true { return }
        UserDefaults.standard.set(id + "|" + String(Int(now.timeIntervalSince1970)), forKey: Self.endedNoticeKey)
    }
    var showsEndedNotice: Bool {
        guard isReal, let snapshot, snapshot.sharingEnded, snapshot.endedReason == .absentFromDirectory,
              let saved = UserDefaults.standard.string(forKey: Self.endedNoticeKey) else { return false }
        let parts = saved.split(separator: "|")
        guard parts.count == 2, parts[0] == snapshot.familyID.uuidString.lowercased(),
              let at = TimeInterval(parts[1]) else { return false }
        return Date.now.timeIntervalSince1970 - at < TimeInterval(Self.endedNoticeDays * 86_400)
    }

    /// Takes someone out of the family: what they wrote stays (test builds:
    /// the tried family member only).
    func removeMember(personID: String) {
        guard !isReal else { return }
        guard personID != Self.me.personID, !joinedSomeonesFamily else { return }
        let removed = (UserDefaults.standard.stringArray(forKey: Self.removedKey) ?? []) + [personID]
        UserDefaults.standard.set(removed, forKey: Self.removedKey)
        objectWillChange.send()
    }

    /// Someone else wrote after you last looked: a small dot on the tools tab.
    var hasNewFromFamily: Bool {
        guard hasFamily else { return false }
        let seen = UInt64(max(0, UserDefaults.standard.integer(forKey: currentSeenKey)))
        return snapshot?.operations.contains { !isMe($0.author) && $0.version.clock > seen } ?? false
    }

    func markSeen() {
        guard let clock = snapshot?.clock else { return }
        let next = Int(clamping: clock)
        guard UserDefaults.standard.integer(forKey: currentSeenKey) != next else { return }
        UserDefaults.standard.set(next, forKey: currentSeenKey)
        objectWillChange.send()
    }

    // MARK: Test buttons: what the family's writing will look like

    private struct Undo: Codable {
        let toolCatID: UUID
        let field: FamilyNotebookField
        let previous: FamilyNotebookValue?
        var written: [FamilyNotebookValue]
    }

    /// Another iPhone in the family writes one item; it arrives as shared and
    /// shows up in 「この子のこと」.
    func tryFamilyWrite() {
        guard !isReal else { return }
        guard let linked = firstLinkedCat() else { message = "「この子のこと」に猫がいないので試せません。"; return }
        let (cat, toolID) = linked
        let target = FamilyNotebookTarget(familyCatID: cat, field: .temperament)
        let value = FamilyNotebookValue.text("（試し）抱っこは短めに。夜はよく鳴きます")
        remember(toolID, .temperament, written: [value])
        let observed = snapshot?.operations.filter { $0.target == target }.map(\.id) ?? []
        arrive(target: target, value: value, observing: observed)
        applyFamilyWrites()
    }

    /// Two people change the same item at once, each without seeing the other.
    func tryConflict() {
        guard !isReal else { return }
        guard let linked = firstLinkedCat() else { message = "「この子のこと」に猫がいないので試せません。"; return }
        let (cat, toolID) = linked
        let target = FamilyNotebookTarget(familyCatID: cat, field: .litter)
        let mine = FamilyNotebookValue.text("（試し）砂は週に 1 回、全部かえる")
        let theirs = FamilyNotebookValue.text("（試し）砂は 2 週に 1 回、全部かえる")
        remember(toolID, .litter, written: [mine, theirs])
        let before = snapshot?.operations.filter { $0.target == target }.map(\.id) ?? []
        do { try store?.edit(target: target, value: mine, author: Self.me); reload() }
        catch { message = "試しの書き込みを入れられませんでした。"; return }
        arrive(target: target, value: theirs, observing: before)
        applyFamilyWrites()
    }

    private func firstLinkedCat() -> (UUID, UUID)? {
        guard let care = CatCareStore.shared.state else { return nil }
        for mapping in snapshot?.mappings ?? [] where mapping.recordID == nil {
            if let toolID = mapping.toolCatID, care.record(catID: toolID) != nil,
               state(mapping.familyCatID, .name)?.isDeleted != true { return (mapping.familyCatID, toolID) }
        }
        return nil
    }

    private func arrive(target: FamilyNotebookTarget, value: FamilyNotebookValue, observing: [UUID]) {
        guard let store, let snapshot else { return }
        let operation = FamilyNotebookOperation(
            familyID: snapshot.familyID, target: target, value: value,
            version: .init(clock: snapshot.clock + 1, deviceID: Self.tryoutDevice, operationID: UUID()),
            author: Self.tryout, editedAt: Date(), observedOperationIDs: observing)
        do {
            try store.receive([operation])
            try store.acknowledge(.init(familyID: snapshot.familyID, operationID: operation.id, version: operation.version))
            reload()
        } catch {
            message = "試しの書き込みを入れられませんでした。"
        }
    }

    /// Keeps what 「この子のこと」 said before a test button, to put it back.
    private func remember(_ toolID: UUID, _ field: FamilyNotebookField, written: [FamilyNotebookValue]) {
        var undos = loadUndos()
        if let index = undos.firstIndex(where: { $0.toolCatID == toolID && $0.field == field }) {
            undos[index].written += written
        } else {
            undos.append(Undo(toolCatID: toolID, field: field, previous: catCareValue(toolID, field), written: written))
        }
        if let data = try? JSONEncoder().encode(undos) { UserDefaults.standard.set(data, forKey: Self.undoKey) }
    }

    private func loadUndos() -> [Undo] {
        guard let data = UserDefaults.standard.data(forKey: Self.undoKey) else { return [] }
        return (try? JSONDecoder().decode([Undo].self, from: data)) ?? []
    }

    private func catCareValue(_ toolID: UUID, _ field: FamilyNotebookField) -> FamilyNotebookValue? {
        guard let snapshot, let care = CatCareStore.shared.state,
              let cat = snapshot.activeMappings.first(where: { $0.recordID == nil && $0.toolCatID == toolID })?.familyCatID,
              let plan = try? Self.plan(care, family: snapshot.familyID, mappings: snapshot.activeMappings) else { return nil }
        return plan.entries.first { $0.target == FamilyNotebookTarget(familyCatID: cat, field: field) }?.value
    }

    /// Only items still showing a test value go back; anything you wrote stays.
    private func undoTryouts() {
        guard !isReal else { return }
        let undos = loadUndos().filter { undo in catCareValue(undo.toolCatID, undo.field).map { undo.written.contains($0) } ?? false }
        guard !undos.isEmpty else { return }
        CatCareStore.shared.update { state in
            for undo in undos {
                guard let index = state.cats.firstIndex(where: { $0.catID == undo.toolCatID }) else { continue }
                Self.put(undo.previous ?? .clear, undo.field, into: &state.cats[index], household: &state.household,
                         by: state.deviceID, at: Date())
            }
        }
        familyWritesToCatCare += 1
    }
}

// MARK: - The notebook

struct FamilyNotebookView: View {
    @ObservedObject private var model = FamilyNotebookPrototype.shared
    @ObservedObject private var sharing = FamilyNotebookSharing.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.membershipAccess) private var access
    @State private var invites = false
    @State private var triesInvitation = false
    @State private var showsPlusOffer = false
    /// 「家族の手帳を作る」 led to Plus: once bought, go on to the name (11/6:
    /// without Plus, 作る ended in an alert with only 「閉じる」).
    @State private var createsAfterPlus = false
    /// 11/14 (family journey A3): 「Plusを始めて再開する」 led to Plus: once
    /// bought, 「わたしのPlusで再開する」 is done for the person (no second press).
    @State private var claimsAfterPlus = false
    @State private var boughtPlus = false
    /// 11/15: 「Plusをもう一度確かめる」 found Plus, but the family read after
    /// it still says sharing is stopped. Said in place of 「確認できました」.
    @State private var familyAwaitsPlus = false
    @State private var showsName = false
    /// 「家族の手帳から抜ける」 at the bottom of the notebook (11/7).
    @State private var confirmsLeave = false
    /// 「家族の手帳を終わりにする」, the payer's, under it (11/19).
    @State private var confirmsDissolve = false
    /// This iPhone sent a family photo report: 「通報への返答」 shows.
    @AppStorage(FamilyReportReplies.sentKey) private var sentPhotoReport = false
    @State private var showsCats = false
    /// The server's answer, or before it comes, the family as last shown here.
    private var shownMembership: FamilyMembership? {
        sharing.state.membership ?? (sharing.state == .checking ? model.lastShownMembership : nil)
    }
    /// The notebook shows: the family is known, or this iPhone is in it and
    /// the first read has not answered (its role then waits, 11/19).
    private var showsNotebook: Bool {
        shownMembership != nil || (sharing.state == .checking && model.hasFamily)
    }
    /// The newest of this person's own join requests, when it ended in the
    /// last week without joining.
    private var endedJoinNotice: String? {
        guard let latest = sharing.ownJoinResults.max(by: { $0.expiresAt < $1.expiresAt }),
              Date(timeIntervalSince1970: TimeInterval(latest.expiresAt)) > Date.now.addingTimeInterval(-7 * 86_400)
        else { return nil }
        switch latest.state {
        case .rejected: return "家族の手帳に参加できませんでした。招待した人に、もう一度確かめてください。"
        case .expired, .cancelled: return "参加の申し込みは終わりました。もう一度参加するには、新しい招待リンクを送ってもらってください。"
        case .pending, .approved: return nil
        }
    }

    private var presentsSheet: Bool { invites || triesInvitation || showsPlusOffer || showsName || showsCats }
    @State private var decliningRequest: FamilyNotebookJoinRequest?
    /// 「運営に知らせる」 on someone else's entry was pressed (11/14).
    @State private var reportsEntry = false
    @Environment(\.scenePhase) private var scenePhase
    /// The pressed 受け入れる/受け入れない, so only it says it is working (11/6).
    @State private var running: String?
    /// 「もう一度」 after 「つながりませんでした」 is running (11/6, 11/19).
    @State private var rechecking = false
    /// 11/16: 「もう一度」 under the unsent line is sending.
    @State private var resending = false
    /// The line was held, or 「もう一度」 did not get it sent: its code shows.
    @State private var showsSendCode = false

    private var prototypeInvitationAction: (@MainActor () -> Void)? {
#if DEBUG || INTERNAL_PRESENTATION
        guard !model.isReal else { return nil }
        return { triesInvitation = true }
#else
        return nil
#endif
    }
    @ToolbarContentBuilder private var closeToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
        // A change started here (or on a member's page, which closes first)
        // shows in the bar, never as a new row: rows here must not move (11/6).
        ToolbarItem(placement: .topBarTrailing) {
            if sharing.isWorking { ProgressView().accessibilityLabel("家族の手帳を変えています") }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                // One branch for the notebook whether the server answered yet
                // or not, so the list is not rebuilt when it does. 11/19 (UI/UX
                // 整理): a member whose role is not read yet (no family shown
                // before on this iPhone, a first read that failed, or right
                // after the 機種変更 switch) sees the notebook too, never
                // the left-copy text; only what needs the role waits.
                if showsNotebook {
                    notebook(shownMembership)
                } else {
                switch sharing.state {
                case .checking:
                    // A notebook this iPhone left or that ended: the checking
                    // state, never another home's cats for a moment.
                    if sharing.readFailed { checkFailedView } else { ProgressView() }
                case .leaving:
                    ProgressView()
                case .notInFamily:
                    // A join this person asked for ended without them, or the
                    // family stopped listing them: say so once it has, instead
                    // of quietly showing the intro (11/6, 11/19).
                    if let ended = endedJoinNotice ?? (model.showsEndedNotice ? FamilyNotebookWords.sharingEnded : nil) {
                        Label(ended, systemImage: "person.crop.circle.badge.xmark")
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 20).padding(.top, 12)
                            .accessibilityIdentifier("family-notebook-join-ended")
                    }
                    FamilyNotebookIntroView(creating: sharing.isWorking, create: {
                        if model.isReal, access.decision(for: .createOwnWindow) == .membershipRequired {
                            createsAfterPlus = true; showsPlusOffer = true
                        } else if model.isReal { showsName = true }
                        else { Task { if await sharing.perform({ try await sharing.service.createFamily(operationID: $0) }) { UsageCounter.shared.count(.familyCreated) } } }
                    }, tryInvitation: prototypeInvitationAction)
                    // 11/18: replies stay readable after leaving the family.
                    .safeAreaInset(edge: .bottom) {
                        if sentPhotoReport || FamilyReportReplies.showsFixture { FamilyReportRepliesRow() }
                    }
                case .pendingApproval:
                    // 11/19 (UI/UX 整理): the same words wherever it waits.
                    ContentUnavailableView(FamilyNotebookWords.awaitingApproval, systemImage: "hourglass")
                case .waitingForKeys:
                    ContentUnavailableView(FamilyNotebookWords.receiving, systemImage: "book.closed")
                case .inFamily:
                    EmptyView()
                }
                }
            }
            .navigationTitle("家族の手帳")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { closeToolbar }
            .sheet(isPresented: $invites) { FamilyNotebookInviteView() }
            .sheet(isPresented: $triesInvitation) { FamilyNotebookJoinView() }
            .sheet(isPresented: $showsName) {
                FamilyNotebookNameView {
                    showsName = false
                    Task { if await sharing.perform({ try await sharing.service.createFamily(operationID: $0) }) { UsageCounter.shared.count(.familyCreated) } }  // Usage (11/7)
                }
            }
            .sheet(isPresented: $showsCats) { FamilyNotebookCatSelectionView() }
            .sheet(isPresented: $showsPlusOffer, onDismiss: {
                NotificationCenter.default.post(name: .membershipAccessRefreshRequested, object: nil)
                let claims = claimsAfterPlus && boughtPlus
                let bought = boughtPlus
                claimsAfterPlus = false
                Task {
                    // 11/15: a purchase is read by the family at once, never
                    // dropped behind a background pass.
                    if bought { await sharing.refreshAfterPlusChange() } else { await sharing.refresh() }
                    if claims { await claimPayerAfterPurchase() }
                }
                if createsAfterPlus { createsAfterPlus = false; showsName = boughtPlus }
                boughtPlus = false
            }) {
                // ADR-027 5章: the same single subscription. Making a family says
                // so (11/7: the reason read like resuming); a paused one continues.
                MembershipOfferSheet(model: .live(), context: createsAfterPlus ? .createFamily : .continueFamily) { result in
                    boughtPlus = result == .completed
                    showsPlusOffer = false
                }
            }
            .alert("家族の手帳", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("閉じる", role: .cancel) {}
            } message: { Text(model.message ?? "") }
            .alert("家族の手帳", isPresented: Binding(get: { sharing.failure != nil }, set: { if !$0 { sharing.failure = nil } })) {
                // Making a family needs Plus: the way to it, not only 「閉じる」.
                if sharing.failure == .plusRequired {
                    Button("Plusについて") { createsAfterPlus = true; showsPlusOffer = true }
                }
                Button("閉じる", role: .cancel) {}
            } message: { Text(sharing.failure?.message ?? "") }
            .confirmationDialog(decliningTitle, isPresented: decliningPresented, titleVisibility: .visible,
                                presenting: decliningRequest, actions: decliningActions)
        }
        .onChange(of: sharing.isWorking) { _, working in if !working { running = nil } }
        // 11/15 (1115q): no loop of its own; the one schedule
        // (FamilyNotebookAutoCheck) reads 「参加を待っている人」 every 20 s and
        // the whole family every 60 s while this is open. An open sheet
        // (inviting, choosing cats) is not redrawn under the person (11/5).
        .onAppear {
            FamilyNotebookAutoCheck.shared.appeared(.notebook)
            // Test builds (the family on this iPhone alone) send nothing.
            if !model.isReal { Task { await sharing.refresh() } }
        }
        .onDisappear { FamilyNotebookAutoCheck.shared.disappeared(.notebook) }
        .onChange(of: presentsSheet, initial: true) { _, open in FamilyNotebookAutoCheck.shared.holdsRedraw = open }
        // 11/16: the notebook gone, nothing on screen waits for a sheet; a
        // hold left on would stop every automatic read until it opens again.
        .onDisappear { FamilyNotebookAutoCheck.shared.holdsRedraw = false }
        .onAppear { model.markSeen() }
        .onDisappear { model.markSeen() }
        // 11/19 (UI/UX 整理): 「同じ子ですか」 is asked by the この子 tab only,
        // not again when the notebook opens.
    }

    /// Who is in the family, and what they wrote lately (like the activity of
    /// a shared note). The writing itself lives in 「この子のこと」 and the tools.
    /// `membership` nil: this iPhone is in the family and its first read has
    /// not answered (11/19): inviting, leaving and a person's page wait for it.
    private func notebook(_ membership: FamilyMembership?) -> some View {
        List {
            // One state line at most (11/19 UI/UX 整理).
            if let pause = sharing.pause {
                pausedSection(pause)
            } else if sharing.showsUnsentLine {
                unsentSection
            } else if sharing.state == .checking && sharing.readFailed {
                checkFailedSection
            }
            Section {
                ForEach(model.members, id: \.personID) { member in
                    // A person's page only where something can be done there
                    // (the payer taking someone else out, 11/19); otherwise
                    // the row does not open an empty page.
                    if let membership, membership.canRemoveMember, !model.isMe(member) {
                        NavigationLink {
                            FamilyNotebookMemberView(member: member, membership: membership)
                        } label: {
                            Label(member.displayName, systemImage: "person.crop.circle.fill")
                        }
                    } else {
                        Label(member.displayName, systemImage: "person.crop.circle.fill")
                    }
                }
                // Everyone in the family invites (the family decision in #543),
                // while sharing goes on.
                if membership?.canInvite == true && sharing.pause == nil {
                    Button { invites = true } label: { Label("招待する", systemImage: "person.badge.plus") }
                        .accessibilityIdentifier("family-notebook-invite")
                }
            } header: {
                Text("家族")
            }
            // No footer here: on 332 its height flipped by 14px on every
            // redraw while the notebook loaded, and everything under 「招待する」
            // jolted (screen recording 11/5 21:39). The invite sheet already
            // says invited people are free.
            if model.isReal {
                Section("猫") {
                    ForEach(model.orderedFamilyCats) { cat in
                        FamilyNotebookSharedCatRow(name: cat.name, remove: {
                            do { try model.unshareCat(cat.id); Task { await sharing.refresh() } }
                            catch { sharing.failure = error as? FamilySharingError ?? .serviceUnavailable }
                        }) {
                            FamilyNotebookCatThumbnail(familyCat: cat.id, profile: model.linkedProfile(of: cat.id))
                        }
                    }
                    // Choosing which cats the notebook holds, not adding a new cat (11/7).
                    Button { showsCats = true } label: { Label("手帳に入れる猫を選ぶ", systemImage: "checklist") }
                        .accessibilityIdentifier("family-notebook-add-cat")
                }
                if !sharing.requests.isEmpty {
                    Section("参加を待っている人") {
                        ForEach(sharing.requests, id: \.id) { request in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(request.displayName)
                                HStack {
                                    Button { running = "受け入れる:\(request.id)"; decide(request, approve: true) } label: {
                                        WorkingLabel(title: "受け入れる", workingTitle: "返事をしています…",
                                                     working: running == "受け入れる:\(request.id)")
                                    }
                                    Button(role: .destructive) { decliningRequest = request } label: {
                                        WorkingLabel(title: "受け入れない", workingTitle: "返事をしています…",
                                                     working: running == "受け入れない:\(request.id)")
                                    }
                                }.buttonStyle(.bordered).disabled(sharing.isWorking)
                            }
                        }
                    }
                }
            }
            if !model.recentFromFamily.isEmpty {
                Section("最近の書き込み") {
                    ForEach(visibleRecentFromFamily) { operation in
                        LabeledContent {
                            Text(operation.editedAt.formatted(.dateTime.month(.defaultDigits).day()))
                        } label: {
                            Text(model.place(of: operation))
                            Text(operation.author.displayName)
                        }
                        .contextMenu {
                            // Hiding is local to this iPhone; nobody is told.
                            Button("この書き込みを表示しない", systemImage: "eye.slash") { hide(operation) }
                            // Review (11/14, 1.2): a way to tell us, through the same
                            // contact page as Settings. Nothing about the entry is sent.
                            if AppPublicLinksConfiguration.current.supportURL != nil {
                                Button("運営に知らせる", systemImage: "exclamationmark.bubble") { reportsEntry = true }
                            }
                        }
                    }
                    // Undo, in the same form as まど's 「表示しない・ブロックした人」.
                    if visibleRecentFromFamily.count < model.recentFromFamily.count {
                        NavigationLink {
                            FamilyHiddenOperationsView()
                        } label: {
                            Label("表示しない書き込み", systemImage: "eye.slash")
                        }
                        .accessibilityIdentifier("family-notebook-hidden-operations")
                    }
                }
            }
            // Leaving only the notebook, where the notebook is (11/7): it was
            // behind your own name, and Settings' row ends every window too.
            // 11/19 (UI/UX 整理): ending the family for everyone is here too,
            // under it (it was on the payer's own page): one place to end.
            if let membership, membership.canLeave {
                Section {
                    Button("家族の手帳から抜ける", role: .destructive) { confirmsLeave = true }
                        .disabled(sharing.isWorking)
                        .accessibilityIdentifier("family-notebook-leave")
                } footer: {
                    Text(FamilyNotebookWords.leaveDetail(payer: membership.role == .payer))
                }
                if membership.canDissolve {
                    Section {
                        Button("家族の手帳を終わりにする", role: .destructive) { confirmsDissolve = true }
                            .disabled(sharing.isWorking)
                            .accessibilityIdentifier("family-notebook-dissolve")
                    } footer: {
                        Text(FamilyNotebookWords.dissolveDetail)
                    }
                }
            }
            // 11/18: only on an iPhone that sent a family photo report.
            if sentPhotoReport || FamilyReportReplies.showsFixture {
                Section {
                    NavigationLink { FamilyReportRepliesView() } label: {
                        Label("通報への返答", systemImage: "exclamationmark.bubble")
                    }
                    .accessibilityIdentifier("family-notebook-report-replies")
                }
            }
#if DEBUG || INTERNAL_PRESENTATION
            if model.isReal { sendDiagnosticsSection }
            if !model.isReal { Section {
                DisclosureGroup("テスト用") {
                    Button("家族が書いたときを試す") { model.tryFamilyWrite() }
                    Button("2 人が同時に直したときを試す") { model.tryConflict() }
                    Button("家族（試し）がPlusを使っていて抜けたときを試す") {
                        prototype?.pretendPayerLeft(hasPlus: access.decision(for: .openGrowingSummary) == .allowed)
                        Task { await sharing.refresh() }
                    }
                }
            } footer: {
                Text("試した結果は、この画面のいちばん上に出ます。「家族が書いた」は「この子のこと」の接し方・トイレに（試し）の文が入ります。家族を終えると元に戻ります。")
            } }
#endif
        }
        .refreshable { if !sharing.isWorking { await sharing.refresh(reportsFailure: true) } }
        .alert("運営に知らせる", isPresented: $reportsEntry) {
            if let url = AppPublicLinksConfiguration.current.supportURL { Link("お問い合わせ", destination: url) }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text(FamilyNotebookWords.reportEntry)
        }
        // The only place to leave (11/7: your own page no longer offers it).
        .confirmationDialog("家族の手帳から抜けますか？", isPresented: $confirmsLeave, titleVisibility: .visible) {
            Button("抜ける", role: .destructive) {
                Task { await sharing.perform { _ = try await sharing.service.leaveFamily(operationID: $0) } }
            }
        }
        .confirmationDialog("家族の手帳を終わりにしますか？", isPresented: $confirmsDissolve, titleVisibility: .visible) {
            Button("終わりにする", role: .destructive) {
                Task { await sharing.perform { _ = try await sharing.service.dissolveFamily(operationID: $0) } }
            }
        }
    }

    /// 11/19 (UI/UX 整理): the read did not reach the family. One line and
    /// 「もう一度」, as 「通報への返答」 says it.
    private var checkFailedSection: some View {
        Section {
            Label("つながりませんでした", systemImage: "wifi.exclamationmark")
                .accessibilityIdentifier("family-notebook-check-failed")
            recheckButton
        }
    }

    /// The same, before anything of the notebook can show.
    private var checkFailedView: some View {
        ContentUnavailableView {
            Label("つながりませんでした", systemImage: "wifi.exclamationmark")
        } description: {
            EmptyView()
        } actions: {
            recheckButton
        }
        .accessibilityIdentifier("family-notebook-check-failed")
    }

    private var recheckButton: some View {
        Button {
            rechecking = true
            Task {
                defer { rechecking = false }
                // The person's own read (their call budget); the line says
                // the result, so no alert as well.
                await SharingPersonAction.run { _ = await sharing.refreshAfterPlusChange(reportsFailure: false) }
            }
        } label: {
            WorkingLabel(title: "もう一度", workingTitle: "確認しています…", working: rechecking)
        }
        .disabled(rechecking || sharing.isWorking)
        .accessibilityIdentifier("family-notebook-check-retry")
    }

    private var prototype: FamilyNotebookPrototypeSharing? { sharing.service as? FamilyNotebookPrototypeSharing }

    /// Entries this iPhone chose not to show. Kept here only; the family and
    /// the server never learn about it.
    @AppStorage("family.hiddenOperations.v1") private var hiddenOperationIDs = ""
    private var visibleRecentFromFamily: [FamilyNotebookOperation] {
        let hidden = Set(hiddenOperationIDs.split(separator: ",").map(String.init))
        return model.recentFromFamily.filter { !hidden.contains(String(describing: $0.id)) }
    }
    private func hide(_ operation: FamilyNotebookOperation) {
        var hidden = Set(hiddenOperationIDs.split(separator: ",").map(String.init))
        hidden.insert(String(describing: operation.id))
        hiddenOperationIDs = hidden.sorted().joined(separator: ",")
    }

    // Kept out of the body chain so the type checker stays fast.
    private var decliningTitle: String { "\(decliningRequest?.displayName ?? "")さんを受け入れませんか？" }
    private var decliningPresented: Binding<Bool> {
        Binding(get: { decliningRequest != nil }, set: { if !$0 { decliningRequest = nil } })
    }
    @ViewBuilder private func decliningActions(_ request: FamilyNotebookJoinRequest) -> some View {
        Button("受け入れない", role: .destructive) { running = "受け入れない:\(request.id)"; decide(request, approve: false) }
        Button("キャンセル", role: .cancel) {}
    }

    private func decide(_ request: FamilyNotebookJoinRequest, approve: Bool) {
        guard let real = sharing.service as? ProductionFamilyNotebookSharingService else { return }
        Task {
            // 11/15: the answered request leaves the list once the relay took
            // it; pressing a stale row again only finds it gone (staleRoster).
            if await sharing.perform({ try await real.decide(requestID: request.id, approve: approve, operationID: $0) }) {
                sharing.forgetRequest(request.id)
            }
        }
    }
}

extension FamilyNotebookView {
    /// 11/14 (family journey A3): after 「Plusを始めて再開する」 and a purchase,
    /// the same as pressing 「わたしのPlusで再開する」 — only when the family
    /// now offers it. Otherwise the section shows what it shows today
    /// (「Plusをもう一度確かめる」 while the family has not seen the Plus yet).
    private func claimPayerAfterPurchase() async {
        guard case let .noPayer(canClaim, handoverPending)? = sharing.pause,
              PlusPurchaseContinuation.claimsFamilyPayer(bought: true, canClaim: canClaim,
                                                         handoverPending: handoverPending)
        else { return }
        _ = await sharing.perform { try await sharing.service.claimPayer(operationID: $0) }
    }

    /// 11/15 (TestFlight 378): 「Plusをもう一度確かめる」 found Plus. Read the
    /// family again at once; the paused box goes when the family sees the
    /// Plus. If it still does not, say that, never 「確認できました」 under
    /// 「共有が止まっています」.
    private func recheckFamilyAfterPlus() async {
        familyAwaitsPlus = false
        guard await sharing.refreshAfterPlusChange() else { return }
        familyAwaitsPlus = PlusPurchaseContinuation.familyStillAwaitsPlus(
            pause: sharing.pause, hasPersonalPlus: access.hasPersonalPlus())
    }

    @ViewBuilder private var familyAwaitsPlusLine: some View {
        if familyAwaitsPlus {
            Text(FamilyNotebookWords.familyAwaitsPlus)
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("family-notebook-awaits-plus")
        }
    }

    /// 11/16: writing of this iPhone has not reached the family for a while
    /// (FamilyNotebookSendHealth). One line and 「もう一度」, nothing about why;
    /// gone once it is sent. Never while all is sent.
    private var unsentSection: some View {
        Section {
            Label("家族に届けられていない書き込みがあります。", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .accessibilityIdentifier("family-notebook-unsent")
                // Held: the code to tell support (no explanation on screen).
                .onLongPressGesture { showsSendCode = true }
            if showsSendCode {
                Text("コード：" + sharing.sendCode)
                    .font(.caption2).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("family-notebook-unsent-code")
            }
            Button {
                resending = true
                Task {
                    defer { resending = false }
                    await sharing.resendUnsent()
                    if sharing.showsUnsentLine { showsSendCode = true }
                }
            } label: {
                WorkingLabel(title: "もう一度", workingTitle: "もう一度", working: resending)
            }
            .disabled(resending || sharing.isWorking)
            .accessibilityIdentifier("family-notebook-unsent-retry")
        }
    }

#if DEBUG || INTERNAL_PRESENTATION
    /// Internal builds only (11/16): why this iPhone's writing last failed to
    /// go, when, and how much waits. The kind only; never in the App Store app.
    private var sendDiagnosticsSection: some View {
        Section {
            DisclosureGroup("テスト用：送信") {
                LabeledContent("未送信", value: "\(sharing.unsentCount)")
                LabeledContent("最後の失敗", value: sharing.sendHealth.last?.kind ?? "なし")
                if let at = sharing.sendHealth.last?.at {
                    LabeledContent("時刻", value: at.formatted(date: .numeric, time: .standard))
                }
                LabeledContent("続けて失敗", value: "\(sharing.sendHealth.failures)")
            }
            .accessibilityIdentifier("family-notebook-send-diagnostics")
        }
    }
#endif

    /// Shown while new writing does not reach the family (1029e). Everything
    /// written stays; only sharing stops. After the payer left, anyone with
    /// Plus may carry it on, and someone without Plus may start it.
    private func pausedSection(_ pause: FamilySharingPause) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("家族との共有が止まっています", systemImage: "pause.circle")
                    .font(.headline)
                Text(FamilyNotebookWords.pausedDetail(pause))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("family-notebook-paused")
            if case .payerPlusUnverified(isPayer: true) = pause {
                // The payer's own Plus lapsed: renewing it brings everyone back
                // (11/6: the notebook said it would come back by itself). This
                // iPhone shows Plus: check it again right here (11/7).
                if access.hasPersonalPlus() {
                    // One row whatever the check shows (11/15: the app quit around
                    // this check while rows came and went); the box goes as a whole.
                    VStack(alignment: .leading, spacing: 8) {
                        MembershipRestoreButton(title: "Plusをもう一度確かめる", look: .wide,
                                                identifier: "family-notebook-payer-restore", showsFound: false) {
                            Task { await recheckFamilyAfterPlus() }
                        }
                        familyAwaitsPlusLine
                    }
                } else {
                    Button { showsPlusOffer = true } label: {
                        Text("Plusを続けて再開する").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("family-notebook-payer-renew")
                }
            }
            if case let .noPayer(canClaim, handoverPending) = pause, !handoverPending {
                if canClaim {
                    Button {
                        Task { await sharing.perform { try await sharing.service.claimPayer(operationID: $0) } }
                    } label: {
                        Group {
                            if sharing.isWorking { ProgressView() } else { Text("わたしのPlusで再開する").font(.headline) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sharing.isWorking)
                    .accessibilityIdentifier("family-notebook-claim-payer")
                } else if access.hasPersonalPlus() {
                    // This iPhone has Plus but the family side does not see it yet:
                    // check it again right here, never the offer (11/5, 11/7).
                    // One row whatever the check shows (11/15: the app quit around
                    // this check while rows came and went); the box goes as a whole.
                    VStack(alignment: .leading, spacing: 8) {
                        MembershipRestoreButton(title: "Plusをもう一度確かめる", look: .wide,
                                                identifier: "family-notebook-restore-plus", showsFound: false) {
                            Task { await recheckFamilyAfterPlus() }
                        }
                        familyAwaitsPlusLine
                    }
                } else {
                    Button { claimsAfterPlus = true; showsPlusOffer = true } label: {
                        HStack(spacing: 8) {
                            Text("Plusを始めて再開する").font(.headline)
                            FamilyNotebookPlusMark()
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Plusを始めて再開する")
                    .accessibilityIdentifier("family-notebook-continue-plus")
                }
            }
            // 11/19 (UI/UX 整理): no footer; the one sentence above says it.
        }
    }
}

/// Sharing a farewell day with the family (1029h): only after this person
/// saw the cat, the day and what it means, and only what they saw. Saying
/// yes saves it for sending; it is never shown as delivered from that alone.
struct FamilyFarewellShareSheet: View {
    let toolCatID: UUID
    var changed: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var state: FamilyFarewellSharingState?
    @State private var preview: FamilyFarewellPreview?
    /// Kept until the outcome is known, so a retry is the same operation.
    @State private var consentOperation: UUID?
    @State private var revokeOperation: UUID?
    @State private var working = false
    @State private var errorMessage: String?
    @State private var confirmsRevoke = false
    /// The pressed button, so only it says it is working (11/6).
    @State private var running: String?

    private var service: any FamilyNotebookSharingService { FamilyNotebookSharing.shared.service }

    var body: some View {
        NavigationStack {
            Form {
                if let preview {
                    previewSections(preview)
                } else if let state {
                    stateSections(state)
                } else if errorMessage == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("旅立った日")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if preview != nil {
                        Button("戻る") { preview = nil; consentOperation = nil; errorMessage = nil }
                    } else {
                        Button("閉じる") { dismiss() }
                    }
                }
            }
            .confirmationDialog("この日付の共有をやめますか？", isPresented: $confirmsRevoke, titleVisibility: .visible) {
                Button("共有をやめる", role: .destructive) { running = "共有をやめる"; Task { await revoke() } }
            } message: {
                Text(state?.revocationExplanation ?? "")
            }
            .interactiveDismissDisabled(working)
            .onChange(of: working) { _, working in if !working { running = nil } }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func previewSections(_ preview: FamilyFarewellPreview) -> some View {
        Section {
            LabeledContent("猫", value: preview.catName)
            LabeledContent("旅立った日", value: FamilyNotebookWords.dayText(preview.day))
        } footer: {
            Text(preview.explanation)
        }
        if let current = preview.currentSharedDay, current != preview.day {
            Section {
                Text("いま家族の手帳には、\(preview.currentSharedAuthor?.displayName ?? "家族")が共有した\(FamilyNotebookWords.dayText(current))が出ています。共有すると、この日付に替わります。")
                    .font(.subheadline)
            }
        }
        Section {
            Button {
                Task { await consent(preview) }
            } label: {
                Group {
                    if working { ProgressView() } else { Text("共有する").font(.headline) }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(working)
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("family-farewell-consent")
        }
    }

    @ViewBuilder
    private func stateSections(_ state: FamilyFarewellSharingState) -> some View {
        Section {
            LabeledContent("このiPhoneの日付", value: state.localDay.map(FamilyNotebookWords.dayText) ?? "記録なし")
            if let shared = state.sharedDay {
                LabeledContent("家族の手帳", value: FamilyNotebookWords.dayText(shared))
            }
        } footer: {
            Text(FamilyNotebookWords.farewellDetail(state))
        }
        .accessibilityIdentifier("family-farewell-state")
        if state.localDay != nil, !state.hasConsentForLocalDay, !state.sharingPending {
            Section {
                Button {
                    running = "家族と共有する"
                    Task { await loadPreview() }
                } label: {
                    WorkingLabel(title: state.consentedDay == nil ? "家族と共有する" : "この日付を共有し直す",
                                 workingTitle: "準備しています…", working: running == "家族と共有する")
                }
                .disabled(working)
                .accessibilityIdentifier("family-farewell-share")
            }
        }
        if state.consentedDay != nil, !state.revocationPending {
            Section {
                Button(role: .destructive) { confirmsRevoke = true } label: {
                    WorkingLabel(title: "この日付の共有をやめる", workingTitle: "やめています…", working: running == "共有をやめる")
                }
                    .disabled(working)
                    .accessibilityIdentifier("family-farewell-revoke")
            } footer: {
                if state.mayAlreadyHaveBeenShared {
                    Text("すでに家族に届いているかもしれません。届いた日付は取り消せません。")
                }
            }
        }
    }

    private func load() async {
        do {
            state = try await FamilyNotebookSharing.waitingForCheck { try await service.loadFarewellSharing(toolCatID: toolCatID) }
        } catch {
            errorMessage = (error as? FamilySharingError ?? .serviceUnavailable).message
        }
    }

    private func loadPreview() async {
        // 1115s: the person's own action, outside the automatic budget.
        await SharingPersonAction.run {
            working = true; defer { working = false }
            errorMessage = nil
            do {
                preview = try await FamilyNotebookSharing.waitingForCheck { try await service.previewFarewellSharing(toolCatID: toolCatID) }
                consentOperation = nil
            } catch {
                errorMessage = (error as? FamilySharingError ?? .serviceUnavailable).message
            }
        }
    }

    private func consent(_ preview: FamilyFarewellPreview) async {
        // 1115s: the person's own action, outside the automatic budget.
        await SharingPersonAction.run {
            working = true; defer { working = false }
            errorMessage = nil
            let operation = consentOperation ?? UUID()
            consentOperation = operation
            do {
                try await service.consentToShareFarewell(previewID: preview.id, operationID: operation)
                consentOperation = nil
                self.preview = nil
                await finish()
            } catch {
                let failure = error as? FamilySharingError ?? .unknownOutcome
                // Unknown or not sent yet: the same operation next time. A changed
                // date or family needs a new look first.
                if failure == .farewellPreviewChanged { self.preview = nil }
                if failure.recovery != .retry && failure != .unknownOutcome { consentOperation = nil }
                errorMessage = failure.message
            }
        }
    }

    private func revoke() async {
        // 1115s: the person's own action, outside the automatic budget.
        await SharingPersonAction.run {
            working = true; defer { working = false }
            errorMessage = nil
            let operation = revokeOperation ?? UUID()
            revokeOperation = operation
            do {
                try await service.revokeFarewellSharing(toolCatID: toolCatID, operationID: operation)
                revokeOperation = nil
                await finish()
            } catch {
                let failure = error as? FamilySharingError ?? .unknownOutcome
                if failure.recovery != .retry && failure != .unknownOutcome { revokeOperation = nil }
                errorMessage = failure.message
            }
        }
    }

    /// Saved for sending; the family's state is read again, and that is
    /// what says whether it went.
    private func finish() async {
        await FamilyNotebookSharing.shared.refresh()
        await load()
        changed()
    }
}

/// One person's page, as in Apple's family settings: what can be done about
/// this person, and what happens. Leaving and ending the family are only at
/// the bottom of the notebook (11/7, 11/19: one place), so a page opens only
/// for the payer taking someone else out.
struct FamilyNotebookMemberView: View {
    let member: FamilyNotebookAuthor
    let membership: FamilyMembership
    @ObservedObject private var sharing = FamilyNotebookSharing.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirms = false
    @State private var selectedAction: Action?

    private enum Action: Hashable { case remove }

    private var isMe: Bool { FamilyNotebookPrototype.shared.isMe(member) }
    private var actions: [Action] {
        !isMe && membership.canRemoveMember ? [.remove] : []
    }

    private func title(_ action: Action) -> String {
        switch action {
        case .remove: "この人を手帳から外す"
        }
    }

    private func explanation(_ action: Action) -> String {
        switch action {
        case .remove: "この人がこれから書くことは、家族に届かなくなります。"
        }
    }

    private func question(_ action: Action) -> String {
        switch action {
        case .remove: "\(member.displayName)さんを家族の手帳から外しますか？"
        }
    }

    private func confirmation(_ action: Action) -> String {
        switch action {
        case .remove: "外す"
        }
    }

    /// Back to the notebook first, then the operation: its refresh replaces the
    /// list that opened this page, which must not happen under it (11/6). A
    /// failure shows on the notebook.
    private func run(_ action: Action) {
        let sharing = self.sharing
        let service = sharing.service
        let personID = member.personID
        dismiss()
        Task {
            await sharing.perform { operationID in
                switch action {
                case .remove: try await service.removeMember(personID: personID, operationID: operationID)
                }
            }
        }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(member.displayName).font(.title2.bold())
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            ForEach(actions, id: \.self) { action in
                Section {
                    Button(title(action), role: .destructive) { selectedAction = action; confirms = true }
                        .disabled(sharing.isWorking)
                } footer: {
                    Text(explanation(action))
                }
            }
        }
        .navigationTitle(member.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(selectedAction.map(question) ?? "", isPresented: $confirms, titleVisibility: .visible) {
            if let action = selectedAction, actions.contains(action) {
                Button(confirmation(action), role: .destructive) { run(action) }
            }
        }
    }
}

/// Before there is a family: what it is, in a sentence, and the button.
struct FamilyNotebookIntroView: View {
    var creating = false
    var create: (@MainActor () -> Void)?
    /// Test builds only: open an invitation as the invited person sees it.
    var tryInvitation: (@MainActor () -> Void)?
    @Environment(\.membershipAccess) private var access

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            // 11/12 (review 22): のわ looking in from a warm window, not the
            // gray people symbol. The cream keeps the black cat visible in dark mode.
            NekoPalette.cream
                .frame(width: 168, height: 112)
                .overlay(alignment: .bottom) {
                    Image("Nowa-peek")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(height: 82)
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityHidden(true)
            Text("家族の手帳").font(.title2.bold())
            Text("この子のこと・病院・預けるときを、\n一緒にお世話する人と共有できます。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button { create?() } label: {
                Group {
                    if creating {
                        ProgressView()
                    } else {
                        HStack(spacing: 8) {
                            Text("家族の手帳を作る").font(.headline)
                            FamilyNotebookPlusMark()
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(create == nil || creating)
            .accessibilityLabel(FamilyNotebookPlusMark.isShown(for: access) ? "家族の手帳を作る、Plus" : "家族の手帳を作る")
            Text("招待された人は無料です。")
                .font(.footnote).foregroundStyle(.secondary)
#if DEBUG || INTERNAL_PRESENTATION
            if let tryInvitation {
                Button("招待を受けたときを試す（テスト用）") { tryInvitation() }
                    .font(.footnote)
                    .accessibilityIdentifier("family-notebook-try-invitation")
            }
#endif
        }
        .padding(24)
    }
}

/// 「Plus」 on the button that needs it, the way apps mark a paid action.
/// Shown only when the same decision that gates the button says Plus is
/// needed. A member, even offline or while launch is still checking, does not
/// see it (11/5).
struct FamilyNotebookPlusMark: View {
    @Environment(\.membershipAccess) private var access

    static func isShown(for access: MembershipAccessContext, now: Date = .now) -> Bool {
        access.decision(for: .createOwnWindow, now: now) == .membershipRequired
    }

    var body: some View {
        if Self.isShown(for: access) {
            Text(verbatim: "Plus")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.white.opacity(0.25), in: Capsule())
                .accessibilityHidden(true)
        }
    }
}

/// What the invited person sees first: who asks, and for which cats. The
/// same card in the sending preview and on the invited iPhone.
struct FamilyNotebookInvitationCard: View {
    let from: String
    let cats: [String]

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 36))
                .foregroundStyle(.white)
                .accessibilityHidden(true)
                .frame(width: 76, height: 76)
                .background(Color.accentColor.gradient, in: Circle())
            Text("\(from)から、家族の手帳への招待").font(.headline).multilineTextAlignment(.center)
            if !cats.isEmpty {
                Text(cats.joined(separator: "・")).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .combine)
    }
}

/// Inviting, as with TimeTree or a shared note: a link sent by Messages or
/// LINE. Nothing can be sent before the family works between iPhones, so
/// this shows the invitation as it will arrive.
struct FamilyNotebookInviteView: View {
    static func inviteMessage(cats: [String]) -> String {
        let who = cats.isEmpty ? "うちの猫" : cats.joined(separator: "・")
        return "ねこのまどの家族の手帳で、\(who)のことを一緒に書こう。このリンクから参加してね。"
    }

    @ObservedObject private var model = FamilyNotebookPrototype.shared
    @ObservedObject private var sharing = FamilyNotebookSharing.shared
    @Environment(\.dismiss) private var dismiss
    @State private var invitation: FamilyInvitation?
    /// 11/14 (family journey A5): one press makes the link and opens the
    /// share sheet once it is ready; the button shows progress meanwhile.
    @State private var creating = false
    @State private var sharesInvitation = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                FamilyNotebookInvitationCard(from: "あなた", cats: model.catNames)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Spacer()
                Button(action: send) {
                    Group {
                        if creating { ProgressView() } else {
                            Label("招待を送る", systemImage: "square.and.arrow.up").font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!sharing.service.sendsInvitations || (sharing.isWorking && !creating))
                .accessibilityIdentifier("family-notebook-send-invitation")
                if sharing.service.sendsInvitations {
                    // 11/14 (A4): the server's 24 hours (migration 0055).
                    Text(GroupWindowPresentation.invitationLifetimeCaption)
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("family-notebook-invitation-lifetime")
                }
                // 11/19 (UI/UX 整理): that invited people are free is said
                // before making the notebook and on the invitation itself.
                if !sharing.service.sendsInvitations {
                    Text("試作のため、まだ送れません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("招待する")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            // A line beside the link, as for a まど: a bare URL said nothing
            // about what it was (11/6). The same system sheet as a まど's.
            .sheet(isPresented: $sharesInvitation) {
                if let invitation {
                    GroupInvitationShareSheet(
                        item: invitation.link.absoluteString,
                        message: FamilyNotebookInviteView.inviteMessage(cats: model.catNames),
                        completedUsage: .familyInviteShared
                    ) { sharesInvitation = false }
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
                }
            }
            // The notebook's own error, here: the notebook is under this sheet.
            .alert("家族の手帳", isPresented: Binding(get: { sharing.failure != nil && !sharesInvitation },
                                                  set: { if !$0 { sharing.failure = nil } })) {
                Button("閉じる", role: .cancel) {}
            } message: { Text(sharing.failure?.message ?? "") }
        }
    }

    /// Makes the link on the first press and shares it when it is ready; a
    /// press while it is being made does nothing (FamilyInviteSendTap).
    private func send() {
        let hasInvitation = invitation.map { $0.expiresAt > Date.now } ?? false
        switch FamilyInviteSendTap.action(isCreating: creating, hasInvitation: hasInvitation) {
        case .ignore:
            return
        case .share:
            sharesInvitation = true
        case .create:
            creating = true
            Task {
                defer { creating = false }
                let service = sharing.service
                var made: FamilyInvitation?
                // A failure is kept in `sharing.failure` and shown above; the
                // screen stays as it was.
                // 11/15: the share sheet opens as soon as the link exists; the
                // whole-family read that followed (sync included) is left to
                // the notebook's next pass, since a link changes nothing shown.
                await sharing.perform(readsAfter: false) { made = try await service.createInvitation(operationID: $0) }
                guard let made else { return }
                invitation = made
                sharesInvitation = true
            }
        }
    }
}

/// 11/14 (family journey A5): what one press on 「招待を送る」 does.
enum FamilyInviteSendTap: Equatable {
    case ignore, create, share

    static func action(isCreating: Bool, hasInvitation: Bool) -> Self {
        if isCreating { return .ignore }
        return hasInvitation ? .share : .create
    }
}

/// Opening an invitation: who asks and for which cats, then 参加する. One
/// family at a time, as in Apple's family sharing. Joining is free.
struct FamilyNotebookJoinView: View {
    var link: URL? = nil
    /// Joined from a link: the caller opens the notebook after this sheet.
    var onJoined: (() -> Void)? = nil
    @ObservedObject private var sharing = FamilyNotebookSharing.shared
    @Environment(\.dismiss) private var dismiss
    @State private var preview: FamilyInvitationPreview?
    @State private var result: FamilyJoinResult?
    @State private var displayName = GroupDisplayName.remembered
    /// The keyboard goes away when 「参加する」 is pressed, so the progress shows (11/6).
    @FocusState private var typingName: Bool

    private var inFamily: Bool { sharing.state.membership != nil }
    /// The link is verified to be another family's than this iPhone's (both
    /// family IDs read on this iPhone, 11/19). Unknown is not another's.
    private var otherFamilyLink: Bool {
        guard let link, let linked = try? FamilyNotebookInvitationCapability(url: link).familyID,
              let own = FamilyNotebookPrototype.shared.snapshot?.familyID, FamilyNotebookPrototype.shared.hasFamily
        else { return false }
        return linked != own
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()
                if let preview {
                    FamilyNotebookInvitationCard(from: preview.inviterName, cats: preview.catNames)
                } else {
                    ProgressView()
                }
                Text("この子のこと・病院・預けるときを、一緒に書きます。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Spacer()
                if let prior = preview?.priorRequestState, ["rejected", "cancelled", "expired"].contains(prior), result == nil {
                    Text("この招待では参加できません。新しい招待リンクを送ってもらってください。")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else if result == .pendingApproval || result == .waitingForKeys
                            || (result == nil && (preview?.priorRequestState == "pending" || sharing.state == .pendingApproval)) {
                    // Sent is not joined: say what it is waiting for, in the
                    // notebook's words (11/19 UI/UX 整理).
                    Text(result == .waitingForKeys ? FamilyNotebookWords.receiving : FamilyNotebookWords.awaitingApproval)
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("閉じる") { dismiss() }
                } else if inFamily && !otherFamilyLink {
                    // 11/19 (UI/UX 整理): a member opening their own family's
                    // link (or one not known to be another's) is never sent
                    // toward leaving: the notebook is where they already are.
                    Text(FamilyNotebookWords.alreadyInThisFamily)
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .accessibilityIdentifier("family-notebook-already-in")
                    Button { onJoined?(); dismiss() } label: {
                        Text("手帳を開く").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("family-notebook-open-own")
                } else if inFamily {
                    Text(FamilySharingError.alreadyInFamily.message)
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else {
                    if sharing.service.sendsInvitations {
                        // 11/15: the name is filled in already, so the hint
                        // never showed and it read as the notebook's name. The
                        // same heading as the まど's join screen.
                        VStack(alignment: .leading, spacing: 6) {
                            Text("あなたの名前").font(.subheadline.weight(.semibold))
                            TextField("家族に表示するあなたの名前", text: VisibleTextInput.binding($displayName))
                                .textFieldStyle(.roundedBorder)
                                .focused($typingName)
                                .disabled(sharing.isWorking)
                                .accessibilityLabel("あなたの名前")
                                .accessibilityIdentifier("family-notebook-display-name")
                            Text("家族に表示されます。").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        typingName = false
                        guard let preview else { return }
                        if sharing.service.sendsInvitations {
                            guard let name = try? GroupWire.name(displayName) else { return }
                            GroupDisplayName.remember(name)
                        }
                        Task {
                            let service = sharing.service
                            var joined: FamilyJoinResult?
                            await sharing.perform { joined = try await service.join(preview, operationID: $0) }
                            result = joined
                            if joined == .joined { onJoined?(); dismiss() }
                        }
                    } label: {
                        Group { if sharing.isWorking { ProgressView() } else { Text("参加する").font(.headline) } }
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sharing.isWorking || preview == nil || (sharing.service.sendsInvitations && (try? GroupWire.name(displayName)) == nil))
                    .accessibilityIdentifier("family-notebook-join")
                    Text("参加は無料です。").font(.footnote).foregroundStyle(.secondary)
                    GroupWindowStandardsAgreement(action: "参加する", isFamilyNotebook: true)
                }
                if result == nil && !(inFamily && !otherFamilyLink) {
                    Button("今はやめておく") { dismiss() }
                        .disabled(sharing.isWorking)
                }
            }
            .padding(24)
            .navigationTitle("招待")
            .navigationBarTitleDisplayMode(.inline)
            .alert("招待", isPresented: Binding(get: { sharing.failure != nil }, set: { if !$0 { sharing.failure = nil } })) {
                Button("閉じる", role: .cancel) {}
            } message: { Text(sharing.failure?.message ?? "") }
        }
        .task {
            // 1115s: opening the invitation link is the person's own action.
            await SharingPersonAction.run {
                await sharing.refresh()
                do { preview = try await sharing.service.previewInvitation(link) }
                catch {
                    // Already waiting, or already in this family: the used link
                    // is not an error to this person (11/19).
                    if sharing.state != .pendingApproval && !(inFamily && !otherFamilyLink) {
                        sharing.failure = error as? FamilySharingError ?? .serviceUnavailable
                    }
                }
            }
        }
    }
}

struct FamilyNotebookNameView: View {
    let confirmed: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = GroupDisplayName.remembered
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("あなたの名前", text: VisibleTextInput.binding($name))
                } footer: { Text("書いた人の名前として、家族に表示されます。") }
                Button("この名前で手帳を作る") {
                    guard let valid = try? GroupWire.name(name) else { return }
                    GroupDisplayName.remember(valid); confirmed()
                }.disabled((try? GroupWire.name(name)) == nil)
                GroupWindowStandardsAgreement(action: "この名前で手帳を作る", isFamilyNotebook: true)
            }
            .navigationTitle("家族で使う名前")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } } }
        }
    }
}

struct FamilyNotebookCatSelectionView: View {
    @ObservedObject private var model = FamilyNotebookPrototype.shared
    @ObservedObject private var care = CatCareStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var saving = false
    @State private var failed = false
    /// Fixed while the sheet is open, so a cat being shared does not drop out
    /// of the list under the person's finger (11/5: the list jumped).
    @State private var shown: [CatCareRecord]?
    /// 11/15: a chosen cat with the name of a family cat not on this iPhone:
    /// 「家族の手帳の「むぎ」」 / 「このiPhoneの子と同じですか。」 before anything is added.
    @State private var sameNameQuestion: SameName?
    @State private var linkedCats: [UUID: UUID] = [:]
    /// 「べつの子」, by chosen cat: the family cats it is not (11/19: one of
    /// several of the same name, so the next one is asked about).
    @State private var answeredDifferent: [UUID: Set<UUID>] = [:]
    struct SameName: Identifiable {
        let record: CatCareRecord
        let family: FamilyNotebookCatLink.Unlinked
        var id: UUID { record.catID }
    }
    private var available: [CatCareRecord] {
        let linked = Set(model.familyCats.map(\.toolID))
        return (care.state?.cats ?? []).filter { $0.deletedAt == nil && !linked.contains($0.catID) }
    }
    var body: some View {
        NavigationStack {
            Group {
                if let shown, shown.isEmpty {
                    ContentUnavailableView("追加できる猫はいません", systemImage: "cat",
                        description: Text("「この子」タブの「この子を追加」で猫を増やすと、ここから追加できます。"))
                        .accessibilityIdentifier("family-notebook-no-cats")
                } else {
                    selection(shown ?? available)
                }
            }
            .navigationTitle("手帳に入れる猫")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() }.disabled(saving) }
                // The action says what the title asks for (11/5: 「家族と共有する」
                // under 「追加する猫を選ぶ」 read as a different step; 11/19:
                // 「手帳に入れる猫」 / 「決める」).
                if shown?.isEmpty == false {
                    ToolbarItem(placement: .confirmationAction) {
                        if saving { ProgressView() }
                        else { Button("決める", action: add).disabled(selected.isEmpty || !care.canSave) }
                    }
                }
            }
            .alert("追加できませんでした", isPresented: $failed) { Button("閉じる", role: .cancel) {} }
                message: { Text("少し待ってから、もう一度お試しください。") }
            // 11/19 (UI/UX 整理): the same question as the この子 tab's.
            .alert(sameNameQuestion.map { "家族の手帳の「" + $0.family.name + "」" } ?? "",
                   isPresented: Binding(get: { sameNameQuestion != nil }, set: { if !$0 { sameNameQuestion = nil } }),
                   presenting: sameNameQuestion) { question in
                Button("同じ子") { answer(question, same: true) }
                Button("べつの子") { answer(question, same: false) }
                Button("キャンセル", role: .cancel) { saving = false }
            } message: { _ in
                Text(FamilyNotebookWords.sameChildQuestion)
            }
        }
        .onAppear { if shown == nil { shown = available } }
    }

    /// The next chosen cat with a family cat's name, not answered yet.
    private func nextSameName() -> SameName? {
        let unlinked = model.unlinkedFamilyCats.filter { cat in !linkedCats.values.contains(cat.id) }
        for record in (shown ?? available) where selected.contains(record.catID) && linkedCats[record.catID] == nil {
            guard record.profileID != nil,
                  let family = FamilyNotebookCatLink.sameName(record.name?.value ?? "", in: unlinked,
                                                              skipping: answeredDifferent[record.catID] ?? []) else { continue }
            return SameName(record: record, family: family)
        }
        return nil
    }

    private func answer(_ question: SameName, same: Bool) {
        sameNameQuestion = nil
        if same { linkedCats[question.record.catID] = question.family.id }
        else { answeredDifferent[question.record.catID, default: []].insert(question.family.id) }
        add()
    }

    private func selection(_ cats: [CatCareRecord]) -> some View {
        List {
            Section {
                ForEach(cats) { cat in
                    Toggle(isOn: Binding(
                        get: { selected.contains(cat.catID) },
                        set: { if $0 { selected.insert(cat.catID) } else { selected.remove(cat.catID) } })) {
                        HStack(spacing: 12) {
                            FamilyNotebookCatThumbnail(familyCat: nil, profile: cat.profileID)
                            Text(cat.name?.value ?? "名前なし")
                        }
                    }
                }
            } footer: {
                Text("選んだ猫の「この子のこと」と、病院・預けるときに書いたことを家族と共有します。")
            }
        }
        .disabled(saving)
    }

    private func add() {
        saving = true
        if let question = nextSameName() { sameNameQuestion = question; return }
        Task {
            do {
                // 「同じ子」: linked to the family cat, never a second one.
                for (record, family) in linkedCats {
                    guard let profile = shown?.first(where: { $0.catID == record })?.profileID else { continue }
                    try await model.link(family, toProfile: profile)
                }
                let rest = selected.subtracting(linkedCats.keys)
                if !rest.isEmpty { try await model.sharePersonalCats(rest) }
                await FamilyNotebookSharing.shared.refresh(); dismiss()
            } catch { failed = true }
            saving = false
        }
    }
}

/// 11/19: a cat's photo in the notebook's lists, so two cats of one name can
/// be told apart: this iPhone's own photo of a cat of this iPhone, else the
/// family's photo (FamilyRepresentativePhotos, only while it is on), else
/// the plain cat. Shown only; no words.
struct FamilyNotebookCatThumbnail: View {
    let familyCat: UUID?
    let profile: UUID?
    @ObservedObject private var model = FamilyNotebookPrototype.shared
    @ObservedObject private var photos = FamilyRepresentativePhotos.shared

    var body: some View {
        Group {
            if let cover = ownCover {
                CatProfileThumbnail(photo: cover)
            } else if let shown = familyPhoto {
                Image(uiImage: shown.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            } else {
                CatProfileThumbnail(photo: nil)
            }
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
        .task(id: familyCat) {
            guard let familyCat, ownCover == nil, photos.isOn else { return }
            await photos.read([familyCat])
        }
    }

    private var ownCover: CatProfilePhotoPresentation? {
        guard let profile else { return nil }
        return model.deviceCats.first { $0.identifier == profile.uuidString }?.coverPhoto
    }

    private var familyPhoto: FamilyRepresentativePhotos.Shown? {
        guard let familyCat, photos.isOn else { return nil }
        return photos.shown[familyCat]
    }
}

/// 11/15: 「家族の手帳の「むぎ」」 / 「このiPhoneの子と同じですか。」, this
/// iPhone's cats with their photos (the same name first) and 「べつの子」.
/// Asked once per family cat; an answer is never asked again.
struct FamilyNotebookLinkQuestionView: View {
    let cat: FamilyNotebookCatLink.Unlinked
    let cats: [CatProfilePresentation]
    let choose: (CatProfilePresentation) -> Void
    let other: () -> Void
    @ObservedObject private var model = FamilyNotebookPrototype.shared
    @Environment(\.dismiss) private var dismiss
    /// 11/15: the chosen cat has writing that differs from the family's:
    /// asked once more before the family's is kept.
    @State private var confirming: CatProfilePresentation?

    private func pick(_ profile: CatProfilePresentation) {
        if model.linkReplacesOwnWriting(cat.id, profile: profile.identifier) { confirming = profile } else { choose(profile) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(cats) { profile in
                        Button { pick(profile) } label: {
                            HStack(spacing: 14) {
                                CatProfileThumbnail(photo: profile.coverPhoto)
                                    .frame(width: 52, height: 52)
                                    .accessibilityHidden(true)
                                Text(profile.displayName)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .accessibilityLabel(profile.displayName + "と同じ子")
                        .accessibilityIdentifier("family-link-same")
                    }
                } header: {
                    Text("このiPhoneの子と同じですか。")
                        .font(.body)
                        .foregroundStyle(.primary)
                        .textCase(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    Button("べつの子") { other() }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("family-link-other")
                }
            }
            .navigationTitle("家族の手帳の「" + cat.name + "」")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .alert("このiPhoneに書いたことは、家族の手帳の内容に合わせます。",
                   isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                   presenting: confirming) { profile in
                Button("つなぐ") { confirming = nil; choose(profile) }
                    .accessibilityIdentifier("family-link-confirm")
                Button("やめる", role: .cancel) { confirming = nil }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("family-link-question")
    }
}

/// The toolbar button on 「この子のこと」: the way into the family notebook,
/// out of the way for anyone who keeps it to themselves (test builds only).
struct FamilyNotebookButton: View {
    var accessibilityIdentifier = "cat-care-family-notebook"
    /// On a cat that is in the notebook: the family's names, shown as faces.
    var sharedNames: [String]? = nil
    @ObservedObject private var model = FamilyNotebookPrototype.shared
    /// Read only: the pause this session already knows, no request of its own.
    @ObservedObject private var sharing = FamilyNotebookSharing.shared
    @State private var shows = false

    /// Sharing stopped shows before the notebook is opened (11/7).
    private var paused: Bool { model.hasFamily && sharing.pause != nil }

    var body: some View {
        Button { shows = true } label: {
            Group {
                if let sharedNames {
                    // 11/7: the words stay beside the faces, so it still says
                    // what the button opens.
                    HStack(spacing: 6) {
                        FamilyFaces(names: sharedNames)
                        Text("家族の手帳")
                            .accessibilityHidden(true)  // the faces already say it
                    }
                } else {
                    // Words beside the icon: a bare person icon was not found (1031).
                    // One name for it everywhere: 家族の手帳 (11/7).
                    Label("家族の手帳", systemImage: model.hasFamily ? "person.2.fill" : "person.badge.plus")
                        .labelStyle(.titleAndIcon)
                }
            }
                .overlay(alignment: .topTrailing) {
                    // 11/7: a mark with a symbol, not a 7pt dot of color alone.
                    if paused {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption.weight(.bold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.orange)
                            .background(Circle().fill(Color(.systemBackground)).padding(-1))
                            .offset(x: 6, y: -6)
                    } else if model.hasNewFromFamily {
                        Circle().fill(Color.accentColor)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                            .offset(x: 4, y: -4)
                    }
                }
        }
        .accessibilityValue(paused ? "共有が止まっています" : model.hasNewFromFamily ? "新しい記録があります" : "")
        .accessibilityIdentifier(accessibilityIdentifier)
        .sheet(isPresented: $shows) { FamilyNotebookView() }
    }
}

/// The family on a shared cat's page: the first two letters of each name in a
/// small circle, overlapped, at most three and then 「+N」. No sentence (11/6).
/// 11/7: two letters (「お母」「お父」 were both 「お」) on dark fills that
/// white text reads well on (it was white on orange).
struct FamilyFaces: View {
    let names: [String]
    private static let tints: [Color] = [
        Color(red: 0.22, green: 0.29, blue: 0.53),  // navy
        Color(red: 0.08, green: 0.40, blue: 0.38),  // deep teal
        Color(red: 0.45, green: 0.22, blue: 0.43),  // plum
        Color(red: 0.40, green: 0.31, blue: 0.20),  // brown
    ]

    var body: some View {
        HStack(spacing: -8) {
            ForEach(Array(names.prefix(3).enumerated()), id: \.offset) { index, name in
                Text(String(name.prefix(2)))
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 2)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Self.tints[index % Self.tints.count]))
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
            }
            if names.count > 3 {
                Text("+\(names.count - 3)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("家族の手帳：" + names.joined(separator: "、"))
        .accessibilityIdentifier("cat-care-family-faces")
    }
}

/// Keep the existing authenticated service moving while a shared tool is open.
private struct FamilyNotebookToolSyncModifier: ViewModifier {
    var enabled: Bool
    @ObservedObject private var model = FamilyNotebookPrototype.shared
    @State private var counted = false
    func body(content: Content) -> some View {
        // 11/15 (1115q): the tool says it is on screen; the one schedule reads
        // the family every 30 s meanwhile (it was every 5 s, a loop of its own).
        content
            .onAppear { update(enabled && model.hasFamily) }
            .onChange(of: enabled && model.hasFamily) { _, on in update(on) }
            .onDisappear { update(false) }
    }
    private func update(_ on: Bool) {
        guard on != counted else { return }
        counted = on
        if on { FamilyNotebookAutoCheck.shared.appeared(.tool) } else { FamilyNotebookAutoCheck.shared.disappeared(.tool) }
    }
}
/// 11/19 (TestFlight 392): この子 shows a photo the family delivered. The
/// photo comes with the notebook, so the one schedule reads the family once a
/// minute meanwhile (FamilyAutoCheckPolicy), as an open notebook does.
private struct FamilyNotebookPhotoScreenModifier: ViewModifier {
    var enabled: Bool
    @State private var counted = false
    func body(content: Content) -> some View {
        content
            .onAppear { update(enabled) }
            .onChange(of: enabled) { _, on in update(on) }
            .onDisappear { update(false) }
    }
    private func update(_ on: Bool) {
        guard on != counted else { return }
        counted = on
        if on { FamilyNotebookAutoCheck.shared.appeared(.photo) } else { FamilyNotebookAutoCheck.shared.disappeared(.photo) }
    }
}

/// 11/15 (TestFlight 378): the person let in learned it only by opening the
/// notebook, so their device never registered for the key. Coming to the
/// front starts the one schedule (FamilyNotebookAutoCheck): someone in a
/// family, waiting to be let in, or not yet known to be neither, is read
/// once, and again on the schedule's terms (1115q: within this iPhone's
/// call budget). Photos access plays no part.
private struct FamilyNotebookOpeningCheck: ViewModifier {
    @ObservedObject private var model = FamilyNotebookPrototype.shared
    @ObservedObject private var purchases = PlusPurchaseStore.productionShared
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content
        // 11/15: Plus confirmed later (the purchase re-checks run wherever the
        // person is): a family stopped for want of it is read again at once,
        // so 「共有が止まっています」 goes without opening anything.
        .onChange(of: purchases.entitlementState.permitsPersonalPlus) { _, plus in
            guard plus, model.isReal, model.hasFamily, FamilyNotebookSharing.shared.pause != nil else { return }
            Task { await FamilyNotebookSharing.shared.refreshAfterPlusChange(reportsFailure: false) }
        }
        .onChange(of: phase == .active, initial: true) { _, active in
            FamilyNotebookAutoCheck.shared.setActive(active)
        }
    }
}

extension View {
    /// Poll only while an actual shared tool is visible in the foreground.
    /// The sharing service still enforces participation, pause and entitlement.
    func familyNotebookToolSync(enabled: Bool = true) -> some View {
        modifier(FamilyNotebookToolSyncModifier(enabled: enabled))
    }

    /// 11/19: この子 while it shows a photo the family delivered.
    func familyNotebookPhotoScreen(enabled: Bool) -> some View {
        modifier(FamilyNotebookPhotoScreenModifier(enabled: enabled))
    }

    /// Put once at the app's root (11/15).
    func familyNotebookOpeningCheck() -> some View {
        modifier(FamilyNotebookOpeningCheck())
    }

    /// 11/16: pull down to read the family's notebook once, on a page of a
    /// cat in the notebook. Anywhere else (no family, a cat of this iPhone
    /// only) the page is not pulled at all.
    func familyNotebookPullToRead(enabled: Bool) -> some View {
        modifier(FamilyNotebookPullToRead(enabled: enabled))
    }
}

/// `enabled` already says the cat is one of the family's (activeFamilyCats,
/// empty outside a family); nothing is observed here, so the この子 pages
/// are not drawn again for the notebook's changes (11/14).
private struct FamilyNotebookPullToRead: ViewModifier {
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled && FamilyNotebookPrototype.shared.isReal {
            content.refreshable { await FamilyNotebookSharing.shared.readPulled() }
        } else {
            content
        }
    }
}

/// How the notebook's items read on screen.
enum FamilyNotebookWords {
    /// After 「運営に知らせる」 on a family entry (11/14). The contact page asks
    /// people not to send photos or others' names, so only this one sentence.
    static let reportEntry = "お問い合わせから、気になった書き込みのことを知らせてください。"

    /// Under 「家族の手帳から抜ける」 at the bottom of the notebook.
    static func leaveDetail(payer: Bool) -> String {
        payer ? "抜けると、だれかがPlusを始めるまで共有が止まります。"
            : "これから書くことは家族に届かなくなります。"
    }

    /// Under the payer's 「家族の手帳を終わりにする」 (11/19 UI/UX 整理).
    static let dissolveDetail = "家族みんなの共有が終わります。書いたものは、それぞれのiPhoneに残ります。"

    /// 11/19 (UI/UX 整理): one way to say each wait, wherever it shows (the
    /// notebook, the invitation, Settings' row).
    static let awaitingApproval = "家族が受け入れるのを待っています"
    static let receiving = "家族の手帳を受け取っています"

    /// 11/19: the family stopped listing this person (taken out, or ended).
    static let sharingEnded = "この手帳の共有は終わりました。"

    /// 11/19: a member opened an invitation to their own family.
    static let alreadyInThisFamily = "もう家族の手帳に入っています。"

    /// 11/19: 「同じ子ですか」, asked the same way everywhere.
    static let sameChildQuestion = "このiPhoneの子と同じですか。"
    /// 11/19: linking to this iPhone's cat did not go (it used to say nothing).
    static let linkFailedTitle = "つなげませんでした"
    static let linkFailedMessage = "少し待ってから、もう一度お試しください。"

    /// 11/15: this iPhone's Plus was found, but the family does not see it yet.
    static let familyAwaitsPlus = "家族の手帳には、まだPlusが届いていません。少しおいて、もう一度確かめてください。"

    /// What brings sharing back, in one sentence (1029e; 11/19 UI/UX 整理:
    /// the reason is the help page's, the heading says it stopped).
    static func pausedDetail(_ pause: FamilySharingPause) -> String {
        switch pause {
        case .noPayer:
            return "だれか1人がPlusを始めると、また共有できます。"
        case .payerPlusUnverified(isPayer: true):
            return "Plusを続けると、家族みんなの共有が戻ります。"
        case .payerPlusUnverified(isPayer: false):
            return "書いたものは消えません。Plusが戻ると、また共有できます。"
        }
    }

    /// "YYYY-MM-DD" as people write it.
    static func dayText(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return day }
        return "\(parts[0])年\(parts[1])月\(parts[2])日"
    }

    /// One line for 「この子のこと」. Saved is not delivered: pending says so.
    static func farewellStatus(_ state: FamilyFarewellSharingState) -> String {
        if state.revocationPending { return "共有をやめるのを待っています" }
        if state.sharingPending { return "家族に届けるのを待っています" }
        if state.hasConsentForLocalDay { return "家族と共有しています" }
        if state.consentedDay != nil { return "前の日付を共有しています" }
        if state.localDay == nil, let shared = state.sharedDay { return dayText(shared) }
        return "共有していません"
    }

    static func farewellDetail(_ state: FamilyFarewellSharingState) -> String {
        var lines: [String] = []
        if let shared = state.sharedDay, let author = state.sharedAuthor,
           !(state.consentedDay == shared && state.hasConsentForLocalDay) {
            lines.append("家族の手帳の日付は、\(author.displayName)が共有しました。")
        }
        if state.revocationPending {
            lines.append("インターネットにつながったら、共有をやめます。")
        } else if state.sharingPending {
            lines.append("インターネットにつながったら、この日付を家族に届けます。")
        } else if state.hasConsentForLocalDay {
            lines.append("この日付を家族と共有しています。")
        } else if state.consentedDay != nil {
            lines.append("前に共有した日付と、このiPhoneの日付が違います。")
        } else if state.localDay != nil {
            lines.append("この日付は、まだ家族と共有していません。")
        }
        return lines.joined(separator: "")
    }

    static func byline(_ operation: FamilyNotebookOperation) -> String {
        let date = (operation.importedSourceEditedAt ?? operation.editedAt)
            .formatted(.dateTime.month(.defaultDigits).day())
        return "\(operation.author.displayName)・\(date)"
    }

    static func label(_ field: FamilyNotebookField) -> String {
        switch field {
        case .name: "名前"
        case .sex: "性別"
        case .neutered: "去勢・避妊"
        case .indoorOnly: "室内飼い"
        case .birthday: "誕生日"
        case .adoptionDay: "迎えた日"
        case .coat: "毛色・柄"
        case .marks: "見分ける特徴"
        case .microchip: "マイクロチップ"
        case .conditions: "持病"
        case .allergyStatus: "アレルギー"
        case .allergyText: "アレルギーの内容"
        case .specialDiet: "療法食など"
        case .water: "水"
        case .litter: "トイレ"
        case .temperament: "接し方・苦手なこと"
        case .vetName: "病院の名前"
        case .vetPhone: "病院の電話"
        case .vetNote: "病院のメモ"
        // The tools' fields, so 最近の書き込み never shows an internal name
        // such as 「grams」 or 「usualFood」 (11/6).
        case .farewellDay: "旅立った日"
        case .position: "並び順"
        case .sharingEnded: "共有"
        case .measuredOn: "体重を量った日"
        case .grams: "体重"
        case .medicationName: "薬の名前"
        case .dose: "薬の量"
        case .schedule: "飲ませる時間"
        case .startedOn: "始めた日"
        case .endedOn: "終えた日"
        case .note, .text: "メモ"
        case .kind: "種類"
        case .givenOn: "受けた日"
        case .nextDueOn: "次の予定"
        case .time: "時間"
        case .food, .meals: "ごはん"
        case .amount: "量"
        case .order: "順番"
        case .catName: "猫の名前"
        case .observations: "診察のときの様子"
        case .questions: "聞きたいこと"
        case .completedAt: "終えた日"
        case .capturedAt: "撮った日"
        case .writtenAt: "書いた日"
        case .recipient: "預け先"
        case .period: "預ける期間"
        case .request: "お願い"
        case .usualFood: "いつものごはん"
        case .toilet: "トイレ"
        case .handling: "接し方"
        case .important: "大事なこと"
        case .callWhen: "連絡してほしいとき"
        case .healthStatus: "体調"
        case .healthDetails: "体調のくわしいこと"
        default: "記録"
        }
    }

    /// The picked (not typed) items: what is stored, and what is shown.
    static func choices(_ field: FamilyNotebookField) -> [(String, String)]? {
        switch field {
        case .sex: [(CatCareSex.unknown.rawValue, "未記入"), (CatCareSex.male.rawValue, "オス"), (CatCareSex.female.rawValue, "メス")]
        case .neutered: [(CatCareTriState.unknown.rawValue, "未記入"), (CatCareTriState.yes.rawValue, "済み"), (CatCareTriState.no.rawValue, "まだ")]
        case .indoorOnly: [(CatCareTriState.unknown.rawValue, "未記入"), (CatCareTriState.yes.rawValue, "室内だけ"), (CatCareTriState.no.rawValue, "外にも出る")]
        case .allergyStatus: [(CatCareAllergy.Status.unknown.rawValue, "未確認"), (CatCareAllergy.Status.none.rawValue, "なし"),
                              (CatCareAllergy.Status.recorded.rawValue, "あり")]
        default: nil
        }
    }

    /// What a value reads as, or nil when nothing is written.
    static func text(_ value: FamilyNotebookValue?, _ field: FamilyNotebookField) -> String? {
        if field == .adoptionDay, let value, let date = try? FamilyNotebookAdoptionDate.decode(value) {
            return date.day + (date.isApproximate ? "ごろ" : "")
        }
        switch value {
        case let .text(text)?:
            if let choices = choices(field) {
                guard let shown = choices.first(where: { $0.0 == text }), shown.0 != choices[0].0 else { return nil }
                return shown.1
            }
            return text.isEmpty ? nil : text
        case let .day(day)?:
            let parts = day.split(separator: "-").compactMap { Int($0) }
            return parts.count == 3 ? "\(parts[0])年\(parts[1])月\(parts[2])日" : day
        case let .date(date)?:
            return date.formatted(.dateTime.year().month(.defaultDigits).day())
        case let .integer(number)?:
            return field == .order ? nil : "\(number)"
        default:
            return nil
        }
    }
}

// MARK: - In 「この子のこと」

/// Under an item of 「この子のこと」: who in the family wrote it. Nothing when
/// you wrote it or there is no family; the item itself stays where it is.
struct FamilyNotebookNote: ViewModifier {
    let toolCatID: UUID?
    let field: FamilyNotebookField

    /// This iPhone's writing still in the outbox a minute after it was
    /// written (a normal send takes one pass, 30 s at most on these pages).
    static func waitsToBeSent(_ state: FamilyNotebookFieldState, now: Date) -> Bool {
        state.status == .pendingShared && now.timeIntervalSince(state.operation.editedAt) > 60
    }
    @ObservedObject private var model = FamilyNotebookPrototype.shared

    @ViewBuilder
    func body(content: Content) -> some View {
        if !model.hasFamily {
            // No family (always so outside test builds): the item exactly as before.
            content
        } else {
            VStack(alignment: .leading, spacing: 4) {
                content
                if let state = model.state(toolCatID: toolCatID, field) {
                    if !model.isMe(state.operation.author) {
                        Label(FamilyNotebookWords.byline(state.operation), systemImage: "person.2")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if FamilyNotebookNote.waitsToBeSent(state, now: Date()) {
                        // 11/16: written here, not sent to the family for over
                        // a minute. A mark, no words (support asks about it).
                        Image(systemName: "icloud.slash")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel("未送信")
                            .accessibilityIdentifier("family-notebook-note-unsent")
                    }
                }
            }
        }
    }
}

extension View {
    func familyNotebookNote(_ toolCatID: UUID?, _ field: FamilyNotebookField) -> some View {
        modifier(FamilyNotebookNote(toolCatID: toolCatID, field: field))
    }
}

/// The family's entries this iPhone chose not to show, each with 「表示する」.
/// The same form as まど's 「表示しない・ブロックした人」; kept on this iPhone only.
struct FamilyHiddenOperationsView: View {
    @ObservedObject private var model = FamilyNotebookPrototype.shared
    @AppStorage("family.hiddenOperations.v1") private var hiddenOperationIDs = ""

    private var hidden: [FamilyNotebookOperation] {
        let ids = Set(hiddenOperationIDs.split(separator: ",").map(String.init))
        return model.recentFromFamily.filter { ids.contains(String(describing: $0.id)) }
    }

    var body: some View {
        List {
            ForEach(hidden) { operation in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.place(of: operation))
                        Text("\(operation.author.displayName)・\(operation.editedAt.formatted(.dateTime.month(.defaultDigits).day()))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("表示する") { show(operation) }
                        .buttonStyle(.bordered)
                }
                .frame(minHeight: 44)
            }
        }
        .overlay {
            if hidden.isEmpty {
                ContentUnavailableView("表示しない書き込みはありません", systemImage: "eye.slash")
            }
        }
        .navigationTitle("表示しない書き込み")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func show(_ operation: FamilyNotebookOperation) {
        var ids = Set(hiddenOperationIDs.split(separator: ",").map(String.init))
        ids.remove(String(describing: operation.id))
        hiddenOperationIDs = ids.sorted().joined(separator: ",")
    }
}

/// 11/18: the reporter's own answers to family photo reports. The row shows
/// only on an iPhone that sent one; nothing about the family is read here.
@MainActor
enum FamilyReportReplies {
    nonisolated static let sentKey = "family.photoReport.sent.v1"

    /// After a family photo report was received.
    static func markSent() { UserDefaults.standard.set(true, forKey: sentKey) }

    /// Review captures only: the row and three sample answers.
    static var showsFixture: Bool {
#if DEBUG
        CommandLine.arguments.contains("--app-store-screenshot-fixture")
            && CommandLine.arguments.contains(fixtureArgument)
#else
        false
#endif
    }

#if DEBUG
    nonisolated static let fixtureArgument = "--family-report-replies-fixture"

    /// Sample receipts, one of each answer. Synthetic numbers only.
    static var fixtureReplies: [FamilyPhotoReportReply] {
        let now = Int64(Date().timeIntervalSince1970)
        return [
            FamilyPhotoReportReply(receiptNumber: "FP-0000-0003", receivedAt: now - 3_600, status: .received),
            FamilyPhotoReportReply(receiptNumber: "FP-0000-0002", receivedAt: now - 3 * 86_400, status: .reviewed),
            FamilyPhotoReportReply(receiptNumber: "FP-0000-0001", receivedAt: now - 9 * 86_400, status: .photoStopped),
        ]
    }

    /// A family on this iPhone alone (the test builds' notebook), so the
    /// row is reached from 設定 → 家族の手帳 as a person reaches it.
    static func seedFixtureIfRequested() async {
        guard showsFixture, !FamilyNotebookPrototype.shared.isReal else { return }
        await FamilyNotebookPrototype.shared.create()
        await FamilyNotebookSharing.shared.refresh()
    }
#endif

    static func load() async throws -> [FamilyPhotoReportReply] {
#if DEBUG
        if showsFixture { return fixtureReplies }
#endif
        return try await FamilyNotebookServiceFactory.reportReplies()
    }
}

/// The same 「通報への返答」 row under the notebook's intro, for someone
/// who reported and is no longer in a family.
private struct FamilyReportRepliesRow: View {
    var body: some View {
        NavigationLink { FamilyReportRepliesView() } label: {
            HStack {
                Label("通報への返答", systemImage: "exclamationmark.bubble")
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .accessibilityIdentifier("family-notebook-report-replies")
    }
}

/// 「通報への返答」: one line per report, newest first.
struct FamilyReportRepliesView: View {
    private enum Phase: Equatable {
        case loading, loaded([FamilyPhotoReportReply]), failed
    }
    @State private var phase: Phase = .loading

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
            case .failed:
                ContentUnavailableView {
                    Label("つながりませんでした", systemImage: "wifi.exclamationmark")
                } description: {
                    EmptyView()
                } actions: {
                    Button("もう一度") { Task { await load() } }
                        .accessibilityIdentifier("family-report-replies-retry")
                }
            case let .loaded(replies) where replies.isEmpty:
                ContentUnavailableView("返答はまだありません", systemImage: "exclamationmark.bubble")
            case let .loaded(replies):
                List(replies) { reply in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("通報番号 \(reply.receiptNumber)")
                                .font(.subheadline.monospaced().weight(.semibold))
                                .textSelection(.enabled)
                            Spacer()
                            Text(reply.receivedDate.formatted(.dateTime.month().day()))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Text(reply.status.message).font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
                .refreshable { await load(showsProgress: false) }
            }
        }
        .accessibilityIdentifier("family-report-replies")
        .navigationTitle("通報への返答")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    /// Opened or 「もう一度」 by the person: the person's call budget.
    private func load(showsProgress: Bool = true) async {
        if showsProgress { phase = .loading }
        do {
            let replies = try await SharingPersonAction.run { try await FamilyReportReplies.load() }
            phase = .loaded(replies.sorted { $0.receivedAt > $1.receivedAt })
        } catch {
            phase = .failed
        }
    }
}
