import CoreGraphics
import Foundation

// 迷子のとき, round 2 (11/8): the saved draft, the offices contacted, the
// 「見つかりました」 post and the sizes of what the tool makes. Foundation only,
// so ci/verify-tool-outputs.swift runs these rules on macOS.

/// A private, local draft. The key is a profile identifier or a generated guest identifier.
struct LostCatDraft: Codable, Equatable {
    static let schemaVersion = 1
    var schemaVersion = Self.schemaVersion
    var faceFileName: String?
    var bodyFileName: String?
    var name = ""
    var features = ""
    var collar = ""
    var approachAdvice = ""
    var contact = ""
    var lastSeenNear = ""
    var lastSeenAt: Date?
    var updatedAt = Date()
    // Optional for existing drafts. These are real editable values, not placeholders.
    var prefilledFields: Set<String>?
    /// Round 2 (11/8): offices contacted, the next day to check and the
    /// 「見つかりました」 message. Optional, so drafts saved before still decode.
    var incident: LostCatIncidentLog? = nil

    /// Something has happened: a place, a day or a contacted office. Only
    /// then is 「見つかりました」 offered.
    var hasIncident: Bool {
        !lastSeenNear.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || lastSeenAt != nil || incident != nil
    }

    /// The log to edit; an emptied log is saved as nothing.
    var incidentLog: LostCatIncidentLog {
        get { incident ?? LostCatIncidentLog() }
        set { incident = newValue.isEmpty ? nil : newValue }
    }

    var foundMessage: String {
        get { incident?.foundMessage ?? "" }
        set { incidentLog.foundMessage = newValue.isEmpty ? nil : newValue }
    }

    /// 「この迷子の記録を終える」: the place, the day and the log go; the
    /// cat's photos, name, features, collar, advice and contact stay for next time.
    func endingIncident() -> LostCatDraft {
        var next = self
        next.lastSeenNear = ""
        next.lastSeenAt = nil
        next.incident = nil
        return next
    }
}

/// The offices step 2 of the guide names. The raw value is what is saved.
enum LostCatOffice: String, CaseIterable, Identifiable, Sendable {
    case animalCenter, healthCenter, police, nearbyVet
    var id: String { rawValue }
    var title: String {
        switch self {
        case .animalCenter: return "動物愛護センター"
        case .healthCenter: return "保健所"
        case .police: return "警察"
        case .nearbyVet: return "近くの動物病院"
        }
    }
}

struct LostCatContactedOffice: Codable, Equatable, Sendable {
    var office: String
    var contactedAt: Date
}

/// What happened since the cat went missing. Every field is optional, so a
/// later field can be added the same way.
struct LostCatIncidentLog: Codable, Equatable, Sendable {
    var contactedOffices: [LostCatContactedOffice]? = nil
    var nextCheckAt: Date? = nil
    var foundMessage: String? = nil

    var isEmpty: Bool {
        (contactedOffices ?? []).isEmpty && nextCheckAt == nil && (foundMessage ?? "").isEmpty
    }

    func contactedAt(_ office: LostCatOffice) -> Date? {
        contactedOffices?.last { $0.office == office.rawValue }?.contactedAt
    }

    /// Offices this version knows; a code saved by a later version is kept, not counted.
    var contactedCount: Int { LostCatOffice.allCases.filter { contactedAt($0) != nil }.count }

    /// Marks (a day) or unmarks (nil) one office. The first office marked
    /// sets the next day to check to tomorrow, unless one is already chosen.
    mutating func setContacted(_ office: LostCatOffice, on day: Date?, now: Date,
                               calendar: Calendar = LostCatText.calendar) {
        let first = contactedCount == 0
        var list = (contactedOffices ?? []).filter { $0.office != office.rawValue }
        if let day { list.append(LostCatContactedOffice(office: office.rawValue, contactedAt: day)) }
        contactedOffices = list.isEmpty ? nil : list
        if first, day != nil, nextCheckAt == nil {
            nextCheckAt = Self.nextDay(after: now, calendar: calendar)
        }
    }

    static func nextDay(after now: Date, calendar: Calendar = LostCatText.calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
    }

