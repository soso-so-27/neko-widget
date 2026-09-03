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
        self.assertIn("if isShowingLastKnownState", synchronize)
        self.assertIn("await retryBootstrap()", synchronize)

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
        self.assertNotIn('entry.isBookmarked ? "残した" : "残す"', view)
        self.assertIn('isSelected ? "bookmark.fill" : "bookmark"', view)
        self.assertIn('private func memoryMark(', view)
        self.assertIn('.frame(width: 44, height: 44)', view)
        self.assertNotIn('title: "残す"', view)
        self.assertNotIn('title: "取り込む"', view)
        self.assertNotIn('title: "残した"', view)
        self.assertIn('if entry.isBookmarked {', view)
        self.assertIn('if entry.isLiked {', view)
        self.assertIn('fallbackIsLiked: false', view)
        self.assertNotIn('entry.isLiked ? "思い出から外す"', view)
        self.assertIn('directActionLabel(', view)
        self.assertIn('statusBadge(', view)
        self.assertIn('accessibilityLabel("写真アプリに取り込んで残す")', view)
        self.assertIn("写真アプリへの取り込みを確認するため、アプリを開きます", view)
        self.assertIn("SendFamilyWidgetHeartIntent", view)

        photo_actions = section(
            view,
            "private var photoActionButtons: some View",
            "@ViewBuilder\n    private var familyMemoryControl",
        )
        family_actions = photo_actions.split(
            "if family == .systemSmall {", 1
        )[1]
        small_actions, larger_actions = family_actions.split("} else {", 1)
        self.assertIn("familyHeartControl(sourceDigest: sourceDigest)", small_actions)
        self.assertNotIn("familyMemoryControl", small_actions)
        self.assertIn("familyMemoryControl", larger_actions)
        self.assertIn("familyHeartControl(sourceDigest: sourceDigest)", larger_actions)

        action_tray = section(
            view,
            "private func actionTray<Content: View>(",
            "private func directActionLabel(",
        )
        self.assertIn("Spacer(minLength: 0)", action_tray)
        self.assertNotIn("LinearGradient(", action_tray)
        self.assertNotIn(".frame(height: 54)", action_tray)

        intent = source("NekoWidgetWidget/ToggleWidgetLikeIntent.swift")
        personal_intent = section(
            intent,
            "struct ToggleWidgetLikeIntent",
            "struct ToggleFamilyWidgetBookmarkIntent",
        )
        self.assertIn("SharedLikeStore.set(", personal_intent)
        self.assertIn("isLiked: true", personal_intent)
        self.assertNotIn("SharedLikeStore.toggle(", personal_intent)
        self.assertIn('systemImage: "heart"', view)
        self.assertIn('title: "ハート"', view)
        self.assertIn('title: "待機中"', view)
        self.assertIn('title: "受付済み"', view)
        self.assertNotIn('title: "送る"', view)
        self.assertNotIn('title: "送った"', view)
        self.assertIn("このiPhoneで送信待ちにし、アプリの同期後に送ります", view)
        self.assertIn("相手が確認したことを示す表示ではありません", view)
        self.assertNotIn("foregroundStyle(.pink)", view)
        self.assertNotIn("Color.accentColor.opacity(0.92)", view)
        self.assertIn("private enum WidgetStatusBadgeStyle", view)
        self.assertIn("case pending", view)
        self.assertIn("case completed", view)
        self.assertIn("actionButtonSpacing", view)

        direct_action = section(
            view,
            "private func directActionLabel(",
            "private func statusBadge(",
        )
        self.assertIn("Capsule()", direct_action)
        self.assertIn(".frame(minHeight: 44)", direct_action)
        self.assertIn(".contentShape(Rectangle())", direct_action)
        self.assertNotIn("RoundedRectangle", direct_action)

        status_badge = section(
            view,
            "private func statusBadge(",
            "@ViewBuilder\n    private var familySourceLabel",
        )
        self.assertIn("RoundedRectangle(cornerRadius: 7", status_badge)
        self.assertIn(".fixedSize()", status_badge)
        self.assertNotIn("Capsule()", status_badge)
        self.assertNotIn(".contentShape", status_badge)

        heart_control = section(
            view,
            "private func familyHeartControl(sourceDigest: String)",
            "private func actionTray<Content: View>(",
        )
        pending = section(heart_control, "case .pending:", "case .serverAccepted:")
        accepted = section(heart_control, "case .serverAccepted:", "case .hidden:")
        for noninteractive_status in (pending, accepted):
            self.assertIn("statusBadge(", noninteractive_status)
            self.assertNotIn("Button(", noninteractive_status)
            self.assertNotIn("Link(", noninteractive_status)
        self.assertIn(".buttonStyle(.plain)", view)

        deep_link = source("Shared/Routing/DeepLink.swift")
        self.assertIn('components.host = "family-window"', deep_link)
        entry = source("NekoWidgetWidget/NekoWidgetEntry.swift")
        self.assertIn(
            "return DeepLink.familyWindow(localWindowID: localWindowID)",
            entry,
        )
        self.assertIn("var memoryActionURL: URL?", entry)

    def test_empty_widget_uses_quiet_window_without_guessing_failure_reason(self) -> None:
        view = source("NekoWidgetWidget/NekoWidgetView.swift")
        production_view = view.rsplit(
            "#if DEBUG && APP_STORE_SCREENSHOT_WIDGET_FIXTURE", 1
        )[0]
        empty_state = section(
            production_view,
            "private var emptyState: some View",
            "private var emptyStateTitle: String",
        )
        self.assertIn("QuietWindowMark()", empty_state)
        self.assertIn("LinearGradient(", empty_state)
        self.assertIn("RadialGradient(", empty_state)
        self.assertIn('Text("アプリを開いて確認")', empty_state)
        self.assertIn(".lineLimit(2)", empty_state)
        self.assertIn(".minimumScaleFactor(0.75)", empty_state)
        self.assertNotIn("CatPawMark", empty_state)
        self.assertNotIn(".orange", empty_state)
        self.assertNotIn("スキャン", empty_state)
        self.assertNotIn("アクセス", empty_state)
        self.assertNotIn("更新してください", empty_state)

        empty_title = section(
            production_view,
            "private var emptyStateTitle: String",
            "private var emptyStateMarkSize: CGFloat",
        )
        self.assertIn('return "\\(entry.windowDisplayName)の一枚を待っています"', empty_title)
        self.assertIn('return "猫の一枚を待っています"', empty_title)

        mark_size = section(
            production_view,
            "private var emptyStateMarkSize: CGFloat",
            "private enum QuietWindowPalette",
        )
        self.assertIn("family == .systemLarge", mark_size)
        self.assertIn("family == .systemMedium", mark_size)
        self.assertIn("return 38", mark_size)

        window_mark = section(
            production_view,
            "private struct QuietWindowMark: View",
            "private enum WidgetStatusBadgeStyle",
        )
        self.assertIn("QuietWindowOpening()", window_mark)
        self.assertIn("QuietWindowPalette.cream", window_mark)
        self.assertNotIn("QuietWindowPalette.opening", window_mark)

        provider = source("NekoWidgetWidget/NekoWidgetTimelineProvider.swift")
        snapshot = section(provider, "func snapshot(", "func timeline(")
        snapshot_family_gate = section(
            snapshot,
            "if WidgetPhotoSource.isFamilyWindowSourceID(source.id)",
            "return familySnapshot(",
        )
        self.assertIn("photoSourceIdentifier: source.id", snapshot_family_gate)
        self.assertIn("familyWindowDisplayName(", snapshot_family_gate)

        timeline = section(provider, "func timeline(", "private func familySnapshot(")
        timeline_family_gate = section(
            timeline,
            "if WidgetPhotoSource.isFamilyWindowSourceID(source.id)",
            "return familyTimeline(",
        )
        self.assertIn("photoSourceIdentifier: source.id", timeline_family_gate)
        self.assertIn("familyWindowDisplayName(", timeline_family_gate)

    def test_concrete_family_widget_prefers_catalog_name_to_stale_manifest(self) -> None:
        container = source("Shared/AppGroup/SharedContainer.swift")
        display_name = section(
            container,
            "static func familyWidgetWindowDisplayName(localWindowID: String?)",
            "static var familyWidgetCacheHistoryURL: URL?",
        )
        self.assertIn("if let localWindowID", display_name)
        self.assertIn("PrivateWindowCatalogStore.widgetEntries()", display_name)
        self.assertIn("PrivateWindowDisplayName.resolved(entry.displayName)", display_name)
        self.assertLess(
            display_name.index("PrivateWindowCatalogStore.widgetEntries()"),
            display_name.index("familyWidgetManifestURL(localWindowID: localWindowID)"),
        )

    def test_family_widget_memory_link_requires_exact_window_and_photo(self) -> None:
        entry = source("NekoWidgetWidget/NekoWidgetEntry.swift")
        photo_url = section(entry, "var photoURL: URL?", "var memoryActionURL: URL?")
        family_branch = section(
            photo_url,
            "if WidgetPhotoSource.isFamilyWindowSourceID(photoSourceIdentifier)",
            "guard let localIdentifier",
        )
        self.assertIn("let localWindowID", family_branch)
        self.assertIn("let familySourceDigest", family_branch)
        self.assertIn("DeepLink.familyWindowPhoto(", family_branch)
        self.assertIn("return exactPhotoURL", family_branch)
        self.assertIn(
            "DeepLink.familyWindow(localWindowID: localWindowID)",
            family_branch,
        )
        self.assertIn("return DeepLink.familyWindow()", family_branch)

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
        self.assertNotIn("photoDestinationURL", widget_view)
        self.assertNotIn("entry.memoryActionURL ?? entry.photoURL", widget_view)

        deep_link = source("Shared/Routing/DeepLink.swift")
        serializer = section(
            deep_link,
            "var url: URL?",
            "static func photo(",
        )
        family_serializer = section(
            serializer,
            "case let .familyWindow(localWindowID, sourceDigest, action):",
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
        self.assertIn(
            'URLQueryItem(name: "action", value: action.rawValue)',
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
        self.assertIn('$0.name == "action"', parser)
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
            "case let .familyWindow(localWindowID, sourceDigest, action):",
            "return\n        }",
        )
        self.assertLess(
            family_route.index("activatePrivateWindowAsync"),
            family_route.index("pendingFamilyMomentSourceDigest = sourceDigest"),
        )
        self.assertLess(
            family_route.index("pendingFamilyMomentSourceDigest = sourceDigest"),
            family_route.rindex("isFamilyWindowPresented = true"),
        )
        self.assertIn("action == .viewPhoto", family_route)
        self.assertIn("WidgetCacheBuilder.retainedFamilyMomentID(", family_route)
        self.assertIn("pendingFamilyNotificationRoute = MomentNotificationRoute(", family_route)
        self.assertIn("kind: .newMoment", family_route)

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
        self.assertIn(
            "@Binding var pendingFamilyMomentSourceDigest: String?",
            main_tab,
        )
        self.assertIn(
            "pendingMemorySourceDigest: $pendingFamilyMomentSourceDigest",
            main_tab,
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
        self.assertIn("memorySaveDialogTitle", family_view)
        self.assertIn('"この写真を取り込んで残しますか？"', family_view)
        self.assertIn('"写真アプリにコピーして残す"', family_view)
        confirmation = section(
            family_view,
            ".confirmationDialog(\n            memorySaveDialogTitle",
            "private var pairedContent: some View",
        )
        self.assertIn("focusedMomentID = nil", confirmation)
        self.assertIn("shouldSave: true", confirmation)
        self.assertIn(
            "clearsWidgetFocusAfterCompletion: clearsWidgetFocus",
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
        self.assertNotIn('Text("ハートは相手へ・思い出は自分だけ")', family_view)
        self.assertIn("相手には通知しません", family_view)
        self.assertIn("写真を届けた相手にハートを送る", family_view)
        self.assertIn('Image(systemName: "bookmark")', family_view)
        self.assertIn('systemImage: "bookmark.fill"', family_view)
        self.assertIn('return canRetry ? "ハートを再送" : "ハートを送れません"', family_view)
        self.assertIn("heart?.phase == .sent", family_view)
        self.assertNotIn("foregroundStyle(.pink)", family_view)
        self.assertIn(
            'sentRecordBadge("ハート", systemImage: "heart.fill")',
            family_view,
        )
        self.assertIn('parts.append("ハートが届いています")', family_view)
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
            "func setSavedMemory(_ item: MomentInboxItem, isSaved: Bool) async",
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
            "func setSavedMemory(_ item: MomentInboxItem, isSaved: Bool) async",
        )
        self.assertNotIn("PhotoLibrary", heart_action)

    def test_memory_actions_set_the_requested_state_without_toggling(self) -> None:
        home = source("NekoWidget/Views/HomeView.swift")
        browser = source("NekoWidget/Views/LikedPhotosView.swift")
        main_tab = source("NekoWidget/Views/MainTabView.swift")
        app_root = source("NekoWidget/App/AppRootView.swift")
        app_model = source("NekoWidget/ViewModels/AppViewModel.swift")
        family = source("NekoWidget/Views/FamilyWindowView.swift")
        family_model = source("NekoWidget/ViewModels/MomentSharingViewModel.swift")

        self.assertNotIn("let setMemorySaved: (String, Bool) -> Void", home)
        self.assertNotIn("setMemorySaved(", home)
        self.assertNotIn("toggleLike", home)

        self.assertIn("let setMemorySaved: (String, Bool) -> Void", browser)
        self.assertIn("setMemorySaved(selectedPhoto.localIdentifier, true)", browser)
        self.assertIn("setMemorySaved(identifier, false)", browser)
        self.assertNotIn("toggleLike", browser)

        self.assertIn("let setMemorySaved: (String, Bool) -> Void", main_tab)
        self.assertIn("setMemorySaved: setMemorySaved", main_tab)
        self.assertNotIn("toggleLike", main_tab)
        self.assertIn("setMemorySaved: { identifier, isSaved in", app_root)
        self.assertIn("viewModel.setMemorySaved(", app_root)
        self.assertIn("isSaved: isSaved", app_root)

        personal_action = section(
            app_model,
            "func setMemorySaved(id localIdentifier: String, isSaved: Bool) async",
            "func selectAsset(id localIdentifier: String?)",
        )
        self.assertIn("SharedLikeStore.set(", personal_action)
        self.assertIn("isLiked: isSaved", personal_action)
        self.assertNotIn("SharedLikeStore.toggle", personal_action)
        self.assertNotIn("fallbackIsLiked", personal_action)

        family_action = section(
            family_model,
            "func setSavedMemory(_ item: MomentInboxItem, isSaved: Bool) async",
            "private func notifyPersonalMemoriesChanged",
        )
        self.assertIn("isLiked: isSaved", family_action)
        self.assertIn("guard isSaved else", family_action)
        self.assertNotIn("let willSave = !isSavedMemory(item)", family_action)
        self.assertIn(
            "await model.setSavedMemory(item, isSaved: shouldSave)",
            family,
        )
        self.assertNotIn("model.toggleSavedMemory", family)

    def test_today_widget_and_memory_photo_contexts_remain_distinct(self) -> None:
        main = source("NekoWidget/Views/MainTabView.swift")
        browser = source("NekoWidget/Views/LikedPhotosView.swift")
        home = source("NekoWidget/Views/HomeView.swift")
        onboarding = source("NekoWidget/Views/OnboardingPresentation.swift")
        model = source("NekoWidget/ViewModels/AppViewModel.swift")

        today_detail = section(
            main,
            "private func detailView(for localIdentifier: String) -> some View",
            "private func memoryDetailView(for localIdentifier: String) -> some View",
        )
        self.assertIn("photos: [initialPhoto]", today_detail)
        self.assertIn(
            "showsWidgetTiming: widgetOpenedPhotoIdentifier == localIdentifier",
            today_detail,
        )

        collection_detail = section(
            main,
            "private func collectionDetailView(for localIdentifier: String) -> some View",
            "private func memoryDetailView(for localIdentifier: String) -> some View",
        )
        self.assertIn("photos: catPhotos", collection_detail)
        self.assertIn("showsWidgetTiming: false", collection_detail)
        self.assertIn("PhotosRoute.collectionPhoto", home)

        memory_detail = section(
            main,
            "private func memoryDetailView(for localIdentifier: String) -> some View",
            "private func memoriesDestination(for route: MemoriesRoute) -> some View",
        )
        self.assertIn("photos: likedPhotos", memory_detail)
        self.assertIn("showsWidgetTiming: false", memory_detail)
        self.assertIn("if showsWidgetTiming", browser)
        self.assertIn("更新時刻は目安で、iOSにより前後します", browser)

        ordering = section(
            browser,
            "private static func makeBrowserPhotos(",
            "private var selectedPhoto: PhotoPresentation?",
        )
        self.assertIn("return ordered", ordering)
        self.assertNotIn(".sorted", ordering)

        self.assertIn("写真は時間とともに変わります。", home)
        self.assertIn("撮りためた猫写真が、", onboarding)
        self.assertIn("自動アルバムとホーム画面へ。", onboarding)
        self.assertIn("TodayPhotoSelectionPolicy.resolve(", model)
        self.assertIn("UIApplication.significantTimeChangeNotification", model)

    def test_album_grid_distinguishes_saved_bookmarks_from_selection(self) -> None:
        albums = source("NekoWidget/Views/LikedPhotosView.swift")
        thumbnail = section(
            albums,
            "private func albumGridThumbnail(",
            "private func toggleSelection(",
        )
        self.assertIn('if isSelected {', thumbnail)
        self.assertIn('Image(systemName: "checkmark.circle.fill")', thumbnail)
        self.assertIn('} else if photo.isLiked {', thumbnail)
        self.assertIn('Image(systemName: "bookmark.fill")', thumbnail)

    def test_memories_use_photo_and_summary_sections_without_a_false_purchase_action(self) -> None:
        memories = source("NekoWidget/Views/LikedPhotosView.swift")
        home = source("NekoWidget/Views/HomeView.swift")
        main_tab = source("NekoWidget/Views/MainTabView.swift")
        memories_section = section(
            memories,
            "private enum MemoriesSection:",
            "/// The entry point for photos the user deliberately kept as memories.",
        )
        memory_view = section(
            memories,
            "struct LikedPhotosView:",
            "private struct LikedPhotoBookExportFile:",
        )
        self.assertIn("if hasPhotoAccess", memory_view)
        self.assertIn("savedPhotosSection", memory_view)
        self.assertIn("summarySection", memory_view)
        self.assertNotIn("reflectionSection", memory_view)
        self.assertNotIn("creationSection", memory_view)
        self.assertIn('case .photos: "選んだ一枚"', memories)
        self.assertIn('case .summaries: "ふりかえり"', memories)
        self.assertLess(
            memories_section.index("case summaries"),
            memories_section.index("case photos"),
        )
        self.assertNotIn('Text("残した写真")', memory_view)
        self.assertIn("MemoriesRoute.monthlyWindow(presentation)", memory_view)
        self.assertIn('"季節のムービー",', memory_view)
        self.assertIn(
            'Label("かたちにする", systemImage: "square.and.arrow.up")',
            memory_view,
        )
        self.assertNotIn("creationPreviewCard", memory_view)
        self.assertNotIn('Text("準備中・カード・卓上・小さな本")', memory_view)
        self.assertNotIn('accessibilityIdentifier("memory-creation-preview")', memory_view)
        self.assertIn('accessibilityIdentifier("memories-latest-summary")', memory_view)
        self.assertIn('accessibilityIdentifier("memories-summary-empty-state")', memory_view)
        self.assertIn('accessibilityIdentifier("memories-seasonal-movies")', memory_view)
        self.assertIn('accessibilityIdentifier("memories-seasonal-movies-empty-state")', memory_view)
        self.assertIn("summarySectionDivider", memory_view)
        self.assertNotIn("if !seasonalMovies.isEmpty", memory_view)
        self.assertIn('systemImage: "calendar"', memory_view)
        self.assertIn('systemImage: "play.rectangle"', memory_view)
        self.assertNotIn('Text("自動アルバム")', memory_view)
        self.assertNotIn('accessibilityIdentifier("memories-open-automatic-albums")', memory_view)
        self.assertIn('accessibilityIdentifier("photos-open-automatic-albums")', home)
        self.assertIn('NavigationLink(value: PhotosRoute.automaticAlbums)', home)
        self.assertIn('case .automaticAlbums:', main_tab)
        self.assertIn('Picker("表示する思い出"', memory_view)
        self.assertIn('.pickerStyle(.segmented)', memory_view)
        self.assertIn('accessibilityIdentifier("memories-section-picker")', memory_view)
        self.assertIn("dynamicTypeSize.isAccessibilitySize", memory_view)
        self.assertIn('accessibilityIdentifier("memories-section-menu")', memory_view)
        self.assertNotIn(
            ".onChange(of: hasUnreadSummary, initial: true)",
            memory_view,
        )
        self.assertNotIn("selectedSection = .summaries", memory_view)
        self.assertIn("selection: $selectedSection", memory_view)
        self.assertIn('Label("写真から選ぶ"', memory_view)
        self.assertIn("photosPath = NavigationPath()", main_tab)
        self.assertIn("openPhotos: {", main_tab)
        self.assertNotIn("showsCreationPreview", memory_view)
        self.assertIn("case monthlyWindow(MonthlyWindowPresentation)", main_tab)
        self.assertIn(
            "monthlyWindowCollection: monthlyWindowCollection",
            main_tab,
        )
        self.assertIn("presentation: refreshedMonthlyWindow(snapshot)", main_tab)

        self.assertNotIn("MemoryCreationPreviewSheet", memories)
        self.assertNotIn('Button("購入', memory_view)
        self.assertNotIn('Button("注文', memory_view)
        self.assertNotIn("StoreKit", memory_view)

    def test_memories_show_the_complete_saved_collection_and_select_exports_separately(self) -> None:
        memories = source("NekoWidget/Views/LikedPhotosView.swift")
        memory_view = section(
            memories,
            "struct LikedPhotosView:",
            "private struct LikedPhotoBookExportFile:",
        )

        self.assertNotIn("ScrollViewReader { proxy in", memory_view)
        self.assertNotIn(".safeAreaInset(edge: .top", memory_view)
        self.assertNotIn("memories-section-jump-bar", memory_view)
        self.assertNotIn("Array(photos.prefix(6))", memory_view)
        self.assertIn("ForEach(photos)", memory_view)
        self.assertIn("SavedMemoriesGalleryView(", memory_view)
        self.assertNotIn("startsInExportMode: false", memory_view)
        self.assertNotIn('accessibilityIdentifier("memories-show-all-saved-photos")', memory_view)
        self.assertIn("startsInExportMode: true", memory_view)
        self.assertIn(
            'accessibilityIdentifier("memories-create-from-photos-action")',
            memory_view,
        )
        self.assertIn('identifier: "memories-latest-summary-title"', memory_view)
        self.assertNotIn('identifier: "memories-automatic-albums-title"', memory_view)
        self.assertIn('identifier: "memories-seasonal-movies-title"', memory_view)
        self.assertIn('.frame(height: 148)', memory_view)
        self.assertIn('Text("これまでの便り")', memory_view)
        self.assertIn("MonthlyWindowArchiveCard(", memory_view)
        self.assertIn(
            'accessibilityIdentifier("memories-previous-monthly-windows")',
            memory_view,
        )
        self.assertNotIn('Text("月の便り")\n                    .font(.caption', memory_view)
        self.assertIn('accessibilityIdentifier("memories-saved-section")', memory_view)
        self.assertIn('accessibilityIdentifier("memories-summaries-section")', memory_view)

        self.assertLess(
            memory_view.index("savedPhotosSection"),
            memory_view.index("summarySection"),
        )

        gallery = section(
            memories,
            "struct SavedMemoriesGalleryView:",
            "private struct LikedPhotoBookExportFile:",
        )
        self.assertIn("ForEach(photos)", gallery)
        self.assertIn('_selectedExportIdentifiers = State(initialValue: Set<String>())', gallery)
        self.assertIn('isSelectingForExport ? "写真を選ぶ"', gallery)
        self.assertIn(".safeAreaInset(edge: .bottom, spacing: 0)", gallery)
        self.assertIn('accessibilityIdentifier("photo-book-export")', gallery)
        self.assertIn('accessibilityIdentifier("book-demand-preview")', gallery)
        self.assertIn('accessibilityIdentifier("book-demand-interest")', gallery)
        self.assertIn("BookDemandValidationPolicy.canPreview", gallery)
        self.assertIn("bookDemandPreview = BookDemandPreviewSelection", gallery)
        self.assertIn("BookDemandValidationPolicy.proposedPriceLabel", gallery)
        self.assertIn(
            "まだ注文ではなく、決済も行いません。写真・氏名・住所は送信されません。",
            gallery,
        )
        self.assertIn("if isDedicatedPhotoBookFlow", gallery)
        self.assertIn("dismiss()", gallery)

        preview_opening = section(
            gallery,
            "private func openBookDemandPreview()",
            "private func toggleExportMode()",
        )
        self.assertIn("guard !isExportingPhotoBook else { return }", preview_opening)
        self.assertIn("selectedPhotoCount: selectedPhotos.count", preview_opening)
        self.assertIn("BookDemandPreviewSelection(photos: selectedPhotos)", preview_opening)

    def test_monthly_window_is_local_read_only_and_reachable_from_memories_only(self) -> None:
        home = source("NekoWidget/Views/HomeView.swift")
        main = source("NekoWidget/Views/MainTabView.swift")
        memories = source("NekoWidget/Views/LikedPhotosView.swift")
        model = source("NekoWidget/Views/MonthlyWindowPresentation.swift")
        view = source("NekoWidget/Views/MonthlyWindowView.swift")
        project = source("NekoWidget.xcodeproj/project.pbxproj")

        self.assertNotIn("monthlyWindow", home)
        self.assertNotIn("seasonalMovie", home)
        self.assertNotIn("reflectionSection", home)
        self.assertIn("MemoriesRoute.monthlyWindow", memories)
        self.assertIn('accessibilityIdentifier("memories-summaries-section")', memories)
        self.assertIn("from: catPhotos", main)
        self.assertIn("buildCompletedCollection", main)
        self.assertIn("let referenceDate = Date()", main)
        self.assertIn("through: referenceDate", main)
        self.assertIn(
            "monthlyWindowCollection: MonthlyWindowCollectionPresentation?",
            main,
        )
        self.assertIn("struct MonthlyWindowCollectionKey", main)
        self.assertIn(".task(id: monthlyWindowCollectionKey)", main)
        self.assertIn("photoPresentationVersion: LibraryPresentationVersion", main)
        self.assertIn("photoPresentationVersion: photoPresentationVersion", main)
        collection_key = section(
            main,
            "private var monthlyWindowCollectionKey:",
            "private var latestMonthlyWindowPeriodIdentifier:",
        )
        self.assertNotIn("for photo in catPhotos", collection_key)
        self.assertIn("Task.detached(priority: .utility)", main)
        self.assertIn("withTaskCancellationHandler", main)
        self.assertIn("buildTask.cancel()", main)
        self.assertIn("completedMonthlyWindowCollectionKey != key", main)
        self.assertIn(
            "monthlyWindowCollection: MonthlyWindowCollectionPresentation?",
            memories,
        )
        self.assertIn("presentation.remainingSceneCount.formatted()", memories)
        photos_routes = section(main, "enum PhotosRoute:", "enum MemoriesRoute:")
        memory_routes = section(
            main,
            "enum MemoriesRoute:",
            "private struct SeasonalMoviePreparationKey:",
        )
        self.assertNotIn("case monthlyWindow", photos_routes)
        self.assertIn("case monthlyWindow", memory_routes)
        self.assertNotIn("case monthlyPhoto", main)
        self.assertIn("refreshedMonthlyWindow(snapshot)", main)

        self.assertIn("static let minimumSceneCount = 5", model)
        self.assertIn("static let maximumSceneCount = 7", model)
        self.assertIn("struct MonthlyWindowCollectionPresentation", model)
        self.assertIn("enum MonthlyWindowReadReceipt", model)
        self.assertIn('static let storageKey = "monthlyWindow.latestReadPeriod.v1"', model)
        self.assertIn("openedPeriodIdentifier == latestPeriodIdentifier", model)
        self.assertIn("latestPeriodIdentifier > readPeriodIdentifier", model)
        self.assertIn("func buildCompletedCollection(", model)
        self.assertIn("let sortedMonthStarts = months.keys.sorted", model)
        self.assertIn("collapseRapidNearDuplicates", model)
        self.assertIn("boundingBoxIntersectionOverUnion", model)
        self.assertIn("lhs.albumPostures == rhs.albumPostures", model)
        self.assertIn("capturedAt >= interval.start && capturedAt < interval.end", model)
        self.assertIn("currentTaskIsCancelled()", model)
        self.assertNotIn("URLSession", model)
        self.assertNotIn("UserDefaults", model)
        self.assertNotIn("PHAsset", model)

        self.assertIn("@AppStorage(MonthlyWindowReadReceipt.storageKey)", main)
        self.assertIn(".badge(hasUnreadMemoriesSummary ? 1 : 0)", main)
        self.assertIn("markMonthlyWindowReadIfLatest(snapshot)", main)
        self.assertIn("latestMonthlyWindowIsUnread: Bool", memories)
        self.assertNotIn('return "まとめ・未読"', memories)

        self.assertIn("写真は送信しません。", view)
        self.assertIn('Button("思い出へ戻る")', view)
        self.assertIn("ScrollView", view)
        self.assertIn("LazyVStack(spacing: 0)", view)
        self.assertIn('Text("この月の便りは、ここまで")', view)
        self.assertIn('isSaved ? "思い出に残した" : "思い出に残す"', view)
        self.assertIn("setMemorySaved(photo.localIdentifier, true)", view)
        self.assertIn(".toolbar(.hidden, for: .tabBar)", view)
        self.assertNotIn("TabView(selection:", view)
        self.assertNotIn("MonthlyLetterMemoryPicker", view)
        self.assertNotIn("もう一度見る", view)
        self.assertNotIn("流して見る", view)
        self.assertNotIn("MonthlyWindowSlideshowView", view)
        self.assertNotIn("AVFoundation", view)
        self.assertNotIn("VideoPlayer", view)

        self.assertIn("MonthlyWindowPresentation.swift in Sources", project)
        self.assertIn("MonthlyWindowView.swift in Sources", project)

    def test_seasonal_movie_is_bounded_local_and_reachable_from_memories_only(self) -> None:
        home = source("NekoWidget/Views/HomeView.swift")
        main = source("NekoWidget/Views/MainTabView.swift")
        memories = source("NekoWidget/Views/LikedPhotosView.swift")
        model = source("NekoWidget/Views/SeasonalMoviePresentation.swift")
        service = source("NekoWidget/Services/SeasonalMovieCandidateService.swift")
        archive = source("NekoWidget/Services/SeasonalMovieArchiveStore.swift")
        export = source("NekoWidget/Services/SeasonalMovieExportService.swift")
        view = source("NekoWidget/Views/SeasonalMovieView.swift")
        project = source("NekoWidget.xcodeproj/project.pbxproj")
        config = source("Config.xcconfig")

        self.assertNotIn("seasonalMovie", home)
        self.assertNotIn("reflectionSection", home)
        self.assertIn("MemoriesRoute.seasonalMovie", memories)
        photos_routes = section(main, "enum PhotosRoute:", "enum MemoriesRoute:")
        memory_routes = section(
            main,
            "enum MemoriesRoute:",
            "private struct SeasonalMoviePreparationKey:",
        )
        self.assertNotIn("case seasonalMovie", photos_routes)
        self.assertIn("case seasonalMovie(SeasonalMoviePeriodID)", memory_routes)
        self.assertIn("SeasonalMovieView(", main)
        self.assertIn("seasonalMovies: seasonalMovieArchive.records", main)
        self.assertIn("latestSeasonalMovieIsNew: latestSeasonalMovieIsNew", main)
        self.assertIn(".badge(hasUnreadMemoriesSummary ? 1 : 0)", main)
        self.assertIn(
            "latestMonthlyWindowIsUnread || latestSeasonalMovieIsNew",
            main,
        )
        self.assertIn("seasonalMovieArchive.records.first.map { !$0.isFrozen }", main)
        self.assertIn("let latestSeasonalMovieIsNew: Bool", memories)
        self.assertNotIn(".onChange(of: hasUnreadSummary, initial: true)", memories)
        self.assertIn("isNew: latestSeasonalMovieIsNew", memories)
        self.assertIn("let service = SeasonalMovieCandidateService()", main)
        self.assertIn("await service.photoCandidates", main)
        self.assertIn("await service.videoCandidateBatch", main)
        self.assertIn("sourceAlbumIdentifier: preparationKey.sourceAlbumIdentifier", main)
        self.assertIn("if photoSourceStatus == .unavailable", main)
        self.assertIn("case let .ready(photoPresentation)", main)
        self.assertIn("seasonalMovieArchive.recordDraft", main)
        self.assertIn("seasonalMovie = archiveDraft?.presentation", main)
        self.assertIn("seasonalMovieArchive.finalizeDraft", main)
        self.assertIn("freezeRecipe: { reason in", main)
        self.assertIn("seasonalMovieArchive.freeze", main)
        self.assertIn(".task(id: seasonalMoviePreparationKey)", main)
        self.assertIn("completedSeasonalMoviePreparationKey", main)
        self.assertIn("guard let richerDraft else", main)
        self.assertIn(".task(id: scenePhase)", main)
        self.assertIn(
            "guard completedSeasonalMoviePreparationKey != preparationKey else { return }",
            main,
        )
        self.assertIn("hasher.combine(photo.isLiked)", main)
        self.assertIn("hasher.combine(photo.isPhotoLibraryFavorite)", main)
        self.assertIn("SeasonalMovieVideoCatalog.digest", main)
        self.assertIn("videoCatalogDigest: videoCatalogDigest", main)
        self.assertIn("videoBatch.hadLocallyUnavailableMedia", main)

        self.assertIn("static let minimumDistinctSceneCount = 10", model)
        self.assertIn("static let minimumCaptureDayCount = 6", model)
        self.assertIn("static let minimumMonthCount = 2", model)
        self.assertIn("static let maximumOutputSceneCount = 12", model)
        self.assertIn("static let maximumPlaybackDuration: TimeInterval = 22", model)
        self.assertIn("trimToPlaybackBudget", model)
        self.assertIn("completedQuarter(containing: referenceDate)", model)
        self.assertIn("collapseRapidNearDuplicates", model)
        self.assertNotIn("URLSession", model)
        self.assertNotIn("UserDefaults", model)
        self.assertIn("let isPhotoLibraryFavorite: Bool", model)
        self.assertIn("var curationSignalRank: Int", model)
        self.assertIn("decodeIfPresent(", model)

        self.assertIn("PHAsset.fetchAssets(with: .video", service)
        self.assertIn("VNRecognizeAnimalsRequest", service)
        self.assertIn("maximumVideosPerMonth = 12", service)
        self.assertIn("evenlySpacedAssets", service)
        self.assertIn("PHAsset.fetchAssets(in: collection, options: options)", service)
        self.assertIn("hasher.combine(asset.duration)", service)
        self.assertIn("hasher.combine(asset.isFavorite)", service)
        self.assertIn("case locallyUnavailable", service)
        self.assertIn("isMemory: false", service)
        self.assertIn("isPhotoLibraryFavorite: photoAsset.isFavorite", service)
        self.assertNotIn("isMemory: photoAsset.isFavorite", service)
        self.assertIn("SeasonalMoviePhotoKitRequest", service)
        self.assertIn("requestTimeoutNanoseconds", service)
        self.assertGreaterEqual(
            service.count("options.isNetworkAccessAllowed = false"),
            2,
        )
        self.assertNotIn("URLSession", service)
        self.assertNotIn("UserDefaults", service)

        self.assertNotIn('Text("できました")', view)
        self.assertNotIn("ができました", view)
        self.assertIn('Text("季節のムービー")', view)
        self.assertIn('の季節のムービー、\\(presentation.scenes.count)場面', view)
        self.assertIn("nextWorkDescription", view)
        self.assertIn('return "次は\\(releaseMonth)月ごろ', view)
        self.assertIn("SeasonalMovieAboutSheet", view)
        self.assertIn("似た写真をまとめます", view)
        self.assertIn("思い出と動く場面を優先します", view)
        self.assertIn("写真が少ない季節は作りません", view)
        self.assertIn("monthMarkerIsVisible", view)
        self.assertIn("try await Task.sleep(nanoseconds: 800_000_000)", view)
        self.assertIn(".dateTime.month(.wide)", view)
        self.assertIn("setCategory(.playback, mode: .moviePlayback)", view)
        self.assertIn("SeasonalMovieSoundtrackContract.volume", view)
        self.assertIn("SeasonalMovieSoundtrackContract.fadeInDuration", view)
        self.assertIn("SeasonalMovieSoundtrackContract.endingHoldDuration", view)
        self.assertIn("SeasonalMovieSoundtrackContract.fadeOutDuration", view)
        self.assertIn('Text("この季節も、ここまで")', view)
        self.assertIn("LocalSeasonalLivePhotoView", view)
        self.assertIn("LocalSeasonalVideoView", view)
        self.assertIn("SeasonalMovieSoundtrackPlayer", view)
        self.assertIn('Text("この作品から外しました")', view)
        self.assertIn("SeasonalMovieArchiveCard", view)
        self.assertIn('Text("新着")', view)
        self.assertIn('+ (isNew ? "、新着" : "")', view)
        self.assertIn("currentSceneIsReady", view)
        self.assertIn("markSceneReady", view)
        self.assertIn("skipUnavailableScene", view)
        self.assertIn("didLoad ? onReady() : onUnavailable()", view)
        self.assertIn("try await Task.sleep(nanoseconds: 5_000_000_000)", view)
        self.assertIn("preheatScenes(around:", view)
        self.assertIn("networkAccessAllowed: false", view)
        self.assertIn(") async throws -> SeasonalMoviePresentation", view)
        self.assertIn("isUpdatingScene", view)
        self.assertGreaterEqual(view.count("isMuted = true"), 2)
        self.assertGreaterEqual(view.count("networkAccessAllowed: false"), 2)
        self.assertIn("@Environment(\\.accessibilityReduceMotion)", view)
        self.assertIn("@Environment(\\.scenePhase)", view)
        self.assertIn("square.and.arrow.up", view)
        self.assertIn("SeasonalMovieExportService.shared.export", view)
        self.assertIn("meaningfulPlaybackSceneCount = 2", view)
        self.assertIn("try? await freezeRecipe(.meaningfulPlayback)", view)
        self.assertIn("try await freezeRecipe(.export)", view)
        self.assertIn("Live Photoは、保存した動画では静止画になります。", view)
        self.assertNotIn("setMemorySaved", view)

        self.assertIn('appendingPathComponent("SeasonalMovies"', archive)
        self.assertIn(".completeFileProtection", archive)
        self.assertIn("values.isExcludedFromBackup = true", archive)
        self.assertNotIn("temporaryDirectory", archive)
        self.assertNotIn("try? load()", archive)
        self.assertIn("return nil", archive)
        self.assertIn("let writingOptions: Data.WritingOptions", archive)
        self.assertIn("func finalizeDraft(", archive)
        self.assertIn("case meaningfulPlayback", archive)
        self.assertIn("case legacyRecord", archive)
        self.assertIn("func freeze(", archive)
        self.assertIn("guard !records[index].isFrozen", archive)
        self.assertIn("records[index].excludedSceneIdentifiers.isEmpty", archive)
        self.assertIn("AVAssetWriter(outputURL: outputURL, fileType: .mp4)", export)
        self.assertIn("writer.metadata = []", export)
        self.assertIn("options.isNetworkAccessAllowed = false", export)

        self.assertIn("SeasonalMoviePresentation.swift in Sources", project)
        self.assertIn("SeasonalMovieCandidateService.swift in Sources", project)
        self.assertIn("SeasonalMovieView.swift in Sources", project)
        self.assertIn("SeasonalMovieArchiveStore.swift in Sources", project)
        self.assertIn("SeasonalMovieExportService.swift in Sources", project)
        self.assertEqual(project.count("SeasonalMovieArchiveStore.swift in Sources"), 2)
        self.assertEqual(project.count("SeasonalMovieExportService.swift in Sources"), 2)
        self.assertIn("猫の写真を端末内で見つけて", config)
        self.assertIn("アルバムとウィジェットへ反映し", config)
        self.assertIn("猫が写る写真や動画から季節のムービー", config)
        self.assertIn("元の写真や動画を変更・削除しません", config)

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
        photo_image = section(
            view,
            "// Every photo fills the Widget",
            ".accessibilityElement(children: .ignore)",
        )
        self.assertIn(".scaledToFill()", photo_image)
        self.assertIn(".clipped()", photo_image)
        self.assertNotIn(".scaledToFit()", view)

        rendered = section(
            builder,
            "private static func renderedWidgetImage(",
            "private static func drawRect(",
        )
        self.assertIn("let rendered = aspectFillImage(image, size: size)", rendered)
        self.assertIn("aspectFillScale(imageSize: image.size, canvasSize: size)", rendered)
        self.assertNotIn("gaussianBlurredImage(", rendered)
        self.assertNotIn("aspectFitRect(", rendered)
        self.assertIn('cacheRenderingRevision = "edge-to-edge-v1"', builder)

        action_tray = section(
            view,
            "private func actionTray<Content: View>(",
            "private func directActionLabel(",
        )
        self.assertNotIn("LinearGradient(", action_tray)

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

    def test_window_list_preserves_cached_windows_and_scopes_pending_counts(self) -> None:
        main_tab = source("NekoWidget/Views/MainTabView.swift")
        pairing_presentation = source("NekoWidget/Views/PairingPresentation.swift")
        self.assertIn("ForEach(connectedWindows)", main_tab)
        self.assertIn("ForEach(setupWindows)", main_tab)
        self.assertIn('windowSectionTitle("接続済みのまど")', main_tab)
        self.assertIn('windowSectionTitle("設定中のまど")', main_tab)
        self.assertIn("まどの名前は、作成した人の最初のiPhoneから変更できます。", main_tab)
        self.assertIn("PrivateWindowListPresentationPolicy.make", main_tab)
        self.assertIn("if $0.createdAt != $1.createdAt", main_tab)
        self.assertNotIn("if $0.updatedAt != $1.updatedAt", main_tab)
        self.assertIn("visual order", pairing_presentation)
        self.assertIn("guard let phase = input.phase else { return true }", pairing_presentation)
        self.assertIn("stable.filter { !isSetup($0) }", pairing_presentation)
        self.assertIn("stable.filter(isSetup)", pairing_presentation)
        self.assertIn("opensActiveWindow = true", main_tab)
        self.assertIn("model.activatePrivateWindow", main_tab)
        self.assertIn("FamilyWindowView(", main_tab)
        self.assertIn('Label("別のまどを追加"', main_tab)

        window_list = section(
            main_tab,
            "private struct WindowListView: View",
            "private struct DeepLinkSelection: Equatable",
        )
        self.assertNotIn("familyWindowPresentation.latestImageURL", window_list)
        self.assertNotIn("familyWindowPresentation.safeCount", window_list)
        self.assertIn("@State private var catalogLoadMessage: String?", window_list)
        self.assertIn(
            "else if windows.isEmpty, let message = availabilityMessage",
            window_list,
        )
        self.assertIn("cachedWindowWarning(message: message)", window_list)
        self.assertIn("model.bootstrapRetryMessage ?? catalogLoadMessage", window_list)
        self.assertIn("|| pausesWindowChanges", window_list)
        self.assertIn('.id(activeWindowID ?? "no-active-window")', window_list)

        reload_catalog = section(
            window_list,
            "private func reloadCatalogPresentation()",
            "private func reloadPreparationCounts()",
        )
        catalog_failure = reload_catalog.split("} catch {", 1)[1]
        self.assertIn("catalogLoadMessage = windows.isEmpty", catalog_failure)
        self.assertNotIn("windows = []", catalog_failure)
        self.assertNotIn("activeWindowID = nil", catalog_failure)
        self.assertNotIn("pendingPreparationCounts = [:]", catalog_failure)

        add_window = section(
            window_list,
            "private var addWindowButton: some View",
            "private func windowCard(",
        )
        self.assertIn("let previousActiveWindowID = activeWindowID", add_window)
        self.assertIn("createdWindowID != previousActiveWindowID", add_window)
        self.assertIn("createAndOpenWindow(setupPath: .create)", main_tab)
        self.assertIn("createAndOpenWindow(setupPath: .join)", main_tab)
        self.assertIn("createAndOpenWindow(setupPath: .recover)", main_tab)
        self.assertIn("initialSetupPath: requestedSetupPath", main_tab)
        empty_window = section(
            window_list,
            "private var emptyWindowCard: some View",
            "private var addWindowButton: some View",
        )
        self.assertIn("showsAddWindowConfirmation = true", empty_window)
        self.assertNotIn("opensActiveWindow = true", empty_window)
        self.assertIn('Button("まどをはじめる")', empty_window)
        pairing_view = source("NekoWidget/Views/PairingView.swift")
        self.assertIn("init(initialSetupPath: PairingSetupPath? = nil)", pairing_view)
        self.assertIn("if setupPath == .create", pairing_view)
        self.assertIn("windowNameSection(state)", pairing_view)
        self.assertIn("let previousPhase", pairing_view)

        preparation_counts = section(
            window_list,
            "private func reloadPreparationCounts()",
            "@ViewBuilder\n    private var activeWindowDestination",
        )
        self.assertIn("MomentShareHandoffStore.activeAdmissions()", preparation_counts)
        self.assertIn("MomentShareHandoffStore.presentationSnapshot()", preparation_counts)
        self.assertIn("admission.localWindowID ?? onlyWindowID", preparation_counts)
        self.assertIn("nextCounts[localWindowID, default: 0] += 1", preparation_counts)
        count_failure = preparation_counts.split("} catch {", 1)[1]
        self.assertNotIn("pendingPreparationCounts = [:]", count_failure)
        self.assertIn('"送信準備中 \\(pendingCount.formatted())枚"', window_list)

        self.assertIn("SubtleWindowThumbnail(showsSetupMark:", window_list)
        self.assertIn("private struct SubtleWindowThumbnail: View", main_tab)
        self.assertIn("Color.accentColor.opacity(0.07)", window_list)
        self.assertNotIn("Color.accentColor.opacity(0.18)", window_list)
        self.assertIn("PairingStateStore.load(", reload_catalog)
        self.assertIn("case .awaitingInvitee:", window_list)
        self.assertIn('return "相手の参加待ち"', window_list)
        self.assertNotIn('Text("現在のまど")', window_list)
        self.assertIn('"このまどを開きます"', window_list)
        self.assertIn('"設定を続ける"', window_list)
        self.assertIn(
            "pairingPhases[window.localWindowID] == .unpaired",
            window_list,
        )
        self.assertIn("dynamicTypeSize.isAccessibilitySize ? 2 : 1", window_list)

    def test_settings_prioritizes_daily_safety_and_about_tasks(self) -> None:
        settings = source("NekoWidget/Views/SettingsView.swift")
        app_root = source("NekoWidget/App/AppRootView.swift")
        family = source("NekoWidget/Views/FamilyWindowView.swift")
        for section_title in (
            "写真とねこ",
            "ウィジェット",
            "まど",
            "プライバシーとサポート",
            "アプリ",
        ):
            self.assertIn(f'Text("{section_title}")', settings)
        self.assertNotIn('Label("写真の検出", systemImage: "lock.iphone")', settings)
        self.assertNotIn('Text("縮小・位置情報削除・暗号化")', settings)

        self.assertIn('Label("写真の表示と整理"', settings)
        self.assertIn("private var photoSettingsView: some View", settings)
        self.assertIn('.navigationTitle("写真")', settings)
        self.assertIn('Label("ウィジェットの置き方"', settings)
        self.assertIn('"settings-widget-placement-guide"', settings)
        self.assertIn('"settings-sharing-review"', settings)
        self.assertIn('FamilyWindowView(initialPresentation: .settings)', settings)
        self.assertIn('Text("まどの設定")', settings)
        self.assertIn('Image(systemName: "rectangle.split.2x2")', settings)
        self.assertIn('Text("名前・相手・iPhone")', family)
        self.assertIn('"相手と接続済み・まど名を変更できます"', family)
        self.assertIn("savePhotoSettings(requestedRange, requestedAlbumLimit)", settings)
        self.assertIn(
            "await saveDetectionSettings(requestedConfidence, requestedMinimumArea)",
            settings,
        )
        self.assertNotIn("var requestedSettings = settings", settings)
        self.assertIn("isPhotoSettingsSavePending = true", settings)
        self.assertIn("!canUpdate || isSavingSettings || state == .updating", settings)
        photo_settings = section(
            settings,
            "private var photoSettingsView: some View",
            "private var advancedDiagnosticsView: some View",
        )
        diagnostics = section(
            settings,
            "private var advancedDiagnosticsView: some View",
            "private var canReviewDetectionAccuracySample",
        )
        self.assertIn('Text("写真を見つけ直す")', photo_settings)
        self.assertIn('"最初から再スキャン"', photo_settings)
        self.assertNotIn('"最初から再スキャン"', diagnostics)
        self.assertIn('Text("診断情報")', settings)
        self.assertIn('.navigationTitle("診断情報")', settings)
        self.assertIn('Label("未保存の変更があります",', diagnostics)
        self.assertIn('Text("検証データ")', diagnostics)
        self.assertIn('Text("ランダム100枚を確認")', diagnostics)
        self.assertNotIn('Text("ランダム100枚を確認")', photo_settings)
        photo_save = section(
            app_root,
            "savePhotoSettings: { range, albumLimit in",
            "saveLifeReference:",
        )
        self.assertIn("var settings = viewModel.settings", photo_save)
        self.assertIn("settings.albumMaximum = albumLimit", photo_save)
        detection_save = section(
            app_root,
            "saveDetectionSettings: { confidenceThreshold, minimumAreaRatio in",
            "saveLifeReference:",
        )
        self.assertIn("var settings = viewModel.settings", detection_save)
        self.assertIn(
            "settings.confidenceThreshold = Float(confidenceThreshold)",
            detection_save,
        )
        self.assertIn(
            "settings.minimumCatAreaRatio = minimumAreaRatio",
            detection_save,
        )
        self.assertIn(
            ".onChange(of: settings) { oldSettings, newSettings in",
            settings,
        )
        self.assertIn("let preservesRange = (", settings)
        self.assertIn("|| isPhotoSettingsSavePending", settings)
        self.assertIn("let preservesLifeReference = (", settings)
        self.assertIn("|| isLifeReferenceSavePending", settings)
        self.assertIn("let preservesDetection = (", settings)
        self.assertIn("pendingDetectionSettingsSave != nil", settings)
        self.assertIn("detectionSettingsMatch(currentDraft, newSettings)", settings)
        self.assertIn("abs(lhs.confidenceThreshold - rhs.confidenceThreshold)", settings)
        self.assertIn("if pendingDetectionSettingsSave == request", settings)
        self.assertGreaterEqual(
            settings.count(".disabled(isSavingDetectionSettings)"),
            2,
        )
        self.assertIn('"settings-privacy-policy"', settings)
        self.assertIn('"settings-support-page"', settings)
        self.assertNotIn('Text("プライバシーとアプリ情報")', settings)

    def test_automatic_albums_have_one_photos_entry(self) -> None:
        main_tab = source("NekoWidget/Views/MainTabView.swift")
        home = source("NekoWidget/Views/HomeView.swift")
        memories = source("NekoWidget/Views/LikedPhotosView.swift")
        photos_routes = section(main_tab, "enum PhotosRoute:", "enum MemoriesRoute:")
        memory_routes = section(
            main_tab,
            "enum MemoriesRoute:",
            "private struct SeasonalMoviePreparationKey:",
        )
        self.assertIn("case automaticAlbums", photos_routes)
        self.assertNotIn("case automaticAlbums", memory_routes)
        self.assertIn("PhotosRoute.automaticAlbums", home)
        self.assertNotIn("MemoriesRoute.automaticAlbums", memories)
        self.assertIn('Text("自動アルバム")', home)
        self.assertIn('Text("成長・年ごと・写り方から探す")', home)
        self.assertIn('accessibilityIdentifier("photos-open-automatic-albums")', home)
        self.assertNotIn('accessibilityIdentifier("memories-open-automatic-albums")', memories)

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
        self.assertIn('static let fallback = "新しいまど"', models)
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
            "private static func writeWhileLifecycleLocked(\n        _ value: PrivateWindowNameSyncState",
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

    def test_synchronized_window_name_verifies_stable_committed_fields(self) -> None:
        store = source("Shared/Sharing/PairingKeychainStore.swift")
        apply_name = section(
            store,
            "static func applySynchronizedOwnerName(",
            "private static func binding(for pairing: PairingState)",
        )
        self.assertIn("return try mirrorCatalog(\n                committed,", apply_name)
        self.assertIn("committed.schemaVersion == next.schemaVersion", apply_name)
        self.assertIn("committed.storageRevision == next.storageRevision", apply_name)
        self.assertIn(
            "committed.pairingBindingSHA256 == next.pairingBindingSHA256",
            apply_name,
        )
        self.assertIn("committed.displayName == next.displayName", apply_name)
        self.assertNotIn("committed == next", apply_name)

    def test_catalog_only_window_name_repair_refreshes_the_window_list(self) -> None:
        store = source("Shared/Sharing/PairingKeychainStore.swift")
        apply_result = section(
            store,
            "struct PrivateWindowPresentationApplyResult",
            "enum PrivateWindowPresentationStore",
        )
        self.assertIn("let presentationDisplayNameChanged: Bool", apply_result)
        self.assertIn("let catalogMetadataChanged: Bool", apply_result)
        self.assertIn(
            "presentationDisplayNameChanged || catalogMetadataChanged",
            apply_result,
        )

        apply_name = section(
            store,
            "static func applySynchronizedOwnerName(",
            "private static func binding(for pairing: PairingState)",
        )
        mirror_catalog = section(
            apply_name,
            "func mirrorCatalog(",
            "let loaded = try? loadWhileLifecycleLocked",
        )
        self.assertIn(
            "target.displayName != presentation.displayName",
            mirror_catalog,
        )
        self.assertIn(
            "target.spaceID != currentPairing.spaceID",
            mirror_catalog,
        )
        self.assertIn(
            "target.credentialAccount",
            mirror_catalog,
        )
        self.assertIn("if catalogMetadataChanged", mirror_catalog)
        self.assertIn(
            "catalogMetadataChanged: catalogMetadataChanged",
            mirror_catalog,
        )

        coordinator = source("NekoWidget/Services/MomentSharingCoordinator.swift")
        name_sync = section(
            coordinator,
            "private func synchronizeWindowName(\n",
            "private func requireWindowNameSynchronizationAllowed(",
        )
        self.assertIn("changed = applied.requiresPresentationRefresh", name_sync)
        self.assertIn(
            "return changed || applied.requiresPresentationRefresh",
            name_sync,
        )

        best_effort = section(
            coordinator,
            "private func synchronizeWindowNameBestEffort(",
            "private func synchronizeWindowName(\n",
        )
        self.assertIn("if changed", best_effort)
        self.assertIn(".momentSharingPresentationNeedsRefresh", best_effort)

        main_tab = source("NekoWidget/Views/MainTabView.swift")
        window_list = section(
            main_tab,
            "private struct WindowListView: View",
            "private struct SubtleWindowThumbnail: View",
        )
        refresh_receiver = section(
            window_list,
            ".onReceive(\n            NotificationCenter.default.publisher(\n                for: .momentSharingPresentationNeedsRefresh",
            ".onReceive(\n            NotificationCenter.default.publisher(\n                for: .momentSharingContentNeedsReload",
        )
        self.assertIn("Task { await reloadCatalogPresentation() }", refresh_receiver)
        reload_catalog = section(
            window_list,
            "private func reloadCatalogPresentation() async",
            "private nonisolated static func loadCatalogPresentationSnapshot()",
        )
        self.assertIn("windows = snapshot.windows", reload_catalog)
        self.assertIn("activeWindowID = snapshot.activeWindowID", reload_catalog)

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
        self.assertIn("try resumeLegacyMigrationIfNeeded(&committed)", catalog)
        self.assertLess(
            catalog.index("try saveWhileLifecycleLocked(state)"),
            catalog.index("try resumeLegacyMigrationIfNeeded(&committed)"),
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
        self.assertIn("privateWindowCatalogAuthorityArtifactURLs.contains", resolution)
        self.assertIn("fileExists(atPath: $0.path)", resolution)
        self.assertIn("return nil", resolution)
        self.assertIn("pendingLegacyMigrationWindowID == catalog.activeWindowID", resolution)

        catalog_storage = section(
            container,
            "static var privateWindowCatalogURL: URL?",
            "static func windowDirectoryURL(localWindowID: String)",
        )
        self.assertIn("sharingControlDirectoryURL?.appendingPathComponent", catalog_storage)
        self.assertIn("legacyPrivateWindowCatalogURL", catalog_storage)
        self.assertIn("containerURL?.appendingPathComponent", catalog_storage)
        self.assertIn("privateWindowCatalogStorageMarkerURL", catalog_storage)

        catalog_loader = section(
            container,
            "private static func loadWithSource()",
            "static func load() throws",
        )
        self.assertIn("protectedStorageMigrationIsComplete()", catalog_loader)
        self.assertIn("throw Error.invalidCatalog", catalog_loader)
        self.assertLess(
            catalog_loader.index("protectedStorageMigrationIsComplete()"),
            catalog_loader.index("decodeCatalogIfPresent(at: legacyURL)"),
        )
        catalog_save = section(
            container,
            "private static func saveWhileLifecycleLocked(",
            "/// URLs shared by the application",
        )
        self.assertIn("SharedContainer.privateWindowCatalogURL", catalog_save)
        self.assertIn("SharingSecureFile.write", catalog_save)
        self.assertNotIn("legacyPrivateWindowCatalogURL", catalog_save)

        catalog_reset = section(
            container,
            "static func resetAllWhileLifecycleLocked",
            "private static func resumeLegacyMigrationIfNeeded",
        )
        self.assertIn("privateWindowCatalogAuthorityArtifactURLs", catalog_reset)

        create_catalog_entry = section(
            container,
            "static func createAndActivateWhileLifecycleLocked(",
            "static func activateWhileLifecycleLocked(",
        )
        self.assertIn("nextDefaultDisplayName(in: state.windows)", create_catalog_entry)
        self.assertIn("displayName: displayName", create_catalog_entry)
        self.assertIn(
            '"\\(PrivateWindowDisplayName.fallback) \\(ordinal)"',
            create_catalog_entry,
        )
        self.assertIn("case duplicateWindowName", container)
        self.assertIn(
            "validateDisplayNameAvailableForActiveWindowWhileLifecycleLocked",
            container,
        )

        pairing_presentation = source("Shared/Sharing/PairingKeychainStore.swift")
        self.assertGreaterEqual(
            pairing_presentation.count(
                "validateDisplayNameAvailableForActiveWindowWhileLifecycleLocked"
            ),
            2,
        )

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
        drain = section(
            processor,
            "func refreshAdmissionsAndDrain(",
            "private func reconcileOrPromote(",
        )
        self.assertIn("MomentShareHandoffStore", drain)
        self.assertIn(".activeAdmissions(now: now)", drain)
        self.assertIn("$0.bindingSHA256 == binding", drain)
        self.assertIn("throw refreshError", drain)
        self.assertNotIn("displayName ==", drain)

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
        self.assertIn("extensionEligibleAdmissions(", active_admissions)
        admission_policy = section(
            handoff,
            "static func extensionEligibleAdmissions(",
            "static func presentationSnapshot(",
        )
        self.assertIn("$0.isActive(at: now)", admission_policy)
        self.assertIn("Set(windowCatalog.windows.map(\\.localWindowID))", admission_policy)
        self.assertIn("admission.localWindowID.map(windowIDs.contains)", admission_policy)
        self.assertIn("windowCatalog.windows.count > 1", admission_policy)
        self.assertIn("let legacy = active.filter { $0.localWindowID == nil }", admission_policy)
        self.assertIn("guard legacy.count <= 1", admission_policy)
        self.assertNotIn("windowCatalog.activeWindowID", admission_policy)

        stage_capture = section(
            handoff,
            "static func stageCapture(",
            "static func nextPendingCapture(",
        )
        self.assertIn("$0.id == admissionID && $0.isActive(at: now)", stage_capture)
        self.assertIn("$0.admissionID == admissionID", stage_capture)
        self.assertIn(
            'privateWindowsDirectoryURL?.appendingPathComponent(\n            "moment-handoff.v2"',
            container,
        )

        share_view = source("NekoWidgetShareExtension/ShareViewController.swift")
        self.assertIn("configureDestinationMenu(admissions)", share_view)
        destination_menu = section(
            share_view,
            "private func configureDestinationMenu(",
            "private func destinationPickerTitles(",
        )
        self.assertIn("destinationButton.isHidden = false", destination_menu)
        self.assertIn("UIAction(", destination_menu)
        self.assertIn("self.selectAdmission(admission, pickerTitle: title)", destination_menu)
        self.assertIn("selectedAdmission?.id == admission.id ? .on : .off", destination_menu)
        self.assertIn("attributes: isAmbiguous ? .disabled : []", destination_menu)
        self.assertIn("duplicateDestinationNames(for: admissions)", destination_menu)
        self.assertIn("名前を変更してください", share_view)
        self.assertIn("選んだまど以外へ保存・送信することはありません", share_view)
        self.assertIn('アプリの「まど」から「\\(admission.displayName)」を開くと', share_view)
        self.assertIn("別のまどへ自動で切り替えることはありません", share_view)
        self.assertIn("admissionID: selectedAdmission.id", share_view)
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
        self.assertIn("guard model.canPersistWindowDisplayName", save_name)
        self.assertIn(
            "if !model.canPersistWindowDisplayName",
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
        liked = source("NekoWidget/Views/LikedPhotosView.swift")
        widget = source("NekoWidgetWidget/NekoWidgetView.swift")
        widget_configuration = source(
            "NekoWidgetWidget/NekoWidgetConfigurationIntent.swift"
        )
        self.assertNotIn("privateWindowDisplayName", home)
        self.assertIn('"\\(entry.windowDisplayName)に届いた一枚"', widget)
        self.assertIn('"\\(entry.windowDisplayName)に届いた写真"', widget)
        self.assertNotIn('"\\(entry.windowDisplayName)から届いた', widget)
        self.assertIn('detail: "このまどに届いた最新の一枚"', widget_configuration)
        self.assertIn('name: "このiPhoneの猫写真"', widget_configuration)
        self.assertIn('detail: "このiPhoneで見つけた猫写真"', widget_configuration)
        self.assertNotIn('name: "このiPhoneの写真"', widget_configuration)
        self.assertIn(
            'Label("写真", systemImage: "photo.on.rectangle.angled")',
            main_tab,
        )
        self.assertIn(
            'Label("まど", systemImage: "rectangle.split.2x2")',
            main_tab,
        )
        self.assertIn(
            'Image(systemName: "rectangle.on.rectangle.angled")',
            home,
        )
        self.assertIn('Label("思い出", systemImage: "photo.stack.fill")', main_tab)
        self.assertIn('.navigationTitle("写真")', home)
        self.assertIn('"window-settings-button"', home)
        self.assertNotIn('"window-list-settings-button"', main_tab)
        self.assertNotIn('"memories-settings-button"', liked)
        home_body = section(
            home,
            "var body: some View",
            "private var photoAccessCard: some View",
        )
        self.assertEqual(home_body.count("if shouldOfferWidgetPlacementGuide"), 2)
        self.assertLess(
            home_body.index("if shouldOfferWidgetPlacementGuide"),
            home_body.index("detectedPhotosSection"),
        )
        self.assertLess(
            home_body.index("photoAccessCard"),
            home_body.rindex("if shouldOfferWidgetPlacementGuide"),
        )
        self.assertNotIn('Text("今日の1枚")', home)
        self.assertNotIn('.navigationTitle("まど")', home)
        self.assertIn("PhotosRoute.automaticAlbums", home)
        self.assertIn('Text("自動アルバム")', home)
        self.assertNotIn("NavigationLink(value: MemoriesRoute.automaticAlbums)", liked)
        self.assertNotIn('"today-memory-saved-state"', home)
        self.assertIn("WindowListView(", main_tab)
        self.assertIn("ForEach(connectedWindows)", main_tab)
        self.assertIn("ForEach(setupWindows)", main_tab)
        self.assertIn("model.activatePrivateWindow", main_tab)
        self.assertIn('Label("別のまどを追加"', main_tab)
        self.assertIn("selectedTab = .photos", main_tab)
        self.assertIn("photosPath.append(PhotosRoute.photo(identifier))", main_tab)
        self.assertIn("selectedTab = .windows", main_tab)
        self.assertLess(
            main_tab.index('.tag(AppTab.photos)'),
            main_tab.index('.tag(AppTab.memories)'),
        )
        self.assertLess(
            main_tab.index('.tag(AppTab.memories)'),
            main_tab.index('.tag(AppTab.windows)'),
        )
        self.assertIn("Task.detached(priority: .userInitiated)", main_tab)
        self.assertIn("catalogReloadRevision", main_tab)
        onboarding = source("NekoWidget/Views/OnboardingPresentation.swift")
        self.assertIn("猫写真のウィジェットをひとつ。", onboarding)
        self.assertNotIn("猫写真のまどをひとつ。", onboarding)

        self.assertIn('"photo-browser-memory-saved-state"', liked)
        self.assertIn('Button("思い出から外す", role: .destructive)', liked)

        settings = source("NekoWidget/Views/SettingsView.swift")
        profiles = source("NekoWidget/Views/CatProfilesView.swift")
        onboarding = source("NekoWidget/Views/OnboardingPresentation.swift")
        permission = source("NekoWidget/Views/PhotoPermissionView.swift")
        scan = source("NekoWidget/Views/ScanStatusView.swift")
        self.assertIn('"ねこのプロフィール"', settings)
        self.assertIn('.navigationTitle("ねこのプロフィール")', profiles)
        self.assertIn('"このiPhoneの猫の写真や動画を"', onboarding)
        self.assertIn('"猫の写真や動画を見つけよう"', permission)
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
        self.assertIn("このiPhoneを以前のまどに追加", pairing)
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
        container = source("Shared/AppGroup/SharedContainer.swift")
        processor = source("NekoWidget/Services/MomentShareHandoffProcessor.swift")
        api_client = source("NekoWidget/Services/MomentSharingAPIClient.swift")
        widget = source("NekoWidgetWidget/NekoWidgetView.swift")
        runtime = source("NekoWidget/Services/SharingRuntimeSelfTest.swift")
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
        self.assertIn('Text("自分が届けた写真")', family)
        self.assertIn('Text("送信状況")', family)
        self.assertNotIn('Text("履歴")', family)
        self.assertIn("届いた写真の保存期間は最長90日です", family)
        self.assertIn("残すときは「取り込んで残す」を選びます", family)
        self.assertIn("「到着」は、相手が写真を開いたことを示しません", family)
        self.assertIn("届けた写真のプレビューは、このiPhoneだけに最長30日・最大200件まで保持します", family)
        self.assertIn("別のiPhoneや再インストール後には表示されません", family)
        self.assertIn("let thumbnail = sentRecordThumbnail(record)", family)
        target_record = section(
            family,
            "private var outgoingStatusSection: some View",
            "private var visibleSentRecords",
        )
        self.assertIn("LazyVGrid(columns: sentRecordColumns, spacing: 10)", target_record)
        self.assertIn("ForEach(visibleSentRecords)", target_record)
        self.assertNotIn("プレビュー画像は送信したiPhoneだけに最長30日残り", target_record)
        sent_columns = section(
            family,
            "private var sentRecordColumns:",
            "private var visibleSentRecords:",
        )
        self.assertIn("dynamicTypeSize.isAccessibilitySize ? 1 : 2", sent_columns)
        self.assertIn("GridItem(.flexible(minimum: 0)", sent_columns)
        self.assertIn("if let focusedSentMomentID", family)
        self.assertIn("records.insert(target, at: records.startIndex)", family)
        self.assertIn("写真のプレビューはこのiPhoneに残っていません", family)
        self.assertIn("sentRecordDisplayLimit + 20", family)
        self.assertIn('Button("さらに見る")', family)
        self.assertIn('Button("最新3件に戻す")', family)
        self.assertIn("static let sentRecordLimit = 200", presentation)
        self.assertIn(
            "record.recipientDeliveryConfirmedAt ?? record.serverAcceptedAt",
            family,
        )
        self.assertIn("let arrived = record.deliveryState", family)
        self.assertIn("localThumbnailFileName", store)
        self.assertIn("legacyInlineLocalThumbnailJPEG", store)
        self.assertIn("Never re-encode legacyInlineLocalThumbnailJPEG", store)
        self.assertIn("migrateLegacyInlineThumbnailsWhileLocked", store)
        self.assertIn("SharingSecureFile.write(", store)
        self.assertIn("let committedURL = URL(fileURLWithPath: url.path", store)
        self.assertIn("committedURL.resourceValues", store)
        self.assertIn("readLocalThumbnail(for item", store)
        self.assertIn("removeLocalThumbnail(for item", store)
        self.assertIn("momentSharingSentThumbnailDirectoryURL", container)
        self.assertIn("maximumLocalThumbnailBytes = 64 * 1_024", store)
        self.assertIn("maximumLocalThumbnailPixelDimension = 512", store)
        self.assertIn("CGImageSourceCreateImageAtIndex", store)
        self.assertNotIn("CGImageSourceGetStatus(source)", store)
        self.assertIn("kCGImageSourceShouldCacheImmediately", store)
        self.assertIn("CGImageSourceGetCount(source) == 1", store)
        self.assertIn(") as NSDictionary?", store)
        self.assertNotIn(") as? [CFString: Any]", store)
        self.assertIn("decodedImage.width", store)
        self.assertIn("decodedImage.height", store)
        self.assertIn("isSafeThumbnailDirectory", store)
        self.assertIn("resolvingSymlinksInPath", store)
        self.assertIn("isSymbolicLinkKey", store)
        self.assertIn("try? writeWhileLocked(state)", store)
        self.assertIn("boundedThumbnailDirectoryEntryNames", store)
        self.assertIn("requireExisting: true", store)
        self.assertIn("try? removeLocalThumbnail(fileName: name)", store)
        self.assertIn("-completedOutboxMetadataSeconds", store)
        self.assertIn("maximumTerminalOutboxMetadataCount = 200", store)
        self.assertIn("CGImageSourceCreateThumbnailAtIndex", processor)
        self.assertIn("CGImageDestinationAddImage", processor)
        self.assertIn("kCGImageDestinationLossyCompressionQuality", processor)
        self.assertNotIn("localThumbnailJPEG", api_client)
        self.assertNotIn("localThumbnailFileName", api_client)
        self.assertNotIn("MomentSharingStateStore", widget)
        self.assertNotIn("localThumbnailFileName", widget)
        self.assertIn("rewrittenOutbox.first?[\"localThumbnailJPEG\"] == nil", runtime)
        self.assertIn("hasRequiredProtectionAndBackupExclusion", runtime)
        self.assertIn("pendingThumbnailURL", runtime)
        self.assertIn("ambiguousThumbnailURL", runtime)
        self.assertIn("reportOnlyThumbnailURL", runtime)
        self.assertIn("recoveredWithoutPreview", runtime)

    def test_memory_action_has_visible_result_and_remains_available_during_sync(self) -> None:
        model = source("NekoWidget/ViewModels/MomentSharingViewModel.swift")
        family = source("NekoWidget/Views/FamilyWindowView.swift")

        self.assertIn("memoryActionMessage", model)
        self.assertIn("思い出に残しました", model)
        self.assertIn("family-window-bookmark-result", family)
        self.assertIn('Label("思い出に残した", systemImage: "bookmark.fill")', family)
        set_action = section(
            model,
            "func setSavedMemory(_ item: MomentInboxItem, isSaved: Bool) async",
            "private func showMemoryActionMessage",
        )
        self.assertIn(
            "guard !isPerformingAction, !isShowingLastKnownState, !isReportOnly",
            set_action,
        )
        self.assertNotIn("guard !isWorking", set_action)
        memory_control = section(
            family,
            "private func memoryActionControl(",
            "private func performMemoryAction(",
        )
        self.assertIn("model.isPerformingAction", memory_control)
        self.assertIn("model.isShowingLastKnownState", memory_control)
        self.assertIn("model.isReportOnly", memory_control)
        self.assertIn(".frame(width: 44, height: 44)", memory_control)
        self.assertNotIn(".disabled(model.isWorking)", memory_control)

        for start, end in (
            ("func discardFailedOutbox() async", "func discardPendingOutbox() async"),
            ("func clearOutgoingOutcomes() async", "func imageURL(for item"),
        ):
            local_cleanup = section(model, start, end)
            self.assertIn("guard !isPerformingAction", local_cleanup)
            self.assertNotIn("guard !isWorking", local_cleanup)

    def test_last_known_family_window_snapshot_is_fully_read_only(self) -> None:
        model = source("NekoWidget/ViewModels/MomentSharingViewModel.swift")
        family = source("NekoWidget/Views/FamilyWindowView.swift")

        for start, end in (
            ("func report(", "func block("),
            ("func block(", "func isSavedMemory("),
            ("func discardFailedOutbox() async", "func discardPendingOutbox() async"),
            ("func discardPendingOutbox() async", "func discardPendingPreparations() async"),
            ("func discardPendingPreparations() async", "func clearOutgoingOutcomes() async"),
            ("func clearOutgoingOutcomes() async", "func imageURL(for item"),
        ):
            mutation = section(model, start, end)
            self.assertIn("!isShowingLastKnownState", mutation)

        report_eligibility = section(
            model,
            "func canSubmitReport(_ item: MomentInboxItem) -> Bool",
            "func reportStatusText(",
        )
        self.assertIn("!isShowingLastKnownState", report_eligibility)

        display_name_reload = section(
            model,
            "func reloadWindowDisplayName()",
            "func reloadContentFromDisk()",
        )
        self.assertIn(
            "guard !isShowingLastKnownState else { return }",
            display_name_reload,
        )

        self.assertIn(".onChange(of: model.isShowingLastKnownState)", family)
        stale_reset = section(
            family,
            ".onChange(of: model.isShowingLastKnownState)",
            "private func temporarilyUnavailableContent",
        )
        for pending_mutation in (
            "reportTarget = nil",
            "blockTarget = nil",
            "showsPendingCancelConfirmation = false",
            "showsPreparationCancelConfirmation = false",
            "showsTerminalResultDismissConfirmation = false",
            "widgetMemoryTarget = nil",
        ):
            self.assertIn(pending_mutation, stale_reset)

        outgoing_menu = section(
            family,
            "private var outgoingManagementMenu: some View",
            "private func sentRecordCard(",
        )
        self.assertIn(".disabled(model.isShowingLastKnownState)", outgoing_menu)
        hidden_card = section(
            family,
            "private func safetyHiddenCard(",
            "private var privacyDisclosure",
        )
        self.assertIn(".disabled(model.isShowingLastKnownState)", hidden_card)

    def test_window_selection_refreshes_catalog_before_cached_guards(self) -> None:
        model = source("NekoWidget/ViewModels/PairingViewModel.swift")
        create = section(
            model,
            "func createAnotherPrivateWindow() async",
            "func activatePrivateWindow(localWindowID: String) async",
        )
        self.assertLess(
            create.index("reloadPrivateWindowCatalog()"),
            create.index("guard canCreateAnotherPrivateWindow else {"),
        )

        activate = section(
            model,
            "func activatePrivateWindow(localWindowID: String) async",
            "private func applyActivatedWindow(",
        )
        self.assertLess(
            activate.index("reloadPrivateWindowCatalog()"),
            activate.index("guard localWindowID != activePrivateWindowID else { return }"),
        )

    def test_draft_window_name_and_initial_product_limit_are_explicit(self) -> None:
        container = source("Shared/AppGroup/SharedContainer.swift")
        model = source("NekoWidget/ViewModels/PairingViewModel.swift")
        pairing = source("NekoWidget/Views/PairingView.swift")
        main_tab = source("NekoWidget/Views/MainTabView.swift")
        installation = source("NekoWidget/Services/PairingInstallationGuard.swift")

        self.assertIn("maximumWindowCount = 20", container)
        self.assertIn("maximumProductWindowCount = 3", container)
        self.assertIn("updateActiveDraftDisplayNameWhileLifecycleLocked", container)
        self.assertIn("case setupWindowAlreadyExists", container)
        self.assertIn("validateDisplayNameAvailableForActiveWindowWhileLifecycleLocked", container)
        create_window = section(
            installation,
            "static func createAndActivatePrivateWindow() throws",
            "static func createAndActivatePrivateWindowAsync()",
        )
        self.assertIn("pairing.phase == .paired", create_window)
        self.assertIn("setupWindowAlreadyExists", create_window)
        self.assertIn("Self.isLocalWindowNameDraft(operation.expectedState)", model)
        self.assertIn("PairingStateStore.updateActiveDraftDisplayName", model)
        self.assertIn("canPersistWindowDisplayName", model)
        self.assertIn("model.shouldShowWindowName", pairing)
        self.assertIn("expectedCredentialAccount: String?", container)
        self.assertNotIn("PairingState", section(
            container,
            "static func updateActiveDraftDisplayNameWhileLifecycleLocked(",
            "static func validateDisplayNameAvailableForActiveWindowWhileLifecycleLocked(",
        ))
        self.assertIn("state.windows[index].spaceID == nil", container)
        pairing_store = source("Shared/Sharing/PairingKeychainStore.swift")
        draft_save = section(
            pairing_store,
            "static func updateActiveDraftDisplayName(",
            "private static func saveCASWhileLifecycleLocked(",
        )
        self.assertIn("current == expected", draft_save)
        self.assertIn("current.role == .inviter", draft_save)
        self.assertIn("current.spaceID == nil", draft_save)
        low_level_create = section(
            container,
            "static func createAndActivateWhileLifecycleLocked(",
            "private static func nextDefaultDisplayName(",
        )
        self.assertIn("maximumWindowCount", low_level_create)
        self.assertNotIn("maximumProductWindowCount", low_level_create)
        self.assertIn("maximumProductWindowCount", create_window)
        self.assertIn('Text("名前を保存")', pairing)
        save_name = section(
            pairing,
            "private func saveWindowNameIfPossible() async -> Bool",
            "private var utcBoundaryMinute",
        )
        self.assertNotIn("spaceID", save_name)
        self.assertNotIn("participantID", save_name)
        self.assertIn("window-list-setup-limit", main_tab)
        self.assertIn("window-list-product-limit", main_tab)

    def test_cat_profile_detail_has_one_photo_addition_entry(self) -> None:
        profile = source("NekoWidget/Views/CatProfilePhotoCurationViews.swift")
        detail = section(
            profile,
            "struct CatProfileDetailView: View",
            "private struct CatProfilePhotoSourcesView: View",
        )
        sources = section(
            profile,
            "private struct CatProfilePhotoSourcesView: View",
            "private struct CatProfilePhotoAlbumSelectionView: View",
        )
        self.assertEqual(detail.count('Text("写真を追加")'), 1)
        self.assertIn('"この子の写真を見る"', detail)
        self.assertIn('Text("この子の時間")', detail)
        self.assertIn('Text("アプリで写真を選ぶ")', sources)
        self.assertIn('Text("写真アプリのアルバムをつなぐ")', sources)

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
        self.assertEqual(paired.count("sendPhotoAction"), 1)
        self.assertLess(
            paired.index("sendPhotoAction"),
            paired.index('Picker("まどに表示する内容"'),
        )

        received_start = paired.index(
            "if model.isReportOnly || selectedSection == .received {"
        )
        sent_start = paired.index("} else {", received_start)
        received_branch = paired[received_start:sent_start]
        sent_branch = paired[sent_start:]

        self.assertIn("receivedSectionContent", received_branch)
        self.assertNotIn("sendPhotoAction", received_branch)
        self.assertIn("sentSectionContent", sent_branch)
        self.assertNotIn("sendPhotoAction", sent_branch)
        self.assertNotIn("prioritizesNotificationTarget", family)
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
        self.assertNotIn("family-window-send-guide", family)
        self.assertNotIn('Text("ほかの送り方")', paired)
        self.assertIn("family-window-widget-guide", family)
        self.assertIn("ウィジェットの表示", family)
        self.assertIn("ウィジェットを編集", family)
        privacy = section(
            family,
            "private var privacyDisclosure: some View",
            "private var trustLinks: some View",
        )
        self.assertIn("DisclosureGroup", privacy)

        self.assertIn("enum FamilyWindowInitialPresentation", family)
        self.assertIn("case settings", family)
        self.assertIn("initialPresentation == .settings", family)
        self.assertIn("windowSettingsContent", family)
        self.assertLess(
            family.index("if !model.isPaired"),
            family.index("initialPresentation == .settings"),
        )

    def test_family_window_photo_and_memory_actions_match_the_ui_contract(self) -> None:
        family = source("NekoWidget/Views/FamilyWindowView.swift")

        compact = section(
            family,
            "private func compactMomentCard(",
            "private func sharingErrorCard(",
        )
        self.assertIn("receivedPhotoSurface(", compact)
        self.assertIn("aspectRatio: 1", compact)
        self.assertIn("contentMode: .fill", compact)
        self.assertIn("receivedPhotoPlaceholder(aspectRatio: 1)", compact)
        self.assertNotIn(".aspectRatio(1, contentMode: .fill)", compact)

        received_section = section(
            family,
            "@ViewBuilder\n    private var receivedSectionContent",
            "@ViewBuilder\n    private var sentSectionContent",
        )
        self.assertIn("columns: receivedPhotoColumns", received_section)
        received_columns = section(
            family,
            "private var receivedPhotoColumns:",
            "@ViewBuilder\n    private var manualRefreshResult",
        )
        self.assertIn("dynamicTypeSize.isAccessibilitySize ? 1 : 2", received_columns)
        self.assertIn("GridItem(.flexible(minimum: 0)", received_columns)

        primary = section(
            family,
            "private func momentCard(",
            "private func memoryActionControl(",
        )
        self.assertIn("receivedPhotoSurface(", primary)
        self.assertIn("aspectRatio: 4.0 / 3.0", primary)
        self.assertIn("contentMode: .fit", primary)
        self.assertIn(
            "receivedPhotoPlaceholder(aspectRatio: 4.0 / 3.0)",
            primary,
        )
        self.assertNotIn(".frame(height: 280)", primary)
        self.assertNotIn("maxHeight: 520", primary)

        surface = section(
            family,
            "private func receivedPhotoSurface(",
            "@ViewBuilder\n    private func memoryActionControl(",
        )
        self.assertIn(".frame(maxWidth: .infinity, maxHeight: .infinity)", surface)
        self.assertIn(".aspectRatio(aspectRatio, contentMode: .fit)", surface)
        self.assertIn(".clipped()", surface)

        local_image = section(
            family,
            "struct MomentLocalImageView:",
            "private struct MomentDownsampledImage:",
        )
        self.assertIn("@State private var loadFailed = false", local_image)
        self.assertIn("} else if loadFailed {", local_image)
        self.assertIn("guard let rendered else {", local_image)
        self.assertIn("loadFailed = true", local_image)

        memory = section(
            family,
            "private func memoryActionControl(",
            "private func performMemoryAction(",
        )
        self.assertIn("if model.isSavedMemory(item)", memory)
        self.assertIn('Label("思い出に残した", systemImage: "bookmark.fill")', memory)
        self.assertIn('Button("思い出から外す", role: .destructive)', memory)
        self.assertIn("memoryRemovalTarget = item", memory)
        self.assertIn("widgetMemoryTarget = item", memory)
        self.assertIn("model.isShowingLastKnownState", memory)
        self.assertIn("model.isReportOnly", memory)

        self.assertIn("写真アプリへコピーして、思い出に加えます", family)
        self.assertIn("iCloud写真の設定により、iCloudにも同期される場合があります", family)
        self.assertIn("if model.hasImportedMemory(item)", family)
        self.assertIn("写真アプリへコピーした写真は削除されません", family)
        self.assertNotIn("ReceivedPhotoFilter", family)
        self.assertNotIn("family-window-photo-filter", family)
        self.assertIn("private var orderedReceivedMoments", family)
        self.assertIn('"接続状態を確認できません"', family)

        pending_widget = section(
            family,
            "private func consumePendingMemoryTargetIfReady()",
            "private func consumePendingNotificationRoute()",
        )
        self.assertLess(
            pending_widget.index("if !model.isSavedMemory(target)"),
            pending_widget.index("widgetMemoryTarget = target"),
        )

        sent = section(
            family,
            "private func sentRecordCard(",
            "private func outgoingStatusCard(",
        )
        self.assertIn("sentRecordPhotoSurface(record)", sent)
        self.assertIn('arrived ? "到着" : "受付済み"', sent)
        self.assertIn('sentRecordBadge("ハート", systemImage: "heart.fill")', sent)
        self.assertIn("private func sentRecordBadge(", sent)
        self.assertIn(".font(.caption2.bold())", sent)
        self.assertIn(".background(.black.opacity(0.48), in: Capsule())", sent)

        sent_photo = section(
            family,
            "private func sentRecordPhotoSurface(",
            "private func sentRecordAccessibilityLabel(",
        )
        self.assertIn("if let thumbnail = sentRecordThumbnail(record)", sent_photo)
        self.assertIn(".scaledToFill()", sent)
        self.assertIn('Text("送信履歴のみ\\n画像はありません")', sent_photo)
        self.assertIn(".aspectRatio(1, contentMode: .fit)", sent_photo)
        self.assertNotIn(".frame(width: 72, height: 72)", sent)
        self.assertNotIn("LazyVStack", sent)
        self.assertNotIn("閲覧・既読の確認ではありません", sent)
        self.assertIn("sentRecordAccessibilityLabel(record)", sent)
        self.assertIn("accessibilityElement(children: .ignore)", sent)

        actions = section(
            family,
            "private func receivedPhotoActionControls(",
            "private func receivedPhotoSurface(",
        )
        self.assertIn("AnyLayout(VStackLayout", actions)
        self.assertIn("AnyLayout(HStackLayout", actions)
        self.assertIn("minHeight: 44", actions)
        self.assertIn("notificationAccessibilityFocus = momentID", family)

    def test_host_photo_picker_uses_the_existing_bounded_handoff(self) -> None:
        family = source("NekoWidget/Views/FamilyWindowView.swift")
        model = source("NekoWidget/ViewModels/MomentSharingViewModel.swift")
        ingress = source("NekoWidgetShareExtension/MomentShareIngressService.swift")
        project = source("NekoWidget.xcodeproj/project.pbxproj")

        self.assertIn("PhotosPicker(", family)
        self.assertIn('"写真を選んで届ける"', family)
        self.assertIn("deliveryConfirmation", family)
        self.assertIn("type: PickedMomentIngressPhoto.self", family)
        self.assertNotIn("loadTransferable(type: Data.self)", family)
        self.assertIn("to: delivery.destination", family)
        self.assertIn("func deliverSelectedPhoto(", model)
        self.assertIn("func deliveryDestinationSnapshot()", model)
        self.assertIn(
            "catalog.activeWindowID == confirmedDestination.localWindowID",
            model,
        )
        self.assertIn(
            "admission.bindingSHA256 == confirmedDestination.bindingSHA256",
            model,
        )
        self.assertIn("refreshAdmissionCatalog(", model)
        self.assertIn("MomentShareIngressService().stage(", model)
        delivery = section(
            model,
            "func deliverSelectedPhoto(",
            "func report(",
        )
        self.assertLess(delivery.index("didStage = true"), delivery.index("try reload()"))
        self.assertIn("Staging already committed a unique durable capture", delivery)
        self.assertIn("func prepare(fromFileURL url: URL)", ingress)
        self.assertIn("try Self.canonicalPhoto(from: url)", ingress)

        app_sources = section(
            project,
            "A00000000000000000000021 /* Sources */ = {",
            "A00000000000000000000025 /* Sources */",
        )
        self.assertIn("MomentShareIngressService.swift in Sources", app_sources)

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
            "func setSavedMemory(",
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
        self.assertIn('Label("思い出に残した", systemImage: "bookmark.fill")', family)
        self.assertIn('Button("思い出から外す", role: .destructive)', family)
        self.assertIn('"取り込んで残す"', family)
        self.assertIn('"写真アプリにコピーして残す"', family)
        self.assertIn("通常の思い出と写真まとめに入り", family)
        self.assertIn("相手へは通知しません", family)
        self.assertIn("アプリ削除のあとも写真アプリに残ります", family)
        self.assertNotIn('Label("写真アプリへコピー"', family)
        self.assertNotIn("ReceivedPhotoFilter", family)

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
        main_tab = source("NekoWidget/Views/MainTabView.swift")
        self.assertIn("相手と接続済み", pairing)
        self.assertNotIn("2人のまどを設定済み", pairing)
        self.assertIn("一時的な届いた写真", pairing)
        self.assertIn("写真アプリへ保存した思い出は残ります", pairing_model)
        self.assertIn("FamilyWindowView(", main_tab)
        self.assertIn('Label("まど", systemImage: "rectangle.split.2x2")', main_tab)
        self.assertNotIn("届いた写真の履歴", main_tab)

    def test_temporary_pairing_storage_failure_has_one_retry_path(self) -> None:
        sharing_model = source("NekoWidget/ViewModels/MomentSharingViewModel.swift")
        bootstrap = section(
            sharing_model,
            "func bootstrap() async",
            "func retryBootstrap() async",
        )
        self.assertIn("bootstrapPresentationState = .ready", bootstrap)
        self.assertIn("if pairingState != nil", bootstrap)
        self.assertIn("isShowingLastKnownState = true", bootstrap)
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
        self.assertEqual(unavailable.count("NavigationLink"), 1)
        self.assertIn("await model.retryBootstrap()", unavailable)
        self.assertIn("保存済みの写真と接続情報は削除していません", unavailable)
        self.assertIn("LogView()", unavailable)
        self.assertIn("ScrollView", unavailable)
        self.assertIn("DisclosureGroup", unavailable)
        self.assertIn(".scrollBounceBehavior(.basedOnSize)", unavailable)
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
        self.assertEqual(retry_section.count("NavigationLink"), 1)
        self.assertIn("await model.bootstrap()", retry_section)
        self.assertIn("if model.isBootstrapping", retry_section)
        self.assertIn("接続情報を確認しています…", retry_section)
        self.assertIn("保存済みの写真と接続情報は削除していません", retry_section)
        self.assertIn("LogView()", retry_section)
        self.assertNotIn("setupChoiceSection", retry_section)

    def test_widget_placement_guide_is_compact_and_auto_closes_after_install(self) -> None:
        guide = source("NekoWidget/Views/WidgetPlacementGuideView.swift")
        presentation = source("NekoWidget/Views/OnboardingPresentation.swift")
        app_root = source("NekoWidget/App/AppRootView.swift")
        checker = source("NekoWidget/Services/WidgetInstallationChecker.swift")

        self.assertNotIn("TabView(selection:", guide)
        self.assertNotIn("selectedStep", guide)
        self.assertIn("widgetModernPlacementSteps", guide)
        self.assertIn("widgetLegacyPlacementSteps", guide)
        self.assertIn("if #available(iOS 18.0, *)", guide)
        self.assertIn('"widget-placement-steps"', guide)
        self.assertIn('"手順を確認した"', presentation)
        self.assertIn('"追加してアプリへ戻ると、自動で確認します。"', presentation)
        self.assertIn(
            ".onChange(of: widgetInstallationChecker.isInstalled, initial: true)",
            app_root,
        )
        self.assertIn(
            ".onChange(of: onboardingState.currentPage, initial: true)",
            app_root,
        )
        self.assertIn("guard page == .widgetGuide,", app_root)
        self.assertIn("widgetInstallationChecker.isInstalled else { return }", app_root)
        completion = section(
            app_root,
            "private func completeWidgetPlacementGuideIfNeeded()",
            "@MainActor\nprivate final class PhotoPresentationCache",
        )
        self.assertIn("showsWidgetPlacementGuide = false", completion)
        self.assertIn("guard state.currentPage == .widgetGuide else { return }", completion)
        self.assertIn("state.advance()", completion)
        self.assertIn("WidgetCenter.shared.getCurrentConfigurations", checker)

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
