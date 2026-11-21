#!/usr/bin/env python3
"""11/21: app bugs found in the second check (source-level pins)."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CARE = (ROOT / "NekoWidget/Views/CatCareView.swift").read_text(encoding="utf-8")


class CatDeletionCleanupTests(unittest.TestCase):
    def test_delete_runs_cleanup_and_clears_farewell(self):
        start = CARE.index("private func delete(_ profile: CatProfilePresentation)")
        body = CARE[start:start + 900]
        self.assertIn("CatProfileDeletionCleanup.run(", body)
        self.assertIn("keepsCareRecord: sharedWithFamily", body)
        self.assertIn("CatFarewell.setting(nil, for: subject.key", body)

    def test_cleanup_reaches_every_tool(self):
        start = CARE.index("enum CatProfileDeletionCleanup")
        body = CARE[start:start + 2600]
        for needle in ("CareHandoffStore.shared", "EvacuationStore.shared", "removeCat(",
                       "CatPreparednessStore.shared.delete", "LostCatDraftStore.shared.delete",
                       "deletedAt = now", "VeterinaryVisitStore.shared"):
            self.assertIn(needle, body)
        # A family cat keeps its record for everyone.
        self.assertLess(body.index("guard !keepsCareRecord"), body.index("CatCareStore.shared.update"))

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


if __name__ == "__main__":
    unittest.main()
