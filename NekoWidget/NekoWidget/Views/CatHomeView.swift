import Combine
import SwiftUI

// MARK: - The 「この子」 tab (11/12, 案D 「写真が主役」)
//
// One page per cat: the cat's key photo across the top with its name (the
// cat menu), a row of round buttons for the five tools, then one card ending
// in 「この子のこと」. With two
// or more cats the pages sit side by side; the chosen cat is remembered and
// is the cat the tools open for. Built apart from MainTabView so its body
// stays small for the type checker.

/// The tool pages, built by MainTabView (they need its photos and stores).
/// The String is the page's cat (`CatHomeCat.id`); the tool opens for it
/// and leaves out its own cat menu.
struct CatHomeTools {
    let vet: (String) -> AnyView
    let care: (String) -> AnyView
    let lost: (String) -> AnyView
    let evacuation: () -> AnyView
    /// The profile's identifier, or nil (no cat, or a cat without a profile).
    let showcase: (String?) -> Void
}

/// A cat with a page: a profile, or a cat of 「この子のこと」 without one
/// here (a family cat, or one known only from the tools).
struct CatHomeCat: Identifiable, Equatable {
    enum Kind: Equatable {
        case profile(CatProfilePresentation)
        case toolCat(UUID)
    }

    /// The profile's identifier, or the household cat ID (`toolCatID`).
    let id: String
    let name: String
    let kind: Kind

    var profile: CatProfilePresentation? {
        if case let .profile(profile) = kind { return profile }
        return nil
    }

    /// The key 旅立った日 is kept under (as in CatCareSubject).
    var farewellKey: String {
        switch kind {
        case let .profile(profile): profile.identifier
        case let .toolCat(id): "tool-" + id.uuidString
        }
    }
}

/// What the tools have for each cat, read after the page is drawn: the
/// stores below read their files on first use, and the vet memos are read
/// off the main thread. Nothing is shown until it is known. Read again when
/// the tab appears and when a vet memo is saved.
@MainActor
final class CatHomeToolStates: ObservableObject {
    struct ToolCat: Equatable {
        let id: UUID
        let name: String
    }

    /// Cats written only in 預けるとき・避難に備える (the cats 病院で見せる offers too).
    @Published private(set) var toolCats: [ToolCat] = []
    /// Each cat's vet memos (upper-cased cat IDs), only what 「これからのこと」
    /// and the 病院 button need.
    @Published private(set) var memosByCat: [String: [CatHomeCareCore.VetMemo]] = [:]
    /// 迷子のとき drafts being searched with (`LostCatDraft.isSearching`).
    @Published private(set) var searchingKeys: Set<String> = []
    private var refreshing = false
    private var observer: AnyCancellable?

    init() {
        observer = NotificationCenter.default.publisher(for: .appRecordsCommitted)
            .compactMap { ($0.object as? URL)?.path }
            .filter { $0.contains("/VeterinaryVisits") }
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in Task { await self?.refresh() } }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await Task.yield()
        let cats = SavedToolCatChoices.cats(care: .shared, evacuation: .shared)
            .map { ToolCat(id: $0.id, name: $0.name) }
        if cats != toolCats { toolCats = cats }
        // 11/13: searching, not a draft with a place typed in to try the flyer.
        let searching = Set(LostCatDraftStore.shared.drafts.filter { $0.value.isSearching }.map(\.key))
        if searching != searchingKeys { searchingKeys = searching }
        guard let visits = try? await VeterinaryVisitStore.shared.visits() else { return }
        let memos = Dictionary(grouping: visits) { $0.catID.uuidString.uppercased() }
            .mapValues { $0.map { CatHomeCareCore.VetMemo($0) } }
        if memos != memosByCat { memosByCat = memos }
    }

    /// The vet memos of the page's cat, under its own ID and its 「この子のこと」 ID.
    func vetMemos(for cat: CatHomeCat, record: CatCareRecord?) -> [CatHomeCareCore.VetMemo] {
        let keys = Set([cat.id.uppercased(), record?.catID.uuidString.uppercased()].compactMap { $0 })
        return keys.flatMap { memosByCat[$0] ?? [] }
    }

    func searching(_ cat: CatHomeCat) -> Bool {
        searchingKeys.contains(cat.id) || searchingKeys.contains("guest-tool-" + cat.id)
    }
}

/// What the page says about a cat, worked out once per drawing.
struct CatHomeFacts {
    /// 「メス・3歳2か月　／　うちに来て 1,204日」, or the 旅立った日 line. On
    /// the birthday 「きょうで5歳」 and on the day the cat came home
    /// 「うちに来て 4年」 take its place (11/14).
    var line: String?
    /// What VoiceOver reads for the photo: 「むぎ、オス、4歳2か月、うちに来て1204日」.
    var spoken: String
    var departed: Bool
    /// The birthday 「これからのこと」 counts to (the same day the age is from).
    var birthday: CatCareDay?

