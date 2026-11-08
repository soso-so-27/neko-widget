import Foundation

private enum Failure: Error { case check(String) }
private func check(_ value: Bool, _ name: String) throws {
    if !value { throw Failure.check(name) }
}

private let t0 = Date(timeIntervalSince1970: 1_792_454_400)
private let halfYear: TimeInterval = 182 * 24 * 60 * 60

@main
struct VerifyEvacuationPlan {
    static func main() throws {
        try oldDataDecodes()
        try amountsFollowCatCount()
        try medicinesFollowCatCare()
        try checklistDates()
        try reviewCountsFromCreation()
        try destinations()
        try expiryRules()
        try noticeSchedule()
        try takenOnTheDay()
        print("Evacuation plan (避難に備える) decoding and rule checks passed")
    }

    /// A plan saved before 11/8 has no createdAt, lastCheckedAt, address or kind.
    static func oldDataDecodes() throws {
        let cat = "E0260929-0000-0000-0000-000000000001"
        let supply = "E0260929-0000-0000-0000-0000000000A1"
        let place = "E0260929-0000-0000-0000-0000000000B1"
        let json = """
        {"schemaVersion":1,
         "cats":[{"id":"\(cat)","name":"むぎ","features":"","food":"","handling":"",
                  "medicalStatus":"unknown","medicalDetails":"","photos":{},"updatedAt":800000000,"reviewedAt":805000000}],
         "supplies":[{"id":"\(supply)","title":"キャリー","quantity":"1個","location":"玄関","isNeeded":true}],
         "destinations":[{"id":"\(place)","name":"第一小学校","conditions":"ケージ持参","source":"",
                          "telephone":"03-1234-5678","checkedAt":790000000}],
         "contact":"","familyMeetingMemo":"","carriedIDs":["\(supply)"],"checkStartedAt":810000000}
        """
        let plan = try JSONDecoder().decode(EvacuationPlan.self, from: Data(json.utf8))
        try plan.validate()
        try check(plan.createdAt == nil && plan.lastCheckedAt == nil, "old plan has no new dates")
        try check(plan.destinations[0].address == nil && plan.destinations[0].kind == nil, "old place has no address or kind")
        try check(plan.supplies[0].expiresAt == nil, "old item has no 期限 (round 2)")
        try check(plan.lastReadyDate == Date(timeIntervalSinceReferenceDate: 810_000_000), "old check day is shown")
        // 11/8: the per-cat and per-place dates are no longer shown, but still read.
        try check(plan.cats[0].reviewedAt == Date(timeIntervalSinceReferenceDate: 805_000_000), "old cat date still decodes")
        try check(plan.destinations[0].checkedAt == Date(timeIntervalSinceReferenceDate: 790_000_000), "old place date still decodes")
        try check(plan.earliestKnownDate == Date(timeIntervalSinceReferenceDate: 790_000_000), "earliest known date")
        var stamped = plan
        stamped.stampCreation(now: t0)
        try check(stamped.createdAt == Date(timeIntervalSinceReferenceDate: 790_000_000), "old plan counts from its earliest date")
        stamped.stampCreation(now: t0.addingTimeInterval(99))
        try check(stamped.createdAt == Date(timeIntervalSinceReferenceDate: 790_000_000), "createdAt never moves")
        var fresh = EvacuationPlan()
        fresh.stampCreation(now: t0)
        try check(fresh.createdAt == t0, "a new plan counts from now")
        // The new fields round-trip, and an unknown kind reads as not chosen.
        var next = stamped
        next.destinations[0].address = "東京都千代田区1-1"
        next.destinations[0].kind = .family
        let again = try JSONDecoder().decode(EvacuationPlan.self, from: JSONEncoder().encode(next))
        try check(again == next && again.destinations[0].kind == .family, "new fields round-trip")
        var future = next
        future.destinations[0].kindValue = "someday"
        try check(future.destinations[0].kind == nil, "unknown kind is not chosen")
    }

