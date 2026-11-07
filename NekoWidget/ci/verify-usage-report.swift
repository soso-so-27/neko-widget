import Foundation

// Usage counts (spec 11/7): the payload, day keys, buckets, the closed name
// list and the 7-day window, against NekoWidget/Services/UsageReport.swift.

private func require(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
    guard condition() else { fatalError(message()) }
}

@main
private struct UsageReportVerifier {
    static func main() throws {
        // Names: exactly the spec's list plus app_opened, one per Plus entry.
        let fixed: Set<String> = [
            "app_opened", "onboarding_completed", "photo_access_granted", "cats_found", "widget_guide_opened",
            "album_work_opened", "seasonal_movie_opened", "nine_exported", "showcase_opened",
            "photo_favorited", "photo_memo_written", "related_photos_opened",
            "mado_opened", "mado_photo_sent", "mado_heart", "official_window_started",
            "cat_care_edited", "tool_care_handoff", "tool_vet_visit", "tool_lost_cat", "tool_evacuation",
            "mado_created", "mado_invite_shared", "mado_joined",
            "family_created", "family_invite_shared", "family_joined", "app_recommended",
            "plus_restored", "autosave_started",
        ]
        let entries = ["onboarding", "widget_resume", "monthly_summary", "new_memo", "create_window",
                       "continue_window", "create_family", "continue_family", "preservation", "settings"]
        require(Set(UsagePlusEntry.allCases.map(\.rawValue)) == Set(entries), "Plus entry names")
        let expected = fixed.union(entries.map { "plus_offer_shown." + $0 }).union(entries.map { "plus_purchased." + $0 })
        require(UsageEvent.allNames == expected, "Event names must be exactly the spec's list")
        require(UsageEvent.all.count == expected.count, "Every event has its own name")
        for name in UsageEvent.allNames {
            require(name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_" || $0 == ".") },
                    "Short ASCII names only: \(name)")
        }

        // Buckets.
        require([0, 1, 2, 3, 9].map(UsageState.catsBucket) == ["0", "1", "2", "3+", "3+"], "cats buckets")
        require([0, 1, 2, 3, 40].map(UsageState.windowsBucket) == ["0", "1-2", "1-2", "3+", "3+"], "windows buckets")
        require(UsageState.catsBucket(-1) == "0" && UsageState.windowsBucket(-1) == "0", "negative counts")

        // Day keys: the device's local day, Gregorian digits.
        let tokyo = UsageDayKey.calendar(timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        let utc = UsageDayKey.calendar(timeZone: TimeZone(identifier: "UTC")!)
        let lateUTC = ISO8601DateFormatter().date(from: "2026-11-06T16:30:00Z")!
        require(UsageDayKey.string(for: lateUTC, calendar: tokyo) == "2026-11-07", "Tokyo day")
        require(UsageDayKey.string(for: lateUTC, calendar: utc) == "2026-11-06", "UTC day")
        require(UsageDayKey.days(from: "2026-10-31", to: "2026-11-07", calendar: tokyo) == 7, "day difference across a month")
        require(UsageDayKey.days(from: "2026-11-7", to: "2026-11-07", calendar: tokyo) == nil, "malformed key")
        require(UsageDayKey.days(from: "2026-02-30", to: "2026-11-07", calendar: tokyo) == nil, "impossible date")

        // Ledger: counting, once-a-day app_opened, batches, the 7-day window.
        var ledger = UsageLedger()
        let today = "2026-11-07"
        for day in ["2026-10-30", "2026-10-31", "2026-11-06", today] {
            ledger.markOpened(day: day)
            ledger.markOpened(day: day)
            ledger.record(.madoPhotoSent, day: day)
        }
        ledger.record(.plusOfferShown(.settings), day: "2026-11-06")
        ledger.record(.plusOfferShown(.settings), day: "2026-11-06")
        let batchBefore = ledger.days.first { $0.day == "2026-11-06" }!.batch
        let pendingBeforePrune = ledger.pending(today: today, calendar: tokyo).map(\.day)
        require(pendingBeforePrune == ["2026-10-31", "2026-11-06"], "Only earlier days within 7 are sent: \(pendingBeforePrune)")
        ledger.prune(today: today, calendar: tokyo)
        require(ledger.days.map(\.day).sorted() == ["2026-10-31", "2026-11-06", today], "Days older than 7 are dropped")
        let yesterday = ledger.days.first { $0.day == "2026-11-06" }!
        require(yesterday.batch == batchBefore, "A day keeps one batch")
        require(yesterday.counts == ["app_opened": 1, "mado_photo_sent": 1, "plus_offer_shown.settings": 2], "counts")
        require(Set(ledger.days.map(\.batch)).count == ledger.days.count, "Each day has its own batch")

        // A stored file with an unknown name, a repeated day or a bad bucket.
        let stored = """
        {"days":[{"day":"2026-11-06","batch":"\(UUID().uuidString)","counts":{"app_opened":1,"photo_name":3,"mado_heart":0}},
                 {"day":"2026-11-06","batch":"\(UUID().uuidString)","counts":{"mado_heart":2}}]}
        """
        let decoded = try JSONDecoder().decode(UsageLedger.self, from: Data(stored.utf8))
        require(decoded.days.count == 1 && decoded.days[0].counts == ["app_opened": 1], "Unknown names are dropped on load")
        let badState = #"{"plus":true,"widget":true,"cats":"4","windows":"0","family":false,"photoAccess":"full"}"#
        require((try? JSONDecoder().decode(UsageState.self, from: Data(badState.utf8))) == nil, "Only bucketed states load")

        // Payload: exactly the spec's fields; the batch is the only identifier.
        let state = UsageState(plus: true, widget: false, catCount: 4, windowCount: 1, family: true, photoAccess: .limited)
        var unsent = yesterday
        unsent.counts["somebody's cat"] = 5
        let payload = UsagePayloadCheck.payload(unsent, state: state)
        let json = try JSONSerialization.jsonObject(with: try payload.body()) as! [String: Any]
        require(Set(json.keys) == ["schema", "day", "batch", "app", "os", "state", "counts"], "Payload fields: \(json.keys)")
        require(json["schema"] as? Int == 1 && json["day"] as? String == "2026-11-06", "schema and day")
        require(json["batch"] as? String == yesterday.batch.uuidString.lowercased(), "batch is the day's UUID")
        require(json["app"] as? String == "1.0 (343)" && json["os"] as? String == "18", "app and os")
        let sentState = json["state"] as! [String: Any]
        require(Set(sentState.keys) == ["plus", "widget", "cats", "windows", "family", "photoAccess"], "state fields")
        require(sentState["cats"] as? String == "3+" && sentState["windows"] as? String == "1-2"
                && sentState["photoAccess"] as? String == "limited", "state buckets")
        let counts = json["counts"] as! [String: Int]
        require(Set(counts.keys).isSubset(of: UsageEvent.allNames), "Only known names are sent")
        require(counts["somebody's cat"] == nil, "An unknown name never leaves")

        // A sent day is removed only with its own batch.
        var afterSend = ledger
        afterSend.remove(day: "2026-11-06", batch: UUID())
        require(afterSend.days.contains { $0.day == "2026-11-06" }, "Another batch does not remove the day")
        afterSend.remove(day: "2026-11-06", batch: yesterday.batch)
        require(!afterSend.days.contains { $0.day == "2026-11-06" }, "The sent day is removed")

        print("PASS usage report: names, buckets, local days, 7-day window, batches, payload fields")
    }
}

private enum UsagePayloadCheck {
    static func payload(_ record: UsageDayRecord, state: UsageState) -> UsageReportPayload {
        UsageReportPayload(record: record, fallbackState: state, app: "1.0 (343)", os: "18")
    }
}