    /// 「連絡済み 3/4・次に確かめる日 11月9日」 on the guide row; nil when nothing is recorded.
    func stateLine(now: Date, calendar: Calendar = LostCatText.calendar) -> String? {
        var parts: [String] = []
        if contactedCount > 0 { parts.append("連絡済み \(contactedCount)/\(LostCatOffice.allCases.count)") }
        if let next = nextCheckAt {
            let day = calendar.isDate(next, inSameDayAs: now) ? "今日" : LostCatText.day(next, calendar: calendar)
            parts.append("次に確かめる日 \(day)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }
}

enum LostCatText {
    static let hashtags = "#迷子猫 #迷い猫"
    static let foundTitle = "見つかりました"
    static let foundThanks = "ご協力ありがとうございました"
    static let foundMessageLimit = 80
    /// The one line after the 「見つかりました」 post is shared.
    static let takeDownFlyers = "貼ったチラシをはがしに行きましょう"

    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "ja_JP")
        return value
    }

    /// 「11月9日」, whatever the iPhone's region.
    static func day(_ date: Date, calendar: Calendar = LostCatText.calendar) -> String {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 0)月\(parts.day ?? 0)日"
    }

    /// The post that closes the earlier ones, with the same hashtags. A
    /// message that was not written is left out.
    static func foundPost(name: String, message: String) -> String {
        var parts = ["\(foundTitle)。"]
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { parts.append(name) }
        parts.append("\(foundThanks)。")
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty { parts.append(message) }
        parts.append(hashtags)
        return parts.joined(separator: "\n")
    }
}

/// What the できあがり screen makes. Images are in pixels, PDFs in points.
enum LostCatOutput: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case social, story, paper, smallPaper
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .social: return "SNS・LINE"
        case .story: return "ストーリー"
        case .paper: return "A4チラシ"
        case .smallPaper: return "小さいチラシ"
        }
    }

    var isPDF: Bool { self == .paper || self == .smallPaper }
    /// The post goes with the SNS image only. A story and the flyers are the file alone.
    var sharesPost: Bool { self == .social }

    /// Named in 「…に入りきりません」.
    var issueName: String {
        switch self {
        case .social: return "SNSの画像"
        case .story: return "ストーリーの画像"
        case .paper: return "A4"
        case .smallPaper: return "小さいチラシ"
        }
    }

    var fileName: String {
        switch self {
        case .social: return "迷子の猫.png"
        case .story: return "迷子の猫_ストーリー.png"
        case .paper: return "迷子の猫.pdf"
        case .smallPaper: return "迷子の猫_小さいチラシ.pdf"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .social: return "lost-cat-share-image"
        case .story: return "lost-cat-share-story"
        case .paper: return "lost-cat-share-pdf"
        case .smallPaper: return "lost-cat-share-small"
        }
    }

    /// SNS 4:5, story 9:16, both flyers one A4 page.
    var canvas: CGSize {
        switch self {
        case .social: return CGSize(width: 1080, height: 1350)
        case .story: return CGSize(width: 1080, height: 1920)
        case .paper, .smallPaper: return CGSize(width: 595.2, height: 841.8)
        }
    }

    /// A story keeps the title and the contact clear of Instagram's own bars.
    var safeInsets: (top: CGFloat, bottom: CGFloat) {
        self == .story ? (top: 160, bottom: 200) : (top: 0, bottom: 0)
    }

    static let foundFileName = "見つかりました.png"
    /// Every file the tool writes; only these are removed after sharing.
    static var exportFileNames: Set<String> { Set(allCases.map(\.fileName)).union([foundFileName]) }
}

/// The small flyer: four copies on one A4 page (2 x 2), to cut apart for
/// mailboxes and shops. Each copy is A6, the same shape as the page.
enum LostCatSmallFlyer {
    static let columns = 2
    static let rows = 2

    static func cells(page: CGSize) -> [CGRect] {
        let width = page.width / CGFloat(columns)
        let height = page.height / CGFloat(rows)
        return (0..<rows).flatMap { row in
            (0..<columns).map { column in
                CGRect(x: CGFloat(column) * width, y: CGFloat(row) * height, width: width, height: height)
            }
        }
    }
}
