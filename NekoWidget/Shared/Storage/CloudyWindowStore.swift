import Foundation

enum CloudyWindowAvailability {
    static var isAvailable: Bool { Version1.isOn }
}

extension Notification.Name {
    static let cloudyWindowConfigurationChanged = Notification.Name("neko.cloudy-window.configuration")
}

enum CloudyWindowStrength: String, Codable, CaseIterable, Sendable {
    case light, medium, strong
    var title: String {
        switch self { case .light: "うすめ"; case .medium: "ふつう"; case .strong: "こいめ" }
    }
    var radius: Double {
        switch self { case .light: 6; case .medium: 10; case .strong: 16 }
    }
}

struct CloudyWindowConfiguration: Codable, Equatable, Sendable {
    /// 11/3: 「このiPhoneの猫写真」 is cloudy from the first install, like the
    /// per-cat windows. A persisted older state keeps whatever it saved.
    var enabled = true
    /// 10/24: the owner preferred こいめ on a real iPhone.
    var strength: CloudyWindowStrength = .strong
    var revision = UUID().uuidString
}

struct CloudyWindowPhotoMetadata: Codable, Equatable, Sendable {
    var creationDate: Date?
    var burstIdentifier: String?
    var profileIDs: Set<String>
    var previouslyShown: Bool
    /// 11/14 たぶん猫 (stored best cat confidence under 0.7, not vouched for
    /// by the user). The window picks one only when the household or the cat
    /// has no 確かな猫 to show. Optional: nil (older app builds) is 確かな猫,
    /// and older Widget builds ignore the key.
    var isProbableCat: Bool? = nil
    /// 11/15: the app's heart (`AssetRecord.liked`), then the Photos app's
    /// favorite (`AssetRecord.isFavorite`) come first among equals, the same
    /// order as the pool's weights (3x, 2x). Optional: older builds leave
    /// them out, and the app writes them again on its next read.
    var isLiked: Bool? = nil
    var isPhotosFavorite: Bool? = nil
}

/// 11/15: why a day's photo was chosen. Stored as text so a kind added later
/// never makes an older build fail to read the saved state.
enum CloudyWindowDayKind: String, Sendable {
    case milestone, new, date, ordinary
}

/// 11/15 節目: a cat's birthday or the day it came home, with the whole years
/// on that day (counted as on the cat's page, CatHomeCareCore.heroDay). The
/// app writes the coming ones; the window only matches the day.
struct CloudyWindowMilestoneDay: Codable, Equatable, Sendable {
    /// The JST start of the day (CloudyWindowStore.calendar).
    var day: Date
    /// `CloudyWindowMilestoneKind` as text.
    var kind: String
    var years: Int
}

enum CloudyWindowMilestoneKind: String, Sendable {
    case birthday, adoption
}

/// A 節目 day as chosen: which cats, their names and years then, and which of
/// them the photo shows.
struct CloudyWindowMilestone: Codable, Equatable, Sendable {
    struct Cat: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var years: Int
        var inPhoto: Bool
    }
    var kind: String
    var cats: [Cat]
}

/// 11/15: the words a date day and a 節目 day add to the cloudy window. Each
/// list is longest first; the Widget shows the first that fits on one line,
/// never a cut word. Nothing on other days, nor on a monthly work's day.
enum CloudyWindowDayText {
    static let maximumNameLength = 20

    private static func names(_ cats: [CloudyWindowMilestone.Cat]) -> [String] {
        cats.map { String($0.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumNameLength)) }
    }

    private static func milestoneOf(_ selection: CloudyWindowSelection) -> CloudyWindowMilestone? {
        guard selection.kind == .milestone, selection.albumPeriod == nil,
              let milestone = selection.milestone, !milestone.cats.isEmpty else { return nil }
        return milestone
    }

    /// The tag while cloudy on a 節目 day: 「きょうは むぎの誕生日」, short
    /// 「きょうは 誕生日」; 「むぎが来て 4年」, short 「うちに来た日」.
    static func tag(_ selection: CloudyWindowSelection) -> [String]? {
        guard let milestone = milestoneOf(selection) else { return nil }
        let catNames = names(milestone.cats)
        if milestone.kind == CloudyWindowMilestoneKind.birthday.rawValue {
            let long = catNames.count == 1 ? "きょうは \(catNames[0])の誕生日"
                : catNames.count == 2 ? "きょうは \(catNames[0])と\(catNames[1])の誕生日"
                : "きょうは \(catNames.count)匹の誕生日"
            return [long, "きょうは 誕生日"]
        }
        let years = Set(milestone.cats.map { $0.years })
        let long = catNames.count == 1 ? "\(catNames[0])が来て \(milestone.cats[0].years)年"
            : years.count == 1 ? "うちに来て \(milestone.cats[0].years)年" : "うちに来た日"
        return long == "うちに来た日" ? [long] : [long, "うちに来た日"]
    }

    /// The one line after clearing: 「1年前のきょう」 / 「1年前の今ごろ」 on a
    /// date day; 「むぎ 5歳」 (short 「5歳の誕生日」) or 「うちに来て 4年」 on
    /// a 節目 day, for the cats in the photo.
    static func revealedLine(_ selection: CloudyWindowSelection) -> [String]? {
        guard selection.revealedAt != nil, selection.albumPeriod == nil else { return nil }
        if selection.kind == .date, let years = selection.dateYearsAgo, years >= 1 {
            return ["\(years)年前の" + (selection.dateSameDay == true ? "きょう" : "今ごろ")]
        }
        guard let milestone = milestoneOf(selection) else { return nil }
        let shown = milestone.cats.filter { $0.inPhoto }
        guard !shown.isEmpty else { return nil }
        let years = Set(shown.map { $0.years })
        if milestone.kind == CloudyWindowMilestoneKind.birthday.rawValue {
            let long = zip(names(shown), shown).map { "\($0.0) \($0.1.years)歳" }.joined(separator: "・")
            return [long, years.count == 1 ? "\(shown[0].years)歳の誕生日" : "きょうは 誕生日"]
        }
        return [years.count == 1 ? "うちに来て \(shown[0].years)年" : "うちに来た日"]
    }

    /// VoiceOver for the tag: 「きょうは むぎの誕生日。」 before what clearing
    /// does; empty on other days.
    static func spokenTagPrefix(_ selection: CloudyWindowSelection) -> String {
        tag(selection).map { $0[0] + "。" } ?? ""
    }

    /// VoiceOver after clearing, added to the photo: 「、1年前のきょう」.
    static func spokenPhotoSuffix(_ selection: CloudyWindowSelection?) -> String {
        selection.flatMap(revealedLine).map { "、" + $0[0] } ?? ""
    }
}

struct CloudyWindowPreparedPhoto: Codable, Equatable, Sendable {
    var source: WidgetManifestItem
    var clear: WidgetCacheFilenames
    var cloudy: WidgetCacheFilenames
    var strength: CloudyWindowStrength
    var visualHash: UInt64
    var preparedAt: Date
    var photoID: String { source.localIdentifier }
    var filenames: [String] { clear.all + cloudy.all }
}

struct CloudyWindowSelection: Codable, Equatable, Sendable {
    var id = UUID().uuidString
    var scopeID: String
    var day: Date
    var photoID: String
    var profileID: String?
    var revealedAt: Date? = nil
    var albumPeriod: String? = nil
    /// 11/15: the kind of day (`CloudyWindowDayKind`), for a date day how
    /// many years ago and whether the same month and day (else within 3
    /// days), and when it was chosen. All optional: older saves have none.
    var dayKind: String? = nil
    var dateYearsAgo: Int? = nil
    var dateSameDay: Bool? = nil
    var chosenAt: Date? = nil
    /// 11/15 節目: the cats, names and years (only on a 節目 day).
    var milestone: CloudyWindowMilestone? = nil
    var kind: CloudyWindowDayKind? { dayKind.flatMap(CloudyWindowDayKind.init(rawValue:)) }
}

/// The host supplies the album's actual cover and closing time, never image
/// bytes or a second source of photo permission. Only this day's parcel may win.
struct CloudyWindowAlbumArrival: Codable, Equatable, Sendable {
    var period: String
    var availableAt: Date
    var photoID: String
    var day: Date { CloudyWindowStore.calendar.startOfDay(for: availableAt) }
}

