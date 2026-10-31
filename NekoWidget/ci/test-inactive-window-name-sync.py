import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


class InactiveWindowNameSyncContractTests(unittest.TestCase):
    def test_scoped_files_are_distinct_per_local_window(self) -> None:
        shared = source("Shared/AppGroup/SharedContainer.swift")
        for name in (
            "privateWindowPresentationURL",
            "privateWindowNameSyncStateURL",
            "momentShareHandoffReportOnlyMarkerURL",
        ):
            match = re.search(
                rf"static func {name}\(localWindowID: String\?\).*?\n    \}}",
                shared,
                re.S,
            )
            self.assertIsNotNone(match, f"missing scoped {name}")
            self.assertIn(
                "sharingCacheDirectoryURL(localWindowID: localWindowID)",
                match.group(0),
            )

    def test_inactive_reconciliation_never_changes_selection(self) -> None:
        shared = source("Shared/AppGroup/SharedContainer.swift")
        targeted_update = shared.split(
            "static func updateDisplayNameWhileLifecycleLocked", 1
        )[1].split("static func updateActiveDraftDisplayNameWhileLifecycleLocked", 1)[0]
        self.assertNotIn("activeWindowID =", targeted_update)

    def test_scoped_sync_preserves_rollback_and_pending_boundaries(self) -> None:
        store = source("Shared/Sharing/PairingKeychainStore.swift")
        self.assertIn("accepted > payload.context.ownerRevision", store)
        self.assertIn("accepted == payload.context.ownerRevision", store)
        self.assertIn(
            "loadWhileLifecycleLocked(localWindowID: localWindowID)", store
        )
        self.assertIn(
            "writeWhileLifecycleLocked(state, localWindowID: localWindowID)", store
        )


    def test_authenticated_remote_name_disambiguates_only_local_conflicts(self) -> None:
        shared = source("Shared/AppGroup/SharedContainer.swift")
        store = source("Shared/Sharing/PairingKeychainStore.swift")
        helper = shared.split(
            "makeDisplayNameAvailableForSynchronizedWindowWhileLifecycleLocked", 1
        )[1].split("updateActiveDraftDisplayNameWhileLifecycleLocked", 1)[0]
        self.assertIn("localWindowID != localWindowID", helper)
        self.assertIn("spaceID == nil", helper)
        self.assertIn("credentialAccount == nil", helper)
        self.assertIn("disambiguatedDisplayName", helper)
        self.assertIn("state.storageRevision += 1", helper)
        self.assertIn(
            "makeDisplayNameAvailableForSynchronizedWindowWhileLifecycleLocked",
            store,
        )
        presentation_store = store.split(
            "enum PrivateWindowPresentationStore", 1
        )[1]
        manual_save = presentation_store.split("static func save(", 1)[1].split(
            "promoteActiveDraftWhileLifecycleLocked", 1
        )[0]
        self.assertIn("duplicateWindowName", manual_save)



if __name__ == "__main__":
    unittest.main()
