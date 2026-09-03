import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


class InactiveWindowNameSyncContractTests(unittest.TestCase):
    def test_window_list_renders_cache_then_reconciles_only_inactive_names(self) -> None:
        model = source("NekoWidget/ViewModels/PairingViewModel.swift")
        window_list = source("NekoWidget/Views/MainTabView.swift")
        refresh = model.split(
            "func synchronizeWindowNamesForWindowList() async", 1
        )[1].split("@discardableResult", 1)[0]
        self.assertNotIn("synchronizeWindowNameForUser", refresh)
        self.assertIn("synchronizeInactiveWindowNamesForWindowList", refresh)
        self.assertIn("reloadPrivateWindowCatalog()", refresh)
        reload_method = window_list.split(
            "private func reload() async", 1
        )[1].split("private struct CatalogPresentationSnapshot", 1)[0]
        self.assertIn("await model.synchronizeWindowNamesForWindowList()", reload_method)
        first_local_reload = reload_method.index("await reloadCatalogPresentation()")
        network_refresh = reload_method.index(
            "await model.synchronizeWindowNamesForWindowList()"
        )
        self.assertLess(first_local_reload, network_refresh)
        self.assertLess(reload_method.index("isLoading = false"), network_refresh)

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

    def test_legacy_peer_normalization_cannot_delay_visible_name_repair(self) -> None:
        coordinator = source("NekoWidget/Services/MomentSharingCoordinator.swift")
        sync = coordinator.split(
            "private func synchronizeWindowName(", 1
        )[1].split("guard role == .inviter", 1)[0]
        apply_name = sync.index(
            "PrivateWindowPresentationStore.applySynchronizedOwnerName"
        )
        schedule_normalization = sync.index(
            "scheduleLegacyReplacementPeerNormalization"
        )
        self.assertLess(apply_name, schedule_normalization)
        confirmation = coordinator.split(
            "private static func confirmedLegacyReplacementPeer", 1
        )[1].split("private func normalizeLegacyReplacementPeerBestEffort", 1)[0]
        for field in (
            "status.deviceID == pairing.recoveryDeviceID",
            "status.transcriptData == recoveryTranscript",
            "status.credential.agreementPublicKey == candidateAgreement",
            "status.credential.signingPublicKey == candidateSigning",
        ):
            self.assertIn(field, confirmation)

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
