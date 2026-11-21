#!/usr/bin/env python3
"""11/21 (1121n): この子 tab, 「この子のこと」 and the profile transfer file (source pins).

The logic parts run in ci/verify-cat-care.swift (liveRecordsOnly,
memoWeightsFollowTheMemo) and ci/verify-cat-household-identity.swift
(verifiesImportPlanSaysWhatApplyingDoes).
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def section(text: str, start: str, end: str) -> str:
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


CARE = source("NekoWidget/Views/CatCareView.swift")
CORE = source("NekoWidget/Services/CatCareCore.swift")
STORE = source("NekoWidget/Services/CatCareStore.swift")
HOME = source("NekoWidget/Views/CatHomeView.swift")
HOME_CARE = source("NekoWidget/Views/CatHomeCareView.swift")
TRANSFER = source("Shared/Models/CatProfileTransfer.swift")
TRANSFER_VIEW = source("NekoWidget/Views/CatProfileTransferView.swift")
MODEL = source("NekoWidget/ViewModels/AppViewModel.swift")


class AutosaveWritesOnlyChangedFields(unittest.TestCase):
    """2: a family member's newer write is not put back to the page's old value."""

    def test_write_compares_with_what_the_page_opened_with(self):
        write = section(CARE, "func write(to r: inout CatCareRecord", "// MARK: - Growing lists")
        self.assertIn("since base: CatCareDraft? = nil", write)
        self.assertIn("guard changed else { return }", write)
        for field in ("sex", "coat", "water", "ownerContact", "backupContact", "temperament"):
            self.assertIn(f"changed: changed(\\.{field})", write)
        self.assertIn("if changed(\\.microchipStatus) || changed(\\.microchip),", write)
        self.assertIn("if changed(\\.conditionsStatus) || changed(\\.conditions),", write)
        self.assertIn("if changed(\\.vetStatus) || changed(\\.vetName) || changed(\\.vetPhone),", write)

    def test_save_passes_the_base_and_shows_others_writes(self):
        save = section(CARE, "private func save() {", "private func takeFamilyWrites()")
        self.assertIn("let base = savedDraft", save)
        self.assertIn("by: state.deviceID, now: Date(), since: base)", save)
        self.assertIn("value.takingOthersWrites(fresh, untouchedSince: base, stored: storedDraft)", save)
        self.assertIn("draft.takingOthersWrites(fresh, untouchedSince: base, stored: storedDraft)", save)


class EntrySheetKeepsWhatWasTyped(unittest.TestCase):
    """3 and 9: a failed save keeps the sheet; an edit of a deleted entry says so."""

    def test_sheet_closes_only_after_saving(self):
        sheet = section(CARE, "struct CatCareListEntrySheet: View {", "extension CatCarePhotoRole: Identifiable")
        self.assertIn("let saving: (CatCareListEditor.Result) -> String?", sheet)
        save = section(sheet, "private func save() {", "\n    }\n}")
        self.assertIn("if let failure = saving(result) { message = failure; return }", save)
        self.assertLess(save.index("saving(result)"), save.index("saved = true"))
        self.assertLess(save.index("saved = true"), save.index("dismiss()"))

    def test_every_page_saves_entries_the_same_way(self):
        self.assertIn("CatCareListEntrySheet(editor: editor, catID: catID, saving: { result in apply(result) })", CARE)
        self.assertIn("store.applyEntry(result, catID: catID)", HOME_CARE)
        self.assertNotIn("saveFailed", HOME_CARE)
        entry = section(CARE, "func applyEntry(_ result: CatCareListEditor.Result, catID: UUID) -> String? {",
                        "/// One 見分ける写真 set or taken off")
        self.assertIn("state.liveIndex(catID: catID)", entry)
        self.assertIn("if deletedMeanwhile { return CatCareListEditor.deletedMeanwhileSentence }", entry)

    def test_a_deleted_entry_is_never_edited(self):
        apply = section(CARE, "func apply(to r: inout CatCareRecord, by: String, now: Date) -> Bool {",
                        "/// 11/14: each list's limit")
        self.assertIn("if editsDeletedEntry(in: r) { return false }", apply)
        self.assertIn('static let deletedMeanwhileSentence = "この記録は削除されています。"', CARE)
        bridge = source("NekoWidget/Services/FamilyNotebookCatCareBridge.swift")
        # The family notebook keeps a deletion final; reviving would not reach it.
        self.assertIn("guard item.deletedAt == nil else { return }", bridge)


class LiveRecordsOnly(unittest.TestCase):
    """7: one rule for finding a cat's record; one way a deleted ID comes back."""

    def test_lookups_read_the_live_record(self):
        self.assertIn("func liveIndex(catID: UUID) -> Int? {", CORE)
        self.assertIn("func record(profileID: UUID) -> CatCareRecord? {", CORE)
        self.assertNotIn("state.cats.firstIndex(where: { $0.catID == catID })", CARE)
        self.assertNotIn("state.cats.firstIndex(where: { $0.catID == catID })", HOME_CARE)
        self.assertIn("UUID(uuidString: profile.identifier).flatMap { careStore.state?.record(profileID: $0) }", HOME)

    def test_reviving_is_one_path(self):
        self.assertEqual(CORE.count("mutating func liveRecordIndex(catID: UUID, profileID: UUID?) -> Int {"), 1)
        ensure = section(STORE, "func ensureRecord(toolCatID: UUID", "// MARK: - The household")
        self.assertIn("state.liveRecordIndex(catID: toolCatID, profileID: profileID)", ensure)
        self.assertNotIn("state.cats.append", ensure)
        self.assertIn("}) else { return nil }", ensure)

    def test_tools_never_fill_a_deleted_cat(self):
        apply = section(CORE, "static func apply(_ source: CatCareImportSource", "static func apply(_ source: CatCareHouseholdImportSource")
        self.assertIn("if let found = state.liveIndex(catID: source.catID) {", apply)
        self.assertIn("} else if let profileID = source.profileID, let found = state.liveIndex(profileID: profileID) {", apply)
        self.assertEqual(apply.count("return\n"), 2)