    static func amountsFollowCatCount() throws {
        var plan = EvacuationPlan()
        let carrier = plan.supplies.firstIndex(where: { $0.title == "キャリー" })!
        let food = plan.supplies.firstIndex(where: { $0.title == "フード・水・食器" })!
        let litter = plan.supplies.firstIndex(where: { $0.title == "猫砂・ペットシーツ" })!
        try check(plan.supplies[carrier].quantity == "1個", "one cat at first")
        plan.cats = [EvacuationCat(), EvacuationCat()]
        plan.supplies[food].quantity = "7日分"  // the owner's own amount
        plan.carriedIDs = [plan.supplies[carrier].id, plan.supplies[food].id]
        plan.followCatCount()
        try check(plan.supplies[carrier].quantity == "2個（1匹に1つ）", "carriers follow the cats")
        try check(!plan.carriedIDs.contains(plan.supplies[carrier].id), "a changed amount is checked again")
        try check(plan.supplies[food].quantity == "7日分", "the owner's amount stays")
        try check(plan.carriedIDs.contains(plan.supplies[food].id), "an unchanged item stays checked")
        try check(plan.supplies[litter].quantity == "5日分以上", "amounts that do not scale stay")
        plan.supplies[food].quantity = "5日分以上×2匹"
        plan.cats.append(EvacuationCat())
        plan.followCatCount()
        try check(plan.supplies[carrier].quantity == "3個（1匹に1つ）", "three carriers")
        try check(plan.supplies[food].quantity == "5日分以上×3匹", "food for three")
        let removed = plan.cats[2].id
        plan.removeCat(removed)
        try check(plan.supplies[carrier].quantity == "2個（1匹に1つ）", "removing a cat follows too")
        // Adding recommended items never edits existing ones.
        plan.supplies[carrier].quantity = "大きいもの1つ"
        plan.addRecommendedSupplies()
        try check(plan.supplies[carrier].quantity == "大きいもの1つ", "adding keeps existing amounts")
    }

    static func medicinesFollowCatCare() throws {
        var plan = EvacuationPlan()
        var mugi = EvacuationCat(); mugi.name = "むぎ"
        var sora = EvacuationCat(); sora.name = "そら"
        plan.cats = [mugi, sora]
        plan.followMedicines([mugi.id: ["A錠"], sora.id: []])
        let item = plan.supplies.first { $0.catID == mugi.id }
        try check(item?.title == "薬：A錠" && item?.quantity == "5日分以上", "a medicine item is made")
        try check(!plan.supplies.contains { $0.catID == sora.id }, "no item without medicine")
        plan.carriedIDs.insert(item!.id)
        plan.followMedicines([mugi.id: ["A錠", "B錠"]])
        try check(plan.supplies.filter { $0.catID == mugi.id }.map(\.title) == ["薬：A錠・B錠"], "the app's item follows")
        try check(!plan.carriedIDs.contains(item!.id), "a changed item is checked again")
        let index = plan.supplies.firstIndex(where: { $0.id == item!.id })!
        plan.supplies[index].title = "薬（冷蔵庫）"
        plan.followMedicines([mugi.id: ["C錠"]])
        try check(plan.supplies[index].title == "薬（冷蔵庫）", "a renamed item stays")
        try check(plan.supplies.filter { $0.catID == mugi.id }.count == 1, "no second item")
    }

    static func checklistDates() throws {
        var plan = EvacuationPlan()
        let id = plan.supplies[0].id
        plan.toggleCarried(id, now: t0)
        try check(plan.carriedIDs == [id] && plan.lastReadyDate == t0 && plan.checkStartedAt == t0, "checked")
        plan.toggleCarried(plan.supplies[1].id, now: t0.addingTimeInterval(60))
        try check(plan.lastReadyDate == t0.addingTimeInterval(60) && plan.checkStartedAt == t0, "last ready day moves")
        plan.toggleCarried(id, now: t0.addingTimeInterval(120))
        try check(!plan.carriedIDs.contains(id) && plan.lastReadyDate == t0.addingTimeInterval(60), "unchecking keeps the day")
        plan.clearChecks()
        try check(plan.carriedIDs.isEmpty && plan.lastReadyDate == nil && plan.checkStartedAt == nil, "review clears checks")
    }

