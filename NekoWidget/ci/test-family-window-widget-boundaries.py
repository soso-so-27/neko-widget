from pathlib import Path
import subprocess
import sys
import tempfile
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def section(value: str, start: str, end: str) -> str:
    start_index = value.index(start)
    end_index = value.index(end, start_index)
    return value[start_index:end_index]


class FamilyWindowWidgetBoundaryTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin", "Requires macOS Foundation /private aliases")
    def test_sent_thumbnail_paths_accept_missing_private_alias_children(self) -> None:
        store = source("Shared/Sharing/MomentSharingStore.swift")
        helpers = section(
            store,
            "private static func localThumbnailURL(fileName: String)",
            "/// A reservation is only an upload lease.",
        )
        filename = section(
            store,
            "static func localThumbnailFileName(for id: UUID)",
            "static func isValidLocalThumbnail",
        )
        # Compile the shipping path helpers themselves, with only their App
        # Group destination and unrelated model dependencies supplied here.
        swift = (
            "import Foundation\nimport Darwin\n"
            "enum MomentSharingError: Error { case stateUnavailable }\n"
            "enum SharedContainer { static var momentSharingSentThumbnailDirectoryURL: URL? { "
            "URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) } }\n"
            "enum MomentOutboxItem {\n" + filename + "\n}\n"
            "enum MomentSharingStateStore {\n" + helpers + r'''
    static func verifyPrivateAlias() throws {
        let manager = FileManager.default
        let leaf = SharedContainer.momentSharingSentThumbnailDirectoryURL!
        let parent = leaf.deletingLastPathComponent()
        let root = parent.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let name = MomentOutboxItem.localThumbnailFileName(for: UUID())

        // Frozen expressions from the defective implementation prove that
        // existing-parent/missing-child standardization disagrees on this OS.
        precondition(leaf.standardizedFileURL.deletingLastPathComponent()
            != parent.standardizedFileURL, "Legacy missing-leaf comparison must reproduce")
        _ = try localThumbnailURL(fileName: name)
        try manager.createDirectory(at: leaf, withIntermediateDirectories: false)
        precondition(leaf.appendingPathComponent(name, isDirectory: false)
            .standardizedFileURL.deletingLastPathComponent()
            != leaf.standardizedFileURL, "Legacy missing-file comparison must reproduce")
        let firstURL = try localThumbnailURL(fileName: name)
        let bytes = Data([0x51, 0x52, 0x53])
        try bytes.write(to: firstURL)
        let existingURL = try localThumbnailURL(fileName: name)
        let reloaded = try Data(contentsOf: existingURL)
        precondition(reloaded == bytes,
            "The newly created file must remain readable through the same helper")

        func requireRejected(_ filename: String) throws {
            var rejected = false
            do { _ = try localThumbnailURL(fileName: filename) }
            catch MomentSharingError.stateUnavailable { rejected = true }
            precondition(rejected, "Unsafe thumbnail path must remain rejected")
        }
        try requireRejected("../" + name)
        let target = root.appendingPathComponent("symlink-target", isDirectory: true)
        try manager.createDirectory(at: target, withIntermediateDirectories: false)
        let sentinel = target.appendingPathComponent("sentinel", isDirectory: false)
        try bytes.write(to: sentinel)
        try manager.removeItem(at: existingURL)
        try manager.createSymbolicLink(at: existingURL, withDestinationURL: sentinel)
        try requireRejected(name)
        try manager.removeItem(at: existingURL)
        try manager.removeItem(at: leaf)
        try manager.createSymbolicLink(at: leaf, withDestinationURL: target)
        try requireRejected(name)
        try manager.removeItem(at: leaf)
        try manager.removeItem(at: parent)
        try manager.createSymbolicLink(at: parent, withDestinationURL: target)
        try requireRejected(name)
        let retainedSentinel = try Data(contentsOf: sentinel)
        precondition(retainedSentinel == bytes,
            "Rejected links must not change their destination")
        print("sent-thumbnail-private-alias: legacy-comparisons-reproduced, creation-readable, symlinks-rejected")
    }
}
try MomentSharingStateStore.verifyPrivateAlias()
'''
        )
        with tempfile.TemporaryDirectory(prefix="neko-sent-thumbnail-", dir="/private/tmp") as temporary:
            script = Path(temporary) / "verify.swift"
            script.write_text(swift, encoding="utf-8")
            result = subprocess.run(
                ["xcrun", "swift", str(script), str(Path(temporary) / "sharing" / "sent-moment-thumbnails")],
                capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout.strip())

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
        self.assertIn("familyActionsRequireApp: familyWindowIsInactive", family_entry)

        view = source("NekoWidgetWidget/NekoWidgetView.swift")
        # Photo navigation and the explicit heart remain separate. A received
        # photo's bookmark only opens the app, which confirms the Photos copy.
        self.assertEqual(view.count(".widgetURL(entry.photoURL)"), 1)
        for removed_control in (
            "familyMemoryControl", "openInAppLabel",
            "ToggleFamilyWidgetBookmarkIntent",
        ):
            self.assertNotIn(removed_control, view)
        self.assertEqual(view.count("Link(destination:"), 1)

        shortcut = section(view, "private var familyHeartShortcut: some View", "private func familyHeartControl(")
        self.assertIn("let sourceDigest = entry.familySourceDigest", shortcut)
        self.assertIn("let localWindowID = WidgetPhotoSource.localWindowID(", shortcut)
        self.assertIn("entry.isBookmarkInteractionEnabled", shortcut)
        self.assertIn("unavailableHeartSlot", shortcut)
        heart_control = section(view, "private func familyHeartControl(", "private var unavailableHeartSlot: some View")
        ready = section(heart_control, "case .ready:", "case .pending:")
        self.assertIn("SendFamilyWidgetHeartIntent(", ready)
        self.assertIn("sourceDigest: sourceDigest", ready)
        self.assertIn("localWindowID: localWindowID", ready)
        pending = section(heart_control, "case .pending:", "case .serverAccepted:")
        self.assertIn("Button(", pending)
        self.assertIn("SendFamilyWidgetHeartIntent(", pending)
        self.assertIn("sourceDigest: sourceDigest", pending)
        self.assertIn("localWindowID: localWindowID", pending)
        self.assertEqual(heart_control.count("Button("), 2)
        self.assertNotIn("Button(", heart_control.split("case .serverAccepted:", 1)[1])
        self.assertIn('"ハートはまだ送れていません"', heart_control)
        self.assertIn('"相手が見たかどうかは分かりません"', heart_control)
        self.assertIn("case .hidden:\n            unavailableHeartSlot", heart_control)
        unavailable = section(view, "private var unavailableHeartSlot: some View", "private func heartMark(")
        self.assertIn(".frame(width: 44, height: 44)", unavailable)
        self.assertIn(".allowsHitTesting(false)", unavailable)
        self.assertIn(".accessibilityHidden(true)", unavailable)
        heart_mark = section(view, "private func heartMark(", "private var familyMemoryShortcut: some View")
        self.assertIn('status == .serverAccepted ? "heart.fill" : "heart"', heart_mark)
        self.assertIn('Image(systemName: "clock.fill")', heart_mark)
        self.assertIn(".frame(width: 44, height: 44)", heart_mark)
        self.assertIn(".contentShape(Rectangle())", heart_mark)

        photo_actions = section(
            view,
            "private func photoActionButtons() -> some View",
            "private func actionTray<Content: View>(",
        )
        self.assertIn(
            "entry.photoSourceIdentifier == WidgetPhotoSource.personalLibraryID",
            photo_actions,
        )
        self.assertIn("let localIdentifier = entry.localIdentifier", photo_actions)
        self.assertIn("entry.isLikeInteractionEnabled", photo_actions)
        self.assertIn("if entry.isLiked {", photo_actions)
        self.assertIn("memoryMark(isSelected: true)", photo_actions)
        self.assertIn("ToggleWidgetLikeIntent(", photo_actions)
        self.assertIn("fallbackIsLiked: false", photo_actions)
        self.assertIn("memoryMark(isSelected: false, invalidatesContent: true)", photo_actions)
        self.assertIn('"お気に入りの写真"', photo_actions)
        self.assertIn('"お気に入りに追加"', photo_actions)
        self.assertNotIn("isFamilyWindowSourceID", photo_actions)
        self.assertNotIn("familyActionsRequireApp", photo_actions)

        memory_mark = section(
            view, "private func memoryMark(", "private var actionButtonSpacing: CGFloat",
        )
        self.assertIn('isSelected ? "bookmark.fill" : "bookmark"', memory_mark)
        self.assertIn(".frame(width: 44, height: 44)", memory_mark)
        self.assertIn(".contentShape(Rectangle())", memory_mark)
        self.assertIn(".buttonStyle(.plain)", photo_actions)
        self.assertNotIn('entry.isLiked ? "お気に入りから外す"', view)

        action_tray = section(
            view,
            "private func actionTray<Content: View>(",
            "/// The private-memory control",
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

        # Supplementary text belongs only to a successfully decoded shared
        # photo; the image alone owns navigation and full-text accessibility.
        loaded = section(view, "let image = WidgetCacheImageLoader.image(", "                emptyState")
        self.assertIn("} else if isWindowPhoto {", loaded)
        window_photo = section(view, "private var isWindowPhoto: Bool", "private var familyCaption: String?")
        self.assertIn("WidgetPhotoSource.isFamilyWindowSourceID(entry.photoSourceIdentifier)", window_photo)
        self.assertIn("GroupWidgetCache.isGroupSourceID(entry.photoSourceIdentifier)", window_photo)
        self.assertIn("familyPhotoFooter", loaded)
        self.assertIn("} else {\n                            photoActionButtons()", loaded)
        self.assertEqual(view.count("                            familyPhotoFooter"), 1)
        self.assertEqual(view.count(".accessibilityLabel(loadedPhotoAccessibilityLabel)"), 1)
        accessibility_label = section(
            view, "private var loadedPhotoAccessibilityLabel: String", "private var familyPhotoFooter: some View",
        )
        self.assertIn("entry.windowDisplayName", accessibility_label)
        self.assertIn("familyCaption.map", accessibility_label)
        self.assertNotIn(".prefix(", accessibility_label)

        footer = section(view, "private var familyPhotoFooter: some View", "private var familyFooterText: some View")
        self.assertIn("ZStack(alignment: .bottom)", footer)
        self.assertEqual(footer.count(".padding(.horizontal, footerInset)"), 2)
        self.assertEqual(footer.count(".padding(.bottom, footerInset)"), 2)
        # The band is sized by a hidden copy of the text alone, never by the
        # 44pt controls, and it never sits on the HStack that holds the heart.
        self.assertEqual(footer.count(".background {"), 1)
        self.assertIn(".hidden()", footer)
        self.assertIn("footerBand(fadeHeight: familyCaption == nil ? 16 : 26)", footer)
        self.assertLess(footer.index(".hidden()"), footer.index(".background {"))
        self.assertLess(footer.index(".background {"), footer.index("HStack(alignment: .bottom, spacing: 6)"))
        self.assertNotIn("LinearGradient(", footer)
        self.assertNotIn("minHeight", footer)
        # Small: name bottom-left (no bookmark exists), heart on the free right
        # side so the name never shifts when a heart appears or expires.
        small = section(footer, "if family == .systemSmall {", "} else {")
        self.assertLess(small.index("familyFooterText"), small.index("familyHeartShortcut"))
        self.assertNotIn("familyMemoryShortcut", small)
        # Larger: heart bottom-left, bookmark bottom-right, decorative text between.
        larger = section(footer, "} else {", "        .frame(maxWidth: .infinity)")
        self.assertLess(larger.index("familyHeartShortcut"), larger.index("familyFooterText"))
        self.assertLess(larger.index("familyFooterText"), larger.index("familyMemoryShortcut"))
        # Hit testing and AX exclusion must end at the decorative text or
        # band, never at the footer that contains the heart Button.
        self.assertNotIn(".allowsHitTesting", footer)
        self.assertNotIn(".accessibilityHidden", footer)
        self.assertTrue(footer.rstrip().endswith("}\n    }"))
        text = section(view, "private var familyFooterText: some View", "/// Fades in over the photo")
        self.assertIn("VStack(alignment: footerTextAlignment.horizontal, spacing: 4)", text)
        self.assertIn("if let caption = familyCaption", text)
        self.assertLess(text.index("familyCaptionPreview(caption)"), text.index("familySourceLabel"))
        self.assertIn(".padding(.bottom, footerTextBottomInset)", text)
        self.assertIn(".frame(maxWidth: .infinity, alignment: footerTextAlignment)", text)
        self.assertNotIn("minHeight", text)
        self.assertIn(".allowsHitTesting(false)", text)
        self.assertIn(".accessibilityHidden(true)", text)
        self.assertNotIn("Button(", text)
        self.assertNotIn("Link(", text)
        band = section(view, "private func footerBand(fadeHeight: CGFloat) -> some View", "private let footerInset")
        self.assertIn("colors: [.clear, .black.opacity(0.60)]", band)
        self.assertIn("colors: [.black.opacity(0.60), .black.opacity(0.63)]", band)
        self.assertIn(".frame(height: fadeHeight)", band)
        self.assertIn(".padding(.top, -fadeHeight)", band)
        self.assertIn(".allowsHitTesting(false)", band)
        self.assertIn(".accessibilityHidden(true)", band)
        self.assertIn("private let footerInset: CGFloat = 12", view)
        self.assertIn("private let footerTextBottomInset: CGFloat = 7", view)
        helpers = section(view, "private var footerTextAlignment: Alignment", "private var familyHeartShortcut: some View")
        self.assertEqual(helpers.count("family == .systemSmall ? .leading : .center"), 2)
        # An official window's name uses the window name's type, inset and
        # band, so two Small Widgets side by side line up.
        official = section(view, "} else if let photo = entry.officialPhoto {", "} else if isWindowPhoto {")
        self.assertIn("Text(photo.catName)", official)
        self.assertIn(".font(.caption2)", official)
        self.assertIn(".foregroundStyle(.white.opacity(0.92))", official)
        self.assertIn(".padding(.bottom, footerTextBottomInset)", official)
        self.assertIn(".padding(.horizontal, footerInset)", official)
        self.assertIn(".padding(.bottom, footerInset)", official)
        self.assertIn(".multilineTextAlignment(footerTextLineAlignment)", official)
        self.assertIn(".frame(maxWidth: .infinity, alignment: footerTextAlignment)", official)
        self.assertNotIn("alignment: .leading", official)
        self.assertIn(".background { footerBand(fadeHeight: 16) }", official)
        self.assertNotIn("LinearGradient(", official)
        self.assertNotIn("Button(", official)
        memory_shortcut = section(view, "private var familyMemoryShortcut: some View", "private func familyCaptionPreview(")
        self.assertIn("if family != .systemSmall {", memory_shortcut)
        self.assertEqual(memory_shortcut.count("entry.isBookmarkInteractionEnabled"), 2)
        self.assertIn("entry.isBookmarked", memory_shortcut)
        self.assertIn("memoryMark(isSelected: true)", memory_shortcut)
        self.assertIn("Link(destination: memoryActionURL)", memory_shortcut)
        self.assertIn("let memoryActionURL = entry.memoryActionURL", memory_shortcut)
        self.assertIn("memoryMark(isSelected: false)", memory_shortcut)
        self.assertIn('"お気に入りに追加"', memory_shortcut)
        self.assertIn('"アプリを開いて、お気に入りに追加します"', memory_shortcut)
        self.assertIn("unavailableHeartSlot", memory_shortcut)
        # The Widget never saves a received photo or sends anything itself.
        self.assertNotIn("Button(", memory_shortcut)
        self.assertNotIn("intent:", memory_shortcut)
        self.assertNotIn("Button(", footer)
        self.assertNotIn("Link(", footer)

        caption = section(view, "private func familyCaptionPreview(", "private func photoActionButtons()")
        name = section(view, "private var familySourceLabel: some View", "private var actionButtonSpacing: CGFloat")
        self.assertIn(".font(.caption)", caption)
        self.assertIn(".lineLimit(family == .systemLarge ? 2 : 1)", caption)
        self.assertIn("Text(entry.windowDisplayName)", name)
        self.assertIn(".font(.caption2)", name)
        self.assertIn(".lineLimit(1)", name)
        for text_view in (caption, name):
            self.assertIn(".multilineTextAlignment(footerTextLineAlignment)", text_view)
            self.assertIn(".frame(maxWidth: .infinity, alignment: footerTextAlignment)", text_view)
            self.assertIn(".truncationMode(.tail)", text_view)
            self.assertNotIn(".background", text_view)
            self.assertNotIn(".accessibilityLabel", text_view)

        heart_intent = source("NekoWidgetWidget/ToggleWidgetLikeIntent.swift")
        self.assertIn("var localWindowID: String?", heart_intent)
        self.assertIn("static var openAppWhenRun = true", heart_intent)
        self.assertIn("guard let localWindowID", heart_intent)
        self.assertIn("localWindowID: localWindowID", heart_intent)
        self.assertIn("PrivateWindowCatalogStore.activeEntry()", heart_intent)
        self.assertIn("localWindowID: canonicalWindowID", heart_intent)

        # The exact durable request is sent by the background host, without
        # routing to a photo screen or giving the extension room credentials.
        send_heart = section(
            heart_intent,
            "struct SendFamilyWidgetHeartIntent",
            "private enum FamilyWidgetActionTargetResolver",
        )
        self.assertNotIn("MomentSharingStateStore.queuePaw", send_heart)
        self.assertNotIn(".sendQueuedWidgetHeart(", send_heart)
        self.assertNotIn("PairingKeychainStore", send_heart)
        self.assertIn('return .result(dialog:', send_heart)
        self.assertIn("static var openAppWhenRun = false", send_heart)

        project = source("NekoWidget.xcodeproj/project.pbxproj")
        app_debug = section(project, "A00000000000000000000052 /* Debug */ = {", "A00000000000000000000053 /* Release */ = {")
        app_release = section(project, "A00000000000000000000053 /* Release */ = {", "A00000000000000000000054 /* Debug */ = {")
        self.assertIn('SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) NEKO_HOST_APP";', app_debug)
        self.assertIn('SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) NEKO_HOST_APP";', app_release)
        self.assertEqual(project.count("NEKO_HOST_APP"), 2)

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
        self.assertIn("Text(emptyStateTitle)", empty_state)
        self.assertIn("Text(emptyStateSubtitle)", empty_state)
        self.assertIn(".lineLimit(2)", empty_state)
        self.assertIn(".minimumScaleFactor(0.75)", empty_state)
        self.assertNotIn("CatPawMark", empty_state)
        self.assertNotIn(".orange", empty_state)
        self.assertNotIn("スキャン", empty_state)
        self.assertNotIn("写真へのアクセス", empty_state)
        self.assertNotIn("更新してください", empty_state)

        empty_title = section(
            production_view,
            "private var emptyStateTitle: String",
            "private var emptyStateMarkSize: CGFloat",
        )
        self.assertIn('return "このまどは表示できません"', empty_title)
        self.assertIn('return "写真を待っています"', empty_title)
        self.assertNotIn('return "まだ届いていません"', empty_title)
        self.assertIn('return "写真を準備しています"', empty_title)
        self.assertIn('return "ウィジェットを編集してください"', empty_title)
        self.assertIn("return entry.windowDisplayName", empty_title)

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
            "private struct QuietWindowOpening: Shape",
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

    def test_family_widget_expires_and_removed_window_fails_closed(self) -> None:
        manifest = source("Shared/Models/WidgetManifest.swift")
        self.assertIn(
            "static let maximumDisplayDuration: TimeInterval = 90 * 24 * 60 * 60",
            manifest,
        )
        self.assertIn("var displayUntil: Date", manifest)
        self.assertIn("var heartExpiresAt: Date?", manifest)
        self.assertIn("var validHeartExpiry: Date?", manifest)

        reader = source("NekoWidgetWidget/WidgetManifestReader.swift")
        family_item = section(
            reader,
            "static func familyItem(",
            "static func familyWindowDisplayName",
        )
        self.assertIn("PrivateWindowCatalogStore.widgetEntries()", family_item)
        self.assertIn("now < item.displayUntil", family_item)
        self.assertNotIn("item.validHeartExpiry", family_item)

        empty_reason = section(
            reader,
            "static func familyEmptyStateReason(",
            "static func familyWindowDisplayName",
        )
        self.assertIn("return .needsApp", empty_reason)
        self.assertIn("guard let item = manifest.item else { return .waiting }", empty_reason)
        self.assertIn("guard now < item.displayUntil else { return .waiting }", empty_reason)

        provider = source("NekoWidgetWidget/NekoWidgetTimelineProvider.swift")
        self.assertIn("WidgetPhotoSource.familyWindowExists(for: source.id)", provider)
        self.assertIn("at: item.displayUntil", provider)
        self.assertIn("let heartExpiresAt = item.validHeartExpiry", provider)
        self.assertIn("policy = .after(heartExpiresAt)", provider)
        self.assertIn("emptyStateReason: .sourceUnavailable", provider)

        builder = source("NekoWidget/Services/WidgetCacheBuilder.swift")
        reuse = section(
            builder,
            "if let active = try? AtomicJSON.read(FamilyWidgetManifest.self",
            "let renderedFiles:",
        )
        self.assertIn("refreshedItem.heartExpiresAt != current.item.accessExpiresAt", reuse)
        self.assertIn("refreshedItem.heartExpiresAt = current.item.accessExpiresAt", reuse)
        self.assertIn("try Self.writeSharingJSON(refreshed, to: manifestURL)", reuse)
        self.assertIn("heartExpiresAt: current.item.accessExpiresAt", builder)

        entry = source("NekoWidgetWidget/NekoWidgetEntry.swift")
        self.assertIn("let emptyStateReason: WidgetEmptyStateReason", entry)
        reason = section(reader, "enum WidgetEmptyStateReason:", "enum WidgetManifestReader")
        self.assertEqual([line.strip().removeprefix("case ") for line in reason.splitlines()
                          if line.strip().startswith("case ")],
                         ["none", "waiting", "needsApp", "sourceUnavailable"])

        view = source("NekoWidgetWidget/NekoWidgetView.swift")
        self.assertIn('return "写真を表示できません"', view)
        self.assertIn('return "アプリを開いて更新"', view)
        self.assertIn("let image = WidgetCacheImageLoader.image(", view)
        empty = section(view, "private var emptyState: some View", "private var emptyStateTitle: String")
        self.assertNotIn("familyPhotoFooter", empty)
        self.assertNotIn("familySourceLabel", empty)
        self.assertNotIn("familyCaptionPreview", empty)

        configuration = source(
            "NekoWidgetWidget/NekoWidgetConfigurationIntent.swift"
        )
        resolved = section(
            configuration,
            "static func resolvedSource(id: String)",
            "static var availableSources",
        )
        self.assertIn('name: "使えなくなったまど"', resolved)
        self.assertIn("static func familyWindowExists", resolved)

        self.assertIn(
            "guard emptyStateReason != .sourceUnavailable else { return nil }",
            entry,
        )

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
        self.assertEqual(widget_view.count("Link(destination: memoryActionURL)"), 1)
        self.assertNotIn("Link(destination: entry.photoURL", widget_view)
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
        self.assertNotIn("MomentSharingStateStore.queuePaw", heart_intent)
        self.assertEqual(
            heart_intent.count('reloadTimelines(ofKind: "NekoWidget")'),
            1,
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
        self.assertNotIn("MomentSharingAPIClient.swift in Sources", widget_sources)
        self.assertNotIn("PairingKeychainStore.swift in Sources", widget_sources)

    def test_widget_heart_background_host_send_preserves_security_and_retry(self) -> None:
        store = source("Shared/Sharing/MomentSharingStore.swift")
        validation = section(store, "static func validatedQueuedPaw(", "private static func validatePawTarget(")
        self.assertIn("withStateWhileLifecycleLocked", validation)
        self.assertIn("validatePawTarget", validation)
        self.assertIn("$0.clientRequestID == clientRequestID && $0.momentID == momentID", validation)
        self.assertNotIn("mutate(", validation)
        self.assertNotIn("append(", validation)

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


        presentation = source("NekoWidget/Views/MomentSharingPresentation.swift")
        self.assertIn("let hasReceivedHeart: Bool", presentation)
        self.assertIn("hasReceivedHeart: delivery.hasReceivedHeart", presentation)




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




    def test_memory_actions_set_the_requested_state_without_toggling(self) -> None:
        home = source("NekoWidget/Views/HomeView.swift")
        browser = source("NekoWidget/Views/LikedPhotosView.swift")
        main_tab = source("NekoWidget/Views/MainTabView.swift")
        app_root = source("NekoWidget/App/AppRootView.swift")
        app_model = source("NekoWidget/ViewModels/AppViewModel.swift")

        self.assertNotIn("let setMemorySaved: (String, Bool) -> Void", home)
        self.assertNotIn("setMemorySaved(", home)
        self.assertNotIn("toggleLike", home)

        self.assertIn("let setMemorySaved: (String, Bool) -> Void", browser)
        self.assertIn("setMemorySaved(photo.localIdentifier, true)", browser)
        self.assertIn("setMemorySaved(photo.localIdentifier, false)", browser)
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


    def test_today_widget_and_memory_photo_contexts_remain_distinct(self) -> None:
        main = source("NekoWidget/Views/MainTabView.swift")
        browser = source("NekoWidget/Views/LikedPhotosView.swift")
        home = source("NekoWidget/Views/HomeView.swift")
        onboarding = source("NekoWidget/Views/OnboardingPresentation.swift")
        model = source("NekoWidget/ViewModels/AppViewModel.swift")

        today_detail = section(
            main,
            "private func detailView(for localIdentifier: String) -> some View",
            "private func memoryDetailView(for localIdentifier: String,",
        )
        self.assertIn("photos: [initialPhoto]", today_detail)
        self.assertIn(
            "openedFromWidget: widgetOpenedPhotoIdentifier == localIdentifier",
            today_detail,
        )
        self.assertIn("showsWidgetTiming: openedFromWidget", today_detail)
        self.assertIn("widgetShownAt: shownAt", today_detail)

        collection_detail = section(
            main,
            "private func collectionDetailView(for localIdentifier: String) -> some View",
            "private func memoryDetailView(for localIdentifier: String,",
        )
        self.assertIn("photos: photoLibraryCatPhotos", collection_detail)
        self.assertIn("libraryPhotos: photoLibraryBrowserPhotos", collection_detail)
        self.assertIn("showsWidgetTiming: false", collection_detail)
        self.assertIn("PhotosRoute.collectionPhoto", home)

        memory_detail = section(
            main,
            "private func memoryDetailView(for localIdentifier: String,",
            "private func memoriesDestination(for route: MemoriesRoute,",
        )
        self.assertIn("photos: libraryContext ? photoLibraryLikedPhotos : likedPhotos", memory_detail)
        self.assertIn("!libraryContext || photoLibraryIncludes(localIdentifier)", memory_detail)
        self.assertIn("showsWidgetTiming: false", memory_detail)
        self.assertIn("if showsWidgetTiming", browser)
        self.assertIn("切り替わる時刻は目安で、iPhoneの都合で前後します", browser)

        ordering = section(
            browser,
            "private static func makeBrowserPhotos(",
            "private var selectedPhoto: PhotoPresentation?",
        )
        self.assertIn("return ordered", ordering)
        self.assertNotIn(".sorted", ordering)

        self.assertIn('Text("ホーム画面にウィジェットを置く").font(.headline)', home)
        self.assertIn("showWidgetPlacementGuide", home)
        self.assertIn("iPhoneの中の猫の写真を、ぜんぶ見つけます。", onboarding)
        self.assertIn("外には送りません。", onboarding)
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

    def test_albums_open_favorites_and_scoped_collections_without_a_false_purchase_action(self) -> None:
        memories = source("NekoWidget/Views/LikedPhotosView.swift")
        home = source("NekoWidget/Views/HomeView.swift")
        main_tab = source("NekoWidget/Views/MainTabView.swift")
        album_root = section(memories, "struct LikedPhotosView:", "private struct AlbumOverviewCard:")
        self.assertIn("if hasPhotoAccess", album_root)
        self.assertIn('isCatDetail ? "albums-cat-detail" : "albums-root"', album_root)
        self.assertNotIn('accessibilityIdentifier("albums-favorites")', album_root)
        photo_library = section(main_tab, "private func photoLibraryContent(", "private var allPhotosView:")
        self.assertIn("case .favorites:", photo_library)
        self.assertIn("SavedMemoriesGalleryView(photos: hasPhotoAccess ? photoLibraryLikedPhotos : []", photo_library)
        self.assertIn("unavailableSavedPhotoCount: unavailablePhotoLibrarySavedCount", photo_library)
        self.assertIn("savedStateReadFailed: savedPhotoStateReadFailed", photo_library)
        self.assertIn("case .notes:", photo_library)
        self.assertIn("PhotoMemoryNotesListView(photos: memoryNotePhotos", photo_library)
        self.assertIn('navigationTitleOverride ?? "アルバム"', album_root)
        self.assertIn("MemoriesRoute.monthlyWindow(month)", album_root)
        self.assertIn("MemoriesRoute.seasonalMovie(movie.periodID)", album_root)
        self.assertIn('"memories-monthly-window"', album_root)
        self.assertIn('"albums-seasonal-movie"', album_root)
        # The album root opens one combined archive of months and movies (#397).
        self.assertIn('NavigationLink("これまでの月のまとめ・季節のムービー", value: MemoriesRoute.reflectionsArchive)', album_root)
        self.assertIn("ForEach(months)", album_root)
        self.assertIn("ForEach(seasonalMovies)", album_root)
        self.assertIn("sections: albumSections", album_root)
        self.assertIn("showsAllPhotos: false", album_root)
        self.assertIn("isEmbedded: true", album_root)
        self.assertNotIn("memories-section-picker", album_root)
        self.assertNotIn("memories-section-menu", album_root)
        self.assertNotIn("photos-open-automatic-albums", home)
        self.assertNotIn("PhotosRoute.automaticAlbums", home)
        albums_destination = section(main_tab, "private func albumsView(", "private func albumDestination(")
        self.assertIn("openPhotosOverride: (() -> Void)? = nil", albums_destination)
        self.assertIn("openPhotos: openPhotosOverride ?? {", albums_destination)
        self.assertIn("photoLibrarySelection.select(.all)", albums_destination)
        self.assertIn("photosPath = NavigationPath()", albums_destination)
        self.assertIn("selectedTab = .photos", albums_destination)
        self.assertIn("photos: likedPhotos", main_tab)
        self.assertIn("currentHouseholdAlbumCatalog?.sections ?? []", main_tab)
        self.assertIn("monthlyWindowCollection: scope == .everyone ? currentMonthlyWindowCollection : nil", main_tab)
        self.assertIn("presentation: refreshedMonthlyWindow(snapshot)", main_tab)
        self.assertNotIn("MemoryCreationPreviewSheet", memories)
        self.assertNotIn('Button("購入', album_root)
        self.assertNotIn('Button("注文', album_root)
        self.assertNotIn("StoreKit", album_root)

    def test_memories_show_the_complete_saved_collection_and_select_exports_separately(self) -> None:
        memories = source("NekoWidget/Views/LikedPhotosView.swift")
        main_tab = source("NekoWidget/Views/MainTabView.swift")
        memory_view = section(
            memories,
            "struct LikedPhotosView:",
            "private struct LikedPhotoBookExportFile:",
        )

        self.assertNotIn("ScrollViewReader { proxy in", memory_view)
        self.assertNotIn(".safeAreaInset(edge: .top", memory_view)
        self.assertNotIn("memories-section-jump-bar", memory_view)
        self.assertNotIn("Array(photos.prefix(6))", memory_view)
        self.assertNotIn("NavigationLink(value: MemoriesRoute.favorites)", memory_view)
        self.assertIn('NavigationLink("これまでの月のまとめ・季節のムービー", value: MemoriesRoute.reflectionsArchive)', memory_view)
        self.assertIn("albumsView().periodArchive(showsMovies: false)", main_tab)
        self.assertIn("albumsView().periodArchive(showsMovies: true)", main_tab)
        destinations = section(
            main_tab,
            "private func memoriesDestination(for route: MemoriesRoute,",
            "private func seasonalMovieDestination(",
        )
        self.assertIn("case .favorites:", destinations)
        self.assertIn("SavedMemoriesGalleryView(", destinations)
        self.assertIn("photos: likedPhotos", destinations)
        self.assertIn("startsInExportMode: false", destinations)
        self.assertIn("case .reflectionsArchive:", destinations)
        self.assertIn("showsReflectionArchive: true", destinations)
        self.assertNotIn('accessibilityIdentifier("albums-favorites")', memory_view)
        self.assertNotIn('accessibilityIdentifier("memories-create-from-photos-action")', memory_view)
        self.assertNotIn("ToolbarItem(placement: .topBarTrailing) { favoritesLink }", memory_view)

        gallery = section(
            memories,
            "struct SavedMemoriesGalleryView:",
            "private struct LikedPhotoBookExportFile:",
        )
        self.assertIn("ForEach(Array(PhotoLibraryGridRow.rows(visiblePhotos).enumerated())", gallery)
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
        self.assertIn("from: photos", main)
        self.assertIn("from: photoSourceStatus == .unavailable ? [] : albumEligibleCatPhotos", main)
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
        self.assertNotIn("presentation.remainingSceneCount.formatted()", memories)
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
        self.assertIn(".badge(hasUnreadMemoriesSummary && summaryOpens ? 1 : 0)", main)
        self.assertIn("markMonthlyWindowReadIfLatest(snapshot)", main)
        self.assertIn("latestMonthlyWindowIsUnread: Bool", memories)
        self.assertNotIn('return "まとめ・未読"', memories)

        self.assertIn("PhotoBrowserView(", view)
        self.assertIn("photos: presentation.storyPhotos", view)
        self.assertIn("initialPhoto: first", view)
        self.assertIn("setMemorySaved: setMemorySaved", view)
        self.assertNotIn("setMemorySaved(", view)
        self.assertIn('accessibilityIdentifier("monthly-window-browser")', view)
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
        self.assertIn("seasonalMovies: scope == .everyone ? currentSeasonalMovieRecords : []", main)
        self.assertIn("latestSeasonalMovieIsNew: scope == .everyone && latestSeasonalMovieIsNew", main)
        self.assertIn(".badge(hasUnreadMemoriesSummary && summaryOpens ? 1 : 0)", main)
        self.assertIn(
            "latestMonthlyWindowIsUnread || latestSeasonalMovieIsNew",
            main,
        )
        self.assertIn("currentSeasonalMovieRecords.first.map { !$0.isFrozen }", main)
        self.assertIn("let latestSeasonalMovieIsNew: Bool", memories)
        self.assertNotIn(".onChange(of: hasUnreadSummary, initial: true)", memories)
        self.assertIn("isNew: isLatest && latestSeasonalMovieIsNew", memories)
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
        self.assertIn("photoPresentationVersion: photoPresentationVersion", main)
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
        self.assertIn("お気に入りと動く場面を優先します", view)
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
        self.assertIn('Text("このムービーから外しました")', view)
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

    def test_received_family_widget_uses_cat_focused_full_bleed_canvases(self) -> None:
        plans = source("Shared/Models/WidgetRenderPlan.swift")
        focused = section(
            plans,
            "static func centeredFullBleedPlan(",
            "private static func clampedCropRect",
        )
        self.assertIn("static func focusedFullBleedPlan(", focused)
        self.assertIn("visionBoundingBox: CGRect?", focused)
        self.assertIn("photoBoundingBox.midX", focused)
        self.assertIn("focus = CGPoint(x: 0.5, y: 0.5)", focused)
        self.assertIn("compositionMode: .catFullBleed", focused)

        builder = source("NekoWidget/Services/WidgetCacheBuilder.swift")
        publication = section(builder, "func buildFamilyWindow(", "func clear() throws")
        self.assertEqual(publication.count("focusedFullBleedPlan("), 3)
        self.assertIn("let catBoundingBox = Self.familyCatBoundingBox", publication)
        self.assertIn("VNRecognizeAnimalsRequest()", builder)
        self.assertIn("item.familyWidgetSourceDigest", builder)
        store = source("Shared/Sharing/MomentSharingStore.swift")
        digest = section(store, "var familyWidgetSourceDigest: String", "func validated() throws -> Self")
        self.assertIn("family-widget-v3-cat-focused-full-bleed", digest)
        self.assertIn("committedAt.timeIntervalSinceReferenceDate.bitPattern", digest)
        self.assertIn("receivedAt.timeIntervalSinceReferenceDate.bitPattern", digest)
        self.assertIn("PairingCrypto.sha256(Data(identity.utf8))", digest)
        widget_gate = section(store, "static func isFamilyWidgetCacheVisible", "static func isLocalSharedImageVisible")
        self.assertIn("item.familyWidgetSourceDigest", widget_gate)
        self.assertIn("!state.isModerationHidden(item.id)", widget_gate)
        self.assertNotIn("family-widget-v2-full-bleed-bookmark", builder)
        self.assertIn("momentID: current.item.id", publication)

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
        self.assertIn('cacheRenderingRevision = "cat-focused-fallback-v2"', builder)

        action_tray = section(
            view,
            "private func actionTray<Content: View>(",
            "/// The private-memory control",
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


    def test_settings_prioritizes_daily_safety_and_about_tasks(self) -> None:
        settings = source("NekoWidget/Views/SettingsView.swift")
        app_root = source("NekoWidget/App/AppRootView.swift")
        for section_title in (
            "写真とウィジェット",
            "家族とまど",
            "保存",
            "困ったとき",
            "テスト用",
        ):
            self.assertIn(f'Text("{section_title}")', settings)
        self.assertNotIn('Label("写真の検出", systemImage: "lock.iphone")', settings)
        self.assertNotIn('Text("縮小・位置情報削除・暗号化")', settings)

        self.assertIn('Label("写真の表示と整理"', settings)
        self.assertIn("private var photoSettingsView: some View", settings)
        self.assertIn('.navigationTitle("写真の表示と整理")', settings)
        self.assertIn('Label("ウィジェットの置き方"', settings)
        self.assertIn('"settings-widget-placement-guide"', settings)
        self.assertIn("savePhotoSettings(requestedRange, requestedAlbumLimit)", settings)
        self.assertIn(
            "await saveDetectionSettings(requestedConfidence, requestedMinimumArea)",
            settings,
        )
        self.assertNotIn("var requestedSettings = settings", settings)
        self.assertIn("isPhotoSettingsSavePending = true", settings)
        # The 「うちの子」 album screen left Settings (10/31).
        self.assertNotIn("PhotoLibraryAlbumSettingsView", settings)
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
        # The rescan is a repair: it sits under 困ったとき in the photo settings, not in diagnostics.
        self.assertIn('"写真を最初から探し直す"', photo_settings)
        self.assertNotIn('"最初から探し直す"', diagnostics)
        self.assertIn('Picker("ウィジェットに出す写真", selection: $draft.range)', photo_settings)
        self.assertIn('Label("診断情報", systemImage: "wrench.and.screwdriver")', settings)
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

    def test_automatic_albums_have_one_root_and_photos_keep_the_full_grid(self) -> None:
        main_tab = source("NekoWidget/Views/MainTabView.swift")
        home = source("NekoWidget/Views/HomeView.swift")
        albums = source("NekoWidget/Views/LikedPhotosView.swift")
        self.assertIn("currentHouseholdAlbumCatalog?.sections ?? []", main_tab)
        self.assertIn("NavigationLink(value: route(for: album.id))", albums)
        self.assertIn("return .album(id)", albums)
        self.assertIn("return .catAlbum(profileIdentifier: identifier, album: id)", albums)
        self.assertIn('"album-card-\\(album.id.logKey)"', albums)
        self.assertIn("showsAllPhotos: false", albums)
        self.assertNotIn("PhotosRoute.automaticAlbums", home)
        self.assertNotIn('Text("自動アルバム")', home)
        self.assertNotIn("HomeAlbumHighlightCard(", home)
        self.assertNotIn("AlbumRoute.album(album.id)", home)
        self.assertIn('Text(showsCatProfileNavigation ? "すべての猫写真" : "猫写真")', home)
        self.assertNotIn('accessibilityIdentifier("photos-open-automatic-albums")', home)

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




        builder = source("NekoWidget/Services/WidgetCacheBuilder.swift")
        publication = section(builder, "func buildFamilyWindow(", "func clear() throws")
        self.assertIn("windowDisplayName: resolvedWindowDisplayName", publication)
        self.assertIn("refreshed.windowDisplayName = resolvedWindowDisplayName", publication)
        self.assertLess(
            publication.index("refreshed.windowDisplayName = resolvedWindowDisplayName"),
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
            "catalogMetadataChanged || conflictMetadataChanged",
            mirror_catalog,
        )




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
        self.assertIn("pairingStateURL", scoped_load)
        self.assertIn("localWindowID: localWindowID", scoped_load)
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
        # The old catalog remains readable by the app, but must never grant
        # the group Share Extension a destination or a fallback recipient.
        self.assertNotIn("MomentShareHandoffStore", share_view)
        self.assertNotIn("selectedAdmission", share_view)
        self.assertIn("service: try GroupShareService.live()", share_view)
        composer = source("NekoWidgetShareExtension/GroupShareComposer.swift")
        self.assertIn("windows.contains(where: { $0.id == window.id })", composer)
        self.assertIn("attemptedWindowID == selected.id", composer)
        self.assertIn("windowID: selected.id, operationID: operationID", composer)
        self.assertIn(".disabled(!GroupShareComposerModel.canDeliver(window))", composer)

        pairing_store = source("Shared/Sharing/PairingKeychainStore.swift")
        self.assertIn(
            "value.localMomentDeviceID != originalLocalMomentDeviceID",
            pairing_store,
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

        self.assertIn("Text(selected.name)", composer)
        self.assertIn("Text(window.name)", composer)

        handoff = source("Shared/Sharing/MomentShareHandoffStore.swift")
        binding = section(
            handoff,
            "static func makeBindingSHA256(",
            "static func publishAdmissions(",
        )
        self.assertNotIn("displayName", binding)

        app_model = source("NekoWidget/ViewModels/AppViewModel.swift")

        window_name_service = (
            ROOT / "SharingService" / "src" / "window-name.ts"
        ).read_text(encoding="utf-8")
        self.assertIn("actor.is_primary_device !== 1", window_name_service)
        self.assertIn("primary_owner_device_required", window_name_service)



        runtime_self_test = source("NekoWidget/Services/SharingRuntimeSelfTest.swift")
        self.assertIn("Models a GET/PUT response resuming after unlink", runtime_self_test)


    def test_sharing_surfaces_do_not_assume_a_family_relationship(self) -> None:
        surfaces = [
            "NekoWidget/Views/HomeView.swift",
            "NekoWidget/Views/SettingsView.swift",
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
        self.assertIn('"\\(entry.windowDisplayName)に届いた写真"', widget)
        self.assertNotIn('"\\(entry.windowDisplayName)から届いた', widget)
        self.assertIn("Text(entry.windowDisplayName)", widget)
        self.assertIn('detail: "このまどに届いた最新の一枚"', widget_configuration)
        self.assertIn('name: "このiPhoneの猫写真"', widget_configuration)
        self.assertIn('detail: "くもりのまど。毎日1枚、猫を順番に"', widget_configuration)
        self.assertNotIn('name: "このiPhoneの写真"', widget_configuration)
        self.assertIn(
            'Label("写真", systemImage: "photo.on.rectangle.angled")',
            main_tab,
        )
        self.assertIn(
            'Label("まど", systemImage: "window.vertical.closed")',
            main_tab,
        )
        self.assertIn('Text("ホーム画面にウィジェットを置く").font(.headline)', home)
        self.assertIn('Label("アルバム", systemImage: "photo.stack.fill")', main_tab)
        self.assertIn('.navigationTitle("写真")', home)
        self.assertIn('"window-settings-button"', home)
        self.assertNotIn('"window-list-settings-button"', main_tab)
        self.assertNotIn('"memories-settings-button"', liked)
        home_body = section(
            home,
            "var body: some View",
            "private var photoAccessCard: some View",
        )
        self.assertEqual(home_body.count("if shouldOfferWidgetPlacementGuide"), 1)
        self.assertIn("if shouldOfferWidgetPlacementGuide, !catPhotos.isEmpty", home_body)
        self.assertLess(
            home_body.index("if shouldOfferWidgetPlacementGuide"),
            home_body.index("detectedPhotosSection"),
        )
        self.assertNotIn('Text("今日の1枚")', home)
        self.assertNotIn('.navigationTitle("まど")', home)
        self.assertNotIn("PhotosRoute.automaticAlbums", home)
        self.assertNotIn('Text("自動アルバム")', home)
        self.assertNotIn("NavigationLink(value: MemoriesRoute.automaticAlbums)", liked)
        self.assertNotIn('"today-memory-saved-state"', home)
        self.assertIn("WindowListView(", main_tab)
        self.assertIn("selectedTab = .photos", main_tab)
        self.assertIn("photosPath.append(PhotosRoute.photo(identifier))", main_tab)
        self.assertIn("selectedTab = .windows", main_tab)
        self.assertLess(
            main_tab.index('.tag(AppTab.memories)'),
            main_tab.index('.tag(AppTab.photos)'),
        )
        self.assertLess(
            main_tab.index('.tag(AppTab.photos)'),
            main_tab.index('.tag(AppTab.windows)'),
        )
        onboarding = source("NekoWidget/Views/OnboardingPresentation.swift")
        self.assertIn("猫写真をひとつ。", onboarding)
        self.assertNotIn("猫写真のまどをひとつ。", onboarding)

        self.assertIn('"photo-browser-memory-saved-state"', liked)
        self.assertIn('.accessibilityLabel(saved ? "お気に入りから外す" : "お気に入りに追加")', liked)

        settings = source("NekoWidget/Views/SettingsView.swift")
        profiles = source("NekoWidget/Views/CatProfilesView.swift")
        onboarding = source("NekoWidget/Views/OnboardingPresentation.swift")
        permission = source("NekoWidget/Views/PhotoPermissionView.swift")
        scan = source("NekoWidget/Views/ScanStatusView.swift")
        # 11/7: cats are opened from the ツール tab's faces only, not from 設定.
        self.assertNotIn('"settings-cat-profiles"', settings)
        self.assertNotIn("CatProfilesView(", settings)
        self.assertIn('.accessibilityIdentifier("tools-cat-\\(profile.identifier)")', source("NekoWidget/Views/MainTabView.swift"))
        self.assertIn('.navigationTitle(opensProfileSettings ? "猫のプロフィール" : "猫ごとの写真")', profiles)
        self.assertIn('"このiPhoneの中から、"', onboarding)
        self.assertIn('"猫の写真や動画を見つけよう"', permission)
        self.assertIn('"このiPhoneの猫写真を探しています"', scan)

        surfaces_without_legacy_album_copy = [
            "NekoWidget/Views/CatCandidateCurationView.swift",
            "NekoWidget/Views/CatProfilePhotoCurationViews.swift",
            "NekoWidget/Views/CatProfilesView.swift",
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

    def test_growth_album_opens_as_a_photo_story_before_editing(self) -> None:
        growth = source("NekoWidget/Views/GrowthAlbumView.swift")

        self.assertIn('.accessibilityLabel("写真の選び方について")', growth)
        self.assertIn('Text(aboutSelectionMessage)', growth)
        self.assertIn('scrapbookTimeline(items: resolvedItems)', growth)
        self.assertIn('Label("写真を変える"', growth)
        # The screen title names the album; no second big range heading above the story.
        self.assertNotIn('.font(.title.bold())', growth)
        self.assertIn('.alert("写真の選び方について"', growth)
        self.assertIn('"\\(firstPeriod.label) → \\(lastPeriod.label)"', growth)
        self.assertNotIn('roleLabel:', growth)
        self.assertNotIn('Text("その間")', growth)
        self.assertNotIn('comparisonCards(', growth)
        self.assertNotIn('Label("写真を替える"', growth)
        self.assertNotIn('Text(date, format: .dateTime.year().month().day())', growth)

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



    def test_device_change_ui_names_each_phone_and_one_primary_next_action(self) -> None:
        presentation = source("NekoWidget/Views/PairingPresentation.swift")

        for device_name in ["追加するiPhone", "すでに使っているiPhone", "相手のiPhone"]:
            self.assertIn(device_name, presentation)

        self.assertIn("すでに使っているiPhoneは解除されません", presentation)



    def test_sent_ledger_separates_server_acceptance_from_device_arrival(self) -> None:
        store = source("Shared/Sharing/MomentSharingStore.swift")
        container = source("Shared/AppGroup/SharedContainer.swift")
        widget = source("NekoWidgetWidget/NekoWidgetView.swift")
        runtime = source("NekoWidget/Services/SharingRuntimeSelfTest.swift")
        presentation = source("NekoWidget/Views/MomentSharingPresentation.swift")

        self.assertIn("recipientDeliveryConfirmedAt", store)
        self.assertIn("markRecipientDeliveryConfirmed", store)
        self.assertIn("MomentSentRecordDeliveryState", presentation)
        self.assertIn("serverAccepted", presentation)
        self.assertIn("recipientDeviceArrivalConfirmed", presentation)
        self.assertIn("相手が写真を見たかどうかは分かりません", presentation)
        self.assertIn("static let sentRecordLimit = 200", presentation)
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
        self.assertNotIn("MomentSharingStateStore", widget)
        self.assertNotIn("localThumbnailFileName", widget)
        self.assertIn("rewrittenOutbox.first?[\"localThumbnailJPEG\"] == nil", runtime)
        self.assertIn("hasRequiredProtectionAndBackupExclusion", runtime)
        self.assertIn("pendingThumbnailURL", runtime)
        self.assertIn("ambiguousThumbnailURL", runtime)
        self.assertIn("reportOnlyThumbnailURL", runtime)
        self.assertIn("recoveredWithoutPreview", runtime)


    def test_last_known_family_window_snapshot_is_fully_read_only(self) -> None:






        store = source("Shared/Sharing/MomentSharingStore.swift")
        delete_hidden = section(
            store,
            "static func deleteInbox(",
            "/// Adds or removes a local, sharing-scoped bookmark",
        )
        self.assertLess(
            delete_hidden.index("FileManager.default.removeItem"),
            delete_hidden.index("try writeWhileLocked"),
        )
        self.assertNotIn("state.reportOutbox.remove", delete_hidden)


    def test_draft_window_name_and_initial_product_limit_are_explicit(self) -> None:
        container = source("Shared/AppGroup/SharedContainer.swift")
        main_tab = source("NekoWidget/Views/MainTabView.swift")
        installation = source("NekoWidget/Services/PairingInstallationGuard.swift")

        self.assertIn("maximumWindowCount = 20", container)
        self.assertIn("maximumProductWindowCount = 10", container)
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

    def test_cat_profile_detail_opens_photo_choices_without_an_extra_sources_page(self) -> None:
        profile = source("NekoWidget/Views/CatProfilePhotoCurationViews.swift")
        detail = section(
            profile,
            "struct CatProfileDetailView: View",
            "private struct CatProfilePhotoAlbumSelectionView: View",
        )
        page = section(detail, "struct CatProfileDetailView: View", "struct CatProfileAddPhotosButton: View")
        self.assertNotIn("CatProfilePhotoSourcesView", profile)
        # 11/7: the cat's page is この子のこと only. No 写真 tab, and the cat's
        # photos are not seen or added from it (the 写真 tab does that).
        self.assertIn("CatCareDetailView(profile: profile, otherProfiles: [], selectedProfileID: .constant(profile.identifier))", page)
        for removed in ('"cat-profile-page-photos"', '"cat-profile-page-care"', "TabView(", "enum CatPage",
                        '"この子の写真を見る"', '"この子の写真を追加"', "UnassignedCatPhotosView(",
                        "CatProfileConfirmedPhotosView("):
            self.assertNotIn(removed, page)
        # The page passes its own actions, so rename, photo and delete use them.
        self.assertIn(".environment(\\.toolProfileActions, actions)", page)
        # The 写真 tab's one entry reuses the same add picker for the chosen cat.
        add = section(profile, "struct CatProfileAddPhotosButton: View", "extension CatProfilePresentation {")
        self.assertIn('Label("この子の写真を追加"', add)
        self.assertIn("UnassignedCatPhotosView(", add)
        self.assertIn("preselectedProfileIdentifier: profile.identifier", add)
        self.assertIn("dismissAfterSaving: true", add)
        main = source("NekoWidget/Views/MainTabView.swift")
        library = section(main, "private var photoLibrary: some View {", "private var albumRoot: some View {")
        self.assertIn("$0.identifier == photoLibraryProfileIdentifier", library)
        self.assertIn("CatProfileAddPhotosButton(", library)
        # The name, key photo and deleting are in この子のこと: the photo and
        # name at the top of the page, outside the folds; deleting is the
        # last row of 基本 (11/7).
        care = source("NekoWidget/Views/CatCareView.swift")
        page = section(care, "struct CatCareDetailView: View {", ".onChange(of: draft)")
        self.assertIn("profileHeading(profile)", page)
        self.assertLess(page.index("profileHeading(profile)"), page.index('folded("basics", "基本"'))
        basics = section(care, "@ViewBuilder private var basicsSection: some View {", "private func profileHeading(")
        self.assertNotIn("profileHeading(profile)", basics)
        self.assertIn("deleteSection(profile)", basics)
        self.assertIn('Text("写真タブでこの子の写真を追加すると選べます")', care)
        heading = section(care, "private func profileHeading(", "private func deleteSection(")
        self.assertIn("showsKeyPhotoPicker = true", heading)
        self.assertIn('"cat-profile-rename"', heading)
        self.assertIn("await profileActions.updateName(profile.identifier, draftName)", heading)
        self.assertIn("await profileActions.setKeyPhoto(profile.identifier, $0)", care)
        delete = section(care, "private func deleteSection(", "@State private var openParts")
        self.assertIn('Button("プロフィールを削除", role: .destructive)', delete)
        self.assertIn("await profileActions.deleteProfile(profile.identifier)", delete)
        self.assertIn('Button("旅立った日を記録する") { showsFarewellEditor = true }', delete)
        self.assertIn("元に戻せません。", delete)
        form = section(care, 'folded("household", "家の情報", progress.household) { householdSection }', ".onChange(of: draft)")
        self.assertNotIn("deleteSection(profile)", form)
        self.assertIn('LabeledContent("誕生日・迎えた日", value: profile.lifeDatesSummary)', care)
        self.assertIn('"cat-care-life-dates"', care)
        # The album link is not offered on the profile; 「うちの子」 lives in 設定 → 写真.
        self.assertNotIn('"写真アプリのアルバムをつなぐ"', detail)
        # 11/7: the album no longer opens the cat's page (one entry: ツール).
        self.assertNotIn("CatProfileDetailView(", source("NekoWidget/Views/LikedPhotosView.swift"))

    def test_cat_pages_browse_before_editing_and_creation_can_start_from_a_photo(self) -> None:
        profiles = source("NekoWidget/Views/CatProfilesView.swift")
        destination = section(profiles, "private func profileDetail(", "private struct CatProfileRow")
        self.assertIn("var opensProfileSettings = false", profiles)
        settings_destination, photo_destination = destination.split("} else {", 1)
        self.assertIn("if opensProfileSettings", settings_destination)
        self.assertIn("CatProfileDetailView(", settings_destination)
        self.assertIn("CatProfileConfirmedPhotosView(", photo_destination)
        self.assertNotIn("CatProfileDetailView(", photo_destination)
        self.assertIn(".sheet(item: $creationRequest", profiles)
        self.assertIn("CreationRequest(photoIdentifier: creationPhotoIdentifier)", profiles)
        self.assertIn("initialPhotoIdentifier: request.photoIdentifier", profiles)
        self.assertIn(".id(request.id)", profiles)
        self.assertIn('Button("写真はあとで")', profiles)
        self.assertNotIn("CatSimilarityReviewCoordinatorView(", profiles)
        self.assertIn("Text(CatIndividualRecognitionCopy.unavailable)", profiles)
        self.assertIn("openedProfileIdentifier = profile.identifier", profiles)
        self.assertIn("!identifiers.contains(openedProfileIdentifier)", profiles)
        self.assertIn("self.openedProfileIdentifier = nil", profiles)

        curation = source("NekoWidget/Views/CatProfilePhotoCurationViews.swift")
        page = section(curation, "struct CatProfileConfirmedPhotosView: View", "private struct CatProfilePhotoPreview")
        self.assertIn("@State private var isSelecting = false", page)
        self.assertIn("showsSelectionMarks: false", page)
        self.assertIn(".sheet(item: $previewPhoto)", page)
        self.assertIn("CatProfileDetailView(", page)
        self.assertIn("dismissAfterSaving: true", page)
        self.assertIn('Label("この子の写真を追加"', page)

    def test_cat_add_shortcut_preserves_other_memberships_and_failed_selection(self) -> None:
        curation = source("NekoWidget/Views/CatProfilePhotoCurationViews.swift")
        picker = section(curation, "struct UnassignedCatPhotosView: View", "struct CatPhotoAssignmentSheet: View")
        addition = picker[picker.index("private func addSelectedPhotos("):]
        self.assertIn("await actions.confirmProfileMembership(profileIdentifier, identifiers)", addition)
        self.assertNotIn("replacePhotoAssignments", addition)
        self.assertNotIn("excludeFromHousehold", addition)
        self.assertLess(addition.index("let saved = await"), addition.index("if saved {"))
        self.assertLess(addition.index("if saved {"), addition.index("selection.removeAll()"))
        failure = addition[addition.index("} else {"):]
        self.assertIn("saveFailed = true", failure)
        self.assertNotIn("selection.removeAll()", failure)
        self.assertNotIn("dismiss()", failure)
        self.assertIn(".interactiveDismissDisabled(isSaving)", picker)
        self.assertIn('Button("ほかの猫も選ぶ"', picker)
        self.assertIn("if assignmentWasSaved && dismissAfterSaving", picker)

    def test_cat_assignments_wait_for_persistence_before_dismissing(self) -> None:
        profile = source("NekoWidget/Views/CatProfilePhotoCurationViews.swift")
        sheet = section(profile, "struct CatPhotoAssignmentSheet: View", "struct LegacyCatExclusionReviewView: View")
        self.assertIn("let save: ([String: Set<String>]) async -> Bool", sheet)
        self.assertIn("let saved = await save(assignmentBatch.assignmentsByPhotoIdentifier)", sheet)
        self.assertIn("if saved { dismiss() } else { saveFailed = true }", sheet)
        self.assertIn(".interactiveDismissDisabled(isSaving)", sheet)
        self.assertNotIn("excludeFromHousehold", sheet)
        main = source("NekoWidget/Views/MainTabView.swift")
        self.assertNotIn("Task { await catProfilesActions.replacePhotoAssignments(values) }", main)



    def test_host_photo_picker_uses_the_existing_bounded_handoff(self) -> None:
        ingress = source("NekoWidgetShareExtension/MomentShareIngressService.swift")
        project = source("NekoWidget.xcodeproj/project.pbxproj")

        self.assertIn("func prepare(fromFileURL url: URL)", ingress)
        self.assertIn("try Self.canonicalPhoto(from: url)", ingress)

        app_sources = section(
            project,
            "A00000000000000000000021 /* Sources */ = {",
            "A00000000000000000000025 /* Sources */",
        )
        self.assertIn("MomentShareIngressService.swift in Sources", app_sources)

    def test_photo_browser_delivery_keeps_the_existing_admission_and_photo_boundaries(self) -> None:
        browser = source("NekoWidget/Views/LikedPhotosView.swift")
        exporter = source("NekoWidget/Services/PhotoBookPDFExporter.swift")
        self.assertIn("groupDelivery = GroupDeliveryRequest(localIdentifier: selectedPhoto.localIdentifier)", browser)
        self.assertIn(".sheet(item: $groupDelivery", browser)
        memory = section(exporter, "struct MemoryPhotoJPEGExporter", "struct PhotoLibraryJPEGExporter")
        self.assertLess(memory.index("MemoryPhotoExportPolicy.selection"),
                        memory.index("PhotoLibraryJPEGExporter().export"))

    def test_retryable_pairing_bootstrap_is_retried_after_data_protection(self) -> None:
        pairing_store = source("Shared/Sharing/PairingKeychainStore.swift")
        pairing_guard = source("NekoWidget/Services/PairingInstallationGuard.swift")
        lifecycle = source("Shared/Storage/AtomicJSON.swift")
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
        sharing_state = section(store, "struct MomentSharingState:", "mutating func normalizePersistedDiagnosticErrors")
        self.assertIn("static let schemaVersion = 10", sharing_state)
        self.assertIn("var moderationOverlays: [MomentModerationOverlay]", sharing_state)
        self.assertIn("if decodedSchema >= 10", sharing_state)
        self.assertIn("decode([MomentModerationOverlay].self, forKey: .moderationOverlays)", sharing_state)
        self.assertIn("overlay.status.revision > 0 || overlay.downloadHidden", sharing_state)
        overlay = section(sharing_state, "mutating func applyModeration", "@discardableResult")
        self.assertIn("moderationOverlays[index].committedAt == committedAt", overlay)
        self.assertIn("moderationOverlays[index].apply(status, downloadHidden: downloadHidden)", overlay)
        self.assertNotIn("removeAll", overlay)
        self.assertNotIn("removeItem", overlay)
        self.assertNotIn("state = .revoked", overlay)
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

        main_tab = source("NekoWidget/Views/MainTabView.swift")
        self.assertIn('Label("まど", systemImage: "window.vertical.closed")', main_tab)
        self.assertNotIn("届いた写真の履歴", main_tab)


    def test_widget_placement_guide_is_compact_and_auto_closes_after_install(self) -> None:
        guide = source("NekoWidget/Views/WidgetPlacementGuideView.swift")
        presentation = source("NekoWidget/Views/OnboardingPresentation.swift")
        app_root = source("NekoWidget/App/AppRootView.swift")
        checker = source("NekoWidget/Services/WidgetInstallationChecker.swift")

        # 10/22: the owner asked for the real iOS screens, swiped one by one, with
        # one line each. The guide is still short: no daily rule, no rediscovery.
        self.assertIn(".tabViewStyle(.page(indexDisplayMode: .always))", guide)
        self.assertNotIn("widget-placement-daily-rule", guide)
        self.assertNotIn("widget-placement-rediscovery", guide)
        self.assertIn("widgetModernPlacementSteps", guide)
        self.assertIn("widgetLegacyPlacementSteps", guide)
        self.assertIn("if #available(iOS 18.0, *)", guide)
        self.assertIn('"widget-placement-steps"', guide)
        self.assertIn('"完了"', presentation)
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

        presentation = source("NekoWidget/Views/PairingPresentation.swift")
        self.assertIn('forInfoDictionaryKey: "CFBundleShortVersionString"', presentation)
        self.assertIn('forInfoDictionaryKey: "CFBundleVersion"', presentation)
        self.assertIn('return "バージョン \\(resolvedVersion)（Build \\(resolvedBuild)）"', presentation)



class GroupWindowUITests(unittest.TestCase):
    def test_group_window_screens_stay_behind_the_client_boundary(self) -> None:
        view = source("NekoWidget/Views/GroupWindowSetupView.swift")
        # No network, storage, or key material in the screens themselves.
        for forbidden in (
            "URLSession", "Keychain", "UserDefaults", "import CryptoKit",
            "SymmetricKey", "roomKey", "HPKE", "print(", "SharedLog",
        ):
            self.assertNotIn(forbidden, view)
        self.assertEqual(view.count("import SwiftUI"), 1)

        # Every mutation is compare-and-set against the revision on screen,
        # and a retry resends the same operation ID instead of a new one.
        perform = section(view, "private func perform(", "struct GroupWindowMembersView: View")
        self.assertIn("expectedRevision: window.revision", perform)
        self.assertIn("id: retainedOperations[key]?.id ?? UUID()", perform)
        self.assertIn("case .offline:", perform)
        self.assertIn("case .staleRevision:", perform)
        stale = section(perform, "case .staleRevision:", "default:")
        self.assertIn("await load()", stale)
        self.assertNotIn("retainedOperations[key] = nil", stale)

        # The invitation link travels only through the share sheet; it is
        # never drawn on screen or logged.
        invitation = section(view, "private func invitationSection(", "private func leaveSection(")
        self.assertIn("item: invitation.shareText", invitation)
        self.assertEqual(view.count("shareText"), 1)

        # 1030q: admission is automatic after the adapter verifies the invitation
        # signature and current owner/window/limits. UI exposes results, never a manual approval.
        self.assertNotIn("verificationPhrase", view)
        request_row = section(view, "private func requestRow(", "private func invitationSection(")
        self.assertNotIn("model.approve(request)", request_row)
        self.assertIn("client.reconcileAdmissions()", view)
        self.assertIn("admissionResults", view)

        # Waiting states refresh by themselves (M2); no manual check button.
        self.assertEqual(view.count(".task(id: model.shouldAutoRefresh)"), 1)
        self.assertEqual(view.count(".task(id: model.isPending)"), 1)
        for removed in ("相手が参加したか確認", "承認されたか確認"):
            self.assertNotIn(removed, view)

        # Limits are people, iPhones and windows, never a paid lever.
        presentation = section(view, "enum GroupWindowPresentation {", "// MARK: - Members and invitation")
        self.assertIn("static let memberLimit = 6", presentation)
        self.assertIn("static let deviceLimitPerPerson = 3", presentation)
        self.assertIn("static let totalWindowLimit = 10", presentation)
        for expected in (
            "このまどは\\(memberLimit)人までです。",
            "1人が使えるiPhoneは\\(deviceLimitPerPerson)台までです。",
            "まどは全部で\\(totalWindowLimit)個までです。",
            "まどを作った人がアプリを開くと、続けられます。",
            "招待リンクの期限が切れました。新しいリンクを送ってもらってください。",
            "接続できません。電波のあるところで",
            "まどを作った人は抜けられません。",
        ):
            self.assertIn(expected, presentation)
        # People, iPhones and the total are never a paid lever. (Creating and
        # continuing a window is Plus by the owner's 10/20 decision.)
        limits = section(presentation, "case .memberLimit:", "case .ownedWindowLimit:")
        for forbidden in ("Plus", "会員", "980", "購入", "課金"):
            self.assertNotIn(forbidden, limits)

        # A failed refresh keeps the last known members and requests.
        load = section(view, "func load(reportsFailure: Bool = true) async {", "func createInvitation() async {")
        self.assertNotIn("window = nil", load)
        self.assertNotIn("pendingRequests = []", load)
        # 11/5: the 8-second pass stays quiet and waits while a sheet is open.
        self.assertIn("if reportsFailure || window == nil {", load)
        self.assertIn("if !presentsSheet { await model.load(reportsFailure: false) }", view)
        join = section(view, "func refresh(reportsFailure: Bool = false) async {", "func cancel() async {")
        self.assertIn("if reportsFailure { errorMessage = GroupWindowPresentation.message(for: error) }", join)
        self.assertIn(".refreshable { await model.refresh(reportsFailure: true) }", view)

        # The fixture is DEBUG-only and reached by a launch argument.
        debug = section(view, "// MARK: - DEBUG fixture entry", "#endif")
        self.assertIn("#if DEBUG", debug)
        debug_blocks = re.findall(r"#if DEBUG(.*?)#endif", view, flags=re.S)
        self.assertEqual(
            view.count("GroupWindowFixture("),
            sum(block.count("GroupWindowFixture(") for block in debug_blocks),
        )
        self.assertIn('"--group-window-ui-fixture"', debug)
        project = source("NekoWidget.xcodeproj/project.pbxproj")
        self.assertIn("GroupWindowSetupView.swift in Sources", project)

        # Today's two-person window is read-only through the same boundary:
        # every change is refused, and the screen hides what it cannot do.
        legacy = section(view, "struct LegacyPairingGroupWindowClient: GroupWindowClient", "struct LegacyWindowMembersScreen: View")
        self.assertEqual(legacy.count("throw GroupClientError.unavailable"), 13)
        self.assertNotIn("URLSession", legacy)
        self.assertIn('displayName: "自分"', legacy)
        self.assertIn('displayName: "相手"', legacy)
        self.assertIn("GroupWindowMembersView(model: model, capabilities: .readOnly)", view)
        self.assertIn("if capabilities.invitations, window.canManage {", view)
        self.assertIn("if capabilities.leave {", view)
        self.assertIn("let canRemove = capabilities.removal", view)


class GroupInvitationLinkTests(unittest.TestCase):
    def test_invitation_link_reaches_the_join_screen_without_leaking_keys(self) -> None:
        link = source("NekoWidget/Services/GroupInvitationLink.swift")
        # CryptoKit authenticates fragment display context; keys never reach logs or UI storage.
        self.assertIn("import CryptoKit", link)
        for forbidden in ("print(", "SharedLog", "UserDefaults", "Keychain", "URLSession"):
            self.assertNotIn(forbidden, link)
        self.assertIn('static let host = "nekonomado.com"', link)
        self.assertIn('static let path = "/join"', link)
        self.assertIn("components.query == nil", link)
        self.assertIn("let fragment = components.fragment", link)
        self.assertIn("keys: redacted", link)
        self.assertNotIn("inviteSecret.base64", link)

        # The app routes the link to the まど tab without logging it.
        app = source("NekoWidget/ViewModels/AppViewModel.swift")
        hook = section(app, "func handleURL(_ url: URL) {", "guard let link = DeepLink(url: url) else {")
        self.assertIn("GroupInvitationLink.isCandidate(url)", hook)
        self.assertIn("GroupInvitationInbox.shared.receive(invitation)", hook)
        self.assertIn("isFamilyWindowPresented = true", hook)
        for leak in ("url.absoluteString", "\\(url)", "url.fragment", "metadata:"):
            self.assertNotIn(leak, hook)

        view = source("NekoWidget/Views/GroupWindowSetupView.swift")
        inbox = section(view, "final class GroupInvitationInbox", "enum GroupWindowClientProvider")
        self.assertNotIn("UserDefaults", inbox)
        self.assertNotIn("print(", inbox)
        # Outside the DEBUG fixture there is no client yet, and the sheet says so.
        provider = section(view, "enum GroupWindowClientProvider", "struct GroupInvitationJoinSheet: View")
        self.assertIn("#if DEBUG", provider)
        self.assertIn("return nil", provider)
        # The production client exists only in builds that turn groups on.
        self.assertIn('(Bundle.main.object(forInfoDictionaryKey: "GroupWindowsEnabled") as? String) == "YES"', provider)
        self.assertIn("configuration.isGroupRuntimeAvailable", provider)
        self.assertIn("let endpoint = configuration.baseURL", provider)
        self.assertIn("production.stageInvitation(url: url)", provider)
        self.assertIn("GroupWindowClientProvider.joinClient(for: invitation)", view)
        self.assertIn("model = GroupJoinModel(client: nil, invitationID: invitation.invitationID)", view)
        self.assertIn('"group-join-unavailable"', view)

        # Only the tab's own screen presents the sheet.

        checks = source("ci/run-quick-ios-checks.sh")
        self.assertIn("ci/verify-group-invitation-link.swift", checks)
        project = source("NekoWidget.xcodeproj/project.pbxproj")
        self.assertIn("GroupInvitationLink.swift in Sources", project)




class GroupWindowPausedTests(unittest.TestCase):
    def test_paused_window_keeps_everything_and_says_who_can_resume(self) -> None:
        view = source("NekoWidget/Views/GroupWindowSetupView.swift")
        presentation = section(view, "enum GroupWindowPresentation {", "// MARK: - Members and invitation")
        self.assertIn("if let error = error as? GroupSubscriptionError {", presentation)
        self.assertIn("case .ownerPlusRequired:", presentation)
        self.assertIn("case .windowPaused:", presentation)
        self.assertIn("これまでの写真・メンバー・ハートはそのままです。", presentation)
        self.assertIn("window.deliveryStatus == .paused", presentation)
        # Never says anything is deleted.
        for forbidden in ("削除", "消え"):
            self.assertNotIn(forbidden, section(presentation, "static let pausedDetail", "static func pausedOwnerName"))

        paused = section(view, "private func pausedSection(", "private func statusSection(")
        self.assertIn('Label("このまどは止まっています"', paused)
        self.assertIn('Text("このまどを続ける")', paused)
        self.assertIn("showsPlusOffer = true", paused)
        # The one Plus screen, with the continue-window context only.
        self.assertEqual(view.count("MembershipOfferSheet("), 1)
        self.assertIn("MembershipOfferSheet(model: plusOfferModel(), context: .continueWindow)", view)
        self.assertIn("plusOfferModel: { .preview() }", view)
        checks = source("ci/run-cheap-safety-checks.sh")
        self.assertIn("NekoWidget/Views/GroupWindowSetupView.swift", checks)
        self.assertIn("がPlusを続けると、また届くようになります。", paused)
        # A paused window's member is not sold a window of their own here.
        for nudge in ("自分でまどを作る", "group-window-create-own", "onCreateOwnWindow", "14日間無料"):
            self.assertNotIn(nudge, paused)
        self.assertIn("GroupWindowPresentation.isMyWindow(window)", paused)
        # Owner sees continue; members see who can resume.
        self.assertLess(paused.index("if !GroupWindowPresentation.isMyWindow(window)"), paused.index('"group-window-paused"'))

        perform = section(view, "private func perform(", "struct GroupWindowScreenCapabilities")
        subscription = section(perform, "catch let error as GroupSubscriptionError {", "catch let error as GroupClientError {")
        self.assertIn("retainedOperations[key] = nil", subscription)
        self.assertIn("await load()", subscription)

        # The fixture override is DEBUG-only and the transform defaults to identity.
        self.assertIn("transform: @escaping (GroupWindow) -> GroupWindow = { $0 }", view)
        debug = section(view, "// MARK: - DEBUG fixture entry", "struct GroupWindowUIFixtureRoot: View")
        self.assertIn("static func applyDelivery(", debug)
        self.assertIn('"--group-window-delivery="', debug)


class GroupWindowScreenTests(unittest.TestCase):
    def test_group_photos_are_checked_kept_then_acknowledged(self) -> None:
        screen = source("NekoWidget/Views/GroupWindowView.swift")
        for forbidden in ("URLSession", "Keychain", "UserDefaults", "print(", "SharedLog", "roomKey"):
            self.assertNotIn(forbidden, screen)
        # Received photos: sensitive-content check, then the durable write,
        # and only inside keep(), which the production adapter runs through storeAndAcknowledge (so ACK follows the write).
        receive = section(screen, "private func receive(", "func prepare(_ item: PhotosPickerItem) async")
        self.assertIn("GroupPhotoModeration.check(incoming.jpeg, with: moderation)", receive)
        self.assertIn("guard verdict != .retryLater, verdict != .checkOff else { return verdict }", receive)
        self.assertIn("client.keep(incoming, outgoingOperationID: outgoingOperationID)", receive)
        self.assertLess(receive.index("GroupPhotoModeration.check"), receive.index("client.keep("))
        self.assertIn("try await store.save(", receive)
        self.assertIn("jpeg: hidden ? nil : jpeg", receive)
        # Sending: the same canonical JPEG and check as the two-person window.
        send = section(screen, "func prepare(_ item: PhotosPickerItem) async", "func toggleHeart(")
        self.assertIn("guard canSend", send)
        self.assertLess(send.index("GroupPhotoModeration.check(picked.jpeg"), send.index("client.sendPhoto("))
        self.assertIn("outgoingOperationID: operationID", send)
        self.assertIn("MomentShareIngressService().prepare(fromFileURL: received.file).canonicalJPEG", screen)
        # Paused windows cannot send; the card points to who can resume.
        self.assertIn("guard !isFormer, let window, window.state == .active, !isPaused else { return false }", screen)
        self.assertIn('"group-window-screen-paused"', screen)

        store = source("NekoWidget/Services/GroupWindowLocalPhotoStore.swift")
        self.assertIn('? "GroupWindows-production" : "GroupWindows"', store)
        self.assertIn(".completeFileProtectionUntilFirstUserAuthentication", store)
        save = section(store, "func save(", "// MARK: - Files")
        # The image is written before the index lists it.
        self.assertLess(save.index("photoURL(photoID: entry.id"), save.index("indexURL(windowID: windowID)"))
        self.assertIn('SHA256.hash(data: Data("group-window|', store)
        for forbidden in ("MomentSharingStateStore", "SharedContainer", "PairingStateStore"):
            self.assertNotIn(forbidden, store)

        tab = source("NekoWidget/Views/MainTabView.swift")
        self.assertIn("if let client = GroupWindowClientProvider.ui {", tab)
        self.assertIn("GroupWindowListSection(client: client, compactHeader: Version1.isOn)", tab)
        project = source("NekoWidget.xcodeproj/project.pbxproj")
        self.assertIn("GroupWindowView.swift in Sources", project)
        self.assertIn("GroupWindowLocalPhotoStore.swift in Sources", project)


class GroupWidgetCacheTests(unittest.TestCase):
    def test_widget_reads_only_the_apps_verified_copy(self) -> None:
        cache = source("Shared/Sharing/GroupWidgetCache.swift")
        for forbidden in ("Keychain", "URLSession", "roomKey", "SymmetricKey", "ProductionGroupWindowClient", "print("):
            self.assertNotIn(forbidden, cache)
        self.assertIn('? "GroupWidget-production" : "GroupWidget"', cache)
        update = section(cache, "static func update(", "// MARK: Files")
        # The image is written before the catalog that points to it.
        self.assertLess(update.index("try write(small"), update.index('appendingPathComponent("catalog.json")'))
        self.assertIn("kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize", cache)
        self.assertIn("static let maximumPixelSize = 1_000", cache)

        # Only the app writes; the Widget never calls update.
        for widget_file in (
            "NekoWidgetWidget/NekoWidgetTimelineProvider.swift",
            "NekoWidgetWidget/NekoWidgetConfigurationIntent.swift",
            "NekoWidgetWidget/WidgetCacheImageLoader.swift",
            "NekoWidgetWidget/NekoWidgetView.swift",
            "NekoWidgetWidget/ToggleWidgetLikeIntent.swift",
        ):
            self.assertNotIn("GroupWidgetCache.update(", source(widget_file))

        screen = source("NekoWidget/Views/GroupWindowView.swift")
        home = section(screen, "    func updateHomeScreenPhoto() async {", "private func receive(")
        self.assertIn("entries.first { !$0.isHidden && !safety.hasReported($0.id, in: windowID) }", home)
        self.assertIn("GroupWidgetCache.update(", home)
        self.assertIn('WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")', home)

        provider = source("NekoWidgetWidget/NekoWidgetTimelineProvider.swift")
        group = section(provider, "private func groupEntry(", "private func familyEntry(")
        self.assertIn("isBookmarkInteractionEnabled: false", group)
        self.assertIn("familyHeartStatus: cached.myHeartActive == true ? .serverAccepted : .ready", group)
        self.assertIn("emptyStateReason: .sourceUnavailable", group)
        intent = source("NekoWidgetWidget/NekoWidgetConfigurationIntent.swift")
        # A missing group window never becomes the personal-library default.
        resolve = section(intent, "if let groupWindowID = GroupWidgetCache.windowID(fromSourceID: id) {", "guard let localWindowID")
        self.assertIn('"使えなくなったまど"', resolve)

        project = source("NekoWidget.xcodeproj/project.pbxproj")
        widget_sources = section(project, "A00000000000000000000025 /* Sources */ = {", "A00000000000000000000028 /* Sources */")
        self.assertIn("GroupWidgetCache.swift in Sources", widget_sources)
        self.assertNotIn("ProductionGroupWindowClient.swift in Sources", widget_sources)
        self.assertNotIn("GroupWindowStorage.swift in Sources", widget_sources)


class GroupInvitationAssociatedDomainTests(unittest.TestCase):
    def test_only_the_app_claims_the_invitation_domain(self) -> None:
        import plistlib
        with (ROOT / "NekoWidget/NekoWidget.entitlements").open("rb") as handle:
            app = plistlib.load(handle)
        # applinks only, exactly the invitation domain (AASA limits it to /join).
        self.assertEqual(app["com.apple.developer.associated-domains"], ["applinks:nekonomado.com"])
        for extension in (
            "NekoWidgetWidget/NekoWidgetWidget.entitlements",
            "NekoWidgetShareExtension/NekoWidgetShareExtension.entitlements",
        ):
            with (ROOT / extension).open("rb") as handle:
                self.assertNotIn("com.apple.developer.associated-domains", plistlib.load(handle))


class CatCareTests(unittest.TestCase):
    def test_cat_care_stays_on_this_iphone_and_never_overwrites(self) -> None:
        core = source("NekoWidget/Services/CatCareCore.swift")
        store = source("NekoWidget/Services/CatCareStore.swift")
        view = source("NekoWidget/Views/CatCareView.swift")
        # Health information is never sent, logged, or put in widgets or notifications.
        for text in (core, store, view):
            for forbidden in ("URLSession", "SharedLog", "print(", "UNUserNotificationCenter",
                              "WidgetCenter", "GroupWindowClient", "MomentSharing"):
                self.assertNotIn(forbidden, text)
        self.assertEqual(core.count("import "), 1)  # Foundation only; runs in CI
        # CatCare follows the atomic restore dataset; it still cannot rewrite
        # recognition or other tools. Stale editors cannot save to a new root.
        self.assertIn('AppRecordDataset.directory("CatCare")', store)
        self.assertIn("guard loadedURL == fileURL", store)
        self.assertIn("AppRecordDataset.requireWritable(fileURL)", store)
        for forbidden in ("CatHouseholdIdentityStore", "CareHandoffStore.shared.update",
                          "EvacuationStore.shared.update"):
            self.assertNotIn(forbidden, store)
        self.assertIn("guard canSave", store)
        self.assertIn("unreadableCatCount == 0", store)
        self.assertIn("onDisk.state.mutationRevision == expected", store)
        # Import fills empty fields only.
        fill = section(core, "private static func fill(", "// MARK: - Reading a file")
        self.assertIn("field == nil", fill)
        # Microchip shown in full (owner decision 10/20).
        self.assertIn("Shown in full on screen and on paper", core)
        self.assertNotIn("suffix(4)", view)
        self.assertIn('CatCareTextField(label: "マイクロチップ番号", example: "15桁の数字", text: $draft.microchip', view)
        # Vaccination proof can come from Photos.
        self.assertIn("証明の写真を選ぶ", view)
        # Deleting marks, never removes.
        self.assertIn("markDeleted", view)
        self.assertNotIn(".remove(at:", view)
        tab = source("NekoWidget/Views/MainTabView.swift")
        # 10/22: the cat's card on the ツール tab opens the cat's page, whose
        # title switch leads to この子のこと (CatCareDetailView).
        self.assertIn("CatChip(profile: profile, progress: careProgress(for: profile),", tab)
        # 11/1: a cat whose farewell day is recorded shows no ring.
        self.assertIn("departed: farewellDays[profile.identifier] != nil)", tab)
        detail = source("NekoWidget/Views/CatProfilePhotoCurationViews.swift")
        # 11/7: the cat's page is この子のこと only, with no tabs.
        page = section(detail, "struct CatProfileDetailView: View", "struct CatProfileAddPhotosButton: View")
        self.assertNotIn('"cat-profile-page"', page)
        self.assertIn("CatCareDetailView(profile: profile, otherProfiles: [], selectedProfileID: .constant(profile.identifier))", page)
        checks = source("ci/run-quick-ios-checks.sh")
        self.assertIn("ci/verify-cat-care.swift", checks)
        project = source("NekoWidget.xcodeproj/project.pbxproj")
        for name in ("CatCareCore.swift", "CatCareStore.swift", "CatCareView.swift"):
            self.assertIn(name + " in Sources", project)


class VeterinaryCatCareTests(unittest.TestCase):
    def test_vet_shows_and_exports_cat_care_without_copying_it(self) -> None:
        view = source("NekoWidget/Views/VeterinaryVisitView.swift")
        summary = source("NekoWidget/Services/CatCareOutputLines.swift")
        self.assertIn("CatCareSummary.veterinaryFields(", view)
        self.assertIn('editIdentifier: "vet-open-cat-care"', view)
        self.assertNotIn("以前の薬やお世話情報は自動で入りません", view)
        # Matched by the saved identity, never by name.
        self.assertIn("CatCareSummary.record(toolCatID: visit.catID, profileIdentifier: visit.catID.uuidString)", view)
        record = section(source("NekoWidget/Views/CatCareView.swift"), "static func record(profileIdentifier: String)", "/// The record for a tool's cat")
        self.assertIn("$0.profileID == profileID", record)
        self.assertNotIn("name", record)
        # Export: PDF or images in the screen's order (11/8), with a caution line,
        # in the same temporary folder the 預けるとき cleanup removes.
        export = section(view, "private func makeExport(pdf: Bool) async {", "private struct VeterinaryCatCareFields")
        self.assertIn("VeterinaryMemoExporter.create(name: displayName ?? visit.catName, blocks: blocks, pdf: pdf)", export)
        self.assertIn("医療の判断ではありません", export)
        self.assertIn("CareHandoffExporter.remove(retainedDirectory)", view)
        exporter = section(view, "private enum VeterinaryMemoExporter {", "\n}\n")
        self.assertIn('private static let prefix = "neko-care-handoff-"', exporter)
        self.assertIn("[.atomic, .completeFileProtection]", exporter)
        self.assertIn("catch { CareHandoffExporter.remove(directory); throw error }", exporter)
        # Empty items say so instead of inventing anything.
        fields = section(summary, "static func veterinaryFields(", "static func weightTrend(")
        self.assertIn('"未記入（飼い主に聞いてください）"', fields)
        self.assertIn('("マイクロチップ", record?.microchipStatus == CatCareMicrochipStatus.none', fields)
        self.assertIn('? "入っていない（飼い主の記入）" : text(record?.microchip?.value)))', fields)
        trend = summary[summary.index("static func weightTrend("):]
        self.assertIn("前回から", trend)


class LostCatToolReview1108Tests(unittest.TestCase):
    """迷子のとき, round 1 of the 11/8 tool review."""

    def test_social_and_a4_are_judged_apart_and_keep_their_sizes(self) -> None:
        store = source("NekoWidget/Services/CatPreparednessStore.swift")
        renderer = section(store, "enum LostCatFlyerRenderer {", "private static func draw(")
        # Each output has its own issues; the A4 never stops the SNS image.
        self.assertIn("static func issues(_ draft: LostCatPublicDraft, paper: Bool)", renderer)
        self.assertIn("guard fits(draft, paper: false)", renderer)
        self.assertIn("guard fits(draft, paper: true)", renderer)
        view = source("NekoWidget/Views/CatPreparednessView.swift")
        preview = section(view, "private struct LostCatPreviewView", "private struct LostCatActivitySheet")
        self.assertIn("LostCatFlyerRenderer.issues(draft, paper: format == 1)", preview)
        self.assertNotIn("validationIssues", preview)
        # Every A4 or SNS overflow names a field, so a red line is always beside it.
        self.assertNotIn('issues["layout"]', renderer)
        self.assertIn('"\\(paper ? "A4" : "SNSの画像")に入りきりません。\\(label)を短くしてください。"', renderer)
        self.assertIn('"features": "特徴"', renderer)
        # The SNS image stays 1080x1350: letters and photo shrink, the canvas never grows.
        self.assertIn("private static let socialSize = CGSize(width: 1080, height: 1350)", renderer)
        self.assertNotIn("canvas.height +=", renderer)
        self.assertIn("let canvas = paper ? paperSize : socialSize", renderer)
        self.assertIn("if !compact { return layout(draft, format: format, compact: true) }", renderer)
        # A4 contact is 32pt or larger and above the name; the title is white on a red band.
        self.assertIn("maxSize: paper ? (compact ? 32 : 36) : 48, minSize: paper ? 32 : 37", renderer)
        self.assertIn('id: "name", maxSize: paper ? (compact ? 23 : 30) : 53', renderer)
        self.assertIn("height: titleHeight, color: .white, centered: true", renderer)
        self.assertIn("context.fill(plan.titleBand)", store)

    def test_date_is_left_out_when_unknown_and_written_plainly(self) -> None:
        store = source("NekoWidget/Services/CatPreparednessStore.swift")
        public = section(store, "struct LostCatPublicDraft {", "enum LostCatFlyerRenderer {")
        self.assertNotIn("不明", public)
        self.assertIn("var lastSeenDescription: String? {", public)
        self.assertIn('formatter.locale = Locale(identifier: "ja_JP")', public)
        self.assertIn('formatter.dateFormat = "M月d日（E）H時ごろ"', public)
        self.assertIn('parts.append("最後に見かけた日時：\\(lastSeenDescription)")', public)
        self.assertIn('static let hashtags = "#迷子猫 #迷い猫"', public)
        self.assertIn("parts.append(Self.hashtags)", public)
        renderer = section(store, "enum LostCatFlyerRenderer {", "private static func draw(")
        self.assertIn("if let lastSeen = draft.lastSeenDescription {", renderer)
        self.assertIn('field("最後に見かけた日時：\\(lastSeen)"', renderer)
        # 347: labels read 「場所：公園」; whole photos sit on white, no gray bars.
        self.assertIn('field("最後に見かけた場所：\\(placeValue)"', renderer)
        self.assertNotIn("UIColor(white: 0.96, alpha: 1).setFill()", store)
        self.assertNotIn('"日時  ', renderer)

    def test_share_sends_image_and_post_with_plain_names(self) -> None:
        view = source("NekoWidget/Views/CatPreparednessView.swift")
        preview = section(view, "private struct LostCatPreviewView", "private struct LostCatActivitySheet")
        self.assertIn('.navigationTitle("できあがり")', preview)
        self.assertIn('Button("保存・共有する", systemImage: "square.and.arrow.up")', preview)
        self.assertIn("text: format == 0 ? draft.message : nil", preview)
        self.assertIn("LostCatActivitySheet(items: item.items)", preview)
        self.assertIn("if let text { return [url, text] }", view)
        # 11/8 tool shape: the button names what it makes.
        self.assertIn('Button("チラシを作る") { openPreview() }', view)
        self.assertNotIn("チラシを見る", view)
        self.assertNotIn("できあがりを見る", view)
        self.assertNotIn('"プレビュー"', view)

    def test_reporting_lives_in_step_two_of_the_guide(self) -> None:
        view = source("NekoWidget/Views/CatPreparednessView.swift")
        form = section(view, "struct LostCatDraftView: View {", "private var catSection: some View {")
        self.assertNotIn("            reportSection\n", form)
        self.assertIn("LostCatGuideView { reportSection }", form)
        guide = section(view, "private struct LostCatGuideView<Report: View>: View {", "#if DEBUG")
        step2 = section(guide, 'Section("2  届け出て、保護されていないか確かめる")', 'Section("3  写真で周囲に知らせる")')
        self.assertIn("警察には遺失届を出します。", step2)
        self.assertIn("マイクロチップの登録の連絡先が今のものか確かめます。", step2)
        self.assertIn("report()", step2)
        # The poster notice is said once, in step 3.
        self.assertEqual(view.count("チラシを貼るとき"), 1)
        self.assertIn('ToolImportantInformation(text: "チラシを貼るときは、その場所の管理者に確かめてください。")', guide)
        # まとめてコピー carries only written lines.
        report = section(view, "@ViewBuilder private var reportSection", "private var catCareRecord")
        self.assertIn("Self.reportCopy(name: profile.displayName, fields: fields)", report)
        self.assertIn('fields.filter { !$0.1.hasPrefix("未記入") && !$0.1.hasPrefix("未確認") }', report)

    def test_photos_start_with_this_cat_and_any_photo_is_a_visible_button(self) -> None:
        view = source("NekoWidget/Views/CatPreparednessView.swift")
        choice = section(view, "private struct LostCatPhotoChoiceView: View {", "private struct LostCatPhotoCropView")
        self.assertNotIn("Menu {", choice)
        self.assertNotIn("「…」", choice)
        self.assertIn('Button("iPhoneの写真から選ぶ", systemImage: "photo.on.rectangle")', choice)
        self.assertEqual(choice.count("systemPickerButton"), 3)
        self.assertIn("showsAllCats || ownPhotos.isEmpty ? allPhotos : ownPhotos", choice)
        self.assertLess(choice.index('Text("この子").tag(false)'), choice.index('Text("猫の写真").tag(true)'))
        self.assertIn('Button("「この子のこと」の写真を使う", systemImage: "photo")', view)
        self.assertNotIn("保存してある写真を使う", view)
        self.assertIn('photoTile("顔・毛柄の写真", role: .face', view)
        self.assertNotIn("・前の写真", view)

    def test_input_page_has_the_shared_tool_shape(self) -> None:
        view = source("NekoWidget/Views/CatPreparednessView.swift")
        form = section(view, "struct LostCatDraftView: View {", "private var catSection: some View {")
        # Top to bottom: purpose, the guide, steps 1-3, then errors last.
        order = ['ToolPurpose(text: "探すためのチラシを作ります。")',
                 'Label("先にすること：探す・届け出る", systemImage: "info.circle")',
                 "catSection.disabled(!loaded)", "incidentSection.disabled(!loaded)",
                 "contactSection.disabled(!loaded)", 'Text("前に入れた内容を読み込めませんでした。")',
                 'Label("保存できませんでした"']
        positions = [form.index(text) for text in order]
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn("まず探す・届け出る", view)
        # Numbered steps; each is done when what the flyer needs is there.
        self.assertIn('ToolStepHeader(number: 1, title: "写真と特徴", state: stepStates[0])', view)
        self.assertIn('ToolStepHeader(number: 2, title: "いなくなった場所と日時", state: stepStates[1])', view)
        self.assertIn('ToolStepHeader(number: 3, title: "見かけた人からの連絡先", state: stepStates[2])', view)
        states = section(view, "private var stepStates: [ToolStepState] {", "private var canPreview: Bool {")
        self.assertIn("ToolStepState.states([", states)
        self.assertLess(states.index("faceImage != nil"), states.index("draft.lastSeenNear"))
        self.assertLess(states.index("draft.lastSeenNear"), states.index("draft.contact"))
        for old in ('Text("猫の写真と特徴")', 'Text("最後に見かけた場所・日時")', 'Text("見かけた方からの連絡")'):
            self.assertNotIn(old, view)
        # Labels above the fields, examples inside, optional ones say so.
        self.assertIn('Text("名前（任意）").font(.subheadline).foregroundStyle(.secondary)', view)
        self.assertIn('prompt: Text("例：むぎ")', view)
        self.assertIn('Text("場所").font(.subheadline).foregroundStyle(.secondary)', view)
        self.assertIn('Text("連絡先").font(.subheadline).foregroundStyle(.secondary)', view)
        self.assertIn('prompt: Text("例：電話番号・メール・SNS")', view)
        self.assertIn('Text("日時（任意）")', view)
        self.assertNotIn('LabeledContent("名前") {', view)
        # The page reads no 「この子のこと」 box itself; reporting stays in the guide.
        self.assertNotIn("ToolCatCareSection(", form)
        # One bar: 「あと：…」 or the issue sentence, and 「チラシを作る」.
        bar = section(form, ".toolBottomBar {", ".navigationDestination(isPresented: $showsPreview)")
        self.assertIn('Button("チラシを作る") { openPreview() }', bar)
        self.assertIn("ToolMakeBar(missing: issues.isEmpty ? requiredFields : []) {", form)
        self.assertIn('Text("直すところがあります。赤い文字の欄を見てください")', form)
        self.assertIn(".disabled(!canPreview)", form)
        self.assertNotIn("を入れると作れます", view)
        required = section(view, "private var requiredFields: [String] {", "private var stepStates")
        for name in ('"写真"', '"場所"', '"連絡先"'):
            self.assertIn(name, required)

    def test_input_examples_and_empty_state_sentences(self) -> None:
        view = source("NekoWidget/Views/CatPreparednessView.swift")
        self.assertIn('TextField("例：○○町2丁目・○○公園の近く", text: $draft.lastSeenNear)', view)
        self.assertIn('example: "例：追いかけず、見かけた場所をお知らせください。お礼をいたします"', view)
        profiles = source("NekoWidget/Views/CatProfilesView.swift")
        picker = section(profiles, "struct ToolCatPicker<Legacy: View>: View {", ".alert(")
        self.assertIn("var purpose: String? = nil", picker)
        self.assertIn('if let purpose { Text(purpose).accessibilityIdentifier("tool-profile-purpose") }', picker)
        self.assertIn('purpose: "探す猫を選んでください。まだいなければ追加します。"', view)
        self.assertIn('purpose: "猫を追加すると、預ける人に渡すメモを作れます。"',
                      source("NekoWidget/Views/CareHandoffView.swift"))


class LostCatCatCareTests(unittest.TestCase):
    def test_lost_cat_reads_cat_care_without_publishing_private_details(self) -> None:
        view = source("NekoWidget/Views/CatPreparednessView.swift")
        summary = source("NekoWidget/Services/CatCareOutputLines.swift")
        store = source("NekoWidget/Services/CatPreparednessStore.swift")
        # The public flyer value is unchanged: no chip number, medicine or report field.
        public = section(store, "struct LostCatPublicDraft {", "enum LostCatFlyerRenderer {")
        for forbidden in ("microchip", "CatCare", "medication", "report"):
            self.assertNotIn(forbidden, public)
        # Reporting details are shown in the app only.
        report = section(view, "@ViewBuilder private var reportSection", "private var catCareRecord")
        self.assertIn("CatCareSummary.lostCatReportFields(catCareRecord)", report)
        self.assertIn("チラシ・画像には載りません", report)
        self.assertIn('editIdentifier: "lost-cat-open-cat-care"', report)
        fields = section(summary, "static func lostCatReportFields(", "/// Newest first")
        self.assertIn('("マイクロチップ番号", record?.microchipStatus == CatCareMicrochipStatus.none', fields)
        self.assertIn('? "入っていない（飼い主の記入）" : text(record?.microchip?.value)))', fields)
        # The flyer line says only that there is a chip.
        core = source("NekoWidget/Services/CatCareCore.swift")
        line = section(core, "static func publicLine(", "static func age(")
        # Empty and explicit none must not claim a chip on the public flyer.
        self.assertIn('microchipStatus == .recorded { parts.append("マイクロチップあり") }', line)
        self.assertNotIn("parts.append(record?.microchip", line)
        # The published contact is added by a tap, never filled on its own.
        fill = section(view, "private func fillFromCatCare(", "@ViewBuilder private func fieldIssue(")
        self.assertNotIn("contact", fill)
        self.assertIn("「この子のこと」の連絡先を使う", view)
        # A new draft starts from 「この子のこと」; owner text is never replaced.
        self.assertIn("if !alreadyPrepared { saved = fillFromCatCare(saved, key: identity) }", view)
        self.assertIn("next.features.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty", fill)
        self.assertIn("== nil", fill)
        load = section(view, "private func load(_ identity:", "private func switchTo(")
        self.assertLess(load.index("try store.hasPreparedRecord(for: identity)"), load.index("fillFromCatCare"))


class EvacuationCatCareTests(unittest.TestCase):
    def test_evacuation_reads_cat_care_and_makes_one_paper_copy(self) -> None:
        plan = source("NekoWidget/Services/EvacuationPlan.swift")
        store = source("NekoWidget/Services/EvacuationStore.swift")
        view = source("NekoWidget/Views/EvacuationPreparationView.swift")
        exporter = source("NekoWidget/Services/EvacuationExporter.swift")
        summary = source("NekoWidget/Services/CatCareOutputLines.swift")
        # A fuller starter list; adding never edits what the owner already has.
        for item in ("ワクチン証明の控え", "首輪・迷子札", "洗濯ネット", "ハーネス・リード"):
            self.assertIn(item, plan)
        add = section(plan, "mutating func addRecommendedSupplies()", "mutating func removeCat(")
        self.assertIn("!titles.contains(title)", add)
        self.assertNotIn("supplies[", add)
        self.assertIn('"\\(cats)個（1匹に1つ）"', plan)
        # Vaccinations, proofs and the chip come from 「この子のこと」; the tool ID is matched first.
        share = section(store, "func shareRecord(", "func bookRecords()")
        self.assertIn("if disclosure.catCare {", share)
        self.assertIn("CatCareSummary.evacuationShareFields(care, legacy: cat,", share)
        self.assertIn("attachments.append", share)
        matching = section(source("NekoWidget/Views/CatCareView.swift"), "static func record(toolCatID:", "\n}\n")
        self.assertLess(matching.index("$0.catID == toolCatID"), matching.index("record(profileIdentifier:"))
        self.assertIn('("マイクロチップ番号", chip.isEmpty', summary)
        self.assertIn('? (record?.microchipStatus == CatCareMicrochipStatus.none ? "入っていない（飼い主の記入）" : empty) : chip))', summary)
        # One PDF: supplies, destinations and every cat, after a confirmation.
        book = section(store, "func bookRecords()", "private static func normalizedJPEG(")
        self.assertIn("for cat in plan.cats { records.append(try shareRecord(", book)
        self.assertIn("disclosure.medical = true", book)
        self.assertIn("static func createBook(", exporter)
        self.assertIn("all.count <= 120", exporter)
        self.assertIn("record.attachments", exporter)
        self.assertIn("EvacuationExporter.createBook(store.bookRecords())", view)
        self.assertIn("EvacuationExporter.remove(retainedBookDirectory)", view)
        self.assertIn('confirmationDialog("印刷用のPDFを作ります"', view)
        # The half-year review is a quiet in-app note, not a notification.
        self.assertIn("halfYear", plan)
        self.assertIn("store.plan.reviewIsDue(", view)
        self.assertNotIn("UNUserNotificationCenter", view)
        self.assertNotIn("UNUserNotificationCenter", plan)

    def test_evacuation_round_one_fixes_1108(self) -> None:
        plan = source("NekoWidget/Services/EvacuationPlan.swift")
        store = source("NekoWidget/Services/EvacuationStore.swift")
        view = source("NekoWidget/Views/EvacuationPreparationView.swift")
        # Fields added 11/8 are optional, so plans saved before still decode;
        # ci/verify-evacuation-plan.swift decodes an old plan and runs the rules.
        for field in ("var createdAt: Date?", "var lastCheckedAt: Date?", "var address: String?", "var kindValue: String?"):
            self.assertIn(field, plan)
        self.assertIn("var schemaVersion = 1", plan)
        self.assertIn("guard schemaVersion == 1,", plan)
        checks = source("ci/run-quick-ios-checks.sh")
        self.assertIn("NekoWidget/Services/EvacuationPlan.swift ci/verify-evacuation-plan.swift", checks)
        self.assertIn('"$RUNNER_TEMP/evacuation-plan-tests"\n', checks)
        verify = source("ci/verify-evacuation-plan.swift")
        for name in ("try oldDataDecodes()", "try amountsFollowCatCount()", "try medicinesFollowCatCare()",
                     "try reviewCountsFromCreation()", "try destinations()"):
            self.assertIn(name, verify)
        # The review counts from when the plan was made, and leads to the checklist.
        self.assertIn("let start = createdAt ?? earliestKnownDate ?? now", plan)
        self.assertIn("if createdAt == nil { createdAt = earliestKnownDate ?? now }", plan)
        update = section(store, "func update(_ change:", "func retrySave()")
        self.assertIn("next.stampCreation()", update)
        self.assertIn('Button("見直しを始める") { startReview() }', view)
        review = section(view, "private func startReview() {", "private func show(")
        self.assertIn("$0.clearChecks()", review)
        self.assertIn("openPacking = true", review)
        self.assertIn('Button("閉じる")', view)
        # Amounts the app wrote follow the cats; the owner's amounts never change.
        follow = section(plan, "mutating func followCatCount()", "mutating func followMedicines(")
        self.assertIn("(1...30).contains(where: { Self.recommendedQuantity(title, cats: $0) == quantity })", follow)
        self.assertIn("carriedIDs.remove(supplies[index].id)", follow)
        self.assertIn("followCatCount()", section(plan, "mutating func removeCat(", "mutating func followCatCount()"))
        self.assertIn("next.followCatCount()", section(store, "func addCat(", "func refreshCandidates("))
        medicines = section(plan, "mutating func followMedicines(", "mutating func toggleCarried(")
        self.assertIn('if supplies[index].title.hasPrefix("薬："), supplies[index].title != title {', medicines)
        # The checklist follows 「この子のこと」 each time it opens.
        packing = section(view, "private struct EvacuationPackingView", "private struct EvacuationGuidelineLink")
        self.assertIn(".task { store.followCatsAndMedicines() }", packing)
        self.assertIn('Text("そろっているもの  \\(confirmedCount) / \\(needed.count)")', packing)
        self.assertIn('Text("最後にそろえた日：', packing)
        for old in ("今回、持ったもの", "チェックを始めた日"):
            self.assertNotIn(old, view)
        # The show screen is named for what it makes, one tap from the entry.
        self.assertIn('Label("避難メモを見せる"', view)
        self.assertNotIn("見せる画面を開く", view)
        self.assertIn('.navigationTitle("\\(record.name)の避難メモ")', view)
        for old in ("できあがりを見る", '"プレビュー"', "1冊のPDFにまとめる", "新しい持ち物"):
            self.assertNotIn(old, view)
        self.assertIn('"evacuation-show-\\(cat.id.uuidString)"', view)
        self.assertIn("EvacuationPreviewItem(record: try store.shareRecord(catID: cat.id, disclosure: EvacuationDisclosure()))", view)
        # The owner's paper copy has the photo with the owner; the button says it prints.
        self.assertIn("disclosure.withOwnerPhoto = true", section(store, "func bookRecords()", "private static func normalizedJPEG("))
        book = section(view, "@ViewBuilder private var bookButton", "private struct EvacuationSaveNotice")
        self.assertIn('Label("印刷用のPDFを作る"', book)
        self.assertIn("if hasContent { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }", book)
        # Each entry row shows one state.
        for state in ('個は置き場所が未記入"', '"写真なし："', '"行き先 \\(store.plan.destinations.count)件"'):
            self.assertIn(state, view)
        # Places: why it cannot be pressed, optional source, the day kept unless the conditions change.
        self.assertIn('Text("施設名と条件を書くと押せます")', view)
        self.assertIn(".disabled(!place.canConfirm)", view)
        self.assertIn("![name, conditions].contains", plan)
        self.assertIn("if key == \\EvacuationDestination.conditions { checkedAt = nil }", plan)
        self.assertIn('TextField("どこで確かめたか（任意）"', view)
        self.assertIn('TextField("住所（任意）"', view)
        self.assertIn('"https://maps.apple.com/?q="', plan)
        self.assertIn('URL(string: "tel:" + digits)', plan)
        self.assertIn(".keyboardType(.phonePad)", view)
        self.assertIn("if let url = place.telephoneURL {", view)
        for kind in ('"避難所"', '"親戚・知人"', '"ペットホテル・病院"'):
            self.assertIn(kind, plan)
        # Contacts and the vet are read here; written only in 「この子のこと」.
        self.assertIn('ToolCatCareSection(title: "連絡先と病院", lines: store.contactLines(includeEmpty: true),', view)
        self.assertIn("places += contactLines()", store)
        self.assertNotIn("setHouseholdText(new, \\.ownerContact", view)
        # New items start empty with the name ready; multi-cat empty page says how.
        self.assertIn('EvacuationSupply(title: "")', view)
        self.assertIn("nameFocused = true", view)
        self.assertIn('Text("上の猫を選ぶと作れます。")', view)
        # One outside link: 環境省, marked as needing a connection.
        self.assertEqual(view.count("Link(destination: URL(string: \"https://"), 1)
        self.assertIn('ExternalLinkRow("環境省「人とペットの災害対策ガイドライン」（通信が必要）"', view)
        self.assertNotIn("metro.tokyo", view)

    def test_evacuation_follows_the_input_page_shape_1108(self) -> None:
        view = source("NekoWidget/Views/EvacuationPreparationView.swift")
        # Hub: the review card, one sentence, three numbered steps, 「見せる」, the note.
        hub = section(view, "struct EvacuationPreparationView: View {", "private func makeBook() async {")
        order = ['"evacuation-review-reminder"',
                 'ToolPurpose(text: "災害のときに持ち出すものと、猫の避難メモを用意します。")',
                 "let states = ToolStepState.states(stepsDone)",
                 'step(1, "持ち出すもの", detail: packingState, state: states[0])',
                 'step(2, "猫の情報", detail: catsState, state: states[1])',
                 'step(3, "行き先と連絡先", detail: "行き先 \(store.plan.destinations.count)件", state: states[2])',
                 '} header: { Text("見せる") }',
                 'ToolImportantInformation(text: "災害のときは、まず自分と家族の安全を守ってください。")',
                 ".toolBottomBar {"]
        positions = [hub.index(needle) for needle in order]
        self.assertEqual(positions, sorted(positions))
        for identifier in ('"evacuation-packing-open"', '"evacuation-cats-open"', '"evacuation-destinations-open"'):
            self.assertIn(identifier, hub)
        self.assertIn("ToolStepHeader(number: number, title: title, state: state)", view)
        self.assertNotIn("private func entry(", view)
        # Done rules: every item has a place, every cat a photo to tell it apart, one place.
        done = section(view, "private var stepsDone: [Bool] {", "private var missingSteps: [String] {")
        self.assertIn("!needed.isEmpty && needed.allSatisfy { !$0.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }", done)
        self.assertIn("!cats.isEmpty && cats.allSatisfy { $0.identificationPhoto != nil }", done)
        self.assertIn("!store.plan.destinations.isEmpty", done)
        self.assertIn('var identificationPhoto: String? { photos["face"] ?? photos["body"] ?? photos["reference"] }', view)
        self.assertIn('cats.filter { $0.identificationPhoto == nil }.map { name(of: $0) }', view)
        # 「印刷用のPDFを作る」 is in the bottom bar, not in the list.
        bar = section(hub, ".toolBottomBar {", '.navigationTitle("避難に備える")')
        self.assertIn("ToolMakeBar(missing: missingSteps, top: {", bar)
        self.assertIn("EvacuationSaveNotice(store: store, inBar: true)", bar)
        self.assertIn("bookButton", bar)
        self.assertIn('.accessibilityIdentifier("evacuation-book-open")', bar)
        self.assertIn(".disabled(store.saveError != nil || makingBook)", bar)
        self.assertEqual(hub.count("bookButton"), 1)
        self.assertNotIn(".listRowInsets(EdgeInsets())", hub)
        self.assertNotIn(".safeAreaInset(edge: .bottom) { EvacuationSaveNotice(store: store) }", hub)
        self.assertIn('confirmationDialog("印刷用のPDFを作ります"', hub)
        # 猫の情報: one sentence, 1 見分ける写真, 2 見せる内容, この子のこと folded, then the rest small.
        cat_page = section(view, "private struct EvacuationCatView: View {", "private struct EvacuationCatEditor: View {")
        order = ['ToolPurpose(text: "避難所で見せる、この子の避難メモを作ります。")',
                 "let states = ToolStepState.states([cat.identificationPhoto != nil, true])",
                 '"evacuation-cat-edit"',
                 'ToolStepHeader(number: 1, title: "見分ける写真", state: states[0])',
                 '"evacuation-disclose-cat-care"',
                 'ToolStepHeader(number: 2, title: "見せる内容", state: states[1])',
                 "ToolCatCareSection(",
                 "profiles: profiles, folded: true)",
                 'ToolImportantInformation(text: "病歴・連絡先・ワクチンの証明・マイクロチップ番号は、必要な相手にだけ見せてください。")',
                 'Text("内容を確かめた日："',
                 'Button("内容を確かめた")',
                 'Button("この子の避難用の記録を削除", role: .destructive)',
                 ".toolBottomBar {"]
        positions = [cat_page.index(needle) for needle in order]
        self.assertEqual(positions, sorted(positions))
        cat_bar = section(cat_page, ".toolBottomBar {", ".navigationDestination(item: $preview)")
        self.assertIn('ToolMakeBar(missing: cat?.identificationPhoto == nil ? ["見分ける写真"] : [], top: {', cat_bar)
        self.assertIn("EvacuationSaveNotice(store: store, inBar: true)", cat_bar)
        self.assertIn("if let error { Text(error)", cat_bar)
        self.assertIn('Label("避難メモを見せる"', cat_bar)
        self.assertIn(".disabled(store.saveError != nil || cat == nil)", cat_bar)
        self.assertNotIn(".safeAreaInset(edge: .bottom) { EvacuationSaveNotice(store: store) }", cat_page)
        # The save error keeps its identifier wherever the notice is shown.
        notice = section(view, "private struct EvacuationSaveNotice: View {", "private struct EvacuationPackingView: View {")
        self.assertIn('.accessibilityIdentifier("evacuation-save-error")', notice)
        self.assertIn("if inBar { content } else { content.padding().frame(maxWidth: .infinity).background(.regularMaterial) }", notice)


class CareHandoffCatCareTests(unittest.TestCase):
    def test_care_handoff_reads_cat_care_and_asks_when_to_call(self) -> None:
        plan = source("NekoWidget/Services/CareHandoffPlan.swift")
        store = source("NekoWidget/Services/CareHandoffStore.swift")
        view = source("NekoWidget/Views/CareHandoffView.swift")
        summary = source("NekoWidget/Services/CatCareOutputLines.swift")
        # Older saved memos still decode: the new field is optional.
        self.assertIn("var callWhen: String?", plan)
        self.assertIn('("こんなときは連絡を", callWhen)', plan)
        self.assertIn('identifier: "care-call-when"', view)
        self.assertIn("おしっこが出ていない", view)
        self.assertIn("!current.contains(choice)".lstrip("!"), view)
        # Age and weight always; medicines and allergy only when health is shared.
        share = section(store, "func shareRecord(", "private static func normalizedJPEG(")
        self.assertIn("CatCareSummary.careHandoffLines(care, legacy: cat)", share)
        self.assertIn("health: CatCareSummary.careHandoffHealthLines(care, legacy: cat)", share)
        health = section(summary, "static func careHandoffHealthFields(", "/// For 「避難に備える」")
        self.assertIn("medicine.dose, medicine.schedule", health)
        # The editor only shows them; 「この子のこと」 stays the one place to change them.
        editor = section(view, "@ViewBuilder private func catCareSection(", "var body: some View {")
        self.assertIn('editIdentifier: "care-open-cat-care"', editor)
        self.assertNotIn("CatCareStore.shared.update", view)


class CareHandoffReviewTests(unittest.TestCase):
    """11/8 review of 「預けるとき」: only what is written, fewer steps, clearer names."""

    def setUp(self) -> None:
        self.plan = source("NekoWidget/Services/CareHandoffPlan.swift")
        self.store = source("NekoWidget/Services/CareHandoffStore.swift")
        self.exporter = source("NekoWidget/Services/CareHandoffExporter.swift")
        self.view = source("NekoWidget/Views/CareHandoffView.swift")
        self.summary = source("NekoWidget/Services/CatCareOutputLines.swift")

    def test_new_saved_fields_are_optional(self) -> None:
        for field in ("var includesHealth: Bool? = nil", "var includesContacts: Bool? = nil",
                      "var lastMadeAt: Date? = nil", "var photoRemoved: Bool? = nil"):
            self.assertIn(field, self.plan)
        self.assertIn("static let staleRequestAge: TimeInterval = 14 * 24 * 60 * 60", self.plan)
        self.assertIn("guard [1,2].contains(schemaVersion)", self.plan)

    def test_handed_memo_leaves_out_unwritten_rows(self) -> None:
        disclosure = section(self.plan, "struct CareHandoffDisclosure {", "static func vetFields(")
        self.assertNotIn("未記入（飼い主に聞いてください）", disclosure)
        self.assertIn('value.isEmpty || value.hasPrefix("未記入") || value.hasPrefix("未確認")', disclosure)
        self.assertEqual(disclosure.count("return Self.written(fields)"), 2)
        self.assertIn("return written([", disclosure)
        # The closed disclosure stays closed by default.
        self.assertIn("    var health = false\n    var contacts = false", disclosure)
        self.assertNotIn("写真はありません", self.exporter)
        self.assertNotIn("最後に書いた日", self.exporter)
        self.assertEqual(self.exporter.count("作った日："), 1)
        display = section(self.view, "private struct CareDisplayView: View {", "private func fields(")
        self.assertNotIn("写真はありません", display)
        # The app says what is missing before the memo is made.
        self.assertIn('"まだ書いていないこと\\(who)："', self.view)

    def test_vet_is_per_cat_with_note(self) -> None:
        vet = section(self.plan, "static func vetFields(", "\n}\n")
        self.assertIn("record?.vetOverride?.value ?? household?.vet?.value", vet)
        self.assertIn("vet.note", vet)
        self.assertIn("vet: CareHandoffDisclosure.vetFields(plan: plan, household: household, record: care)",
                      section(self.store, "func shareRecord(", "private static func normalizedJPEG("))
        contacts = section(self.plan, "static func contactFields(", "static func vetFields(")
        self.assertNotIn("かかりつけの動物病院", contacts)

    def test_indoor_cat_is_always_said(self) -> None:
        lines = section(self.summary, "static func careHandoffLines(", "static func careHandoffHealthLines(")
        self.assertIn('if record?.indoorOnly?.value == .yes { lines.append(("暮らし", "外に出さない（室内飼い）")) }', lines)
        self.assertLess(lines.index("外に出さない（室内飼い）"), lines.index("年齢・体重"))

    def test_medicine_note_moved_to_medicine_input(self) -> None:
        self.assertNotIn("薬は、獣医師に言われたとおりに書いてください。", self.view)
        medicine = section(source("NekoWidget/Views/CatCareView.swift"), 'case .medication:\n                    TextField("薬の名前"', "case .vaccination:")
        self.assertIn("薬は、獣医師に言われたとおりに書いてください。", medicine)

    def test_making_screen_order_defaults_and_steps(self) -> None:
        making = section(self.view, "private struct CareDisclosureView: View {", "private struct CareDisplayView: View {")
        # Period and request at the top; contacts shown once here.
        self.assertLess(making.index('title: "期間とお願い"'), making.index('title: "お願いする猫"'))
        self.assertIn('label: "ほかにお願いしたいこと"', making)
        self.assertIn("CareHandoffDisclosure.contactFields(plan: store.plan", making)
        self.assertIn("store.clearStaleRequest()", making)
        # Every cat that has not passed away starts chosen.
        self.assertIn("disclosure.catIDs = Set(cats.map(\\.id))", making)
        self.assertIn("CatFarewell.days(farewellJSON)", making)
        # Health and contacts start on when written, and remember the last memo.
        self.assertIn("disclosure.health = healthWritten && (store.plan.includesHealth ?? true)", making)
        self.assertIn("disclosure.contacts = contactsWritten && (store.plan.includesContacts ?? true)", making)
        self.assertIn('Toggle("薬・持病・アレルギーを載せる"', making)
        self.assertIn('Toggle("連絡先・動物病院を載せる"', making)
        self.assertIn("store.recordMade(health:", making)
        # No question before the share sheet.
        self.assertNotIn("この内容で作りますか", self.view)
        self.assertIn('.navigationTitle("できあがり")', self.view)
        self.assertNotIn('.navigationTitle("プレビュー")', self.view)

    def test_editor_order_and_quiet_cleanup(self) -> None:
        editor = section(self.view, "private struct CareCatEditor: View {", "private struct CarePhoto: View {")
        body = editor[editor.index("var body: some View {"):]
        self.assertLess(body.index('identifier: "care-important"'), body.index("catCareSection(cat)"))
        self.assertLess(body.index('identifier: "care-call-when"'), body.index("catCareSection(cat)"))
        self.assertIn('"薬と連絡先は、次の画面で選ぶと載ります。"', editor)
        self.assertNotIn("CareRequestEditor", self.view)
        # 347: period and request are written in one place, the make screen.
        # A chosen family cat keeps its own shared request (never this iPhone's
        # household one), so the form writes there.
        self.assertNotIn("この子の期間とお願い", editor)
        self.assertIn('text: request(\.period, \.period))', self.view)
        self.assertIn("store.plan.requestText(key, planKey, chosen: disclosure.catIDs)", self.view)
        self.assertIn("ci/verify-tool-outputs.swift", source("ci/run-quick-ios-checks.sh"))
        self.assertEqual(self.view.count('"今回のお願い"'), 0)
        # Face photo from 「この子のこと」 first; never after the owner removed it.
        self.assertIn("care?.facePhoto?.value", editor)
        self.assertIn("cat.photoRemoved != true", editor)
        self.assertIn("$0.photoName = nil; $0.photoRemoved = true", editor)
        self.assertIn("next.cats[index].photoRemoved = nil", self.store)
        # Leftover photo copies are removed in the background, not by a button.
        self.assertNotIn("使わなくなった写真のコピーが残っています。", self.view)
        self.assertNotIn("もう一度消す", self.view)
        self.assertIn("store.retryPhotoCleanup()", self.view)
        self.assertIn("func retryPhotoCleanup()", self.plan)

    def test_both_pages_follow_the_input_page_shape(self) -> None:
        """ねこのまど_ツール入力ページの型_1108: purpose, numbered steps, folded
        「この子のこと」, notes last, one button at the bottom."""
        editor = section(self.view, "private struct CareCatEditor: View {", "private struct CarePhoto: View {")
        body = editor[editor.index("var body: some View {"):]
        self.assertIn('ToolPurpose(text: "預ける人に渡すお世話メモを作ります。")', body)
        order = [body.index('ToolPurpose(text:'),
                 body.index('ToolStepHeader(number: 1, title: "写真", state: states[0])'),
                 body.index('ToolStepHeader(number: 2, title: "まず伝えたいこと", state: states[1])'),
                 body.index('ToolStepHeader(number: 3, title: "こんなときは連絡を", state: states[2])'),
                 body.index("catCareSection(cat)"),
                 body.index("このメモは、家族の手帳には入っていません。"),
                 body.index("前に入れた内容を読み込めませんでした。"),
                 body.index('Button("このお世話メモを削除", role: .destructive)'),
                 body.index(".toolBottomBar {")]
        self.assertEqual(order, sorted(order))
        # The photo heading sits over the name, photo and its two buttons.
        photo = body[body.index('Section {\n                    if let profile'):body.index('title: "写真"')]
        for part in ('identifier: "care-cat-name"', '"care-photo-open"', '"このメモの写真を外す"'):
            self.assertIn(part, photo)
        self.assertIn("ToolStepState.states([cat.photoName != nil, Self.isFilled(cat.important), Self.isFilled(cat.callWhen)])", editor)
        self.assertIn(".trimmingCharacters(in: .whitespacesAndNewlines).isEmpty", editor)
        # The field under a heading of the same words does not repeat it, but
        # VoiceOver still reads its name.
        self.assertIn('identifier: "care-important", text: text(' + chr(92) + '.important),\n                              showsLabel: false)', body)
        self.assertIn("}), showsLabel: false)", body)
        self.assertIn(".accessibilityLabel(label).accessibilityIdentifier(identifier)", self.view)
        self.assertIn("if showsLabel { Text(label)", self.view)
        # 「この子のこと」 is folded to one row; its footer stays.
        cat_care = section(editor, "@ViewBuilder private func catCareSection(", "/// Where the three steps stand")
        self.assertIn("folded: true)", cat_care)
        self.assertIn('"薬と連絡先は、次の画面で選ぶと載ります。"', cat_care)
        bar = body[body.index(".toolBottomBar {"):]
        self.assertIn("ToolMakeBar(top: { CareSaveNotice(store: store) }) {", bar)
        self.assertIn("NavigationLink { CareDisclosureView(store: store, currentCatID: id) }", bar)
        self.assertIn(".disabled(store.saveError != nil)", bar)
        self.assertIn('.accessibilityIdentifier("care-disclosure-open")', bar)

        making = section(self.view, "private struct CareDisclosureView: View {", "private struct CareDisplayView: View {")
        page = making[making.index("    var body: some View {"):]
        order = [page.index('ToolStepHeader(number: 1, title: "期間とお願い", state: states[0])'),
                 page.index('ToolStepHeader(number: 2, title: "お願いする猫", state: states[1])'),
                 page.index('ToolStepHeader(number: 3, title: "載せるもの", state: states[2])'),
                 page.index('"care-unwritten"'),
                 page.index("if let error { Section"),
                 page.index(".toolBottomBar {")]
        self.assertEqual(order, sorted(order))
        self.assertNotIn('Section("今回お願いする猫")', making)
        # Period done, at least one cat, and 載せるもの done once seen.
        states = section(making, "private var stepStates: [ToolStepState] {", "var body: some View {")
        self.assertIn(r"CareCatEditor.isFilled(store.plan.requestText(\.period, \.period, chosen: disclosure.catIDs))", states)
        self.assertIn("!disclosure.catIDs.isEmpty,", states)
        self.assertIn("true,", states)
        # The period and request stay written in one place.
        self.assertIn("store.update { $0.setRequestText(new, key, planKey, chosen: disclosure.catIDs) }", making)
        bar = page[page.index(".toolBottomBar {"):]
        self.assertIn('ToolMakeBar(missing: disclosure.catIDs.isEmpty ? ["お願いする猫"] : [],', bar)
        self.assertIn("top: { CareSaveNotice(store: store) }", bar)
        self.assertIn("preview = CarePreview(record: try store.shareRecord(disclosure))", bar)
        self.assertIn(".disabled(disclosure.catIDs.isEmpty || store.saveError != nil)", bar)
        self.assertIn('.accessibilityIdentifier("care-preview-open")', bar)
        # The shared parts are used, not copied.
        for name in ("struct ToolStepHeader", "struct ToolMakeBar", "struct ToolPurpose", "enum ToolStepState"):
            self.assertNotIn(name, self.view)

    def test_pdf_with_several_cats_says_shared_things_once(self) -> None:
        self.assertIn("let sharedFirstPage = record.cats.count > 1", self.exporter)
        self.assertIn("(sharedFirstPage ? [] : record.commonFields) + cat.fields", self.exporter)
        self.assertIn('page.catIndex.map { "\\(record.heading) · \\(record.cats[$0].name)" } ?? record.heading', self.exporter)
        self.assertNotIn("append(cat.name", self.exporter)


class ShowcaseCatCareTests(unittest.TestCase):
    def test_showcase_caption_ios17_score_and_cat_care_face(self) -> None:
        store = source("NekoWidget/Services/ShowcasePhotoStore.swift")
        view = source("NekoWidget/Views/ShowcasePhotoView.swift")
        # iOS 17 falls back to a local look score; iOS 18 keeps Vision's score.
        self.assertIn("thumbnail.flatMap(aestheticScore)\n                    ?? thumbnail.flatMap { lookScore(", store)
        self.assertIn("if #available(iOS 18.0, *)", store)
        score = section(store, "static func lookScore(gray", "private static func imageHash(")
        for part in ("variance / 400", "abs(mean - 128)", "catArea ?? 0"):
            self.assertIn(part, score)
        # The caption only names a chosen cat, and can be turned off.
        caption = section(view, "private var caption: String?", "private var storedScopeIDs")
        self.assertIn("!scopeID.isEmpty", caption)
        self.assertIn('@AppStorage("showcase-shows-name-and-age")', view)
        self.assertIn('"showcase-caption-toggle"', view)
        # The 「この子のこと」 face photo leads only if it is already a candidate.
        self.assertIn("identifiers.firstIndex(of: face)", view)

    def test_showcase_tool_review_round_one(self) -> None:
        """11/8 review of 「写真を見せる」 (source contracts; no Swift is run here)."""
        store = source("NekoWidget/Services/ShowcasePhotoStore.swift")
        view = source("NekoWidget/Views/ShowcasePhotoView.swift")
        tab = source("NekoWidget/Views/MainTabView.swift")
        # 1／2×2／3×2／3×3: only as many photos as fill the shape, on screen and in the picture.
        layout = section(view, "enum ShowcaseLayout {", "enum ShowcaseBand {")
        for part in ("case 9...: 9", "case 6...: 6", "case 4...: 4", "default: min(max(count, 0), 1)",
                     "tileCount >= 6 ? 3 : tileCount == 4 ? 2 : 1"):
            self.assertIn(part, layout)
        main = section(view, "struct ShowcasePhotoView: View {", "enum BestNineComposer {")
        self.assertIn("let tiles = Array(all.prefix(ShowcaseLayout.tileCount(for: all.count)))", main)
        self.assertIn("count: ShowcaseLayout.columns(for: tiles.count)", main)
        # Three columns at every text size (no 2-column large-text grid on the show screen).
        self.assertNotIn("dynamicTypeSize.isAccessibilitySize ? 2 : 3", main)
        composer = section(view, "enum BestNineComposer {", "private struct ShowcaseItemImage: View {")
        self.assertIn("let count = ShowcaseLayout.tileCount(for: photos.count)", composer)
        self.assertIn("let rows = count / columns", composer)
        self.assertNotIn("cell * 3 + gap * 4", composer)
        # The cat box is kept with the photo and every square is cut around it.
        self.assertIn("var catBoundingBox: CGRect? = nil", store)
        self.assertIn("catBoundingBox: catBoundingBox.flatMap(Self.validBox)", store)
        for call in ("try await store.addPhotos(identifiers, boxes: boxes, to: targetScope)",
                     "try await store.replace(old, with: identifier, catBoundingBox: boxes[identifier])",
                     "try await store.applyRecommendations(identifiers, boxes: boxes, to: targetScope)"):
            self.assertIn(call, view)
        self.assertIn("try await showcaseStore.applyRecommendations(identifiers, boxes: boxes, to: scopeID)", tab)
        self.assertIn("PhotoThumbnailCropPolicy.cropRect(", section(view, "enum ShowcaseImageLoader {",
                                                                    "struct ShowcasePhotoView: View {"))
        self.assertIn("ShowcaseImageLoader.load(url, box: entry.catBoundingBox, side: side, square: true)", main)
        # Kept JPEGs are not decoded at full size on each redraw.
        self.assertNotIn("UIImage(contentsOfFile:", view)
        self.assertIn("kCGImageSourceThumbnailMaxPixelSize", view)
        # The name band sits under the grid (not over it), is in the shared picture, and one switch drives both.
        self.assertNotIn(".overlay(alignment: .bottom) {", main)
        self.assertIn("if initialScopeID != nil, let band = shownCaption {", main)
        self.assertIn("private var shownCaption: String? { showsCaption ? caption : nil }", main)
        self.assertIn("BestNineComposer.image(photos, title: band)", main)
        self.assertIn('Toggle("名前と年齢", isOn: $showsCaption)', main)
        self.assertIn("if let band {", composer)
        # The first cat, not すべての猫, before anything is chosen.
        self.assertIn('@AppStorage("showcase.lastScopeID.v1") private var storedShowcaseScopeID: String?', tab)
        self.assertIn("storedShowcaseScopeID ?? catProfilesPresentation.profiles.first?.identifier", tab)
        # The screen opens at once and says 「選んでいます…」, never 「写真がありません」 while choosing.
        prepare = section(tab, "private func prepareShowcaseIfNeeded(", "private func showcaseCandidatesForScope(")
        self.assertLess(prepare.index("showcaseSession = ShowcaseSession("), prepare.index("ShowcaseRecommender.identifiers("))
        self.assertNotIn("showcaseWaitingToOpen", tab)
        self.assertNotIn('ProgressView("見せる写真を用意しています…")', tab)
        empty = section(main, "private var emptyState: some View {", "private func selectScope(")
        self.assertLess(empty.index('ProgressView("選んでいます…")'), empty.index('"まだ写真を選んでいません"'))
        # Words.
        self.assertIn('Label("画像を共有", systemImage: "square.and.arrow.up")', main)
        self.assertNotIn("画像を書き出す", view)
        self.assertIn('"\\(profile.displayName)の\\(count)枚"', main)
        self.assertIn('"うちの猫の\\(count)枚"', main)
        self.assertNotIn("鉛筆", view)
        self.assertNotIn('Image(systemName: "pencil")', view)
        self.assertIn('Text("編集")', main)
        self.assertIn('entry.pinned ? "おすすめで入れ替える" : "おすすめで入れ替えない"', view)
        self.assertIn('Button("先頭にする")', view)
        for gone in ("固定する", "固定を外す", "表紙"):
            self.assertNotIn(gone, view)
        preparation = section(view, "struct ShowcasePreparationView: View {", "private struct ShowcaseCandidatePicker: View {")
        self.assertNotIn('"見せる写真の操作"', preparation)
        self.assertIn('"showcase-preparation-reselect"', preparation)
        self.assertIn("if canReselect {", preparation)
        self.assertIn('Text("あと\\(ShowcasePhotoStore.maximumCount - allEntries.count)枚")', preparation)
        picker = section(view, "private struct ShowcaseCandidatePicker: View {", "struct ShowcaseToolCatPicker: View {")
        self.assertIn('Text("あと\\(max(0, maximumSelection - selected.count))枚")', picker)
        self.assertIn("else if isReplacing { selected = [identifier] }", picker)
        # A failed add is told once (the picker's alert), not twice.
        self.assertNotIn("写真を用意できませんでした", view)
        self.assertNotIn("写真を準備できませんでした", view)
        # 「前の写真」, and a former set can be swiped away.
        cats = section(view, "struct ShowcaseToolCatPicker: View {", "private func storeOrder(")
        self.assertIn('Section("前の写真")', cats)
        self.assertIn('Button("前に選んだ写真（\\(storeOrder(scope))）")', cats)
        self.assertIn('Button("削除", role: .destructive) { remove(scope) }', cats)
        self.assertIn("try store.removeScope(removed)", main)
        self.assertNotIn("まだ登録していない猫", view)
        # The arrow shows only when there is something to switch to.
        self.assertIn("if detailIndex == nil && initialScopeID != nil && canSwitchScope {", main)
        # The enlarged photo pages, zooms and closes with a downward drag.
        detail = section(view, "private struct ShowcaseDetailPhoto: View {", "struct ShowcasePreparationView: View {")
        for part in ("MagnifyGesture()", ".onTapGesture(count: 2)", "moved.height > 110", "page(1)", "page(-1)"):
            self.assertIn(part, detail)
        # Names match the tool, the Control Center and Siri.
        self.assertIn('subtitle: "自慢の9枚", tint: ToolTint.everydayLight)', tab)
        control = source("NekoWidgetWidget/ShowcaseControl.swift")
        shortcut = source("NekoWidget/App/ShowcaseAppShortcuts.swift")
        self.assertIn('.displayName("写真を見せる")', control)
        self.assertIn('shortTitle: "写真を見せる"', shortcut)
        for text in (control, shortcut, source("NekoWidgetWidget/OpenShowcaseIntent.swift")):
            self.assertNotIn("うちのこを見せる", text)

    def test_vet_memo_is_an_everyday_tool(self) -> None:
        tab = source("NekoWidget/Views/MainTabView.swift")
        everyday = section(tab, 'toolSection("ふだん") {', 'toolSection("もしものとき") {')
        emergency = section(tab, 'toolSection("もしものとき") {', "private var showcaseToolCard: some View {")
        self.assertLess(everyday.index("showcaseToolCard"), everyday.index('.accessibilityIdentifier("tools-vet-open")'))
        self.assertIn("ToolTint.everydayDeep", everyday)
        self.assertNotIn("tools-vet-open", emergency)
        for identifier in ("tools-lost-cat-open", "tools-care-open", "tools-evacuation-open"):
            self.assertIn(identifier, emergency)


class CatCareMemoWeightTests(unittest.TestCase):
    def test_memo_weights_join_by_id_and_memos_are_not_changed(self) -> None:
        core = source("NekoWidget/Services/CatCareCore.swift")
        view = source("NekoWidget/Views/CatCareView.swift")
        rule = section(core, "enum CatCareMemoWeights {", "// MARK: - 迷子のとき")
        self.assertIn("guard let id = weight.catID, id == cat.catID || id == cat.profileID", rule)
        self.assertNotIn("catName", rule)
        # 11/7: the cat's page reads them wherever it opens (CatProfileDetailView).
        entry = section(view, "try? await PhotoMemoryNoteStore.shared.records()", "/// Whose 「この子のこと」 a page shows")
        self.assertIn("importWeights(records.compactMap", entry)
        self.assertIn(".task { await catCare.importMemoWeights() }",
                      source("NekoWidget/Views/CatProfilePhotoCurationViews.swift"))
        for forbidden in ("noteStore.save", ".save(text:", "delete(id:"):
            self.assertNotIn(forbidden, view)
        self.assertIn("try memoWeights()", source("ci/verify-cat-care.swift"))


class CatCareProofCameraTests(unittest.TestCase):
    def test_vaccination_proof_from_camera_stays_in_the_app(self) -> None:
        view = source("NekoWidget/Views/CatCareView.swift")
        plist = source("NekoWidget/Info.plist")
        self.assertIn("<key>NSCameraUsageDescription</key>", plist)
        self.assertIn("写真アプリには追加しません", plist)
        camera = section(view, "private struct CatCareCameraView", "// MARK: - Formatting")
        self.assertIn("picker.sourceType = .camera", camera)
        for forbidden in ("UIImageWriteToSavedPhotosAlbum", "PHPhotoLibrary", "PHAssetChangeRequest"):
            self.assertNotIn(forbidden, view)
        self.assertIn('origin: .camera', view)
        self.assertIn("UIImagePickerController.isSourceTypeAvailable(.camera)", view)


class ToolTemplateTests(unittest.TestCase):
    def test_tools_share_the_cat_care_section_and_a_bottom_preview(self) -> None:
        shared = section(source("NekoWidget/Views/CatCareView.swift"), "struct ToolCatCareSection<Extra: View>", "/// The system camera.")
        self.assertIn('NavigationLink("「この子のこと」を開く") { CatCareSubjectView(subject: subject, profiles: profiles) }', shared)
        # 11/7: the link opens the cat's own page (この子のこと only).
        subject_view = section(source("NekoWidget/Views/CatCareView.swift"), "struct CatCareSubjectView: View {", "struct CatCareDetailView: View {")
        self.assertIn("CatProfileDetailView(profile: profile,", subject_view)
        self.assertIn("actions: profileActions)", subject_view)
        self.assertNotIn("initialPage", subject_view)
        self.assertNotIn("CatCareStore.shared.update", shared)
        for path in ("NekoWidget/Views/VeterinaryVisitView.swift", "NekoWidget/Views/CareHandoffView.swift",
                     "NekoWidget/Views/CatPreparednessView.swift", "NekoWidget/Views/EvacuationPreparationView.swift"):
            text = source(path)
            self.assertIn("ToolCatCareSection(", text, path)
            self.assertIn("ToolImportantInformation(", text, path)
        care = source("NekoWidget/Views/CareHandoffView.swift")
        # 11/8: what is written this time comes before the read-only 「この子のこと」.
        self.assertLess(care.index('CareField(label: "まず伝えたいこと"'), care.index("catCareSection(cat)"))
        self.assertIn('ToolImportantInformation(text: "住所や鍵の番号は、別の方法で伝えてください。")', care)
        evacuation = source("NekoWidget/Views/EvacuationPreparationView.swift")
        # 11/7: the page has the link's name, 「猫の情報」.
        bottom = section(evacuation, '}.navigationTitle("猫の情報")', ".navigationDestination(item: $preview)")
        self.assertIn('"evacuation-preview-open"', bottom)
        self.assertIn(".toolBottomBar {", bottom)
        # 348: tool bottom bars step aside while typing, with one way to close the keyboard.
        care_view = source("NekoWidget/Views/CatCareView.swift")
        bar = section(care_view, "private struct ToolBottomBar<Bar: View>: ViewModifier {", "/// A photo beside its text")
        self.assertIn(".safeAreaInset(edge: .bottom) { if !typing { bar } }", bar)
        self.assertIn("UIResponder.keyboardWillShowNotification", bar)
        self.assertIn('Button("キーボードを閉じる")', bar)
        for path in ("NekoWidget/Views/VeterinaryVisitView.swift", "NekoWidget/Views/CareHandoffView.swift",
                     "NekoWidget/Views/CatPreparednessView.swift"):
            text = source(path)
            self.assertIn(".toolBottomBar {", text, path)
            self.assertNotIn('Button("キーボードを閉じる")', text, path)


class CatCareUsabilityTests(unittest.TestCase):
    def test_cat_care_saves_by_itself_and_asks_before_deleting(self) -> None:
        view = source("NekoWidget/Views/CatCareView.swift")
        # No save button to forget; leaving or switching cats saves.
        self.assertNotIn('Button("保存") { save() }', view)
        self.assertIn(".onDisappear { autosave?.cancel(); save() }", view)
        switching = section(view, ".task(id: subject.key) {", "// MARK: Sections")
        self.assertLess(switching.index("save()"), switching.index("load()"))
        save = section(view, "private func save() {", "private func apply(")
        self.assertIn("draft != savedDraft", save)
        self.assertIn("value.microchip = savedDraft.microchip", save)
        # Deleting is a button with a confirmation; a swipe is not the only way.
        self.assertIn('confirmationDialog("この記録を削除しますか？"', view)
        self.assertIn('.accessibilityHint("押すと直せます。削除もここからできます")', view)
        self.assertIn('"cat-care-delete-entry"', view)
        self.assertNotIn("deleteButton(entry.id)", view)


class ToolFlowTests(unittest.TestCase):
    def test_export_buttons_are_visible_and_names_match(self) -> None:
        care = source("NekoWidget/Views/CareHandoffView.swift")
        evacuation = source("NekoWidget/Views/EvacuationPreparationView.swift")
        vet = source("NekoWidget/Views/VeterinaryVisitView.swift")
        # Image and PDF are two buttons, not hidden in a menu.
        for text in (care, evacuation, vet):
            self.assertNotIn('Label("書き出す", systemImage: "square.and.arrow.up")', text)
        self.assertIn('shareButton("PDFで渡す", pdf: true)', care)
        self.assertIn('"evacuation-share-pdf"', evacuation)
        self.assertIn('"vet-export-pdf"', vet)
        # The button says where it goes: the next step's name (11/8 型).
        self.assertIn('Text("次へ：期間とお願い")', care)
        self.assertIn('.navigationTitle("メモを作る")', care)
        self.assertIn('Label("お世話メモを作る", systemImage: "doc.text")', care)
        self.assertNotIn('"この内容で作る"', care)
        self.assertNotIn('"渡す内容を選ぶ"', care)
        self.assertNotIn("できあがりを見る", care)
        self.assertIn('.navigationTitle("病院で見せる")', vet)
        # Closing the vet memo saves; it asks only when it could not.
        close = section(vet, "private func close() {", "private func save(completing:")
        self.assertLess(close.index("await save()"), close.index("discarding = true"))
        self.assertNotIn("保存せずに閉じる", vet)
        self.assertNotIn("迷子への備え", source("NekoWidget/Views/CatProfilePhotoCurationViews.swift"))


class ToolAccessibilityTests(unittest.TestCase):
    def test_tools_work_without_precise_gestures_and_speak_errors(self) -> None:
        lost = source("NekoWidget/Views/CatPreparednessView.swift")
        showcase = source("NekoWidget/Views/ShowcasePhotoView.swift")
        # Cropping works with buttons and VoiceOver, not only dragging.
        crop = section(lost, "private struct LostCatPhotoCropView", "private func clamped(")
        for name in ("上へ動かす", "下へ動かす", "左へ動かす", "右へ動かす"):
            self.assertIn(name, crop)
        self.assertIn('nudgeButton("左へ"', crop)
        # Large text stacks the two photo tiles.
        self.assertIn("AnyLayout(VStackLayout(spacing: 12))", lost)
        self.assertNotIn("frame(minWidth: 36, minHeight: 36)", lost)
        # Photos in a grid are told apart by their day.
        for path in ("NekoWidget/Views/CatPreparednessView.swift", "NekoWidget/Views/CareHandoffView.swift",
                     "NekoWidget/Views/EvacuationPreparationView.swift"):
            self.assertIn("ToolPhotoLabel.text(", source(path), path)
        # Errors are read aloud.
        for path in ("NekoWidget/Views/CatPreparednessView.swift", "NekoWidget/Views/CareHandoffView.swift",
                     "NekoWidget/Views/EvacuationPreparationView.swift", "NekoWidget/Views/VeterinaryVisitView.swift",
                     "NekoWidget/Views/CatCareView.swift"):
            self.assertIn(".announcesWhenShown(", source(path), path)
        self.assertIn("AccessibilityNotification.Announcement(new).post()", source("NekoWidget/Views/CatCareView.swift"))
        # Showcase has previous and next buttons as well as swiping.
        self.assertIn('.accessibilityLabel("前の写真")', showcase)
        self.assertIn('.accessibilityLabel("次の写真")', showcase)


class GroupWindowUsabilityTests(unittest.TestCase):
    def test_group_window_plain_words_buttons_and_labels(self) -> None:
        setup = source("NekoWidget/Views/GroupWindowSetupView.swift")
        window = source("NekoWidget/Views/GroupWindowView.swift")
        # Plain words: no keys, no "却下", one name for the phrase.
        for word in ("鍵を", "却下", "確認語", "今後の版"):
            self.assertNotIn(word, setup)
        self.assertIn('WorkingLabel(title: "断る"', setup)
        # Removing a member has a visible button and a VoiceOver action, not only a swipe.
        self.assertIn('"group-window-remove-member"', setup)
        self.assertIn('.accessibilityAction(named: Text("外す"))', setup)
        # Photo tiles are buttons and say whether they have a heart.
        self.assertNotIn(".onTapGesture { openedEntry = entry }", window)
        self.assertIn('parts.append("ハートあり")', window)


class WindowCreationEntryTests(unittest.TestCase):
    def test_both_kinds_of_window_start_from_the_same_place(self) -> None:
        tab = source("NekoWidget/Views/MainTabView.swift")
        self.assertNotIn("PairingView(", tab)
        self.assertIn("GroupWindowListSection(client: client", tab)
        window = source("NekoWidget/Views/GroupWindowView.swift")
        self.assertNotIn("グループのまど", window)
        create = section(window, "struct GroupWindowCreateScreen: View {", "struct GroupWindowListSection: View {")
        self.assertIn("GroupWindowMembersScreen(client: model.client, windowID: createdWindowID)", create)

    def test_create_says_it_is_making_and_puts_the_keyboard_away(self) -> None:
        window = source("NekoWidget/Views/GroupWindowView.swift")
        create = section(window, "struct GroupWindowCreateScreen: View {", "struct GroupWindowListSection: View {")
        self.assertIn("typing = nil", section(create, "private func create() {", "private var trimmed"))
        self.assertIn('WorkingLabel(title: "作る", workingTitle: "作っています…", working: model.isWorking)', create)
        self.assertEqual(create.count(".focused($typing, equals:"), 2)
        self.assertEqual(create.count(".disabled(model.isWorking)"), 2)


class WorkingFeedbackTests(unittest.TestCase):
    """11/6: a press that waits on the network or a slow file says so on its
    own button (「〜しています…」), instead of only graying out."""

    def test_working_label_is_shared(self) -> None:
        window = source("NekoWidget/Views/GroupWindowView.swift")
        label = section(window, "struct WorkingLabel: View {", "struct GroupWindowListSection: View {")
        self.assertIn("let workingTitle: String", label)
        self.assertIn("if working { HStack(spacing: 8) { ProgressView(); Text(workingTitle) } } else { Text(title) }", label)
        self.assertEqual(window.count("struct WorkingLabel: View {"), 1)
        create = section(window, "struct GroupWindowCreateScreen: View {", "struct GroupWindowStandardsAgreement: View {")
        self.assertIn('WorkingLabel(title: "作る", workingTitle: "作っています…", working: model.isWorking)', create)

    def test_key_buttons_say_what_they_are_doing(self) -> None:
        expected = {
            "NekoWidget/Views/GroupWindowView.swift": (
                'WorkingLabel(title: "もう一度", workingTitle: "読み込んでいます…", working: model.isSyncing)',
                'WorkingLabel(title: "もう一度", workingTitle: "読み込んでいます…", working: reloading)',
                'workingTitle: "追加しています…"',
                'WorkingLabel(title: "確かめる", workingTitle: "確かめています…", working: working)',
                '"解除しています…" : "表示しています…"',
                'WorkingLabel(title: "もう一度送る", workingTitle: "送っています…", working: running == record.id)',
            ),
            "NekoWidget/Views/GroupWindowSetupView.swift": (
                'WorkingLabel(title: "もう一度", workingTitle: "読み込んでいます…", working: reloading)',
                'WorkingLabel(title: "外す", workingTitle: "外しています…"',
                'workingTitle: "取り消しています…"',
                'workingTitle: "終わりにしています…"',
                'workingTitle: "抜けています…"',
                'WorkingLabel(title: "断る", workingTitle: "断っています…"',
                'WorkingLabel(title: "招待リンクを作る", workingTitle: "作っています…"',
                'WorkingLabel(title: "参加をやめる", workingTitle: "やめています…"',
            ),
            "NekoWidget/Views/FamilyNotebookView.swift": (
                'WorkingLabel(title: "もう一度確認", workingTitle: "確認しています…", working: rechecking)',
                'workingTitle: "返事をしています…"',
                'workingTitle: "準備しています…"',
                'WorkingLabel(title: "共有をやめる", workingTitle: "やめています…"',
            ),
            "NekoWidget/Views/ManagedPreservationView.swift": (
                'WorkingLabel(title: "購入を復元", workingTitle: "確認しています…", working: coordinator.membershipRestoring)',
                'WorkingLabel(title: "メモを保存", workingTitle: "保存しています…"',
            ),
            "NekoWidget/Services/AppRecordPersistence.swift": (
                'WorkingLabel(title: "Plusをもう一度確かめる", workingTitle: "確認しています…", working: authentication.membershipRestoring)',
                'workingTitle: "切り替えています…"',
            ),
            "NekoWidget/Views/MembershipOfferView.swift": (
                'WorkingLabel(title: "購入を復元", workingTitle: "確認しています…"',
            ),
            "NekoWidget/Views/ShowcasePhotoView.swift": (
                'workingTitle: isReplacing ? "入れ替えています…" : "追加しています…"',
                'WorkingLabel(title: "おすすめで選ぶ", workingTitle: "選んでいます…"',
            ),
            "NekoWidget/Views/VeterinaryVisitView.swift": ('workingTitle: "作っています…"',),
            "NekoWidget/Views/CareHandoffView.swift": ('workingTitle: "作っています…"',),
            "NekoWidget/Views/EvacuationPreparationView.swift": ('workingTitle: "作っています…"',),
        }
        for path, needles in expected.items():
            text = source(path)
            for needle in needles:
                self.assertIn(needle, text, f"{path}: {needle}")

    def test_new_flags_are_set_only_while_their_work_runs(self) -> None:
        window = source("NekoWidget/Views/GroupWindowView.swift")
        # Retry progress is the view's own: background loads must not redraw the list.
        self.assertNotIn("isLoading", window)
        self.assertEqual(window.count("reloading = true; Task { defer { reloading = false }; await model.load() }"), 2)
        favorite = section(window, "func addToFavorites(", "func remove(")
        self.assertIn("addingFavoriteID = entry.id\n        defer { addingFavoriteID = nil }", favorite)
        setup = source("NekoWidget/Views/GroupWindowSetupView.swift")
        self.assertNotIn("isLoading", setup)
        self.assertIn("Task { defer { reloading = false }; await model.load() }", setup)
        # Family changes show in the bar, never as a new row in the notebook list.
        notebook = source("NekoWidget/Views/FamilyNotebookView.swift")
        bar = section(notebook, "@ToolbarContentBuilder private var closeToolbar", "var body: some View {")
        self.assertIn("if sharing.isWorking { ProgressView()", bar)
        sharing = source("NekoWidget/Services/FamilyNotebookSharing.swift")
        self.assertEqual(sharing.count("isWorking = true"), 1)
        self.assertIn("isWorking = true", section(sharing, "func perform(", "/// Test builds"))

    def test_exports_show_their_label_before_drawing(self) -> None:
        for path, start in (("NekoWidget/Views/VeterinaryVisitView.swift", "private func makeExport(pdf: Bool) async {"),
                            ("NekoWidget/Views/CareHandoffView.swift", "private func createExport() async {"),
                            ("NekoWidget/Views/EvacuationPreparationView.swift", "private func makeBook() async {"),
                            ("NekoWidget/Views/EvacuationPreparationView.swift", "private func createExport() async {")):
            body = source(path)
            body = body[body.index(start):]
            self.assertLess(body.index("try? await Task.sleep(for: .milliseconds(100))"), body.index("Exporter.create"), path)
        evacuation = source("NekoWidget/Views/EvacuationPreparationView.swift")
        export = section(evacuation, "private func createExport() async {", "private struct EvacuationActivitySheet")
        self.assertIn("busy = true\n        defer { busy = false }", export)

    def test_join_and_rename_put_the_keyboard_away(self) -> None:
        setup = source("NekoWidget/Views/GroupWindowSetupView.swift")
        join = section(setup, "struct GroupJoinView: View {", "// MARK: - Today's two-person window")
        apply = section(join, "private var applySection: some View {", "private func pendingSection(")
        self.assertIn(".focused($typingName)", apply)
        self.assertLess(apply.index("typingName = false"), apply.index("await model.apply()"))
        rename = section(setup, "struct GroupWindowRenameSheet: View {", "struct GroupMemberAvatar: View {")
        self.assertIn(".focused($typing)", rename)
        self.assertLess(rename.index("typing = false"), rename.index("await model.rename(to: trimmed)"))
        family = section(source("NekoWidget/Views/FamilyNotebookView.swift"),
                         "struct FamilyNotebookJoinView: View {", "struct FamilyNotebookNameView: View {")
        self.assertIn(".focused($typingName)", family)
        self.assertLess(family.index("typingName = false"), family.index("service.join(preview"))
        report = section(source("NekoWidget/Views/GroupWindowView.swift"),
                         "struct GroupReportSheet: View {", "private func send() async {")
        self.assertIn(".disabled(record != nil || safety.isWorking)", report)


class CatPageSharedLabelTests(unittest.TestCase):
    def test_only_a_cat_in_the_notebook_says_it_is_shared(self) -> None:
        care = source("NekoWidget/Views/CatCareView.swift")
        self.assertIn("familyNotebook.familyCats.contains { $0.toolID == catID }", care)
        # Faces, not a sentence: in the notebook as a picture, elsewhere as the way in.
        self.assertIn("FamilyFaces(names: familyNotebook.members.map(\\.displayName))", care)
        self.assertIn("FamilyNotebookButton(sharedNames: familyNotebook.members.map(\\.displayName))", care)
        self.assertNotIn("家族の手帳で共有しています", care)
        notebook = source("NekoWidget/Views/FamilyNotebookView.swift")
        self.assertIn("struct FamilyFaces: View {", notebook)
        # The old note showed for every cat once the person had a family.
        self.assertNotIn("家族と一緒に書いています。", care)


class OnboardingEndingTests(unittest.TestCase):
    def test_guide_endings_scan_errors_and_widget_steps(self) -> None:
        root_view = source("NekoWidget/App/AppRootView.swift")
        plus = section(root_view, "private func skipOnboardingPlusOffer() {", "private func completeOnboardingWithoutPhotoAccess()")
        self.assertIn("hasSeenInitialScanResult = true", plus)
        guide = section(root_view, "private func completeWidgetPlacementGuideIfNeeded() {", "@MainActor")
        self.assertIn("hasSeenInitialScanResult = true", guide)
        self.assertIn(".onChange(of: viewModel.linkErrorMessage)", root_view)
        self.assertIn(".onChange(of: viewModel.isScanning)", root_view)
        model = source("NekoWidget/ViewModels/AppViewModel.swift")
        self.assertIn('linkErrorMessage = "この招待リンクは開けませんでした。', model)
        steps = source("NekoWidget/Views/WidgetPlacementGuideView.swift")
        self.assertIn('["onboarding-widget-step-1", "", "onboarding-widget-step-3"]', steps)


class WidgetHygieneTests(unittest.TestCase):
    def test_reported_hidden_and_gone_windows_leave_the_home_screen(self) -> None:
        window = source("NekoWidget/Views/GroupWindowView.swift")
        home = section(window, "    func updateHomeScreenPhoto() async {", "private func receive(")
        # Works offline: the name comes from the widget's own copy.
        self.assertIn("window?.name ?? GroupWidgetCache.entry(windowID: windowID)?.windowName", home)
        self.assertNotIn("if !isFormer { await updateHomeScreenPhoto() }", window)
        self.assertIn(".onReceive(GroupSafety.shared.$records.dropFirst())", window)
        card = section(window, "private struct GroupWindowCard: View {", "private struct KnownWindowCard: View {")
        self.assertIn("!GroupSafety.shared.hasReported($0.id, in: window.id)", card)
        load = section(window, "    func load() async {", "    func create(name: String, ownerName: String)")
        self.assertIn("GroupWidgetCache.keepOnly(windowIDs: Set(windows.map(\\.id)))", load)
        cache = source("Shared/Sharing/GroupWidgetCache.swift")
        self.assertIn("static func keepOnly(windowIDs: Set<String>) -> Bool {", cache)


class InvitationAppLinkTests(unittest.TestCase):
    def test_app_scheme_invitation_becomes_the_same_https_link(self) -> None:
        link = source("NekoWidget/Services/GroupInvitationLink.swift")
        app = section(link, "enum InvitationAppLink {", "struct GroupInvitationLink:")
        self.assertIn('host == "join" || host == "family-join"', app)
        self.assertIn('https.scheme = "https"; https.host = "nekonomado.com"; https.path = "/" + host', app)
        self.assertIn("parts.query == nil", app)
        root_view = source("NekoWidget/App/AppRootView.swift")
        handle = section(root_view, "private func handleNonPhotoURL(_ incoming: URL) {", "if FamilyNotebookServiceFactory.productionRequested")
        self.assertIn("let url = InvitationAppLink.universal(from: incoming) ?? incoming", handle)


class FreeFirstPhotoTests(unittest.TestCase):
    def test_a_free_window_gets_its_first_photo_once(self) -> None:
        store = source("Shared/Storage/CloudyWindowStore.swift")
        self.assertIn("var issuedScopeIDs: Set<String>? = nil", store)
        frozen = section(store, "if !maySelect {", "} else if date == today {")
        self.assertIn("if selection == nil, date == today, !issued.contains(scopeID),", frozen)
        self.assertLess(frozen.index("state.selections.append(first)"), frozen.index("frozen[scopeID] = selection.id"))
        verify = source("ci/verify-cloudy-window.swift")
        self.assertIn("try freeWindowGetsItsFirstPhotoOnce()", verify)


class FamilyInviteMessageTests(unittest.TestCase):
    def test_family_invitation_carries_a_line_like_a_window(self) -> None:
        notebook = source("NekoWidget/Views/FamilyNotebookView.swift")
        self.assertIn("message: Text(FamilyNotebookInviteView.inviteMessage(cats: model.catNames))", notebook)
        self.assertIn("のことを一緒に書こう。このリンクから参加してね。", notebook)


class ReviewRequestTests(unittest.TestCase):
    def test_review_is_asked_once_at_the_end_of_a_monthly_book(self) -> None:
        album = source("NekoWidget/Views/AlbumPrototypeView.swift")
        book = section(album, "struct MonthlyBookView: View {", "struct PageCurlView<Page: View>")
        self.assertIn("@Environment(\\.requestReview) private var requestReview", book)
        self.assertIn('@AppStorage("review.requestedAfterMonthlyBook.v1") private var reviewRequested = false', book)
        self.assertIn("case .colophon = leaves[index]", book)
        self.assertEqual(album.count("requestReview()"), 1)


class PlusRouteTests(unittest.TestCase):
    def test_making_a_family_and_saving_lead_to_plus(self) -> None:
        notebook = source("NekoWidget/Views/FamilyNotebookView.swift")
        self.assertIn("access.decision(for: .createOwnWindow) == .membershipRequired", notebook)
        self.assertIn("if createsAfterPlus { createsAfterPlus = false; showsName = boughtPlus }", notebook)
        self.assertIn("if sharing.failure == .plusRequired {", notebook)
        saving = source("NekoWidget/Services/AppRecordPersistence.swift")
        link = section(saving, "private func linkAfterPurchaseIfReady() {", "private func linkPlusIfStarting() {")
        self.assertIn("authentication.connectMembership(consent: true)", link)
        self.assertIn(".onChange(of: hasPlusHere) { _, _ in linkAfterPurchaseIfReady() }", saving)


class WindowStateTests(unittest.TestCase):
    def test_gone_window_rotation_wait_and_kept_failure_reason(self) -> None:
        window = source("NekoWidget/Views/GroupWindowView.swift")
        self.assertIn("} catch GroupClientError.notMember {\n            window = nil; failedDelivery = nil; message = nil; isGone = true", window)
        self.assertIn("if !model.isFormer && !model.isGone { sendBar }", window)
        self.assertIn("if message == nil, !isGone { message = reason }", window)
        self.assertIn("window.state == .rotationRequired, !window.canManage", window)
        self.assertIn("model.deliver(model.failedDelivery?.photo ?? prepared, memo: memo)", window)

    def test_recent_writes_never_show_internal_field_names(self) -> None:
        notebook = source("NekoWidget/Views/FamilyNotebookView.swift")
        label = section(notebook, "static func label(_ field: FamilyNotebookField) -> String {", "/// The picked (not typed) items")
        self.assertNotIn("field.rawValue", label)
        for name in ("grams", "usualFood", "observations", "farewellDay"):
            self.assertIn("case ." + name, label)


class RecommendAppTests(unittest.TestCase):
    def test_settings_can_recommend_the_app_once_the_listing_exists(self) -> None:
        settings = source("NekoWidget/Views/SettingsView.swift")
        self.assertIn("enum AppStoreListing {", settings)
        self.assertIn('https://apps.apple.com/jp/app/id', settings)
        self.assertIn("if let url = AppStoreListing.pageURL {", settings)
        self.assertIn('Text("ねこのまどを紹介する").foregroundStyle(Color.primary)', settings)
        self.assertIn('Image(systemName: "square.and.arrow.up")', settings)


class SharedWorkMarkTests(unittest.TestCase):
    def test_shared_pictures_and_movies_say_where_they_were_made(self) -> None:
        showcase = source("NekoWidget/Views/ShowcasePhotoView.swift")
        composer = section(showcase, "enum BestNineComposer {", "struct ShowcasePreparationView: View {")
        self.assertIn('let mark = "ねこのまど" as NSString', composer)
        movie = source("NekoWidget/Services/SeasonalMovieExportService.swift")
        ending = section(movie, "case .ending:", 'let mark = "ねこのまど" as NSString')
        self.assertIn('"この季節も、ここまで"', ending)


class ReviewCTests(unittest.TestCase):
    def test_small_review_items(self) -> None:
        window = source("NekoWidget/Views/GroupWindowView.swift")
        self.assertIn("if failedDelivery?.photo.operationID == prepared.operationID { failedDelivery = nil }", window)
        self.assertNotIn("このまどから抜けました", window)
        self.assertNotIn("抜けたまどです", window)
        self.assertIn("} else if model.message != nil, GroupWidgetCache.entry(windowID: requested) != nil {", window)
        # 11/7: one restore for 設定 and the members screen; it still refreshes the Widget.
        restore = section(window, "static func restore(_ member: GroupWindowLocalPhotoStore.HiddenMember, windowID: String)",
                          "struct GroupIdentityDeletionView: View {")
        self.assertIn("await GroupWidgetCache.refreshKept(windowID: windowID)", restore)
        self.assertIn("_ = await Self.restore(item.member, windowID: item.window.id)", window)
        tab = source("NekoWidget/Views/MainTabView.swift")
        group_open = section(tab, ".onChange(of: groupWindowOpenInbox.pendingWindowID, initial: true)", ".onChange(of: photosTabInbox.pending")
        self.assertIn("relatedPhotoRoute = nil", group_open)
        root_view = source("NekoWidget/App/AppRootView.swift")
        self.assertIn("if windowID != nil { officialWindowRoute = nil }", root_view)
        self.assertIn(".onReceive(NotificationCenter.default.publisher(for: .onboardingPlusSheetClosed))", root_view)
        onboarding = source("NekoWidget/Views/OnboardingView.swift")
        self.assertIn("NotificationCenter.default.post(name: .onboardingPlusSheetClosed, object: nil)", onboarding)


class FormerReportsEntryTests(unittest.TestCase):
    def test_a_left_window_shows_its_report_answers(self) -> None:
        window = source("NekoWidget/Views/GroupWindowView.swift")
        self.assertIn('Button("通報への返答", systemImage: "exclamationmark.bubble")', window)
        self.assertIn("showsFormerReports = true", window)
        self.assertIn("GroupReportsView(windowID: model.windowID)", window)


class JoinOwnWindowTests(unittest.TestCase):
    def test_a_link_to_a_window_already_joined_opens_it(self) -> None:
        setup = source("NekoWidget/Views/GroupWindowSetupView.swift")
        self.assertIn("alreadyMember = windowID.map { GroupWidgetCache.entry(windowID: $0) != nil } ?? false", setup)
        self.assertIn("} catch GroupInvitationError.alreadyMember {\n            alreadyMember = true", setup)
        self.assertIn('Label("もうこのまどに入っています", systemImage: "checkmark.circle")', setup)
        self.assertIn("windowID: invitation.windowID)", setup)
        self.assertNotIn('Text("招待されたまど")', setup)
        window = source("NekoWidget/Views/GroupWindowView.swift")
        self.assertNotIn("このiPhoneから消", window)
        self.assertIn('Button("自分のまどから消す", systemImage: "trash", role: .destructive)', window)
        self.assertIn("写真アプリの写真と、ほかの人のまどには残ります。", window)


class ReviewBRestTests(unittest.TestCase):
    def test_remaining_review_items_on_screen(self) -> None:
        client = source("NekoWidget/Services/ManagedPreservationClient.swift")
        self.assertNotIn("保存したコピーを削除すると", client)
        self.assertEqual(client.count("保存する写真やメモを減らすと、また保存できます。"), 3)
        window = source("NekoWidget/Views/GroupWindowView.swift")
        self.assertIn("Plusの支払いは、ここでは止まりません。", window)
        offer = source("NekoWidget/Services/MembershipOfferModel.swift")
        prompt = section(offer, "struct PlusOfferPrompt: View {", "struct PlusSettingsSection")
        # The sheet sits on the whole prompt, after both branches.
        self.assertLess(prompt.index("MembershipAccessNotice(decision: decision)"), prompt.index(".sheet(isPresented: $showsOffer"))
        sharing = source("NekoWidget/Services/FamilyNotebookSharing.swift")
        self.assertIn("static func waitingForCheck<T>(_ read: () async throws -> T) async throws -> T {", sharing)
        care = source("NekoWidget/Views/CatCareView.swift")
        self.assertIn("FamilyNotebookSharing.waitingForCheck({ try await service.loadFarewellSharing(toolCatID: catID) })", care)
        setup = source("NekoWidget/Views/GroupWindowSetupView.swift")
        self.assertIn("let isCurrent = inbox.pending?.id == invitation.id", setup)
        care_page = section(care, "private func takeFamilyWrites() {", "private func apply(")
        self.assertIn("fresh[keyPath: path] != storedDraft[keyPath: path]", care_page)


class CodexWiringTests(unittest.TestCase):
    def test_outcomes_from_the_relay_reach_the_screen(self) -> None:
        settings = source("NekoWidget/Views/SettingsView.swift")
        self.assertIn('static let appID: String? = "6801962436"', settings)
        setup = source("NekoWidget/Views/GroupWindowSetupView.swift")
        self.assertIn('case .alreadyMember: return "もうこのまどに入っています。', setup)
        self.assertIn('case .windowClosed: return "このまどは終わりました。"', setup)
        reporting = source("NekoWidget/Services/ProductionGroupReporting.swift")
        self.assertIn("case .disabled, .notAuthorized, .consentRequired, .notFound: current.record.progress = .unavailable", reporting)
        notebook = source("NekoWidget/Views/FamilyNotebookView.swift")
        self.assertIn("sharing.ownJoinResults.max(by: { $0.expiresAt < $1.expiresAt })", notebook)
        self.assertIn('preview?.priorRequestState == "pending"', notebook)
        self.assertIn("if case .payerPlusUnverified(isPayer: true) = pause {", notebook)
        self.assertNotIn("確認できたら自動で戻ります", notebook)
        saving = source("NekoWidget/Services/AppRecordPersistence.swift")
        self.assertIn("ほかのiPhoneで保存した記録は、使わなくなります。", saving)


class SensitiveCheckOptionalTests(unittest.TestCase):
    def test_photos_go_through_when_the_system_check_is_off(self) -> None:
        service = source("NekoWidget/Services/MomentSharePreparationService.swift")
        moderation = section(service, "actor MomentModerationService: MomentModerating {", "func requireSafeImage(at url: URL) async throws {\n        // 「")
        self.assertIn("SCSensitivityAnalyzer()", moderation)
        require = section(service, "func requireSafeImage(at url: URL) async throws {\n        // 「", "} catch {")
        self.assertIn("guard analyzer.analysisPolicy != .disabled else { return }", require)
        self.assertNotIn("throw MomentSharingError.moderationDisabled", require)
        self.assertIn("throw MomentSharingError.sensitiveContent", require)


class AlbumPurposeTests(unittest.TestCase):
    def test_album_shows_each_cat_upcoming_summaries_and_plus_honestly(self) -> None:
        album = source("NekoWidget/Views/LikedPhotosView.swift")
        main = source("NekoWidget/Views/MainTabView.swift")
        # 成長 lists every cat on the album root.
        growth = section(album, "private func timeAlbums(", "var yearArchive: some View {")
        self.assertIn("MemoriesRoute.catAlbums(profile.identifier)", growth)
        self.assertIn("selectedProfileIdentifier == nil && !profiles.isEmpty", growth)
        # ふりかえり is always there; before the first summary it says what will come.
        self.assertIn("else if showsReflectionPlaceholder { reflectionPlaceholder }", album)
        self.assertIn("ひと月に5枚ほどたまると", album)
        # Plus is shown before the tap; the tab mark only points to what opens.
        self.assertIn("if summaryNeedsPlus { plusMark", album)
        self.assertIn('membershipAccess.decision(for: .openGrowingSummary) == .allowed', main)
        # No photo permission explains what the album does.
        self.assertIn('Label("猫の写真を自動でまとめます"', album)
        self.assertNotIn("この作品から外す", source("NekoWidget/Views/SeasonalMovieView.swift"))


class GroupSendConfirmTests(unittest.TestCase):
    def test_group_send_confirms_keeps_memo_local_and_shows_progress(self) -> None:
        screen = source("NekoWidget/Views/GroupWindowView.swift")
        # Picking only prepares; sending waits for 「届ける」 on the confirmation screen.
        prepare = section(screen, "func prepare(_ item: PhotosPickerItem) async", "func deliver(")
        self.assertNotIn("client.sendPhoto(", prepare)
        self.assertIn("Task { prepared = await model.prepare(item) }", screen)
        self.assertIn("GroupSendConfirmSheet(photo: photo", screen)
        self.assertIn('"group-window-send-confirm"', screen)
        # The memo is the photo's own memo on this iPhone, saved only after sending.
        deliver = section(screen, "func deliver(", "func toggleHeart(")
        self.assertLess(deliver.index("client.sendPhoto("), deliver.index("await saveMemo(memo"))
        self.assertIn("PhotoMemoryNoteStore.shared", deliver)
        # Progress is visible while checking and sending.
        self.assertIn('"group-window-send-progress"', screen)
        # Making a window asks for Plus first, and again if the relay says so.
        create = section(screen, "struct GroupWindowCreateScreen: View {", "struct GroupWindowListSection: View {")
        self.assertIn("PlusOfferPrompt(context: .createWindow", create)
        self.assertIn("MembershipOfferSheet(model: .live(), context: .createWindow)", create)
        self.assertIn("(error as? GroupSubscriptionError) == .ownerPlusRequired", screen)
        # One way to make a window: the list links to the same screen.
        listing = section(screen, "struct GroupWindowListSection: View {", "private func row(")
        self.assertIn("GroupWindowCreateScreen(client: model.client)", listing)
        self.assertNotIn("showsNameEntry", listing)


class GroupWindowSpeedTests(unittest.TestCase):
    def test_kept_photos_and_known_windows_show_before_the_relay_answers(self) -> None:
        screen = source("NekoWidget/Views/GroupWindowView.swift")
        self.assertIn("await model.showStored()\n            await model.sync()", screen)
        sync = section(screen, "func sync() async {", "    func updateHomeScreenPhoto()")
        loop = section(sync, "for photo in photos {", "message = nil")
        self.assertIn("entries = await store.entries(windowID: windowID)", loop)
        self.assertIn('"group-window-syncing"', screen)
        # 11/7: a window read before opens with its name and kept photos (or
        # its empty state) at once; only a first-ever open shows the spinner.
        self.assertIn("if model.entries.isEmpty && !model.knowsPhotos && !model.isFormer {", screen)
        self.assertIn('.navigationTitle(model.shownName ?? "まど")', screen)
        self.assertIn("GroupWindowListNavigation.shared.rememberListed(windows)", screen)
        listing = section(screen, "struct GroupWindowListSection: View {", "private func row(")
        self.assertIn("GroupWidgetCache.entries()", listing)
        # Known windows show while loading, and stay when the relay cannot be reached.
        self.assertIn("if model.windows.isEmpty, !model.hasLoaded || model.message != nil {", listing)
        self.assertIn('"group-window-list-stale"', listing)


class GroupWidgetOpenTests(unittest.TestCase):
    def test_home_screen_photo_opens_its_group_window(self) -> None:
        cache = source("Shared/Sharing/GroupWidgetCache.swift")
        open_url = section(cache, "static func openURL(windowID: String) -> URL?", "static func windowID(fromOpenURL url: URL)")
        self.assertIn('components.host = "group-window"', open_url)
        self.assertIn('URLQueryItem(name: "window", value: windowID)', open_url)
        parse = section(cache, "static func windowID(fromOpenURL url: URL)", "// MARK: Reading")
        self.assertIn("items.count == 1", parse)
        self.assertIn("isValidID(windowID)", parse)
        # 11/7: the shown photo may ride along, under its own name and the same ID rule.
        self.assertIn('if let photoID, isValidID(photoID) { items.append(URLQueryItem(name: "photo", value: photoID)) }', open_url)
        self.assertIn('items[1].name == "photo", let photoID = items[1].value, isValidID(photoID)', parse)
        entry = source("NekoWidgetWidget/NekoWidgetEntry.swift")
        photo_url = section(entry, "var photoURL: URL? {", "var memoryActionURL: URL?")
        self.assertLess(photo_url.index("GroupWidgetCache.windowID(fromSourceID:"), photo_url.index("PublicWindowDefinition.windowID"))
        self.assertIn("GroupWidgetCache.openURL(windowID: groupWindowID, photoID: groupWindowPhoto?.photoID)", photo_url)
        app = source("NekoWidget/ViewModels/AppViewModel.swift")
        hook = section(app, "func handleURL(_ url: URL) {", "guard let link = DeepLink(url: url) else {")
        self.assertIn("GroupWindowOpenInbox.shared.open(windowID: groupWindowID, photoID: GroupWidgetCache.photoID(fromOpenURL: url))", hook)
        screen = source("NekoWidget/Views/GroupWindowView.swift")
        self.assertIn("if model.windows.contains(where: { $0.id == requested }) {", screen)
        tab = source("NekoWidget/Views/MainTabView.swift")
        self.assertIn(".onChange(of: groupWindowOpenInbox.pendingWindowID, initial: true)", tab)


class GroupWidgetHeartTests(unittest.TestCase):
    def test_group_heart_runs_in_the_app_for_the_shown_photo_only(self) -> None:
        intent = source("NekoWidgetWidget/SendGroupWidgetHeartIntent.swift")
        self.assertIn("static var openAppWhenRun = false", intent)
        self.assertIn("cached.photoID == photoID", intent)
        # Only the host app signs and sends; the extension never does.
        host = section(intent, "#if NEKO_HOST_APP", "#endif")
        self.assertIn("GroupWindowClientProvider.production", host)
        self.assertIn("active: true", host)
        self.assertNotIn("URLSession", intent)
        self.assertIn("extension SendGroupWidgetHeartIntent: ForegroundContinuableIntent {}", intent)
        view = source("NekoWidgetWidget/NekoWidgetView.swift")
        control = section(view, "private func groupHeartControl(", "private func familyHeartControl(")
        self.assertIn("SendGroupWidgetHeartIntent(windowID: photo.windowID, photoID: photo.photoID)", control)
        self.assertEqual(control.count("Button("), 1)
        cache = source("Shared/Sharing/GroupWidgetCache.swift")
        self.assertIn("var myHeartActive: Bool? = nil", cache)
        project = source("NekoWidget.xcodeproj/project.pbxproj")
        widget_sources = section(project, "A00000000000000000000025 /* Sources */ = {", "A00000000000000000000028 /* Sources */")
        self.assertIn("SendGroupWidgetHeartIntent.swift in Sources", widget_sources)
        self.assertNotIn("ProductionGroupWindowClient.swift in Sources", widget_sources)


class GroupJoinOpensWindowTests(unittest.TestCase):
    def test_open_window_after_joining_opens_that_window(self) -> None:
        setup = source("NekoWidget/Views/GroupWindowSetupView.swift")
        sheet = section(setup, "struct GroupInvitationJoinSheet: View {", ".task {")
        self.assertIn("GroupWindowOpenInbox.shared.open(windowID: invitation.windowID)", sheet)
        self.assertLess(sheet.index("GroupWindowOpenInbox.shared.open"), sheet.index("dismiss()"))
        # The list opens only a window this iPhone belongs to.
        window = source("NekoWidget/Views/GroupWindowView.swift")
        self.assertIn("if model.windows.contains(where: { $0.id == requested }) {", window)


class AppOrientationTests(unittest.TestCase):
    def test_app_stays_upright(self) -> None:
        # 11/8: an iPhone-only app whose screens are made for upright use.
        import plistlib
        info = plistlib.loads((ROOT / "NekoWidget/Info.plist").read_bytes())
        self.assertEqual(info.get("UISupportedInterfaceOrientations"), ["UIInterfaceOrientationPortrait"])
        project = source("NekoWidget.xcodeproj/project.pbxproj")
        self.assertNotIn("TARGETED_DEVICE_FAMILY = \"1,2\"", project)


class SettingsLayoutTests(unittest.TestCase):
    def test_settings_put_plus_and_saving_first_and_test_tools_last(self) -> None:
        settings = source("NekoWidget/Views/SettingsView.swift")
        body = section(settings, "    var body: some View {\n        Form {", '.navigationTitle("設定")')
        # 11/8: Plus and 保存 first; one-row sections grouped; the app's own pages together.
        order = ["PlusSettingsSection()", 'Text("保存")', 'Text("写真とウィジェット")',
                 'Text("家族とまど")', '"settings-support-page"', '"settings-privacy-policy"',
                 '"settings-recommend-app"', 'Text("ねこのまどについて")', '"settings-app-version"',
                 '"settings-account-deletion"', 'Text("テスト用")']
        positions = [body.index(item) for item in order]
        self.assertEqual(positions, sorted(positions))
        for gone in ('Text("プライバシー")', 'Text("サポート")'):
            self.assertNotIn(gone, body)
        # Link and share words in the text color; only icons carry the tint (11/8).
        link_row = section(settings, "struct ExternalLinkRow: View {", "struct SettingsActionRow: View {")
        self.assertIn("Text(title).foregroundStyle(Color.primary)", link_row)
        self.assertIn(".foregroundStyle(Color(uiColor: .tertiaryLabel))", link_row)
        self.assertNotIn(".foregroundStyle(.tint)", link_row)
        self.assertIn('Text("ねこのまどを紹介する").foregroundStyle(Color.primary)', body)
        # Previews and diagnostics sit together in the test-only section.
        cut = body.index("// Test builds only.")
        for identifier in ("settings-membership-preview",
                           "settings-internal-diagnostics", "settings-billing-owner-enrollment"):
            self.assertIn(identifier, body[cut:])
            self.assertNotIn(identifier, body[:cut])
        # Plain words.
        for old in ("接続設定のみ", "画面プレビュー", "1枚ずつ非公開で共有", "ブロックした共有", "まどでめくった写真"):
            self.assertNotIn(old, settings)


class WidgetSourceOrderTests(unittest.TestCase):
    def test_shared_windows_first_and_group_empty_states_say_why(self) -> None:
        intent = source("NekoWidgetWidget/NekoWidgetConfigurationIntent.swift")
        sources = section(intent, "static var availableSources: [WidgetPhotoSource] {", "static func groupWindow(")
        self.assertLess(sources.index("GroupWidgetCache.entries()"), sources.index("sources.append(.personalLibrary)"))
        self.assertLess(sources.index("sources.append(.personalLibrary)"), sources.index("OfficialWindowConfiguration.definitions"))
        self.assertIn(".filter { $0.endpoint != nil }", sources)
        # New widgets still start on this iPhone's photos.
        self.assertIn("func defaultResult() async -> WidgetPhotoSource? {\n        .personalLibrary", intent)
        view = source("NekoWidgetWidget/NekoWidgetView.swift")
        self.assertIn('return "このまどは止まっています"', view)
        self.assertIn('"アプリを開くと写真が出ます" : "まだ写真が届いていません"', view)


class FirstLaunchInvitationTests(unittest.TestCase):
    def test_invitation_during_first_launch_joins_and_photos_tab_opens_on_all(self) -> None:
        root_view = source("NekoWidget/App/AppRootView.swift")
        self.assertIn(".onChange(of: invitationInbox.pending?.id, initial: true)", root_view)
        self.assertIn("GroupInvitationJoinSheet(invitation: invitation)", root_view)
        # The guide ends only after a window was joined and opened.
        dismiss = section(root_view, ".sheet(item: $onboardingInvitation, onDismiss: {", "GroupInvitationJoinSheet(invitation: invitation)")
        self.assertLess(dismiss.index("GroupWindowOpenInbox.shared.pendingWindowID != nil"), dismiss.index("completeOnboardingForInvitation()"))
        # Joining ends the guide from any page, not only the Photos page (11/6).
        presentation = source("NekoWidget/Views/OnboardingPresentation.swift")
        finish = section(presentation, "mutating func finishForInvitation() {", "mutating func completeWithoutWidgetPhoto()")
        self.assertIn("guard mode == .firstRun, currentPage != nil else { return }", finish)
        self.assertIn("state.finishForInvitation()", root_view)
        family = section(root_view, ".sheet(item: $familyLink, onDismiss: {", "FamilyNotebookJoinView(link:")
        self.assertIn("completeOnboardingForInvitation()", family)
        # 11/7: the first screen says how to join in one line; no help sheet.
        self.assertIn("showsInvitationHint: SharingAPIConfiguration.current.isReviewVisible", root_view)
        self.assertNotIn("OnboardingInvitationHelpView", root_view)
        onboarding = source("NekoWidget/Views/OnboardingView.swift")
        purpose = section(onboarding, "private struct OnboardingPurposePage: View", "struct OnboardingWindowMosaic: View")
        self.assertIn('Text("届いた招待リンクをタップしてください。")', purpose)
        self.assertIn('"onboarding-purpose-join-hint"', purpose)
        self.assertNotIn('"onboarding-purpose-join"', purpose)
        self.assertNotIn("struct OnboardingInvitationHelpView: View", onboarding)
        tab = source("NekoWidget/Views/MainTabView.swift")
        # Widget and showcase entries to the 写真 tab start on すべて, not the last segment.
        self.assertGreaterEqual(tab.count("selectedTab = .photos\n                photoLibrarySelection.select(.all)"), 2)
        self.assertIn("selectedTab = .photos\n            photoLibrarySelection.select(.all)", tab)


class Build269FeedbackTests(unittest.TestCase):
    def test_one_cat_care_title_profile_birthday_and_own_photo_heart(self) -> None:
        profiles = source("NekoWidget/Views/CatProfilesView.swift")
        # 11/7: the birthday and adoption day sit in the one この子のこと box of each tool.
        self.assertNotIn("struct ToolCatProfileInfo", profiles)
        shared = section(source("NekoWidget/Views/CatCareView.swift"), "struct ToolCatCareSection<Extra: View>", "/// The system camera.")
        self.assertIn('LabeledContent("誕生日", value: birthday.date.formatted(date: .abbreviated, time: .omitted))', shared)
        self.assertIn('LabeledContent("迎えた日", value: adoption.date.formatted(date: .abbreviated, time: .omitted))', shared)
        store = source("NekoWidget/Services/CatCareStore.swift")
        birthdays = section(store, "func importBirthdays(", "func ensureRecord(")
        self.assertIn('editedBy: "import:Profile"', birthdays)
        self.assertIn("return stored != day", birthdays)
        for path in ("NekoWidget/Views/CareHandoffView.swift", "NekoWidget/Views/CatCareView.swift",
                     "NekoWidget/Views/CatPreparednessView.swift", "NekoWidget/Views/VeterinaryVisitView.swift",
                     "NekoWidget/Views/EvacuationPreparationView.swift"):
            self.assertIn("importBirthdays(profiles)", source(path), path)
        window = source("NekoWidget/Views/GroupWindowView.swift")
        self.assertIn("let shown = !entry.isHidden && !safety.hasReported(entry.id, in: model.windowID)", window)
        self.assertIn("if shown && !entry.isOwn {", window)


class TwoPersonWindowHiddenTests(unittest.TestCase):
    def test_group_builds_show_no_two_person_window(self) -> None:
        tab = source("NekoWidget/Views/MainTabView.swift")
        self.assertIn('"group-window-unavailable"', tab)
        self.assertIn("GroupInvitationJoinSheet(invitation: invitation)", tab)
        self.assertIn(".onChange(of: groupWindowOpenInbox.pendingWindowID, initial: true)", tab)
        for name in ("FamilyWindowView", "PairingView", "PhotoWindowDeliveryView", "BlockedSharingView"):
            self.assertFalse((ROOT / "NekoWidget/Views" / (name + ".swift")).exists())
        for path in ("Views/MainTabView.swift", "Views/SettingsView.swift", "App/AppRootView.swift"):
            current = source("NekoWidget/" + path)
            self.assertNotIn("PairingView(", current)
            self.assertNotIn("FamilyWindowView(", current)
        browser = source("NekoWidget/Views/LikedPhotosView.swift")
        self.assertIn("GroupLibraryDeliverySheet(client: client", browser)
        self.assertNotIn("PhotoWindowDeliveryView(", browser)
        root_view = source("NekoWidget/App/AppRootView.swift")
        dismiss = section(root_view, ".sheet(item: $onboardingInvitation, onDismiss: {", "GroupInvitationJoinSheet(invitation: invitation)")
        self.assertNotIn("isFamilyWindowPresented", dismiss)



class LibraryGroupDeliveryTests(unittest.TestCase):
    def test_photo_detail_delivers_to_a_group_window_after_confirming(self) -> None:
        browser = source("NekoWidget/Views/LikedPhotosView.swift")
        self.assertIn('"photo-browser-deliver-group"', browser)
        # The deliver button is pinned at the bottom, visible without scrolling the footer.
        self.assertIn("// The one main action, always in view (not below the fold).", browser)
        self.assertIn("GroupLibraryDeliverySheet(client: client, localIdentifier: request.localIdentifier)", browser)
        window = source("NekoWidget/Views/GroupWindowView.swift")
        sheet = section(window, "struct GroupLibraryDeliverySheet: View {", "/// Shown after a photo is picked")
        # One window: no choosing step. Sending only from the confirmation's button.
        self.assertIn("if openWindows.count == 1 {", sheet)
        self.assertEqual(sheet.count("model.deliver("), 1)
        self.assertIn('"group-library-delivery-send"', sheet)
        prepare = section(window, "func prepare(localIdentifier: String) async", "func toggleHeart(")
        self.assertLess(prepare.index("GroupPhotoModeration.check(jpeg"), prepare.index("return PreparedPhoto("))
        self.assertIn(".canonicalJPEG", prepare)
        self.assertNotIn("client.sendPhoto(", prepare)


class WindowListOrderTests(unittest.TestCase):
    def test_shared_photo_detail_keeps_explicit_load_failure(self) -> None:
        components = source("NekoWidget/Views/PhotoDetailComponents.swift")
        local_image = section(components, "struct MomentLocalImageView:", "private struct MomentDownsampledImage:")
        self.assertIn("@State private var loadFailed = false", local_image)
        self.assertIn("} else if loadFailed {", local_image)
        self.assertIn("guard let rendered else {", local_image)
        self.assertIn("loadFailed = true", local_image)

    def test_shared_windows_first_and_public_windows_named(self) -> None:
        tab = source("NekoWidget/Views/MainTabView.swift")
        self.assertLess(tab.index("GroupWindowListSection(client: client, compactHeader: Version1.isOn)"), tab.index('.accessibilityIdentifier("window-list-receiving")'))
        arrival = section(tab, "@ViewBuilder private var arrivalLayout:", "private func reload() async")
        self.assertLess(arrival.index("groupSection"), arrival.index("ForEach(receivingPublicWindows)"))
        self.assertLess(arrival.index("ForEach(receivingPublicWindows)"), arrival.index("let discoverable"))
        self.assertIn('publicCard(source, presentation: .wide)', arrival)
        self.assertIn('publicCard(source, presentation: .row)', arrival)
        self.assertIn('"window-list-discover"', tab)
        setup = source("NekoWidget/Views/GroupWindowSetupView.swift")
        self.assertNotIn("退出", setup)


class GroupWindowAuditFixTests(unittest.TestCase):
    def test_window_goes_on_after_a_member_leaves(self) -> None:
        window = source("NekoWidget/Views/GroupWindowView.swift")
        sync = section(window, "    func sync() async {", "    func updateHomeScreenPhoto()")
        self.assertIn("latest.state == .rotationRequired, latest.canManage", sync)
        self.assertIn("client.rotate(", sync)
        members = source("NekoWidget/Views/GroupWindowSetupView.swift")
        self.assertIn("try? await client.rotate(", section(members, "    func load(reportsFailure: Bool = true) async {", "func createInvitation()"))
        self.assertIn("func rotate(windowID: String, operation: GroupOperation) async throws -> GroupWindow",
                      source("NekoWidget/Services/GroupWindowContract.swift"))

    def test_waiting_photos_and_failed_sends_are_explained(self) -> None:
        window = source("NekoWidget/Views/GroupWindowView.swift")
        self.assertIn("catch MomentSharingError.moderationDisabled {\n            return .checkOff", window)
        self.assertIn("receiveNotice = waiting.map(GroupPhotoModeration.receiveMessage)", window)
        deliver = section(window, "    func deliver(_ prepared: PreparedPhoto", "func retryFailedDelivery()")
        self.assertIn("let operationID = prepared.operationID", deliver)
        self.assertNotIn("UUID()\n            let sent", deliver)
        self.assertIn("failedDelivery = FailedDelivery(photo: retry, memo: memo)", deliver)
        self.assertIn('"group-window-send-retry"', window)

    def test_left_windows_keep_their_photos(self) -> None:
        window = source("NekoWidget/Views/GroupWindowView.swift")
        self.assertIn("GroupWindowScreen(client: model.client, windowID: former.id, formerName: former.name)", window)
        self.assertIn("guard model.hasLoaded, model.message == nil else { return }", window)
        self.assertIn("onLeft: closeAfterLeaving", window)
        setup = source("NekoWidget/Views/GroupWindowSetupView.swift")
        self.assertIn("if let onLeft { onLeft() } else { dismiss() }", setup)
        self.assertNotIn("届いた写真とお気に入りは", setup)
        self.assertNotIn("相手のiPhoneに残ります", setup)
        store = source("NekoWidget/Services/GroupWindowLocalPhotoStore.swift")
        self.assertIn("func knownWindows()", store)
        # A photo removed here is not downloaded again.
        contains = section(store, "func contains(photoID: String", "func entry(photoID:")
        self.assertNotIn("isRemoved", contains)

    def test_received_photo_can_be_kept_like_the_two_person_window(self) -> None:
        window = source("NekoWidget/Views/GroupWindowView.swift")
        favorite = section(window, "func addToFavorites(", "func remove(_ entry:")
        self.assertIn("ReceivedPhotoMemoryImportService()", favorite)
        self.assertIn('source: "received-memory"', favorite)
        self.assertIn(".receivedMemoryImportNeedsRefresh", favorite)
        self.assertLess(favorite.index("token: token, localIdentifier: nil"), favorite.index("service.importMemory("))
        detail = section(window, "private struct GroupPhotoDetail: View {", "private struct GroupPhotoPage: View {")
        self.assertIn(".tabViewStyle(.page(indexDisplayMode: .never))", detail)
        self.assertIn("に届きました", detail)
        self.assertIn('"group-photo-favorite"', detail)

    def test_widget_matches_the_app(self) -> None:
        view = source("NekoWidgetWidget/NekoWidgetView.swift")
        self.assertIn("if photo.isOwn {\n            unavailableHeartSlot", view)
        intent = source("NekoWidgetWidget/NekoWidgetConfigurationIntent.swift")
        self.assertIn("familyWindowSourceIsEnabled && !GroupWidgetCache.groupWindowsAreOn", intent)
        cache = source("Shared/Sharing/GroupWidgetCache.swift")
        self.assertNotIn("catalog.entries.insert(entry, at: 0)", cache)


class OnboardingInvitationSequenceTests(unittest.TestCase):
    def test_join_opens_at_once_and_used_invitations_go(self) -> None:
        root_view = source("NekoWidget/App/AppRootView.swift")
        # 11/7: no help sheet on the first screen, so the join sheet is the only one.
        changed = section(root_view, ".onChange(of: invitationInbox.pending?.id, initial: true)", ".sheet(item: $onboardingInvitation, onDismiss: {")
        self.assertIn("onboardingInvitation = invitation", changed)
        self.assertNotIn("showsInvitationJoin", root_view)
        self.assertIn("GroupWindowOpenInbox.shared.pendingWindowID != nil || invitationInbox.pending == nil", root_view)
        setup = source("NekoWidget/Views/GroupWindowSetupView.swift")
        settle = section(setup, "private func settleInvitation()", "// MARK: - DEBUG fixture entry")
        self.assertIn("case .approved?:", settle)
        self.assertIn("if isCurrent { inbox.discard() }", settle)


class CatCareOnePlaceTests(unittest.TestCase):
    def test_tools_read_everyday_care_from_cat_care_only(self) -> None:
        care = source("NekoWidget/Views/CareHandoffView.swift")
        for removed in ('identifier: "care-water"', 'identifier: "care-toilet"', 'identifier: "care-health"',
                        '"care-meal-time-', 'identifier: "care-usual-food"'):
            self.assertNotIn(removed, care)
        store = source("NekoWidget/Services/CareHandoffStore.swift")
        self.assertIn("everyday: CatCareSummary.careHandoffLines(care, legacy: cat)", store)
        self.assertIn("commonFields(plan: plan, household: CatCareStore.shared.state?.household)", store)
        evacuation = source("NekoWidget/Views/EvacuationPreparationView.swift")
        for removed in ('"evacuation-cat-food"', '"evacuation-cat-handling"', '"evacuation-contact"'):
            self.assertNotIn(removed, evacuation)
        plan = source("NekoWidget/Services/EvacuationPlan.swift")
        self.assertIn("var catCare = false", plan)
        evac_store = source("NekoWidget/Services/EvacuationStore.swift")
        self.assertIn("|| disclosure.catCare,", evac_store)

    def test_imports_never_refill_or_misfile(self) -> None:
        core = source("NekoWidget/Services/CatCareCore.swift")
        fill = section(core, "private static func fill(", "// MARK: - Weights from photo memos")
        self.assertIn("guard field == nil,", fill)
        self.assertIn("if r.meals.isEmpty {", core)
        store = source("NekoWidget/Services/CatCareStore.swift")
        sources = section(store, "nonisolated static func sources(", "// MARK: - Photos")
        self.assertNotIn("healthDetails", sources)
        self.assertNotIn("approachAdvice", sources)
        self.assertIn('allergy?.editedBy == "import:CareHandoff"', store)

    def test_cat_care_page_keeps_what_is_typed(self) -> None:
        view = source("NekoWidget/Views/CatCareView.swift")
        save = section(view, "private func save() {", "private func apply(")
        self.assertIn("if saved { savedDraft = value }", save)
        # 11/5: a failed autosave is one line on the page, not an alert each pause.
        self.assertIn("autosaveFailed = !saved", save)
        self.assertNotIn("saveFailed = true", save)
        self.assertIn('"cat-care-save-retry"', view)
        self.assertIn("guard loadedKey != subject.key else { return }", view)
        self.assertIn('TextField("体重（kg）例：4.2"', view)
        self.assertIn("case let .toolCat(id, name):", view)
        self.assertNotIn("enum CatCareCompleteness", view)
        self.assertNotIn("写真タブで「うちの子」を登録", view)

    def test_vet_sheet_has_its_own_heading_and_asks_first(self) -> None:
        vet = source("NekoWidget/Views/VeterinaryVisitView.swift")
        # 11/8: one name, 「診察メモ」, on the screen, the question and every page.
        exporter = section(vet, "private enum VeterinaryMemoExporter {", "\n}\n")
        self.assertIn('("診察メモ · \\(name)" as NSString).draw(in:', exporter)
        self.assertIn('confirmationDialog("診察メモを渡しますか？"', vet)
        self.assertIn('.navigationTitle("診察メモ")', vet)
        for old in ("病院で見せるメモ", "病院に渡すメモ", "診察の記録", "通院"):
            self.assertNotIn(old, vet)
        exporter = source("NekoWidget/Services/CareHandoffExporter.swift")
        self.assertIn("record.heading", exporter)
        summary = source("NekoWidget/Services/CatCareOutputLines.swift")
        self.assertIn('fields.append(("年齢", CatCareLostCat.age(', summary)


class VeterinaryRoundOneTests(unittest.TestCase):
    """病院で見せる, round 1 (11/8): results after the consultation, the screen
    and PDF order, all chosen photos, one name and plain fields."""

    def setUp(self) -> None:
        self.view = source("NekoWidget/Views/VeterinaryVisitView.swift")
        self.store = source("NekoWidget/Services/VeterinaryVisitStore.swift")

    def test_results_are_optional_and_the_only_edit_after_finishing(self) -> None:
        model = section(self.store, "struct VeterinaryVisit: Codable", "var orderedEntries")
        # Saved memos from before 11/8 have none of these keys: optional with defaults.
        for field in ("var doctorNote: String? = nil", "var prescription: String? = nil",
                      "var nextVisitOn: String? = nil", "var createdAt: Date? = nil", "var updatedAt: Date? = nil"):
            self.assertIn(field, model)
        self.assertNotIn("init(from decoder", self.store)
        save = section(self.store, "func save(_ draft: VeterinaryVisit", "func saveResults(")
        self.assertIn("state.visits[index].completedAt == nil else { throw VeterinaryVisitError.changed }", save)
        results = section(self.store, "func saveResults(", "/// Caller freezes")
        self.assertIn("state.visits[index].completedAt != nil else { throw VeterinaryVisitError.changed }", results)
        self.assertIn("var next = current", results)
        for kept in ("observations", "questions", "entries", "completedAt", "startedOn"):
            self.assertNotIn("next." + kept + " =", results)
        validate = section(self.store, "private func validate(_ visit: VeterinaryVisit)", "for entry in visit.entries")
        self.assertIn("(visit.doctorNote?.count ?? 0) <= 500, (visit.prescription?.count ?? 0) <= 500", validate)
        self.assertIn("visit.nextVisitOn.map(PhotoMemoWeightValue.validDay) ?? true", validate)
        self.assertIn("Self.keepingLocalResults(try FamilyNotebookToolSharing.visitsReceived(state.visits), from: state.visits)", self.store)
        verifier = (ROOT / "ci/verify-veterinary-visits.swift").read_text(encoding="utf-8")
        for case in ("A memo saved before the results fields became unreadable", "A finished memo was rewritten",
                     "Saving results changed what was shown", "A received family change erased or churned local results"):
            self.assertIn(case, verifier)
        # The screen: three fields, written before or after 「診察済み」.
        for text in ('title: "先生の話"', 'title: "出た薬"', 'Toggle("次に行く日を記録"', 'ToolStepHeader(number: 4, title: "診察のあと"',
                     "adopt(try await store.saveResults(draft,", '"診察済みにすると、書けるのは「診察のあと」だけになります。"'):
            self.assertIn(text, self.view)
        self.assertNotIn("このメモは書き直せなくなります", self.view)

    def test_show_screen_and_pdf_follow_the_consultation_order(self) -> None:
        read = section(self.view, "private struct VeterinaryReadView: View {", "@ViewBuilder private var exportButtons")
        order = [read.index('Text("家で気付いたこと")'), read.index("ForEach(Array(results.enumerated())"),
                 read.index("VeterinaryEntryPhoto(entry: entry"), read.index('Text("先生に聞きたいこと")'),
                 read.index("VeterinaryCatCareFields(fields: care.medical)"), read.index('Text("そのほか")')]
        self.assertEqual(order, sorted(order))
        export = section(self.view, "private func makeExport(pdf: Bool) async {", "private enum VeterinaryCareOrder")
        order = [export.index('("家で気付いたこと"'), export.index("blocks.append(.fields(noticed + results))"),
                 export.index("blocks.append(.photos(images))"), export.index('("先生に聞きたいこと"'),
                 export.index("blocks.append(.fields(care.medical))"), export.index('blocks.append(.heading("そのほか"))')]
        self.assertEqual(order, sorted(order))
        # Unwritten rows are left out on both, as on the edit side.
        care = section(self.view, "private enum VeterinaryCareOrder {", "\n}\n")
        self.assertIn('field.1.hasPrefix("未記入") || field.1.hasPrefix("未確認")', care)
        self.assertIn('["飲んでいる薬", "アレルギー", "持病", "体重の推移"]', care)
        self.assertNotIn("VeterinaryCatCareFields(fields: catCareFields)", read)
        # Every chosen photo, not the first one.
        self.assertIn("for (offset, entry) in visit.orderedEntries.enumerated()", export)
        self.assertNotIn(".first(where: { $0.photoFile != nil })", export)
        self.assertIn("visit.entries.count <= 20", self.store)

    def test_names_buttons_and_fields_are_plain(self) -> None:
        self.assertIn('Label("先生に見せる", systemImage: "stethoscope")', self.view)
        self.assertIn("短くすると保存され、先生に見せられます", self.view)
        self.assertIn("保存できると、先生に見せられます", self.view)
        self.assertNotIn("できあがり", self.view)
        self.assertIn('title: "家で気付いたこと", example: "例：1日2回吐く・食欲が半分"', self.view)
        self.assertIn('title: "先生に聞きたいこと", example: "例：ごはんを変えたほうがいいですか"', self.view)
        field = section(self.view, "private struct VeterinaryLabeledField: View {", "\n}\n")
        self.assertLess(field.index("Text(title)"), field.index("TextField(example"))
        self.assertIn(".accessibilityLabel(title)", field)
        # The mechanism stays off the screen; cleanup is retried silently.
        for old in ("使わなくなった写真のコピーが残っています", "もう一度消す", "cleanupPending ="):
            self.assertNotIn(old, self.view)
        self.assertIn("_ = try? await store.cleanupPending()", self.view)
        readable = source("NekoWidget/Services/ReadablePreservationExport.swift")
        self.assertIn('"VeterinaryVisits": "診察メモ"', readable)
        # 11/8: the fields the tools added read in Japanese; codes become words.
        for key in ("includesHealth", "includesContacts", "lastMadeAt", "lastCheckedAt", "checkStartedAt",
                    "kindValue", "identifyingFeatures", "familyMeetingMemo", "veterinarian"):
            self.assertIn(f'"{key}": "', readable)
        self.assertIn('"kindValue": ["shelter": "避難所", "family": "親戚・知人", "hotel": "ペットホテル・病院"]', readable)
        self.assertIn('"photoRemoved", "pendingPhotoCleanup"]', readable)
        self.assertNotIn("通院", readable)

    def test_started_day_previous_visit_and_past_rows(self) -> None:
        self.assertIn('Text("書き始めた日 \\(DayText.japanese(VeterinaryVisit.day(started)))")', self.view)
        finished = section(self.view, "private func looksFinished(", "/// A past memo is named")
        self.assertIn("7 * 24 * 60 * 60", finished)
        self.assertIn('Text("前の診察は終わりましたか？")', self.view)
        self.assertIn("createdAt: VeterinaryVisit.now()", self.store)
        self.assertIn("visit.updatedAt = VeterinaryVisit.now()", self.store)
        past = section(self.view, 'Section("これまでの診察メモ")', ".navigationTitle(")
        self.assertIn("Text(pastTitle(past))", past)
        self.assertIn('"vet-past-\\(past.id.uuidString)"', past)
        self.assertIn('[past.doctorNote ?? "", past.observations', self.view)
        dates = section(self.view, "private struct VeterinaryEntryDates: View {", "\n}\n")
        self.assertIn("entry.weight?.measuredOn ?? entry.capturedAt.map(VeterinaryVisit.day) ?? entry.writtenAt.map(VeterinaryVisit.day)", dates)
        self.assertNotIn("不明", dates)

    def test_page_follows_the_tool_input_shape(self) -> None:
        # 11/8 (ねこのまど_ツール入力ページの型_1108): what the page makes, four
        # numbered steps, この子のこと folded, the rest small, past memos last.
        view = self.view
        page = section(view, "@ViewBuilder private var formContent: some View {", "private func lifecycle<")
        content = section(page, "@ViewBuilder private var formContent: some View {", "@ViewBuilder private var errorSection")
        order = [content.index("headerSections(visit)"), content.index("stepSections(visit)"),
                 content.index("catCareSection(visit)"), content.index("closingSections(visit)"),
                 content.index("errorSection"), content.index("pastSection")]
        self.assertEqual(order, sorted(order))
        header = section(page, "@ViewBuilder private func headerSections(", "@ViewBuilder private func stepSections(")
        self.assertIn('ToolPurpose(text: "先生に見せる診察メモを作ります。")', header)
        self.assertLess(header.index("ToolPurpose("), header.index('"vet-started-day"'))
        self.assertLess(header.index('"vet-started-day"'), header.index('Text("前の診察は終わりましたか？")'))
        steps = section(page, "@ViewBuilder private func stepSections(", "/// Shown in a step of a finished memo")
        self.assertIn("let states = stepStates(visit)", steps)
        order = [steps.index("noticedStep(visit, states[0])"), steps.index("recordsStep(visit, states[1])"),
                 steps.index("questionsStep(visit, states[2])"), steps.index("resultsStep(states[3])")]
        self.assertEqual(order, sorted(order))
        titles = [('noticedStep(', 'ToolStepHeader(number: 1, title: "家で気付いたこと", state: state)'),
                  ('recordsStep(', 'ToolStepHeader(number: 2, title: "見せる写真・記録（任意）", state: state)'),
                  ('questionsStep(', 'ToolStepHeader(number: 3, title: "先生に聞きたいこと（任意）", state: state)')]
        for start, title in titles:
            self.assertIn(title, section(view, "private func " + start, "\n    }\n"))
        results = section(view, "private func resultsStep(", "\n    }\n")
        self.assertIn('ToolStepHeader(number: 4, title: "診察のあと", state: state)', results)
        # Each step holds its own fields: the questions moved out of step 1.
        noticed = section(view, "private func noticedStep(", "private func recordsStep(")
        self.assertIn('identifier: "vet-observations"', noticed)
        self.assertIn('Toggle("いつからかを記録", isOn: $hasStartedDay)', noticed)
        self.assertNotIn('"vet-questions"', noticed)
        records = section(view, "private func recordsStep(", "private func entryRow(")
        self.assertIn('"vet-pick-records"', records)
        self.assertIn('"vet-step-records"', records)
        questions = section(view, "private func questionsStep(", "/// Read from 「この子のこと」")
        self.assertIn('identifier: "vet-questions"', questions)
        for name in ("vet-doctor-note", "vet-prescription", "vet-next-visit-toggle"):
            self.assertIn(f'"{name}"', results)
        # Done when written; the first not done is the one to do now.
        states = section(view, "private func stepStates(", "private static func filled(")
        self.assertIn("ToolStepState.states(written)", states)
        self.assertIn("[Self.filled(observations), !visit.entries.isEmpty, Self.filled(questions), results]", states)
        self.assertIn("Self.filled(doctorNote) || Self.filled(prescription)", states)
        # A finished memo keeps only 「診察のあと」 editable, under the same headers.
        for step in (noticed, questions):
            self.assertIn("if visit.completedAt == nil {", step)
        self.assertNotIn('Section("伝えたこと")', view)
        self.assertNotIn('Text("今回伝えること")', view)
        # この子のこと folded, right after the steps.
        care = section(view, "private func catCareSection(", "/// Not part of writing the memo")
        self.assertIn("folded: true)", care)
        self.assertIn('editIdentifier: "vet-open-cat-care"', care)
        # The rest, small: the note, 診察済み, delete.
        closing = section(view, "@ViewBuilder private func closingSections(", "private func lifecycle<")
        order = [closing.index("ToolImportantInformation("), closing.index('Button("診察済みにする"'),
                 closing.index('Button("この診察メモを削除", role: .destructive)')]
        self.assertEqual(order, sorted(order))
        self.assertIn(".font(.subheadline)", closing)
        # The bar: save status on top, then the one button.
        bar = section(view, "private var bottomBar: some View {", "@ViewBuilder private var formContent")
        self.assertIn("ToolMakeBar(top: { saveStatus }) {", bar)
        self.assertIn('Label("先生に見せる", systemImage: "stethoscope")', bar)
        self.assertIn('.accessibilityIdentifier("vet-show").disabled(changes || busy)', bar)
        self.assertIn('Button("もう一度保存する") { Task { await save() } }.accessibilityIdentifier("vet-save")', bar)
        self.assertIn(".toolBottomBar { bottomBar }", view)
        # A field under a step heading of the same name hides its own; VoiceOver keeps it.
        field = section(view, "private struct VeterinaryLabeledField: View {", "\n}\n")
        self.assertIn("if showsTitle {", field)
        self.assertIn(".accessibilityLabel(title)", field)

    def test_confirmation_asks_only_when_ownership_is_unclear(self) -> None:
        confirm = section(self.view, "private struct VeterinaryRecordConfirmation: View {", "var body: some View {")
        self.assertIn("_confirmed = State(initialValue: Self.belongsOnly(to: visit.catID, source))", confirm)
        rule = section(confirm, "static func belongsOnly(", "private var wrongCat")
        self.assertIn("if let owner = source.note.weight?.catID { return owner == cat && cats.isSubset(of: [cat]) }", rule)
        self.assertIn("return cats == [cat]", rule)
        self.assertNotIn("name", rule)
        # The store still refuses an unconfirmed record and another cat's weight.
        self.assertIn("guard confirmedTarget else { throw VeterinaryVisitError.confirmationRequired }", self.store)
        self.assertIn("if let owner = source.note.weight?.catID, owner != visit.catID { throw VeterinaryVisitError.wrongCat }", self.store)
        picker = section(self.view, "private struct VeterinaryRecordPicker: View {", "private struct VeterinaryRecordConfirmation")
        self.assertIn("GridItem(.flexible(), spacing: 4), count: 3", picker)
        self.assertIn(".sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }", picker)
        self.assertIn("profile?.confirmedPhotos", picker)
        self.assertIn(".assignedProfileIdentifiers == [profile.identifier]", picker)


class NavigationAfterActionTests(unittest.TestCase):
    """After a change of state, Back never leads to a page whose action already
    happened or to something that is gone (11/6)."""

    def test_a_window_opened_from_anywhere_sits_on_the_list(self) -> None:
        window = source("NekoWidget/Views/GroupWindowView.swift")
        inbox = section(window, "final class GroupWindowOpenInbox", "// MARK: - The list in the まど tab")
        opening = section(inbox, "func open(windowID: String, photoID: String? = nil) {", "func consume()")
        self.assertLess(opening.index("GroupWindowListNavigation.shared.openedWindow = nil"), opening.index("pendingWindowID = windowID"))
        self.assertLess(opening.index("listGeneration = UUID()"), opening.index("pendingWindowID = windowID"))
        self.assertIn("GroupWindowListNavigation.shared.openedWindow = nil", section(inbox, "func showCreateFromShare()", "func dismissCreatePrompt()"))
        tab = source("NekoWidget/Views/MainTabView.swift")
        self.assertIn(".id([groupShareNavigationGeneration, groupWindowOpenInbox.listGeneration])", tab)
        # The window page is declared on the list's root, outside its lazy stacks.
        windows = section(tab, "private struct WindowListView: View {", "private var receivingPublicWindows")
        self.assertIn(".navigationDestination(item: $listNavigation.openedWindow)", windows)
        listing = section(window, "struct GroupWindowListSection: View {", "private func row(")
        self.assertNotIn("navigationDestination", listing)
        self.assertNotIn("GroupWindowScreen(client: model.client, windowID: window.id)", listing)
        # 11/7: with the home-screen photo, and a window no longer listed opens as 「前のまど」.
        self.assertIn("GroupWindowListNavigation.shared.openedWindow = GroupWindowRoute(windowID: requested, photoID: photoID)", listing)
        self.assertIn("windowID: requested, photoID: photoID, formerName: former.name)", listing)

    def test_leaving_a_window_returns_to_the_list(self) -> None:
        window = source("NekoWidget/Views/GroupWindowView.swift")
        leave = section(window, "private func closeAfterLeaving() {", "private var membersScreen")
        self.assertIn("navigation.returnToList()", leave)
        self.assertIn(".groupWindowListNeedsReload", leave)
        deletion = section(window, "struct GroupIdentityDeletionView: View {", "private func refresh() async {")
        delete = section(deletion, "private func delete() async {", "} catch {")
        self.assertIn("GroupWindowListNavigation.shared.returnToList()", delete)
        self.assertIn("NotificationCenter.default.post(name: .groupWindowListNeedsReload, object: nil)", delete)

    def test_a_waiting_invitation_is_kept_and_offered_again(self) -> None:
        tab = source("NekoWidget/Views/MainTabView.swift")
        windows = section(tab, "private struct WindowListView: View {", "private var receivingPublicWindows")
        self.assertIn("set: { if $0 == nil { invitationInbox.setAside() } }", windows)
        self.assertNotIn("invitationInbox.discard()", windows)
        setup = source("NekoWidget/Views/GroupWindowSetupView.swift")
        settle = section(setup, "private func settleInvitation()", "// MARK: - DEBUG fixture entry")
        self.assertIn("case .pending?:\n            if isCurrent { inbox.markWaiting() }", settle)
        self.assertIn("if !openedWindow, GroupWindowOpenInbox.shared.pendingWindowID == nil {", settle)
        window = source("NekoWidget/Views/GroupWindowView.swift")
        listing = section(window, "struct GroupWindowListSection: View {", "private func row(")
        self.assertIn("invitationInbox.isSetAside, invitationInbox.isWaiting", listing)
        self.assertIn("invitationInbox.reopen()", listing)
        self.assertIn('"group-window-waiting-invitation"', listing)

    def test_buying_plus_from_create_makes_the_window_once(self) -> None:
        window = source("NekoWidget/Views/GroupWindowView.swift")
        create = section(window, "struct GroupWindowCreateScreen: View {", "struct GroupWindowStandardsAgreement: View {")
        self.assertIn("createsAfterPurchase = result == .completed", create)
        self.assertIn("guard createsAfterPurchase, !retriedAfterPurchase else { return }", create)

    def test_family_pages_close_before_the_family_changes(self) -> None:
        notebook = source("NekoWidget/Views/FamilyNotebookView.swift")
        run = section(notebook, "private func run(_ action: Action) {", "var body: some View {")
        self.assertLess(run.index("dismiss()"), run.index("sharing.perform"))
        # 11/7: one place to write 「この子のこと」 — the cat's page in ツール.
        # The notebook lists the shared cats and leads nowhere else.
        self.assertNotIn("CatCareDetailView(", notebook)
        self.assertNotIn("NavigationLink(cat.name)", notebook)
        row = source("NekoWidget/Views/FamilyNotebookSharedCatRow.swift")
        self.assertNotIn("NavigationLink", row)
        tab = source("NekoWidget/Views/MainTabView.swift")
        self.assertIn("ForEach(familyOnlyCats) { cat in", tab)
        self.assertNotIn("CatCareDetailView(toolCatID: cat.toolID, name: cat.name)", notebook)
        self.assertIn("if joined == .joined { onJoined?(); dismiss() }", notebook)
        care = source("NekoWidget/Views/CatCareView.swift")
        self.assertIn("if !insideFamilyNotebook, Version1.familyNotebook || familyNotebook.hasFamily {", care)
        root_view = source("NekoWidget/App/AppRootView.swift")
        self.assertIn("FamilyNotebookJoinView(link: $0.url, onJoined: { joinedFamilyFromLink = true })", root_view)
        self.assertIn(".sheet(isPresented: $showsFamilyNotebook) { FamilyNotebookView() }", root_view)

    def test_account_page_returns_to_auto_save_after_sign_out(self) -> None:
        view = source("NekoWidget/Views/ManagedPreservationView.swift")
        self.assertIn("returnsWhenDone = isAccountEntry\n                                    coordinator.signOut()", view)
        self.assertEqual(view.count("returnsWhenDone = isAccountEntry; coordinator.dismissCompletedDeletion()"), 2)
        self.assertIn("if coordinator.errorMessage == nil, !coordinator.isSignedIn, !coordinator.hasUnsecuredMemo { dismiss() }", view)


class OnePlaceSettingsTests(unittest.TestCase):
    """11/7: each thing a person does has one place."""

    def test_settings_rows_are_one_place_each(self) -> None:
        settings = source("NekoWidget/Views/SettingsView.swift")
        body = section(settings, "    var body: some View {\n        Form {", '.navigationTitle("設定")')
        # The family notebook row stays; the cat profile row is gone.
        self.assertIn('"settings-family-notebook"', body)
        # Not tinted: hierarchical styles inside a list button turn blue (346, 11/8).
        family = section(body, "if showsFamilyNotebookRow {", '"settings-family-notebook"')
        self.assertIn('Text("家族の手帳").foregroundStyle(Color.primary)', family)
        self.assertIn(".foregroundStyle(Color(uiColor: .tertiaryLabel))", family)
        self.assertNotIn('"settings-cat-profiles"', body)
        # 保存 is one row: 自動保存 holds the profile file; without 自動保存 the file row stands alone.
        save = section(body, "if ManagedPreservationConfiguration.current.isEnabled {", 'Text("保存")')
        self.assertIn("AppRecordSettingsView(profileTransfer: (actions: catProfilesActions,", save)
        self.assertLess(save.index('"settings-managed-preservation"'), save.index("} else {"))
        self.assertGreater(save.index('"settings-cat-profile-transfer"'), save.index("} else {"))
        self.assertNotIn("プロフィールの引き継ぎはいりません", settings)
        saving = source("NekoWidget/Services/AppRecordPersistence.swift")
        transfer = section(saving, "if let profileTransfer {", '"app-record-cat-profile-transfer"')
        self.assertIn('Label("Plusなしで猫のプロフィールだけ移す"', transfer)
        self.assertIn("CatProfileTransferView(actions: profileTransfer.actions, hasProfiles: profileTransfer.hasProfiles)", transfer)

    def test_account_deletion_is_one_row_one_tap_from_settings(self) -> None:
        settings = source("NekoWidget/Views/SettingsView.swift")
        body = section(settings, "    var body: some View {\n        Form {", '.navigationTitle("設定")')
        # App Review: one row in shipping builds (outside the test-only section), one tap from 設定.
        public = body[:body.index("// Test builds only.")]
        row = section(public, "if AccountDeletionChoicesView.isAvailable {", '"settings-account-deletion"')
        self.assertIn('NavigationLink { AccountDeletionChoicesView() } label: {', row)
        self.assertIn('Label("アカウントとデータを消す"', row)
        # The old rows are gone from 設定 and from 自動保存.
        self.assertNotIn('"settings-group-identity-deletion"', settings)
        choices = section(settings, "struct AccountDeletionChoicesView: View {", "struct SettingsSheetHost")
        self.assertIn("GroupIdentityDeletionView(client: client)", choices)
        self.assertIn("ManagedPreservationView(deletesAccount: true)", choices)
        self.assertEqual(choices.count("} footer: {"), 2, "each choice says what it deletes")
        self.assertIn("GroupWindowClientProvider.production != nil || ManagedPreservationConfiguration.current.isEnabled", choices)
        saving = source("NekoWidget/Services/AppRecordPersistence.swift")
        self.assertNotIn("アカウント（削除・サインアウト）", saving)
        self.assertIn('NavigationLink("アカウント") { ManagedPreservationView() }', saving)
        # The delete button and its confirmation exist only on the deletion entry.
        view = source("NekoWidget/Views/ManagedPreservationView.swift")
        buttons = section(view, "if deletesAccount {", "} footer: {")
        self.assertLess(buttons.index('"preservation-account-delete"'), buttons.index("} else {"))
        self.assertGreater(buttons.index('Button("サインアウト", role: .destructive)'), buttons.index("} else {"))
        self.assertEqual(view.count('"preservation-account-delete"'), 1)
        self.assertIn('Button("アカウントと保存したコピーを削除", role: .destructive) { coordinator.deleteServiceAccount() }', view)

    def test_family_notebook_cats_and_leaving_have_one_place(self) -> None:
        notebook = source("NekoWidget/Views/FamilyNotebookView.swift")
        self.assertIn('Label("手帳に入れる猫を選ぶ"', notebook)
        self.assertNotIn('Label("猫を追加", systemImage: "plus") }\n                        .accessibilityIdentifier("family-notebook-add-cat")', notebook)
        # Leaving: the bottom of the notebook only.
        self.assertEqual(notebook.count('"家族の手帳から抜ける"'), 1)
        self.assertIn('"family-notebook-leave"', notebook)
        member = section(notebook, "struct FamilyNotebookMemberView: View {", "struct FamilyNotebookIntroView: View {")
        self.assertNotIn("leaveFamily", member)
        self.assertIn("return membership.canDissolve ? [.dissolve] : []", member)

    def test_one_widget_guide(self) -> None:
        official = source("NekoWidget/Views/OfficialWindowView.swift")
        guide = section(official, "struct OfficialWindowWidgetGuide: View {", "struct OfficialWindowView: View {")
        self.assertIn('WidgetPlacementGuideView(onComplete: { dismiss() }, onSkip: { dismiss() },', guide)
        self.assertIn("windowName: displayName", guide)
        self.assertNotIn("すでに置いている", official)
        # Offered once after 「受け取る」; no link that is always there.
        self.assertEqual(official.count('"official-window-widget-guide"'), 1)
        offer = section(official, "private var widgetSetupOffer: some View {", "private var introduction: some View {")
        self.assertIn("if offersWidgetSetup {", offer)
        placement = source("NekoWidget/Views/WidgetPlacementGuideView.swift")
        self.assertIn('.accessibilityIdentifier("official-window-widget-source")', placement)
        settings = source("NekoWidget/Views/SettingsView.swift")
        self.assertIn('"settings-widget-placement-guide"', settings)

    def test_empty_window_list_has_one_create_button(self) -> None:
        window = source("NekoWidget/Views/GroupWindowView.swift")
        listing = section(window, "struct GroupWindowListSection: View {", "if let invitation = invitationInbox.pending")
        self.assertIn("let hidesHeaderCreate = model.windows.isEmpty && known.isEmpty && model.message == nil", listing)
        self.assertLess(listing.index("if !hidesHeaderCreate {"), listing.index('.accessibilityIdentifier("group-window-create")'))
        self.assertIn('"group-window-empty-create"', window)

    def test_auto_save_is_offered_after_buying_plus_anywhere(self) -> None:
        offer = source("NekoWidget/Services/MembershipOfferModel.swift")
        sheet = section(offer, "struct MembershipOfferSheet: View {", "struct PlusOfferPrompt: View {")
        purchase = section(sheet, "onPurchase: {", "onRestore: {")
        self.assertIn("AutoSaveAfterPurchase.applies(after: context)", purchase)
        self.assertIn("AutoSaveAfterPurchase.shared.waitsForOnboardingEnd = true", purchase)
        self.assertIn("asksAutoSave = true", purchase)
        self.assertIn("AppRecordSettingsView(startsOnOpen: true)", sheet)
        self.assertIn("later: { onFinish(.completed) }", sheet)
        self.assertIn(".interactiveDismissDisabled(model.isWorking || asksAutoSave || showsAutoSave)", sheet)
        prompt = section(offer, "final class AutoSaveAfterPurchase", "@MainActor\n/// The one Plus screen.")
        self.assertIn("context != .preservation && ManagedPreservationConfiguration.current.isEnabled", prompt)
        self.assertIn("!AppRecordPersistence.shared.enabled", prompt)
        self.assertEqual(offer.count('"自動保存も始めますか？"'), 1, "one prompt for every entry")
        root = source("NekoWidget/App/AppRootView.swift")
        self.assertIn(".autoSaveOfferAfterOnboarding(ended: !OnboardingPresentationPersistence.requiresPresentation(", root)


if __name__ == "__main__":
    unittest.main()
