#!/usr/bin/env python3
"""11/21: app bugs found in the second check (source-level pins)."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CARE = (ROOT / "NekoWidget/Views/CatCareView.swift").read_text(encoding="utf-8")


class CatDeletionCleanupTests(unittest.TestCase):
    def test_delete_runs_cleanup_and_clears_farewell(self):
        start = CARE.index("private func delete(_ profile: CatProfilePresentation)")
        body = CARE[start:start + 1600]
        self.assertIn("CatProfileDeletionCleanup.run(", body)
        self.assertIn("keepsCareRecord: shared)", body)
        self.assertLess(body.index("let shared = sharedWithFamily"), body.index("await profileActions.deleteProfile"))
        self.assertIn("CatFarewell.setting(nil, for: subject.key", body)
        self.assertIn('CatFarewell.setting(day, for: "tool-" + catID.uuidString, in: days)', body)

    def test_cleanup_reaches_every_tool(self):
        start = CARE.index("enum CatProfileDeletionCleanup")
        body = CARE[start:CARE.index("/// Test builds only: the day a cat passed away")]
        for needle in ("CareHandoffStore.shared", "EvacuationStore.shared", "removeCat(",
                       "CatPreparednessStore.shared.delete", "LostCatDraftStore.shared.delete",
                       "deletedAt = now", "VeterinaryVisitStore.shared"):
            self.assertIn(needle, body)
        # A family cat keeps its records; they follow the family's cat, and
        # nothing of it is deleted.
        kept = body[body.index("if keepsCareRecord {"):body.index("care.update { $0.cats.removeAll")]
        self.assertIn("plan.cats[index].toolCatID = careCatID", kept)
        self.assertIn("return", kept)
        self.assertNotIn("delete(", kept)
        # A deleted cat names no photo, so its files can leave.
        self.assertIn("state.cats[index].facePhoto = nil", body)
        self.assertIn("state.cats[index].detachedVaccinations = nil", body)

    def test_dialog_says_tool_records_go(self):
        self.assertNotIn("ツールの記録は残ります", CARE)
        self.assertIn("ツールに書いたことが消えます", CARE)


CLIENT = (ROOT / "NekoWidget/Services/ProductionGroupWindowClient.swift").read_text(encoding="utf-8")
FACTORY = (ROOT / "NekoWidget/Services/FamilyNotebookServiceFactory.swift").read_text(encoding="utf-8")
WINDOW = (ROOT / "NekoWidget/Views/GroupWindowView.swift").read_text(encoding="utf-8")


class RecoveredPersonDeletionTests(unittest.TestCase):
    def test_recovered_person_is_deleted_first(self):
        start = WINDOW.index("private func delete() async {")
        body = WINDOW[start:start + 1200]
        self.assertLess(body.index("FamilyNotebookServiceFactory.deleteRecoveredPerson(client)"),
                        body.index("client.requestIdentityDeletion()"))

    def test_signed_by_the_recovered_device_with_its_own_receipt(self):
        start = CLIENT.index("func requestDeletion(of recovered: GroupDeviceIdentity")
        body = CLIENT[start:start + 2600]
        self.assertIn("identity: recovered", body)
        self.assertIn("store.read(Self.deletionAccount)", body)
        self.assertIn("createOnly: true", body)

    def test_only_another_person(self):
        start = FACTORY.index("static func deleteRecoveredPerson(")
        body = FACTORY[start:start + 1600]
        self.assertIn("recovered.personID != usual", body)
        self.assertIn("GroupIdentityDeletionLocalData.remove(record)", body)


STORE = (ROOT / "NekoWidget/Services/CatCareStore.swift").read_text(encoding="utf-8")
VIEW_MODEL = (ROOT / "NekoWidget/ViewModels/AppViewModel.swift").read_text(encoding="utf-8")


class CarePhotoFilesTests(unittest.TestCase):
    """保存 reads every photo the file names; a named file is never removed."""

    def test_every_named_photo_counts(self):
        start = STORE.index("static func usedPhotoNames(")
        body = STORE[start:start + 600]
        self.assertNotIn("deletedAt", body)
        self.assertIn("detachedVaccinations", body)

    def test_removal_checks_the_saved_file_and_the_personal_copy(self):
        start = STORE.index("private func savedPhotoNames()")
        body = STORE[start:start + 700]
        self.assertIn("CatCareDecoding.backupPhotoNames(bytes)", body)
        self.assertIn("CatCareDecoding.backupPhotoNames(CatCareDecoding.personalBackup(bytes))", body)
        remove = STORE[STORE.index("private func removePhotoFiles("):]
        self.assertIn("let named = savedPhotoNames() else { return }", remove[:400])

    def test_family_writing_removes_nothing(self):
        self.assertIn("if !familyProjection {"+chr(10)+"                removePhotoFiles(", STORE)


class ImportBesideACatTests(unittest.TestCase):
    def test_the_only_cat_keeps_its_photo(self):
        start = VIEW_MODEL.index("func importCatProfileDates(")
        body = VIEW_MODEL[start:start + 3200]
        self.assertIn("if reconciled.profiles.count == 1, profiles.profiles.count > 1 {", body)
        self.assertIn("pinned.pinSingleCatPhotoBeforeAnotherProfile(shownPhotoIdentifier: shown?.photo)", body)


if __name__ == "__main__":
    unittest.main()