    static func reviewCountsFromCreation() throws {
        var plan = EvacuationPlan()
        plan.createdAt = t0
        let never = Date(timeIntervalSince1970: 0)
        try check(!plan.reviewIsDue(now: t0.addingTimeInterval(halfYear - 60), dismissedAt: never), "not yet")
        // Shown even when nothing was ever marked as checked (was hidden before 11/8).
        try check(plan.reviewIsDue(now: t0.addingTimeInterval(halfYear + 60), dismissedAt: never), "half a year after making")
        let closed = t0.addingTimeInterval(halfYear + 60)
        try check(!plan.reviewIsDue(now: closed.addingTimeInterval(60), dismissedAt: closed), "closed for half a year")
        try check(plan.reviewIsDue(now: closed.addingTimeInterval(halfYear + 60), dismissedAt: closed), "again later")
        let empty = EvacuationPlan()
        try check(!empty.reviewIsDue(now: t0, dismissedAt: never), "a plan with no dates counts from now")
        // 11/8: one date. A later 「最後に見直した日」 moves the next review.
        var reviewed = EvacuationPlan()
        reviewed.createdAt = t0
        reviewed.lastCheckedAt = t0.addingTimeInterval(halfYear)
        try check(!reviewed.reviewIsDue(now: t0.addingTimeInterval(halfYear + 60), dismissedAt: never), "counts from the last review")
        try check(reviewed.reviewIsDue(now: t0.addingTimeInterval(2 * halfYear + 60), dismissedAt: never), "half a year after the last review")
        var earlier = EvacuationPlan()
        earlier.createdAt = t0
        earlier.checkStartedAt = t0.addingTimeInterval(-halfYear)
        try check(earlier.reviewIsDue(now: t0.addingTimeInterval(halfYear + 60), dismissedAt: never), "an older day never delays it past creation")
    }

    static func destinations() throws {
        var place = EvacuationDestination()
        try check(!place.canConfirm, "empty place cannot be confirmed")
        place.setText(\.name, "第一小学校")
        try check(!place.canConfirm, "name alone is not enough")
        place.setText(\.conditions, "ケージ持参")
        try check(place.canConfirm && place.source.isEmpty, "where it was checked is optional")
        place.checkedAt = t0
        place.setText(\.telephone, "03-1234-5678")
        place.setText(\.source, "市のホームページ")
        place.setText(\.name, "第一小学校 体育館")
        try check(place.checkedAt == t0, "phone, source and name keep the checked day")
        place.setText(\.conditions, "ケージ持参")
        try check(place.checkedAt == t0, "the same conditions keep the day")
        place.setText(\.conditions, "ケージとリード")
        try check(place.checkedAt == nil, "new conditions are checked again")
        try check(place.telephoneURL?.absoluteString == "tel:0312345678", "phone link")
        place.telephone = "  "
        try check(place.telephoneURL == nil, "no link without a number")
        try check(place.mapURL == nil, "no map without an address")
        place.address = "東京都千代田区1-1"
        let map = place.mapURL?.absoluteString ?? ""
        try check(map.hasPrefix("https://maps.apple.com/?q=") && !map.contains(" "), "map link")
        try check(EvacuationDestination.Kind.allCases.map(\.title) == ["避難所", "親戚・知人", "ペットホテル・病院"], "kinds")
    }

