import Foundation

enum PhotoDateRange: String, CaseIterable, Codable, Identifiable, Sendable {
    case all
    case recentYear

    var id: Self { self }
}

enum CatLifeReferenceKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case birthday
    case adoptionDay

    var id: Self { self }
}

/// A calendar-only value avoids moving the cat's birthday/adoption day when a
/// device changes time zone. It is local metadata and is never logged.
struct CatLifeDate: Codable, Equatable, Sendable {
    var year: Int
    var month: Int
    var day: Int

    /// Always 西暦, in `calendar`'s time zone: a 和暦 calendar still gives 2026.
    init?(date: Date, calendar: Calendar = .nekoGregorian) {
        let values = Calendar.nekoGregorian(in: calendar).dateComponents([.year, .month, .day], from: date)
        guard let year = values.year,
              let month = values.month,
              let day = values.day else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    func date(in inputCalendar: Calendar = .nekoGregorian,
              deviceCalendar: Calendar = .current) -> Date? {
        var calendar = inputCalendar
        if Self.isDeviceCalendarYear(year, reading: inputCalendar, device: deviceCalendar) {
            // Saved before 11/10 on an iPhone set to 和暦 or 仏暦: the year is
            // that calendar's (「8」, 「2569」). Read it as it was read then.
            calendar = deviceCalendar
            calendar.timeZone = inputCalendar.timeZone
        }
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: 12
        ))
    }

    /// 11/20: the same day in 西暦, when this is an old value in the
    /// iPhone's own calendar and this iPhone can still say which day that
    /// was (it is set to that calendar now). nil: already 西暦, or not
    /// determinable here — then it is left exactly as it is.
    func inGregorian(device: Calendar = .current) -> CatLifeDate? {
        let gregorian = Calendar.nekoGregorian
        guard Self.isDeviceCalendarYear(year, reading: gregorian, device: device),
              let instant = self.date(in: gregorian, deviceCalendar: device),
              let converted = CatLifeDate(date: instant, calendar: gregorian),
              !Self.isDeviceCalendarYear(converted.year, reading: gregorian, device: device) else { return nil }
        return converted
    }

    /// A 西暦 year no cat could have (before 1900 or after next year), on an
    /// iPhone whose own calendar is not 西暦: an old value in that calendar.
    static func isDeviceCalendarYear(_ year: Int, reading calendar: Calendar, device: Calendar) -> Bool {
        guard calendar.identifier == .gregorian, device.identifier != .gregorian else { return false }
        let nextYear = calendar.component(.year, from: Date()) + 1
        return year < 1900 || year > nextYear
    }
}

struct CatLifeReference: Codable, Equatable, Sendable {
    var kind: CatLifeReferenceKind
    var date: CatLifeDate

