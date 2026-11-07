import Foundation

// Anonymous usage counts (spec 11/7, 利用状況の分析). Foundation only, so
// ci/verify-usage-report.swift compiles this file alone. The app side
// (counting, the file, sending) is UsageCounter.swift.
//
// What leaves the iPhone is only UsageReportPayload: a day, one random batch
// ID made for that day, the app and iOS versions, a few bucketed states and
// counts keyed by UsageEvent names. No photo, text, name, window ID, place,
// advertising ID or device ID exists in these types.

/// Where the one Plus screen was opened from (`PlusOfferContext`), as a short
/// stable name. UsageCounter.swift maps every context case exhaustively.
enum UsagePlusEntry: String, CaseIterable, Sendable {
    case onboarding
    case widgetResume = "widget_resume"
    case monthlySummary = "monthly_summary"
    case newMemo = "new_memo"
    case createWindow = "create_window"
    case continueWindow = "continue_window"
    case createFamily = "create_family"
    case continueFamily = "continue_family"
    case preservation
    case settings
}

/// Exactly the spec's names, plus `app_opened` (once a day, so the days a
/// device was used can be counted even when nothing else happened).
enum UsageEvent: Hashable, Sendable {
    case appOpened
    // 始める
    case onboardingCompleted, photoAccessGranted, catsFound, widgetGuideOpened
    // 楽しむ
    case albumWorkOpened, seasonalMovieOpened, nineExported, showcaseOpened
    case photoFavorited, photoMemoWritten, relatedPhotosOpened
    // まど
    case madoOpened, madoPhotoSent, madoHeart, officialWindowStarted
    // 記録する
    case catCareEdited, toolCareHandoff, toolVetVisit, toolLostCat, toolEvacuation
    // 広げる
    case madoCreated, madoInviteShared, madoJoined
    case familyCreated, familyInviteShared, familyJoined, appRecommended
    // 稼ぐ
    case plusOfferShown(UsagePlusEntry)
    case plusPurchased(UsagePlusEntry)
    case plusRestored, autosaveStarted

    var name: String {
        switch self {
        case .appOpened: "app_opened"
        case .onboardingCompleted: "onboarding_completed"
        case .photoAccessGranted: "photo_access_granted"
        case .catsFound: "cats_found"
        case .widgetGuideOpened: "widget_guide_opened"
        case .albumWorkOpened: "album_work_opened"
        case .seasonalMovieOpened: "seasonal_movie_opened"
        case .nineExported: "nine_exported"
        case .showcaseOpened: "showcase_opened"
        case .photoFavorited: "photo_favorited"
        case .photoMemoWritten: "photo_memo_written"
        case .relatedPhotosOpened: "related_photos_opened"
        case .madoOpened: "mado_opened"
        case .madoPhotoSent: "mado_photo_sent"
        case .madoHeart: "mado_heart"
        case .officialWindowStarted: "official_window_started"
        case .catCareEdited: "cat_care_edited"
        case .toolCareHandoff: "tool_care_handoff"
        case .toolVetVisit: "tool_vet_visit"
        case .toolLostCat: "tool_lost_cat"
        case .toolEvacuation: "tool_evacuation"
        case .madoCreated: "mado_created"
        case .madoInviteShared: "mado_invite_shared"
        case .madoJoined: "mado_joined"
        case .familyCreated: "family_created"
        case .familyInviteShared: "family_invite_shared"
        case .familyJoined: "family_joined"
        case .appRecommended: "app_recommended"
        case let .plusOfferShown(entry): "plus_offer_shown." + entry.rawValue
        case let .plusPurchased(entry): "plus_purchased." + entry.rawValue
        case .plusRestored: "plus_restored"
        case .autosaveStarted: "autosave_started"
        }
    }

    static let all: [UsageEvent] = [
        .appOpened,
        .onboardingCompleted, .photoAccessGranted, .catsFound, .widgetGuideOpened,
        .albumWorkOpened, .seasonalMovieOpened, .nineExported, .showcaseOpened,
        .photoFavorited, .photoMemoWritten, .relatedPhotosOpened,
        .madoOpened, .madoPhotoSent, .madoHeart, .officialWindowStarted,
        .catCareEdited, .toolCareHandoff, .toolVetVisit, .toolLostCat, .toolEvacuation,
        .madoCreated, .madoInviteShared, .madoJoined,
        .familyCreated, .familyInviteShared, .familyJoined, .appRecommended,
        .plusRestored, .autosaveStarted,
    ] + UsagePlusEntry.allCases.map(UsageEvent.plusOfferShown)
      + UsagePlusEntry.allCases.map(UsageEvent.plusPurchased)

    /// The only keys `counts` can hold. A stored file is filtered by this too.
    static let allNames: Set<String> = Set(all.map(\.name))
}

enum UsagePhotoAccess: String, Sendable {
    case full, limited, none
}

/// The day's state, bucketed (spec: cats "0"/"1"/"2"/"3+", windows "0"/"1-2"/"3+").
struct UsageState: Codable, Equatable, Sendable {
    let plus: Bool
    let widget: Bool
    let cats: String
    let windows: String
    let family: Bool
    let photoAccess: String