    static func make(cat: CatHomeCat, record: CatCareRecord?, farewell: CatCareDay?, now: Date = Date(),
                     calendar: Calendar = .nekoGregorian) -> CatHomeFacts {
        let profile = cat.profile
        if let farewell {
            let day = CatFarewell.text(farewell)
            return CatHomeFacts(line: "旅立った日　" + day, spoken: "\(cat.name)、旅立った日、\(day)", departed: true,
                                birthday: nil)
        }
        let birthday: Date? = profile?.lifeDates.birthday?.date
            ?? (profile?.lifeReference?.kind == .birthday ? profile?.lifeReference?.date : nil)
            ?? record?.birthday?.value?.date(calendar: calendar)
        let adoption: Date? = profile?.lifeDates.adoptionDay?.date
            ?? (profile?.lifeReference?.kind == .adoptionDay ? profile?.lifeReference?.date : nil)
        let sex: String? = switch record?.sex?.value ?? .unknown {
        case .male: "オス"
        case .female: "メス"
        case .unknown: nil
        }
        let age: String? = birthday.flatMap { Self.age(from: $0, to: now, calendar: calendar) }
        let days: Int? = adoption.flatMap { Self.daysTogether(since: $0, now: now, calendar: calendar) }
        let about = [sex, age].compactMap { $0 }.joined(separator: "・")
        let parts = [about.isEmpty ? nil : about, days.map { "うちに来て \($0.formatted())日" }].compactMap { $0 }
        let spoken = [cat.name, sex, age, days.map { "うちに来て\($0)日" }].compactMap { $0 }.joined(separator: "、")
        // 「だいたいの日付」: the day is kept, the age it gives is not said.
        let birthdayApproximate = profile?.lifeDates.birthday?.isApproximate
            ?? (profile?.lifeReference?.kind == .birthday ? profile?.lifeReference?.isApproximate : nil)
            ?? false
        let birthdayDay = birthday.flatMap { CatCareDay(date: $0, calendar: calendar) }
        let dayLine: String? = CatCareDay(date: now, calendar: calendar).flatMap { today in
            CatHomeCareCore.heroDayLine(birthday: birthdayDay, birthdayYearKnown: !birthdayApproximate,
                                        adoption: adoption.flatMap { CatCareDay(date: $0, calendar: calendar) },
                                        today: today)
        }
        if let dayLine {
            return CatHomeFacts(line: dayLine, spoken: "\(cat.name)、\(dayLine)", departed: false, birthday: birthdayDay)
        }
        return CatHomeFacts(line: parts.isEmpty ? nil : parts.joined(separator: "　／　"), spoken: spoken,
                            departed: false, birthday: birthdayDay)
    }

    /// 「3歳2か月」, 「3歳」, or 「5か月」 under one year. Nil for a birthday ahead.
    static func age(from birthday: Date, to now: Date, calendar: Calendar) -> String? {
        guard birthday <= now else { return nil }
        let parts = calendar.dateComponents([.year, .month], from: birthday, to: now)
        let years = parts.year ?? 0, months = parts.month ?? 0
        if years == 0 { return "\(months)か月" }
        return months == 0 ? "\(years)歳" : "\(years)歳\(months)か月"
    }

    /// Days since the cat came home, from the day itself; nil for a day ahead.
    static func daysTogether(since adoption: Date, now: Date, calendar: Calendar) -> Int? {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: adoption),
                                           to: calendar.startOfDay(for: now)).day
        return days.flatMap { $0 >= 0 ? $0 : nil }
    }
}

/// The five tools, in the order of the page.
enum CatHomeTool: CaseIterable {
    case vet, care, lost, evacuation, showcase

    var shortTitle: String {
        switch self {
        case .vet: "病院"
        case .care: "預ける"
        case .lost: "迷子"
        case .evacuation: "避難"
        case .showcase: "見せる"
        }
    }

    var title: String {
        switch self {
        case .vet: "病院で見せる"
        case .care: "預けるとき"
        case .lost: "迷子のとき"
        case .evacuation: "避難に備える"
        case .showcase: "写真を見せる"
        }
    }

    /// The tiles' symbols, as line icons.
    var systemImage: String {
        switch self {
        case .vet: "cross.case"
        case .care: "hand.raised"
        case .lost: "magnifyingglass"
        case .evacuation: "backpack"
        case .showcase: "square.grid.3x3"
        }
    }

    var identifier: String {
        switch self {
        case .vet: "tools-vet-open"
        case .care: "tools-care-open"
        case .lost: "tools-lost-cat-open"
        case .evacuation: "tools-evacuation-open"
        case .showcase: "tools-showcase-open"
        }
    }

    /// 避難に備える and 写真を見せる are for the whole home; they stay with no cat.
    static let household: [CatHomeTool] = [.evacuation, .showcase]
}

struct CatHomeView: View {
    let presentation: CatProfilesPresentation
    let actions: CatProfilesViewActions
    let tools: CatHomeTools
    let openSettings: () -> Void

