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
    def test_handoff_purge_removes_legacy_quarantines(self) -> None:
        handoff = source("Shared/Sharing/MomentShareHandoffStore.swift")
        purge = section(
            handoff,
            "private static func purgeAllWhileLocked() throws",
            "private static func captureURL(for id: UUID) throws",
        )
        self.assertIn("momentShareHandoffLegacyQuarantineDirectoryURL", purge)
        self.assertIn("privateWindowLegacySharingQuarantineDirectoryURL", purge)
        self.assertIn("fileManager.removeItem(at: candidate)", purge)

        unlink = section(
            handoff,
            "static func revokeAdmissionWhileLifecycleLocked(",
            "static func writeReportOnlyHandoffMarkerWhileLifecycleLocked(",
        )
        self.assertIn(
            "purgeLegacyQuarantinesWhileLocked(localWindowID: localWindowID)",
            unlink,
        )
        scoped_purge = section(
            handoff,
            "private static func purgeLegacyQuarantinesWhileLocked(",
            "private static func captureURL(for id: UUID) throws",
        )
        self.assertIn("catalogWindowIDs.contains(canonicalWindowID)", scoped_purge)
        self.assertIn("catalogWindowIDs.contains(entry.lastPathComponent.lowercased())", scoped_purge)
        self.assertIn("handoffRoot.appendingPathComponent(", scoped_purge)
        self.assertIn("catalog.windows.first?.localWindowID.lowercased()", scoped_purge)
        self.assertNotIn("legacyQuarantineDirectories\n        where", scoped_purge)

    def test_family_window_reload_keeps_handoff_presentation_best_effort(self) -> None:
        model = source("NekoWidget/ViewModels/MomentSharingViewModel.swift")
        synchronize = section(
            model,
            "func synchronize(isManual: Bool = true) async",
            "func report(",
        )
        self.assertIn(
            "let synchronizationSucceeded = await coordinator.synchronize(",
            synchronize,
        )
        self.assertIn("else if !synchronizationSucceeded", synchronize)
        self.assertIn("preliminaryFailureMessage", synchronize)
        self.assertIn("manualRefreshSucceeded = synchronizationSucceeded", synchronize)

        reload_body = section(
            model,
            "private func reload(notifyPresentationChange: Bool = true) throws",
            "private func refreshOutgoingPresentation() async",
        )
        self.assertIn(
            "bestEffortHandoffPresentationSnapshot(configuration: configuration)",
            reload_body,
        )
        self.assertNotIn(
            "try MomentShareHandoffStore.presentationSnapshot()",
            reload_body,
        )

        fallback = section(
            model,
            "private nonisolated static func bestEffortHandoffPresentationSnapshot(",
            "private nonisolated static func makeOutgoingPresentation(",
        )
        self.assertIn("try MomentShareHandoffStore.presentationSnapshot()", fallback)
        self.assertIn("catch", fallback)
        self.assertIn(
            "MomentShareHandoffPresentationSnapshot(statuses: [], terminalOutcomes: [])",
            fallback,
        )
        self.assertIn("SharedLog.app.warning", fallback)
        self.assertIn("SharedLog.errorMetadata", fallback)

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
        self.assertIn("Link(destination: memoryActionURL)", view)
        self.assertNotIn("ToggleFamilyWidgetBookmarkIntent", view)
        self.assertIn('entry.isBookmarked ? "残した" : "残す"', view)
        self.assertIn('"photo.badge.plus"', view)
        self.assertIn('"checkmark.circle.fill"', view)
        self.assertIn('actionPill(', view)
        self.assertIn("写真アプリへの取り込みを確認するため、アプリを開きます", view)
        self.assertIn("SendFamilyWidgetHeartIntent", view)
        self.assertIn('systemImage: "heart"', view)
        self.assertIn('systemImage: "clock.fill"', view)
        self.assertIn('"ハート"', view)
        self.assertIn('"送信済み"', view)
        self.assertIn("ハートを送信待ちに追加", view)
        self.assertIn("ハートはサーバー受付済みです", view)
        self.assertNotIn("foregroundStyle(.pink)", view)

        deep_link = source("Shared/Routing/DeepLink.swift")
        self.assertIn('components.host = "family-window"', deep_link)
        entry = source("NekoWidgetWidget/NekoWidgetEntry.swift")
        self.assertIn(
            "return DeepLink.familyWindow(localWindowID: localWindowID)",
            entry,
        )
        self.assertIn("var memoryActionURL: URL?", entry)

    def test_family_widget_memory_link_requires_exact_window_and_photo(self) -> None:
        entry = source("NekoWidgetWidget/NekoWidgetEntry.swift")
        photo_url = section(entry, "var photoURL: URL?", "var memoryActionURL: URL?")
        family_branch = section(
            photo_url,
            "if WidgetPhotoSource.isFamilyWindowSourceID(photoSourceIdentifier)",
            "guard let localIdentifier",
        )
        self.assertIn("let localWindowID", family_branch)
        self.assertIn(
            "DeepLink.familyWindow(localWindowID: localWindowID)",
            family_branch,
        )
        self.assertIn("return DeepLink.familyWindow()", family_branch)
        self.assertNotIn("sourceDigest", family_branch)

        memory_action_url = section(entry, "var memoryActionURL: URL?", "\n    }\n}")
        self.assertIn(
            "WidgetPhotoSource.isFamilyWindowSourceID(photoSourceIdentifier)",
            memory_action_url,
        )
        self.assertIn("let localWindowID", memory_action_url)
        self.assertIn("let familySourceDigest", memory_action_url)
        self.assertIn("DeepLink.familyWindow(", memory_action_url)
        self.assertIn("localWindowID: localWindowID", memory_action_url)
        self.assertIn("sourceDigest: familySourceDigest", memory_action_url)
        self.assertNotIn("DeepLink.familyWindow()", memory_action_url)
        self.assertNotIn(
            "DeepLink.familyWindow(localWindowID: localWindowID)",
            memory_action_url,
        )

        widget_view = source("NekoWidgetWidget/NekoWidgetView.swift")
        self.assertIn("Link(destination: memoryActionURL)", widget_view)
        self.assertIn(".widgetURL(entry.photoURL)", widget_view)
        self.assertNotIn(".widgetURL(entry.memoryActionURL)", widget_view)

        deep_link = source("Shared/Routing/DeepLink.swift")
        serializer = section(
            deep_link,
            "var url: URL?",
            "static func photo(",
        )
        family_serializer = section(
            serializer,
            "case let .familyWindow(localWindowID, sourceDigest):",
            "return components.url",
        )
        self.assertIn(
            'URLQueryItem(name: "window", value: localWindowID)',
            family_serializer,
        )
        self.assertIn(
            'URLQueryItem(name: "source", value: sourceDigest)',
            family_serializer,
        )

        exact_link = section(
            deep_link,
            "static func familyWindow(localWindowID: String, sourceDigest: String)",
            "\n    init?(url: URL)",
        )
        self.assertIn("UUID(uuidString: localWindowID)", exact_link)
        self.assertIn("isLowercaseSHA256(sourceDigest)", exact_link)
        self.assertIn("localWindowID: localWindowID.lowercased()", exact_link)
        self.assertIn("sourceDigest: sourceDigest", exact_link)

        parser = section(deep_link, 'if host == "family-window"', 'guard host == "photo"')
        self.assertIn('$0.name == "window"', parser)
        self.assertIn('$0.name == "source"', parser)
        self.assertIn("sourceDigest == nil || localWindowID != nil", parser)
        self.assertIn("isLowercaseSHA256", parser)
        self.assertIn("sourceDigest: sourceDigest", parser)

        app_model = source("NekoWidget/ViewModels/AppViewModel.swift")
        self.assertIn(
            "@Published var pendingFamilyMomentSourceDigest: String?",
            app_model,
        )
        family_route = section(
            app_model,
            "case let .familyWindow(localWindowID, sourceDigest):",
            "return\n        }",
        )
        self.assertLess(
            family_route.index("activatePrivateWindowAsync"),
            family_route.index("pendingFamilyMomentSourceDigest = sourceDigest"),
        )
        self.assertLess(
            family_route.index("pendingFamilyMomentSourceDigest = sourceDigest"),
            family_route.index("isFamilyWindowPresented = true"),
        )

        app_root = source("NekoWidget/App/AppRootView.swift")
        self.assertIn(
            "deepLinkedFamilyMomentSourceDigest: "
            "$viewModel.pendingFamilyMomentSourceDigest",
            app_root,
        )
        main_tab = source("NekoWidget/Views/MainTabView.swift")
        self.assertIn(
            "@Binding var deepLinkedFamilyMomentSourceDigest: String?",
            main_tab,
        )
        self.assertIn(
            "pendingFamilyMomentSourceDigest: "
            "$deepLinkedFamilyMomentSourceDigest",
            main_tab,
        )
        home = source("NekoWidget/Views/HomeView.swift")
        self.assertIn(
            "@Binding var pendingFamilyMomentSourceDigest: String?",
            home,
        )
        self.assertIn(
            "pendingMemorySourceDigest: $pendingFamilyMomentSourceDigest",
            home,
        )

        family_view = source("NekoWidget/Views/FamilyWindowView.swift")
        self.assertIn("@Binding private var pendingMemorySourceDigest: String?", family_view)
        resolver = section(
            family_view,
            "private func consumePendingMemoryTargetIfReady()",
            "private func heartActionTitle(",
        )
        self.assertIn("WidgetCacheBuilder.retainedFamilyMomentID(", resolver)
        self.assertIn("forSourceDigest: sourceDigest", resolver)
        self.assertIn("localWindowID: activeWindow.localWindowID", resolver)
        self.assertIn("validating: bootstrap.lifecycleToken", resolver)
        self.assertIn("let catalog = try PrivateWindowCatalogStore.load()", resolver)
        catalog_read = section(
            resolver,
            "let activeWindow: PrivateWindowCatalogEntry",
            "let momentID: String?",
        )
        self.assertIn("catch {", catalog_read)
        self.assertIn("Keep the exact target", catalog_read)
        self.assertIn(
            "model.receivedMoments.first(where: { $0.id == momentID })",
            resolver,
        )
        self.assertGreater(
            resolver.index("pendingMemorySourceDigest = nil"),
            resolver.index("WidgetCacheBuilder.retainedFamilyMomentID("),
        )
        self.assertGreater(
            resolver.index("focusedMomentID = nil"),
            resolver.index("WidgetCacheBuilder.retainedFamilyMomentID("),
        )
        self.assertIn("showsStaleWidgetPhotoAlert = true", resolver)
        self.assertNotIn("didFinishBootstrap", family_view)
        self.assertIn(
            "PendingFamilyMemoryTargetPresentationPolicy.disposition(",
            resolver,
        )
        self.assertIn(
            "catch is PairingInstallationGuard.RetryableBootstrapError",
            resolver,
        )
        retryable_catch = section(
            resolver,
            "catch is PairingInstallationGuard.RetryableBootstrapError",
            "} catch {",
        )
        self.assertIn("return", retryable_catch)
        self.assertNotIn("rejectPendingMemoryTarget()", retryable_catch)
        self.assertIn("rejectPendingMemoryTarget()", resolver)
        rejection = section(
            family_view,
            "private func rejectPendingMemoryTarget()",
            "private func heartActionTitle(",
        )
        self.assertIn("pendingMemorySourceDigest = nil", rejection)
        self.assertIn("focusedMomentID = nil", rejection)
        self.assertIn("widgetMemoryTarget = nil", rejection)
        self.assertIn("showsStaleWidgetPhotoAlert = true", rejection)
        self.assertIn("widgetMemoryTarget = target", resolver)
        self.assertIn('alert("この写真は更新されました"', family_view)
        self.assertIn("ウィジェットの新しい写真で、もう一度お試しください。", family_view)
        self.assertIn('"この写真を思い出に残しますか？"', family_view)
        confirmation = section(
            family_view,
            '.confirmationDialog(\n            "この写真を思い出に残しますか？"',
            "private var pairedContent: some View",
        )
        self.assertIn("focusedMomentID = nil", confirmation)
        self.assertIn(
            "performMemoryAction(item, clearsWidgetFocusAfterCompletion: true)",
            confirmation,
        )

        presentation = source("NekoWidget/Views/PairingPresentation.swift")
        policy = section(
            presentation,
            "enum PendingFamilyMemoryTargetBootstrapPhase",
            "/// User-facing guidance",
        )
        self.assertIn("case checking", policy)
        self.assertIn("case temporarilyUnavailable", policy)
        self.assertIn("case ready", policy)
        self.assertIn("case .checking, .temporarilyUnavailable:", policy)
        self.assertIn("return .preserve", policy)
        self.assertIn("case .ready:", policy)
        self.assertIn("return .resolve", policy)

        cache_builder = source("NekoWidget/Services/WidgetCacheBuilder.swift")
        retained = section(
            cache_builder,
            "static func retainedFamilyMomentID(",
            "@discardableResult\n    func clearFamilyWindow(",
        )
        self.assertIn("isLowercaseFamilySourceDigest(sourceDigest)", retained)
        self.assertIn("familyWidgetManifestURL(", retained)
        self.assertIn("familyWidgetCacheHistoryURL(", retained)
        self.assertIn("history.generations.count <= maximumFamilyGenerationCount", retained)
        self.assertIn("Set(digests).count == digests.count", retained)
        self.assertIn("generation.generatedAt >= cutoff", retained)
        self.assertIn("generation.generatedAt <= futureLimit", retained)
        self.assertIn("currentManifestMomentID != nil || retainedByHistory", retained)
        self.assertIn("PrivateWindowCatalogStore.activeEntry()?.localWindowID", retained)
        self.assertIn("Self.familySourceDigest(for: $0) == sourceDigest", retained)
        self.assertIn("identityMatches.count == 1", retained)
        self.assertIn("Self.familySourceSnapshot(", retained)
        self.assertIn("snapshot.sourceDigest == sourceDigest", retained)

    def test_family_widget_memory_opens_app_for_explicit_photos_import(self) -> None:
        store = source("Shared/Sharing/MomentSharingStore.swift")
        imported = section(
            store,
            "static func completeMemoryImport(",
            "/// Removes only a stale mapping",
        )
        self.assertIn("mutate(validating: lifecycleToken)", imported)
        self.assertIn("state.importedMemories.append(candidate)", imported)
        self.assertIn("validateSavedMemoryTarget", imported)
        self.assertIn("state.savedMemories.removeAll", imported)
        self.assertNotIn("outbox", imported.lower())
        self.assertNotIn("URLSession", imported)

        intent = source("NekoWidgetWidget/ToggleWidgetLikeIntent.swift")
        family_intent = section(
            intent,
            "struct ToggleFamilyWidgetBookmarkIntent",
            "struct SendFamilyWidgetHeartIntent",
        )
        self.assertIn("static var isDiscoverable = false", family_intent)
        self.assertIn("static var openAppWhenRun = true", family_intent)
        self.assertIn("FamilyWidgetActionTargetResolver.momentID", family_intent)
        self.assertNotIn("MomentSharingStateStore.toggleSavedMemory", family_intent)
        self.assertNotIn("SharedLikeStore", family_intent)
        self.assertEqual(
            family_intent.count('reloadTimelines(ofKind: "NekoWidget")'),
            1,
        )
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
        self.assertEqual(
            heart_intent.count('reloadTimelines(ofKind: "NekoWidget")'),
            2,
        )
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
        self.assertIn('Text("ハートは相手へ・思い出は自分だけ")', family_view)
        self.assertIn('"photo.badge.plus"', family_view)
        self.assertIn('"checkmark.circle.fill"', family_view)
        self.assertIn('return canRetry ? "送信を再試行" : "送信できません"', family_view)
        self.assertIn("heart?.phase == .sent", family_view)
        self.assertNotIn("foregroundStyle(.pink)", family_view)
        self.assertIn('Label("ハートが届きました", systemImage: "heart.fill")', family_view)
        self.assertNotIn("family-window-received-paws", family_view)

        presentation = source("NekoWidget/Views/MomentSharingPresentation.swift")
        family_model = source("NekoWidget/ViewModels/MomentSharingViewModel.swift")
        self.assertIn("let hasReceivedHeart: Bool", presentation)
        self.assertIn("hasReceivedHeart: delivery.hasReceivedHeart", presentation)
        self.assertIn("sharingState.receivedPaws.map(\\.momentID)", family_model)
        self.assertIn("$0.serverMomentID.map", family_model)

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

    def test_received_memory_import_is_explicit_durable_and_lifecycle_validated(self) -> None:
        store = source("Shared/Sharing/MomentSharingStore.swift")
        payload = section(
            store,
            "static func photoLibraryCopyPayload(",
            "static func importedMemoryRecord(",
        )
        self.assertIn("withStateWhileLifecycleLocked", payload)
        self.assertIn("validateSavedMemoryTarget", payload)
        self.assertIn("MomentPhotoLibraryCopyPayload", payload)
        self.assertIn("item.receivedAt >= now.addingTimeInterval(-localHistorySeconds)", payload)

        service = source("NekoWidget/Services/PhotoAlbumService.swift")
        import_service = section(
            service,
            "final class ReceivedPhotoMemoryImportService",
            "\n}",
        )
        self.assertIn("@MainActor", service)
        self.assertIn("authorizationStatus(for: .readWrite)", import_service)
        self.assertIn("requestAuthorization(for: .readWrite)", import_service)
        self.assertIn("PHAssetCreationRequest.forAsset()", import_service)
        self.assertIn("request.addResource", import_service)
        self.assertIn("placeholderForCreatedAsset?.localIdentifier", import_service)
        self.assertIn("func assetVisibility(", import_service)
        self.assertIn("case confirmedMissing", service)
        self.assertIn("case unknown", service)
        self.assertIn("func recoverImportedAsset(importToken: UUID)", import_service)
        self.assertIn("PHAssetResource.assetResources(for: asset)", import_service)
        self.assertIn("options.originalFilename = originalFilename", import_service)

        model = source("NekoWidget/ViewModels/MomentSharingViewModel.swift")
        import_action = section(
            model,
            "func toggleSavedMemory(_ item: MomentInboxItem) async",
            "private func notifyPersonalMemoriesChanged",
        )
        self.assertIn("MomentSharingStateStore.importedMemoryRecord", import_action)
        self.assertIn("copyService.requestMemoryImportAuthorization()", import_action)
        self.assertIn("MomentSharingStateStore.prepareMemoryImport", import_action)
        self.assertIn("MomentSharingStateStore.photoLibraryCopyPayload", import_action)
        self.assertIn("copyService.recoverImportedAsset", import_action)
        self.assertIn("copyService.importMemory(", import_action)
        self.assertIn("MomentSharingStateStore.completeMemoryImport", import_action)
        self.assertIn('source: "received-memory"', import_action)
        self.assertLess(
            import_action.index("requestMemoryImportAuthorization"),
            import_action.index("prepareMemoryImport"),
        )
        self.assertLess(
            import_action.index("prepareMemoryImport"),
            import_action.index("copyService.importMemory("),
        )
        self.assertLess(
            import_action.index('source: "received-memory"'),
            import_action.index("completeMemoryImport"),
        )

        family = source("NekoWidget/Views/FamilyWindowView.swift")
        self.assertNotIn('"写真アプリへコピーしますか？"', family)
        self.assertNotIn("photoCopyTarget", family)
        self.assertIn("通常の思い出と写真まとめに入り", family)
        self.assertIn("アプリ削除のあとも写真アプリに残ります", family)

        heart_action = section(
            model,
            "func sendHeart(_ item: MomentInboxItem) async",
            "func toggleSavedMemory(_ item: MomentInboxItem) async",
        )
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
        self.assertNotIn("family-widget-v3", builder)
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
        self.assertIn("WidgetPhotoSource.isFamilyWindowSourceID(identifier)", source_switch)
        self.assertIn("WidgetPhotoSource.localWindowID(from: identifier)", source_switch)
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
        self.assertIn("familyWindowDisplayName(", provider)
        self.assertIn("localWindowID: localWindowID", provider)
        self.assertIn("let windowDisplayName: String", entry)
        self.assertIn("entry.windowDisplayName", widget_view)
        self.assertIn('static let familyWindowID = "family-window"', configuration)
        self.assertIn('static let personalLibraryID = "personal-library"', configuration)
        self.assertIn('name: "このiPhoneの猫写真"', configuration)
        self.assertIn("PrivateWindowCatalogStore.widgetEntries()", configuration)
        self.assertIn("familyWindowIDPrefix + entry.localWindowID", configuration)
        self.assertNotIn("WidgetManifestReader", configuration)

    def test_legacy_family_widget_stays_bound_to_migrated_first_window(self) -> None:
        configuration = source("NekoWidgetWidget/NekoWidgetConfigurationIntent.swift")
        legacy_resolution = section(
            configuration,
            "static func localWindowID(from sourceID: String)",
            "static func resolvedSource(id: String)",
        )
        self.assertIn(
            "PrivateWindowCatalogStore.legacyWidgetEntry()?.localWindowID",
            legacy_resolution,
        )
        self.assertNotIn(
            "PrivateWindowCatalogStore.activeEntry()",
            legacy_resolution,
        )

        container = source("Shared/AppGroup/SharedContainer.swift")
        legacy_entry = section(
            container,
            "static func legacyWidgetEntry()",
            "static func widgetEntries()",
        )
        self.assertIn("return state.windows.first", legacy_entry)
        self.assertNotIn("activeWindowID", legacy_entry)

        provider = source("NekoWidgetWidget/NekoWidgetTimelineProvider.swift")
        interaction = section(
            provider,
            "private func familyInteractionState(",
            "private func availableItems(",
        )
        self.assertIn(
            "let boundWindowID = WidgetPhotoSource.localWindowID",
            interaction,
        )
        self.assertIn(
            "PrivateWindowCatalogStore.activeEntry()?.localWindowID",
            interaction,
        )
        self.assertIn(
            "guard photoSourceIdentifier == WidgetPhotoSource.familyWindowID",
            interaction,
        )

    def test_private_window_catalog_migration_is_resumable_and_fail_closed(self) -> None:
        container = source("Shared/AppGroup/SharedContainer.swift")
        catalog = section(
            container,
            "enum PrivateWindowCatalogStore",
            "enum SharedContainer",
        )
        self.assertIn("pendingLegacyMigrationWindowID", catalog)
        self.assertIn("try saveWhileLifecycleLocked(state)", catalog)
        self.assertIn("try resumeLegacyMigrationIfNeeded(&state)", catalog)
        self.assertLess(
            catalog.index("try saveWhileLifecycleLocked(state)"),
            catalog.index("try resumeLegacyMigrationIfNeeded(&state)"),
        )
        self.assertIn("fileManager.moveItem(at: legacy, to: destination)", catalog)
        self.assertIn("throw Error.conflictingLegacyMigration", catalog)
        quarantine = section(
            catalog,
            "private static func quarantineReappearedLegacySharingIfNeeded(",
            "private static func saveWhileLifecycleLocked(",
        )
        self.assertIn("state.windows.first?.localWindowID", quarantine)
        self.assertIn("LegacyPairingIdentity", quarantine)
        self.assertIn("legacyEntriesAreReplaceable", quarantine)
        self.assertIn("fileManager.moveItem(at: legacy, to: quarantine)", quarantine)
        self.assertNotIn("fileManager.removeItem", quarantine)
        handoff_store = source("Shared/Sharing/MomentShareHandoffStore.swift")
        handoff_migration = section(
            handoff_store,
            "private static func prepareMultiWindowStorageWhileLocked()",
            "private static func boundedData(",
        )
        self.assertIn(
            "legacyMomentShareHandoffDirectoryIsSafelyQuarantinable",
            handoff_migration,
        )
        self.assertIn(
            "quarantineLegacyHandoffSourcesWhileLocked(sources)",
            handoff_migration,
        )
        self.assertIn("windowUUID.uuidString.lowercased()", handoff_migration)
        self.assertIn("fileManager.moveItem(at: source.url, to: quarantine)", handoff_migration)
        self.assertNotIn("fileManager.removeItem", handoff_migration)
        self.assertIn("Set(windows.map(\\.localWindowID)).count", container)
        self.assertIn("Set(pairedSpaceIDs).count == pairedSpaceIDs.count", container)
        self.assertIn(
            "Set(credentialAccounts).count == credentialAccounts.count",
            container,
        )
        self.assertIn("maximumWindowCount = 20", container)

        resolution = section(
            container,
            "static func sharingCacheDirectoryURL(localWindowID: String?)",
            "static var sharingControlDirectoryURL",
        )
        self.assertIn("fileExists(atPath: catalogURL.path)", resolution)
        self.assertIn("return nil", resolution)
        self.assertIn("pendingLegacyMigrationWindowID == catalog.activeWindowID", resolution)

        pairing_store = source("Shared/Sharing/PairingKeychainStore.swift")
        scoped_load = section(
            pairing_store,
            "static func load(localWindowID: String)",
            "private static func decodedStateWithNormalizedDiagnostics()",
        )
        self.assertIn("windowSharingDirectoryURL", scoped_load)
        self.assertNotIn("sharingCacheDirectoryURL", scoped_load)

        guard = source("NekoWidget/Services/PairingInstallationGuard.swift")
        cleanup = section(
            guard,
            "private static func performCleanupWhileLocked",
            "private static func markerURL",
        )
        self.assertIn("deleteAllSharingCredentials()", cleanup)
        self.assertIn("PairingKeychainStore.delete(account: activeCredentialAccount)", cleanup)
        self.assertIn("resetAllWhileLifecycleLocked()", cleanup)
        self.assertIn("writeWindowCleanupScopeWhileLocked", cleanup)
        self.assertIn("revokeAdmissionWhileLifecycleLocked", cleanup)
        self.assertIn("deleteWindowCleanupScopeWhileLocked", cleanup)
        self.assertIn("catch PairingStateStore.LoadError.invalidState", cleanup)
        self.assertIn("?? scopedEntry?.credentialAccount", cleanup)
        self.assertIn("let activeWindowID = scopedEntry?.localWindowID", cleanup)

        create_window = section(
            guard,
            "static func createAndActivatePrivateWindow()",
            "static func createAndActivatePrivateWindowAsync()",
        )
        self.assertLess(
            create_window.index(
                "finishPendingCleanupBeforeWindowSelectionWhileLocked()"
            ),
            create_window.index(
                "PrivateWindowCatalogStore.createAndActivateWhileLifecycleLocked()"
            ),
        )
        activate_window = section(
            guard,
            "static func activatePrivateWindow(localWindowID: String)",
            "static func activatePrivateWindowAsync(",
        )
        self.assertLess(
            activate_window.index(
                "finishPendingCleanupBeforeWindowSelectionWhileLocked()"
            ),
            activate_window.index(
                "PrivateWindowCatalogStore.activateWhileLifecycleLocked("
            ),
        )

        initial_commit = section(
            pairing_store,
            "static func saveInitialCredentialAndState(",
            "private static func saveCASWhileLifecycleLocked(",
        )
        self.assertIn("activeEntry.credentialAccount", initial_commit)
        self.assertIn("previousCandidate != credential.account", initial_commit)
        self.assertLess(
            initial_commit.index(
                "loadWhileLifecycleLockedMigratingDiagnostics() == expected"
            ),
            initial_commit.index(
                "PrivateWindowCatalogStore.updateActiveMetadataWhileLifecycleLocked("
            ),
        )
        self.assertLess(
            initial_commit.index(
                "PrivateWindowCatalogStore.updateActiveMetadataWhileLifecycleLocked("
            ),
            initial_commit.index(
                "PairingKeychainStore.saveWhileLifecycleLocked(credential)"
            ),
        )
        self.assertIn("current == expected", initial_commit)
        self.assertIn(
            "PairingKeychainStore.delete(account: credential.account)",
            initial_commit,
        )
        bootstrap = section(
            guard,
            "private static func bootstrapWhileLocked()",
            "/// Pure failure classification.",
        )
        self.assertIn("state.phase == .unpaired", bootstrap)
        self.assertIn("activeEntry.credentialAccount", bootstrap)
        self.assertIn(
            "PairingKeychainStore.delete(account: candidateAccount)",
            bootstrap,
        )
        self.assertIn("credentialAccount: nil", bootstrap)
        self.assertNotIn("deleteAllSharingCredentials()", bootstrap)
        self.assertIn("catalog.windows.contains(where:", bootstrap)
        self.assertIn(
            "catalog.activeWindowID != cleanupScope.localWindowID",
            bootstrap,
        )
        self.assertIn(
            "localWindowID: cleanupScope.localWindowID",
            bootstrap,
        )

        pending_cleanup = section(
            guard,
            "private static func finishPendingCleanupBeforeWindowSelectionWhileLocked()",
            "/// Pure failure classification.",
        )
        self.assertIn(
            "SharingLifecycleGate.cleanupRequiredWhileLocked()",
            pending_cleanup,
        )
        self.assertIn("_ = try bootstrapWhileLocked()", pending_cleanup)

        processor = source("NekoWidget/Services/MomentShareHandoffProcessor.swift")
        self.assertIn("displayName: entry.displayName", processor)
        self.assertIn(
            "senderDeviceID: localMomentDeviceID",
            processor,
        )
        self.assertIn("refreshAdmissionCatalog(", processor)
        self.assertIn("localWindowID: entry.localWindowID", processor)

        handoff = source("Shared/Sharing/MomentShareHandoffStore.swift")
        self.assertIn("let localWindowID: String?", handoff)
        self.assertIn("prepareMultiWindowStorageWhileLocked()", handoff)
        self.assertIn("revokeAdmissionWhileLifecycleLocked(", handoff)
        self.assertIn("sources.count <= 1", handoff)
        active_admissions = section(
            handoff,
            "static func activeAdmissions(now: Date = .now)",
            "static func presentationSnapshot(",
        )
        self.assertIn("$0.localWindowID == windowCatalog.activeWindowID", active_admissions)
        self.assertIn("windowCatalog.windows.count == 1", active_admissions)
        self.assertIn("guard eligible.count <= 1", active_admissions)
        self.assertIn(
            'privateWindowsDirectoryURL?.appendingPathComponent(\n            "moment-handoff.v2"',
            container,
        )

        share_view = source("NekoWidgetShareExtension/ShareViewController.swift")
        self.assertNotIn("configureDestinationPicker(admissions)", share_view)
        self.assertIn("現在アプリで開いているまどへ一時保存します", share_view)
        self.assertIn("届けたいまどを開いてください", share_view)
        self.assertIn("selectedAdmission = nil", share_view)
        self.assertIn("continueButton.isEnabled = false", share_view)

        pairing_store = source("Shared/Sharing/PairingKeychainStore.swift")
        self.assertIn(
            "value.localMomentDeviceID != originalLocalMomentDeviceID",
            pairing_store,
        )

        pairing_view_model = source("NekoWidget/ViewModels/PairingViewModel.swift")
        coordinator = source("NekoWidget/Services/MomentSharingCoordinator.swift")
        finish_recovery = section(
            pairing_view_model,
            "private func finishLocalDeviceRecovery(",
            "private func validateDeviceRecoveryStatus(",
        )
        self.assertIn(
            "current.localMomentDeviceID = recoveredDeviceID",
            finish_recovery,
        )
        self.assertIn("current.localDeviceIsAdditional = true", finish_recovery)
        self.assertIn(
            "current.canonicalParticipantSigningPublicKey =",
            finish_recovery,
        )
        self.assertIn(
            "pairing.canonicalParticipantSigningPublicKey",
            coordinator,
        )
        pairing_core = source("Shared/Sharing/PairingCore.swift")
        paired_validation = section(
            pairing_core,
            "case .paired:",
            "case .failed:",
        )
        self.assertIn("localDeviceIsAdditional == true", paired_validation)
        self.assertIn("localMomentDeviceID != memberID", paired_validation)
        self.assertIn(
            "canonicalParticipantSigningPublicKey != nil",
            paired_validation,
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
        self.assertIn(
            "state.spaceID != nil, !model.canEditWindowDisplayName",
            pairing_view,
        )
        self.assertIn("追加したiPhoneでは名前を変更できません", pairing_view)
        self.assertIn("最初のiPhoneで変更", pairing_view)
        window_name_service = (
            ROOT / "SharingService" / "src" / "window-name.ts"
        ).read_text(encoding="utf-8")
        self.assertIn("actor.is_primary_device !== 1", window_name_service)
        self.assertIn("primary_owner_device_required", window_name_service)
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
        self.assertIn("handoffProcessor.refreshAdmissionCatalog(", no_consent)
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

    def test_multi_window_scope_and_remaining_boundaries_are_documented(self) -> None:
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
        self.assertIn("段階4の実装契約", adr)
        self.assertIn("1台につき最大20の独立したまど", adr)
        self.assertIn("作成者と、信頼できる招待相手1人の合計2人", adr)
        self.assertIn("iPhoneを最大4台", adr)
        self.assertIn("非activeまどの通知起点バックグラウンド同期は未実装", adr)

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
        self.assertIn("別のiPhoneをこのまどに追加", pairing)
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

        for device_name in ["追加するiPhone", "すでに使っているiPhone", "相手のiPhone"]:
            self.assertIn(device_name, pairing)
            self.assertIn(device_name, presentation)

        self.assertIn("DeviceChangeGuidancePresentation", pairing)
        self.assertIn("追加に関係するiPhone", pairing)
        self.assertIn("今すること", pairing)
        self.assertIn("primaryActionLabel", pairing)
        self.assertIn(".buttonStyle(.borderedProminent)", pairing)
        self.assertIn("相手の別のiPhoneを追加", pairing)
        self.assertIn("iPhone追加コードを作る", pairing)
        self.assertIn("追加するiPhoneへコードを送る", pairing)
        self.assertIn("このiPhoneの追加を承認", pairing)
        self.assertIn("すでに使っているiPhoneは解除されません", presentation)
        self.assertNotIn("相手側のiPhoneを置き換える", pairing)
        self.assertNotIn("相手側の新しいiPhoneへ置き換える", pairing)

    def test_additional_owner_device_cannot_sponsor_an_invitee_enrollment(self) -> None:
        pairing = source("NekoWidget/Views/PairingView.swift")
        pairing_model = source("NekoWidget/ViewModels/PairingViewModel.swift")
        eligibility = section(
            pairing_model,
            "var canCreateDeviceRecoveryInvitation: Bool",
            "@discardableResult",
        )
        create_recovery = section(
            pairing_model,
            "func createDeviceRecoveryInvitation() async",
            "func joinDeviceRecovery() async",
        )
        self.assertIn("state.role != .inviter", eligibility)
        self.assertIn("state.localDeviceIsAdditional != true", eligibility)
        self.assertIn("guard canCreateDeviceRecoveryInvitation", create_recovery)
        self.assertIn("まどを最初に作ったiPhone", create_recovery)
        self.assertIn("model.canCreateDeviceRecoveryInvitation", pairing)
        self.assertIn("追加コードは最初のiPhoneで作れます", pairing)

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
        self.assertIn("思い出に残しました", model)
        self.assertIn("family-window-bookmark-result", family)
        self.assertIn('Label("思い出に残した", systemImage: "checkmark.circle.fill")', family)
        toggle = section(
            model,
            "func toggleSavedMemory(_ item: MomentInboxItem) async",
            "private func showMemoryActionMessage",
        )
        self.assertIn("guard !isPerformingAction, !isReportOnly", toggle)
        self.assertNotIn("guard !isWorking", toggle)
        moment_card = section(
            family,
            "private func momentCard(",
            "private func performMemoryAction(",
        )
        bookmark_button = section(
            moment_card,
            "Button {\n                        performMemoryAction(item)",
            'accessibilityIdentifier("family-window-save-memory")',
        )
        self.assertIn(".disabled(model.isPerformingAction)", bookmark_button)
        self.assertNotIn(".disabled(model.isWorking)", bookmark_button)

        for start, end in (
            ("func discardFailedOutbox() async", "func discardPendingOutbox() async"),
            ("func clearOutgoingOutcomes() async", "func imageURL(for item"),
        ):
            local_cleanup = section(model, start, end)
            self.assertIn("guard !isPerformingAction", local_cleanup)
            self.assertNotIn("guard !isWorking", local_cleanup)

    def test_family_window_separates_received_sent_and_settings(self) -> None:
        family = source("NekoWidget/Views/FamilyWindowView.swift")
        paired = section(
            family,
            "private var pairedContent: some View",
            "@ViewBuilder\n    private var receivedSectionContent",
        )
        self.assertIn('Picker("まどに表示する内容"', paired)
        self.assertIn("receivedSectionContent", paired)
        self.assertIn("sentSectionContent", paired)
        self.assertIn("sendPhotoAction", paired)
        self.assertNotIn("sharingManagementLink", paired)
        settings = section(
            family,
            "private var windowSettingsContent: some View",
            "private var notificationSettingsCard: some View",
        )
        self.assertIn("sharingManagementLink", settings)
        self.assertIn("notificationSettingsCard", settings)
        self.assertIn("privacyDisclosure", settings)
        self.assertNotIn("statusCard", paired)
        self.assertNotIn("howToSendCard", paired)
        self.assertIn("family-window-send-guide", family)
        self.assertIn("family-window-widget-guide", family)
        self.assertIn("ウィジェットの表示", family)
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

    def test_received_memory_import_joins_the_permanent_personal_collection(self) -> None:
        store = source("Shared/Sharing/MomentSharingStore.swift")
        record = section(
            store,
            "struct MomentImportedMemoryRecord",
            "/// One fail-closed snapshot",
        )
        import_mapping = section(
            store,
            "static func completeMemoryImport(",
            "/// Removes only a stale mapping",
        )
        self.assertIn("static let schemaVersion = 9", store)
        self.assertIn("momentID", record)
        self.assertIn("photoLocalIdentifier", record)
        self.assertIn("importedAt", record)
        self.assertNotIn("participant", record.lower())
        self.assertIn("validateSavedMemoryTarget", import_mapping)
        self.assertIn("state.importedMemories.append(candidate)", import_mapping)
        self.assertIn("existing.photoLocalIdentifier == photoLocalIdentifier", import_mapping)
        self.assertIn("state.savedMemories.removeAll", import_mapping)
        self.assertIn("state.importedMemories.removeAll", store)
        self.assertIn("struct MomentPendingMemoryImportRecord", store)
        self.assertIn("static func prepareMemoryImport(", store)
        self.assertIn("static func completeMemoryImport(", store)
        self.assertIn("state.pendingMemoryImports.append(candidate)", store)
        self.assertIn("$0.importToken == importToken", store)

        likes = source("Shared/Storage/SharedLikeStore.swift")
        self.assertIn("var isReceivedMemoryImport: Bool? = nil", likes)
        self.assertIn('source == "received-memory"', likes)
        self.assertIn("static func ensureInitialized", likes)
        self.assertIn("mergeLegacyLikes([], at: date)", likes)

        sharing_model = source("NekoWidget/ViewModels/MomentSharingViewModel.swift")
        import_action = section(
            sharing_model,
            "func toggleSavedMemory(",
            "private func notifyPersonalMemoriesChanged",
        )
        self.assertIn("SharedLikeStore.ensureInitialized()", import_action)
        self.assertLess(
            import_action.index("SharedLikeStore.ensureInitialized()"),
            import_action.index("copyService.importMemory("),
        )

        runtime = source("NekoWidget/Services/SharingRuntimeSelfTest.swift")
        imported_boundary = section(
            runtime,
            "private static func testMomentImportedMemoryBoundary()",
            "private static func testMomentSentDeliveryReceiptBoundary()",
        )
        self.assertIn("prepareMemoryImport", imported_boundary)
        self.assertIn("completeMemoryImport", imported_boundary)
        self.assertIn("imported.importedMemories ==", imported_boundary)
        self.assertIn("imported.pendingMemoryImports.isEmpty", imported_boundary)
        self.assertIn("photos-imported-memory-fixture/L0/duplicate", imported_boundary)
        self.assertIn("revoked.state = .revoked", imported_boundary)
        self.assertIn("importedMemories.isEmpty", imported_boundary)
        migration = section(
            runtime,
            "private static func testMomentOutcomeLedgerAndMigration()",
            "private static func testMomentCommitAcknowledgementMetadata()",
        )
        self.assertIn('schema7Object?["schemaVersion"] = 7', migration)
        self.assertIn('schema7Object?.removeValue(forKey: "importedMemories")', migration)
        self.assertIn("migratedSchema7.importedMemories.isEmpty", migration)
        self.assertIn('schema8Object?["schemaVersion"] = 8', migration)
        self.assertIn('schema8Object?.removeValue(forKey: "pendingMemoryImports")', migration)
        self.assertIn("migratedSchema8.pendingMemoryImports.isEmpty", migration)

        family = source("NekoWidget/Views/FamilyWindowView.swift")
        self.assertIn('model.isSavedMemory(item) ? "思い出に残した" : "思い出に残す"', family)
        self.assertIn("通常の思い出と写真まとめに入り", family)
        self.assertIn("相手へは通知しません", family)
        self.assertIn("アプリ削除のあとも写真アプリに残ります", family)
        self.assertNotIn('Label("写真アプリへコピー"', family)
        self.assertIn('case .memories: "残した写真"', family)

        app_model = source("NekoWidget/ViewModels/AppViewModel.swift")
        app_root = source("NekoWidget/App/AppRootView.swift")
        self.assertIn("receivedMemoryImportNeedsRefresh", app_model)
        self.assertIn("isReceivedMemoryImport == true", app_model)
        self.assertIn("currentlyVisibleImportIdentifiers", app_model)
        self.assertIn(
            "currentlyVisibleImportIdentifiers.contains($0.localIdentifier)",
            app_model,
        )
        self.assertIn("canConcludeImportedAssetWasDeleted", app_model)
        self.assertIn("PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized", app_model)
        self.assertIn('source: "received-memory-deleted"', app_model)
        self.assertIn("snapshot.likedAssets", app_model)
        self.assertIn("likedPhotos = sourceSnapshot.assets.compactMap", app_root)
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
        self.assertIn("一時的な届いた写真", pairing)
        self.assertIn("写真アプリへ保存した思い出は残ります", pairing_model)
        self.assertIn("届いた写真を開きます", home)
        self.assertNotIn("届いた写真の履歴", home)

    def test_temporary_pairing_storage_failure_has_one_retry_path(self) -> None:
        sharing_model = source("NekoWidget/ViewModels/MomentSharingViewModel.swift")
        bootstrap = section(
            sharing_model,
            "func bootstrap() async",
            "func retryBootstrap() async",
        )
        self.assertIn("bootstrapPresentationState = .ready", bootstrap)
        self.assertIn(
            "bootstrapPresentationState = .temporarilyUnavailable(message: message)",
            bootstrap,
        )

        family = source("NekoWidget/Views/FamilyWindowView.swift")
        base = section(
            family,
            "private var baseContent: some View",
            "private func temporarilyUnavailableContent",
        )
        self.assertIn("switch model.bootstrapPresentationState", base)
        self.assertIn("case let .temporarilyUnavailable(message):", base)
        self.assertLess(
            base.index("case let .temporarilyUnavailable(message):"),
            base.index("if !model.isPaired"),
        )
        unavailable = section(
            family,
            "private func temporarilyUnavailableContent",
            "private var consentRequiredContent",
        )
        self.assertEqual(unavailable.count("Button("), 1)
        self.assertIn("await model.retryBootstrap()", unavailable)
        self.assertNotIn("PairingView()", unavailable)

        pairing = source("NekoWidget/Views/PairingView.swift")
        pairing_model = source("NekoWidget/ViewModels/PairingViewModel.swift")
        pairing_bootstrap = section(
            pairing_model,
            "func bootstrap() async",
            "/// Updates presentation metadata only.",
        )
        self.assertGreater(
            pairing_bootstrap.index("bootstrapRetryMessage = nil"),
            pairing_bootstrap.index("restoreRecoveryInvitationCodeIfAvailable"),
        )
        body = section(pairing, "var body: some View", "private func temporarilyUnavailableSection")
        self.assertLess(
            body.index("if let retryMessage = model.bootstrapRetryMessage"),
            body.index("pairingContent(state)"),
        )
        retry_section = section(
            pairing,
            "private func temporarilyUnavailableSection",
            "private var buildIdentitySection",
        )
        self.assertEqual(retry_section.count("Button("), 1)
        self.assertIn("await model.bootstrap()", retry_section)
        self.assertIn("if model.isBootstrapping", retry_section)
        self.assertIn("接続情報を確認しています…", retry_section)
        self.assertNotIn("setupChoiceSection", retry_section)

    def test_paired_consent_renewal_and_dynamic_build_identity_are_explicit(self) -> None:
        family = source("NekoWidget/Views/FamilyWindowView.swift")
        base = section(
            family,
            "private var baseContent: some View",
            "private func temporarilyUnavailableContent",
        )
        self.assertIn("if !model.isPaired", base)
        self.assertIn("else if !model.hasCurrentMediaSharingConsent", base)
        self.assertIn("consentRequiredContent", base)
        consent = section(
            family,
            "private var consentRequiredContent",
            "private var buildIdentityText",
        )
        self.assertIn("PairingAvailabilityPresentation.consentRequired", consent)
        self.assertIn('Label("共有の同意を更新"', consent)
        self.assertIn("PairingView()", consent)

        presentation = source("NekoWidget/Views/PairingPresentation.swift")
        self.assertIn('forInfoDictionaryKey: "CFBundleShortVersionString"', presentation)
        self.assertIn('forInfoDictionaryKey: "CFBundleVersion"', presentation)
        self.assertIn('return "バージョン \\(resolvedVersion)（Build \\(resolvedBuild)）"', presentation)

        pairing = source("NekoWidget/Views/PairingView.swift")
        build = section(
            pairing,
            "private var buildIdentitySection",
            "private var pairingOnlyBuildSection",
        )
        self.assertIn("PairingBuildPresentation.currentText", build)
        self.assertIn('accessibilityIdentifier("pairing-build-identity")', build)


if __name__ == "__main__":
    unittest.main()
