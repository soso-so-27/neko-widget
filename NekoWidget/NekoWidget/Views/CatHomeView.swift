import SwiftUI

// MARK: - The 「この子」 tab (11/12, 案D 「写真が主役」)
//
// One page per cat: the cat's key photo across the top with its name, a
// row of round buttons for the five tools, then 「この子のこと」. With two
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
/// off the main thread. Nothing is shown until it is known.
@MainActor
final class CatHomeToolStates: ObservableObject {
    struct ToolCat: Equatable {
        let id: UUID
        let name: String
    }

    /// Cats written only in 預けるとき・避難に備える (the cats 病院で見せる offers too).
    @Published private(set) var toolCats: [ToolCat] = []
    /// Cats (upper-cased IDs) with an unfinished vet memo that has something in it.
    @Published private(set) var unfinishedVetCats: Set<String> = []
    /// 迷子のとき drafts with something happened (a place, a day, an office).
    @Published private(set) var searchingKeys: Set<String> = []
    private var refreshing = false

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await Task.yield()
        let cats = SavedToolCatChoices.cats(care: .shared, evacuation: .shared)
            .map { ToolCat(id: $0.id, name: $0.name) }
        if cats != toolCats { toolCats = cats }
        let searching = Set(LostCatDraftStore.shared.drafts.filter { $0.value.hasIncident }.map(\.key))
        if searching != searchingKeys { searchingKeys = searching }
        guard let visits = try? await VeterinaryVisitStore.shared.visits() else { return }
        let unfinished = Set(visits.filter { visit in
            visit.completedAt == nil
                && (!visit.observations.isEmpty || !visit.questions.isEmpty || !visit.entries.isEmpty || visit.hasResults)
        }.map { $0.catID.uuidString.uppercased() })
        if unfinished != unfinishedVetCats { unfinishedVetCats = unfinished }
    }

    func vetUnfinished(_ cat: CatHomeCat) -> Bool {
        unfinishedVetCats.contains(cat.id.uppercased())
    }

    func searching(_ cat: CatHomeCat) -> Bool {
        searchingKeys.contains(cat.id) || searchingKeys.contains("guest-tool-" + cat.id)
    }
}

/// What the page says about a cat, worked out once per drawing.
struct CatHomeFacts {
    /// 「メス・3歳2か月　／　うちに来て 1,204日」, or the 旅立った日 line.
    var line: String?
    /// What VoiceOver reads for the photo: 「むぎ、オス、4歳2か月、うちに来て1204日」.
    var spoken: String
    var departed: Bool
    /// 「あと6つ」 / 「そろっています」 and the share filled; nil for a departed cat.
    var progressText: String?
    var progressShare: CGFloat
    /// 「3.90kg（10月21日）」
    var weight: String?
    /// 「あと23日」 / 「きょう」
    var birthdayIn: String?

    static func make(cat: CatHomeCat, record: CatCareRecord?, progress: CatCareProgress?,
                     farewell: CatCareDay?, now: Date = Date(),
                     calendar: Calendar = .nekoGregorian) -> CatHomeFacts {
        let profile = cat.profile
        if let farewell {
            let day = CatFarewell.text(farewell)
            return CatHomeFacts(line: "旅立った日　" + day, spoken: "\(cat.name)、旅立った日、\(day)", departed: true,
                                progressText: nil, progressShare: 0,
                                weight: weightText(record, now: now, calendar: calendar), birthdayIn: nil)
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
        let share: CGFloat = progress.map { $0.total > 0 ? CGFloat($0.filled) / CGFloat($0.total) : 0 } ?? 0
        let progressText = progress.map { $0.filled >= $0.total ? "そろっています" : "あと\($0.total - $0.filled)つ" }
        let birthdayIn: String? = birthday.flatMap { Self.daysUntilBirthday($0, now: now, calendar: calendar) }
            .map { $0 == 0 ? "きょう" : "あと\($0)日" }
        return CatHomeFacts(line: parts.isEmpty ? nil : parts.joined(separator: "　／　"), spoken: spoken,
                            departed: false, progressText: progressText, progressShare: min(max(share, 0), 1),
                            weight: weightText(record, now: now, calendar: calendar), birthdayIn: birthdayIn)
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

    /// Days to the next birthday; 0 on the day. 2/29 counts on 3/1 in other years.
    static func daysUntilBirthday(_ birthday: Date, now: Date, calendar: Calendar) -> Int? {
        let parts = calendar.dateComponents([.month, .day], from: birthday)
        let today = calendar.startOfDay(for: now)
        guard let next = calendar.nextDate(after: today.addingTimeInterval(-1), matching: parts,
                                           matchingPolicy: .nextTime) else { return nil }
        return calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: next)).day
    }