    @ObservedObject private var careStore = CatCareStore.shared
    /// Shared cats with no profile on this iPhone (an invited family) have a
    /// page too, so 「この子のこと」 has one place for everyone (11/7).
    @ObservedObject private var familyNotebook = FamilyNotebookPrototype.shared
    @StateObject private var states = CatHomeToolStates()
    @AppStorage(CatFarewell.key) private var farewellJSON = ""
    /// The cat whose page is shown, and the cat the tools open for.
    @AppStorage("catHome.selectedCat.v1") private var storedCatID = ""
    /// The page the pager rests on; kept in storedCatID once it settles.
    @State private var pageID: String?
    @State private var addsCat = false
    @State private var addedCat: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let cats = self.cats
        let current = currentCat(in: cats)
        GeometryReader { proxy in
            let metrics = CatHomeMetrics(proxy)
            Group {
                if let current {
                    pager(cats, current: current, metrics: metrics)
                } else {
                    CatHomeNoCatPage(metrics: metrics, tools: tools, topBar: AnyView(topBar)) {
                        addsCat = true
                    }
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        // 11/13: 設定 is part of each page's content (on top of the photo,
        // scrolling away with it), not pinned over the page; 11/14: the cat
        // menu is the name on the photo.
        // No title on this page: the photo runs under the status bar.
        .toolbar(.hidden, for: .navigationBar)
        .addingCatProfile(isStarted: $addsCat, presentation: presentation, actions: actions) { identifier in
            storedCatID = identifier
            pageID = identifier
            addedCat = identifier
        }
        .navigationDestination(item: $addedCat) { identifier in
            if let profile = presentation.profiles.first(where: { $0.identifier == identifier }) {
                profilePage(profile)
            }
        }
        .navigationDestination(for: CatHomeRoute.self) { route in toolPage(route) }
        .onAppear { Task { await states.refresh() } }
        // Kept once the pages rest, never while they move.
        .task(id: pageID) {
            guard let pageID, pageID != storedCatID else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            storedCatID = pageID
        }
    }

    // MARK: Cats

    /// Profiles, then family cats without a profile here, then cats known
    /// only from the tools; one page each.
    private var cats: [CatHomeCat] {
        var result = presentation.profiles.map {
            CatHomeCat(id: $0.identifier, name: $0.displayName, kind: .profile($0))
        }
        var seen = Set(result.map { $0.id.uppercased() })
        for cat in familyOnlyCats where seen.insert(cat.toolID.uuidString.uppercased()).inserted {
            result.append(CatHomeCat(id: cat.toolID.uuidString, name: cat.name, kind: .toolCat(cat.toolID)))
        }
        for cat in states.toolCats where seen.insert(cat.id.uuidString.uppercased()).inserted {
            result.append(CatHomeCat(id: cat.id.uuidString, name: cat.name, kind: .toolCat(cat.id)))
        }
        return result
    }

    private func currentCat(in cats: [CatHomeCat]) -> CatHomeCat? {
        let chosen = pageID ?? storedCatID
        return cats.first { $0.id == chosen } ?? cats.first
    }

    /// Shared cats without a profile, plus restored personal proofs that must
    /// open even before their cat reappears through a new invitation.
    private var familyOnlyCats: [FamilyNotebookPrototype.FamilyCat] {
        let profileIDs = Set(presentation.profiles.map(\.identifier))
        let shared = familyNotebook.familyCats.filter { cat in
            guard let profileID = careStore.state?.cats
                .first(where: { $0.catID == cat.toolID && $0.deletedAt == nil })?.profileID else { return true }
            return !profileIDs.contains(profileID.uuidString)
        }
        let listed = Set(shared.map(\.toolID))
        let restored = (careStore.state?.cats ?? []).compactMap { record -> FamilyNotebookPrototype.FamilyCat? in
            guard record.deletedAt == nil, !record.unmatchedVaccinationProofs.isEmpty, !listed.contains(record.catID),
                  record.profileID.map({ !profileIDs.contains($0.uuidString) }) ?? true else { return nil }
            let name = record.name?.value.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .init(id: record.catID, toolID: record.catID, name: name.isEmpty ? "名前未設定の猫" : name)
        }
        return shared + restored
    }

    private func record(for cat: CatHomeCat) -> CatCareRecord? {
        switch cat.kind {
        case let .profile(profile):
            careStore.state?.cats.first { $0.profileID?.uuidString == profile.identifier }
        case let .toolCat(id):
            careStore.state?.cats.first { $0.catID == id && $0.deletedAt == nil }
        }
    }

    private func facts(for cat: CatHomeCat, record: CatCareRecord?) -> CatHomeFacts {
        // Cats whose farewell day is recorded (1.0 only, as in この子のこと).
        let farewell = Version1.isOn ? CatFarewell.days(farewellJSON)[cat.farewellKey] : nil
        return CatHomeFacts.make(cat: cat, record: record, farewell: farewell)
    }

    /// 「これからのこと」 for a living cat: what exists for it (CatHomeCareView.swift).
    private func care(for cat: CatHomeCat, record: CatCareRecord?, facts: CatHomeFacts) -> CatHomeCareRows? {
        guard !facts.departed else { return nil }
        return CatHomeCareRows.make(hasProfile: cat.profile != nil, record: record, birthday: facts.birthday,
                                    vetMemos: states.vetMemos(for: cat, record: record))
    }

    // MARK: Pages

    /// The cats side by side, one page each; a swipe switches the cat.
    /// 11/14: at rest a page is exactly as before (full bleed, no corners);
    /// while it moves each page becomes a card, a little smaller with
    /// rounded corners, the page background showing between the two (the
    /// WWDC23 「Beyond scroll views」 scrollTransition pattern). Reduce
    /// Motion: plain paging.
    private func pager(_ cats: [CatHomeCat], current: CatHomeCat, metrics: CatHomeMetrics) -> some View {
        let reduceMotion = self.reduceMotion
        let shrink = CatHomeCardWhileMoving.shrink
        return ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(Array(cats.enumerated()), id: \.element.id) { index, cat in
                    page(cat, index: index, cats: cats, metrics: metrics)
                        .modifier(CatHomeCardWhileMoving(enabled: !reduceMotion && cats.count > 1))
                        .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                            content.scaleEffect(phase.isIdentity || reduceMotion
                                                ? 1 : 1 - shrink * CGFloat(min(abs(phase.value), 1)))
                        }
                        // Only the page on screen is read and found by tests.
                        .accessibilityHidden(cat.id != current.id)
                        .containerRelativeFrame(.horizontal)
                        .id(cat.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $pageID)
        .scrollIndicators(.hidden)
#if DEBUG
        .modifier(CatHomeFrameProbeModifier())
#endif
        .scrollDisabled(cats.count < 2)
        // A light tick when another cat's page is reached; never on the
        // first appearance (pageID is set from nil there).
        .sensoryFeedback(.selection, trigger: pageID) { old, new in
            old != nil && new != nil && old != new
        }
        .onAppear { if pageID == nil { pageID = current.id } }
    }

    private func page(_ cat: CatHomeCat, index: Int, cats: [CatHomeCat], metrics: CatHomeMetrics) -> CatHomePage {
        let record = self.record(for: cat)
        let facts = self.facts(for: cat, record: record)
        return CatHomePage(cat: cat, facts: facts, metrics: metrics,
                           pageIndex: index, pageCount: cats.count,
                           vetUnfinished: states.vetMemos(for: cat, record: record).contains(where: \.isUnfinished),
                           searching: states.searching(cat),
                           tools: tools,
                           care: care(for: cat, record: record, facts: facts),
                           careLinks: CatHomeCareLinks(cat: cat, catID: record?.catID, carePage: AnyView(carePage(cat)),
                                                       saveLifeDates: actions.updateLifeDates),
                           catMenu: AnyView(catMenuItems(cats, current: cat)),
                           topBar: AnyView(topBar))
    }

    /// The page 「この子のこと」 opens: the cat's own page (CatProfileDetailView)
    /// for a profile, else its 「この子のこと」 under its name.
    @ViewBuilder
    private func carePage(_ cat: CatHomeCat) -> some View {
        switch cat.kind {
        case let .profile(profile):
            profilePage(profile)
        case let .toolCat(toolID):
            let profileID = careStore.state?.cats.first { $0.catID == toolID && $0.deletedAt == nil }?.profileID
            if let profile = presentation.profiles.first(where: { $0.identifier == profileID?.uuidString }) {
                profilePage(profile)
            } else {
                CatCareDetailView(toolCatID: toolID, name: cat.name)
                    .navigationTitle(cat.name.isEmpty ? "この子のこと" : cat.name)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    /// Exactly what the tiles opened; the per-cat tools for the page's cat.
    private func toolPage(_ route: CatHomeRoute) -> AnyView {
        guard let catID = route.catID else { return tools.evacuation() }
        switch route.tool {
        case .vet: return tools.vet(catID)
        case .care: return tools.care(catID)
        case .lost: return tools.lost(catID)
        case .evacuation, .showcase: return tools.evacuation()
        }
    }

    private func profilePage(_ profile: CatProfilePresentation) -> some View {
        CatProfileDetailView(
            profile: profile,
            allProfiles: presentation.profiles,
            manualCandidatePhotos: profile.manualCandidatePhotos,
            photoAlbumOptions: presentation.photoAlbumOptions,
            actions: actions
        )
    }

    // MARK: Over the photo

    /// 設定 (top right), over the photo. 11/14: no cat menu here; the name
    /// on the photo is the cat menu (CatHomeHero), so the name shows once.
    private var topBar: some View {
        HStack(alignment: .center) {
            Spacer(minLength: 12)
            Button(action: openSettings) {
                // 11/13: a material, so it reads as a live control on any
                // photo (a dark tint looked disabled).
                SettingsGearIcon()
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("設定")
            .accessibilityIdentifier("tools-settings-button")
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
    }

    /// The items of the cat menu (the name on the photo): every cat this tab
    /// knows, and 「この子を追加」. Always there, even with one cat, since it
    /// is also where a cat is added.
    @ViewBuilder
    private func catMenuItems(_ cats: [CatHomeCat], current: CatHomeCat) -> some View {
        ForEach(cats) { cat in
            Button { show(cat.id) } label: {
                if cat.id == current.id { Label(cat.name, systemImage: "checkmark") } else { Text(cat.name) }
            }
            .accessibilityIdentifier("tools-cat-menu-\(cat.id)")
        }
        Divider()
        Button { addsCat = true } label: { Label("この子を追加", systemImage: "plus") }
            .accessibilityIdentifier("tools-cat-profiles")
    }

    private func show(_ id: String) {
        withAnimation(.snappy) { pageID = id }
        storedCatID = id
    }
}

#if DEBUG
/// 11/14: DEBUG-only frame probe for the speed sweep (--cat-home-frame-probe).
/// The simulator gives XCTest no hitch metrics, so a display link counts,
/// while the pager scrolls (iOS 18 scroll phase), how many frames came late
/// on the main thread and by how much. The totals are put on a hidden text
/// (identifier cat-home-frame-probe) only when the pager rests.
@MainActor
final class CatHomeFrameProbe: NSObject, ObservableObject {
    static let isOn = CommandLine.arguments.contains("--cat-home-frame-probe")
    @Published private(set) var summary = "frames=0 late=0 late_ms=0 max_ms=0"
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var frames = 0
    private var late = 0
    private var lateSeconds: CFTimeInterval = 0
    private var maxGap: CFTimeInterval = 0

    func setMoving(_ moving: Bool) {
        if moving {
            guard link == nil else { return }
            last = 0
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            link?.invalidate()
            link = nil
            summary = String(format: "frames=%d late=%d late_ms=%.0f max_ms=%.0f",
                             frames, late, lateSeconds * 1000, maxGap * 1000)
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard last > 0 else { return }
        let gap = link.timestamp - last
        let expected = max(link.duration, 1.0 / 120)
        frames += 1
        maxGap = max(maxGap, gap)
        if gap > expected * 1.5 {
            late += 1
            lateSeconds += gap - expected
        }
    }
}

private struct CatHomeFrameProbeModifier: ViewModifier {
    @StateObject private var probe = CatHomeFrameProbe()

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            if CatHomeFrameProbe.isOn {
                content
                    .onScrollPhaseChange { _, phase in probe.setMoving(phase != .idle) }
                    .overlay(alignment: .topLeading) {
                        Text(probe.summary)
                            .font(.system(size: 1))
                            .foregroundStyle(Color.clear)
                            .frame(width: 1, height: 1)
                            .allowsHitTesting(false)
                            .accessibilityLabel(probe.summary)
                            .accessibilityIdentifier("cat-home-frame-probe")
                    }
            } else {
                content
            }
        } else {
            content
        }
    }
}
#endif

/// While the pages move, each page is a card with continuous rounded corners
/// (0 at rest, `radius` a full page away); its scale comes from the pager's
/// scrollTransition. The corners are painted in the page background (the
/// colour that shows between the two cards) rather than clipped: at rest
/// the paint is an empty path, so nothing is clipped or composited offscreen
/// and the photo under the status bar draws exactly as before, also while the
/// page scrolls up and down. A ViewModifier, so the moving offset re-draws
/// only the corners, never the page's own body.
private struct CatHomeCardWhileMoving: ViewModifier {
    /// How much smaller a page is a full page away (0.92 at most).
    static let shrink: CGFloat = 0.08
    static let radius: CGFloat = 32

    let enabled: Bool
    /// 0 at rest, 1 a full page away; kept in hundredths.
    @State private var progress: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                CatHomeCardCorners(radius: Self.radius * progress)
                    .fill(Color(.systemGroupedBackground), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                let width = proxy.size.width
                guard width > 0 else { return 0 }
                let moved = min(abs(proxy.frame(in: .scrollView(axis: .horizontal)).minX) / width, 1)
                // A settled page reads exactly 0 (no corner, no clip).
                return moved < 0.01 ? 0 : (moved * 100).rounded() / 100
            } action: { value in
                let next = enabled ? value : 0
                if next != progress { progress = next }
            }
    }
}

/// What lies outside a rounded rectangle in the rectangle (even-odd); an
/// empty path when the radius is 0.
private struct CatHomeCardCorners: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        guard radius > 0 else { return Path() }
        var path = Path(rect)
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        return path
    }
}

/// Sizes taken once from the screen: the photo is about 46% of its height
/// (40% on short screens, so the first buttons show on iPhone SE).
struct CatHomeMetrics {
    let width: CGFloat
    let heroHeight: CGFloat
    let topInset: CGFloat

    init(_ proxy: GeometryProxy) {
        let screen = proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
        width = proxy.size.width
        topInset = proxy.safeAreaInsets.top
        heroHeight = (screen * (screen < 700 ? 0.40 : 0.46)).rounded()
    }
}

/// One cat's page: the photo with the name, the tools, then one card: the
/// four rows (11/14) and 「この子のこと」 last. Only what helps take care of
/// the cat: its photos and past records live in their own tabs.
private struct CatHomePage: View {
    let cat: CatHomeCat
    let facts: CatHomeFacts
    let metrics: CatHomeMetrics
    let pageIndex: Int
    let pageCount: Int
    let vetUnfinished: Bool
    let searching: Bool
    let tools: CatHomeTools
    /// nil: a departed cat, or nothing to show for the four rows; the card
    /// is then 「この子のこと」 alone.
    let care: CatHomeCareRows?
    let careLinks: CatHomeCareLinks
    /// The items of the cat menu, which is the name on the photo.
    let catMenu: AnyView
    /// 設定, at the top of the photo; it scrolls with it.
    let topBar: AnyView

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                CatHomeHero(cat: cat, facts: facts, metrics: metrics, pageIndex: pageIndex, pageCount: pageCount,
                            menu: catMenu)
                // 18 (was 22): the page fits one screen on a standard iPhone (11/14).
                VStack(spacing: 18) {
                    // A cat whose farewell day is recorded is not offered in the tools.
                    if !facts.departed {
                        CatHomeToolBar(cat: cat, toolsShown: CatHomeTool.allCases, width: metrics.width,
                                       vetUnfinished: vetUnfinished, searching: searching, tools: tools)
                        // Until 「この迷子の記録を終える」 clears the place, day and log.
                        if searching { CatHomeSearchingLine(cat: cat) }
                    }
                    // 「この子のこと」 is the card's last row (11/14), so the
                    // card is there for every cat, departed ones too.
                    CatHomeCareCard(rows: care, links: careLinks)
                }
                .padding(.horizontal, 16)
                // Up into the photo's fade.
                .padding(.top, facts.departed ? 4 : -18)
                // Clear of the floating tab bar.
                .padding(.bottom, 32)
            }
            // Where the pinned bar rested: just under the status bar.
            .overlay(alignment: .top) { topBar.padding(.top, metrics.topInset) }
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// The cat's key photo from the very top, its name and one line on it.
/// 11/14: the name is the cat menu (a small chevron after it), so the name
/// is not said twice on the page.
private struct CatHomeHero: View {
    let cat: CatHomeCat
    let facts: CatHomeFacts
    let metrics: CatHomeMetrics
    let pageIndex: Int
    let pageCount: Int
    /// The cat menu's items (every cat, 「この子を追加」).
    let menu: AnyView
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .largeTitle) private var nameSize: CGFloat = 56
    /// The round cat-menu button after the name (40 at most).
    @ScaledMetric(relativeTo: .body) private var menuCircle: CGFloat = 30

    /// How tall the fade into the page is, under the name.
    static let fade: CGFloat = 44

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // VoiceOver: the photo is one header read once (name, sex, age,
            // days); the name over it is the cat menu, reached on its own.
            photoLayer
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(facts.spoken)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("cat-home-hero")
            words
        }
        .frame(width: metrics.width, height: metrics.heroHeight)
        .clipped()
    }

