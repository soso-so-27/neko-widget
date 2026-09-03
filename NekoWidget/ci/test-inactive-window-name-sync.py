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
        coordinator = source("NekoWidget/Services/MomentSharingCoordinator.swift")
        method = coordinator.split(
            "func synchronizeInactiveWindowNamesForWindowList", 1
        )[1].split("#if DEBUG", 1)[0]
        self.assertNotIn("activatePrivateWindow", method)
        self.assertNotIn("activateWhileLifecycleLocked", method)
        self.assertIn("loadInactiveWindowNameAuthorizations", method)
        self.assertIn("authorization: authorization", method)
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
        coordinator = source("NekoWidget/Services/MomentSharingCoordinator.swift")
        self.assertGreaterEqual(
            coordinator.count("localWindowID: authorization.localWindowID"), 8
        )

    def test_report_only_and_catalog_binding_fail_closed_before_get(self) -> None:
        coordinator = source("NekoWidget/Services/MomentSharingCoordinator.swift")
        sync = coordinator.index("private func synchronizeWindowName(")
        guard = coordinator.index("try await requireWindowNameSynchronizationAllowed", sync)
        get = coordinator.index("let remote = try await api.currentWindowName", sync)
        self.assertLess(guard, get)
        scoped_guard = coordinator.split(
            "if let localWindowID = authorization.localWindowID", 1
        )[1].split("let markerUntil", 1)[0]
        self.assertIn("catalog.activeWindowID != localWindowID", scoped_guard)
        self.assertIn("entry.spaceID == authorization.state.spaceID", scoped_guard)
        self.assertIn("entry.credentialAccount == authorization.state.credentialAccount", scoped_guard)
        self.assertIn("momentShareHandoffReportOnlyMarkerURL", scoped_guard)
        self.assertIn("scopedState.reportOnlyUntil == nil", scoped_guard)


if __name__ == "__main__":
    unittest.main()
