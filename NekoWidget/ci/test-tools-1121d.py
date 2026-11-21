#!/usr/bin/env python3
"""11/21 (d): bugs in 病院で見せる, 避難に備える and 預けるとき (source-level pins).

The rules themselves are checked by ci/verify-evacuation-plan.swift and
ci/verify-tool-outputs.swift; these pins hold the screens to them."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


VET = read("NekoWidget/Views/VeterinaryVisitView.swift")
EVAC_VIEW = read("NekoWidget/Views/EvacuationPreparationView.swift")
EVAC_STORE = read("NekoWidget/Services/EvacuationStore.swift")
EVAC_PLAN = read("NekoWidget/Services/EvacuationPlan.swift")
CARE_PLAN = read("NekoWidget/Services/CareHandoffPlan.swift")
CARE_STORE = read("NekoWidget/Services/CareHandoffStore.swift")


def section(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


class VetMemoNeverLosesTypedTextTests(unittest.TestCase):
    def test_a_long_field_does_not_stop_the_others(self):
        save = section(VET, "    private func save(completing: Bool = false) async {", "    private func adoptSaved(")
        self.assertNotIn("!tooLong", save)
        for field in ("doctorNote", "prescription", "observations", "questions"):
            self.assertIn(f"Self.savable({field}, else: base.", save)
        self.assertIn("guard completing || draft != base else { return }", save)
        self.assertIn("text.count > 500 ? saved : text", VET)

    def test_autosave_never_writes_back_into_the_field_being_edited(self):
        save = section(VET, "    private func save(completing: Bool = false) async {", "    private func adoptSaved(")
        self.assertNotIn("adopt(try await", save)
        self.assertEqual(save.count("adoptSaved(try await"), 2)
        adopt = section(VET, "    private func adoptSaved(", "    private func adopt(_ value: VeterinaryVisit) {")
        self.assertIn("if observations == sent.observations, value.observations != observations", adopt)
        self.assertIn("if questions == sent.questions, value.questions != questions", adopt)
        plain = section(VET, "    private func adopt(_ value: VeterinaryVisit) {", "\n    }\n")
        self.assertIn("if observations != value.observations { observations = value.observations }", plain)

    def test_leaving_with_unsaved_text_asks(self):
        self.assertIn("private var blocksLeaving: Bool { changes && (tooLong || error != nil) }", VET)
        self.assertIn(".navigationBarBackButtonHidden(isPage && blocksLeaving)", VET)
        page = section(VET, "    private var page: some View {", "    private var blocksLeaving: Bool")
        self.assertIn("if isPage && blocksLeaving {", page)
        self.assertIn("Button { close() } label: { Label(\"戻る\"", page)
        close = section(VET, "    private func close() {", "\n    }\n")
        self.assertIn("if changes { discarding = true } else { dismiss() }", close)

    def test_a_failed_reload_keeps_the_open_memo(self):
        reload = section(VET, "    private func reload() async {", "    private var detachedPhotoRows")
        self.assertNotIn("ready = false", reload)


class EvacuationDepartedCatsTests(unittest.TestCase):
    def test_no_screen_lists_every_item_or_cat(self):
        # Checklists, いま避難する and the hub read the active items only.
        self.assertNotIn("store.plan.supplies.filter(\\.isNeeded)", EVAC_VIEW)
        self.assertEqual(EVAC_VIEW.count("store.plan.activeSupplies(departed: CatFarewell.departedIdentifiers())"), 2)
        self.assertIn("store.plan.activeSupplies(departed: departed)", EVAC_VIEW)
        self.assertIn("store.plan.expiryState(departed: departed)", EVAC_VIEW)
        self.assertNotIn("ForEach(store.plan.cats)", EVAC_VIEW)
        now = section(EVAC_VIEW, "private struct EvacuationNowView: View {", "/// 環境省")
        self.assertIn("ForEach(livingCats) { cat in", now)
        self.assertIn("ForEach(ownerChoices)", EVAC_VIEW)
        self.assertIn("plan.addRecommendedSupplies(departed: departed)", EVAC_VIEW)
        self.assertIn("plan.followMedicines(medicines, departed: departed)", EVAC_VIEW)
        self.assertNotIn("guard let cat = store.plan.cats.first else", EVAC_VIEW)

    def test_store_and_paper_follow(self):
        self.assertIn("next.followMedicines(medicineNames(), departed: departed)", EVAC_STORE)
        book = section(EVAC_STORE, "    func bookRecords() throws", "    private static func normalizedJPEG(")
        self.assertIn("let needed = plan.activeSupplies(departed: departed)", book)
        self.assertNotIn("plan.supplies.filter(\\.isNeeded)", book)

    def test_plan_file_stays_buildable_alone(self):
        # Built alone by ci/verify-evacuation-plan.swift: no app-only types.
        code = "\n".join(line.split("//")[0] for line in EVAC_PLAN.splitlines())
        for name in ("CatFarewell", "UIKit", "SwiftUI", "UserNotifications"):
            self.assertNotIn(name, code)


class EvacuationReviewAndNoticeTests(unittest.TestCase):
    def test_redo_resets_the_review_clock(self):
        self.assertIn("    var reviewRestartedAt: Date?\n", EVAC_PLAN)
        clear = section(EVAC_PLAN, "    mutating func clearChecks(now: Date = Date()) {", "\n    }\n")
        self.assertIn("reviewRestartedAt = now", clear)
        self.assertEqual(EVAC_PLAN.count("reviewRestartedAt ?? made"), 2)

    def test_late_expiry_and_gregorian_trigger(self):
        self.assertIn("    var expirySetAt: Date?\n", EVAC_PLAN)
        self.assertIn("if let set = item.expirySetAt, set > at, let late = nineOClock(onOrAfter: set) { at = late }", EVAC_PLAN)
        notice = section(EVAC_STORE, "    private static func replace(", "\n    }\n")
        self.assertNotIn("Calendar.current.dateComponents", notice)
        self.assertIn("var gregorian = Calendar(identifier: .gregorian)", notice)
        self.assertIn("parts.calendar = gregorian", notice)


class CareHandoffKeepsTypedTextTests(unittest.TestCase):
    def test_only_the_handed_text_expires(self):
        self.assertIn("var madePeriod: String? = nil", CARE_PLAN)
        self.assertIn("var madeRequest: String? = nil", CARE_PLAN)
        clear = section(CARE_PLAN, "    mutating func clearStaleRequest(", "\n    }\n")
        self.assertIn("if let madePeriod, period == madePeriod { period = \"\" }", clear)
        self.assertIn("if let madeRequest, request == madeRequest { request = \"\" }", clear)
        made = section(CARE_STORE, "    func recordMade(", "\n    }\n")
        self.assertIn("$0.madePeriod = $0.period; $0.madeRequest = $0.request", made)
        store = section(CARE_STORE, "    func clearStaleRequest(", "\n    }\n")
        self.assertNotIn('$0.period = ""', store)
        stale = section(CARE_PLAN, "    func requestIsStale(", "\n    }\n")
        self.assertIn("CareCheckTable.range(period: period, now: lastMadeAt, calendar: calendar)", stale)

    def test_period_parsing(self):
        table = section(CARE_PLAN, "    static func range(period: String", "\n    }\n}")
        self.assertIn("(?<![泊\\d.])(\\d{1,2})\\s*日(?!間)", table)
        self.assertIn("\\s*泊", table)
        self.assertIn("\\s*日間", table)
        self.assertIn("func isDate(_ match: NSTextCheckingResult) -> Bool", table)
        verify = read("ci/verify-tool-outputs.swift")
        for case in ('days("11/3から2泊3日")', 'days("12/30から1.5日") == nil', "try careMemoOldStayExpires(calendar: calendar)"):
            self.assertIn(case, verify)


class RegisteredTests(unittest.TestCase):
    def test_runs_in_quick_checks(self):
        script = read("ci/run-quick-ios-checks.sh")
        self.assertIn("python3 ci/test-tools-1121d.py", script)
        verify = read("ci/verify-evacuation-plan.swift")
        for name in ("try redoingTheCheckIsAReview()", "try lateExpiryGetsOneNotice()", "try departedCatsEverywhere()"):
            self.assertIn(name, verify)


if __name__ == "__main__":
    unittest.main()