    private var photoLayer: some View {
        backdrop
            .frame(width: metrics.width, height: metrics.heroHeight)
            .overlay {
                // Only as much as the white name needs (11/13): nothing over the
                // upper half, so a dim photo keeps its own light there.
                LinearGradient(stops: [.init(color: .black.opacity(0), location: 0.5),
                                       .init(color: .black.opacity(0.3), location: 0.72),
                                       .init(color: .black.opacity(0.6), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .top) {
                // The clock and battery sit on the photo (11/14): white in dark
                // mode, black in light mode. A short wash of the opposite tone
                // keeps them readable on a very bright or very dark photo.
                LinearGradient(colors: [(colorScheme == .dark ? Color.black : Color.white).opacity(0.32),
                                        (colorScheme == .dark ? Color.black : Color.white).opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: metrics.topInset + 36)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [Color(.systemGroupedBackground).opacity(0), Color(.systemGroupedBackground)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.fade)
            }
    }

    @ViewBuilder private var backdrop: some View {
        ZStack {
            // A calm neutral for a cat without a key photo (no placeholder icon).
            LinearGradient(colors: [Color(red: 0.56, green: 0.57, blue: 0.60), Color(red: 0.30, green: 0.31, blue: 0.34)],
                           startPoint: .top, endPoint: .bottom)
            if let photo = cat.profile?.coverPhoto {
                PhotoAssetImageView(
                    localIdentifier: photo.localIdentifier,
                    catBoundingBox: Self.faceBiased(photo.catBoundingBox),
                    targetPixelSize: pixelSize,
                    targetAspectRatio: aspectRatio
                )
                .frame(width: metrics.width, height: metrics.heroHeight)
                .accessibilityHidden(true)
            }
        }
    }

    private var words: some View {
        // 11/14: the name takes at most 62% of the photo's width at rest.
        let nameWidth = (metrics.width * CGFloat(CatHomeHeroLayout.nameWidthShare)).rounded(.down)
        let fit = nameFit(maxWidth: nameWidth)
        return VStack(alignment: .leading, spacing: 6) {
            nameRow(fit, maxWidth: nameWidth)
            // The line and the dots are in the photo's spoken summary.
            if let line = facts.line {
                // Two lines (three at the accessibility sizes) before it
                // gets any smaller, and never below 0.85.
                Text(line)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
            if pageCount > 1 {
                CatHomePageDots(count: pageCount, current: pageIndex)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 8, y: 1)
        .padding(.horizontal, 20)
        .padding(.bottom, Self.fade + 6)
    }

    /// The largest size of the ladder (56, 48, 40, 34, each scaled by
    /// Dynamic Type up to 1.5×) at which the name fits on one line in
    /// `maxWidth`; else two lines at the smallest. A short name (up to
    /// three full-width characters) stays at 56.
    private func nameFit(maxWidth: CGFloat) -> CatHomeHeroLayout.NameFit {
        let name = cat.name as NSString
        // On a short photo (iPhone SE) the ladder does not grow with the
        // text size: at the accessibility sizes a larger name pushed the
        // name above the top of the photo (capture 45_home_text_ax3, se).
        let scale = metrics.heroHeight < CatHomeHeroLayout.shortHero ? min(nameSize / 56, 1) : nameSize / 56
        return CatHomeHeroLayout.nameFit(scale: Double(scale), maxWidth: Double(maxWidth)) { size in
            let font = UIFont.systemFont(ofSize: CGFloat(size), weight: .heavy)
            return Double(ceil(name.size(withAttributes: [.font: font]).width))
        }
    }

    /// The name as plain text, then the cat menu: a chevron in a small
    /// round button just after it, centred on the name's glyphs (on its last
    /// line when it takes two).
    ///
    /// 11/14: a Menu shows the system's lifted highlight around its whole
    /// label while it opens, and SwiftUI has no API to turn that off for a
    /// Menu (`ContentShapeKinds.contextMenuPreview` is documented for context
    /// menu previews only). With the name as the label that highlight was a
    /// faint rectangle around the big name; on a round button it is a small
    /// circle that looks intended.
    @ViewBuilder
    private func nameRow(_ fit: CatHomeHeroLayout.NameFit, maxWidth: CGFloat) -> some View {
        let size = CGFloat(fit.size)
        let gap = max((size * 0.12).rounded(), 6)
        if fit.lines == 1 {
            HStack(alignment: .lastTextBaseline, spacing: gap) {
                nameText(cat.name, fit: fit, maxWidth: maxWidth)
                centred(menuButton, size: size)
            }
        } else {
            // Two lines: broken where TextKit breaks them, so the button
            // sits just after the end of the last line as drawn (11/14: the
            // first capture put it after the first line's full width, and
            // SwiftUI's own breaks differ from a measurement).
            let lines = nameLines(size: size, maxWidth: maxWidth)
            ZStack(alignment: Alignment(horizontal: .leading, vertical: .lastTextBaseline)) {
                nameText(lines.text, fit: fit, maxWidth: maxWidth)
                centred(menuButton, size: size)
                    .alignmentGuide(.leading) { _ in -(lines.lastWidth + gap) }
            }
        }
    }

    /// The circle's centre about 0.36 of the size above the baseline: the
    /// middle of kana, kanji and capitals alike.
    private func centred<Content: View>(_ content: Content, size: CGFloat) -> some View {
        content.alignmentGuide(.lastTextBaseline) { dimensions in
            dimensions[VerticalAlignment.center] + size * CGFloat(CatHomeHeroLayout.glyphCentre)
        }
    }

    /// The name with a line break where it wraps in `maxWidth` (a little
    /// narrower, so the drawn text never wraps again), and how wide its last
    /// line is: the full width when more than two lines are cut short.
    private func nameLines(size: CGFloat, maxWidth: CGFloat) -> (text: String, lastWidth: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakStrategy = .standard
        let storage = NSTextStorage(string: cat.name, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .heavy), .paragraphStyle: paragraph])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(maxWidth - 4, 1), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        var lines: [(range: NSRange, width: CGFloat)] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, used, _, glyphs, _ in
            lines.append((layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil), used.width))
        }
        guard lines.count >= 2 else { return (cat.name, min(ceil(lines.first?.width ?? maxWidth), maxWidth)) }
        let name = cat.name as NSString
        let first = name.substring(with: lines[0].range).trimmingCharacters(in: .whitespaces)
        let rest = name.substring(from: NSMaxRange(lines[0].range)).trimmingCharacters(in: .whitespaces)
        let last = lines.count == 2 ? min(ceil(lines[1].width), maxWidth) : maxWidth
        return (first + "\n" + rest, last)
    }

    @ViewBuilder
    private func nameText(_ name: String, fit: CatHomeHeroLayout.NameFit, maxWidth: CGFloat) -> some View {
        let text = Text(name)
            .font(.system(size: CGFloat(fit.size), weight: .heavy))
            .foregroundStyle(.white)
            // The photo above reads the name; the button reads it as its value.
            .accessibilityHidden(true)
        if fit.lines == 1 {
            text.lineLimit(1).fixedSize()
        } else {
            text.lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: maxWidth, alignment: .leading)
        }
    }

    /// The cat menu (every cat, a check on this one, 「この子を追加」).
    private var menuButton: some View {
        let circle = min(menuCircle, 40)
        let target = max(circle, 44)
        return Menu { menu } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: (circle * 0.42).rounded(), weight: .bold))
                .foregroundStyle(.white)
                .frame(width: circle, height: circle)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
                .frame(width: target, height: target)
                .contentShape(Circle())
                .contentShape(.contextMenuPreview, Circle().inset(by: (target - circle) / 2))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("猫を切り替える")
        .accessibilityValue(cat.name)
        .accessibilityIdentifier("tools-cat-menu")
    }

    /// The frame's shape, rounded so the cached image is found again.
    private var aspectRatio: CGFloat {
        guard metrics.heroHeight > 0 else { return 1 }
        return (metrics.width / metrics.heroHeight * 100).rounded() / 100
    }

    /// As many pixels as the screen shows across, never the original.
    private var pixelSize: CGSize {
        let width = min((metrics.width * displayScale).rounded(), 1_290)
        return CGSize(width: width, height: (width / max(aspectRatio, 0.1)).rounded())
    }

    /// The crop centres on the top third of the cat (Vision's rect, origin
    /// bottom-left), where the face usually is; without a cat box, on the
    /// upper middle of the photo.
    static func faceBiased(_ box: CGRect?) -> CGRect {
        guard let box, box.width > 0, box.height > 0 else {
            return CGRect(x: 0.3, y: 0.55, width: 0.4, height: 0.3)
        }
        return CGRect(x: box.minX, y: box.maxY - box.height / 3, width: box.width, height: box.height / 3)
    }
}