    init(plus: Bool, widget: Bool, catCount: Int, windowCount: Int, family: Bool, photoAccess: UsagePhotoAccess) {
        self.plus = plus
        self.widget = widget
        cats = Self.catsBucket(catCount)
        windows = Self.windowsBucket(windowCount)
        self.family = family
        self.photoAccess = photoAccess.rawValue
    }

    /// A stored state is read back only through the same buckets.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plus = try container.decode(Bool.self, forKey: .plus)
        widget = try container.decode(Bool.self, forKey: .widget)
        let cats = try container.decode(String.self, forKey: .cats)
        let windows = try container.decode(String.self, forKey: .windows)
        let photoAccess = try container.decode(String.self, forKey: .photoAccess)
        guard ["0", "1", "2", "3+"].contains(cats), ["0", "1-2", "3+"].contains(windows),
              UsagePhotoAccess(rawValue: photoAccess) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .cats, in: container, debugDescription: "bucket")
        }
        self.cats = cats
        self.windows = windows
        family = try container.decode(Bool.self, forKey: .family)
        self.photoAccess = photoAccess
    }

    static func catsBucket(_ count: Int) -> String {
        count <= 0 ? "0" : count == 1 ? "1" : count == 2 ? "2" : "3+"
    }

    static func windowsBucket(_ count: Int) -> String {
        count <= 0 ? "0" : count <= 2 ? "1-2" : "3+"
    }
}

/// One local day: its own random batch ID (a resend uses the same one), the
/// counts and the last state seen that day.
struct UsageDayRecord: Codable, Equatable, Sendable {
    let day: String
    let batch: UUID
    var counts: [String: Int]
    var state: UsageState?
}

/// Exactly the spec's version 1 body. Nothing else is encoded.
struct UsageReportPayload: Encodable, Equatable {
    let schema: Int
    let day: String
    let batch: String
    let app: String
    let os: String
    let state: UsageState
    let counts: [String: Int]

    init(record: UsageDayRecord, fallbackState: UsageState, app: String, os: String) {
        schema = 1
        day = record.day
        batch = record.batch.uuidString.lowercased()
        self.app = app
        self.os = os
        state = record.state ?? fallbackState
        counts = record.counts.filter { UsageEvent.allNames.contains($0.key) && $0.value > 0 }
    }

    func body() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// Local day keys ("yyyy-MM-dd") in the device's time zone, Gregorian digits.
enum UsageDayKey {
    static func calendar(timeZone: TimeZone = .autoupdatingCurrent) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func string(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Whole days from `day` to `today`; nil for a malformed key.
    static func days(from day: String, to today: String, calendar: Calendar) -> Int? {
        guard let start = date(day, calendar: calendar), let end = date(today, calendar: calendar) else { return nil }
        return calendar.dateComponents([.day], from: start, to: end).day
    }

    private static func date(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-")
        guard key.count == 10, parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        guard let date = calendar.date(from: components),
              string(for: date, calendar: calendar) == key else { return nil }
        return date
    }
}

/// The days kept on this iPhone. Only `record(_:day:)` adds counts, so a
/// name outside `UsageEvent` cannot be counted; loading drops any such name.
struct UsageLedger: Codable, Equatable, Sendable {
    static let retentionDays = 7
    private(set) var days: [UsageDayRecord] = []

    init() { }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decode([UsageDayRecord].self, forKey: .days)
        var seen = Set<String>()
        days = stored.compactMap { record in
            guard seen.insert(record.day).inserted else { return nil }
            var record = record
            record.counts = record.counts.filter { UsageEvent.allNames.contains($0.key) && $0.value > 0 }
            return record
        }
    }

    var isEmpty: Bool { days.isEmpty }

    mutating func record(_ event: UsageEvent, day: String) {
        let position = slot(for: day)
        days[position].counts[event.name, default: 0] &+= 1
    }

    /// `app_opened` is 1 on any day the app was opened, however often.
    mutating func markOpened(day: String) {
        let position = slot(for: day)
        days[position].counts[UsageEvent.appOpened.name] = 1
    }

    mutating func setState(_ state: UsageState, day: String) {
        let position = slot(for: day)
        days[position].state = state
    }

    /// Drops days more than `retentionDays` before today (and malformed keys).
    mutating func prune(today: String, calendar: Calendar) {
        days.removeAll { record in
            guard let age = UsageDayKey.days(from: record.day, to: today, calendar: calendar) else { return true }
            return age > Self.retentionDays
        }
    }

    /// Days before today and within the retention window, oldest first.
    func pending(today: String, calendar: Calendar) -> [UsageDayRecord] {
        days.filter { record in
            guard let age = UsageDayKey.days(from: record.day, to: today, calendar: calendar) else { return false }
            return age >= 1 && age <= Self.retentionDays
        }.sorted { $0.day < $1.day }
    }

    /// After the server took a day. The batch must match: a day sent and then
    /// cleared by turning the setting off and on is never removed by mistake.
    mutating func remove(day: String, batch: UUID) {
        days.removeAll { $0.day == day && $0.batch == batch }
    }

    private mutating func slot(for day: String) -> Int {
        if let index = days.firstIndex(where: { $0.day == day }) { return index }
        days.append(UsageDayRecord(day: day, batch: UUID(), counts: [:], state: nil))
        return days.count - 1
    }
}