    /// The latest weight with its day: 「3.90kg（10月21日）」, the year too when not this year.
    static func weightText(_ record: CatCareRecord?, now: Date, calendar: Calendar) -> String? {
        guard let latest = record?.activeWeights.first else { return nil }
        let day = latest.measuredOn
        let thisYear = CatCareDay(date: now, calendar: calendar)?.year
        let date = day.year == thisYear ? "\(day.month)月\(day.day)日" : "\(day.year)年\(day.month)月\(day.day)日"
        return CatCareFormat.weight(latest.grams) + "（\(date)）"
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

    var body: some View {
        let cats = self.cats
        let current = currentCat(in: cats)
        GeometryReader { proxy in
            let metrics = CatHomeMetrics(proxy)
            Group {
                if let current {
                    pager(cats, current: current, metrics: metrics)
                } else {
                    CatHomeNoCatPage(metrics: metrics, tools: tools) { addsCat = true }
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .overlay(alignment: .top) { topBar(cats, current: current) }
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

    /// How far this cat's この子のこと is (the count the ring used).
    private func progress(for cat: CatHomeCat, record: CatCareRecord?) -> CatCareProgress {
        let draft = record.map { CatCareDraft(record: $0, household: careStore.state?.household ?? CatCareHousehold()) }
            ?? CatCareDraft()
        return CatCareProgress(draft: draft, record: record,
                               hasLifeDates: cat.profile.map { $0.lifeReference != nil })
    }

    private func facts(for cat: CatHomeCat) -> CatHomeFacts {
        let record = self.record(for: cat)
        // Cats whose farewell day is recorded (1.0 only, as in この子のこと).
        let farewell = Version1.isOn ? CatFarewell.days(farewellJSON)[cat.farewellKey] : nil
        return CatHomeFacts.make(cat: cat, record: record,
                                 progress: farewell == nil ? progress(for: cat, record: record) : nil,
                                 farewell: farewell)
    }

    // MARK: Pages

    /// The cats side by side, one page each; a swipe switches the cat.
    private func pager(_ cats: [CatHomeCat], current: CatHomeCat, metrics: CatHomeMetrics) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(Array(cats.enumerated()), id: \.element.id) { index, cat in
                    CatHomePage(cat: cat, facts: facts(for: cat), metrics: metrics,
                                pageIndex: index, pageCount: cats.count,
                                vetUnfinished: states.vetUnfinished(cat), searching: states.searching(cat),
                                tools: tools, carePage: AnyView(carePage(cat)))
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
        .scrollDisabled(cats.count < 2)
        .onAppear { if pageID == nil { pageID = current.id } }
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

    /// The cat menu (top left) and 設定 (top right), over the photo.
    private func topBar(_ cats: [CatHomeCat], current: CatHomeCat?) -> some View {
        HStack(alignment: .center) {
            if let current { catMenu(cats, current: current) }
            Spacer(minLength: 12)
            Button(action: openSettings) {
                SettingsGearIcon()
                    .font(.body.weight(.semibold))
                    .foregroundStyle(current == nil ? Color.primary : Color.white)
                    .frame(width: 40, height: 40)
                    .background(current == nil ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.black.opacity(0.32)),
                                in: Circle())
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

    /// Every cat this tab knows, and 「この子を追加」. Always there, since it
    /// is also where a cat is added.
    private func catMenu(_ cats: [CatHomeCat], current: CatHomeCat) -> some View {
        Menu {
            ForEach(cats) { cat in
                Button { show(cat.id) } label: {
                    if cat.id == current.id { Label(cat.name, systemImage: "checkmark") } else { Text(cat.name) }
                }
                .accessibilityIdentifier("tools-cat-menu-\(cat.id)")
            }
            Divider()
            Button { addsCat = true } label: { Label("この子を追加", systemImage: "plus") }
                .accessibilityIdentifier("tools-cat-profiles")
        } label: {
            HStack(spacing: 5) {
                Text(current.name).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(Color.black.opacity(0.32), in: Capsule())
            .frame(maxWidth: 220, alignment: .leading)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("猫を切り替える")
        .accessibilityValue(current.name)
        .accessibilityIdentifier("tools-cat-menu")
    }

    private func show(_ id: String) {
        withAnimation(.snappy) { pageID = id }
        storedCatID = id
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

/// One cat's page: the photo with the name, the tools, 「この子のこと」.
private struct CatHomePage: View {
    let cat: CatHomeCat
    let facts: CatHomeFacts
    let metrics: CatHomeMetrics
    let pageIndex: Int
    let pageCount: Int
    let vetUnfinished: Bool
    let searching: Bool
    let tools: CatHomeTools
    let carePage: AnyView

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                CatHomeHero(cat: cat, facts: facts, metrics: metrics, pageIndex: pageIndex, pageCount: pageCount)
                VStack(spacing: 22) {
                    // A cat whose farewell day is recorded is not offered in the tools.
                    if !facts.departed {
                        CatHomeToolBar(cat: cat, toolsShown: CatHomeTool.allCases, width: metrics.width,
                                       vetUnfinished: vetUnfinished, searching: searching, tools: tools)
                    }
                    CatHomeAboutCard(cat: cat, facts: facts, destination: carePage)
                }
                .padding(.horizontal, 16)
                // Up into the photo's fade.
                .padding(.top, facts.departed ? 4 : -18)
                .padding(.bottom, 24)
            }
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// The cat's key photo from the very top, its name and one line on it.
private struct CatHomeHero: View {
    let cat: CatHomeCat
    let facts: CatHomeFacts
    let metrics: CatHomeMetrics
    let pageIndex: Int
    let pageCount: Int
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var nameSize: CGFloat = 56

    /// How tall the fade into the page is, under the name.
    static let fade: CGFloat = 44

    var body: some View {
        backdrop
            .frame(width: metrics.width, height: metrics.heroHeight)
            .overlay {
                // Keeps the white name readable on any photo, light or dark mode.
                LinearGradient(stops: [.init(color: .black.opacity(0), location: 0.35),
                                       .init(color: .black.opacity(0.55), location: 0.9)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [Color(.systemGroupedBackground).opacity(0), Color(.systemGroupedBackground)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.fade)
            }
            .overlay(alignment: .bottomLeading) { words }
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(facts.spoken)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("cat-home-hero")
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
        VStack(alignment: .leading, spacing: 6) {
            Text(cat.name)
                .font(.system(size: min(nameSize, 84), weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(0.5)
            if let line = facts.line {
                Text(line)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    .minimumScaleFactor(0.75)
            }
            if pageCount > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        Circle()
                            .fill(Color.white.opacity(index == pageIndex ? 1 : 0.45))
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.top, 4)
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 6, y: 1)
        .padding(.horizontal, 20)
        .padding(.bottom, Self.fade + 6)
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

/// A round button: a line icon in a circle, a dot for a state, a short name.
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
                .overlay(alignment: .topTrailing) {
                    if let state {
                        Circle()
                            .fill(state.color)
                            .frame(width: 11, height: 11)
                            .overlay(Circle().stroke(Color(.systemGroupedBackground), lineWidth: 2))
                            .offset(x: -1, y: 1)
                    }
                }
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

/// 「この子のこと」: how much is written, a thin line for it, then the
/// latest weight and the days to the birthday when they are known. The
/// whole card opens the cat's page.
private struct CatHomeAboutCard: View {
    let cat: CatHomeCat
    let facts: CatHomeFacts
    let destination: AnyView

    var body: some View {
        NavigationLink { destination } label: {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    CatHomeLine(title: "この子のこと", value: facts.progressText, emphasized: true)
                    if facts.progressText != nil {
                        Capsule()
                            .fill(Color.primary.opacity(0.12))
                            .frame(height: 3)
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(Color.primary)
                                    .frame(height: 3)
                                    .scaleEffect(x: facts.progressShare, y: 1, anchor: .leading)
                            }
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                if let weight = facts.weight {
                    Divider().padding(.leading, 16)
                    CatHomeLine(title: "体重", value: weight)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                }
                if let birthdayIn = facts.birthdayIn {
                    Divider().padding(.leading, 16)
                    CatHomeLine(title: "誕生日まで", value: birthdayIn)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                }
            }
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(CatHomePressStyle())
        .accessibilityIdentifier(cat.profile != nil ? "tools-cat-\(cat.id)" : "tools-family-cat-\(cat.id)")
    }
}

/// A name and its value on one line; at the accessibility sizes the value
/// goes under the name.
private struct CatHomeLine: View {
    let title: String
    let value: String?
    var emphasized = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 8) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                Text(title)
                    .font(emphasized ? .headline : .body)
                    .foregroundStyle(.primary)
                if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                if let value {
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if emphasized { ToolChevron() }
        }
    }
}

/// No cat yet: のわ in a soft field, one sentence, one button; under it the
/// two tools for the whole home.
private struct CatHomeNoCatPage: View {
    let metrics: CatHomeMetrics
    let tools: CatHomeTools
    let add: () -> Void

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 22) {
                VStack(spacing: 14) {
                    Image("Nowa-sit-up")
                        .resizable()
                        .scaledToFit()
                        .frame(height: max(min(metrics.heroHeight * 0.38, 150), 80))
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