/// Which page this is, on the photo: one dot per cat, at most seven; with
/// more cats the seven around this page show and the ends shrink, as the
/// system page control does (CatHomeHeroLayout.dots).
private struct CatHomePageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(CatHomeHeroLayout.dots(count: count, current: current), id: \.index) { dot in
                Circle()
                    .fill(Color.white.opacity(dot.index == current ? 1 : 0.45))
                    .frame(width: 6 * CGFloat(dot.scale), height: 6 * CGFloat(dot.scale))
            }
        }
        .frame(height: 6)
    }
}

/// The tools under the photo: five round buttons with a short name, or, at
/// the accessibility text sizes, rows with the full name and the state.
private struct CatHomeToolBar: View {
    /// nil: no cat yet (only the household tools are given).
    let cat: CatHomeCat?
    let toolsShown: [CatHomeTool]
    let width: CGFloat
    let vetUnfinished: Bool
    let searching: Bool
    let tools: CatHomeTools
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: 0) {
                ForEach(Array(toolsShown.enumerated()), id: \.offset) { index, tool in
                    if index > 0 { Divider().padding(.leading, 16) }
                    entry(tool) { CatHomeToolRow(tool: tool, state: state(tool)) }
                }
            }
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            // Five columns across the page; on iPhone SE the circles are a little smaller.
            let column = (width - 32) / 5
            let circle = min(66, max(column - 8, 44))
            HStack(spacing: 0) {
                ForEach(toolsShown, id: \.self) { tool in
                    entry(tool) { CatHomeToolButton(tool: tool, state: state(tool), circle: circle) }
                        .frame(width: column)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// 「書きかけ」 in orange, 「探しています」 in red; the others say nothing.
    private func state(_ tool: CatHomeTool) -> (text: String, color: Color)? {
        if tool == .vet && vetUnfinished { return (text: "書きかけ", color: Color.orange) }
        if tool == .lost && searching { return (text: "探しています", color: Color.red) }
        return nil
    }

    /// Opens exactly what the tiles opened, with the same identifiers.
    @ViewBuilder
    private func entry<Content: View>(_ tool: CatHomeTool, @ViewBuilder label: () -> Content) -> some View {
        let content = label()
        switch tool {
        case .showcase:
            Button { tools.showcase(cat?.profile?.identifier) } label: { content }
                .buttonStyle(CatHomePressStyle())
                .accessibilityIdentifier(tool.identifier)
        case .evacuation:
            NavigationLink(value: CatHomeRoute(tool: tool, catID: nil)) { content }
                .buttonStyle(CatHomePressStyle())
                .accessibilityIdentifier(tool.identifier)
        case .vet, .care, .lost:
            if let cat {
                NavigationLink(value: CatHomeRoute(tool: tool, catID: cat.id)) { content }
                    .buttonStyle(CatHomePressStyle())
                    .accessibilityIdentifier(tool.identifier)
            }
        }
    }
}

/// A tool pushed from a page, by value: the open tool stays when its page
/// goes (a cat deleted from inside the tool), as it did from the old tiles.
struct CatHomeRoute: Hashable {
    let tool: CatHomeTool
    /// The page's cat; nil for 避難に備える (the same for the whole home).
    let catID: String?
}

/// 「むぎを探しています」: the 迷子 state in words between the buttons and
/// the card; opens the same 迷子のとき for this cat.
private struct CatHomeSearchingLine: View {
    let cat: CatHomeCat

    var body: some View {
        NavigationLink(value: CatHomeRoute(tool: .lost, catID: cat.id)) {
            HStack(spacing: 10) {
                Image(systemName: CatHomeTool.lost.systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.red)
                    .accessibilityHidden(true)
                Text("\(cat.name)を探しています")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ToolChevron()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(CatHomePressStyle())
        .accessibilityLabel("\(cat.name)を探しています")
        .accessibilityIdentifier("cat-home-searching")
    }
}

/// A round button: a line icon in a circle and a short name; its state is
/// only in what VoiceOver reads.
private struct CatHomeToolButton: View {
    let tool: CatHomeTool
    let state: (text: String, color: Color)?
    let circle: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: tool.systemImage)
                .font(.system(size: (circle * 0.4).rounded(), weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: circle, height: circle)
                .background(Color(.secondarySystemGroupedBackground), in: Circle())
                .overlay(Circle().strokeBorder(Color(.separator), lineWidth: 1 / max(displayScale, 1)))
                // No dot (11/14): 迷子 is said in words under the buttons
                // (CatHomeSearchingLine) and 「書きかけ」 on the 病院 row of
                // 「これからのこと」, one place for a state; VoiceOver still
                // hears it on the button.
            Text(tool.shortTitle)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.map { "\(tool.title)、\($0.text)" } ?? tool.title)
    }
}

/// The accessibility-size form of a tool: icon, full name, the state under it.
private struct CatHomeToolRow: View {
    let tool: CatHomeTool
    let state: (text: String, color: Color)?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(tool.title).foregroundStyle(Color.primary)
                } icon: {
                    Image(systemName: tool.systemImage).foregroundStyle(Color.primary)
                }
                if let state {
                    Text(state.text).foregroundStyle(state.color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ToolChevron()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.map { "\(tool.title)、\($0.text)" } ?? tool.title)
    }
}