class TransferSaysWhatItDoes(unittest.TestCase):
    """1: the confirm screen and the result come from the plan `applying` follows."""

    def test_one_plan(self):
        self.assertIn("func importPlan(into current: CatHouseholdIdentityState) -> ImportPlan {", TRANSFER)
        applying = section(TRANSFER, "func applying(to current: CatHouseholdIdentityState", "struct CatProfileImportPreview")
        self.assertIn("let plan = importPlan(into: current)", applying)
        self.assertIn("for entry in plan.added {", applying)
        self.assertIn("let plan = transfer.importPlan(into: reconciled)", MODEL)
        self.assertIn("plan: plan,", MODEL)

    def test_screen_lists_only_added_cats(self):
        self.assertIn("ForEach(item.plan.added) { profile in", TRANSFER_VIEW)
        self.assertNotIn("ForEach(item.transfer.profiles)", TRANSFER_VIEW)
        self.assertIn("Self.resultNotice(changed: changed, addsCats: !item.plan.added.isEmpty,", TRANSFER_VIEW)
        self.assertIn('case (true, false): return "猫の名前と日付を引き継ぎました。"', TRANSFER_VIEW)
        self.assertIn('default: return "選んだ写真がどの子かを引き継ぎました。"', TRANSFER_VIEW)


class DeletionCleanupFinishes(unittest.TestCase):
    """4: a cleanup that fails midway is tried again; 8: drafts follow the family cat."""

    def test_pending_marker_and_retry(self):
        cleanup = section(CARE, "enum CatProfileDeletionCleanup {", "/// Test builds only: the day a cat passed away")
        self.assertIn('static let pendingKey = "catProfileDeletionCleanup.pending.v1"', cleanup)
        self.assertIn("if await perform(job) { forget(profileID: job.profileID) }", cleanup)
        self.assertNotIn("try? CatPreparednessStore", cleanup)
        self.assertNotIn("try? await vet.delete", cleanup)
        self.assertIn("} catch { done = false }", cleanup)
        self.assertIn("CatProfileDeletionCleanup.retryPending(existingProfiles: presentation.profiles.map(\\.identifier))", HOME)
        self.assertIn("for entry in preview.plan.added { CatProfileDeletionCleanup.forget(profileID: entry.id.uuidString) }", MODEL)

    def test_lost_draft_moves_to_the_family_cat(self):
        cleanup = section(CARE, "enum CatProfileDeletionCleanup {", "/// Test builds only: the day a cat passed away")
        self.assertIn('let newKey = "guest-tool-" + careCatID.uuidString', cleanup)
        self.assertLess(cleanup.index("try lost.save(draft, for: newKey)"), cleanup.index("try lost.delete(for: key)"))


class PageAfterDeletingACat(unittest.TestCase):
    """5: the この子 tab's page moves off a deleted cat."""

    def test_page_is_clamped(self):
        self.assertIn(".onChange(of: cats.map(\\.id)) { old, new in", HOME)
        self.assertIn("let next = new[min(old.firstIndex(of: shown) ?? 0, new.count - 1)]", HOME)
        self.assertIn("!cats.contains(where: { $0.id == pageID })) { pageID = current.id }", HOME)


class MemoWeights(unittest.TestCase):
    """6: every cat's page reads memo weights; a moved or cleared memo takes its weight."""

    def test_tool_and_family_cats_read_memo_weights(self):
        self.assertIn("if catID != nil, !isProfile { await store.importMemoWeights() }", CARE)
        self.assertIn("cleared: Set(records.filter { $0.note.weight == nil }.map { $0.note.id.uuidString }))", CARE)
        self.assertIn("let stale = CatCareMemoWeights.stale(weights, cleared: cleared, cats: cats)", STORE)
        self.assertIn("if entry.deletedAt != nil, entry.editedBy == by { return nil }", CORE)


class VaccinationProofLeaves(unittest.TestCase):
    """8: a deleted vaccination's proof is named no more, so its file can go."""

    def test_delete_clears_the_proof(self):
        apply = section(CARE, "case let .delete(kind, entryID):", "return true\n        }")
        self.assertIn("r.replaceVaccinationProof(nil, for: entryID)", apply)
        self.assertLess(apply.index("replaceVaccinationProof(nil"), apply.index("r.vaccinations.markDeleted"))
        # The store removes a file only when no saved copy names it.
        self.assertIn("for name in names where !named.contains(name)", STORE)


if __name__ == "__main__":
    unittest.main()
