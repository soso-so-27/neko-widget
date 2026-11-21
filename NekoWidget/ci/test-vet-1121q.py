#!/usr/bin/env python3
"""11/21: 病院で見せる, 迷子の備え and 預けるとき after the whole-app check (source-level pins)."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def section(text: str, start: str, end: str) -> str:
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


STORE = source("NekoWidget/Services/VeterinaryVisitStore.swift")
VIEW = source("NekoWidget/Views/VeterinaryVisitView.swift")
CAPTURE = source("NekoWidget/Views/VeterinaryCapture.swift")
PREPAREDNESS = source("NekoWidget/Services/CatPreparednessStore.swift")
CARE = source("NekoWidget/Views/CareHandoffView.swift")
VERIFY = source("ci/verify-veterinary-visits.swift")
QUICK = source("ci/run-quick-ios-checks.sh")


class VetMemoRefileTests(unittest.TestCase):
    """A family cat whose profile was deleted keeps its memos."""

    def test_one_store_api_moves_every_memo_at_once(self):
        refile = section(STORE, "func refile(from old: UUID, to new: UUID) throws -> Int {", "/// For CatProfileDeletionCleanup")
        self.assertIn("Self.lock.lock(); defer { Self.lock.unlock() }", refile)
        self.assertIn("revision: UUID()", refile)
        self.assertIn("photo.catID == old", refile)
        # One write, compared by the family as if the memos had always been there.
        self.assertEqual(refile.count("try commit("), 1)
        self.assertIn("try commit(state, familyBefore: unchanged)", refile)
        self.assertIn("visitsChanged(before: familyBefore ?? load().visits, after: state.visits", STORE)
        # One open memo per cat: an empty one gives way, else the earlier is finished.
        self.assertIn("if let blank = open.first(where: Self.isBlank)", refile)
        self.assertIn("next[index].completedAt = VeterinaryVisit.now()", refile)

    def test_the_moved_memo_keeps_every_saved_field(self):
        struct = section(STORE, "struct VeterinaryVisit: Codable, Identifiable, Equatable, Sendable {", "var lastEditedAt")
        fields = re.findall(r"^\s+(?:let|var) (\w+)", struct, re.M)
        filed = section(STORE, "nonisolated static func filed(", "func cleanupPending()")
        for field in fields:
            self.assertIn(field + ":" if field in ("id", "catID", "catName", "revision", "startedOn",
                                                   "observations", "questions", "entries", "completedAt")
                          else "moved." + field + " = visit." + field, filed, field)

    def test_entry_point_for_the_deletion_cleanup(self):
        self.assertIn("static func refile(fromProfileID profileID: String, toCatID catID: UUID,", STORE)
        self.assertIn("verifiesRefile(suiteRoot.appendingPathComponent(\"refile\"))", VERIFY)

    def test_the_family_cat_page_moves_memos_left_under_its_old_profile(self):
        heal = section(VIEW, "private func refilingDeletedProfile(", "private var detachedPhotoRows")
        self.assertIn("CatProfileDeletionCleanup.pending() where job.keepsCareRecord && job.careCatID == catID", heal)
        self.assertIn("try? await store.refile(from: old, to: catID)", heal)
        self.assertIn("let loaded = await refilingDeletedProfile(stored)", VIEW)


class WeightSheetTests(unittest.TestCase):
    def test_a_failed_weight_keeps_the_sheet_open(self):
        self.assertIn("saving: { result in recordWeight(result, visit) })", VIEW)
        record = section(VIEW, "private func recordWeight(", "private func memoSection(")
        self.assertIn("-> String? {", record)
        self.assertIn('return "体重を保存できませんでした。もう一度お試しください。"', record)
        self.assertIn("return applied ? nil : CatCareListEditor.Kind.weight.limitSentence", record)
        self.assertNotIn("error =", record)


class PreparednessMoveTests(unittest.TestCase):
    def test_record_moves_copy_first_and_never_overwrites(self):
        move = section(PREPAREDNESS, "func move(from old: String, to new: String) throws {", "static func move(fromProfileID")
        self.assertIn("records[new] == nil", move)
        self.assertLess(move.index("copied[new] = record"), move.index("next.removeValue(forKey: old)"))
        self.assertNotIn("removeItem", move)
        entry = section(PREPAREDNESS, "static func move(fromProfileID", "private func persist(")
        self.assertIn('"guest-tool-" + catID.uuidString', entry)


class VetCatChoiceTests(unittest.TestCase):
    def test_photo_memo_cats_must_still_exist(self):
        reload = section(VIEW, "private func reload() async {", "/// The cats that exist here")
        self.assertIn("notes.flatMap { $0.note.context?.cats ?? [] }.filter(exists)", reload)
        self.assertIn("measuredCats.filter(exists)", reload)
        live = section(VIEW, "private func liveCatIDs(", "/// 11/21: a family cat whose profile")
        self.assertIn("record.deletedAt == nil", live)

    def test_departed_cat_gets_no_new_memo(self):
        opening = section(VIEW, "private func open(_ cat: PhotoMemoryNoteCat) async {", "private func reload()")
        self.assertIn("ToolCatDeparture.isDeparted(id: cat.id.uuidString, in: farewellJSON)", opening)
        self.assertLess(opening.index("isDeparted"), opening.index("store.current("))


class CameraTests(unittest.TestCase):
    def test_a_movie_not_kept_is_said_and_removed(self):
        picker = section(CAPTURE, "didFinishPickingMediaWithInfo", "imagePickerControllerDidCancel")
        self.assertIn("try manager.moveItem(at: movie, to: copy)", picker)
        self.assertIn("done(.failed)", picker)
        self.assertIn("try? manager.removeItem(at: movie)", picker)
        self.assertIn("VeterinaryCapture.removeLeftoverMovies()", VIEW)
        self.assertIn('"vet-capture-error"', VIEW)
        self.assertIn("if case .failed = shot {", VIEW)


class LostCatPhotoTests(unittest.TestCase):
    def test_large_photos_are_downsampled(self):
        self.assertEqual(PREPAREDNESS.count("VeterinaryCapture.copy(of: data)"), 2)
        self.assertNotIn("UIImage(data:", PREPAREDNESS)
        self.assertIn("CGImageSourceCreateThumbnailAtIndex", CAPTURE)


class CareShareTests(unittest.TestCase):
    def test_text_only_where_text_is_sent(self):
        self.assertIn("[CareMemoText(text)]", CARE)
        item = section(CARE, "private final class CareMemoText", "/// The tool's one safety sentence")
        self.assertIn("[.copyToPasteboard, .message, .mail]", item)
        self.assertIn("return nil", item)


class RegisteredTests(unittest.TestCase):
    def test_registered_after_photo(self):
        self.assertIn("python3 ci/test-photo-1121o.py\npython3 ci/test-vet-1121q.py\n", QUICK)


if __name__ == "__main__":
    unittest.main()