/// No cat yet: のわ in a soft field, one sentence, one button; under it the
/// two tools for the whole home.
private struct CatHomeNoCatPage: View {
    let metrics: CatHomeMetrics
    let tools: CatHomeTools
    /// 設定 (no cat menu without a cat), scrolling with the page.
    let topBar: AnyView
    let add: () -> Void

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 22) {
                VStack(spacing: 14) {
                    Image("Nowa-sit-up")
                        .resizable()
                        .scaledToFit()
                        .frame(height: max(min(metrics.heroHeight * 0.38, 150), 80))
                        .padding(22)
                        // のわ is black: a pale round keeps the shape in dark mode.
                        .background(Color(red: 0.96, green: 0.94, blue: 0.90), in: Circle())
                        .accessibilityHidden(true)
                    Text("この子を追加すると、ここに出ます。")
                        .font(.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: add) {
                        Text("この子を追加").frame(minWidth: 180)
                    }
                    .nekoPrimaryButton()
                    .accessibilityIdentifier("cat-home-add")
                }
                .padding(.horizontal, 24)
                .padding(.top, metrics.topInset + 44)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, minHeight: metrics.heroHeight)
                .background(Color(.secondarySystemGroupedBackground))
                CatHomeToolBar(cat: nil, toolsShown: CatHomeTool.household, width: metrics.width,
                               vetUnfinished: false, searching: false, tools: tools)
                    .padding(.horizontal, 16)
            }
            .padding(.bottom, 24)
            .overlay(alignment: .top) { topBar.padding(.top, metrics.topInset) }
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct CatHomePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1)
    }
}