/// Links name a committed reveal, not a user-supplied month or photo.
struct CloudyWindowAlbumRoute: Equatable, Sendable {
    let selectionID: String
    var url: URL {
        var components = URLComponents()
        components.scheme = "nekowidget"
        components.host = "album-arrival"
        components.queryItems = [.init(name: "selection", value: selectionID)]
        return components.url!
    }
    init(selectionID: String) { self.selectionID = selectionID }
    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "nekowidget", components.host == "album-arrival",
              components.path.isEmpty, components.fragment == nil,
              components.user == nil, components.password == nil, components.port == nil,
              let items = components.queryItems, items.count == 1,
              items[0].name == "selection", let value = items[0].value,
              let id = UUID(uuidString: value) else { return nil }
        selectionID = id.uuidString
    }
}

struct CloudyWindowEntry: Sendable {
    var date: Date
    var selection: CloudyWindowSelection
    var photo: CloudyWindowPreparedPhoto
    var isCloudy: Bool { selection.revealedAt == nil }
}

struct CloudyWindowPreparation: Sendable {
    var configuration: CloudyWindowConfiguration
    var authorityRevision: String
    var candidates: [PersonalRediscoveryCandidate]
    var existing: [CloudyWindowPreparedPhoto]
    var protectedPhotoIDs: Set<String>
}

private struct CloudyWindowState: Codable {
    var version = 1
    var configuration = CloudyWindowConfiguration()
    var profiles: [String: String] = [:]
    var metadata: [String: CloudyWindowPhotoMetadata] = [:]
    var photos: [CloudyWindowPreparedPhoto] = []
    var selections: [CloudyWindowSelection] = []
    var frozenSelectionIDs: [String: String]? = nil
    var seenPhotoIDs: Set<String> = []
    var albumPrototypeEnabled: Bool? = nil
    var albumArrival: CloudyWindowAlbumArrival? = nil
    /// Only a successful host WidgetCenter query can grant image preparation.
    /// Nil is an older install, not permission to render in the background.
    /// An empty set (WidgetKit answered: none placed) before any Widget was
    /// ever drawn still prepares the few newest cats of 「このiPhoneの猫写真」,
    /// so the first Widget draws its cloudy window at once (11/10).
    var installedSources: Set<String>? = nil
    /// Windows that have ever been given a photo. Without Plus, a window not
    /// in here still gets its first photo once (ADR-027 「最初の1枚」).
    var issuedScopeIDs: Set<String>? = nil
    /// 11/15: the last time the photos or their details changed (the app read
    /// the library or prepared an image). Tomorrow's cloudy photo chosen
    /// before then is chosen again.
    var libraryChangedAt: Date? = nil
    /// 11/15: capture years already shown on a date day, so another year
    /// comes first next time. Kept beyond the 40 days of selections.
    var datedYears: Set<Int>? = nil
    /// 11/15 節目: each cat's coming birthdays and days it came home, by
    /// profile ID (the same keys as `profiles`). Optional: older saves.
    var profileMilestones: [String: [CloudyWindowMilestoneDay]]? = nil
    /// 11/15: cats whose 旅立った日 is recorded (profile IDs, as `profiles`).
    /// A photo of only such cats never makes a date day. Optional: older
    /// saves have none.
    var departedProfileIDs: Set<String>? = nil
}

/// All experiment metadata and derived files are local. Every operation is
/// serialized with the existing personal-photo authority, including Intent
/// actions. Original Photos, favorites and sharing state are never mutated.
struct CloudyWindowStore: Sendable {
    static let shared = CloudyWindowStore()
    static let personalScope = "personal-library"
    static let profilePrefix = "personal-cat:"
    static let maximumPhotoCount = 32
    /// Before any Widget is placed: this many of the newest cats are kept
    /// ready (11/10: a Widget placed during the first run said 「写真を表示
    /// できません」 until the app was opened again).
    static let prePlacementPhotoCount = 3
    /// 11/15 毎日の1枚の決まり v2. A day is, in this order: a new day (a
    /// photo taken in the last `newPhotoDays` days and never shown; at most
    /// one in `newDayGap` days), a date day (a photo from an earlier year on
    /// this month and day, else within `dateWindowDays`; at most one in
    /// `dateDayGap` days), or an ordinary day (only photos taken more than
    /// `newPhotoDays` days ago). A window with fewer than `splitPhotoCount`
    /// such older photos keeps one rotation and only adds a new photo, never
    /// two days running. A 節目 day can come first later.
    static let newPhotoDays = 30
    static let newDayGap = 3
    static let dateDayGap = 7
    static let dateWindowDays = 3
    static let splitPhotoCount = 30
    /// The bounded pools keep this many new photos and, for each coming day,
    /// date photos, so the rest of the 32 / 100 stay older photos.
    static let preparedNewPhotoCount = 8
    static let preparedDateDays = 7
    static let maximumFileBytes = 220 * 1_024
    private let containerURL: URL?
    private let authorityStore: PersonalRediscoveryStore
    private let internalPresentation: Bool

    private static var defaultContainerURL: URL? {
#if PERSONAL_REDISCOVERY_CHECKS
        nil
#else
        SharedContainer.containerURL
#endif
    }

    init(containerURL: URL? = Self.defaultContainerURL,
         internalPresentation: Bool = CloudyWindowAvailability.isAvailable) {
        self.containerURL = containerURL
        authorityStore = PersonalRediscoveryStore(containerURL: containerURL)
        self.internalPresentation = internalPresentation
    }

