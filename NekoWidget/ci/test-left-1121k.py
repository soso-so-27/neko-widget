#!/usr/bin/env python3
"""11/21k: memo list read once, days that keep their day, readable labels,
the まど report copy (source-level pins)."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def section(text: str, start: str, end: str) -> str:
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


MEMO_STORE = source("NekoWidget/Services/PhotoMemoryNoteStore.swift")
MEMO_LIST = source("NekoWidget/Views/PhotoMemoryNoteLibraryView.swift")
VET = source("NekoWidget/Services/VeterinaryVisitStore.swift")
LOST = source("NekoWidget/Services/LostCatIncident.swift")
READABLE = source("NekoWidget/Services/ReadablePreservationExport.swift")
KEPT = source("NekoWidget/Services/GroupWindowStorage.swift")
MEMO_VERIFY = source("ci/verify-photo-memory-notes.swift")
TOOL_VERIFY = source("ci/verify-tool-outputs.swift")
KEPT_VERIFY = source("ci/verify-group-window-choices-survive-reinstall.swift")


class MemoListTests(unittest.TestCase):
    def test_the_list_reads_the_file_once(self):
        reload = section(MEMO_LIST, "func reload(reportsFailure: Bool = false) async {", "/// The caller supplies")
        self.assertIn("try await store.recordsWithPhotos()", reload)
        self.assertNotIn("store.photoURL(for: record.id)", reload)
        self.assertNotIn("for record in result", reload)
        listed = section(MEMO_STORE, "func recordsWithPhotos()", "/// 11/20: memos restored")
        self.assertEqual(listed.count("load(from: url)"), 1)
        # A broken name leaves that memo without its photo; it never throws.
        self.assertIn("guard let name = Self.photoName(of: record.note) else { continue }", listed)
        self.assertIn("verifiesListReadAndPhotoCleanup", MEMO_VERIFY)

    def test_a_deleted_memo_takes_its_photo_only_when_nothing_names_it(self):
        save = section(MEMO_STORE, "    private func save(\n        normalized text: String,", "private static func normalizedText")
        self.assertIn("if note == nil { removePhotoIfUnnamed(of: existing, at: url) }", save)
        self.assertLess(save.index("try commit(state, to: url)"), save.index("removePhotoIfUnnamed"))
        remove = section(MEMO_STORE, "private func removePhotoIfUnnamed(", "private static func normalizedText")
        self.assertIn("let saved = try? load(from: url) else { return }", remove)
        self.assertIn("$0.photoFile == name || $0.id.uuidString + \".jpg\" == name", remove)


class DayTests(unittest.TestCase):
    def test_the_vet_memo_keeps_the_day_it_was_started(self):
        self.assertIn("var createdOn: String? = nil", VET)
        self.assertIn("if let createdOn, PhotoMemoWeightValue.validDay(createdOn) { return createdOn }", VET)
        self.assertIn("return createdAt.map(Self.day)", VET)
        self.assertIn("visit.createdOn = visit.createdAt.map(VeterinaryVisit.day)", VET)
        self.assertIn("next.createdAt = current.createdAt; next.createdOn = current.createdOn", VET)
        self.assertIn("kept.createdOn = old.createdOn", VET)

    def test_lost_cat_days_keep_their_day_and_their_saved_key(self):
        self.assertIn("var contactedOn: String? = nil", LOST)
        self.assertIn('savedNextCheckAt = "nextCheckAt"', LOST)
        self.assertIn("contactedOn: LostCatText.dayKey(day)", LOST)
        self.assertIn("static func shownDay(", LOST)
        self.assertNotIn("init(from decoder", LOST)
        # The moment the cat was last seen (with its hour) stays a moment.
        self.assertIn("var lastSeenAt: Date?", LOST)
        self.assertIn("lostCatDaysKeepTheirDay()", TOOL_VERIFY)


class ReadableLabelTests(unittest.TestCase):
    def test_every_new_field_reads_in_japanese(self):
        labels = section(READABLE, "static let labels", "private static let bookkeeping")
        bookkeeping = section(READABLE, "private static let bookkeeping", "/// Stored codes shown")
        for key in ("expirySetAt", "reviewRestartedAt", "madePeriod", "madeRequest", "contactSuggestion"):
            self.assertRegex(labels, '"%s": "[^"]+"' % key)
        for key in ("expiresOn", "createdOn", "contactedOn", "nextCheckOn", "familyPhotoLink", "photoCloudIdentifier"):
            self.assertIn('"%s"' % key, bookkeeping)
        dates = section(READABLE, '["createdAt", "updatedAt", "writtenAt"', ".contains(key)")
        for key in ("expirySetAt", "reviewRestartedAt"):
            self.assertIn('"%s"' % key, dates)


class KeptReportTests(unittest.TestCase):
    def test_the_answer_is_kept_and_an_unsent_copy_covers_nothing(self):
        report = section(KEPT, "struct Report: Codable, Equatable, Sendable {", "/// 11/20: 「まどと家族の手帳のデータを消す」")
        self.assertIn("var reply: String? = nil", report)
        self.assertIn("var repliedAt: Date? = nil", report)
        self.assertIn("allReports(windowID: windowID, in: store).filter { $0.receiptNumber != nil }", KEPT)
        self.assertIn("reply: String? = nil, repliedAt: Date? = nil,", KEPT)
        self.assertIn("keptAnswersAndUnsentCopies()", KEPT_VERIFY)


if __name__ == "__main__":
    unittest.main()