    /// Round 2: a calendar fixed to Tokyo, so the day counts do not move with the runner.
    static var tokyo: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    static func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        tokyo.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// Round 2: 期限 on food, water, medicine and 療法食; shown from 30 days before.
    static func expiryRules() throws {
        var plan = EvacuationPlan()
        let food = plan.supplies.firstIndex(where: { $0.title == "フード・水・食器" })!
        let medicine = plan.supplies.firstIndex(where: { $0.title == "薬・療法食" })!
        let carrier = plan.supplies.firstIndex(where: { $0.title == "キャリー" })!
        try check(plan.supplies[food].canHaveExpiry && plan.supplies[medicine].canHaveExpiry, "food and medicine have a 期限")
        try check(!plan.supplies[carrier].canHaveExpiry, "a carrier has no 期限")
        try check(EvacuationSupply(title: "水 2L").canHaveExpiry && EvacuationSupply(title: "療法食").canHaveExpiry
                  && EvacuationSupply(title: "薬：A錠").canHaveExpiry, "water, 療法食 and a cat's medicine")
        let now = day(2026, 11, 9)
        try check(plan.expiryState(now: now, calendar: tokyo) == nil, "no 期限, no line")
        plan.supplies[food].expiresAt = day(2026, 11, 21, hour: 0)
        try check(plan.supplies[food].daysUntilExpiry(now: now, calendar: tokyo) == 12, "whole days")
        try check(plan.supplies[food].expiryText(now: now, calendar: tokyo) == "期限まであと12日", "期限まであと〇日")
        try check(plan.expiryState(now: now, calendar: tokyo) == "フード・水・食器の期限まであと12日", "the hub names it")
        plan.supplies[food].expiresAt = day(2026, 12, 9)
        try check(plan.supplies[food].expiryText(now: now, calendar: tokyo) == "期限まであと30日", "30 days is shown")
        plan.supplies[food].expiresAt = day(2026, 12, 10)
        try check(plan.supplies[food].expiryText(now: now, calendar: tokyo) == nil, "31 days is not")
        try check(plan.expiryState(now: now, calendar: tokyo) == nil, "nothing near")
        plan.supplies[food].expiresAt = day(2026, 11, 9, hour: 23)
        try check(plan.supplies[food].expiryText(now: now, calendar: tokyo) == "期限は今日", "the day itself")
        plan.supplies[food].expiresAt = day(2026, 11, 8, hour: 23)
        try check(plan.supplies[food].expiryText(now: now, calendar: tokyo) == "期限切れ", "the day after")
        try check(plan.expiryState(now: now, calendar: tokyo) == "フード・水・食器が期限切れ", "an expired item")
        // The nearest one is named; an item not on the checklist is left out.
        plan.supplies[food].expiresAt = day(2026, 11, 30)
        plan.supplies[medicine].expiresAt = day(2026, 11, 20)
        try check(plan.expiryState(now: now, calendar: tokyo) == "薬・療法食の期限まであと11日", "the nearest first")
        plan.supplies[medicine].isNeeded = false
        try check(plan.expiryState(now: now, calendar: tokyo) == "フード・水・食器の期限まであと21日", "only the checklist")
        // A 期限 is kept when the title changes, so it can still be taken off.
        plan.supplies[food].title = "皿"
        try check(plan.supplies[food].canHaveExpiry, "an item with a 期限 keeps the field")
        // It round-trips, and the plan stays valid.
        let again = try JSONDecoder().decode(EvacuationPlan.self, from: JSONEncoder().encode(plan))
        try check(again == plan, "期限 round-trips")
        try again.validate()
    }