    static var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 9 * 3_600)!
        return result
    }

    static func nextDay(after date: Date) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
    }

    /// 11/15: taken within `newPhotoDays` of `date` (and not in its future)
    /// and never shown. The capture date, not the day the app found it: an
    /// old photo that refills the pool is not new.
    static func isNewPhoto(takenAt captured: Date?, previouslyShown: Bool, at date: Date) -> Bool {
        guard !previouslyShown, let captured, captured <= date.addingTimeInterval(86_400) else { return false }
        return date.timeIntervalSince(captured) <= Double(newPhotoDays) * 86_400
    }

    /// 11/15: taken more than `newPhotoDays` days before `date`. An unknown
    /// capture date counts as old.
    static func isOldPhoto(takenAt captured: Date?, at date: Date) -> Bool {
        captured.map { date.timeIntervalSince($0) > Double(newPhotoDays) * 86_400 } ?? true
    }

    /// JST day number and civil date without Calendar, so a pass over the
    /// whole library stays cheap (days from civil, H. Hinnant).
    static func dayNumber(_ date: Date) -> Int {
        Int(((date.timeIntervalSince1970 + 32_400) / 86_400).rounded(.down))
    }

    static func civil(dayNumber: Int) -> (year: Int, month: Int, day: Int) {
        let z = dayNumber + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    static func dayNumber(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        return era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468
    }

    /// 11/15: how a photo taken on `capturedDay` (a JST day number) matches
    /// the day `targetDay`: the same month and day of an earlier year
    /// (offset 0), else within `dateWindowDays`. 2/29 falls on 2/28.
    static func dateMatch(capturedDay: Int, targetDay: Int) -> (offset: Int, yearsAgo: Int)? {
        let captured = civil(dayNumber: capturedDay), target = civil(dayNumber: targetDay)
        var best: (offset: Int, yearsAgo: Int)?
        for yearsAgo in max(1, target.year - captured.year - 1)...max(1, target.year - captured.year + 1) {
            let year = target.year - yearsAgo
            let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
            let day = target.month == 2 && target.day == 29 && !leap ? 28 : target.day
            let offset = abs(capturedDay - dayNumber(year: year, month: target.month, day: day))
            if offset <= dateWindowDays, best.map({ offset < $0.offset }) ?? true { best = (offset: offset, yearsAgo: yearsAgo) }
        }
        return best
    }

    static func dateMatch(takenAt captured: Date?, on date: Date) -> (offset: Int, yearsAgo: Int)? {
        captured.flatMap { dateMatch(capturedDay: dayNumber($0), targetDay: dayNumber(date)) }
    }

    /// 11/15: the host's newest new photos, so the bounded personal pool
    /// takes them in before tomorrow's photo is chosen.
    static func newPhotoIDs<S: Sequence>(_ items: S, now: Date = .now, id: (S.Element) -> String,
                                         takenAt: (S.Element) -> Date?) -> Set<String> {
        var recent: [(id: String, captured: Date)] = []
        for item in items {
            guard let captured = takenAt(item),
                  isNewPhoto(takenAt: captured, previouslyShown: false, at: now) else { continue }
            recent.append((id: id(item), captured: captured))
        }
        return Set(recent.sorted { $0.captured == $1.captured ? $0.id < $1.id : $0.captured > $1.captured }
            .prefix(preparedNewPhotoCount).map { $0.id })
    }

    /// 11/15: for today and each of the next `preparedDateDays` days, the two
    /// closest photos from an earlier year, so a date day finds one in the
    /// pool. Uses the capture dates already loaded; one pass, no Calendar.
    static func datePhotoIDs<S: Sequence>(_ items: S, now: Date = .now, id: (S.Element) -> String,
                                          takenAt: (S.Element) -> Date?) -> Set<String> {
        let today = dayNumber(now)
        let targets = Array(today...(today + preparedDateDays))
        var best: [Int: [(offset: Int, captured: Int, id: String)]] = [:]
        for item in items {
            guard let captured = takenAt(item) else { continue }
            let day = dayNumber(captured)
            guard day < today - 300 else { continue }
            for target in targets {
                guard let match = dateMatch(capturedDay: day, targetDay: target) else { continue }
                var list = best[target] ?? []
                list.append((offset: match.offset, captured: day, id: id(item)))
                list.sort { $0.offset == $1.offset ? ($0.captured == $1.captured ? $0.id < $1.id : $0.captured > $1.captured)
                    : $0.offset < $1.offset }
                best[target] = Array(list.prefix(2))
            }
        }
        return Set(best.values.flatMap { $0.map { $0.id } })
    }

    func configuration() -> CloudyWindowConfiguration {
        // Outside Version1 the cloudy window does not exist, whatever the
        // stored or default value says.
        guard internalPresentation else { return .init(enabled: false) }
        return (try? authorityStore.withAuthoritySnapshot { _ in try read().configuration }) ?? .init()
    }

    func configure(enabled: Bool, strength: CloudyWindowStrength) throws {
        guard internalPresentation else { return }
        try authorityStore.withAuthoritySnapshot { _ in
            var state = try read()
            let old = state.configuration
            guard old.enabled != enabled || old.strength != strength else { return }
            state.configuration = .init(enabled: enabled, strength: strength)
            // Re-enabling keeps today's committed photo and reveal state.
            try write(state)
        }
    }

    func isCloudySource(_ sourceID: String) -> Bool {
        guard internalPresentation else { return false }
        return (try? authorityStore.withAuthoritySnapshot { _ in
            let state = try read()
            return supports(sourceID, in: state)
        }) ?? false
    }

    /// Never changes the persisted Widget intent or the legacy personal-photo
    /// switch. Unknown WidgetKit results must not be supplied as an empty set.
    func synchronizeInstalledSources(_ sourceIDs: Set<String>) throws {
        guard internalPresentation else { return }
        try authorityStore.withAuthoritySnapshot { _ in
            var state = try read()
            let installed = Set(sourceIDs.filter { supports($0, in: state) })
            guard state.installedSources != installed || state.configuration.strength != .strong else { return }
            state.installedSources = installed
            state.configuration.strength = .strong
            state.configuration.revision = UUID().uuidString
            if installed.isEmpty { state.photos = [] }
            try write(state)
            collectFiles(keeping: Set(state.photos.flatMap(\.filenames)))
        }
    }

    /// Before the first Widget: WidgetKit answered "none", no window was ever
    /// given a photo, and 「このiPhoneの猫写真」 is cloudy.
    private func preparesBeforePlacement(_ state: CloudyWindowState) -> Bool {
        state.installedSources?.isEmpty == true && (state.issuedScopeIDs ?? []).isEmpty
            && state.selections.isEmpty && supports(Self.personalScope, in: state)
    }

    private func supports(_ sourceID: String, in state: CloudyWindowState) -> Bool {
        sourceID == Self.personalScope ? state.configuration.enabled : profileID(sourceID, in: state) != nil
    }

    /// Metadata contains only known personal candidates. Imported received
    /// photos are excluded by the host, so a hidden sender cannot reappear.
    func synchronize(metadata: [String: CloudyWindowPhotoMetadata], profiles: [String: String],
                     milestones: [String: [CloudyWindowMilestoneDay]] = [:], departed: Set<String> = [],
                     now: Date = .now) throws {
        guard internalPresentation else { return }
        try authorityStore.withAuthoritySnapshot(now: now) { authority in
            var state = try read()
            let relevant = Set(authority?.candidates.map { $0.item.localIdentifier } ?? [])
                .union(state.photos.map(\.photoID))
                .union(state.albumArrival.map { [$0.photoID] } ?? [])
            let kept = metadata.filter { relevant.contains($0.key) }
            let coming = milestones.filter { profiles[$0.key] != nil }
            let gone = departed.filter { profiles[$0] != nil }
            if state.metadata != kept || state.profiles != profiles || (state.profileMilestones ?? [:]) != coming
                || (state.departedProfileIDs ?? []) != gone {
                state.libraryChangedAt = now
            }
            state.profiles = profiles
            state.metadata = kept
            state.profileMilestones = coming.isEmpty ? nil : coming
            state.departedProfileIDs = gone.isEmpty ? nil : gone
            reconcile(&state, authority: authority, now: now)
            try write(state)
            collectFiles(keeping: Set(state.photos.flatMap(\.filenames)))
        }
    }

    /// Called after the host resolves current album inputs. Unread old archives
    /// and months closed before enabling the prototype are never deliveries.
    @discardableResult
    func synchronizeAlbumArrival(enabled: Bool, enabledAt: Date?, openedPeriods: Set<String>,
                                 arrival: CloudyWindowAlbumArrival?, now: Date = .now) throws -> Bool {
        guard internalPresentation else { return false }
        return try authorityStore.withAuthoritySnapshot(now: now) { authority in
            var state = try read()
            let today = Self.calendar.startOfDay(for: now)
            let nextClosing = Calendar.current.dateInterval(of: .month, for: now)?.end
            let valid = arrival.flatMap { value -> CloudyWindowAlbumArrival? in
                guard enabled, let enabledAt, enabledAt < value.availableAt,
                      !openedPeriods.contains(value.period),
                      value.day == today || value.availableAt == nextClosing,
                      Self.validPeriod(value.period, closingAt: value.availableAt),
                      authority?.isAuthorized == true,
                      authority?.eligiblePhotoIDs.contains(value.photoID) == true else { return nil }
                return value
            }
            let oldSelections = state.selections
            for index in state.selections.indices where state.selections[index].revealedAt == nil {
                if let period = state.selections[index].albumPeriod,
                   openedPeriods.contains(period) || (enabled && period != valid?.period) {
                    state.selections[index].albumPeriod = nil
                }
            }
            guard state.albumPrototypeEnabled != enabled || state.albumArrival != valid
                || state.selections != oldSelections else { return false }
            state.albumPrototypeEnabled = enabled
            state.albumArrival = valid
            try write(state)
            return true
        }
    }

    func albumPriorityPhotoIDs(now: Date = .now) -> Set<String> {
        guard internalPresentation else { return [] }
        return (try? authorityStore.withAuthoritySnapshot(now: now) { authority in
            let state = try read()
            guard state.installedSources?.isEmpty == false, state.albumPrototypeEnabled == true, let arrival = state.albumArrival,
                  arrival.day >= Self.calendar.startOfDay(for: now),
                  arrival.availableAt <= (Calendar.current.dateInterval(of: .month, for: now)?.end ?? now),
                  authority?.isAuthorized == true,
                  authority?.eligiblePhotoIDs.contains(arrival.photoID) == true else { return [] }
            return Set([arrival.photoID])
        }) ?? []
    }

    func albumPeriod(for route: CloudyWindowAlbumRoute, now: Date = .now) -> String? {
        guard internalPresentation else { return nil }
        return try? authorityStore.withAuthoritySnapshot(now: now) { authority in
            let state = try read()
            guard state.albumPrototypeEnabled == true,
                  let selection = state.selections.first(where: { $0.id == route.selectionID }),
                  supports(selection.scopeID, in: state), selection.day == Self.calendar.startOfDay(for: now),
                  selection.revealedAt != nil, let period = selection.albumPeriod,
                  let photo = state.photos.first(where: { $0.photoID == selection.photoID }),
                  valid(photo, in: state, authority: authority), filesExist(photo) else { return nil }
            return period
        }
    }

    /// Album months use the device calendar, while cloudy days use JST. A
    /// closing time inside a JST day must wake the provider at that time too.
    func nextRefresh(after now: Date) -> Date {
        let tomorrow = Self.nextDay(after: now)
        guard internalPresentation else { return tomorrow }
        return (try? authorityStore.withAuthoritySnapshot(now: now) { authority in
            let state = try read()
            guard state.albumPrototypeEnabled == true,
                  let arrival = state.albumArrival, arrival.availableAt > now,
                  arrival.availableAt < tomorrow, authority?.isAuthorized == true,
                  let photo = state.photos.first(where: { $0.photoID == arrival.photoID }),
                  valid(photo, in: state, authority: authority), filesExist(photo) else { return tomorrow }
            return arrival.availableAt
        }) ?? tomorrow
    }

    private static func validPeriod(_ period: String, closingAt date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let interval = calendar.dateInterval(of: .month, for: date), interval.start == date,
              let previous = calendar.date(byAdding: .month, value: -1, to: date) else { return false }
        return period == String(format: "%04d-%02d", calendar.component(.year, from: previous),
                                calendar.component(.month, from: previous))
    }

    func profiles() -> [(id: String, name: String)] {
        guard internalPresentation else { return [] }
        return (try? authorityStore.withAuthoritySnapshot { authority in
            let state = try read()
            guard authority?.isAuthorized == true else { return [] }
            return state.profiles.sorted { $0.key < $1.key }.map { (id: $0.key, name: $0.value) }
        }) ?? []
    }

    func preparation(now: Date = .now) throws -> CloudyWindowPreparation? {
        guard internalPresentation else { return nil }
        return try authorityStore.withAuthoritySnapshot(now: now) { authority in
            guard let authority, authority.isAuthorized else { return nil }
            var state = try read()
            guard let installed = state.installedSources else { return nil }
            reconcile(&state, authority: authority, now: now)
            // The capture date the window chooses by (the same record).
            let taken = { (candidate: PersonalRediscoveryCandidate) in
                state.metadata[candidate.item.localIdentifier]?.creationDate ?? candidate.creationDate
            }
            let available = authority.candidates.filter { state.metadata[$0.item.localIdentifier] != nil }
                .sorted { (taken($0) ?? .distantPast) > (taken($1) ?? .distantPast) }
            if installed.isEmpty {
                // No Widget yet, and none ever drawn: the newest few cats of
                // 「このiPhoneの猫写真」 only, cloudy like every first photo
                // (11/10). Removing a Widget later still releases everything.
                guard preparesBeforePlacement(state) else { return nil }
                let planned = Array(available.prefix(Self.prePlacementPhotoCount))
                return .init(configuration: state.configuration, authorityRevision: authority.eligibilityRevision,
                             candidates: planned, existing: state.photos.filter(filesExist),
                             protectedPhotoIDs: protectedSelections(in: state, now: now)
                                .union(planned.map { $0.item.localIdentifier }))
            }
            let month = Self.calendar.component(.month, from: now)
            var pools = [
                available.filter { !state.seenPhotoIDs.contains($0.item.localIdentifier)
                    && state.metadata[$0.item.localIdentifier]?.previouslyShown != true },
                available.filter { candidate in
                    guard let date = candidate.creationDate,
                          Self.calendar.component(.year, from: date) < Self.calendar.component(.year, from: now) else { return false }
                    let distance = abs(Self.calendar.component(.month, from: date) - month)
                    return min(distance, 12 - distance) <= 1
                },
                available.filter { $0.creationDate.map { now.timeIntervalSince($0) <= 30 * 86_400 } ?? false },
                available
            ]
            // 11/15: with enough older photos, the ordinary days' share of the
            // 32 holds older photos only; new and date photos come below.
            if available.filter({ Self.isOldPhoto(takenAt: taken($0), at: now) }).count >= Self.splitPhotoCount {
                pools = pools.map { pool in pool.filter { Self.isOldPhoto(takenAt: taken($0), at: now) } }
            }
            var candidates: [PersonalRediscoveryCandidate] = []
            var collected = Set<String>()
            while pools.contains(where: { !$0.isEmpty }) {
                for index in pools.indices where !pools[index].isEmpty {
                    let candidate = pools[index].removeFirst()
                    if collected.insert(candidate.item.localIdentifier).inserted { candidates.append(candidate) }
                }
            }
            // Interleave known cats before filling the bounded preparation pool.
            // Keep already-issued images even when a new batch arrives.
            let pinned = protectedSelections(in: state, now: now)
            let arrivalID = state.albumPrototypeEnabled == true
                && (state.albumArrival?.day ?? .distantPast) >= Self.calendar.startOfDay(for: now)
                ? state.albumArrival?.photoID : nil
            var ordered = available.filter { $0.item.localIdentifier == arrivalID }
            ordered += available.filter { pinned.contains($0.item.localIdentifier)
                && $0.item.localIdentifier != arrivalID }
            // 11/15: then the newest new photos (8 at most) and, for each of
            // the coming days, its closest date photo, so a new day and a
            // date day each find theirs. The rest stays older photos.
            let newPhotos = available.filter { candidate in
                let id = candidate.item.localIdentifier
                guard let metadata = state.metadata[id], !state.seenPhotoIDs.contains(id) else { return false }
                return Self.isNewPhoto(takenAt: metadata.creationDate, previouslyShown: metadata.previouslyShown, at: now)
            }.prefix(Self.preparedNewPhotoCount)
            let shownRecently = Set(state.selections.filter { now.timeIntervalSince($0.day) < 30 * 86_400 }.map(\.photoID))
            var datePhotos: [PersonalRediscoveryCandidate] = []
            var day = Self.calendar.startOfDay(for: now)
            for _ in 0..<Self.preparedDateDays {
                day = Self.nextDay(after: day)
                let best = available.compactMap { candidate -> (candidate: PersonalRediscoveryCandidate, offset: Int)? in
                    guard !shownRecently.contains(candidate.item.localIdentifier),
                          !Self.showsOnlyDeparted(state.metadata[candidate.item.localIdentifier], in: state),
                          let match = Self.dateMatch(takenAt: taken(candidate), on: day) else { return nil }
                    return (candidate: candidate, offset: match.offset)
                }.min { $0.offset < $1.offset }
                if let best { datePhotos.append(best.candidate) }
            }
            // 11/15 節目: a cat whose birthday or day it came home is within
            // the coming week keeps two of its photos ready (one with all
            // such cats first).
            let today = Self.calendar.startOfDay(for: now)
            let weekEnd = today.addingTimeInterval(Double(Self.preparedDateDays) * 86_400 + 3_600)
            let soonCats = Set((state.profileMilestones ?? [:]).filter { id, marks in
                state.profiles[id] != nil && marks.contains { $0.day >= today && $0.day <= weekEnd && $0.years >= 1 }
            }.keys)
            var milestonePhotos: [PersonalRediscoveryCandidate] = []
            if !soonCats.isEmpty {
                let cats = { (candidate: PersonalRediscoveryCandidate) in
                    state.metadata[candidate.item.localIdentifier]?.profileIDs ?? []
                }
                let unshown = available.filter { !shownRecently.contains($0.item.localIdentifier) }
                let pool = unshown.isEmpty ? available : unshown
                if soonCats.count > 1, let together = pool.first(where: { soonCats.isSubset(of: cats($0)) }) {
                    milestonePhotos.append(together)
                }
                for cat in soonCats.sorted() {
                    milestonePhotos += pool.filter { cats($0).contains(cat) }.prefix(2)
                }
            }
            for candidate in Array(newPhotos) + datePhotos + milestonePhotos where !ordered.contains(where: {
                $0.item.localIdentifier == candidate.item.localIdentifier
            }) { ordered.append(candidate) }
            let groups = state.profiles.keys.sorted()
            var queues = groups.map { profile in
                candidates.filter { state.metadata[$0.item.localIdentifier]?.profileIDs.contains(profile) == true }
            }
            while queues.contains(where: { !$0.isEmpty }), ordered.count < Self.maximumPhotoCount {
                for index in queues.indices where !queues[index].isEmpty {
                    let candidate = queues[index].removeFirst()
                    if !ordered.contains(where: { $0.item.localIdentifier == candidate.item.localIdentifier }) {
                        ordered.append(candidate)
                    }
                }
            }
            for candidate in candidates where !ordered.contains(where: {
                $0.item.localIdentifier == candidate.item.localIdentifier
            }) { ordered.append(candidate) }
            let retainedOutsidePool = pinned.subtracting(Set(ordered.map { $0.item.localIdentifier }))
            let planned = Array(ordered.prefix(max(0, Self.maximumPhotoCount - retainedOutsidePool.count)))
            return .init(configuration: state.configuration, authorityRevision: authority.eligibilityRevision,
                         candidates: planned, existing: state.photos.filter(filesExist),
                         protectedPhotoIDs: pinned.union(planned.map { $0.item.localIdentifier }))
        }
    }

    /// Publish complete clear/cloudy image pairs only, under the permission
    /// lock. A stale render cannot revive a removed photo or old strength.
    func publish(_ photo: CloudyWindowPreparedPhoto, files: [String: Data],
                 authorityRevision: String, configurationRevision: String,
                 protectedPhotoIDs: Set<String> = [], now: Date = .now) throws {
        try authorityStore.withAuthoritySnapshot(now: now) { authority in
            var state = try read()
            let beforePlacement = state.installedSources?.isEmpty == true
            guard internalPresentation, let installed = state.installedSources,
                  !installed.isEmpty || preparesBeforePlacement(state),
                  state.configuration.revision == configurationRevision,
                  authority?.eligibilityRevision == authorityRevision,
                  valid(photo, in: state, authority: authority),
                  photo.strength == state.configuration.strength,
                  Set(files.keys) == Set(photo.filenames),
                  files.values.allSatisfy({ !$0.isEmpty && $0.count <= Self.maximumFileBytes })
            else { throw PersonalRediscoveryStore.Error.staleRevision }
            state.photos.removeAll { $0.photoID == photo.photoID }
            if beforePlacement {
                // Before placement the set stays at the planned few.
                let pinned = protectedSelections(in: state, now: now).union(protectedPhotoIDs)
                state.photos.removeAll { !pinned.contains($0.photoID) }
            }
            if state.photos.count >= Self.maximumPhotoCount {
                let pinned = protectedSelections(in: state, now: now).union(protectedPhotoIDs)
                guard let index = state.photos.firstIndex(where: { !pinned.contains($0.photoID) }) else {
                    throw PersonalRediscoveryStore.Error.cacheBudgetExceeded
                }
                state.photos.remove(at: index)
            }
            let directory = try imageDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (filename, bytes) in files {
                let url = directory.appendingPathComponent(filename)
                try bytes.write(to: url, options: .atomic)
#if os(iOS)
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                       ofItemAtPath: url.path)
#endif
            }
            state.photos.append(photo)
            state.libraryChangedAt = now
            try write(state)
            collectFiles(keeping: Set(state.photos.flatMap(\.filenames)))
        }
    }

    func timeline(scopeID: String, now: Date = .now, allowsSelection: Bool = true,
                  selectionValidUntil: Date? = nil) throws -> [CloudyWindowEntry] {
        guard internalPresentation else { return [] }
        let entries: [CloudyWindowEntry] = try authorityStore.withAuthoritySnapshot(now: now) { authority in
            var state = try read()
            guard supports(scopeID, in: state), authority?.isAuthorized == true else { return [] }
            reconcile(&state, authority: authority, now: now)
            // Older installs: any window with a selection was issued one.
            let issued = (state.issuedScopeIDs ?? []).union(state.selections.map(\.scopeID))
            let today = Self.calendar.startOfDay(for: now)
            let tomorrow = Self.nextDay(after: now)
            var entries: [CloudyWindowEntry] = []
            for date in [today, tomorrow] {
                let maySelect = allowsSelection && (selectionValidUntil.map { date < $0 } ?? true)
                var selection = state.selections.first { $0.scopeID == scopeID && $0.day == date }
                if !maySelect {
                    // Keep the last issued photo through membership expiry,
                    // with its exact cloudy/revealed state. Never grant a new day.
                    selection = state.selections.filter {
                        $0.scopeID == scopeID && $0.day <= now
                    }.filter { value in selectionValidUntil.map { value.day < $0 } ?? true }
                        .max { $0.day < $1.day }
                    // Never given a photo: without Plus the window still gets
                    // its first one, kept from then on. Only once per window,
                    // so an expired window does not start choosing again
                    // (11/6: a free widget stayed empty).
                    if selection == nil, date == today, !issued.contains(scopeID),
                       let first = choose(state: state, scopeID: scopeID, date: date, now: now) {
                        selection = first
                        state.selections.append(first)
                    }
                    if let selection {
                        var frozen = state.frozenSelectionIDs ?? [:]
                        frozen[scopeID] = selection.id
                        state.frozenSelectionIDs = frozen
                    }
                } else if date == today {
                    state.frozenSelectionIDs?[scopeID] = nil
                }
                if maySelect, selection?.revealedAt == nil,
                   state.albumPrototypeEnabled == true, let arrival = state.albumArrival,
                   arrival.day == date, arrival.availableAt <= max(now, date),
                   let cover = state.photos.first(where: { $0.photoID == arrival.photoID }), filesExist(cover),
                   scopeID == Self.personalScope || state.metadata[cover.photoID]?.profileIDs.contains(
                    String(scopeID.dropFirst(Self.profilePrefix.count))) == true,
                   selection?.albumPeriod != arrival.period {
                    if let old = selection { state.selections.removeAll { $0.id == old.id } }
                    let chosen = CloudyWindowSelection(scopeID: scopeID, day: date,
                        photoID: cover.photoID, profileID: profileID(scopeID, in: state), albumPeriod: arrival.period)
                    selection = chosen
                    state.selections.append(chosen)
                }
                // 11/15: once the app read new photos (or prepared one),
                // tomorrow's photo is chosen again while it is still cloudy,
                // not here yet and not the monthly cover. Today's never is.
                if maySelect, date > today, let planned = selection,
                   planned.revealedAt == nil, planned.albumPeriod == nil,
                   let changed = state.libraryChangedAt, (planned.chosenAt ?? .distantPast) < changed,
                   let index = state.selections.firstIndex(where: { $0.id == planned.id }) {
                    if let chosen = choose(state: state, scopeID: scopeID, date: date, now: now),
                       chosen.photoID != planned.photoID {
                        state.selections[index] = chosen
                        selection = chosen
                    } else {
                        state.selections[index].chosenAt = now
                        selection = state.selections[index]
                    }
                }
                if selection == nil && maySelect,
                   let chosen = choose(state: state, scopeID: scopeID, date: date, now: now) {
                    selection = chosen
                    state.selections.append(chosen)
                }
                guard let selection,
                      let photo = state.photos.first(where: { $0.photoID == selection.photoID }),
                      filesExist(photo) else { continue }
                if date <= now, state.seenPhotoIDs.count < 100_000 { state.seenPhotoIDs.insert(photo.photoID) }
                if date <= now, selection.kind == .date, let captured = state.metadata[photo.photoID]?.creationDate {
                    var years = state.datedYears ?? []
                    if years.count < 200, years.insert(Self.civil(dayNumber: Self.dayNumber(captured)).year).inserted {
                        state.datedYears = years
                    }
                }
                var visibleSelection = selection
                if state.albumPrototypeEnabled != true || selection.day != date {
                    visibleSelection.albumPeriod = nil
                }
                entries.append(.init(date: date == today ? now : date, selection: visibleSelection, photo: photo))
            }
            state.issuedScopeIDs = issued.union(state.selections.map(\.scopeID))
            try write(state)
            return entries
        }
        // This runs after releasing the authority lock. The second commit
        // independently checks current permission; failure never grants access.
        for entry in entries {
            try authorityStore.recordExternalWidgetIssue(slotID: "cloudy-" + entry.selection.id,
                photoID: entry.photo.photoID, scheduledAt: entry.selection.day, now: now)
        }
        return entries
    }

    @discardableResult
    func reveal(selectionID: String, scopeID: String, photoID: String,
                now: Date = .now, allowsSelection: Bool = true,
                selectionValidUntil: Date? = nil) throws -> Bool {
        guard internalPresentation else { return false }
        return try authorityStore.withAuthoritySnapshot(now: now) { authority in
            var state = try read()
            guard supports(scopeID, in: state), authority?.isAuthorized == true else { return false }
            reconcile(&state, authority: authority, now: now)
            guard let index = state.selections.firstIndex(where: {
                $0.id == selectionID && $0.scopeID == scopeID && $0.photoID == photoID
            }), let photo = state.photos.first(where: { $0.photoID == photoID }), filesExist(photo) else { return false }
            let selection = state.selections[index]
            guard selectionValidUntil.map({ selection.day < $0 }) ?? true else { return false }
            let today = Self.calendar.startOfDay(for: now)
            let latestIssued = state.selections.filter { value in
                value.scopeID == scopeID && value.day <= now
                    && (selectionValidUntil.map { value.day < $0 } ?? true)
            }.max(by: { $0.day < $1.day })?.id == selectionID
            let frozen = !allowsSelection && latestIssued
            if selection.day < today, allowsSelection, latestIssued, selection.revealedAt == nil,
               selectionValidUntil.map({ today < $0 }) ?? true,
               !state.selections.contains(where: { $0.scopeID == scopeID && $0.day == today }) {
                // iOS skipped the midnight reload, so this cloudy photo is the
                // one on screen. Clearing it makes it today's photo instead of
                // swapping in a different one the tap never showed.
                state.selections[index].day = today
                state.selections[index].albumPeriod = nil
                // 11/15: its date or 節目 was another day's; the photo stays.
                state.selections[index].dayKind = nil
                state.selections[index].milestone = nil
                state.selections[index].revealedAt = now
                state.seenPhotoIDs.insert(photoID)
                try write(state)
                return true
            }
            guard selection.day == today || frozen else { return false }
            if selection.revealedAt == nil {
                state.selections[index].revealedAt = now
                state.seenPhotoIDs.insert(photoID)
                try write(state)
            }
            return true
        }
    }

    /// Test builds only: cloud today's window again, so the clearing can be
    /// seen again without waiting for tomorrow. The photo stays the same.
    func cloudTodayAgain(now: Date = .now) throws {
        guard internalPresentation else { return }
        try authorityStore.withAuthoritySnapshot(now: now) { _ in
            var state = try read()
            let today = Self.calendar.startOfDay(for: now)
            var changed = false
            for index in state.selections.indices where state.selections[index].day == today
                && state.selections[index].revealedAt != nil {
                state.selections[index].revealedAt = nil
                changed = true
            }
            if changed { try write(state) }
        }
    }

    /// Whether a window was cleared by its tag at least once (read only): the
    /// first Plus offer waits for it, or for the next day (11/10).
    func hasRevealedAnyWindow() -> Bool {
        guard internalPresentation else { return false }
        return (try? authorityStore.withAuthoritySnapshot { _ in
            try read().selections.contains { $0.revealedAt != nil }
        }) ?? false
    }

    /// Photos revealed in the window between the dates (read only), for the
    /// album prototype's monthly story.
    func revealedPhotos(from start: Date, to end: Date) -> [(photoID: String, revealedAt: Date)] {
        guard internalPresentation else { return [] }
        let selections = (try? authorityStore.withAuthoritySnapshot { _ in try read().selections }) ?? []
        return selections.compactMap { selection in
            guard let revealedAt = selection.revealedAt, revealedAt >= start, revealedAt < end else { return nil }
            return (selection.photoID, revealedAt)
        }
    }

    func noteViewed(photoID: String) {
        guard internalPresentation else { return }
        try? authorityStore.withAuthoritySnapshot { authority in
            var state = try read()
            guard state.installedSources?.isEmpty == false, authority?.eligiblePhotoIDs.contains(photoID) == true,
                  state.seenPhotoIDs.count < 100_000, !state.seenPhotoIDs.contains(photoID) else { return }
            state.seenPhotoIDs.insert(photoID)
            try write(state)
        }
    }

    func imageURL(filename: String, scopeID: String = Self.personalScope) -> URL? {
        guard internalPresentation, Self.validFilename(filename) else { return nil }
        return try? authorityStore.withAuthoritySnapshot { authority in
            let state = try read()
            guard supports(scopeID, in: state), let photo = state.photos.first(where: { $0.filenames.contains(filename) }),
                  valid(photo, in: state, authority: authority) else { return nil }
            if scopeID != Self.personalScope {
                guard let profile = profileID(scopeID, in: state),
                      state.metadata[photo.photoID]?.profileIDs.contains(profile) == true else { return nil }
            }
            let url = try imageDirectory().appendingPathComponent(filename)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    /// 11/15: new (see `isNewPhoto`), not seen in any window, and never this
    /// window's photo before `date`.
    private func isNew(_ photoID: String, scopeID: String, date: Date, in state: CloudyWindowState) -> Bool {
        guard let metadata = state.metadata[photoID], !state.seenPhotoIDs.contains(photoID),
              !state.selections.contains(where: { $0.scopeID == scopeID && $0.day < date && $0.photoID == photoID })
        else { return false }
        return Self.isNewPhoto(takenAt: metadata.creationDate, previouslyShown: metadata.previouslyShown, at: date)
    }

    /// 11/15: a photo whose cats have all died, so a date day never says
    /// 「1年前のきょう」 over it. A photo with no cat, or with a living cat
    /// too, is not.
    private static func showsOnlyDeparted(_ metadata: CloudyWindowPhotoMetadata?, in state: CloudyWindowState) -> Bool {
        guard let cats = metadata?.profileIDs, !cats.isEmpty, let departed = state.departedProfileIDs else { return false }
        return cats.isSubset(of: departed)
    }

    /// 11/15: the app's heart, then the Photos app's favorite, then a cat
    /// that fits every Widget size. Smaller comes first.
    private func quality(_ photo: CloudyWindowPreparedPhoto, in state: CloudyWindowState) -> Int {
        let metadata = state.metadata[photo.photoID]
        let fits = photo.source.renderPlans.map { plans in
            [plans.small, plans.medium, plans.large].allSatisfy { $0.compositionMode == .catFullBleed }
        } ?? false
        return (metadata?.isLiked == true ? 0 : 4) + (metadata?.isPhotosFavorite == true ? 0 : 2) + (fits ? 0 : 1)
    }

    /// 11/15: whether a day of this kind came within `gap` days before
    /// `date` in this window (`gap` 3: the previous 2 days).
    private func hadKind(_ kind: CloudyWindowDayKind, within gap: Int, before date: Date,
                         in previous: [CloudyWindowSelection]) -> Bool {
        previous.contains { $0.kind == kind && date.timeIntervalSince($0.day) < (Double(gap) - 0.5) * 86_400 }
    }

    /// 11/15 節目: this window's cats (all in the household window) with a
    /// birthday or a day they came home on `date`, a year or more on.
    private func milestoneCats(_ kind: CloudyWindowMilestoneKind, on date: Date, scopeProfile: String?,
                               in state: CloudyWindowState) -> [(id: String, years: Int)] {
        state.profiles.keys.sorted().filter { id in scopeProfile.map { $0 == id } ?? true }.compactMap { id -> (id: String, years: Int)? in
            guard let mark = state.profileMilestones?[id]?.first(where: {
                $0.day == date && $0.kind == kind.rawValue && $0.years >= 1
            }) else { return nil }
            return (id: id, years: mark.years)
        }
    }

    /// 11/15 節目: a photo with every cat if there is one, else the photo of
    /// the cat shown least lately. A photo shown in the last 30 days only
    /// when there is no other.
    private func milestonePhoto(for cats: [String], from candidates: [CloudyWindowPreparedPhoto],
                                previous: [CloudyWindowSelection], recent: Set<String>,
                                in state: CloudyWindowState) -> CloudyWindowPreparedPhoto? {
        func best(_ photos: [CloudyWindowPreparedPhoto]) -> CloudyWindowPreparedPhoto? {
            let unshown = photos.filter { !recent.contains($0.photoID) }
            return (unshown.isEmpty ? photos : unshown).min { lhs, rhs in
                let a = previous.first { $0.photoID == lhs.photoID }?.day ?? .distantPast
                let b = previous.first { $0.photoID == rhs.photoID }?.day ?? .distantPast
                if a != b { return a < b }
                let qualityA = quality(lhs, in: state), qualityB = quality(rhs, in: state)
                if qualityA != qualityB { return qualityA < qualityB }
                return lhs.photoID < rhs.photoID
            }
        }
        let shown = { (photoID: String) in state.metadata[photoID]?.profileIDs ?? [] }
        let everyone = Set(cats)
        if let together = best(candidates.filter { everyone.isSubset(of: shown($0.photoID)) }) { return together }
        let lastShown = { (cat: String) in
            previous.first { shown($0.photoID).contains(cat) }?.day ?? .distantPast
        }
        for cat in cats.sorted(by: { lastShown($0) == lastShown($1) ? $0 < $1 : lastShown($0) < lastShown($1) }) {
            if let photo = best(candidates.filter { shown($0.photoID).contains(cat) }) { return photo }
        }
        return nil
    }

    private func choose(state: CloudyWindowState, scopeID: String, date: Date,
                        now: Date) -> CloudyWindowSelection? {
        let profile = profileID(scopeID, in: state)
        let previous = state.selections.filter { $0.scopeID == scopeID && $0.day < date }.sorted { $0.day > $1.day }
        var candidates = state.photos.filter { photo in
            guard let metadata = state.metadata[photo.photoID], filesExist(photo) else { return false }
            return profile.map { metadata.profileIDs.contains($0) } ?? true
        }.sorted { $0.photoID < $1.photoID }
        // Keep one representative of a burst / very similar nearby capture.
        var unique: [CloudyWindowPreparedPhoto] = []
        for photo in candidates {
            guard !unique.contains(where: { similar(photo, $0, metadata: state.metadata) }) else { continue }
            unique.append(photo)
        }
        candidates = unique
        // 11/14: たぶん猫 only where nothing better exists. In this cat's
        // window, only when the cat has no 確かな猫; in the household window a
        // cat whose photos are all たぶん猫 keeps them, so it still gets turns.
        let isProbable = { (photo: CloudyWindowPreparedPhoto) in
            state.metadata[photo.photoID]?.isProbableCat == true
        }
        let confidentCats = Set(candidates.filter { !isProbable($0) }
            .flatMap { state.metadata[$0.photoID]?.profileIDs ?? [] })
        let surest = candidates.filter { photo in
            guard isProbable(photo) else { return true }
            let cats = state.metadata[photo.photoID]?.profileIDs ?? []
            return profile == nil && !cats.isEmpty && cats.isDisjoint(with: confidentCats)
        }
        if !surest.isEmpty { candidates = surest }
        if candidates.count > 1, let last = previous.first {
            candidates.removeAll { $0.photoID == last.photoID }
        }
        guard !candidates.isEmpty else { return nil }
        func made(_ photo: CloudyWindowPreparedPhoto, _ kind: CloudyWindowDayKind, profileID: String?,
                  match: (offset: Int, yearsAgo: Int)? = nil) -> CloudyWindowSelection {
            let cats = state.metadata[photo.photoID]?.profileIDs ?? []
            return CloudyWindowSelection(scopeID: scopeID, day: date, photoID: photo.photoID,
                profileID: profileID ?? state.profiles.keys.sorted().first(where: { cats.contains($0) }),
                dayKind: kind.rawValue, dateYearsAgo: match?.yearsAgo,
                dateSameDay: match.map { $0.offset == 0 }, chosenAt: now)
        }
        let recent = Set(previous.filter { date.timeIntervalSince($0.day) < 30 * 86_400 }.map(\.photoID))
        // 11/15 節目: a cat of this window has its birthday (first) or the day
        // it came home. One photo with all of them if there is one, else the
        // cat shown least lately. Without a photo of them, no 節目 day.
        for kind in [CloudyWindowMilestoneKind.birthday, .adoption] {
            let cats = milestoneCats(kind, on: date, scopeProfile: profile, in: state)
            guard !cats.isEmpty, let photo = milestonePhoto(for: cats.map { $0.id }, from: candidates,
                                                             previous: previous, recent: recent, in: state) else { continue }
            let shown = state.metadata[photo.photoID]?.profileIDs ?? []
            let milestone = CloudyWindowMilestone(kind: kind.rawValue, cats: cats.map { cat in
                .init(id: cat.id, name: state.profiles[cat.id] ?? "", years: cat.years, inPhoto: shown.contains(cat.id))
            })
            return CloudyWindowSelection(scopeID: scopeID, day: date, photoID: photo.photoID,
                profileID: profile ?? cats.first(where: { shown.contains($0.id) })?.id,
                dayKind: CloudyWindowDayKind.milestone.rawValue, chosenAt: now, milestone: milestone)
        }
        // 11/15: enough older photos in this window: the kinds of day apply.
        // Fewer: one rotation, and a new photo never two days running.
        let older = state.metadata.values.filter { metadata in
            Self.isOldPhoto(takenAt: metadata.creationDate, at: date)
                && (profile.map { metadata.profileIDs.contains($0) } ?? true)
        }.count
        let splits = older >= Self.splitPhotoCount
        // New day: the newest new photo, by the day it was taken; within a
        // day the app's heart, the Photos favorite, a fitting cat. Ahead of
        // the cats' turns.
        if !hadKind(.new, within: splits ? Self.newDayGap : 2, before: date, in: previous) {
            let newest = candidates.filter { isNew($0.photoID, scopeID: scopeID, date: date, in: state) }
                .min { lhs, rhs in
                    let a = state.metadata[lhs.photoID]?.creationDate ?? .distantPast
                    let b = state.metadata[rhs.photoID]?.creationDate ?? .distantPast
                    let dayA = Self.dayNumber(a), dayB = Self.dayNumber(b)
                    if dayA != dayB { return dayA > dayB }
                    let qualityA = quality(lhs, in: state), qualityB = quality(rhs, in: state)
                    if qualityA != qualityB { return qualityA < qualityB }
                    return a == b ? lhs.photoID < rhs.photoID : a > b
                }
            if let newest { return made(newest, .new, profileID: profile) }
        }
        // Date day: the same month and day of an earlier year first, then
        // within 3 days; a year not yet shown on a date day first. Never a
        // photo shown in the last 30 days.
        // 11/15: never a date day in the window of a cat that has died.
        if splits, !hadKind(.date, within: Self.dateDayGap, before: date, in: previous),
           !(profile.map { state.departedProfileIDs?.contains($0) == true } ?? false) {
            let datedYears = state.datedYears ?? []
            let datedPhotos = Set(previous.filter { $0.kind == .date }.map(\.photoID))
            var best: (photo: CloudyWindowPreparedPhoto, offset: Int, yearsAgo: Int, rank: [Int])?
            for photo in candidates where !recent.contains(photo.photoID)
                && !Self.showsOnlyDeparted(state.metadata[photo.photoID], in: state) {
                guard let captured = state.metadata[photo.photoID]?.creationDate,
                      let match = Self.dateMatch(takenAt: captured, on: date) else { continue }
                let year = Self.civil(dayNumber: Self.dayNumber(captured)).year
                let rank = [match.offset > 0 ? 1 : 0, datedYears.contains(year) ? 1 : 0,
                            datedPhotos.contains(photo.photoID) ? 1 : 0, match.offset, quality(photo, in: state),
                            -Int(captured.timeIntervalSince1970)]
                if let current = best, !rank.lexicographicallyPrecedes(current.rank) { continue }
                best = (photo: photo, offset: match.offset, yearsAgo: match.yearsAgo, rank: rank)
            }
            if let best {
                return made(best.photo, .date, profileID: profile, match: (offset: best.offset, yearsAgo: best.yearsAgo))
            }
        }
        // Ordinary day. With enough older photos, only those.
        if splits {
            let old = candidates.filter { Self.isOldPhoto(takenAt: state.metadata[$0.photoID]?.creationDate, at: date) }
            if !old.isEmpty { candidates = old }
        }
        var selectedProfile = profile
        if profile == nil {
            let groups = state.profiles.keys.sorted().filter { id in
                candidates.contains { state.metadata[$0.photoID]?.profileIDs.contains(id) == true }
            }
            if !groups.isEmpty {
                let last = previous.first?.profileID
                let next = groups.first { $0 != last } ?? groups[0]
                // Least recently shown known cat; alphabetical IDs never
                // starve a third or fourth cat in the daily rotation.
                selectedProfile = groups.filter { $0 != last }.min { lhs, rhs in
                    let a = previous.first { $0.profileID == lhs }?.day ?? .distantPast
                    let b = previous.first { $0.profileID == rhs }?.day ?? .distantPast
                    return a == b ? lhs < rhs : a < b
                } ?? next
                candidates = candidates.filter { state.metadata[$0.photoID]?.profileIDs.contains(selectedProfile!) == true }
            }
        }
        guard !candidates.isEmpty else { return nil }
        // Rotate cats first. A cat with one photo must still get a turn when
        // another cat has hundreds; repeat avoidance then applies within it.
        let unusedRecently = candidates.filter { !recent.contains($0.photoID) }
        if !unusedRecently.isEmpty { candidates = unusedRecently }
        let channel = Int(floor(date.timeIntervalSince1970 / 86_400)) % 3
        let preferred = candidates.filter { photo in
            guard let metadata = state.metadata[photo.photoID] else { return false }
            switch channel {
            case 0: return !splits && !metadata.previouslyShown && !state.seenPhotoIDs.contains(photo.photoID)
            case 1:
                // One day in three: the same season of an earlier year.
                guard let captured = metadata.creationDate,
                      Self.calendar.component(.year, from: captured) < Self.calendar.component(.year, from: date) else { return false }
                let distance = abs(Self.calendar.component(.month, from: captured) - Self.calendar.component(.month, from: date))
                return min(distance, 12 - distance) <= 1
            default:
                guard !splits, let captured = metadata.creationDate else { return false }
                return captured <= date.addingTimeInterval(86_400) && date.timeIntervalSince(captured) <= 30 * 86_400
            }
        }
        let pool = preferred.isEmpty ? candidates : preferred
        let selected = pool.min { lhs, rhs in
            let a = previous.first { $0.photoID == lhs.photoID }?.day ?? .distantPast
            let b = previous.first { $0.photoID == rhs.photoID }?.day ?? .distantPast
            if a != b { return a < b }
            // 11/15: among equals, with the kinds of day: the app's heart,
            // the Photos favorite, a fitting cat first.
            if splits {
                let qualityA = quality(lhs, in: state), qualityB = quality(rhs, in: state)
                if qualityA != qualityB { return qualityA < qualityB }
            }
            return lhs.photoID < rhs.photoID
        }!
        return CloudyWindowSelection(scopeID: scopeID, day: date, photoID: selected.photoID, profileID: selectedProfile,
                                     dayKind: CloudyWindowDayKind.ordinary.rawValue, chosenAt: now)
    }

    private func similar(_ lhs: CloudyWindowPreparedPhoto, _ rhs: CloudyWindowPreparedPhoto,
                         metadata: [String: CloudyWindowPhotoMetadata]) -> Bool {
        guard let a = metadata[lhs.photoID], let b = metadata[rhs.photoID] else { return false }
        if let burst = a.burstIdentifier, !burst.isEmpty, burst == b.burstIdentifier { return true }
        guard let first = a.creationDate, let second = b.creationDate,
              abs(first.timeIntervalSince(second)) < 90 else { return false }
        return (lhs.visualHash ^ rhs.visualHash).nonzeroBitCount <= 4
    }

    private func profileID(_ scopeID: String, in state: CloudyWindowState) -> String? {
        guard scopeID.hasPrefix(Self.profilePrefix) else { return nil }
        let id = String(scopeID.dropFirst(Self.profilePrefix.count))
        return state.profiles[id] == nil ? nil : id
    }

    private func valid(_ photo: CloudyWindowPreparedPhoto, in state: CloudyWindowState,
                       authority: PersonalRediscoverySnapshot?) -> Bool {
        guard let authority, authority.isAuthorized, authority.eligiblePhotoIDs.contains(photo.photoID),
              authority.photoModificationDates[photo.photoID] == photo.source.sourceModificationDate,
              state.metadata[photo.photoID] != nil else { return false }
        return photo.filenames.count == 6 && Set(photo.filenames).count == 6
            && photo.filenames.allSatisfy(Self.validFilename)
    }

    private func reconcile(_ state: inout CloudyWindowState, authority: PersonalRediscoverySnapshot?, now: Date) {
        let keptPhotos = state.photos.filter { valid($0, in: state, authority: authority) }
        state.photos = keptPhotos
        let available = Set(state.photos.map(\.photoID))
        let lastIDs = Set(Dictionary(grouping: state.selections.filter { $0.day <= now }, by: \.scopeID)
            .values.compactMap { $0.max(by: { $0.day < $1.day })?.id })
        let today = Self.calendar.startOfDay(for: now)
        let keptSelections = state.selections.filter { selection in
            // A released derived cache is rendered again for the kept
            // selection, so re-adding the Widget shows the same photo in the
            // same state. A photo that left the library is dropped.
            let unavailableToday = selection.day >= today && !available.contains(selection.photoID)
                && !(authority?.eligiblePhotoIDs.contains(selection.photoID) == true
                     && state.metadata[selection.photoID] != nil)
            let invalidScope =
                (selection.scopeID != Self.personalScope && profileID(selection.scopeID, in: state) == nil)
                || (selection.scopeID != Self.personalScope && state.metadata[selection.photoID]?.profileIDs.contains(
                    String(selection.scopeID.dropFirst(Self.profilePrefix.count))) != true)
            let expired = now.timeIntervalSince(selection.day) > 40 * 86_400 && !lastIDs.contains(selection.id)
            return !unavailableToday && !invalidScope && !expired
        }
        state.selections = keptSelections
        let retainedIDs = Set(keptSelections.map(\.id))
        state.frozenSelectionIDs = state.frozenSelectionIDs?.filter { retainedIDs.contains($0.value) }
    }

    private func protectedSelections(in state: CloudyWindowState, now: Date) -> Set<String> {
        let today = Self.calendar.startOfDay(for: now)
        let latest = Dictionary(grouping: state.selections.filter { $0.day <= now }, by: \.scopeID)
            .values.compactMap { $0.max(by: { $0.day < $1.day })?.photoID }
        let frozen = Set((state.frozenSelectionIDs ?? [:]).values)
        return Set(latest).union(state.selections.filter { $0.day >= today || frozen.contains($0.id) }.map(\.photoID))
    }

    private func filesExist(_ photo: CloudyWindowPreparedPhoto) -> Bool {
        guard let directory = try? imageDirectory() else { return false }
        return photo.filenames.allSatisfy { filename in
            guard Self.validFilename(filename), let values = try? directory.appendingPathComponent(filename)
                .resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                values.isRegularFile == true, values.isSymbolicLink != true,
                let size = values.fileSize else { return false }
            return size > 0 && size <= Self.maximumFileBytes
        }
    }

    private static func validFilename(_ filename: String) -> Bool {
        filename.hasPrefix("cloudy-") && filename.hasSuffix(".jpg") && filename.utf8.count < 180
            && filename.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }
    }

    private func directory() throws -> URL {
        guard let containerURL else { throw PersonalRediscoveryStore.Error.unavailable }
        return containerURL.appendingPathComponent("cloudy-window.v1", isDirectory: true)
    }
    private func imageDirectory() throws -> URL { try directory().appendingPathComponent("images", isDirectory: true) }
    private func read() throws -> CloudyWindowState {
        let url = try directory().appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1_024 * 1_024 else {
            throw PersonalRediscoveryStore.Error.corrupted
        }
        let state = try JSONDecoder().decode(CloudyWindowState.self, from: Data(contentsOf: url))
        guard state.version == 1, state.photos.count <= Self.maximumPhotoCount,
              Set(state.photos.map(\.photoID)).count == state.photos.count,
              state.photos.allSatisfy({ $0.filenames.allSatisfy(Self.validFilename) }),
              state.selections.count <= 5_000, state.seenPhotoIDs.count <= 100_000 else {
            throw PersonalRediscoveryStore.Error.corrupted
        }
        return state
    }
    private func write(_ state: CloudyWindowState) throws {
        var folder = try directory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        let bytes = try JSONEncoder().encode(state)
        guard bytes.count <= 8 * 1_024 * 1_024 else { throw PersonalRediscoveryStore.Error.corrupted }
        let url = folder.appendingPathComponent("state.json")
        try bytes.write(to: url, options: .atomic)
#if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: url.path)
#endif
    }
    private func collectFiles(keeping filenames: Set<String>) {
        guard let directory = try? imageDirectory(), let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where Self.validFilename(file.lastPathComponent) && !filenames.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
