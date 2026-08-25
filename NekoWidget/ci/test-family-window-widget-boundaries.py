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

    def test_family_manifest_exposes_only_a_local_opaque_bookmark_target(self) -> None:
        models = source("Shared/Models/WidgetManifest.swift")
        family_models = section(
            models,
            "struct FamilyWidgetManifestItem",
            "/// Each widget family records",
        )
        self.assertIn("sourceDigest", family_models)
        self.assertIn("var momentID: String? = nil", family_models)
        self.assertIn("hasValidBookmarkTarget", family_models)
        self.assertIn("isOpaqueIdentifier", family_models)
        self.assertNotIn("participant", family_models.lower())
        self.assertNotIn("localIdentifier", family_models)
        self.assertNotIn("room", family_models.lower())

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

    def test_widget_keeps_received_photo_actions_separate_and_fail_closed(self) -> None:
        provider = source("NekoWidgetWidget/NekoWidgetTimelineProvider.swift")
        family_entry = section(
            provider,
            "private func familyEntry(",
            "private func availableItems(",
        )
        self.assertIn("localIdentifier: nil", family_entry)
        self.assertIn("isLiked: false", family_entry)
        self.assertIn("isLikeInteractionEnabled: false", family_entry)
        self.assertIn("familySourceDigest: item.sourceDigest", family_entry)
        self.assertIn("let interactionState = familyInteractionState", family_entry)
        self.assertIn("isBookmarked: interactionState?.isSavedMemory ?? false", family_entry)
        self.assertIn("isBookmarkInteractionEnabled: interactionState != nil", family_entry)
        self.assertIn("familyHeartStatus: heartStatus", family_entry)

        view = source("NekoWidgetWidget/NekoWidgetView.swift")
        self.assertIn(
            "entry.photoSourceIdentifier == WidgetPhotoSource.personalLibraryID",
            view,
        )
        self.assertIn("ToggleFamilyWidgetBookmarkIntent", view)
        self.assertIn('entry.isBookmarked ? "star.fill" : "star"', view)
        self.assertIn("自分だけの操作です。相手には送られません", view)
        self.assertIn("SendFamilyWidgetHeartIntent", view)
        self.assertIn('Image(systemName: "heart")', view)
        self.assertIn('Image(systemName: "clock.fill")', view)
        self.assertIn("ハートを送信待ちに追加", view)
        self.assertIn("ハートはサーバー受付済みです", view)

        deep_link = source("Shared/Routing/DeepLink.swift")
        self.assertIn('components.host = "family-window"', deep_link)
        entry = source("NekoWidgetWidget/NekoWidgetEntry.swift")
        self.assertIn("return DeepLink.familyWindow()", entry)

    def test_family_widget_bookmark_is_local_atomic_and_fail_closed(self) -> None:
        store = source("Shared/Sharing/MomentSharingStore.swift")
        toggle = section(
            store,
            "static func toggleSavedMemory(",
            "private static func validateSavedMemoryTarget(",
        )
        self.assertIn("mutate(validating: lifecycleToken)", toggle)
        self.assertIn("state.savedMemories.removeAll", toggle)
        self.assertIn("MomentSavedMemoryRecord", toggle)
        self.assertNotIn("outbox", toggle.lower())
        self.assertNotIn("URLSession", toggle)

        intent = source("NekoWidgetWidget/ToggleWidgetLikeIntent.swift")
        family_intent = section(
            intent,
            "struct ToggleFamilyWidgetBookmarkIntent",
            "struct SendFamilyWidgetHeartIntent",
        )
        self.assertIn("static var isDiscoverable = false", family_intent)
        self.assertIn("static var openAppWhenRun = false", family_intent)
        self.assertIn("FamilyWidgetActionTargetResolver.momentID", family_intent)
        self.assertIn("MomentSharingStateStore.toggleSavedMemory", family_intent)
        self.assertIn('reloadTimelines(ofKind: "NekoWidget")', family_intent)
        self.assertNotIn("URLSession", family_intent)
        self.assertNotIn("MomentOutbox", family_intent)

        models = source("NekoWidgetWidget/ToggleWidgetLikeIntent.swift")
        resolver = section(
            models,
            "private enum FamilyWidgetActionTargetResolver",
            "\n}\n",
        )
        self.assertIn("item.sourceDigest == sourceDigest", resolver)
        self.assertIn("item.hasValidBookmarkTarget", resolver)

        heart_intent = section(
            intent,
            "struct SendFamilyWidgetHeartIntent",
            "private enum FamilyWidgetActionTargetResolver",
        )
        self.assertIn("static var openAppWhenRun = false", heart_intent)
        self.assertIn("MomentSharingStateStore.queuePaw", heart_intent)
        self.assertIn('reloadTimelines(ofKind: "NekoWidget")', heart_intent)
        self.assertNotIn("URLSession", heart_intent)

        project = source("NekoWidget.xcodeproj/project.pbxproj")
        widget_sources = section(
            project,
            "A00000000000000000000025 /* Sources */ = {",
            "A00000000000000000000028 /* Sources */",
        )
        self.assertIn("MomentSharingCore.swift in Sources", widget_sources)
        self.assertIn("MomentSharingStore.swift in Sources", widget_sources)

    def test_heart_reaction_is_explicit_and_separate_from_private_memory(self) -> None:
        store = source("Shared/Sharing/MomentSharingStore.swift")
        bookmark = section(
            store,
            "static func toggleSavedMemory(",
            "private static func validateSavedMemoryTarget(",
        )
        paw = section(
            store,
            "static func queuePaw(",
            "static func markPawCommitting(",
        )
        self.assertNotIn("pawOutbox", bookmark)
        self.assertNotIn("URLSession", bookmark)
        self.assertIn("state.pawOutbox.append", paw)
        self.assertIn("validatePawTarget", paw)

        paw_target = section(
            store,
            "private static func validatePawTarget(",
            "static func markPawCommitting(",
        )
        self.assertIn("validateSavedMemoryTarget", paw_target)
        self.assertIn("now < item.accessExpiresAt", paw_target)
        self.assertIn("discardRejectedPaw", store)

        family_view = source("NekoWidget/Views/FamilyWindowView.swift")
        self.assertIn("family-window-send-paw", family_view)
        self.assertIn("写真を届けた相手にハートを送る", family_view)
        self.assertIn("family-window-save-memory", family_view)
        self.assertIn('Text("自分だけ・最長90日")', family_view)
        self.assertIn('Text("相手へ")', family_view)

        coordinator = source("NekoWidget/Services/MomentSharingCoordinator.swift")
        self.assertIn("sendPawOutbox", coordinator)
        self.assertIn("receivePawChanges", coordinator)
        self.assertIn("advanceReactionCursor", coordinator)
        self.assertIn("isPermanentPawRejection", coordinator)
        self.assertIn("discardRejectedPaw", coordinator)
        permanent = section(
            coordinator,
            "private nonisolated static func isPermanentPawRejection",
            "private func receivePawChanges(",
        )
        self.assertIn('"reaction_not_allowed"', permanent)

        self.assertIn('"reaction_daily_quota_reached"', permanent)
        for retryable_code in (
            "rate_limited",
            "stale_request",
            "replayed_request",
            "reaction_conflict",
            "invalid_authentication",
        ):
            self.assertNotIn(f'"{retryable_code}"', permanent)

        api = source("NekoWidget/Services/MomentSharingAPIClient.swift")
        paw_change = section(api, "struct MomentPawChange", "struct MomentPawChangesResult")
        paw_response = section(
            api,
            "private struct PawReactionChangesResponse",
            "private struct BlockResponse",
        )
        self.assertNotIn("createdAt", paw_change)
        self.assertNotIn("createdAt", paw_response)

    def test_received_photo_copy_is_explicit_add_only_and_lifecycle_validated(self) -> None:
        store = source("Shared/Sharing/MomentSharingStore.swift")
        payload = section(
            store,
            "static func photoLibraryCopyPayload(",
            "static func toggleSavedMemory(",
        )
        self.assertIn("withStateWhileLifecycleLocked", payload)
        self.assertIn("validateSavedMemoryTarget", payload)
        self.assertIn("MomentPhotoLibraryCopyPayload", payload)
        self.assertIn("item.receivedAt >= now.addingTimeInterval(-localHistorySeconds)", payload)

        service = source("NekoWidget/Services/PhotoAlbumService.swift")
        copy_service = section(
            service,
            "final class ReceivedPhotoLibraryCopyService",
            "\n}",
        )
        self.assertIn("@MainActor", service)
        self.assertIn("authorizationStatus(for: .addOnly)", copy_service)
        self.assertIn("requestAuthorization(for: .addOnly)", copy_service)
        self.assertIn("PHAssetCreationRequest.forAsset()", copy_service)
        self.assertIn("request.addResource", copy_service)
        self.assertNotIn("createdIdentifier", copy_service)

        model = source("NekoWidget/ViewModels/MomentSharingViewModel.swift")
        copy_action = section(
            model,
            "func copyToPhotoLibrary(_ item: MomentInboxItem) async",
            "private func showPhotoCopyActionMessage",
        )
        self.assertIn("MomentSharingStateStore.photoLibraryCopyPayload", copy_action)
        self.assertIn("copyService.requestAddAuthorization()", copy_action)
        self.assertIn("copyService.copy(payload)", copy_action)
        self.assertLess(
            copy_action.index("requestAddAuthorization"),
            copy_action.index("PairingInstallationGuard.bootstrap"),
        )
        self.assertLess(
            copy_action.index("photoLibraryCopyPayload"),
            copy_action.index("copyService.copy(payload)"),
        )

        family = source("NekoWidget/Views/FamilyWindowView.swift")
        self.assertIn('"写真アプリへコピーしますか？"', family)
        self.assertIn("photoCopyTarget = item", family)
        self.assertIn("共有解除・ブロック・アプリ削除後も残り", family)
        self.assertIn("このアプリからは削除できません", family)

        memory_action = section(
            model,
            "func toggleSavedMemory(_ item: MomentInboxItem) async",
            "private func showMemoryActionMessage",
        )
        heart_action = section(
            model,
            "func sendHeart(_ item: MomentInboxItem) async",
            "func toggleSavedMemory(_ item: MomentInboxItem) async",
        )
        self.assertNotIn("PhotoLibrary", memory_action)
        self.assertNotIn("PhotoLibrary", heart_action)

    def test_received_family_widget_uses_centered_full_bleed_canvases(self) -> None:
        plans = source("Shared/Models/WidgetRenderPlan.swift")
        centered = section(
            plans,
            "static func centeredFullBleedPlan(",
            "private static func clampedCropRect",
        )
        self.assertIn("centeredAt: CGPoint(x: 0.5, y: 0.5)", centered)
        self.assertIn("compositionMode: .catFullBleed", centered)

        builder = source("NekoWidget/Services/WidgetCacheBuilder.swift")
        publication = section(builder, "func buildFamilyWindow(", "func clear() throws")
        self.assertEqual(publication.count("centeredFullBleedPlan("), 3)
        self.assertIn("family-widget-v2-full-bleed-bookmark", builder)
        self.assertIn("momentID: source.item.id", publication)

        view = source("NekoWidgetWidget/NekoWidgetView.swift")
        family_image = section(
            view,
            "if entry.usesFamilySpecificImage",
            "} else {\n                            // During an app/extension update",
        )
        self.assertIn(".scaledToFill()", family_image)
        self.assertIn(".clipped()", family_image)

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

        pairing_core = source("Shared/Sharing/PairingCore.swift")
        local_device = section(
            pairing_core,
            "var resolvedLocalMomentDeviceID: String?",
            "static func unpaired(",
        )
        self.assertIn("if let localMomentDeviceID", local_device)
        self.assertIn("recoveryWasLocalDeviceReplacement == true", local_device)
        self.assertIn("return recoveryDeviceID", local_device)
        self.assertIn("return memberID", local_device)

        moment_api_implementation = section(
            api_client,
            "actor URLSessionMomentSharingAPIClient",
            "private final class MomentNoRedirectSessionDelegate",
        )
        reservation = section(
            moment_api_implementation,
            "func reserve(\n        item: MomentOutboxItem",
            "func upload(\n        momentID: String",
        )
        self.assertIn("MomentReservationIdentityPolicy.accepts(", reservation)
        self.assertLess(
            reservation.index("MomentReservationIdentityPolicy.acceptsContext("),
            reservation.index("let response: ReservationResponse = try await sendJSON("),
        )
        self.assertNotIn(
            "response.moment.senderDeviceId == localMemberID",
            reservation,
        )

        reservation_identity = section(
            api_client,
            "enum MomentReservationIdentityPolicy",
            "enum MomentSendFailurePolicy",
        )
        self.assertIn(
            "pairingState.acceptsPersistedMomentDeviceID(context.senderDeviceID)",
            reservation_identity,
        )
        self.assertIn(
            "responseDeviceID == localMomentDeviceID",
            reservation_identity,
        )

        coordinator = source("NekoWidget/Services/MomentSharingCoordinator.swift")
        best_effort = section(
            coordinator,
            "private func synchronizeWindowNameBestEffort(",
            "private func synchronizeWindowName(",
        )
        self.assertIn("return false", best_effort)
        normal_sync = section(
            coordinator,
            "sent = try await sendOutbox(",
            'SharedLog.app.info(\n                "moment-sharing"',
        )
        self.assertLess(
            normal_sync.index("received = try await receiveChanges("),
            normal_sync.index("synchronizeWindowNameBestEffort("),
        )
        self.assertIn("inboundState.inbox != localSharingState.inbox", normal_sync)
        self.assertIn(".momentSharingPresentationNeedsRefresh", normal_sync)
        self.assertIn(".momentSharingContentNeedsReload", normal_sync)
        self.assertLess(
            normal_sync.index(".momentSharingPresentationNeedsRefresh"),
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
        self.assertIn(
            "senderDeviceID: localMomentDeviceID",
            processor,
        )

        pairing_store = source("Shared/Sharing/PairingKeychainStore.swift")
        self.assertIn(
            "value.localMomentDeviceID != originalLocalMomentDeviceID",
            pairing_store,
        )

        pairing_view_model = source("NekoWidget/ViewModels/PairingViewModel.swift")
        finish_recovery = section(
            pairing_view_model,
            "private func finishLocalDeviceRecovery(",
            "private func validateDeviceRecoveryStatus(",
        )
        self.assertIn(
            "current.localMomentDeviceID = recoveredDeviceID",
            finish_recovery,
        )

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
        self.assertIn("resetLocalPairing", report_only_name_guard)
        self.assertIn(".reportOnlyWindowClosed", report_only_name_guard)
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

    def test_window_name_sync_survives_missing_media_consent_after_reports(self) -> None:
        coordinator = source("NekoWidget/Services/MomentSharingCoordinator.swift")
        report_start = "let reported = try await sendReportOutbox("
        report_only_start = coordinator.index(report_start)
        normal_start = coordinator.index(
            report_start,
            report_only_start + len(report_start),
        )
        normal_end = coordinator.index("\n        } catch {", normal_start)
        synchronization = coordinator[normal_start:normal_end]
        consent_predicate = section(
            synchronization,
            "let hasCurrentMediaConsent =",
            "if !hasCurrentMediaConsent {",
        )
        self.assertIn("mediaSharingConsentVersion", consent_predicate)
        self.assertIn("PairingMediaSharingConsent.currentVersion", consent_predicate)
        self.assertIn("mediaSharingConsentAcceptedAt != nil", consent_predicate)
        no_consent = section(
            synchronization,
            "if !hasCurrentMediaConsent {",
            "} else {",
        )
        self.assertIn("handoffProcessor.revokeAdmissions(", no_consent)
        self.assertIn("sent = 0", no_consent)
        self.assertIn("received = 0", no_consent)
        self.assertNotIn("sendOutbox(", no_consent)
        self.assertNotIn("receiveChanges(", no_consent)
        self.assertNotIn("refreshAdmissionsAndDrain(", no_consent)
        self.assertLess(
            synchronization.index("sendReportOutbox("),
            synchronization.index("if !hasCurrentMediaConsent {"),
        )
        self.assertIn(
            "\n            }\n            // Keep presentation metadata",
            synchronization,
        )
        self.assertLess(
            synchronization.index("// Keep presentation metadata"),
            synchronization.index("synchronizeWindowNameBestEffort("),
        )

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
        main_tab = source("NekoWidget/Views/MainTabView.swift")
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
        self.assertIn('Label("ホーム", systemImage: "house.fill")', main_tab)
        self.assertNotIn('Label("まど",', main_tab)
        self.assertIn('.navigationTitle("ホーム")', home)
        self.assertNotIn('.navigationTitle("まど")', home)
        onboarding = source("NekoWidget/Views/OnboardingPresentation.swift")
        self.assertIn("猫写真のウィジェットをひとつ。", onboarding)
        self.assertNotIn("猫写真のまどをひとつ。", onboarding)

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

        local_photo_surfaces = [
            "NekoWidget/Views/CatCandidateCurationView.swift",
            "NekoWidget/Views/GrowthAlbumView.swift",
            "NekoWidget/Views/LikedPhotosView.swift",
            "NekoWidget/Views/SettingsView.swift",
        ]
        for relative in local_photo_surfaces:
            value = source(relative)
            self.assertNotIn("まど、ウィジェット", value, relative)
            self.assertNotIn("まど・ウィジェット", value, relative)

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
        self.assertIn("新しいiPhoneで、以前のまどへ戻る", pairing)
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

    def test_device_change_ui_names_each_phone_and_one_primary_next_action(self) -> None:
        pairing = source("NekoWidget/Views/PairingView.swift")
        presentation = source("NekoWidget/Views/PairingPresentation.swift")

        for device_name in ["新しいiPhone", "以前のiPhone", "相手のiPhone"]:
            self.assertIn(device_name, pairing)
            self.assertIn(device_name, presentation)

        self.assertIn("DeviceChangeGuidancePresentation", pairing)
        self.assertIn("機種変更で使う3台", pairing)
        self.assertIn("今すること", pairing)
        self.assertIn("primaryActionLabel", pairing)
        self.assertIn(".buttonStyle(.borderedProminent)", pairing)
        self.assertIn("相手のiPhoneの機種変更を手伝う", pairing)
        self.assertIn("新しいiPhone用の復旧コードを作る", pairing)
        self.assertIn("新しいiPhoneへ復旧コードを送る", pairing)
        self.assertIn("新しいiPhoneを承認する", pairing)
        self.assertNotIn("相手側のiPhoneを置き換える", pairing)
        self.assertNotIn("相手側の新しいiPhoneへ置き換える", pairing)

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
        self.assertIn("更新しました。新しい写真はありません", family_model)
        self.assertNotIn("相手が見ました", family_model)
        self.assertNotIn("相手が受け取りました", family_model)

    def test_sent_ledger_separates_server_acceptance_from_device_arrival(self) -> None:
        store = source("Shared/Sharing/MomentSharingStore.swift")
        coordinator = source("NekoWidget/Services/MomentSharingCoordinator.swift")
        presentation = source("NekoWidget/Views/MomentSharingPresentation.swift")
        model = source("NekoWidget/ViewModels/MomentSharingViewModel.swift")
        family = source("NekoWidget/Views/FamilyWindowView.swift")

        self.assertIn("recipientDeliveryConfirmedAt", store)
        self.assertIn("markRecipientDeliveryConfirmed", store)
        self.assertIn('change.deliveryState == "acknowledged"', coordinator)
        self.assertIn("markRecipientDeliveryConfirmed", coordinator)
        self.assertIn("recipientDeliveryConfirmedAt: $0.recipientDeliveryConfirmedAt", model)
        self.assertIn("MomentSentRecordDeliveryState", presentation)
        self.assertIn("serverAccepted", presentation)
        self.assertIn("recipientDeviceArrivalConfirmed", presentation)
        self.assertIn("閲覧・既読の確認ではありません", presentation)
        self.assertIn("自分が届けた写真", family)
        self.assertIn("この一覧には画像を保存せず、送信結果だけを表示します", family)
        self.assertIn(
            "record.recipientDeliveryConfirmedAt ?? record.serverAcceptedAt",
            family,
        )

    def test_memory_action_has_visible_result_and_remains_available_during_sync(self) -> None:
        model = source("NekoWidget/ViewModels/MomentSharingViewModel.swift")
        family = source("NekoWidget/Views/FamilyWindowView.swift")

        self.assertIn("memoryActionMessage", model)
        self.assertIn("思い出に追加しました", model)
        self.assertIn("family-window-bookmark-result", family)
        self.assertIn('Label("思い出に追加済み", systemImage: "star.fill")', family)
        toggle = section(
            model,
            "func toggleSavedMemory(_ item: MomentInboxItem) async",
            "private func showMemoryActionMessage",
        )
        self.assertIn("guard !isPerformingAction, !isReportOnly", toggle)
        self.assertNotIn("guard !isWorking", toggle)
        bookmark_button = family.split(
            "Task { await model.toggleSavedMemory(item) }", 1
        )[1].split('accessibilityIdentifier("family-window-save-memory")', 1)[0]
        self.assertIn(".disabled(model.isPerformingAction)", bookmark_button)
        self.assertNotIn(".disabled(model.isWorking)", bookmark_button)

        for start, end in (
            ("func discardFailedOutbox() async", "func discardPendingOutbox() async"),
            ("func clearOutgoingOutcomes() async", "func imageURL(for item"),
        ):
            local_cleanup = section(model, start, end)
            self.assertIn("guard !isPerformingAction", local_cleanup)
            self.assertNotIn("guard !isWorking", local_cleanup)

    def test_family_window_puts_photos_and_actions_before_settings_and_details(self) -> None:
        family = source("NekoWidget/Views/FamilyWindowView.swift")
        paired = section(
            family,
            "private var pairedContent: some View",
            "@ViewBuilder\n    private var manualRefreshResult",
        )
        self.assertLess(paired.index('Text("届いた写真")'), paired.index("primaryActions"))
        self.assertLess(paired.index("primaryActions"), paired.index("sharingManagementLink"))
        self.assertLess(paired.index("sharingManagementLink"), paired.index("privacyDisclosure"))
        self.assertNotIn("statusCard", paired)
        self.assertNotIn("howToSendCard", paired)
        self.assertIn("family-window-send-guide", family)
        self.assertIn("family-window-widget-guide", family)
        self.assertIn("ウィジェットの表示設定", family)
        self.assertIn("ウィジェットを編集", family)
        privacy = section(
            family,
            "private var privacyDisclosure: some View",
            "private var trustLinks: some View",
        )
        self.assertIn("DisclosureGroup", privacy)

    def test_retryable_pairing_bootstrap_is_retried_after_data_protection(self) -> None:
        pairing_model = source("NekoWidget/ViewModels/PairingViewModel.swift")
        pairing_view = source("NekoWidget/Views/PairingView.swift")
        pairing_store = source("Shared/Sharing/PairingKeychainStore.swift")
        pairing_guard = source("NekoWidget/Services/PairingInstallationGuard.swift")
        lifecycle = source("Shared/Storage/AtomicJSON.swift")
        bootstrap = section(
            pairing_model,
            "func bootstrap() async",
            "/// Updates presentation metadata only.",
        )
        self.assertIn("guard !didBootstrap else", bootstrap)
        self.assertIn("if isBootstrapping", bootstrap)
        self.assertIn("PairingInstallationGuard.RetryableBootstrapError", bootstrap)
        self.assertIn("didBootstrap = false", bootstrap)
        self.assertIn("bootstrapRetryMessage", bootstrap)
        self.assertGreater(
            bootstrap.rindex("didBootstrap = true"),
            bootstrap.index("restoreInvitationCodeIfAvailable"),
        )
        self.assertIn("isRetryableBootstrapCompletionError", bootstrap)
        self.assertIn(
            "UIApplication.protectedDataDidBecomeAvailableNotification",
            pairing_view,
        )
        self.assertIn("UIApplication.didBecomeActiveNotification", pairing_view)
        pairing_decode = section(
            pairing_store,
            "private static func decodedStateWithNormalizedDiagnostics",
            "/// Physical cleanup is allowed only",
        )
        self.assertIn("data = try Data(contentsOf: url)", pairing_decode)
        self.assertNotIn("FileManager.default.fileExists", pairing_decode)
        self.assertIn("SharingFileReadFailureClassifier.disposition", pairing_decode)
        self.assertLess(pairing_decode.index("throw error"), pairing_decode.index("let decoder"))
        self.assertIn("throw LoadError.invalidState", pairing_decode)
        self.assertIn("readLocalMarkerForBootstrap()", pairing_guard)
        self.assertIn('"installation-marker-read-unavailable"', pairing_guard)
        marker_read = section(
            pairing_guard,
            "private static func readLocalMarker()",
            "private static func readLocalMarkerForBootstrap()",
        )
        self.assertIn("let data: Data", marker_read)
        self.assertIn("String(data: data, encoding: .utf8)", marker_read)
        self.assertNotIn("fileExists", marker_read)
        self.assertIn("SharingFileReadFailureClassifier.disposition", marker_read)
        epoch_read = section(
            lifecycle,
            "static func currentEpochWhileLocked() throws -> Int",
            "/// Repairs only bytes",
        )
        self.assertIn("let data: Data", epoch_read)
        self.assertIn("throw Error.unavailable", epoch_read)
        self.assertIn("throw Error.corrupted", epoch_read)
        self.assertNotIn("fileExists", epoch_read)
        self.assertIn("recoverCorruptedEpochWhileLocked", lifecycle)
        self.assertIn("lifecycle-state-recovered", pairing_guard)
        self.assertIn("bootstrapRetryRequested", pairing_model)
        self.assertIn("error is SharingSecureFile.Error", pairing_model)
        self.assertIn("case .stateUnavailable, .stateChanged:", pairing_model)
        self.assertIn("もう一度確認する", pairing_view)

        terminal_classifier = section(
            pairing_model,
            "private nonisolated static func serverConfirmsPairingIsGone",
            "#if DEBUG",
        )
        self.assertIn('status == 410 && code == "sharing_revoked"', terminal_classifier)
        self.assertNotIn("invalid_authentication", terminal_classifier)

    def test_report_window_closed_reset_keeps_report_route_provenance(self) -> None:
        coordinator = source("NekoWidget/Services/MomentSharingCoordinator.swift")
        synchronize = section(
            coordinator,
            "private func performSynchronization(trigger: String) async",
            "func synchronizationNotice()",
        )
        report_outbox = section(
            coordinator,
            "private func sendReportOutbox(",
            "private func finalizeCommittedReport(",
        )
        self.assertIn("BackgroundSynchronizationTermination", synchronize)
        self.assertNotIn("Self.isReportWindowClosed(error)", synchronize)
        self.assertIn("Self.isReportWindowClosed(error)", report_outbox)
        self.assertIn(".reportOnlyWindowClosed", report_outbox)
        self.assertIn("resetLocalPairing", report_outbox)

    def test_foreground_sync_reloads_an_open_window_without_network_loop(self) -> None:
        app_model = source("NekoWidget/ViewModels/AppViewModel.swift")
        family_model = source("NekoWidget/ViewModels/MomentSharingViewModel.swift")
        family_view = source("NekoWidget/Views/FamilyWindowView.swift")
        synchronize = section(
            app_model,
            "private func synchronizeMomentSharing(trigger: String) async",
            "func refreshFamilyWindowOutputs(trigger: String) async",
        )
        self.assertIn("UIApplication.shared.isProtectedDataAvailable", synchronize)
        self.assertIn('"protected-data-unavailable"', synchronize)
        self.assertLess(
            synchronize.index("isProtectedDataAvailable"),
            synchronize.index("momentSharingCoordinator.synchronize"),
        )
        refresh = section(
            app_model,
            "func refreshFamilyWindowOutputs(trigger: String) async",
            "private nonisolated static func familyWindowInputs",
        )
        self.assertIn("UIApplication.shared.isProtectedDataAvailable", refresh)
        self.assertLess(
            refresh.index("isProtectedDataAvailable"),
            refresh.index("PairingInstallationGuard.bootstrapAsync"),
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
            "struct MomentSavedMemoryMutation",
        )
        save = section(
            store,
            "static func setSavedMemory(",
            "/// Opaque relay cursors",
        )
        self.assertIn("static let schemaVersion = 7", store)
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
        self.assertIn("acknowledged.savedMemories == saved.savedMemories", saved_boundary)
        migration = section(
            runtime,
            "private static func testMomentOutcomeLedgerAndMigration()",
            "private static func testMomentCommitAcknowledgementMetadata()",
        )
        self.assertIn('schema5Object?["schemaVersion"] = 5', migration)
        self.assertIn('schema5Object?.removeValue(forKey: "savedMemories")', migration)
        self.assertIn("migratedSchema5.savedMemories.isEmpty", migration)

        family = source("NekoWidget/Views/FamilyWindowView.swift")
        self.assertIn('model.isSavedMemory(item) ? "思い出に追加済み" : "思い出に追加"', family)
        self.assertIn("写真の保持期限は変わりません", family)
        self.assertIn("期限は延びず、相手へ通知しません", family)
        self.assertIn("写真アプリへコピーした写真", family)
        self.assertIn("共有解除・ブロック・再インストールで写真と印は消えます", family)
        self.assertIn("最長90日", family)
        self.assertIn('case .memories: "思い出"', family)
        for legacy_received_list_copy in (
            "受信履歴",
            "共有履歴",
            "まどの履歴",
            "届いた写真の履歴",
        ):
            self.assertNotIn(legacy_received_list_copy, family)

        pairing = source("NekoWidget/Views/PairingView.swift")
        pairing_model = source("NekoWidget/ViewModels/PairingViewModel.swift")
        home = source("NekoWidget/Views/HomeView.swift")
        self.assertIn("相手と接続済み", pairing)
        self.assertNotIn("2人のまどを設定済み", pairing)
        self.assertIn("届いた写真・思い出", pairing)
        self.assertIn("届いた写真、思い出", pairing_model)
        self.assertIn("届いた写真を開きます", home)
        self.assertNotIn("届いた写真の履歴", home)


if __name__ == "__main__":
    unittest.main()
