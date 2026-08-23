from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def section(value: str, start: str, end: str) -> str:
    start_index = value.index(start)
    end_index = value.index(end, start_index)
    return value[start_index:end_index]


class FamilyWindowWidgetBoundaryTests(unittest.TestCase):
    def test_family_cache_is_separate_and_purge_scoped(self) -> None:
        container = source("Shared/AppGroup/SharedContainer.swift")
        family_urls = section(
            container,
            "static var familyWidgetManifestURL",
            "static var logsDirectoryURL",
        )
        self.assertIn("sharingCacheDirectoryURL", family_urls)
        self.assertIn("family-widget-manifest.v1.json", family_urls)
        self.assertIn("family-widget-cache", family_urls)
        self.assertNotIn("widgetManifestURL", family_urls)
        self.assertNotIn('"widget-cache"', family_urls)

        builder = source("NekoWidget/Services/WidgetCacheBuilder.swift")
        personal_clear = section(
            builder,
            "func clear() throws",
            "private static func familySourceSnapshot",
        )
        self.assertNotIn("familyWidget", personal_clear)
        self.assertNotIn("family-widget", personal_clear)

    def test_family_manifest_contains_no_routable_identity(self) -> None:
        models = source("Shared/Models/WidgetManifest.swift")
        family_models = section(
            models,
            "struct FamilyWidgetManifestItem",
            "/// Each widget family records",
        )
        self.assertIn("sourceDigest", family_models)
        self.assertNotIn("momentID", family_models)
        self.assertNotIn("participant", family_models.lower())
        self.assertNotIn("localIdentifier", family_models)

    def test_family_publication_revalidates_lifecycle_and_state(self) -> None:
        builder = source("NekoWidget/Services/WidgetCacheBuilder.swift")
        publication = section(
            builder,
            "func buildFamilyWindow(",
            "func clear() throws",
        )
        self.assertGreaterEqual(
            publication.count("withStateWhileLifecycleLocked"),
            3,
        )
        self.assertIn("current.state == .available", builder)
        self.assertIn("current.state == .acknowledged", builder)
        self.assertIn("clearFamilyWindowWhileLifecycleLocked", publication)
        self.assertIn("Data(SHA256.hash(data: current.data))", publication)

        app_model = source("NekoWidget/ViewModels/AppViewModel.swift")
        refresh = section(
            app_model,
            "func refreshFamilyWindowOutputs(trigger: String) async",
            "private nonisolated static func familyWindowInputs",
        )
        self.assertLess(
            refresh.index("familyWindowPresentation = .empty"),
            refresh.index("PairingInstallationGuard.bootstrapAsync()"),
        )
        self.assertLess(
            refresh.index("buildFamilyWindow("),
            refresh.index("familyWindowPresentation = presentation"),
        )

    def test_family_clear_and_history_are_fail_closed(self) -> None:
        builder = source("NekoWidget/Services/WidgetCacheBuilder.swift")
        clear = section(
            builder,
            "private static func clearFamilyWindowWhileLifecycleLocked(",
            "private static func updateFamilyHistoryAndRemoveStaleFiles(",
        )
        self.assertLess(
            clear.index("removeItem(at: cacheDirectory)"),
            clear.index("writeSharingJSON(manifest, to: manifestURL)"),
        )

        history = section(
            builder,
            "private static func updateFamilyHistoryAndRemoveStaleFiles(",
            "private static func writeSharingJSON<Value: Encodable>(",
        )
        self.assertIn("retainedCandidateDigests", history)
        self.assertIn("familySourceSnapshot(for: candidate, in: state)", history)
        self.assertNotIn("FileManager.default.fileExists", history)

    def test_widget_cannot_like_or_route_a_family_photo_identifier(self) -> None:
        provider = source("NekoWidgetWidget/NekoWidgetTimelineProvider.swift")
        family_entry = section(
            provider,
            "private func familyEntry(",
            "private func availableItems(",
        )
        self.assertIn("localIdentifier: nil", family_entry)
        self.assertIn("isLiked: false", family_entry)
        self.assertIn("isLikeInteractionEnabled: false", family_entry)

        view = source("NekoWidgetWidget/NekoWidgetView.swift")
        self.assertIn(
            "entry.photoSourceIdentifier == WidgetPhotoSource.personalLibraryID",
            view,
        )

        deep_link = source("Shared/Routing/DeepLink.swift")
        self.assertIn('components.host = "family-window"', deep_link)
        entry = source("NekoWidgetWidget/NekoWidgetEntry.swift")
        self.assertIn("return DeepLink.familyWindow()", entry)

    def test_unknown_source_does_not_fall_back_to_personal(self) -> None:
        reader = source("NekoWidgetWidget/WidgetManifestReader.swift")
        source_switch = section(
            reader,
            "static func cacheURL(\n        for filename",
            "private static func readManifest",
        )
        self.assertIn("case WidgetPhotoSource.personalLibraryID", source_switch)
        self.assertIn("case WidgetPhotoSource.familyWindowID", source_switch)
        self.assertIn("default:\n            return nil", source_switch)

        provider = source("NekoWidgetWidget/NekoWidgetTimelineProvider.swift")
        self.assertIn(
            "guard source.id == WidgetPhotoSource.personalLibraryID else { return [] }",
            provider,
        )

    def test_home_exposes_latest_count_and_existing_history(self) -> None:
        home = source("NekoWidget/Views/HomeView.swift")
        self.assertIn('"いま届いた・\\(privateWindowDisplayName)"', home)
        self.assertIn('Text("ほか \\(familyWindowPresentation.safeCount - 1)枚")', home)
        self.assertIn('accessibilityIdentifier("window-latest-family-photo")', home)
        self.assertIn("showsFamilyWindow = true", home)

    def test_named_window_is_presentation_only_and_migration_safe(self) -> None:
        container = source("Shared/AppGroup/SharedContainer.swift")
        presentation_url = section(
            container,
            "static var privateWindowPresentationURL",
            "static var sharingCacheDirectoryURL",
        )
        self.assertIn("sharingCacheDirectoryURL", presentation_url)
        self.assertIn("window-presentation.v1.json", presentation_url)
        self.assertIn("window-name-sync.v1.json", presentation_url)

        models = source("Shared/Models/WidgetManifest.swift")
        self.assertIn('static let fallback = "ふたりのまど"', models)
        self.assertIn("var windowDisplayName: String? = nil", models)

        pairing = source("Shared/Sharing/PairingCore.swift")
        pairing_state = section(pairing, "struct PairingState", "struct PairingCredential")
        self.assertNotIn("windowDisplayName", pairing_state)

        store = source("Shared/Sharing/PairingKeychainStore.swift")
        local_presentation = section(
            store,
            "struct PrivateWindowPresentationState",
            "private static func writeWhileLifecycleLocked",
        )
        self.assertIn("pairingBindingSHA256", local_presentation)
        self.assertIn("SharingLifecycleGate.withValidatedToken", local_presentation)
        self.assertNotIn("PairingStateStore.save(", local_presentation)

        sync_state = section(
            store,
            "struct PrivateWindowNameSyncState",
            "private static func writeWhileLifecycleLocked(_ value: PrivateWindowNameSyncState)",
        )
        self.assertIn("acceptedOwnerRevision", sync_state)
        self.assertIn("acceptedCiphertextSHA256", sync_state)
        self.assertIn("pendingPayload", sync_state)
        self.assertIn("pendingClientRequestID", sync_state)
        self.assertNotIn("displayName", sync_state)
        self.assertNotIn("PairingStateStore.save(", sync_state)

        moment_core = source("Shared/Sharing/MomentSharingCore.swift")
        moment_kind = section(moment_core, "enum MomentKind", "enum MomentReportReason")
        self.assertNotIn("window", moment_kind.lower())
        name_crypto = section(
            moment_core,
            "enum PrivateWindowNameCrypto",
            "enum MomentKind",
        )
        self.assertIn("jp.nekowidget.private-window-name.v1", name_crypto)
        self.assertIn("ownerMemberID", name_crypto)
        self.assertNotIn("ownerParticipantID", name_crypto)
        self.assertNotIn("PairingCredential", name_crypto)
        self.assertNotIn("PairingCrypto", name_crypto)
        self.assertIn("ownerSigningPrivateKey", name_crypto)
        self.assertIn("ownerSignature", name_crypto)
        self.assertIn("ChaChaPoly.open", name_crypto)

        api_client = source("NekoWidget/Services/MomentSharingAPIClient.swift")
        self.assertIn('path: "/v2/window-name"', api_client)
        self.assertNotIn('case window', moment_kind)

        coordinator = source("NekoWidget/Services/MomentSharingCoordinator.swift")
        best_effort = section(
            coordinator,
            "private func synchronizeWindowNameBestEffort(",
            "private func synchronizeWindowName(",
        )
        self.assertIn("return false", best_effort)
        normal_sync = section(
            coordinator,
            "let sent = try await sendOutbox(",
            'SharedLog.app.info(\n                "moment-sharing"',
        )
        self.assertLess(
            normal_sync.index("let received = try await receiveChanges("),
            normal_sync.index("synchronizeWindowNameBestEffort("),
        )

        builder = source("NekoWidget/Services/WidgetCacheBuilder.swift")
        publication = section(builder, "func buildFamilyWindow(", "func clear() throws")
        self.assertIn("windowDisplayName: resolvedWindowDisplayName", publication)
        self.assertIn("renamed.windowDisplayName = resolvedWindowDisplayName", publication)
        self.assertLess(
            publication.index("renamed.windowDisplayName = resolvedWindowDisplayName"),
            publication.index("let renderedFiles"),
        )

        provider = source("NekoWidgetWidget/NekoWidgetTimelineProvider.swift")
        entry = source("NekoWidgetWidget/NekoWidgetEntry.swift")
        widget_view = source("NekoWidgetWidget/NekoWidgetView.swift")
        configuration = source("NekoWidgetWidget/NekoWidgetConfigurationIntent.swift")
        self.assertIn("familyWindowDisplayName()", provider)
        self.assertIn("let windowDisplayName: String", entry)
        self.assertIn("entry.windowDisplayName", widget_view)
        self.assertIn('static let familyWindowID = "family-window"', configuration)
        self.assertIn('static let personalLibraryID = "personal-library"', configuration)
        self.assertIn('name: "このiPhoneの猫写真"', configuration)
        self.assertIn("SharedContainer.familyWidgetWindowDisplayName()", configuration)
        self.assertNotIn("WidgetManifestReader", configuration)

        processor = source("NekoWidget/Services/MomentShareHandoffProcessor.swift")
        self.assertIn("PrivateWindowPresentationStore.resolvedDisplayName", processor)
        self.assertIn("displayName: windowDisplayName", processor)

        share_view = source("NekoWidgetShareExtension/ShareViewController.swift")
        self.assertIn(
            'destinationLabel.text = "届け先　\\(admission.displayName)"',
            share_view,
        )
        self.assertIn(
            'detailLabel.text = "この1枚を\\(admission.displayName)',
            share_view,
        )

        handoff = source("Shared/Sharing/MomentShareHandoffStore.swift")
        binding = section(
            handoff,
            "static func makeBindingSHA256(",
            "static func publishAdmissions(",
        )
        self.assertNotIn("displayName", binding)

        app_model = source("NekoWidget/ViewModels/AppViewModel.swift")
        refresh = section(
            app_model,
            "func refreshFamilyWindowOutputs(trigger: String) async",
            "private nonisolated static func familyWindowInputs",
        )
        refresh_failure = section(
            refresh,
            "        } catch {",
            "            Self.logError(",
        )
        self.assertIn(
            "windowDisplayName: privateWindowDisplayName",
            refresh_failure,
        )

        pairing_view_model = source("NekoWidget/ViewModels/PairingViewModel.swift")
        pairing_view = source("NekoWidget/Views/PairingView.swift")
        family_view = source("NekoWidget/Views/FamilyWindowView.swift")
        sharing_view_model = source("NekoWidget/ViewModels/MomentSharingViewModel.swift")
        self.assertIn(".momentSharingPresentationNeedsRefresh", family_view)
        self.assertIn("model.reloadWindowDisplayName()", family_view)
        self.assertIn("func reloadWindowDisplayName()", sharing_view_model)
        self.assertIn("guard let pairing = snapshot.state", sharing_view_model)
        save_name = section(
            pairing_view,
            "private func saveWindowNameIfPossible()",
            "private var utcBoundaryMinute",
        )
        self.assertIn("guard model.canEditWindowDisplayName", save_name)
        update_name = section(
            pairing_view_model,
            "func updateWindowDisplayName(",
            "func reloadWindowDisplayName()",
        )
        self.assertIn("windowNameCoordinator.synchronizeWindowNameForUser", update_name)
        self.assertIn(".momentSharingPresentationNeedsRefresh", update_name)
        self.assertNotIn(".sharingMediaSyncRequested", update_name)
        self.assertIn("相手へ共有中…", pairing_view)
        self.assertIn("相手のiPhoneへ反映できる状態です。", pairing_view_model)

        name_only_admission = section(
            processor,
            "func refreshAdmissionLabel(",
            "private func reconcileOrPromote(",
        )
        self.assertIn("MomentShareHandoffStore.publishAdmissions", name_only_admission)
        self.assertNotIn("nextPendingCapture", name_only_admission)

        coordinator = source("NekoWidget/Services/MomentSharingCoordinator.swift")
        explicit_name_sync = section(
            coordinator,
            "private func performWindowNameSynchronizationForUser(",
            "private func performSynchronization(",
        )
        self.assertIn("synchronizeWindowName(", explicit_name_sync)
        self.assertIn("refreshAdmissionLabel(", explicit_name_sync)
        self.assertNotIn("sendOutbox(", explicit_name_sync)
        self.assertNotIn("receiveChanges(", explicit_name_sync)
        window_name_sync = section(
            coordinator,
            "private func synchronizeWindowName(",
            "private func requireWindowNameSynchronizationAllowed(",
        )
        self.assertLess(
            window_name_sync.index("requireWindowNameSynchronizationAllowed("),
            window_name_sync.index("api.currentWindowName("),
        )
        report_only_name_guard = section(
            coordinator,
            "private func requireWindowNameSynchronizationAllowed(",
            "private func sendOutbox(",
        )
        self.assertIn("MomentSharingError.reportOnly", report_only_name_guard)
        self.assertIn("resetAfterRemoteRevocationAsync", report_only_name_guard)
        reset = section(
            pairing_view_model,
            "private func resetLocalPairing(",
            "private func record(",
        )
        self.assertIn(
            "NotificationCenter.default.post(name: .sharingMediaSyncRequested",
            reset,
        )

        runtime_self_test = source("NekoWidget/Services/SharingRuntimeSelfTest.swift")
        self.assertIn("Models a GET/PUT response resuming after unlink", runtime_self_test)
        self.assertIn("reportOnlyCounts.gets == 0", runtime_self_test)
        self.assertIn("reportOnlyCounts.puts == 0", runtime_self_test)

    def test_sharing_surfaces_do_not_assume_a_family_relationship(self) -> None:
        surfaces = [
            "NekoWidget/Views/PairingView.swift",
            "NekoWidget/Views/FamilyWindowView.swift",
            "NekoWidget/Views/HomeView.swift",
            "NekoWidget/Views/SettingsView.swift",
            "NekoWidget/ViewModels/MomentSharingViewModel.swift",
            "NekoWidgetShareExtension/ShareViewController.swift",
            "NekoWidgetWidget/NekoWidgetConfigurationIntent.swift",
            "NekoWidgetWidget/NekoWidgetView.swift",
            "Shared/Sharing/MomentSharingCore.swift",
        ]
        for relative in surfaces:
            value = source(relative)
            self.assertNotIn("家族のまど", value, relative)
            self.assertNotIn("家族から", value, relative)

    def test_window_and_cat_copy_name_the_actual_destination_or_object(self) -> None:
        home = source("NekoWidget/Views/HomeView.swift")
        widget = source("NekoWidgetWidget/NekoWidgetView.swift")
        widget_configuration = source(
            "NekoWidgetWidget/NekoWidgetConfigurationIntent.swift"
        )
        self.assertIn('"\\(privateWindowDisplayName)に届いた一枚"', home)
        self.assertNotIn('"\\(privateWindowDisplayName)から届いた一枚"', home)
        self.assertIn('"\\(entry.windowDisplayName)に届いた一枚"', widget)
        self.assertIn('"\\(entry.windowDisplayName)に届いた写真"', widget)
        self.assertNotIn('"\\(entry.windowDisplayName)から届いた', widget)
        self.assertIn('detail: "このまどに届いた最新の一枚"', widget_configuration)
        self.assertIn('name: "このiPhoneの猫写真"', widget_configuration)
        self.assertIn('detail: "このiPhoneで見つけた猫写真"', widget_configuration)
        self.assertNotIn('name: "このiPhoneの写真"', widget_configuration)

        settings = source("NekoWidget/Views/SettingsView.swift")
        profiles = source("NekoWidget/Views/CatProfilesView.swift")
        onboarding = source("NekoWidget/Views/OnboardingPresentation.swift")
        permission = source("NekoWidget/Views/PhotoPermissionView.swift")
        scan = source("NekoWidget/Views/ScanStatusView.swift")
        self.assertIn('"ねこのプロフィール"', settings)
        self.assertIn('.navigationTitle("ねこのプロフィール")', profiles)
        self.assertIn('"このiPhoneの猫写真を探すために、"', onboarding)
        self.assertIn('"このiPhoneの猫写真を見つけよう"', permission)
        self.assertIn('"このiPhoneの猫写真を探しています"', scan)

        surfaces_without_legacy_album_copy = [
            "NekoWidget/Views/CatCandidateCurationView.swift",
            "NekoWidget/Views/CatProfilePhotoCurationViews.swift",
            "NekoWidget/Views/CatProfilesView.swift",
            "NekoWidget/Views/CatSimilarityReviewView.swift",
            "NekoWidget/Views/GrowthAlbumView.swift",
            "NekoWidget/Views/LikedPhotosView.swift",
            "NekoWidget/Views/OnboardingPresentation.swift",
            "NekoWidget/Views/PhotoPermissionView.swift",
            "NekoWidget/Views/ScanStatusView.swift",
            "NekoWidget/Views/WidgetPlacementGuideView.swift",
            "NekoWidgetWidget/NekoWidgetConfigurationIntent.swift",
            "NekoWidgetWidget/NekoWidgetView.swift",
        ]
        for relative in surfaces_without_legacy_album_copy:
            self.assertNotIn("うちの子", source(relative), relative)

        self.assertEqual(
            home.count("うちの子"),
            home.count('写真アプリの「うちの子」アルバム'),
        )
        self.assertEqual(
            settings.count("うちの子"),
            settings.count('写真アプリの「うちの子」'),
        )

    def test_multi_window_is_documented_but_remains_out_of_scope(self) -> None:
        adr = source("docs/ADR-018-名前付きの非公開なまど.md")
        for required_boundary in [
            "`WindowID`",
            "`WindowCatalog`",
            "`WindowContext`",
            "per-window隔離",
            "Widget cache",
            "Share Extension",
            "deep link",
        ]:
            self.assertIn(required_boundary, adr)
        self.assertIn("段階4の実装契約（未実装）", adr)
        self.assertIn("複数まど、3人以上、1人の複数端末、APNs", adr)
        self.assertIn("名前付きの非公開なまど1つ", adr)

    def test_pairing_starts_with_one_explicit_role_path(self) -> None:
        pairing = source("NekoWidget/Views/PairingView.swift")
        unpaired = section(
            pairing,
            "case .unpaired:",
            "case .creatingInvitation:",
        )
        self.assertIn("setupChoiceSection", unpaired)
        self.assertIn("setupPath == .create", unpaired)
        self.assertIn("setupPath == .join", unpaired)
        self.assertIn("windowNameSection(state)", unpaired)
        self.assertLess(
            unpaired.index("setupPath == .create"),
            unpaired.index("windowNameSection(state)"),
        )
        self.assertIn("新しいまどを作る", pairing)
        self.assertIn("招待されたまどに参加", pairing)
        self.assertIn("この名前でまどを作る", pairing)
        self.assertNotIn("Keychain:", pairing)
        self.assertNotIn("App Group", pairing)

        core = source("Shared/Sharing/PairingCore.swift")
        errors = section(core, "enum PairingError:", "enum PairingCrypto")
        self.assertNotIn("Keychain:", errors)
        self.assertNotIn("App Group", errors)
        self.assertNotIn("return message", errors)
        self.assertIn('"invitation_unavailable"', errors)
        self.assertIn('"enrollment_unavailable"', errors)

        moment_errors = source("Shared/Sharing/MomentSharingCore.swift")
        self.assertIn('"moment_daily_quota_exceeded"', moment_errors)
        self.assertIn('"report_daily_quota_exceeded"', moment_errors)

        self.assertIn("hasAcceptedPairingTerms = false", pairing)
        self.assertIn(".onChange(of: model.state?.phase)", pairing)
        self.assertIn("previousPhase != .unpaired", pairing)
        self.assertIn("model.userFacingStatusMessage", pairing)
        self.assertNotIn("model.state?.lastError ??", pairing)

        pairing_model = source("NekoWidget/ViewModels/PairingViewModel.swift")
        status = section(
            pairing_model,
            "var userFacingStatusMessage: String?",
            "var hasCurrentMediaSharingConsent",
        )
        self.assertIn("state?.lastError != nil", status)
        self.assertNotIn("return state?.lastError", status)

    def test_manual_refresh_result_is_visible_without_claiming_read_receipt(self) -> None:
        pairing_model = source("NekoWidget/ViewModels/PairingViewModel.swift")
        family_model = source("NekoWidget/ViewModels/MomentSharingViewModel.swift")
        family_view = source("NekoWidget/Views/FamilyWindowView.swift")
        self.assertIn("manualCheckMessage", pairing_model)
        self.assertIn("manualCheckSucceeded", pairing_model)
        self.assertIn("manualRefreshMessage", family_model)
        self.assertIn("family-window-manual-refresh-result", family_view)
        self.assertIn("manualRefreshSucceeded", family_model)
        self.assertIn("exclamationmark.triangle", family_view)
        self.assertIn("現在このiPhoneで表示できる新しい写真はありません", family_model)
        self.assertNotIn("相手が見ました", family_model)
        self.assertNotIn("相手が受け取りました", family_model)

    def test_foreground_sync_reloads_an_open_window_without_network_loop(self) -> None:
        app_model = source("NekoWidget/ViewModels/AppViewModel.swift")
        family_model = source("NekoWidget/ViewModels/MomentSharingViewModel.swift")
        family_view = source("NekoWidget/Views/FamilyWindowView.swift")
        synchronize = section(
            app_model,
            "private func synchronizeMomentSharing(trigger: String) async",
            "func refreshFamilyWindowOutputs(trigger: String) async",
        )
        self.assertIn(".momentSharingContentNeedsReload", synchronize)
        self.assertIn(".momentSharingContentNeedsReload", family_view)
        self.assertIn("model.reloadContentFromDisk()", family_view)
        disk_reload = section(
            family_model,
            "func reloadContentFromDisk()",
            "private func reload(",
        )
        self.assertIn("notifyPresentationChange: false", disk_reload)
        self.assertNotIn("synchronize(", disk_reload)

    def test_saved_received_memory_stays_inside_bounded_sharing_history(self) -> None:
        store = source("Shared/Sharing/MomentSharingStore.swift")
        record = section(
            store,
            "struct MomentSavedMemoryRecord",
            "struct MomentSharingState",
        )
        save = section(
            store,
            "static func setSavedMemory(",
            "/// Opaque relay cursors",
        )
        self.assertIn("static let schemaVersion = 6", store)
        self.assertIn("momentID", record)
        self.assertIn("savedAt", record)
        self.assertNotIn("localJPEGFileName", record)
        self.assertNotIn("participant", record.lower())
        self.assertIn("state.reportOnlyUntil == nil", save)
        self.assertIn("item.state == .available", save)
        self.assertIn("item.state == .acknowledged", save)
        self.assertIn(".isRegularFileKey", save)
        self.assertNotIn("SharedLikeStore", save)
        self.assertIn("state.savedMemories.removeAll", store)
        retention = section(
            store,
            "let savedAtByMomentID",
            "var expiredPending",
        )
        self.assertIn("newestDisplayableMomentID", retention)
        self.assertLess(
            retention.index("firstIsSafetyState != secondIsSafetyState"),
            retention.index("firstSavedAt = savedAtByMomentID"),
        )

        runtime = source("NekoWidget/Services/SharingRuntimeSelfTest.swift")
        saved_boundary = section(
            runtime,
            "private static func testMomentSavedMemoryBoundary()",
            "private static func testMomentEmptyCursorNormalization()",
        )
        self.assertIn("MomentSharingStateStore.maximumLocalHistoryCount", saved_boundary)
        self.assertIn("capped.savedMemories.count == 497", saved_boundary)
        self.assertIn("revocationTombstone", saved_boundary)
        self.assertIn("expired.savedMemories.isEmpty", saved_boundary)
        migration = section(
            runtime,
            "private static func testMomentOutcomeLedgerAndMigration()",
            "private static func testMomentCommitAcknowledgementMetadata()",
        )
        self.assertIn('schema5Object?["schemaVersion"] = 5', migration)
        self.assertIn('schema5Object?.removeValue(forKey: "savedMemories")', migration)
        self.assertIn("migratedSchema5.savedMemories.isEmpty", migration)

        family = source("NekoWidget/Views/FamilyWindowView.swift")
        self.assertIn("思い出に残す", family)
        self.assertIn("写真アプリやiCloudには追加されず", family)
        self.assertIn("最大90日", family)


if __name__ == "__main__":
    unittest.main()