    /// Round 2: the half-year review and 14 days before each 期限, 9:00, text only.
    static func noticeSchedule() throws {
        let never = Date(timeIntervalSince1970: 0)
        let now = day(2026, 11, 9)
        var plan = EvacuationPlan()
        try check(plan.notices(now: now, dismissedAt: never, calendar: tokyo).isEmpty, "a plan never saved has none")
        plan.createdAt = day(2026, 11, 1, hour: 10)
        var notices = plan.notices(now: now, dismissedAt: never, calendar: tokyo)
        try check(notices.map(\.id) == ["evacuation.review"], "the review only")
        let due = plan.reviewDueDate(dismissedAt: never)!
        try check(due == plan.createdAt!.addingTimeInterval(halfYear), "half a year after making")
        // The notice is the first 9:00 at or after the moment the in-app note shows.
        try check(notices[0].date >= due && notices[0].date.timeIntervalSince(due) < 24 * 60 * 60, "on the day it falls due")
        try check(tokyo.component(.hour, from: notices[0].date) == 9, "at 9:00")
        try check(!plan.reviewIsDue(now: due.addingTimeInterval(-60), dismissedAt: never)
                  && plan.reviewIsDue(now: due.addingTimeInterval(60), dismissedAt: never), "the same day as the in-app note")
        try check(notices[0].body == "避難の備えを見直す時期です。", "review text")
        // A later 「最後に見直した日」 or 「閉じる」 moves it.
        plan.lastCheckedAt = day(2027, 1, 10)
        try check(plan.reviewDueDate(dismissedAt: never) == day(2027, 1, 10).addingTimeInterval(halfYear), "counts from the last review")
        let closed = day(2027, 3, 1)
        try check(plan.reviewDueDate(dismissedAt: closed) == closed.addingTimeInterval(halfYear), "counts from 閉じる")
        try check(plan.notices(now: closed.addingTimeInterval(halfYear + 2 * 24 * 60 * 60), dismissedAt: closed, calendar: tokyo).isEmpty,
                  "nothing for a day already past")
        // 14 days before each 期限, one per day; past ones are not set.
        let food = plan.supplies.firstIndex(where: { $0.title == "フード・水・食器" })!
        let medicine = plan.supplies.firstIndex(where: { $0.title == "薬・療法食" })!
        plan.supplies[food].expiresAt = day(2026, 12, 20)
        plan.supplies[medicine].expiresAt = day(2026, 12, 20, hour: 8)
        notices = plan.notices(now: now, dismissedAt: never, calendar: tokyo)
        let expiry = notices.filter { $0.id.hasPrefix("evacuation.expiry.") }
        try check(expiry.map(\.id) == ["evacuation.expiry.2026-12-06"], "one notice for the day, 14 days before")
        try check(expiry[0].date == day(2026, 12, 6, hour: 9), "at 9:00")
        try check(expiry[0].body == "持ち出すものの期限まであと14日です。", "expiry text")
        plan.supplies[medicine].expiresAt = day(2026, 11, 15)
        try check(plan.notices(now: now, dismissedAt: never, calendar: tokyo).filter { $0.id.hasPrefix("evacuation.expiry.") }.count == 1,
                  "a 期限 within 14 days has no notice (the list shows it)")
        plan.supplies[medicine].isNeeded = false
        plan.supplies[medicine].expiresAt = day(2027, 2, 1)
        try check(plan.notices(now: now, dismissedAt: never, calendar: tokyo).filter { $0.id.hasPrefix("evacuation.expiry.") }.count == 1,
                  "an item not on the checklist has none")
        // Every identifier has the tool's prefix; no item or cat's name in the text.
        plan.supplies[food].title = "むぎの療法食"
        for notice in plan.notices(now: now, dismissedAt: never, calendar: tokyo) {
            try check(notice.id.hasPrefix(EvacuationScheduledNotice.prefix), "prefix")
            try check(!notice.body.contains("むぎ") && !notice.body.contains("療法食"), "text only")
        }
        // Many 期限 stay under the app's limit.
        for index in 0..<40 {
            var item = EvacuationSupply(title: "フード\(index)")
            item.expiresAt = day(2027, 1, 1).addingTimeInterval(Double(index) * 24 * 60 * 60)
            plan.supplies.append(item)
        }
        try check(plan.notices(now: now, dismissedAt: never, calendar: tokyo).count <= 1 + EvacuationScheduledNotice.expiryLimit, "limit")
        // A plan with nothing left to tell has no notices to keep.
        var emptied = EvacuationPlan()
        emptied.supplies = []
        try check(emptied.notices(now: now, dismissedAt: never, calendar: tokyo).isEmpty, "nothing for an empty plan")
    }

    /// Round 2: 「いま避難する」 records the day only when an item is checked.
    static func takenOnTheDay() throws {
        var plan = EvacuationPlan()
        let before = plan
        plan.recordTaken(UUID(), now: t0)
        try check(plan == before, "an unknown item records nothing")
        let id = plan.supplies[0].id
        plan.carriedIDs = [plan.supplies[1].id]
        plan.recordTaken(id, now: t0)
        try check(plan.lastCheckedAt == t0 && plan.lastReadyDate == t0, "a check records the day")
        try check(plan.carriedIDs == [plan.supplies[1].id] && plan.checkStartedAt == nil, "the list's own checks stay")
    }
}