    /// 11/20: see CatLifeDate.inGregorian; unchanged when not determinable.
    func inGregorian(device: Calendar = .current) -> Self {
        CatLifeReference(kind: kind, date: date.inGregorian(device: device) ?? date)
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var dateRange: PhotoDateRange
    var albumMaximum: Int
    var confidenceThreshold: Float
    var minimumCatAreaRatio: Double
    var albumName: String
    var quickScanLimit: Int
    var widgetEntryCount: Int
    var widgetEntryIntervalMinutes: Int
    var analysisRevision: Int
    /// Changing this only regroups dates; it must not invalidate Vision work.
    var catLifeReference: CatLifeReference? = nil
    /// Marks the one-time move of the stored default line (0.7 -> 0.5, 11/13).
    /// Optional, so older builds still decode the settings (they ignore it).
    var detectorPolicyVersion: Int? = nil
    /// 11/20: fingerprints a full rescan replaced. Until that rescan finishes,
    /// cat records still carrying one of them keep showing (写真, cat pages,
    /// Widgets); the scanner replaces them record by record, newest first.
    /// Optional, so older builds still decode the settings (they ignore it).
    var supersededAnalysisFingerprints: [String]? = nil

    static let currentDetectorPolicyVersion = 2
    /// A rescan started again during a rescan keeps the older results too.
    static let maximumSupersededAnalysisFingerprints = 4

    /// 11/13 on-device measurement: of the photos Apple's Photos app groups
    /// as the owner's two cats, 402 had been judged "not a cat". Run again at
    /// 1024px, 269 had a best cat label of 0.5-0.7 and 245 a cat box larger
    /// than 5% of the image, so the 0.7 line dropped about 38% of real cat
    /// photos the recogniser did see as cats. The line is now 0.5.
    static let defaultConfidenceThreshold: Float = 0.5
    /// The line used until 11/13. Read only by the one-time migration.
    static let legacyDefaultConfidenceThreshold: Float = 0.7
    /// 11/14 確かな猫: a stored best cat confidence at or above this line.
    /// 0.5 ..< 0.7 is たぶん猫 — shown in every list the user browses, but
    /// never chosen by the app on its own (covers, widgets, works) while
    /// enough 確かな猫 exist. The old 0.7 line, kept as its own setting.
    static let confidentCatThreshold: Float = 0.7
    /// 11/15 safety net: with fewer 確かな猫 than this in the whole library,
    /// the tiers are off and たぶん猫 count as 確かな猫 everywhere, so a cat
    /// that photographs poorly still gets themes, widgets and works.
    static let minimumConfidentCatPhotos = 20

    static let `default` = AppSettings(
        dateRange: .all,
        albumMaximum: 300,
        confidenceThreshold: defaultConfidenceThreshold,
        minimumCatAreaRatio: 0.08,
        albumName: "うちの子",
        quickScanLimit: 500,
        widgetEntryCount: 20,
        widgetEntryIntervalMinutes: 20,
        analysisRevision: 1,
        detectorPolicyVersion: currentDetectorPolicyVersion
    )

    /// Settings saved before 11/13 carry the old default line (0.7). Move it to
    /// 0.5 once; a line chosen on purpose in an internal build is kept. The
    /// analysis revision is not touched, so positive records migrate in place
    /// (AssetRecord.migratedToLowerConfidenceThreshold) and nothing restarts.
    func migratedToCurrentDetectorPolicy() -> AppSettings {
        guard (detectorPolicyVersion ?? 1) < Self.currentDetectorPolicyVersion else {
            return self
        }
        var value = self
        if value.confidenceThreshold == Self.legacyDefaultConfidenceThreshold {
            value.confidenceThreshold = Self.defaultConfidenceThreshold
        }
        value.detectorPolicyVersion = Self.currentDetectorPolicyVersion
        return value
    }

    func normalized() -> AppSettings {
        var value = self
        value.albumMaximum = min(2_000, max(1, albumMaximum))
        value.confidenceThreshold = min(1, max(0, confidenceThreshold))
        value.minimumCatAreaRatio = min(1, max(0, minimumCatAreaRatio))
        value.quickScanLimit = min(2_000, max(1, quickScanLimit))
        value.widgetEntryCount = min(20, max(15, widgetEntryCount))
        value.widgetEntryIntervalMinutes = min(30, max(10, widgetEntryIntervalMinutes))
        value.analysisRevision = max(1, analysisRevision)
        if let superseded = value.supersededAnalysisFingerprints {
            let kept = superseded.filter { $0 != value.analysisFingerprint }
                .suffix(Self.maximumSupersededAnalysisFingerprints)
            value.supersededAnalysisFingerprints = kept.isEmpty ? nil : Array(kept)
        }
        let today = Calendar.current.startOfDay(for: .now)
        let startOfTomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)
        if let referenceDate = value.catLifeReference?.date.date(),
           let startOfTomorrow,
           referenceDate < startOfTomorrow {
            // Keep the validated date-only value.
        } else {
            value.catLifeReference = nil
        }
        return value
    }

    var analysisFingerprint: String {
        // Minimum area is a Widget presentation policy, not detector input.
        // Changing it must not invalidate otherwise identical Vision evidence.
        "cat-v3:\(confidenceThreshold.bitPattern):\(analysisRevision)"
    }

    /// True for a record made under the current detector settings, or under
    /// settings a still-running rescan is replacing (11/20). Starting a
    /// rescan must not empty the 写真 tab, the cat pages or the Widgets.
    func presentsAnalysis(fingerprint: String) -> Bool {
        fingerprint == analysisFingerprint
            || supersededAnalysisFingerprints?.contains(fingerprint) == true
    }

    /// The settings for a rescan: the analysis revision moves on, and the
    /// results made so far stay shown until the rescan replaces them.
    func startingRescan() -> AppSettings {
        var value = self
        var superseded = supersededAnalysisFingerprints ?? []
        superseded.removeAll { $0 == analysisFingerprint }
        superseded.append(analysisFingerprint)
        value.supersededAnalysisFingerprints = superseded
        value.analysisRevision = analysisRevision + 1
        return value.normalized()
    }

    /// Called when a pass under the current settings completed.
    func finishingRescan() -> AppSettings {
        var value = self
        value.supersededAnalysisFingerprints = nil
        return value
    }
}
