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


class FirstLaunchAndPlusLook1112Tests(unittest.TestCase):
    """11/12 見た目の点検: the first-run screens, the Widget guide and Plus."""

    GUIDE_IMAGES = ("onboarding-widget-step-1", "onboarding-widget-step-2-ios18",
                    "onboarding-widget-step-2-legacy", "onboarding-widget-step-3",
                    "onboarding-widget-cloudy", "onboarding-widget-change-source")

    @staticmethod
    def png_size(path: Path) -> tuple:
        import struct
        data = path.read_bytes()[:24]
        assert data[:8] == b"\x89PNG\r\n\x1a\n", path
        return struct.unpack(">II", data[16:24])

    def test_guide_pictures_are_drawn_screens_in_the_catalog(self) -> None:
        import json
        guide = source("NekoWidget/Views/WidgetPlacementGuideView.swift")
        assets = ROOT / "NekoWidget/Assets.xcassets"
        for name in self.GUIDE_IMAGES:
            self.assertIn(f'"{name}"', guide, name)
            folder = assets / f"{name}.imageset"
            contents = json.loads((folder / "Contents.json").read_text(encoding="utf-8"))
            files = [image["filename"] for image in contents["images"] if "filename" in image]
            self.assertEqual(files, [f"{name}.png"], name)
            # One iPhone screen at 3x, like the captures they replace.
            self.assertEqual(self.png_size(folder / f"{name}.png"), (1206, 2622), name)
        # Every step is a picture: no symbol stands in for one.
        self.assertNotIn('"sf:', guide)
        self.assertNotIn("Image(systemName:", guide)
        # The page dots keep a finger's room from the step's last line.
        self.assertIn(".padding(.bottom, 56)", guide)

    def test_nowa_art_is_small_and_decorative(self) -> None:
        assets = ROOT / "NekoWidget/Assets.xcassets"
        for name in ("Nowa-peek", "Nowa-sit-up"):
            width, height = self.png_size(assets / f"{name}.imageset/{name}.png")
            self.assertLessEqual(max(width, height), 600, name)
        offer = source("NekoWidget/Views/MembershipOfferView.swift")
        nowa = section(offer, "private static var nowaBox: some View {", "    private var offerDetails: some View {")
        self.assertIn('Image("Nowa-peek")', nowa)
        self.assertIn(".frame(height: 164)", nowa)
        self.assertIn(".accessibilityHidden(true)", nowa)
        self.assertNotIn('Image(systemName: "cat")', offer)
        onboarding = source("NekoWidget/Views/OnboardingView.swift")
        zero = section(onboarding, "private var nowaWindow: some View {", "/// Full access:")
        self.assertIn('Image("Nowa-sit-up")', zero)
        self.assertIn(".accessibilityHidden(true)", zero)
        result = section(onboarding, "private var zeroResult: some View {", "private var nowaWindow: some View {")
        self.assertLess(result.index("nowaWindow"), result.index('"onboarding-scan-zero-body"'))

    def test_first_page_fits_and_bars_match_the_page(self) -> None:
        onboarding = source("NekoWidget/Views/OnboardingView.swift")
        purpose = section(onboarding, "private struct OnboardingPurposePage: View", "struct OnboardingWindowMosaic: View")
        # The windows shrink first; the page scrolls only when the words alone do not fit.
        self.assertIn("ViewThatFits(in: .vertical) {\n            fittedPage", purpose)
        self.assertIn(".frame(width: OnboardingWindowMosaic.width(fitting: proxy.size))", purpose)
        self.assertIn("max(0, min(size.width, (size.height - 2) * 3 / 4))", onboarding)
        guide = source("NekoWidget/Views/WidgetPlacementGuideView.swift")
        for text in (onboarding, guide):
            self.assertNotIn(".background(.bar)", text)
        self.assertIn(".buttonStyle(GuideSecondaryButtonStyle())", guide)
        self.assertIn("Color(uiColor: .secondarySystemFill)", guide)

    def test_found_cats_fill_the_page(self) -> None:
        onboarding = source("NekoWidget/Views/OnboardingView.swift")
        grid = section(onboarding, "    private var photoGrid: some View {", "    private func photoTile(")
        self.assertIn("if showsProgress || photos.count >= 5 {", grid)
        self.assertIn("} else if photos.count == 3 {", grid)
        self.assertIn("let count = photos.count == 1 ? 1 : 2", grid)
        self.assertIn('.accessibilityLabel("見つかった猫写真の一部")', grid)
        self.assertIn('.accessibilityIdentifier("initial-scan-photo-\\(photo.localIdentifier)")', onboarding)

    def test_plus_purchase_block_is_tight_on_small_screens(self) -> None:
        offer = source("NekoWidget/Views/MembershipOfferView.swift")
        self.assertIn(".onGeometryChange(for: Bool.self) { $0.size.height < 640 } action: { isShortScreen = $0 }", offer)
        self.assertIn("VStack(spacing: isShortScreen ? 4 : 8) {", offer)
        self.assertIn(".padding(.bottom, pinsPurchase ? Self.fadeHeight + 20 : 20)", offer)
        links = section(offer, "    private var footerLinks: some View {", "@ViewBuilder private var footerLinkContent")
        self.assertIn("HStack(spacing: 16) { footerLinkContent }", links)
        self.assertIn("LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],", links)
        self.assertIn("if dynamicTypeSize.isAccessibilitySize {", links)


class WordingPass1112Tests(unittest.TestCase):
    """11/12 wording pass: one word per thing on the screens this pass owns.

    Each old variant below was removed; it must not come back as a string
    shown to people. Identifiers, keys and stored values are not checked."""

    OWNED = (
        "NekoWidget/Views/FamilyNotebookView.swift",
        "NekoWidget/Services/FamilyNotebookSharingContract.swift",
        "NekoWidget/Views/LikedPhotosView.swift",
        "NekoWidget/Views/MonthlyWindowView.swift",
        "NekoWidget/Views/GroupWindowSetupView.swift",
        "NekoWidget/Views/GroupWindowView.swift",
        "NekoWidget/ViewModels/AppViewModel.swift",
        "NekoWidget/Views/ManagedPreservationView.swift",
        "NekoWidget/Services/AppRecordPersistence.swift",
        "NekoWidget/Services/ManagedPreservationClient.swift",
        "NekoWidget/Services/BillingClientCore.swift",
        "NekoWidget/Services/CatCareStore.swift",
        "NekoWidget/Services/CatCandidateCurationStore.swift",
        "NekoWidget/Services/CatHouseholdIdentityStore.swift",
        "NekoWidget/Services/PhotoMemoryNoteStore.swift",
        "NekoWidget/Services/SeasonalMovieArchiveStore.swift",
        "NekoWidget/Views/CatCareView.swift",
        "NekoWidget/Views/MainTabView.swift",
        "NekoWidget/Views/CatProfilePhotoCurationViews.swift",
        "NekoWidget/Views/CatProfileTransferView.swift",
        "Shared/Sharing/ClientUpgradeRequirement.swift",
        "NekoWidgetWidget/NekoWidgetView.swift",
        "NekoWidgetWidget/NekoWidgetConfigurationIntent.swift",
        "NekoWidgetWidget/NekoWidgetTimelineProvider.swift",
        "NekoWidgetWidget/WidgetManifestReader.swift",
        "NekoWidgetWidget/ToggleWidgetLikeIntent.swift",
    )

    REMOVED = (
        # 家族の手帳, not 家族
        "家族から抜けますか", "家族から外す", "を家族から外しますか", "この名前で家族を作る",
        "家族は 1 つまで", "この家族は、もう人数", "この家族の共有は終わ",
        # 月の作品
        "月のまとめ",
        # このまどは終わりました／終わったまど
        "このまどは閉じられています", "このまどはもうありません", "利用できなくなりました",
        "使えなくなったまど", "このまどは表示できません", "ウィジェットを編集してください",
        # 確認をやめるボタンは「キャンセル」
        'Button("戻る", role: .cancel)', 'placement: .cancellationAction) { Button("やめる")',
        # お問い合わせ
        "サポートにお問い合わせ", 'Link("問い合わせる"', "問い合わせから連絡",
        # アプリを最新にする
        "アップデートして", "アプリを新しくして", "（形式 ",
        # この子のこと／猫の名前と日付
        "猫のプロフィールだけ移す", "猫のプロフィールが変わりました", "猫のプロフィールを",
        "猫のプロフィールがまだ", '"プロフィールを編集"',
        # 自動保存
        "保存用のアカウント", "アカウントと保存したコピー", "書き出せる期限",
        # 作品が「とどきました」
        "作品が届きました",
        # 半角のすき間
        "Plus を", "の Plus", "ひと月に 5 枚", "この iPhone", "の iPhone", "タップで きょうの 1 枚",
        # 中の事情
        "以前の保存先と", "前のデータの片づけ", "ファイルを片づけられません", "購入情報を引き継いで", "購入情報を、このiPhoneに引き継いで",
        "引き継ぎを最初からやり直して",
    )

    def test_removed_variants_do_not_come_back(self) -> None:
        literal = re.compile(r'"(?:[^"\\\n]|\\.)*"')
        for path in self.OWNED:
            code_lines = [line for line in source(path).splitlines() if not line.lstrip().startswith("//")]
            code = "\n".join(code_lines)
            # Only what is inside string literals, so comments and names do not count.
            shown = "\n".join("\n".join(literal.findall(line)) for line in code_lines)
            for old in self.REMOVED:
                is_code = old.startswith(("Button(", "placement", "Link(", '"'))
                self.assertFalse(old in (code if is_code else shown), f"{path}: {old}")

    def test_standard_words_are_used(self) -> None:
        notebook = source("NekoWidget/Views/FamilyNotebookView.swift")
        self.assertIn('"家族の手帳から抜けますか？"', notebook)
        self.assertIn('"この名前で手帳を作る"', notebook)
        self.assertIn('"\\(member.displayName)を家族の手帳から外しますか？"', notebook)
        self.assertIn('"\\(presentation.monthNumber)月の作品"', source("NekoWidget/Views/MonthlyWindowView.swift"))
        self.assertIn('"これまでの月の作品・季節のムービー"', source("NekoWidget/Views/LikedPhotosView.swift"))
        self.assertIn('return "このまどは終わりました。"', source("NekoWidget/Views/GroupWindowSetupView.swift"))
        self.assertIn('"終わったまど"', source("NekoWidgetWidget/NekoWidgetConfigurationIntent.swift"))
        self.assertIn('Text("Plusをやめたあとも、12か月のあいだは読み出しと書き出しができます。このiPhoneの記録は残ります。")',
                      source("NekoWidget/Views/ManagedPreservationView.swift"))
        self.assertIn('"App Storeでアプリを最新にしてください。"', source("Shared/Sharing/ClientUpgradeRequirement.swift"))
        setup = source("NekoWidget/Views/GroupWindowSetupView.swift")
        self.assertIn('Text("メンバー全員が写真を届けられなくなり、元に戻せません。届いた写真は「前のまど」で見られます。")', setup)
        self.assertIn('Text("これから届く写真は見られなくなります。届いた写真は「前のまど」で見られます。")', setup)


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
        self.assertIn('return "このまどは終わりました"', empty_title)
        self.assertIn('return "写真を待っています"', empty_title)
        self.assertNotIn('return "まだ届いていません"', empty_title)
        self.assertIn('return "写真を準備しています"', empty_title)
        self.assertIn('return "長押しして、別のまどを選んでください"', empty_title)
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
        # 11/10: right after placing, the personal Widget is "being prepared",
        # not an error that tells the person to update.
        self.assertIn('return "写真を準備しています"', view)
        self.assertIn('return "アプリを開くと始まります"', view)
        self.assertNotIn('return "写真を表示できません"', view)
        self.assertNotIn('return "アプリを開いて更新"', view)
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
        self.assertIn('name: "終わったまど"', resolved)
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
        self.assertIn('NavigationLink("これまでの月の作品・季節のムービー", value: MemoriesRoute.reflectionsArchive)', album_root)
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
        self.assertIn('NavigationLink("これまでの月の作品・季節のムービー", value: MemoriesRoute.reflectionsArchive)', memory_view)
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
        # 11/8: the old cards and their explanation sheet were never shown
        # (the アルバム tab shows the movies); they are gone.
        for gone in ("struct SeasonalMovieCard", "SeasonalMovieAboutSheet", "struct SeasonalMovieArchiveCard",
                     "nextWorkDescription", "似た写真をまとめます", "写真が少ない季節は作りません"):
            self.assertNotIn(gone, view)
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
        # 11/8: said once (before saving), not again while it is prepared.
        self.assertEqual(view.count("Live Photoは、保存した動画では静止画になります。"), 1)
        self.assertNotIn("動画はこのiPhoneの中だけで作っています。", view)
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
        # 11/12: one plain, true sentence: what is found, where it shows, and
        # that the finding happens on the iPhone. The 「うちの子」 album left
        # the app (10/31) and the seasonal movie is Plus, so neither is named.
        self.assertIn("PHOTO_LIBRARY_USAGE_DESCRIPTION = 猫の写真をiPhoneの中で見つけて、アルバムとホーム画面のウィジェットに出すために使います。\n", config)
        for term in ("うちの子", "季節のムービー", "写真ライブラリ", "端末内"):
            self.assertNotIn(term, section(config, "PHOTO_LIBRARY_USAGE_DESCRIPTION = ", "\n"))
        self.assertNotIn("元の写真や動画を変更・削除しません", config)

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
        # 11/8: names only in the Widget's source list.
        self.assertIn('detail: "くもりのまど"', widget_configuration)
        self.assertNotIn("毎日1枚、猫を順番に", widget_configuration)
        self.assertNotIn("· 公式のまど", widget_configuration)
        self.assertIn("name: definition.displayName, detail: definition.subtitle", widget_configuration)
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
        # 11/7: cats are opened from the この子 tab (was ツール) only, not from 設定.
        self.assertNotIn('"settings-cat-profiles"', settings)
        self.assertNotIn("CatProfilesView(", settings)
        # 11/14: the 「この子のこと」 row is the last row of the care card.
        self.assertIn('.accessibilityIdentifier(links.cat.profile != nil ? "tools-cat-\\(links.cat.id)"',
                      source("NekoWidget/Views/CatHomeCareView.swift"))
        self.assertIn('.navigationTitle(opensProfileSettings ? "猫のプロフィール" : "猫ごとの写真")', profiles)
        # 11/10: page two has no title of its own (it repeated page one), and
        # Photos turned off says one state and one sentence, no features.
        self.assertNotIn('"このiPhoneの中から、"', onboarding)
        self.assertIn('"写真へのアクセスがオフです"', permission)
        self.assertIn('"設定で許可すると、猫の写真を探せます。"', permission)
        self.assertNotIn("季節のムービー", permission)
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

        # 11/8: no 「i」 button or alert explaining how photos are picked.
        self.assertNotIn('写真の選び方について', growth)
        self.assertNotIn('aboutSelectionMessage', growth)
        self.assertNotIn('info.circle', growth)
        self.assertIn('scrapbookTimeline(items: resolvedItems)', growth)
        self.assertIn('Label("写真を変える"', growth)
        # The screen title names the album; no second big range heading above the story.
        self.assertNotIn('.font(.title.bold())', growth)
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
            "struct CatProfileLifeReferenceEditor: View",
        )
        # 11/8: the never-opened 「アルバムをつなぐ」 screen is gone.
        self.assertNotIn("CatProfilePhotoAlbumSelectionView", profile)
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
        self.assertIn("photoLibraryCatRow", library)
        # 11/11: the add button is in the one cat row over the pages.
        row = section(main, "private var photoLibraryCatRow: some View {", "private var photoLibraryCatPicker: some View {")
        self.assertIn("$0.identifier == photoLibraryProfileIdentifier", row)
        self.assertIn("CatProfileAddPhotosButton(", row)
        # The name, key photo and deleting are in この子のこと: the photo and
        # name at the top of the page (11/7); 11/12: the four parts are
        # always open and deleting is the page's last row, after all of them.
        care = source("NekoWidget/Views/CatCareView.swift")
        page = section(care, "@ViewBuilder private var formContent: some View {", "@ViewBuilder private var statusSections")
        self.assertIn("profileHeading(profile)", page)
        self.assertLess(page.index("profileHeading(profile)"), page.index("basicsSection"))
        # 11/12 (round 2): deleting is in 「…」 at the top right, not a last row.
        self.assertNotIn("deleteSection(profile)", page)
        self.assertIn('itemIdentifier: "cat-profile-delete"', care)
        self.assertNotIn("folded(", page)
        basics = section(care, "private var basicsSection: some View {", "private var sexPicker: some View {")
        self.assertNotIn("profileHeading(profile)", basics)
        self.assertNotIn("deleteSection(profile)", basics)
        # 11/13: the key photo can be any cat photo; see CatHomePolish1113Tests.
        self.assertIn('.accessibilityIdentifier("cat-care-key-photo-empty")', care)
        heading = section(care, "private func profileHeading(", "private var isProfile: Bool {")
        self.assertIn("showsKeyPhotoPicker = true", heading)
        self.assertIn('"cat-profile-rename"', heading)
        self.assertIn("await profileActions.updateName(profile.identifier, draftName)", heading)
        # 11/11: renamed in the system dialog, not in rows opened under the name.
        self.assertIn('.alert("名前を変更", isPresented: $showsNameEditor)', heading)
        self.assertIn('Button("キャンセル", role: .cancel) {}', heading)
        self.assertNotIn("if showsNameEditor {", heading)
        self.assertIn("return await profileActions.setKeyPhoto(profile.identifier, identifier)", care)
        # 11/12 (round 2): deleting is in 「…」; the same question and choices.
        delete = section(care, "private var isProfile: Bool {", "// MARK: 健康")
        # 11/8: 「この子」, not 「プロフィール」.
        self.assertIn('Button("この子を削除", role: .destructive)', delete)
        self.assertNotIn("プロフィール", delete)
        self.assertIn('.alert("この子を追加できませんでした"', source("NekoWidget/Views/CatProfilesView.swift"))
        self.assertIn("await profileActions.deleteProfile(profile.identifier)", delete)
        self.assertIn('Button("旅立った日を記録する") { showsFarewellEditor = true }', delete)
        self.assertIn("元に戻せません。", section(care, "private var form: some View {", "var body: some View {"))
        self.assertNotIn("openParts", care)
        self.assertIn('sheetRow("誕生日・迎えた日", "birthday.cake", value: profile.lifeDatesSummary,', care)
        self.assertIn('"cat-care-life-dates"', care)
        # The album link is not offered on the cat's page (この子のこと). 11/13: its
        # one entry is in the 写真 tab beside 「この子の写真を追加」 (CatHomePolish1113Tests).
        self.assertNotIn('"写真アプリのアルバムをつなぐ"', page)
        self.assertNotIn('"写真アプリのアルバムをつなぐ"', care)
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
        sheet = section(profile, "struct CatPhotoAssignmentSheet: View", "struct CatProfilePhotoPicker: View")
        # 11/8: the never-opened 「前に外した写真」 screen is gone.
        self.assertNotIn("LegacyCatExclusionReviewView", profile)
        self.assertNotIn("LegacySelectablePhotoGrid", profile)
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
        # 11/12: opened from 設定 (closeTitle), one more last step says how to
        # change what the Widget shows. Not at first launch, not for a window.
        self.assertIn(
            'static let widgetChangeSourceStep = "出す写真を変えるには、ウィジェットを長押しして「ウィジェットを編集」→「表示する写真」。まども選べます。"',
            presentation,
        )
        self.assertIn("closeTitle != nil && windowName == nil", guide)
        self.assertIn('[(image: "onboarding-widget-change-source", text: OnboardingPresentationCopy.widgetChangeSourceStep)]', guide)
        self.assertIn("return placementSteps + cloudy + changeSource", guide)
        # 11/10: place first, then come back. The hint is on the screen. 11/12:
        # the button checks nothing, so it says the person goes out to place
        # it, not that it was placed.
        self.assertIn('static let widgetAction = "ホーム画面で置いてきます"', presentation)
        self.assertNotIn('"置きました"', presentation)
        # 11/12: the guide's last step uses the Widget's own words.
        self.assertIn('[(image: "onboarding-widget-cloudy", text: OnboardingPresentationCopy.widgetCloudyStep)]', guide)
        widget_view = source("NekoWidgetWidget/NekoWidgetView.swift")
        self.assertIn('"タップで、きょうの1枚"', widget_view)
        self.assertIn("「タップで、きょうの1枚」を押すと", presentation)
        for text in (guide, presentation):
            self.assertNotIn("札を押すと", text)
        self.assertIn('"追加してアプリへ戻ると、自動で確認します。"', presentation)
        self.assertIn("Text(OnboardingPresentationCopy.widgetReturnHint)", guide)
        self.assertNotIn("猫を登録すると", guide)
        self.assertNotIn("hasCats", guide)
        self.assertIn(
            ".onChange(of: widgetInstallationChecker.isInstalled, initial: true)",
            app_root,
        )
        self.assertIn(
            ".onChange(of: onboardingState.currentPage, initial: true)",
            app_root,
        )
        # Coming back from placing the Widget closes a 写真-tab guide and
        # turns the first run's guide into 「置けました」. It never advances
        # the first run by itself, so no Plus page opens on return (11/10).
        installed = section(app_root, ".onChange(of: widgetInstallationChecker.isInstalled, initial: true)",
                            ".onChange(of: onboardingState.currentPage, initial: true)")
        self.assertIn("showsWidgetPlacementGuide = false", installed)
        self.assertNotIn("completeWidgetPlacementGuideIfNeeded()", installed)
        self.assertNotIn("advance()", installed)
        self.assertIn("isWidgetPlaced: widgetInstallationChecker.isInstalled,", app_root)
        onboarding_view = source("NekoWidget/Views/OnboardingView.swift")
        self.assertIn("if isWidgetPlaced {\n                    OnboardingWidgetPlacedPage(close: finish)", onboarding_view)
        self.assertNotIn("(.widgetGuide, .plusOffer)", app_root)
        # The cloudy images are prepared when the guide opens, before the
        # person reaches the Home Screen (11/10).
        guide_page = section(app_root, ".onChange(of: onboardingState.currentPage, initial: true)", ".onDisappear {")
        self.assertIn("guard page == .widgetGuide else { return }", guide_page)
        self.assertIn("await viewModel.refreshInstalledCloudyWindows()", guide_page)
        store = source("Shared/Storage/CloudyWindowStore.swift")
        self.assertIn("static let prePlacementPhotoCount = 3", store)
        self.assertIn("guard preparesBeforePlacement(state) else { return nil }", store)
        self.assertIn("!installed.isEmpty || preparesBeforePlacement(state),", store)
        completion = section(
            app_root,
            "private func completeWidgetPlacementGuideIfNeeded()",
            "@MainActor\nprivate final class PhotoPresentationCache",
        )
        self.assertIn("showsWidgetPlacementGuide = false", completion)
        self.assertIn("guard state.currentPage == .widgetGuide else { return }", completion)
        self.assertIn("state.advance()", completion)
        self.assertIn("persistOnboardingState(state, entersPhotos: entersPhotos)", completion)
        self.assertIn("WidgetCenter.shared.getCurrentConfigurations", checker)

    def test_first_three_minutes_review_rules(self) -> None:
        """11/12 review of the first three minutes."""
        app_root = source("NekoWidget/App/AppRootView.swift")
        presentation = source("NekoWidget/Views/OnboardingPresentation.swift")
        main = source("NekoWidget/Views/MainTabView.swift")
        onboarding = source("NekoWidget/Views/OnboardingView.swift")
        album = source("NekoWidget/Views/AlbumPrototypeView.swift")
        home = source("NekoWidget/Views/HomeView.swift")
        # A found photo opens over the scan page; the first run goes on, so
        # 「ウィジェットを置く」 is still there when the photo is closed.
        open_photo = section(app_root, "openPhoto: { photo in", "openNowaWindow: openNowaWindowFromOnboarding")
        self.assertIn("guard onboardingState.currentPage == .scanResult,", open_photo)
        self.assertIn("firstRunPhoto = photo", open_photo)
        self.assertNotIn("completeOnboarding", open_photo)
        self.assertNotIn("persistOnboardingState", open_photo)
        self.assertIn(".sheet(item: $firstRunPhoto)", app_root)
        fixture = source("NekoWidget/App/AppStoreScreenshotFixture.swift")
        fixture_photo = section(fixture, "openPhoto: { photo in", "firstRunPhoto = photo")
        self.assertNotIn("finished = true", fixture_photo)
        # The first Plus offer is due however the first run ended: one place,
        # on the step that ends it, and nowhere tied to the Widget guide.
        persist = section(app_root, "private func persistOnboardingState(", "private func dismissWidgetPlacementGuide()")
        self.assertIn("OnboardingPresentationPersistence.endsFirstRun(from: onboardingCompletedVersion,", persist)
        self.assertIn("FirstPlusOfferPolicy.noteFirstRunEnded()", persist)
        self.assertEqual(app_root.count("FirstPlusOfferPolicy.noteFirstRunEnded("), 1)
        self.assertNotIn("if page == .widgetGuide {", app_root)
        # Every other guard stays: once, not for members, not in the opening
        # that ended the first run, a Widget placed, cleared or the next day.
        offer = section(main, "private func offerFirstPlusIfDue() async {", "/// A sheet, cover, alert")
        self.assertIn("!membershipAccess.hasPersonalPlus()", offer)
        self.assertIn("!defaults.bool(forKey: FirstPlusOfferPolicy.shownKey)", offer)
        self.assertIn("try? await Task.sleep(for: .seconds(1.5))", offer)
        self.assertIn("FirstPlusOfferPolicy.noteFirstRunEnded(defaults: defaults)", offer)
        self.assertLess(offer.index("FirstPlusOfferPolicy.noteFirstRunEnded(defaults: defaults)"),
                        offer.index("try? await Task.sleep"))
        policy = section(presentation, "enum FirstPlusOfferPolicy {", "extension Notification.Name {")
        self.assertIn("guard let dueSince, !shown, plusIsOffered, widgetPlaced, !promptedThisLaunch,", policy)
        self.assertIn("activeSince > dueSince", policy)
        # The 写真 tab is remembered when the first run ends into it, under
        # the key MainTabView reads.
        self.assertIn('static let lastTabKey = "navigation.lastTab.v1"', presentation)
        self.assertIn('@AppStorage("navigation.lastTab.v1") private var lastViewedTab', main)
        self.assertIn("if entersPhotos { FirstRunTabMemory.rememberPhotosTab() }", persist)
        for name, end in (("private func completeOnboarding() {", "/// One tap past a resumed Plus page."),
                          ("private func skipOnboardingPlusOffer() {", "private func completeOnboardingWithoutPhotoAccess()"),
                          ("private func completeOnboardingWithoutPhotoAccess() {", "/// Joined a まど"),
                          ("private func completeOnboardingWithoutWidgetPhoto() {", "/// `entersPhotos`"),
                          ("private func completeWidgetPlacementGuideIfNeeded() {", "@MainActor\nprivate final class")):
            self.assertIn("persistOnboardingState(state, entersPhotos: ", section(app_root, name, end), name)
        invitation = section(app_root, "private func completeOnboardingForInvitation() {", "/// 「あとで」 (or 「はじめる」")
        self.assertNotIn("entersPhotos: true", invitation)
        # The automatic Plus offer and the notification request for album
        # works never share a launch: whichever comes first, the other waits.
        ask = section(album, "static func askIfNeeded() async {", "#if DEBUG || INTERNAL_PRESENTATION")
        self.assertIn("!FirstPlusOfferPolicy.promptedThisLaunch", ask)
        self.assertLess(ask.index("FirstPlusOfferPolicy.promptedThisLaunch = true"),
                        ask.index("center.requestAuthorization(options: [.alert])"))
        self.assertIn("promptedThisLaunch: FirstPlusOfferPolicy.promptedThisLaunch", offer)
        # No cat: said plainly, one next step that fits, and のわのまど through
        # the existing official-window sheet. Never 「アクセスを確かめて」.
        self.assertNotIn("写真へのアクセスを確かめて、もう一度探してください。", onboarding)
        self.assertNotIn('Text("写真へのアクセスを確かめてください。")', home)
        self.assertIn("OnboardingPresentationCopy.scanZeroLimitedBody", home)
        zero = section(onboarding, "private var zeroResult: some View {", "private var photoGrid: some View {")
        self.assertIn("isLimitedAccess ? OnboardingPresentationCopy.scanZeroLimitedBody", zero)
        self.assertIn('"initial-scan-zero-nowa"', zero)
        self.assertIn("labeledContinueButton(OnboardingPresentationCopy.scanZeroStartAction)", zero)
        nowa = section(app_root, "private var openNowaWindowFromOnboarding: (() -> Void)? {", "@ViewBuilder")
        self.assertIn("officialWindowRoute = OfficialWindowRoute(windowID: Self.nowaWindowID)", nowa)
        self.assertIn('private static let nowaWindowID = "black-cats"', app_root)
        # The title says 「見つかりました」 from the first cat; the count keeps
        # 「まだ探しています」 until the scan is final.
        self.assertIn("return scan.displayedCatCount > 0 || scan.hasFinalResult", onboarding)
        self.assertIn("if !scan.hasFinalResult {\n                Text(OnboardingPresentationCopy.scanStillSearching)", onboarding)
        self.assertNotIn("scanCountLead", onboarding + presentation)

    def test_first_run_lands_on_photos_and_plus_comes_later_once(self) -> None:
        app_root = source("NekoWidget/App/AppRootView.swift")
        presentation = source("NekoWidget/Views/OnboardingPresentation.swift")
        main = source("NekoWidget/Views/MainTabView.swift")
        app = source("NekoWidget/App/NekoWidgetApp.swift")
        # 11/10: every ending of the first run lands on the 写真 tab, once;
        # MainTabStartupPolicy still decides every later launch.
        for name, end in (("private func completeOnboarding() {", "/// One tap past a resumed Plus page."),
                          ("private func skipOnboardingPlusOffer() {", "private func completeOnboardingWithoutPhotoAccess()"),
                          ("private func completeOnboardingWithoutPhotoAccess() {", "/// Joined a まど"),
                          ("private func completeOnboardingWithoutWidgetPhoto() {", "private func persistOnboardingState("),
                          ("private func completeWidgetPlacementGuideIfNeeded() {", "@MainActor\nprivate final class")):
            body = section(app_root, name, end)
            self.assertIn("startsInPhotosAfterOnboarding = ", body, name)
        self.assertIn("MainTabStartupPolicy.selection(lastTab: lastViewedTab", main)
        # The first run never routes to the Plus page; the reducer completes.
        reducer = section(presentation, "mutating func advance() {", "mutating func skipPlusOffer()")
        self.assertIn("case .widgetGuide, .plusOffer:", reducer)
        self.assertNotIn("routeFirstRun(to: .plusOffer)", presentation)
        # The first offer: once, on a later opening, after a cleared window or
        # the next day, over the person's own cat, never with the review prompt.
        policy = section(presentation, "enum FirstPlusOfferPolicy {", "extension Notification.Name {")
        self.assertIn("activeSince > dueSince", policy)
        self.assertIn("hasClearedCloudyWindow || !calendar.isDate(now, inSameDayAs: dueSince)", policy)
        self.assertIn("FirstPlusOfferPolicy.activeSince = .now", app)
        offer = section(main, "private func offerFirstPlusIfDue() async {", "/// A sheet, cover, alert")
        self.assertIn("CloudyWindowStore.shared.hasRevealedAnyWindow()", offer)
        self.assertIn("await UsageCounter.anyWidgetPlaced() == true", offer)
        self.assertIn("!membershipAccess.hasPersonalPlus()", offer)
        self.assertIn("FirstPlusOfferPolicy.promptedThisLaunch = true", offer)
        self.assertIn("FirstPlusOfferPolicy.noteShown(defaults: defaults)", offer)
        self.assertLess(main.index("MembershipOfferSheet(model: .live(), context: .onboarding)"),
                        main.index(".environment(\\.plusOfferPhoto, bestShowcaseCandidate.map {"),
                        "the first offer must show the person's own cat")
        review = section(main, "private func askForReviewAfterPhotoIfDue() async {", "@ViewBuilder")
        self.assertIn("askedThisSession: !firstThisSession || FirstPlusOfferPolicy.promptedThisLaunch", review)
        self.assertIn("FirstPlusOfferPolicy.promptedThisLaunch = true", review)
        # A resumed first-run Plus page also shows the person's own cat.
        self.assertIn(".environment(\\.plusOfferPhoto, hasPhotoAccess ? viewModel.catAssets.first.map {", app_root)
        model = source("NekoWidget/Services/MembershipOfferModel.swift")
        # 11/11: the daily Widget photo is free, so no reason line at all.
        self.assertIn("case .onboarding: nil", model)
        self.assertNotIn("毎日新しくなるのはPlus", model)

    def test_paired_consent_renewal_and_dynamic_build_identity_are_explicit(self) -> None:

        presentation = source("NekoWidget/Views/PairingPresentation.swift")
        self.assertIn('forInfoDictionaryKey: "CFBundleShortVersionString"', presentation)
        self.assertIn('forInfoDictionaryKey: "CFBundleVersion"', presentation)
        self.assertIn('return "バージョン \\(resolvedVersion)（Build \\(resolvedBuild)）"', presentation)



class AppDrawingWasteTests(unittest.TestCase):
    """Work that drawing used to repeat for nothing stays removed."""

    def test_internal_detection_samples_are_not_built_in_shipping_builds(self) -> None:
        root = source("NekoWidget/App/AppRootView.swift")
        samples = section(root, "private func internalDetectionAccuracySample(", "private func excludedCatPhotoPresentations(")
        for name in ("internalDetectionAccuracySample", "internalHighResolutionRecoverySample"):
            body = section(samples, f"private func {name}(", "\n    }\n")
            self.assertIn("#if DEBUG || INTERNAL_PRESENTATION", body)
            self.assertIn("#else\n        .init()\n#endif", body)
        # The ranking itself only exists where Settings shows it.
        guarded = samples[samples.index("#if DEBUG || INTERNAL_PRESENTATION\n    private var detectionAccuracySamplePresentation"):]
        self.assertIn("private func highResolutionRecoverySamplePresentation(", guarded)
        self.assertTrue(guarded.rstrip().endswith("#endif"))
        presentation = section(root, "settings: settingsPresentation,", "excludedCatPhotos:")
        self.assertIn("detectionAccuracySample: internalDetectionAccuracySample(hasPhotoAccess: hasPhotoAccess)", presentation)
        self.assertIn("highResolutionRecoverySample: internalHighResolutionRecoverySample(", presentation)
        self.assertNotIn("? detectionAccuracySamplePresentation", presentation)

    def test_app_root_does_not_observe_the_family_notebook(self) -> None:
        root = source("NekoWidget/App/AppRootView.swift")
        self.assertNotIn("@ObservedObject private var familyNotebook", root)
        # Still made at launch, so the first run's 「この子のこと」 reaches it.
        self.assertIn("private let familyNotebook = FamilyNotebookPrototype.shared", root)
        main = source("NekoWidget/Views/MainTabView.swift")
        # 11/12: the この子 tab's page observes it; the whole tab view no longer does.
        self.assertNotIn("@ObservedObject private var familyNotebook", main)
        self.assertNotIn("@ObservedObject private var careStore", main)
        home = source("NekoWidget/Views/CatHomeView.swift")
        self.assertIn("@ObservedObject private var familyNotebook = FamilyNotebookPrototype.shared", home)

    def test_seasonal_movie_video_digest_is_remembered_between_drawings(self) -> None:
        main = source("NekoWidget/Views/MainTabView.swift")
        key = section(main, "private var seasonalMoviePreparationKey: SeasonalMoviePreparationKey {", "private func prepareSeasonalMovie()")
        self.assertNotIn("SeasonalMovieVideoCatalog.digest(", key)
        self.assertIn("seasonalMovieVideoCatalogDigest.digest(for: .init(", key)
        self.assertIn("photoPresentationVersion: photoPresentationVersion,\n                libraryChangeCount: photoLibraryChangeCount", key)
        self.assertIn("seasonalMovieVideoCatalogDigest.forget()", key)
        cache = section(main, "private final class SeasonalMovieVideoCatalogDigestCache {", "private struct LazyToolDestination")
        self.assertIn("if self.input != input {\n            digest = SeasonalMovieVideoCatalog.digest(", cache)
        self.assertIn("@State private var seasonalMovieVideoCatalogDigest = SeasonalMovieVideoCatalogDigestCache()", main)
        self.assertIn(".onReceive(NotificationCenter.default.publisher(for: .photoLibraryContentDidChange)) { _ in\n            photoLibraryChangeCount &+= 1", main)
        model = source("NekoWidget/ViewModels/AppViewModel.swift")
        observer = section(model, "private lazy var libraryObserver = PhotoLibraryObserver {", "init() {")
        self.assertIn("NotificationCenter.default.post(name: .photoLibraryContentDidChange, object: nil)", observer)

    def test_plus_offer_photo_is_found_without_sorting_every_candidate(self) -> None:
        main = source("NekoWidget/Views/MainTabView.swift")
        self.assertIn(".environment(\\.plusOfferPhoto, bestShowcaseCandidate.map {", main)
        self.assertNotIn("showcaseCandidates.first.map", main)
        best = section(main, "private var bestShowcaseCandidate: PhotoPresentation? {", "private var toolsView: some View {")
        self.assertNotIn(".sorted", best)
        self.assertNotIn("Dictionary(", best)
        self.assertIn("!Self.showcaseCandidatePrecedes(photo, current)", best)
        self.assertIn("for photos in [libraryPhotos, likedPhotos, catPhotos] {", best)
        # One ordering rule for the list and for the single best photo.
        candidates = section(main, "private var showcaseCandidates: [PhotoPresentation] {", "private static func showcaseCandidatePrecedes(")
        self.assertIn("}.sorted(by: Self.showcaseCandidatePrecedes)", candidates)

    def test_photo_library_filter_is_built_once_per_list(self) -> None:
        main = source("NekoWidget/Views/MainTabView.swift")
        builder = section(main, "private func photoLibraryIncludesFilter() -> (String) -> Bool {", "private var photoLibraryCatPhotos")
        self.assertLess(builder.index("guard let selected = photoLibraryProfileIdentifier else { return { _ in true } }"),
                        builder.index("let registered = photoLibraryRegisteredIdentifiers"))
        closure = builder[builder.index("return { identifier in"):]
        self.assertNotIn("photoLibraryRegisteredIdentifiers", closure)
        self.assertNotIn("currentPhotoLibraryAssignments", closure)
        for start, end in (("private var photoLibraryCatPhotos", "private var photoLibraryLikedPhotos"),
                           ("private var photoLibraryLikedPhotos", "private var photoLibraryBrowserPhotos"),
                           ("private var unavailablePhotoLibrarySavedCount", "private var photoLibraryCatPicker")):
            body = section(main, start, end)
            self.assertIn("let includes = photoLibraryIncludesFilter()", body)
            self.assertNotIn("photoLibraryIncludes(", body)
        scoped = section(main, "private func scopedCatPhotos(for scope:", "guard case let .profile(identifier) = scope else {")
        self.assertNotIn("photoLibraryIncludes(", scoped)

    def test_tool_pages_are_built_only_when_shown(self) -> None:
        main = source("NekoWidget/Views/MainTabView.swift")
        tools = section(main, "private var catHomeTools: CatHomeTools {", "private func openShowcaseTool(")
        for page in ("VeterinaryVisitsView(", "LostCatEmergencyEntryView(", "CareHandoffView(", "EvacuationPreparationView("):
            self.assertIn("AnyView(LazyToolDestination {\n                    " + page, tools)
        self.assertEqual(tools.count("LazyToolDestination {"), 4)
        # The page pushes the tools by value; each is built only when pushed.
        home = source("NekoWidget/Views/CatHomeView.swift")
        self.assertIn("NavigationLink(value: CatHomeRoute(tool: tool, catID: cat.id)) { content }", home)
        self.assertIn("NavigationLink(value: CatHomeRoute(tool: tool, catID: nil)) { content }", home)
        self.assertIn(".navigationDestination(for: CatHomeRoute.self) { route in toolPage(route) }", home)
        lazy = section(main, "private struct LazyToolDestination<Content: View>: View {", "private struct PhotoThemeCatKey")
        # 11/11: a tool is shown without the tab bar.
        self.assertIn("var body: some View { content().toolChrome() }", lazy)

    def test_home_screen_photo_is_read_and_written_only_when_it_changes(self) -> None:
        screen = source("NekoWidget/Views/GroupWindowView.swift")
        home = section(screen, "    func updateHomeScreenPhoto() async {", "private func receive(")
        self.assertIn("let keepsCachedImage = previous?.photoID == newest?.id && previous?.imageFileName != nil", home)
        self.assertIn("let jpeg = keepsCachedImage ? nil : imageURL.flatMap { try? Data(contentsOf: $0) }", home)
        self.assertEqual(home.count("Data(contentsOf"), 1)
        # The hide check still runs before anything is handed to the cache.
        self.assertLess(home.index("|| safety.hasReported(newest.id, in: windowID) { return }"), home.index("let jpeg ="))
        self.assertLess(home.index("let jpeg ="), home.index("try GroupWidgetCache.update("))
        cache = source("Shared/Sharing/GroupWidgetCache.swift")
        update = section(cache, "static func update(", "// MARK: Files")
        self.assertLess(update.index("if previous == entry, catalog.entries.count <= maximumWindows { return }"),
                        update.index('appendingPathComponent("catalog.json")'))
        safety = source("NekoWidget/Services/GroupReporting.swift")
        load = section(safety, "func loadRecords(windowID: String) async {", "func hasReported(")
        self.assertIn("if records[windowID] != nextRecords { records[windowID] = nextRecords }", load)
        self.assertIn("if locallyReportedPhotos[windowID] != reported { locallyReportedPhotos[windowID] = reported }", load)
        self.assertIn("if pendingBlocks[windowID] != nextBlocks { pendingBlocks[windowID] = nextBlocks }", load)
        # An unreadable record still covers the photo.
        self.assertIn("unreadableSuppression.insert(windowID)", load)

    def test_group_photo_page_decodes_once_off_the_main_thread(self) -> None:
        screen = source("NekoWidget/Views/GroupWindowView.swift")
        page = section(screen, "private struct GroupPhotoPage: View {", "private struct GroupPhotoPageImageKey")
        self.assertNotIn("UIImage(contentsOfFile", page)
        self.assertIn("@State private var image: UIImage?", page)
        self.assertIn(".task(id: GroupPhotoPageImageKey(id: entry.id, isHidden: entry.isHidden)) {", page)
        self.assertIn("GroupPhotoDecoder.image(at: url, maxPixel: 2048)", page)
        self.assertIn("Task.detached(priority: .userInitiated)", page)
        # 2048px is the largest photo a window accepts, so nothing is shrunk.
        self.assertIn("(1...2048).contains(width), (1...2048).contains(height)",
                      source("NekoWidget/Services/GroupWindowPhotoValidation.swift"))

    def test_month_jump_months_are_worked_out_once_per_drawing(self) -> None:
        home = source("NekoWidget/Views/HomeView.swift")
        heading = section(home, "@ViewBuilder private var detectedPhotosSection: some View {", '.id("photo-library-all-heading")')
        self.assertEqual(heading.count("monthDestinations"), 1)
        self.assertIn("monthJumpMenu(monthDestinations)", heading)
        menu = section(home, "private func monthJumpMenu(", "private func moveToMonth(")
        self.assertNotIn("monthDestinations", menu)
        self.assertIn("PhotoLibraryMonthJumpMenu(months: months, select: moveToMonth)", menu)
        shared = section(home, "struct PhotoLibraryMonthJumpMenu: View {", "struct HomeView: View {")
        self.assertNotIn("months(in:", shared)
        self.assertIn('.accessibilityIdentifier("photo-library-month-jump")', shared)
        # The 写真 tab's cat row works the months out once for its two layouts.
        main = source("NekoWidget/Views/MainTabView.swift")
        row = section(main, "private struct PhotoLibraryCatRow<", "private struct PhotoThemeTile: View {")
        self.assertEqual(row.count("PhotoLibraryMonthDestination.months(in: photos)"), 1)

    def test_idle_auto_save_seconds_publish_nothing(self) -> None:
        persistence = source("NekoWidget/Services/AppRecordPersistence.swift")
        once = section(persistence, "    private func synchronizeOnce() async {", "        var phase = ")
        # No await before `busy`, and an idle second returns before it.
        self.assertNotIn("await", once)
        self.assertLess(once.index("if case .success(nil) = starting { return }"),
                        once.index("busy = true\n        defer { busy = false }"))
        work = section(persistence, "private func bindingWithWork() throws -> Binding? {", "    private func synchronizeOnce()")
        self.assertIn("guard requested || cleanupPending || value.pending != nil"
                      " || !(value.retiring ?? []).isEmpty || waitingForEditor else { return nil }", work)
        self.assertIn("if !requested, Date() < cleanupNextAttempt { return nil }", work)
        self.assertIn("try AppRecordDataset.requireScope(owner: value.owner, origin: value.origin)", work)
        self.assertNotIn("await", work)
        # A thrown binding error is still handled inside, while busy.
        body = section(persistence, "        var phase = \"保存設定を確認\"", "try AppRecordEditingLease.requireIdle()")
        self.assertIn("guard var value = try starting.get() else { return }", body)


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
        self.assertIn('static let pausedDetail = "これまでの写真はそのままで、新しい写真だけ届きません。"', presentation)
        self.assertIn("window.deliveryStatus == .paused", presentation)
        # Never says anything is deleted.
        for forbidden in ("削除", "消え"):
            self.assertNotIn(forbidden, section(presentation, "static let pausedDetail", "static func pausedOwnerName"))

        paused = section(view, "private func pausedSection(", "private func statusSection(")
        self.assertIn('Label("このまどは止まっています"', paused)
        # 11/8 (30): 「このまどを続ける」 is on the window's own card only.
        self.assertNotIn("このまどを続ける\")", paused)
        self.assertNotIn("showsPlusOffer", view)
        self.assertNotIn("plusOfferModel", view)
        self.assertEqual(view.count("MembershipOfferSheet("), 0)
        window = source("NekoWidget/Views/GroupWindowView.swift")
        card = section(window, "private func pausedCard(", "private func failedDeliveryRow(")
        self.assertEqual(card.count('Text("このまどを続ける")'), 1)
        self.assertIn("MembershipOfferSheet(model: .live(), context: .continueWindow)", window)
        # The state, then one sentence: the owner's, or who can resume it.
        self.assertEqual(card.count("GroupWindowPresentation.pausedDetail"), 1)
        self.assertLess(card.index("if GroupWindowPresentation.isMyWindow(window) {"), card.index("GroupWindowPresentation.pausedDetail"))
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
        self.assertIn('"終わったまど"', resolve)

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
        # 11/12: the number has a page of its own, with the same example and keyboard.
        self.assertIn('Self(title: "マイクロチップ番号", systemImage: "number", example: "15桁の数字", path: \\.microchip,\n'
                      '             identifier: "cat-care-microchip", keyboard: .numberPad, isMicrochip: true)', view)
        # Vaccination proof can come from Photos.
        self.assertIn("証明の写真を選ぶ", view)
        # Deleting marks, never removes.
        self.assertIn("markDeleted", view)
        self.assertNotIn(".remove(at:", view)
        tab = source("NekoWidget/Views/MainTabView.swift")
        # 10/22: the cat's 「この子のこと」 card on the この子 tab opens the
        # cat's page, which is この子のこと (CatCareDetailView).
        home = source("NekoWidget/Views/CatHomeView.swift")
        self.assertIn("carePage: AnyView(carePage(cat))", home)
        self.assertIn("NavigationLink { links.carePage } label: { CatHomeCareRow(title: \"この子のこと\", value: nil) }",
                      source("NekoWidget/Views/CatHomeCareView.swift"))
        self.assertIn("case let .profile(profile):\n            profilePage(profile)", home)
        # 11/1: a cat whose farewell day is recorded shows no progress; 11/14:
        # nor 「これからのこと」 (no count on the page at all).
        self.assertIn("guard !facts.departed else { return nil }", home)
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
        self.assertIn("VeterinaryMemoExporter.create(name: displayName ?? visit.catName, blocks: blocks, pdf: pdf,\n"
                      "                                                         face: face)", export)
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
        self.assertIn('? "入っていない" : text(record?.microchip?.value)))', fields)
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
        # Round 2: the story and the small flyer are judged on their own too.
        self.assertIn("LostCatFlyerRenderer.issues(draft, output: format)", preview)
        self.assertIn("static func issues(_ draft: LostCatPublicDraft, output: LostCatOutput)", renderer)
        self.assertIn("issues(draft, output: paper ? .paper : .social)", renderer)
        self.assertNotIn("validationIssues", preview)
        # Every A4 or SNS overflow names a field, so a red line is always beside it.
        self.assertNotIn('issues["layout"]', renderer)
        self.assertIn('"\\(format.issueName)に入りきりません。\\(label)を短くしてください。"', renderer)
        self.assertIn('"features": "特徴"', renderer)
        # The SNS image stays 1080x1350: letters and photo shrink, the canvas never grows.
        self.assertIn("private static let socialSize = CGSize(width: 1080, height: 1350)", renderer)
        self.assertNotIn("canvas.height +=", renderer)
        self.assertIn("let canvas = paper ? paperSize : (format == .story ? storySize : socialSize)", renderer)
        self.assertIn("private static let storySize = LostCatOutput.story.canvas", renderer)
        self.assertIn("if !compact { return layout(draft, format: format, compact: true) }", renderer)
        # A4 contact is 32pt or larger and above the name; the title is white on a red band.
        # 11/12: the place and the contact are the largest after the title; the
        # compact sizes are the earlier ones, so what fitted before still fits.
        self.assertIn("maxSize: paper ? (compact ? 32 : 40) : (compact ? 48 : 58), minSize: paper ? 32 : 37", renderer)
        self.assertIn('id: "name", maxSize: paper ? (compact ? 23 : 30) : (compact ? 53 : 52)', renderer)
        self.assertIn("maxSize: paper ? (compact ? 17 : 32) : (compact ? 43 : 54), minSize: paper ? 17 : 34", renderer)
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
        self.assertIn('static let hashtags = LostCatText.hashtags', public)
        self.assertIn('static let hashtags = "#迷子猫 #迷い猫"', source("NekoWidget/Services/LostCatIncident.swift"))
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
        # 11/11: the input pages' bottom bar, the button the full width; the
        # page is plain (not grouped), so the bar takes that colour.
        self.assertIn("ToolMakeBar(ground: NekoPalette.plainGround) {", preview)
        self.assertIn('Label("保存・共有する", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)', preview)
        self.assertIn("text: format.sharesPost ? draft.message : nil", preview)
        self.assertIn("var sharesPost: Bool { self == .social }", source("NekoWidget/Services/LostCatIncident.swift"))
        self.assertIn("LostCatActivitySheet(items: item.items)", preview)
        self.assertIn("if let text { return [url, text] }", view)
        # 11/8 tool shape: the button names what it makes.
        self.assertIn('Button { openPreview() } label: { Label("チラシを作る", systemImage: "doc.richtext").frame(maxWidth: .infinity) }', view)
        self.assertNotIn("チラシを見る", view)
        self.assertNotIn("できあがりを見る", view)
        self.assertNotIn('"プレビュー"', view)

    def test_reporting_lives_in_step_two_of_the_guide(self) -> None:
        view = source("NekoWidget/Views/CatPreparednessView.swift")
        form = section(view, "struct LostCatDraftView: View {", "    // MARK: Rows (11/12)")
        self.assertNotIn("            reportSection\n", form)
        self.assertIn("LostCatGuideView(log: $draft.incidentLog, editable: loaded) { reportSection }", form)
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
        choice = section(view, "private struct LostCatPhotoChoiceView: View {", "struct LostCatPhotoCropView: View {")
        self.assertNotIn("Menu {", choice)
        self.assertNotIn("「…」", choice)
        self.assertIn('Button("写真アプリから選ぶ", systemImage: "photo.on.rectangle")', choice)
        self.assertNotIn("iPhoneの写真から選ぶ", view)
        self.assertEqual(choice.count("systemPickerButton"), 3)
        self.assertIn("showsAllCats || ownPhotos.isEmpty ? allPhotos : ownPhotos", choice)
        # 11/8: this cat first (kept), every recent photo one tap away and named so.
        self.assertLess(choice.index('Text("この子の写真").tag(false)'), choice.index('Text("最近の写真").tag(true)'))
        self.assertNotIn('Text("猫の写真")', choice)
        self.assertIn('Button("「この子のこと」の写真を使う") { useCatCarePhotos() }', view)
        self.assertNotIn("保存してある写真を使う", view)
        self.assertIn('photoTile("顔の写真", role: .face', view)
        self.assertNotIn('photoTile("顔・毛柄の写真"', view)
        self.assertNotIn("・前の写真", view)

    def test_input_page_has_the_shared_tool_shape(self) -> None:
        view = source("NekoWidget/Views/CatPreparednessView.swift")
        form = section(view, "struct LostCatDraftView: View {", "    // MARK: Rows (11/12)")
        # 11/12, a list of rows: purpose, the guide, 「チラシに載せること」, then
        # 「見つかりました」 and errors last.
        order = ['ToolPurpose(text: "探すためのチラシを作ります。")',
                 "guideSection",
                 "flyerSection(issues).disabled(!loaded)",
                 "foundSection",
                 "saveErrorSection"]
        content = section(form, "@ViewBuilder private func formContent(", "private var guideSection: some View {")
        positions = [content.index(text) for text in order]
        self.assertEqual(positions, sorted(positions))
        guide = section(form, "private var guideSection: some View {", "@ViewBuilder private var foundSection")
        self.assertIn('Text("先にすること：探す・届け出る")', guide)
        # The guide row keeps its name for VoiceOver and the UI tests; the state is its value.
        self.assertIn('.accessibilityLabel("先にすること：探す・届け出る")', guide)
        self.assertIn('} icon: { Image(systemName: "info.circle") }', guide)
        self.assertIn('.accessibilityIdentifier("lost-cat-row-guide")', guide)
        found = section(form, "@ViewBuilder private var foundSection", "@ViewBuilder private var saveErrorSection")
        self.assertIn("if loaded, draft.hasIncident {", found)
        self.assertIn('Label("保存できませんでした"', form)
        # 11/8: a failed refresh of earlier text is not announced.
        self.assertNotIn("前に入れた内容を読み込めませんでした。", view)
        self.assertNotIn("まず探す・届け出る", view)
        # No numbered steps any more: rows that each open their own page.
        for old in ("ToolStepHeader(", "ToolStepState", "stepStates", "catSection(", "incidentSection(", "contactSection(",
                    'Text("猫の写真と特徴")', 'Text("最後に見かけた場所・日時")', 'Text("見かけた方からの連絡")'):
            self.assertNotIn(old, view)
        rows = section(view, "private func flyerSection(_ issues: [String: String]) -> some View {",
                       "/// 「顔・全身」, 「顔だけ」 or 「なし」")
        self.assertIn('Text("チラシに載せること")', rows)
        order = ['"lost-cat-row-photo"', '"lost-cat-row-name"', '"lost-cat-row-features"', '"lost-cat-row-collar"',
                 '"lost-cat-row-place"', "dateRow", '"lost-cat-row-contact"', '"lost-cat-row-advice"']
        positions = [rows.index(text) for text in order]
        self.assertEqual(positions, sorted(positions))
        # The name only for a cat without a profile, as before.
        self.assertIn("if !profiles.contains(where: { $0.identifier == key }) {", rows)
        for label, key in (("名前", "name"), ("見分ける特徴", "features"), ("最後に見かけた場所", "place"),
                           ("連絡先", "contact"), ("見かけた方へ", "advice")):
            self.assertIn(f'textRow("{label}", ', rows)
            self.assertIn(f'issue: issues["{key}"])', rows)
        # A field with something to fix for the flyer is red on its row.
        text_row = section(view, "private func textRow(_ title: String", "private func flyerSection(")
        self.assertIn('value: issue ?? words ?? ToolEmptyValue.unwritten', text_row)
        self.assertIn("problem: issue != nil", text_row)
        self.assertIn('problem: issues["collar"] != nil', view)
        self.assertIn('value = faceImage == nil ? ToolEmptyValue.none : (bodyImage == nil ? "顔だけ" : "顔・全身")', view)
        # 日時 opens the date sheet at once, as 体重 does in 病院.
        date = section(view, "private var dateRow: some View {", "// MARK: Pages each row opens (11/12)")
        self.assertIn("showsDatePicker = true", date)
        self.assertIn('ToolValueRow(title: "日時"', date)
        self.assertNotIn("NavigationLink", date)
        # The prefill note stays on the page, under the rows.
        self.assertIn('.accessibilityIdentifier("lost-cat-prefill-note")', rows)
        # Labels above the fields, examples inside, optional ones say so.
        self.assertIn('Text("名前（任意）").font(.subheadline).foregroundStyle(.secondary)', view)
        self.assertIn('prompt: Text("例：むぎ")', view)
        self.assertIn('Text("場所").font(.subheadline).foregroundStyle(.secondary)', view)
        self.assertIn('Text("連絡先").font(.subheadline).foregroundStyle(.secondary)', view)
        self.assertIn('prompt: Text("例：電話番号・メール・SNS")', view)
        self.assertNotIn('LabeledContent("名前") {', view)
        # The page reads no 「この子のこと」 box itself; reporting stays in the guide.
        self.assertNotIn("ToolCatCareSection(", form)
        # One bar: 「あと：…」 or the issue sentence, and 「チラシを作る」.
        bar = section(form, "private func bottomBar(_ issues: [String: String]) -> some View {", "private var catMenu: some View {")
        self.assertIn('Button { openPreview() } label: { Label("チラシを作る", systemImage: "doc.richtext").frame(maxWidth: .infinity) }', bar)
        self.assertIn("ToolMakeBar(missing: issues.isEmpty ? requiredFields : []) {", bar)
        self.assertIn('Text("直すところがあります。赤い文字の欄を見てください。")', bar)
        self.assertIn(".disabled(!canPreview)", bar)
        self.assertNotIn("を入れると作れます", view)
        required = section(view, "private var requiredFields: [String] {", "private var canPreview")
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
        self.assertIn('? "入っていない" : text(record?.microchip?.value)))', fields)
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
        self.assertIn('? (record?.microchipStatus == CatCareMicrochipStatus.none ? "入っていない" : empty) : chip))', summary)
        # One PDF: supplies, destinations and every cat, after a confirmation.
        book = section(store, "func bookRecords()", "private static func normalizedJPEG(")
        self.assertIn("var record = try shareRecord(catID: cat.id, disclosure: disclosure)", book)
        self.assertIn("record.showsReviewDate = false", book)
        self.assertIn("disclosure.medical = true", book)
        self.assertIn("static func createBook(", exporter)
        self.assertIn("all.count <= 120", exporter)
        self.assertIn("record.attachments", exporter)
        self.assertIn("EvacuationExporter.createBook(store.bookRecords())", view)
        self.assertIn("EvacuationExporter.remove(retainedBookDirectory)", view)
        self.assertIn('confirmationDialog("印刷用のPDFを作ります"', view)
        # The half-year review is a quiet in-app note. Round 2 adds an optional
        # local notice, set only through EvacuationNotice in the store: the
        # screen and the rules never touch the notification center.
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
                     "try reviewCountsFromCreation()", "try destinations()",
                     "try expiryRules()", "try noticeSchedule()", "try takenOnTheDay()"):
            self.assertIn(name, verify)
        # The review counts from when the plan was made, and leads to the checklist.
        self.assertIn("let made = createdAt ?? earliestKnownDate ?? now", plan)
        self.assertIn("let start = max(made, lastReadyDate ?? made)", plan)
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
        self.assertIn('Text("最後に見直した日：', packing)
        self.assertNotIn("最後にそろえた日", view)
        for old in ("今回、持ったもの", "チェックを始めた日"):
            self.assertNotIn(old, view)
        # The show screen is named for what it makes, one tap from the entry.
        self.assertIn('Label("避難メモを見せる"', view)
        self.assertNotIn("見せる画面を開く", view)
        # 11/12: the shown memo is 「できあがり」, as the other tools' memos; the
        # cat's name is on the sheet, and nothing is said there without a photo.
        display = section(view, "private struct EvacuationDisplayView: View {", "private struct EvacuationActivitySheet")
        self.assertIn('.navigationTitle("できあがり")', display)
        self.assertIn('ToolMemoSheet(kind: "避難メモ", name: record.name, date: made)', display)
        self.assertNotIn("見分けるための写真はまだありません", view)
        self.assertNotIn("見分けるための写真はまだありません", source("NekoWidget/Services/EvacuationExporter.swift"))
        for old in ("できあがりを見る", '"プレビュー"', "1冊のPDFにまとめる", "新しい持ち物"):
            self.assertNotIn(old, view)
        self.assertIn('"evacuation-show-\\(cat.id.uuidString)"', view)
        self.assertIn("EvacuationPreviewItem(record: try store.shareRecord(catID: cat.id, disclosure: store.disclosure(for: cat.id)))", view)
        # The owner's paper copy has the photo with the owner; the button says it prints.
        self.assertIn("disclosure.withOwnerPhoto = true", section(store, "func bookRecords()", "private static func normalizedJPEG("))
        book = section(view, "private var bookButton: some View {", "private struct EvacuationSaveNotice")
        self.assertIn('Label("印刷用のPDFを作る"', book)
        # 11/12 (round 2): filled whenever it can be pressed, by the bar's own
        # style (gray with blue words read as 「cannot be pressed」).
        self.assertNotIn(".buttonStyle(", book)
        self.assertNotIn("hasContent", view)
        # Each entry row shows one state.
        for state in ('"写真なし："', 'count == 0 ? ToolEmptyValue.unwritten : "\\(count)件"',
                      'return ("\\(ready) / \\(needed.count)", true, false)'):
            self.assertIn(state, view)
        for old in ("置き場所が未記入", "置き場所は未記入", '"行き先 \\(', '"まだありません"'):
            self.assertNotIn(old, view)
        # Places: optional source; the stored day (old plans) is kept unless the conditions change.
        self.assertNotIn('Text("施設名と条件を書くと押せます")', view)
        self.assertNotIn("受け入れの条件を確かめた", view)
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
        # Hub: 「いま避難する」 first, the review card, one sentence, three rows,
        # 「見せる」, the note. 11/12 (round 2): the rows are the shared rows of
        # every tool (icon, name, value, chevron), not numbered two-line steps.
        hub = section(view, "struct EvacuationPreparationView: View {", "private func makeBook() async {")
        order = ['"evacuation-now-open"',
                 '"evacuation-review-reminder"',
                 'ToolPurpose(text: "災害のときに持ち出すものと、猫の避難メモを用意します。")',
                 'ToolValueRow(title: "持ち出すもの", systemImage: "backpack", value: packingState.value,',
                 'ToolValueRow(title: "猫の情報", systemImage: "cat", value: catsState,',
                 'ToolValueRow(title: "行き先と連絡先", systemImage: "mappin.and.ellipse", value: destinationsState,',
                 '} header: { Text("見せる") }',
                 'ToolImportantInformation(text: "災害のときは、まず自分と家族の安全を守ってください。")',
                 ".toolBottomBar {"]
        positions = [hub.index(needle) for needle in order]
        self.assertEqual(positions, sorted(positions))
        for identifier in ('"evacuation-packing-open"', '"evacuation-cats-open"', '"evacuation-destinations-open"'):
            self.assertIn(identifier, hub)
        self.assertNotIn("private func entry(", view)
        for old in ("ToolStepState.states(stepsDone)", "private var stepsDone", "private func step("):
            self.assertNotIn(old, view)
        # 11/9: the photo is 「この子のこと」's face or body (this tool's older one
        # until set there); the photo with the owner never counts.
        self.assertIn("return CatCareSummary.identifyingPhotoURL(care, role, legacy: store.imageURL(legacyIdentifyingPhoto(role)))", view)
        self.assertIn("identifyingPhoto(.face, store: store) ?? identifyingPhoto(.body, store: store)", view)
        self.assertIn('role == .face ? photos["face"] ?? photos["reference"] : photos["body"]',
                      source("NekoWidget/Services/CatCareOutputLines.swift"))
        self.assertIn('cats.filter { $0.identificationPhoto(store: store) == nil }.map { name(of: $0) }', view)
        # 「印刷用のPDFを作る」 is in the bottom bar, not in the list.
        bar = section(hub, ".toolBottomBar {", '.navigationTitle("避難に備える")')
        # 349: 「あと：」 names only what must be done before the button works;
        # the PDF can be made at any stage, so the steps alone show progress.
        self.assertIn("ToolMakeBar(top: {", bar)
        self.assertNotIn("missingSteps", view)
        self.assertNotIn('["見分ける写真"]', view)
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
                 "let states = ToolStepState.states([cat.identificationPhoto(store: store) != nil, true])",
                 'identifier: "evacuation-identifying-photos")',
                 '"evacuation-cat-edit"',
                 'ToolStepHeader(number: 1, title: "見分ける写真", state: states[0])',
                 '"evacuation-disclose-cat-care"',
                 'ToolStepHeader(number: 2, title: "見せる内容", state: states[1])',
                 "ToolCatCareSection(",
                 "profiles: profiles, folded: true)",
                 'ToolImportantInformation(text: "病歴・連絡先・ワクチンの証明・マイクロチップ番号は、必要な相手にだけ見せてください。")',
                 'Button("この子の避難用の記録を削除", role: .destructive)',
                 ".toolBottomBar {"]
        positions = [cat_page.index(needle) for needle in order]
        self.assertEqual(positions, sorted(positions))
        cat_bar = section(cat_page, ".toolBottomBar {", ".navigationDestination(item: $preview)")
        self.assertIn('ToolMakeBar(top: {', cat_bar)
        self.assertIn("EvacuationSaveNotice(store: store, inBar: true)", cat_bar)
        self.assertIn("if let error { Text(error)", cat_bar)
        self.assertIn('Label("避難メモを見せる"', cat_bar)
        self.assertIn(".disabled(store.saveError != nil || cat == nil)", cat_bar)
        self.assertNotIn(".safeAreaInset(edge: .bottom) { EvacuationSaveNotice(store: store) }", cat_page)
        # The save error keeps its identifier wherever the notice is shown.
        notice = section(view, "private struct EvacuationSaveNotice: View {", "private struct EvacuationPackingView: View {")
        self.assertIn('.accessibilityIdentifier("evacuation-save-error")', notice)
        self.assertIn("if inBar { content } else { content.padding().frame(maxWidth: .infinity).background(.regularMaterial) }", notice)


class EvacuationRoundTwoTests(unittest.TestCase):
    """Round 2 (11/9): 期限, the local notices, and 「いま避難する」. The rules
    run in ci/verify-evacuation-plan.swift; these check the wiring."""

    def setUp(self) -> None:
        self.plan = source("NekoWidget/Services/EvacuationPlan.swift")
        self.store = source("NekoWidget/Services/EvacuationStore.swift")
        self.view = source("NekoWidget/Views/EvacuationPreparationView.swift")

    def test_expiry_is_optional_and_shown(self) -> None:
        supply = section(self.plan, "struct EvacuationSupply: Codable, Equatable, Identifiable {", "struct EvacuationDestination")
        self.assertIn("    var expiresAt: Date?\n", supply)
        self.assertNotIn("init(from decoder", self.plan)
        for word in ('"フード"', '"水"', '"薬"', '"療法食"'):
            self.assertIn(word, supply)
        self.assertIn('"期限切れ"', supply)
        self.assertIn('"期限まであと\\(days)日"', supply)
        self.assertIn("static let expirySoonDays = 30", supply)
        # The list shows it under the item; the hub's step 1 names the nearest.
        packing = section(self.view, "private struct EvacuationPackingView", "private struct EvacuationGuidelineLink")
        self.assertIn("EvacuationExpiryLine(item: item)", packing)
        state = section(self.view, "private var packingState: (value: String, filled: Bool, problem: Bool) {",
                        "private var catsState: String {")
        self.assertIn('if let expiry = store.plan.expiryState() { return (expiry, true, expiry.contains("期限切れ")) }', state)
        # Only food, water, medicine and 療法食 offer it; it is optional.
        editor = section(self.view, "private struct EvacuationSupplyEditor: View {", "private struct EvacuationCatsView: View {")
        self.assertIn("if let item, item.canHaveExpiry {", editor)
        self.assertIn('Toggle("期限（任意）"', editor)
        self.assertIn("displayedComponents: .date", editor)
        self.assertIn("if saved, date != nil { Task { await store.firstExpirySet() } }", editor)
        # On paper, and in the readable backup in Japanese, as a date.
        self.assertIn('"期限 " + $0.nekoExportText()', section(self.store, "func bookRecords()", "private static func normalizedJPEG("))
        readable = source("NekoWidget/Services/ReadablePreservationExport.swift")
        self.assertIn('"expiresAt": "期限"', readable)
        self.assertIn('"lastMadeAt", "expiresAt", "checkStartedAt"', readable)

    def test_notices_are_local_asked_only_on_a_tap_and_follow_the_plan(self) -> None:
        notice = section(self.store, "enum EvacuationNotice {", "\n}\n")
        # Local only; no server, no push, no item or cat's name in the text.
        self.assertIn("import UserNotifications", self.store)
        self.assertIn("UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)", notice)
        for forbidden in ("registerForRemoteNotifications", "URLSession", "content.userInfo", "content.sound", "badge"):
            self.assertNotIn(forbidden, notice)
        self.assertIn('content.title = "ねこのまど"', notice)
        # The permission is asked in one place, reached only from the toggle and the first 期限.
        self.assertEqual(self.store.count("requestAuthorization"), 1)
        turn_on = section(notice, "static func turnOn(", "static func turnOff()")
        self.assertIn("requestAuthorization(options: [.alert])", turn_on)
        self.assertEqual(self.store.count("EvacuationNotice.turnOn("), 2)
        self.assertIn("return await EvacuationNotice.turnOn(plan)", section(self.store, "func turnOnNotices()", "func firstExpirySet()"))
        first = section(self.store, "func firstExpirySet()", "func turnOffNotices()")
        self.assertIn("guard schedulesNotices, !EvacuationNotice.wasChosen else { return }", first)
        self.assertNotIn("turnOn", section(self.store, "func reload()", "func retryPhotoCleanup()"))
        self.assertNotIn("turnOn", section(self.store, "func followNotices()", "func turnOnNotices()"))
        self.assertEqual(self.view.count("store.turnOnNotices()"), 1)
        self.assertEqual(self.view.count("store.firstExpirySet()"), 1)
        # Off at first; one quiet toggle on the hub, below 「見せる」.
        self.assertIn("@AppStorage(EvacuationNotice.settingKey) private var noticeSetting = 0", self.view)
        self.assertIn("static var isOn: Bool { UserDefaults.standard.integer(forKey: settingKey) == 1 }", notice)
        hub = section(self.view, "struct EvacuationPreparationView: View {", "private func makeBook() async {")
        self.assertIn('Toggle("見直しの時期に知らせる"', hub)
        self.assertIn('"evacuation-notices-toggle"', hub)
        self.assertLess(hub.index('} header: { Text("見せる") }'), hub.index('Toggle("見直しの時期に知らせる"'))
        # Replaced as the plan changes, all under one prefix; only the app's own plan.
        self.assertIn("let value = EvacuationStore(schedulesNotices: true)", self.store)
        self.assertIn("schedulesNotices: Bool = false", self.store)
        self.assertIn("guard schedulesNotices, loadError == nil else { return }", self.store)
        self.assertGreaterEqual(self.store.count("followNotices()"), 7)
        self.assertIn(".filter { $0.hasPrefix(EvacuationScheduledNotice.prefix) }", notice)
        self.assertIn("center.removePendingNotificationRequests(withIdentifiers: old)", notice)
        self.assertIn('static let prefix = "evacuation."', self.plan)
        self.assertIn("let wanted = isOn ? plan.notices(now: now, dismissedAt: dismissed) : []", notice)
        # The review notice counts as the in-app note: 「閉じる」 moves both.
        self.assertIn('nonisolated static let dismissedKey = "evacuation-review-reminder-dismissed"', notice)
        self.assertIn('@AppStorage("evacuation-review-reminder-dismissed")', self.view)
        review = section(self.view, "private func startReview() {", "private func show(")
        self.assertLess(review.index("reminderDismissedAt ="), review.index("$0.clearChecks()"))
        self.assertIn("store.followNotices()", hub)

    def test_evacuate_now_is_first_and_uses_local_data(self) -> None:
        hub = section(self.view, "struct EvacuationPreparationView: View {", "private func makeBook() async {")
        self.assertLess(hub.index('Label("いま避難する"'), hub.index('"evacuation-review-reminder"'))
        self.assertLess(hub.index('Label("いま避難する"'), hub.index("ToolPurpose(text:"))
        self.assertIn("EvacuationNowView(profiles: profiles, store: store)", hub)
        self.assertIn('"evacuation-now-open"', hub)
        now = section(self.view, "private struct EvacuationNowView: View {", "/// 環境省「人とペットの災害対策ガイドライン」")
        # The checklist, each cat's memo, and the places with a call and the map.
        self.assertIn("ForEach(needed) { item in", now)
        self.assertIn("store.takenIDs.contains(item.id)", now)
        self.assertIn('Button("\\(name(of: cat))を見せる") { show(cat) }', now)
        self.assertIn("store.shareRecord(catID: cat.id, disclosure: store.disclosure(for: cat.id))", now)
        self.assertIn("EvacuationDisplayView(record: $0.record)", now)
        self.assertIn("if let url = place.telephoneURL {", now)
        self.assertIn("if let url = place.mapURL {", now)
        self.assertIn('.navigationTitle("いま避難する")', now)
        # Offline: nothing fetched; outside pages stay out of this screen.
        for forbidden in ("URLSession", "https://", "AsyncImage", "EvacuationGuidelineLink"):
            self.assertNotIn(forbidden, now)
        # Only a check records the day; leaving changes nothing; the list's checks stay.
        take = section(now, "private func take(_ id: UUID) {", "private func show(")
        self.assertIn("store.update { $0.recordTaken(id) }", take)
        self.assertLess(take.index("store.takenIDs.remove(id); return"), take.index("recordTaken"))
        self.assertNotIn("toggleCarried", now)
        self.assertNotIn("onDisappear", now)
        self.assertNotIn("carriedIDs", now)
        self.assertIn("@Published var takenIDs: Set<UUID> = []", self.store)
        taken = section(self.plan, "mutating func recordTaken(", "mutating func clearChecks()")
        self.assertIn("guard supplies.contains(where: { $0.id == id }) else { return }", taken)
        self.assertIn("lastCheckedAt = now", taken)
        self.assertNotIn("carriedIDs", taken)


class OwnerDecisions1108Tests(unittest.TestCase):
    """11/8 owner decisions: fewer things shown, nothing hidden or lost."""

    def test_window_offers_block_and_report_only_and_keeps_old_hidden_people(self) -> None:
        window = source("NekoWidget/Views/GroupWindowView.swift")
        setup = source("NekoWidget/Views/GroupWindowSetupView.swift")
        settings = source("NekoWidget/Views/SettingsView.swift")
        # D: the photo's 「…」 has ブロック and 通報 (App Review 1.2), no 「表示しない」.
        for gone in ("の写真を表示しない", "showsHideConfirmation", "hideSender(", "の写真を表示しないようにしますか"):
            self.assertNotIn(gone, window)
        menu = section(window, 'ToolbarItem(placement: .topBarTrailing) {\n                    Menu {', '.accessibilityLabel("この写真の操作")')
        self.assertIn('.accessibilityIdentifier("group-photo-report")', menu)
        self.assertIn('.accessibilityIdentifier("group-photo-block")', menu)
        block = section(window, "func blockSender(of entry: GroupWindowLocalPhotoStore.Entry) async {", "/// For a window this iPhone left")
        self.assertIn("blocked: true)", block)
        self.assertIn("await model.blockSender(of: blocked)", window)
        # People hidden before stay hidden and readable: listed, shown again only on request.
        self.assertIn("func hide(memberID: String, name: String, windowID: String, blocked: Bool = false)",
                      source("NekoWidget/Services/GroupWindowLocalPhotoStore.swift"))
        restore = section(window, "static func restore(_ member: GroupWindowLocalPhotoStore.HiddenMember, windowID: String)",
                          "struct GroupIdentityDeletionView: View {")
        self.assertIn("if member.blocked == true {", restore)
        self.assertIn('"ブロックを解除" : "表示する"', window)
        self.assertIn('Button(member.blocked == true ? "ブロックを解除" : "表示する") { restore(member) }', setup)
        # The settings row and its screen are 「ブロックした人」; un-blocking stays there.
        self.assertIn('Label("ブロックした人", systemImage: "hand.raised")', settings)
        self.assertIn('NavigationLink { GroupHiddenMembersView() } label: {', settings)
        self.assertIn('.navigationTitle("ブロックした人")', window)
        for old in ("表示しない・ブロックした人",):
            self.assertNotIn(old, window)
            self.assertNotIn(old, settings)
            self.assertNotIn(old, setup)
        # 16: where to undo a block is said once.
        self.assertEqual(window.count("から戻せます。"), 1)
        self.assertIn('"困る写真は、写真の「…」から通報・ブロックできます。"', setup)

    def test_window_notes_are_short(self) -> None:
        window = source("NekoWidget/Views/GroupWindowView.swift")
        setup = source("NekoWidget/Views/GroupWindowSetupView.swift")
        # 15: no parenthetical notes; 38: the internal notice is only in internal builds.
        for gone in ("（7日後に削除）", "（位置情報は付きません）"):
            self.assertNotIn(gone, window)
        self.assertIn("#if DEBUG || INTERNAL_PRESENTATION\n        if SharingAPIConfiguration.current.isOwnerInternalReportsDisabled {", window)
        for gone in ("知らない人なら断れます。", "参加したあとでも外せます。", "リンクから「参加する」を押した人は"):
            self.assertNotIn(gone, setup)
        # 17: the invitation's message and expiry are not drawn; the message still travels in the share sheet.
        invitation = section(setup, "private func invitationSection(_ window: GroupWindow) -> some View {", "private func renewAndShareInvitation()")
        self.assertNotIn('"有効期限"', invitation)
        self.assertNotIn("GroupWindowPresentation.inviteMessage(", invitation)
        sheet = section(setup, "private func invitationShareSheet(", "private func manageSection(")
        self.assertIn("message: GroupWindowPresentation.inviteMessage(windowName:", sheet)

    def test_evacuation_one_pdf_and_one_memo(self) -> None:
        view = source("NekoWidget/Views/EvacuationPreparationView.swift")
        store = source("NekoWidget/Services/EvacuationStore.swift")
        # C: one 「印刷用のPDF」, drawn by createBook on the hub and on the show screen.
        display = section(view, "private struct EvacuationDisplayView: View {", "private struct EvacuationActivitySheet")
        self.assertIn('Label("印刷用のPDF", systemImage: "printer")', display)
        self.assertIn('.accessibilityIdentifier("evacuation-share-pdf")', display)
        self.assertIn("? EvacuationExporter.createBook([record])", display)
        self.assertIn(": EvacuationExporter.create(record, printCopy: false))", display)
        self.assertIn('Label("画像で渡す", systemImage: "photo")', display)
        # The export buttons sit in the bottom inset, outside the scroll view:
        # the screen's identifier must be on a container, or it replaces
        # 「印刷用のPDF」's and 「画像で渡す」's own (as c8880b79).
        before = display[:display.index('.accessibilityIdentifier("evacuation-share-preview")')].rstrip()
        self.assertTrue(before.endswith(".accessibilityElement(children: .contain)"))
        self.assertIn('.accessibilityIdentifier("evacuation-share-images")', display)
        for gone in ("PDFで渡す", "PDFを作って渡す"):
            self.assertNotIn(gone, view)
        # 31: the hub's 「〇〇を見せる」 and the cat's 「避難メモを見せる」 open the same memo.
        self.assertIn("store.shareRecord(catID: cat.id, disclosure: store.disclosure(for: cat.id))", view)
        self.assertIn("store.shareRecord(catID: id, disclosure: disclosure.wrappedValue)", view)
        self.assertIn("Binding(get: { store.disclosure(for: id) }, set: { store.disclosures[id] = $0 })", view)
        self.assertNotIn("@State private var disclosure", view)
        self.assertIn("@Published var disclosures: [UUID: EvacuationDisclosure] = [:]", store)
        # C: old per-cat and per-place dates still decode (kept, not shown).
        plan = source("NekoWidget/Services/EvacuationPlan.swift")
        self.assertIn("    var reviewedAt: Date?\n", plan)
        self.assertIn("    var checkedAt: Date?\n", plan)
        self.assertIn("guard before.reviewedAt == nil else { return false }", store)


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
        # The app says what is missing before the memo is made: once, on the
        # cat's folded 「この子のこと」 row (11/8), not again on the make page.
        self.assertIn("folded: true)", section(self.view, "@ViewBuilder private func catCareSection(", "static func isFilled("))
        # 11/12 (round 2): the row says how many, VoiceOver hears which.
        self.assertIn('value: missing.isEmpty ? "そろっています" : "あと\\(missing.count)つ"', source("NekoWidget/Views/CatCareView.swift"))
        self.assertIn('.accessibilityHint(missing.isEmpty ? "" : "まだ：" + missing.joined(separator: "・"))',
                      source("NekoWidget/Views/CatCareView.swift"))
        self.assertNotIn("まだ書いていないこと", self.view)

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
        # 11/12: what was the make page is part of the cat's page, which
        # makes the memo in one step.
        making = section(self.view, "private struct CareCatEditor: View {", "private struct CareHandoffDetachedPhotos: View {")
        # Period and request first in 「今回のお願い」; contacts shown once, in 「載せるもの」.
        rows = section(making, "private var requestSection: some View {", "private var requestLabel: ToolValueRow {")
        order = [rows.index("requestPage"), rows.index("housePage"), rows.index("catsPage"), rows.index("includePage")]
        self.assertEqual(order, sorted(order))
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
        editor = section(self.view, "private struct CareCatEditor: View {", "private struct CarePreview: Identifiable, Hashable {")
        content = section(editor, "@ViewBuilder private var formContent: some View {", "private func headerSection(")
        # What is written this time comes before what is read from 「この子のこと」.
        self.assertLess(content.index("aboutSection(cat)"), content.index("catCareSection(cat)"))
        self.assertLess(content.index("requestSection"), content.index("catCareSection(cat)"))
        about = section(editor, "private func aboutSection(_ cat: CareCat) -> some View {", "private func photoLabel(")
        self.assertIn('"care-row-important"', about)
        self.assertIn('"care-row-call-when"', about)
        # 11/8: no notes on what goes on the memo; that is chosen on the next page.
        self.assertNotIn("次の画面で選ぶと載ります", self.view)
        self.assertNotIn("いつも載ります", self.view)
        self.assertNotIn("前に入れた内容を読み込めませんでした。", self.view)
        self.assertNotIn("CareRequestEditor", self.view)
        # 347: period and request are written in one place, the make screen.
        # A chosen family cat keeps its own shared request (never this iPhone's
        # household one), so the form writes there.
        self.assertNotIn("この子の期間とお願い", editor)
        self.assertIn('text: request(\.period, \.period))', self.view)
        self.assertIn("store.plan.requestText(key, planKey, chosen: disclosure.catIDs)", self.view)
        self.assertIn("ci/verify-tool-outputs.swift", source("ci/run-quick-ios-checks.sh"))
        # 11/12: 「今回のお願い」 is the one heading over the trip's rows, once
        # for every cat; never a second form per cat.
        self.assertEqual(self.view.count('"今回のお願い"'), 1)
        self.assertIn('Text("今回のお願い")', section(editor, "private var requestSection: some View {", "private var requestLabel:"))
        # Face photo from 「この子のこと」 (11/9: chosen there only); never after the
        # owner left it off this memo. The memo's older photo is kept, not cleared.
        self.assertIn("CatCareSummary.identifyingPhotoURL(care, .face, legacy: store.imageURL(cat.photoName))", editor)
        self.assertIn("guard cat.photoRemoved != true else { return nil }", editor)
        self.assertIn('Button("このメモには載せない") { store.editCat(id) { $0.photoRemoved = true } }', editor)
        self.assertIn('Button("このメモにも写真を載せる") { store.editCat(id) { $0.photoRemoved = nil } }', editor)
        self.assertNotIn("$0.photoName = nil", editor)
        self.assertIn("next.cats[index].photoRemoved = nil", self.store)
        # Leftover photo copies are removed in the background, not by a button.
        self.assertNotIn("使わなくなった写真のコピーが残っています。", self.view)
        self.assertNotIn("もう一度消す", self.view)
        self.assertIn("store.retryPhotoCleanup()", self.view)
        self.assertIn("func retryPhotoCleanup()", self.plan)

    def test_both_pages_follow_the_input_page_shape(self) -> None:
        """11/12: one page as a list of rows, as in 設定 (病院で見せる's shape):
        purpose, 「この子について」 and 「今回のお願い」 as rows that each open
        their own page, the folded 「この子のこと」, notes last, one button at the
        bottom that makes the memo. The second page (メモを作る) is gone."""
        editor = section(self.view, "private struct CareCatEditor: View {", "private struct CarePreview: Identifiable, Hashable {")
        self.assertNotIn("CareDisclosureView", self.view)
        self.assertNotIn('"care-disclosure-open"', self.view)
        for old in ("ToolStepHeader(", "ToolStepState", "stepStates", "ToolCatStrip("):
            self.assertNotIn(old, self.view, old)
        content = section(editor, "@ViewBuilder private var formContent: some View {", "private func headerSection(")
        order = [content.index("headerSection(cat)"), content.index("aboutSection(cat)"), content.index("requestSection"),
                 content.index("catCareSection(cat)"), content.index("errorSection"), content.index("footnoteSection(cat)")]
        self.assertEqual(order, sorted(order))
        self.assertIn('ToolPurpose(text: "預ける人に渡すお世話メモを作ります。")', section(editor, "private func headerSection(", "@ViewBuilder private var errorSection"))
        # 「この子について」: the name (a cat without a profile), the photo, what
        # to say first, when to call; each row opens a page with today's field.
        about = section(editor, "private func aboutSection(_ cat: CareCat) -> some View {", "private func photoLabel(")
        self.assertIn('Text("この子について")', about)
        order = [about.index('"care-row-name"'), about.index('"care-row-photo"'), about.index('"care-row-important"'),
                 about.index('"care-row-call-when"')]
        self.assertEqual(order, sorted(order))
        self.assertIn("if !profiles.contains(where: { $0.identifier == cat.profileID }) {", about)
        photo_label = section(editor, "private func photoLabel(", "private var requestSection")
        self.assertIn('cat.photoRemoved == true ? "載せない" : (memoPhoto(cat) != nil ? "載せる" : ToolEmptyValue.none)', photo_label)
        # The photo's page keeps the face photo slot and its two buttons.
        photo = section(editor, "@ViewBuilder private func photoRows(", "private var importantPage")
        for part in ('"care-photo-open"', '"このメモには載せない"', '"このメモにも写真を載せる"'):
            self.assertIn(part, photo)
        self.assertIn('identifier: "care-cat-name", text: text(' + chr(92) + '.name), limit: 80,', editor)
        self.assertIn(".trimmingCharacters(in: .whitespacesAndNewlines).isEmpty", editor)
        # The field under a page of the same name does not repeat it, but
        # VoiceOver still reads its name; the page puts the cursor in it.
        # 11/12 (round 2): the two long texts start three lines tall.
        self.assertIn('identifier: "care-important", text: text(' + chr(92) + '.important),\n                          showsLabel: false, focus: focus, lines: 3...8)', editor)
        self.assertIn("}), showsLabel: false, focus: focus, lines: 3...8)", editor)
        self.assertIn('.accessibilityIdentifier("care-call-when-choices")', section(editor, "private var callWhenChips", "/// Period and request"))
        self.assertIn(".accessibilityLabel(label).accessibilityIdentifier(identifier)", self.view)
        self.assertIn("if showsLabel { Text(label)", self.view)
        self.assertIn("if let focus { field.focused(focus) } else { field }", self.view)
        for page in ("namePage", "importantPage", "callWhenPage", "requestPage", "housePage"):
            self.assertIn("pushed(", section(editor, f"private var {page}: some View {{", "}\n"))
        self.assertIn("ToolPushedPage(title: title, focusesField: focuses, content: content)", editor)
        # 「今回のお願い」: what was the second page, as rows.
        request = section(editor, "private var requestSection: some View {", "private var requestLabel: ToolValueRow {")
        self.assertIn('Text("今回のお願い")', request)
        for row in ('"care-row-request"', '"care-row-house"', '"care-row-cats"', '"care-row-include"'):
            self.assertIn(row, request)
        cats = section(editor, "private var catsLabel: ToolValueRow {", "private var includeLabel: ToolValueRow {")
        # 11/12 (round 2): every chosen cat by name, so the row reads as the
        # cats this memo is for, not a second cat switcher.
        self.assertIn('chosen.isEmpty ? ToolEmptyValue.none : chosen.map(' + chr(92) + '.displayName).joined(separator: "・")', cats)
        self.assertNotIn("匹", cats)
        include = section(editor, "private var includeLabel: ToolValueRow {", "// MARK: Pages each row opens (11/12)")
        for value in ('"薬・連絡先を載せる"', '"薬を載せる"', '"連絡先を載せる"', '"載せない"'):
            self.assertIn(value, include)
        # 「この子のこと」 is folded to one row, with no footer (11/8).
        cat_care = section(editor, "@ViewBuilder private func catCareSection(", "static func isFilled(")
        self.assertIn("folded: true)", cat_care)
        self.assertNotIn("footer:", cat_care)
        self.assertNotIn('Section("今回お願いする猫")', editor)
        # 11/8: what is not written yet is listed once, on the cat's row only.
        self.assertNotIn('"care-unwritten"', editor)
        self.assertNotIn("まだ書いていないこと", self.view)
        # The period and request stay written in one place.
        self.assertIn("store.update { $0.setRequestText(new, key, planKey, chosen: disclosure.catIDs) }", editor)
        # The choices of what goes on the memo are for this hand-off only: in
        # @State, set once when the page opens, never saved.
        self.assertIn("@State private var disclosure = CareHandoffDisclosure()", editor)
        init = section(editor, "private func initialize() {", "\n    }\n")
        self.assertIn("guard !initialized else { return }", init)
        self.assertLess(section(editor, "private func lifecycle<", "private var moreMenu").index("CatCareStore.shared.importFromTools()"),
                        section(editor, "private func lifecycle<", "private var moreMenu").index("initialize()"))
        # One bar: 「あと：お願いする猫」 and 「お世話メモを作る」, as on the second page.
        bar = section(editor, "private var bottomBar: some View {", "private func makeMemo() {")
        self.assertIn('ToolMakeBar(missing: initialized && disclosure.catIDs.isEmpty ? ["お願いする猫"] : [],', bar)
        self.assertIn("top: { CareSaveNotice(store: store) }", bar)
        self.assertIn(".disabled(!initialized || disclosure.catIDs.isEmpty || store.saveError != nil)", bar)
        self.assertIn('.accessibilityIdentifier("care-preview-open")', bar)
        make = section(editor, "private func makeMemo() {", "@ViewBuilder private var formContent")
        self.assertIn("chosen.catIDs.formIntersection(store.plan.cats.map(" + chr(92) + ".id))", make)
        self.assertIn("preview = CarePreview(record: try store.shareRecord(chosen))", make)
        # The cat menu in the bar, not the row of faces; a new cat is a new page.
        self.assertIn('ToolCatMenu(cats: stripCats, selectedID: selectedStripID, title: menuName,\n                        identifier: "care-cat-menu")', self.view)
        self.assertIn("editor(id).id(id)", self.view)
        self.assertNotIn("safeAreaInset(edge: .top", self.view)
        # The shared parts are used, not copied.
        for name in ("struct ToolStepHeader", "struct ToolMakeBar", "struct ToolPurpose", "enum ToolStepState",
                     "struct ToolValueRow", "struct ToolPushedPage"):
            self.assertNotIn(name, self.view)

    def test_pdf_with_several_cats_says_shared_things_once(self) -> None:
        self.assertIn("let sharedFirstPage = record.cats.count > 1", self.exporter)
        self.assertIn("(sharedFirstPage ? [] : record.commonFields) + cat.fields", self.exporter)
        self.assertIn('ToolMemoPage.drawHeader(kind: record.heading,', self.exporter)
        self.assertIn('name: page.catIndex.map { record.cats[$0].name } ?? record.cats.map(\\.name).joined(separator: "・")', self.exporter)
        self.assertNotIn("append(cat.name", self.exporter)


class CareHandoffRoundTwoTests(unittest.TestCase):
    """預けるとき, round 2 (11/8): every profile cat, the daily check table,
    the house notes and the memo as text. The logic is run in
    ci/verify-tool-outputs.swift; these check that the screens use it."""

    def setUp(self) -> None:
        self.plan = source("NekoWidget/Services/CareHandoffPlan.swift")
        self.store = source("NekoWidget/Services/CareHandoffStore.swift")
        self.exporter = source("NekoWidget/Services/CareHandoffExporter.swift")
        self.view = source("NekoWidget/Views/CareHandoffView.swift")
        # 11/12: the make page is part of the cat's page.
        self.making = section(self.view, "private struct CareCatEditor: View {", "private struct CareHandoffDetachedPhotos: View {")
        self.verify = source("ci/verify-tool-outputs.swift")

    def test_logic_is_run_in_ci(self) -> None:
        for name in ("careMemoOffersEveryProfile", "careMemoHouseNotes", "careMemoCheckTable", "careMemoPlainText"):
            self.assertIn("try %s()" % name, self.verify)
            self.assertIn("static func %s() throws" % name, self.verify)

    def test_every_profile_cat_can_be_chosen(self) -> None:
        # Profiles without a memo are offered, except a cat whose farewell day is recorded.
        offered = section(self.making, "private var profilesWithoutMemo:", "private func choose(")
        self.assertIn("store.plan.profileIDsWithoutMemo(profiles.map(\\.identifier))", offered)
        self.assertIn("CatFarewell.days(farewellJSON)", offered)
        # A tap makes the memo the way opening the cat does: the same addCat,
        # then the same fill from 「この子のこと」 as the editor.
        choose = section(self.making, "private func choose(", "private func record(")
        self.assertIn("store.addCat(profileID: profile.identifier, name: profile.displayName,", choose)
        self.assertIn("using: reuseStore, access: actionAccess)", choose)
        self.assertIn("disclosure.catIDs.insert(id)", choose)
        self.assertIn("await CareCatEditor.fillFromCatCare(id, store: store, reuseStore: reuseStore, profiles: profiles)", choose)
        editor = section(self.view, "private struct CareCatEditor: View {", "private struct CarePreview: Identifiable, Hashable {")
        self.assertIn("await Self.fillFromCatCare(id, store: store, reuseStore: reuseStore, profiles: profiles)", editor)
        fill = section(editor, "static func fillFromCatCare(", "private static func useKeyPhotoForCatCare(")
        self.assertIn("try? store.refreshCandidates(id, using: reuseStore)", fill)
        self.assertIn("await useKeyPhotoForCatCare(id, store: store, profiles: profiles)", fill)
        # The tool opens a cat through the same store call.
        self.assertIn("if let id = store.addCat(profileID: profileID, name: name, using: reuseStore,", self.view)
        self.assertIn('ForEach(profilesWithoutMemo, id: \\.identifier) { profile in profileChoice(profile) }', self.making)
        cats = section(self.making, "private func profileChoice(_ profile: CatProfilePresentation) -> some View {", "private var includePage")
        self.assertIn("Button { choose(profile) }", cats)
        self.assertIn('.accessibilityIdentifier("care-add-profile-\\(profile.identifier)")', cats)
        # Not 「care-select-」: the UI test takes the first of those as already chosen.
        self.assertNotIn('"care-select-profile', self.view)
        self.assertIn("var profiles: [CatProfilePresentation] = []", self.making)

    def test_house_notes_are_optional_and_once(self) -> None:
        for field in ("houseFoodPlace", "houseCarrierPlace", "houseHidingPlace", "houseOther"):
            self.assertIn("var %s: String? = nil" % field, self.plan)
            self.assertIn("text: house(\\.%s)" % field, self.making)
        self.assertNotIn("init(from decoder", self.plan)
        # The readable backup names them in Japanese, as every saved field.
        readable = source("NekoWidget/Services/ReadablePreservationExport.swift")
        for key in ("houseFoodPlace", "houseCarrierPlace", "houseHidingPlace", "houseOther"):
            self.assertIn(f'"{key}": "', readable)
        # Page 1 of the memo, once for every cat, never per cat.
        common = section(self.plan, "func commonFields(plan: CareHandoffPlan) -> [(String, String)] {", "/// Round 2 (11/8): 「家の中のこと」 as handed over")
        self.assertIn("fields += Self.houseFields(plan: plan)", common)
        per_cat = section(self.plan, "func fields(cat: CareCat) -> [(String, String)] {", "/// Contacts from 「この子のこと」's household")
        self.assertNotIn("house", per_cat)
        for label in ('label: "フードと砂の置き場所"', 'label: "キャリーの場所"', 'label: "隠れる場所"', 'label: "ほかに"'):
            self.assertIn(label, self.making)
        # No address or keys: the note stays, under the house notes.
        house = section(self.making, 'identifier: "care-house-food"', 'ForEach(cats) { cat in')
        self.assertIn('ToolImportantInformation(text: "住所や鍵の番号は、別の方法で伝えてください。")', house)
        # 11/12: as a Section's only row the note is a quiet footnote, not a card.
        views = ROOT / "NekoWidget/Views"
        handoff = (views / "CareHandoffView.swift").read_text(encoding="utf-8")
        quiet = section(handoff, "struct ToolImportantInformation: View {", "\n}\n")
        self.assertIn("func quietRow() -> some View {", quiet)
        self.assertIn("listRowBackground(Color.clear)", quiet)
        self.assertIn('Text(text).font(.footnote).foregroundStyle(.secondary)', quiet)
        # As a section footer it is already quiet: unchanged.
        self.assertIn('} footer: { ToolImportantInformation(text: "住所や鍵の番号は、別の方法で伝えてください。") }\n', handoff)
        for name, text in (("EvacuationPreparationView.swift", "災害のときは、まず自分と家族の安全を守ってください。"),
                           ("EvacuationPreparationView.swift", "まず自分と家族の安全を守ってください。"),
                           ("EvacuationPreparationView.swift", "病歴・連絡先・ワクチンの証明・マイクロチップ番号は、必要な相手にだけ見せてください。"),
                           ("CatPreparednessView.swift", "チラシを貼るときは、その場所の管理者に確かめてください。"),
                           ("VeterinaryVisitView.swift", "飼い主の記録をまとめたもので、医療の判断ではありません。様子がおかしいときは、迷わず動物病院に連絡してください。")):
            swift = (views / name).read_text(encoding="utf-8")
            call = 'ToolImportantInformation(text: "' + text + '")\n'
            self.assertIn(call, swift, name)
            self.assertTrue(swift[swift.index(call) + len(call):].lstrip(" ").startswith(".quietRow()"), (name, text))
        for word in ("住所", "鍵", "暗証"):
            self.assertNotIn(word, house.replace("住所や鍵の番号は、別の方法で伝えてください。", ""))

    def test_check_table_is_the_last_pdf_page_only(self) -> None:
        share = section(self.store, "func shareRecord(", "private static func normalizedJPEG(")
        self.assertIn("record.checkTable = CareCheckTable(period: plan.requestText(\\.period, \\.period, chosen: disclosure.catIDs),", share)
        self.assertIn("let medicine = disclosure.health && plan.cats.contains { cat in", share)
        self.assertIn("disclosure.catIDs.contains(cat.id) && CareCheckTable.hasMedicine(", share)
        # PDF only; the image has no table.
        self.assertIn("let table = pdf ? record.checkTable", self.exporter)
        pdf = section(self.exporter, "if pdf {", "} else {")
        self.assertIn("drawTable(context.cgContext, pieces: pieces, table: table, index: pages.count + offset)", pdf)
        self.assertLess(pdf.index("draw(context.cgContext, index: index)"), pdf.index("drawTable("))
        images = section(self.exporter, "let format = UIGraphicsImageRendererFormat(); format.scale = 2", "return Export(")
        self.assertNotIn("drawTable", images)
        # Page numbers count the table pages; the page limit still holds.
        self.assertIn("guard pages.count + tablePages.count <= 80 else { throw CareHandoffError.tooLarge }", self.exporter)
        self.assertIn("\\(index + 1) / \\(pageCount)", self.exporter)
        # 「様子」 is the wide column to write in; the others get a box.
        self.assertIn('$0 == "様子" ? 2.5 : 1.0', self.exporter)
        self.assertIn('where column != "様子"', self.exporter)
        # Western dates even on a 和暦 iPhone.
        self.assertIn("Calendar(identifier: .gregorian)", self.plan)
        self.assertIn("static let blankRows = 7", self.plan)
        # The vet sheet uses its own exporter, without a table.
        self.assertNotIn("checkTable", source("NekoWidget/Views/VeterinaryVisitView.swift"))

    def test_memo_is_also_sent_as_text(self) -> None:
        display = section(self.view, "private struct CareDisplayView: View {", "private struct CareActivitySheet")
        self.assertIn("CareActivitySheet(items: $0.files, text: record.plainText)", display)
        sheet = section(self.view, "private struct CareActivitySheet", "/// The tool's one safety sentence")
        self.assertIn("(items as [Any]) + (text.isEmpty ? [] : [text])", sheet)
        # The text is built from the same rows as the PDF and the image.
        record = section(self.exporter, "struct CareHandoffShareRecord {", "@MainActor")
        self.assertIn("CareHandoffDisclosure.plainText(heading: heading, common: commonFields,", record)
        self.assertIn("cats: cats.map { (name: $0.name, fields: $0.fields) }", record)
        self.assertIn("CareHandoffDisclosure.closingNotes(health: includesHealth, contacts: includesContacts)", record)
        self.assertIn("CareHandoffDisclosure.closingNotes(health: record.includesHealth, contacts: record.includesContacts)",
                      self.exporter)
        text = section(self.plan, "static func plainText(", "/// The first rows of a cat")
        self.assertIn("written(fields)", text)


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
        # 11/8: one switch, under the grid; not a second one over the photo.
        self.assertIn('"showcase-band-toggle"', view)
        self.assertNotIn('"showcase-caption-toggle"', view)
        self.assertEqual(view.count("showsCaption.toggle()"), 0)
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
                     "try await store.applyRecommendations(identifiers, boxes: boxes, to: targetScope,"):
            self.assertIn(call, view)
        self.assertIn("identifiers, boxes: boxes, to: scopeID,\n                    candidateCount: candidates.count", tab)
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
        self.assertLess(empty.index('ProgressView("選んでいます…")'), empty.index("ShowcaseNothingChosen {"))
        self.assertIn('Text("まだ写真を選んでいません")', section(view, "private struct ShowcaseNothingChosen: View {", "\n}\n"))
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
        cats = view[view.index("struct ShowcaseToolCatPicker: View {"):]
        self.assertIn('Section("前の写真")', cats)
        # 11/8: no order number after the name.
        self.assertIn('Button("前に選んだ写真") { select(scope); dismiss() }', cats)
        self.assertNotIn("storeOrder", cats)
        self.assertIn('Button("削除", role: .destructive) { removing = scope }', cats)
        self.assertIn('Button("削除", role: .destructive) { remove?(scope); removing = nil }', cats)
        self.assertIn("try store.removeScope(removed)", main)
        self.assertNotIn("まだ登録していない猫", view)
        # The arrow shows only when there is something to switch to.
        self.assertIn("if detailIndex == nil && initialScopeID != nil && canSwitchScope {", main)
        # The enlarged photo pages, zooms and closes with a downward drag.
        detail = section(view, "private struct ShowcaseDetailPhoto: View {", "struct ShowcasePreparationView: View {")
        for part in ("MagnifyGesture()", ".onTapGesture(count: 2)", "moved.height > 110", "page(1)", "page(-1)"):
            self.assertIn(part, detail)
        # Names match the tool, the Control Center and Siri.
        home = source("NekoWidget/Views/CatHomeView.swift")
        self.assertIn('case .showcase: "写真を見せる"', home)
        control = source("NekoWidgetWidget/ShowcaseControl.swift")
        shortcut = source("NekoWidget/App/ShowcaseAppShortcuts.swift")
        self.assertIn('.displayName("写真を見せる")', control)
        self.assertIn('shortTitle: "写真を見せる"', shortcut)
        for text in (control, shortcut, source("NekoWidgetWidget/OpenShowcaseIntent.swift")):
            self.assertNotIn("うちのこを見せる", text)

    def test_showcase_tool_review_round_two(self) -> None:
        """Round 2 of 「写真を見せる」: drag order, slideshow, iOS 17 widget."""
        store = source("NekoWidget/Services/ShowcasePhotoStore.swift")
        view = source("NekoWidget/Views/ShowcasePhotoView.swift")
        # 1. Drag to reorder in 「編集」; the order is the store's own order.
        move = section(store, "func move(_ entry: Entry, to target: Entry) throws {", "/// 「先頭にする」")
        self.assertIn("moved.isPinned = true", move)
        self.assertIn("scope.insert(moved, at: destination)", move)
        self.assertIn("where next.entries[index].scopeID == entry.scopeID", move)
        self.assertIn("try commit(next, undoable: true)", move)
        self.assertIn("func moveToFront(_ entry: Entry) throws {", store)
        self.assertIn('Button("先頭にする") { change { try store.moveToFront(entry) } }', view)
        preparation = section(view, "struct ShowcasePreparationView: View {", "private struct ShowcaseReorderDrop: DropDelegate {")
        cell = section(preparation, "private func photoCell(", "private func thumbnail(")
        self.assertIn(".onDrag {", cell)
        self.assertIn('NSItemProvider(object: "" as NSString)', cell)
        self.assertIn(".onDrop(of: [.text], delegate: ShowcaseReorderDrop(", cell)
        self.assertIn("try store.move(moved, to: entry)", cell)
        self.assertIn('accessibilityAction(named: Text("前へ"))', cell)
        self.assertIn('accessibilityAction(named: Text("後ろへ"))', cell)
        drop = section(view, "private struct ShowcaseReorderDrop: DropDelegate {", "private struct ShowcaseCandidatePicker: View {")
        self.assertIn("func validateDrop(info: DropInfo) -> Bool { dragging != nil }", drop)
        self.assertIn("move(dragging)", drop)
        # Pinned photos keep their places when 「おすすめで選び直す」 runs.
        apply = section(store, "func applyRecommendations(", "func add(photoIdentifier:")
        self.assertIn("let ordered = Self.keepingPinnedPlaces(current, fills: fills)", apply)
        self.assertNotIn("var ordered = pinned", apply)
        self.assertIn("guard startRevision == revision else { throw Error.changedDuringPreparation }", apply)
        places = section(store, "static func keepingPinnedPlaces(", "func move(_ entry: Entry, to target: Entry)")
        self.assertIn("for (place, entry) in current.enumerated() where entry.pinned { kept[place] = entry }", places)
        self.assertIn("if let entry = kept[place] {", places)
        # The saved file keeps its shape: no new field for the order.
        entry = section(store, "struct Entry: Codable, Equatable, Identifiable {", "private struct ScopeState")
        self.assertNotIn("order", entry.lower())

        # 2. Slideshow: a quiet button, a full screen with no controls.
        main = section(view, "struct ShowcasePhotoView: View {", "enum BestNineComposer {")
        self.assertIn('Label("スライドショー", systemImage: "play")', main)
        self.assertIn("if slides.count > 1 {", main)
        self.assertIn(".fullScreenCover(isPresented: $showsSlideshow) {", main)
        slides = section(view, "struct ShowcaseSlideshowView: View {", "private struct ShowcaseDetailPhoto: View {")
        self.assertIn("static let seconds: UInt64 = 3", slides)
        self.assertIn('static let idleOwner = "showcase-slideshow"', slides)
        self.assertIn("index = next", slides)
        self.assertIn("let next = (index + 1) % items.count", slides)
        self.assertIn(".onTapGesture { paused.toggle() }", slides)
        self.assertIn("value.translation.height > 110 { leave() }", slides)
        self.assertIn('Button("閉じる") { leave() }', slides)
        self.assertIn(".transition(reduceMotion ? .identity : .opacity)", slides)
        self.assertIn(".animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: index)", slides)
        # The screen stays on only while it shows, and is always let go.
        self.assertIn("AppIdleTimer.setPreventSleep(on, for: Self.idleOwner)", slides)
        self.assertIn(".onAppear { keepAwake(scenePhase == .active) }", slides)
        self.assertIn(".onChange(of: scenePhase) { _, phase in keepAwake(phase == .active) }", slides)
        self.assertIn(".onDisappear { keepAwake(false) }", slides)
        leave = section(slides, "private func leave() {", "private static func preload(")
        self.assertLess(leave.index("keepAwake(false)"), leave.index("close()"))
        for gone in ("Slider(", "ProgressView(", "chevron.left", "chevron.right"):
            self.assertNotIn(gone, slides)

        # 3. iOS 17 widget: icon + 「見せる」, no photo, same launch request.
        widget = source("NekoWidgetWidget/ShowcaseWidget.swift")
        bundle = source("NekoWidgetWidget/NekoWidgetBundle.swift")
        intent = source("NekoWidgetWidget/OpenShowcaseIntent.swift")
        root = source("NekoWidget/App/AppRootView.swift")
        project = source("NekoWidget.xcodeproj/project.pbxproj")
        self.assertIn(".supportedFamilies([.accessoryCircular, .systemSmall])", widget)
        self.assertIn('.configurationDisplayName("写真を見せる")', widget)
        self.assertIn('Text("見せる")', widget)
        self.assertIn(".widgetURL(ShowcaseWidgetRoute.url)", widget)
        for gone in ("WidgetCacheImageLoader", "WidgetManifestReader", "UIImage", "PHAsset", "AppGroup",
                     "UserDefaults", "displayName"):
            self.assertNotIn(gone, widget)
        bundle_body = section(bundle, "var body: some Widget {", "if #available(iOS 18.0, *) {")
        self.assertIn("ShowcaseWidget()", bundle_body)
        self.assertIn('static let url = URL(string: "nekowidget://showcase")!', intent)
        route = section(intent, "enum ShowcaseWidgetRoute {", "enum ShowcaseOpenTarget")
        for part in ("components.queryItems == nil", "components.path.isEmpty", "components.fragment == nil"):
            self.assertIn(part, route)
        handler = section(root, "private func handleNonPhotoURL(", "private func widgetPhotoDestination(")
        widget_branch = section(handler, "if ShowcaseWidgetRoute.matches(url) {", "Task { @MainActor in")
        self.assertIn("ShowcaseLaunchRequest.request()", widget_branch)
        self.assertLess(widget_branch.index("ShowcaseLaunchRequest.request()"), widget_branch.index("return"))
        # Registered for the widget extension only.
        self.assertEqual(project.count("E02611090000000000000001 /* ShowcaseWidget.swift in Sources */"), 2)
        self.assertEqual(project.count("E02611090000000000000002 /* ShowcaseWidget.swift */"), 3)
        widget_sources = section(project, "E0260923000000000000000B /* OpenShowcaseIntent.swift in Sources */,",
                                 "runOnlyForDeploymentPostprocessing")
        self.assertIn("E02611090000000000000001 /* ShowcaseWidget.swift in Sources */,", widget_sources)

    def test_vet_memo_is_an_everyday_tool(self) -> None:
        # 11/12 (案D): no ふだん/もしも groups any more; one row of buttons in
        # this order: the everyday tools (病院, 預ける) first, then 迷子, 避難, 見せる.
        tab = source("NekoWidget/Views/MainTabView.swift")
        home = source("NekoWidget/Views/CatHomeView.swift")
        self.assertIn("case vet, care, lost, evacuation, showcase", home)
        identifiers = section(home, "    var identifier: String {", "/// 避難に備える and 写真を見せる")
        order = ['"tools-vet-open"', '"tools-care-open"', '"tools-lost-cat-open"', '"tools-evacuation-open"', '"tools-showcase-open"']
        self.assertEqual([identifiers.index(name) for name in order], sorted(identifiers.index(name) for name in order))
        self.assertNotIn("toolSection(", tab)
        self.assertNotIn("ToolTint", tab)
        self.assertNotIn("emergencyWarm", tab)


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


class CatCareListRowWordingTests(unittest.TestCase):
    """11/11: 「ごはん 3回」/「0回」 read as how many times the cat was fed."""

    def test_meals_row_shows_times_and_empty_rows_say_unwritten(self) -> None:
        view = source("NekoWidget/Views/CatCareView.swift")
        self.assertIn('listRow(title: "ごはん", systemImage: "fork.knife",\n'
                      '                    detail: CatCareFormat.meals(currentRecord?.activeMeals ?? []), kind: .meal)', view)
        self.assertNotIn('activeMeals.count ?? 0)回"', view)
        self.assertNotIn('activeMedications.count ?? 0)件"', view)
        self.assertIn('return count == 0 ? ToolEmptyValue.unwritten : "\\(count)件"', view)
        row = section(view, "private func listRow(", "// MARK: Summaries")
        # 11/12: the same row as the rest of the page, one line.
        self.assertIn('ToolValueRow(title: title, systemImage: systemImage, value: detail, filled: detail != ToolEmptyValue.unwritten)', row)
        self.assertIn(".lineLimit(1)", section(source("NekoWidget/Views/ToolRowParts.swift"),
                                              "struct ToolValueRow: View {", "struct ToolPushedPage"))
        self.assertIn(".accessibilityValue(detail)", row)
        rule = section(source("NekoWidget/Services/CatCareOutputLines.swift"), "static func meals(", "// MARK: - What tools show")
        self.assertIn('guard !labels.isEmpty else { return "未記入" }', rule)
        self.assertIn('labels.prefix(3).joined(separator: "・")', rule)
        self.assertIn('" ほか"', rule)
        verify = source("ci/verify-tool-outputs.swift")
        self.assertIn("try mealsRow()", verify)
        self.assertIn('CatCareFormat.meals([]) == "未記入"', verify)
        self.assertIn('== "朝7時・夜7時"', verify)


class CatCareRowListPage1112Tests(unittest.TestCase):
    """11/12: 「この子のこと」 as 設定 and 病院で見せる: the four parts always open,
    each a list of rows that show what is written; choices are menus in the
    row, written items open a page with their one field, lists stay lists."""

    def setUp(self) -> None:
        self.view = source("NekoWidget/Views/CatCareView.swift")
        self.detail = section(self.view, "struct CatCareDetailView: View {", "/// A written item of 「この子のこと」")

    def test_four_parts_always_open_with_counts_and_delete_last(self) -> None:
        page = section(self.detail, "@ViewBuilder private var formContent: some View {",
                       "@ViewBuilder private var statusSections")
        order = ["profileHeading(profile)", "progressSection", "identifyingPhotosSection", "basicsSection",
                 "healthSection", "livingSection", "householdSection"]
        indexes = [page.index(name) for name in order]
        # 11/12 (round 2): deleting the cat is in 「…」 at the top right, not a last row.
        self.assertNotIn("deleteSection", self.detail)
        more = section(self.detail, "private var moreMenu: some View {", "private var deleteTitle: String")
        self.assertIn('ToolMoreMenu(destructiveTitle: "この子を削除", itemIdentifier: "cat-profile-delete",', more)
        self.assertIn('menuIdentifier: "cat-care-more-menu")', more)
        self.assertIn("ToolbarItem(placement: .topBarTrailing) { moreMenu }", self.detail)
        self.assertIn(".alert(deleteTitle, isPresented: $showsDeleteConfirmation) { deleteActions } message: {", self.detail)
        self.assertEqual(indexes, sorted(indexes))
        for gone in ("folded(", "openParts", "isOpen"):
            self.assertNotIn(gone, self.detail)
        for title, key in (("基本", "basics"), ("健康", "health"), ("暮らし", "living"), ("家の情報", "household")):
            self.assertIn(f'partHeader("{title}", progress.{key}, key: "{key}")', self.detail)
        header = section(self.detail, "private func partHeader(", "private static func rowLabel(")
        # 11/12 (round 2): the count, or one green check once full.
        self.assertIn('Text(verbatim: "\\(count.0) / \\(count.1)").foregroundStyle(Color.secondary)', header)
        self.assertIn('Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)', header)
        self.assertNotIn("そろっています", header)
        self.assertIn('.accessibilityIdentifier("cat-care-part-\\(key)")', header)
        household = section(self.detail, "private var householdSection: some View {", "private var vetPicker: some View {")
        self.assertIn('Text("ほかの猫とも共通です。")', household)
        # The ring and its one line are as before.
        self.assertIn('.accessibilityIdentifier("cat-care-next-hint")', self.detail)

    def test_written_items_open_their_own_page(self) -> None:
        row = section(self.detail, "private func textRow(", "private func textPage(")
        self.assertIn("NavigationLink { textPage(item) } label: {", row)
        self.assertIn('value: words ?? ToolEmptyValue.unwritten,', row)
        self.assertIn('.accessibilityIdentifier(item.identifier + "-row")', row)
        page = section(self.detail, "private func textPage(", "private func sheetRow(")
        self.assertIn("ToolPushedPage(title: item.title, focusesField: true, leave: { autosave?.cancel(); save() })", page)
        self.assertIn("CatCareTextField(item: item, text: $draft[dynamicMember: item.path], focus: focus)", page)
        self.assertIn('Label("15桁の数字にすると保存されます。", systemImage: "exclamationmark.circle")', page)
        field = section(self.view, "private struct CatCareTextField: View {", "// MARK: - Progress")
        for needed in ("TextField(item.example, text: $text,", ".keyboardType(item.keyboard)", ".focused(focus)",
                       ".accessibilityIdentifier(item.identifier)", ".accessibilityLabel(item.title)"):
            self.assertIn(needed, field)
        items = section(self.view, "private struct CatCareTextItem {", "private struct CatCareTextField: View {")
        for example in ("例：キジトラ", "例：しっぽが短い、右耳に切れ込み", "15桁の数字", "例：腎臓の療法食中", "例：鶏肉",
                        "例：療法食、ほかの猫と分けてあげる", "例：1日2回とりかえる", "例：システムトイレ・1日2回そうじ",
                        "例：抱っこが苦手", "例：090-1234-5678", "例：家族の名前と電話番号", "例：みどり動物病院",
                        "例：03-1234-5678"):
            self.assertIn(f'example: "{example}"', items)
        for identifier in ('"cat-care-microchip", keyboard: .numberPad', '"cat-care-conditions-text"',
                           '"cat-care-vet-phone", note: .vetPhone, keyboard: .phonePad'):
            self.assertIn(identifier, items)
        for note in (".coat", ".marks", ".allergyText", ".specialDiet", ".water", ".litter", ".temperament"):
            self.assertIn(f"note: {note}", items)
        for item in ("coat", "marks", "specialDiet", "water", "litter", "temperament", "ownerContact", "backupContact"):
            self.assertIn(f"textRow(.{item})", self.detail)
        # Shown only when the choice says so, as before.
        for condition, item in (("draft.microchipStatus == .recorded", "microchip"),
                                ("draft.conditionsStatus == .recorded", "conditions"),
                                ("draft.allergyStatus == .recorded", "allergyText"),
                                ("draft.vetStatus == .recorded", "vetName")):
            self.assertIn(f"if {condition} {{\n                textRow(.{item})", self.detail)

    def test_choices_are_menus_in_the_row_and_lists_stay_lists(self) -> None:
        for name, field, identifier in (("sexPicker", ".sex", "cat-care-sex"),
                                        ("neuteredPicker", ".neutered", "cat-care-neutered"),
                                        ("indoorPicker", ".indoorOnly", "cat-care-indoor"),
                                        ("microchipPicker", ".microchip", "cat-care-microchip-status"),
                                        ("conditionsPicker", ".conditions", "cat-care-conditions-status"),
                                        ("allergyPicker", ".allergyStatus", "cat-care-allergy-status"),
                                        ("vetPicker", ".vetName", "cat-care-vet-status")):
            picker = section(self.detail, f"private var {name}: some View {{", ".accessibilityIdentifier(")
            self.assertIn(".pickerStyle(.menu)", picker)
            self.assertIn(f".familyNotebookNote(catID, {field})", picker)
            self.assertIn(f'.accessibilityIdentifier("{identifier}")', self.detail)
            self.assertNotIn("NavigationLink", picker)
        lists = section(self.detail, "private func listRow(", "// MARK: Summaries")
        self.assertIn("CatCareListView(kind: kind, catID: catID, editing: $editing)", lists)
        self.assertIn('.accessibilityIdentifier("cat-care-list-\\(kind.rawValue)")', lists)
        for title in ("体重", "飲んでいる薬", "ワクチン", "ごはん"):
            self.assertIn(f'listRow(title: "{title}"', self.detail)
        self.assertIn('.accessibilityIdentifier("cat-care-vaccination-none")', self.detail)
        for identifier in ("cat-care-life-dates", "cat-care-farewell", "cat-care-farewell-family"):
            self.assertIn(f'identifier: "{identifier}")', self.detail)

    def test_square_identifying_photos_and_summary_line(self) -> None:
        photos = section(self.detail, "private var identifyingPhotosSection: some View {", "private func crop(")
        self.assertIn(".filledSquare()", photos)
        self.assertNotIn("ToolPhotoGrid", photos)
        slot = section(self.view, "struct ToolPhotoSlot<Actions: View>: View {", "struct ToolPhotoGrid<Content: View>: View {")
        self.assertIn("var fillsSquare = false", slot)
        self.assertIn(".aspectRatio(fillsSquare ? 1 : 4.0 / 3.0, contentMode: .fit)", slot)
        self.assertIn("if fillsSquare, let shown { Image(uiImage: shown).resizable().scaledToFill() }", slot)
        # 11/12 (round 2): every slot showing 「この子のこと」's photos fills its
        # square: this page, and the tools that show or choose them.
        self.assertEqual(self.view.count(".filledSquare()"), 4)
        tools = section(self.view, "struct ToolIdentifyingPhotos: View {", "extension ToolMakeBar where Top == EmptyView {")
        self.assertEqual(tools.count(".filledSquare()"), 3)
        summary = section(self.detail, "private var summaryLine: String? {", "// MARK: Rows")
        self.assertIn('case .male: parts.append("オス")', summary)
        self.assertIn('case .female: parts.append("メス")', summary)
        self.assertIn('parts.append(farewell == nil ? age : age + "まで")', summary)
        self.assertIn('return parts.isEmpty ? nil : parts.joined(separator: "・")', summary)
        heading = section(self.detail, "private func profileHeading(", "private func nameButton(")
        self.assertIn("if let summaryLine {", heading)
        self.assertIn('.accessibilityIdentifier("cat-care-summary")', heading)
        self.assertIn("nameButton(profile)", heading)
        self.assertIn('.accessibilityIdentifier("cat-care-key-photo")', heading)


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
        content = section(care, "@ViewBuilder private var formContent: some View {", "private func headerSection(")
        self.assertLess(content.index("aboutSection(cat)"), content.index("catCareSection(cat)"))
        self.assertIn('CareField(label: "まず伝えたいこと"', care)
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


class ToolShapeTrialTests(unittest.TestCase):
    def test_vet_care_and_lost_are_row_lists_and_evacuation_keeps_its_shape(self) -> None:
        """11/12 (build 360): 病院で見せる first tried the list of rows from 設定
        and the cat menu in the bar; 預けるとき and 迷子のとき were then made
        the same way. 避難に備える keeps the 11/8 shape: the row of cats on top,
        numbered steps, the folded この子のこと."""
        shared = source("NekoWidget/Views/CatCareView.swift")
        shape = section(shared, "// MARK: - One shape for every tool's input page (11/8)", "enum ToolStepState")
        self.assertIn("病院で見せる is the trial of another shape, a list of rows as in 設定", shape)
        self.assertIn("(ToolRowParts.swift). 預けるとき and", shape)
        self.assertIn("迷子のとき were then made the same way; 避難に備える keeps the shape above.", shape)
        vet = source("NekoWidget/Views/VeterinaryVisitView.swift")
        care = source("NekoWidget/Views/CareHandoffView.swift")
        lost = source("NekoWidget/Views/CatPreparednessView.swift")
        # The lost-cat page itself; a DEBUG fixture further down has its own frame.
        rows = {"vet": vet, "care": care,
                "lost": section(lost, "struct LostCatDraftView: View {", "private struct LostCatPhotoChoiceView")}
        for tool, text in rows.items():
            for name in ("ToolStepHeader(", "ToolStepState", "ToolCatStrip(", "safeAreaInset(edge: .top"):
                self.assertNotIn(name, text, (tool, name))
            for name in ("ToolValueRow(title:", "ToolPushedPage(title: title,", "ToolCatMenu(cats: stripCats,",
                         "ToolPurpose(text: "):
                self.assertIn(name, text, (tool, name))
            self.assertNotIn("foldedHeader:", text, tool)
        for name in ('"vet-cat-menu"', '"vet-more-menu"', 'Text("診察の前に")', 'Text("診察のあと")', 'Text("診察メモ")',
                     "ToolMoreMenu(destructiveTitle:"):
            self.assertIn(name, vet, name)
        for name in ('"care-cat-menu"', '"care-more-menu"', 'Text("この子について")', 'Text("今回のお願い")',
                     "ToolMoreMenu(destructiveTitle:"):
            self.assertIn(name, care, name)
        for name in ('"lost-cat-menu"', 'Text("チラシに載せること")'):
            self.assertIn(name, lost, name)
        # 11/12: the row-list parts live in one shared file for every tool,
        # not inside a tool's page.
        for name in ("VeterinaryRow", "VeterinaryPushedPage", "この子の記録"):
            self.assertNotIn(name, vet, name)
        evacuation = source("NekoWidget/Views/EvacuationPreparationView.swift")
        # 11/12 (round 2): its main page has the same rows; its cat's page
        # keeps the row of faces and the numbered parts.
        self.assertIn("ToolStepHeader(number: 1, title: ", evacuation)
        self.assertIn("ToolCatStrip(cats: stripCats", evacuation)
        self.assertIn("ToolPurpose(text: ", evacuation)
        self.assertNotIn("foldedHeader:", evacuation)
        hub = section(evacuation, "struct EvacuationPreparationView: View {", "private func makeBook() async {")
        self.assertEqual(hub.count("ToolValueRow(title:"), 3)
        self.assertNotIn("ToolStepHeader", hub)


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
        # 11/11: the output screens use the input pages' bottom bar, in the
        # page's colour. 11/12: the three memos sit on the grouped ground.
        for text in (care, evacuation, vet):
            self.assertRegex(text, r"\.safeAreaInset\(edge: \.bottom\) \{\s*ToolMakeBar \{\s*ViewThatFits \{")
        for text in (care, evacuation, vet):
            self.assertNotIn(".padding().background(.regularMaterial)", text)
        self.assertIn('"evacuation-share-pdf"', evacuation)
        self.assertIn('"vet-export-pdf"', vet)
        # The button says where it goes: the next step's name (11/8 型).
        # 11/12: one page; the memo is made from it, no 「次へ」 step between.
        self.assertNotIn("次へ：期間とお願い", care)
        self.assertNotIn('.navigationTitle("メモを作る")', care)
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
        crop = section(lost, "struct LostCatPhotoCropView: View {", "private func clamped(")
        for name in ("上へ動かす", "下へ動かす", "左へ動かす", "右へ動かす"):
            self.assertIn(name, crop)
        self.assertIn('nudgeButton("左へ"', crop)
        # Large text stacks the two photo tiles.
        self.assertIn("AnyLayout(VStackLayout(spacing: 12))", lost)
        self.assertNotIn("frame(minWidth: 36, minHeight: 36)", lost)
        # Photos in a grid are told apart by their day.
        for path in ("NekoWidget/Views/CatPreparednessView.swift", "NekoWidget/Views/ToolRecentPhotos.swift"):
            self.assertIn("ToolPhotoLabel.text(", source(path), path)
        for path in ("NekoWidget/Views/CatCareView.swift", "NekoWidget/Views/EvacuationPreparationView.swift"):
            self.assertIn("ToolRecentPhotoSection(", source(path), path)
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
        self.assertIn('["onboarding-widget-step-1", "onboarding-widget-step-2-legacy", "onboarding-widget-step-3"]', steps)


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
        listing_source = source("Shared/Sharing/ClientUpgradeRequirement.swift")
        self.assertIn("enum AppStoreListing {", listing_source)
        self.assertIn('https://apps.apple.com/jp/app/id', listing_source)
        self.assertIn("if let url = AppStoreListing.pageURL {", settings)
        # 1.0 is reviewed before its page exists: no row points at it (11/10).
        listing = section(listing_source, "enum AppStoreListing {", "static let recommendMessage")
        self.assertIn("static let isPagePublished = false", listing)
        self.assertIn("guard isPagePublished else { return nil }", listing)
        self.assertLess(listing.index("guard isPagePublished"), listing.index("return URL(string:"))
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
        # 11/8 (29): said once, on 「アカウントとデータを消す」 (SettingsView).
        self.assertNotIn("Plusの支払いは、ここでは止まりません。", window)
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
        listing = source("Shared/Sharing/ClientUpgradeRequirement.swift")
        self.assertIn('static let appID: String? = "6801962436"', listing)
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
        # 11/9: one-way. Sending never writes the photo's own memo on this iPhone.
        deliver = section(screen, "func deliver(", "func toggleHeart(")
        self.assertIn("client.sendPhoto(", deliver)
        self.assertNotIn("PhotoMemoryNoteStore", deliver)
        self.assertNotIn("saveMemo", screen)
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


class AutoSaveScreenLayoutTests(unittest.TestCase):
    def test_status_first_then_kept_records_account_profiles_and_stop_last(self) -> None:
        # 349: start / stop / export / account were mixed in one box; the stop
        # row sat far from the status it changes.
        saving = source("NekoWidget/Services/AppRecordPersistence.swift")
        body = section(saving, "@ViewBuilder private var settingsSections: some View {", "@ViewBuilder private var startAction: some View {")
        order = [body.index('.accessibilityIdentifier("app-record-save-status")'),
                 body.index("if !persistence.enabled { startAction } else { savingActions }"),
                 body.index('header: { Text("保存されているもの") }'),
                 body.index('NavigationLink("自動保存のアカウント")'),
                 body.index('"app-record-cat-profile-transfer"'),
                 body.index('"app-record-pause"')]
        self.assertEqual(order, sorted(order))
        stop = body[body.index("// Stopping on this iPhone"):]
        self.assertIn("if persistence.enabled, authentication.isSignedIn", stop)
        self.assertNotIn("savingSections", saving)
        # Off: the kept-records box keeps 書き出す; space and records only while saving.
        self.assertIn("if persistence.enabled, let quota = displayedQuota { ProductQuotaSummary(quota: quota) }", body)

class ToolPageReview349Tests(unittest.TestCase):
    def test_tool_pages_share_spacing_and_the_folded_box_says_what_it_uses(self) -> None:
        shared = source("NekoWidget/Views/CatCareView.swift")
        spacing = section(shared, "func toolPageSpacing() -> some View {", "extension ToolMakeBar where Top == EmptyView {")
        self.assertIn("listSectionSpacing(.compact)", spacing)
        self.assertIn(".contentMargins(.top, 4, for: .scrollContent)", spacing)
        # Round 2: 「いま避難する」 is the third evacuation page with the same spacing.
        for path, count in (("NekoWidget/Views/VeterinaryVisitView.swift", 1), ("NekoWidget/Views/CatPreparednessView.swift", 1),
                            ("NekoWidget/Views/CareHandoffView.swift", 1), ("NekoWidget/Views/EvacuationPreparationView.swift", 3)):
            self.assertEqual(source(path).count(".toolPageSpacing()"), count, path)
        folded = section(shared, "struct ToolCatCareSection<Extra: View>: View {", "private func readRows(")
        self.assertIn('ToolValueRow(title: title, systemImage: "pawprint",', folded)
        self.assertIn("header: { if !folded { Text(title) } else if let foldedHeader { Text(foldedHeader) } }", folded)
        # A heading over the folded row stays possible; no tool gives one now
        # (11/12: 病院で見せる's 「この子の記録」 became 「診察メモ」 and この子のこと).
        self.assertIn("foldedHeader: String? = nil", folded)

    def test_folded_cat_care_is_one_row_that_opens_the_cat(self) -> None:
        """349: three rows (a disclosure, what is missing, a link) read as one
        thing to tap; it is one row now, opening 「この子のこと」."""
        shared = source("NekoWidget/Views/CatCareView.swift")
        box = section(shared, "struct ToolCatCareSection<Extra: View>: View {", "private func readRows(")
        body = section(box, "var body: some View {", "private func foldedLabel(")
        fold = section(body, "if folded {", "} else {\n                readRows(")
        self.assertIn("NavigationLink { CatCareSubjectView(subject: subject, profiles: profiles) } label: {", fold)
        self.assertEqual(fold.count("NavigationLink"), 1)
        self.assertEqual(fold.count('.accessibilityIdentifier(identifier + "-folded")'), 2)
        self.assertNotIn("editIdentifier", fold)
        self.assertNotIn("DisclosureGroup", shared)
        self.assertNotIn("「この子のこと」から入ります", shared)
        self.assertNotIn("まだ書いていないこと", fold)
        # Without a cat to open, the same row without the link.
        self.assertIn("} else {\n                    foldedLabel(", fold)
        label = section(box, "private func foldedLabel(", "@ViewBuilder")
        # 11/12 (round 2): the same row as every other row of the tool.
        self.assertIn('ToolValueRow(title: title, systemImage: "pawprint",', label)
        self.assertIn('value: missing.isEmpty ? "そろっています" : "あと\\(missing.count)つ",', label)
        self.assertIn("filled: missing.isEmpty)", label)
        self.assertIn('.accessibilityHint(missing.isEmpty ? "" : "まだ：" + missing.joined(separator: "・"))', label)
        self.assertNotIn(".font(.caption)", label)
        # The open box keeps its rows and its link.
        open_box = body[body.index("} else {\n                readRows("):]
        self.assertIn('"まだ書いていないこと："', open_box)
        self.assertIn('NavigationLink("「この子のこと」を開く")', open_box)
        self.assertIn(".accessibilityIdentifier(editIdentifier)", open_box)
        for path in ("NekoWidget/Views/CareHandoffView.swift", "NekoWidget/Views/EvacuationPreparationView.swift"):
            self.assertIn("folded: true)", source(path), path)
            self.assertNotIn("foldedHeader:", source(path), path)
        # 11/12: on the vet page's row list it is a section of its own, no heading.
        self.assertIn('editIdentifier: "vet-open-cat-care", profiles: profiles,\n            folded: true)\n',
                      source("NekoWidget/Views/VeterinaryVisitView.swift"))

    def test_photos_use_one_slot_and_removal_sits_in_its_menu(self) -> None:
        shared = source("NekoWidget/Views/CatCareView.swift")
        slot = section(shared, "struct ToolPhotoSlot<Actions: View>: View {", "struct ToolPhotoGrid<Content: View>: View {")
        self.assertIn("Menu { actions } label:", slot)
        self.assertIn('Image(systemName: "ellipsis")', slot)
        care = source("NekoWidget/Views/CareHandoffView.swift")
        lost = source("NekoWidget/Views/CatPreparednessView.swift")
        evac = source("NekoWidget/Views/EvacuationPreparationView.swift")
        for text in (lost, evac):
            self.assertIn("ToolPhotoSlot(", text)
        # 11/9: 預ける, 迷子 and 避難 show 「この子のこと」's photos through the same slot.
        for text in (care, lost, evac):
            self.assertIn("ToolIdentifyingPhotos(", text)
        identifying = section(shared, "struct ToolIdentifyingPhotos: View {", "extension ToolMakeBar where Top == EmptyView {")
        self.assertIn("ToolPhotoSlot(readOnly:", identifying)
        # Taking a photo off is a menu item, not red text on the page (349). 11/9:
        # the memo shows 「この子のこと」's photo; leaving it off this memo is a
        # quiet gray choice that deletes nothing, and never red.
        self.assertIn('Button("このメモには載せない") { store.editCat(id) { $0.photoRemoved = true } }\n'
                      '                    .font(.footnote).foregroundStyle(.secondary)', care)
        self.assertNotIn("このメモの写真を外す", care)
        for line in care.splitlines():
            if "このメモには載せない" in line or "このメモにも写真を載せる" in line:
                self.assertNotIn(".destructive", line)
        self.assertIn('Button("\\(title)を外す", systemImage: "minus.circle", role: .destructive)',
                      source("NekoWidget/Views/CatCareView.swift"))
        self.assertIn('Button("\(role.title)を外す", systemImage: "minus.circle", role: .destructive)', evac)
        self.assertNotIn('Button("\(role.title)を外す", role: .destructive)', evac)


class OwnerEntryWordingTests(unittest.TestCase):
    def test_outputs_do_not_tag_every_answer_as_the_owners(self) -> None:
        # 349: 「なし（飼い主の記入）」 on every line was noise; everything in these
        # memos is the owner's own record (the vet memo says so once).
        for path in ("NekoWidget/Services/CatCareOutputLines.swift", "NekoWidget/Services/CareHandoffPlan.swift",
                     "NekoWidget/Services/EvacuationPlan.swift"):
            text = source(path)
            self.assertNotIn("（飼い主の記入）", text, path)
            self.assertNotIn("（飼い主の記録）", text, path)
        self.assertIn("飼い主の記録をまとめたもの", source("NekoWidget/Views/VeterinaryVisitView.swift"))

class PhotoScanStatusTests(unittest.TestCase):
    def test_searching_says_so_and_a_retry_only_appears_when_it_can_work(self) -> None:
        home = source("NekoWidget/Views/HomeView.swift")
        status = section(home, "private var partialScanStatus: some View {", "private var monthDestinations")
        self.assertLess(status.index("if scan.isScanning {"), status.index('"もう一度探す"'))
        self.assertNotIn("まだ読み込めない写真があります", status)
        self.assertNotIn(".disabled(scan.isScanning)", status)
        self.assertIn('"読み込めなかった写真が\\(scan.deferredAssets.formatted())枚あります"', status)
        self.assertIn(".padding(.horizontal, isEmbedded ? 16 : 0)", status)

    def test_monthly_nine_share_image_has_no_title_band(self) -> None:
        # 349: 「あめとむぎ　10月の9枚」 on the shared image was in the way; the
        # name stays in the share sheet's preview title only.
        album = source("NekoWidget/Views/AlbumPrototypeView.swift")
        self.assertEqual(album.count("BestNineComposer.image(images, title: nil)"), 4)
        self.assertNotIn("BestNineComposer.image(images, title: request.input.title)", album)
        self.assertIn("SharePreview(input.title, image:", album)


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
        # 11/8: the version only; no build number, OS requirement or full-access note.
        self.assertIn('Text("ねこのまど バージョン \\(appVersion)")', settings)
        self.assertNotIn("iOS 17.1以上", settings)
        self.assertNotIn('"CFBundleVersion"', settings)
        self.assertNotIn("すべての写真を使えます。", settings)
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
        # 11/12: the first screen has no line for invited people (it stopped
        # everyone else); the link itself opens the join screen. No help sheet.
        self.assertNotIn("showsInvitationHint", root_view)
        self.assertNotIn("OnboardingInvitationHelpView", root_view)
        onboarding = source("NekoWidget/Views/OnboardingView.swift")
        self.assertNotIn("showsInvitationHint", onboarding)
        purpose = section(onboarding, "private struct OnboardingPurposePage: View", "struct OnboardingWindowMosaic: View")
        self.assertNotIn("届いた招待リンク", purpose)
        self.assertNotIn('"onboarding-purpose-join-hint"', purpose)
        self.assertNotIn('"onboarding-purpose-join"', purpose)
        self.assertNotIn("struct OnboardingInvitationHelpView: View", onboarding)
        tab = source("NekoWidget/Views/MainTabView.swift")
        # Widget and showcase entries to the 写真 tab start on すべて, not the last segment.
        self.assertGreaterEqual(len(re.findall(r"selectedTab = \.photos\n {16,20}photoLibrarySelection\.select\(\.all\)", tab)), 2)
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
        # 11/8: an identifier on a plain stack replaced every row's and button's
        # own identifier (iOS 26 UI test). Identified stacks that hold
        # identified controls are containers.
        for container in ('"window-list-discover-section"', '"window-list-subscription-confirmation"'):
            before = tab[:tab.index(".accessibilityIdentifier(" + container + ")")].rstrip()
            self.assertTrue(before.endswith(".accessibilityElement(children: .contain)"), container)
        self.assertIn(r'.accessibilityIdentifier("public-window-add-\(source.id)")', tab)
        # 11/13: 「受け取る」 is a small filled accent capsule (32pt seen, 44pt hit),
        # not the grey bordered blob; the row icon is a 48pt soft tile.
        add = section(tab, "private func addButton(", "private func add(")
        self.assertIn(".buttonStyle(.officialWindowReceive)", add)
        self.assertNotIn(".buttonStyle(.bordered)", add)
        official = source("NekoWidget/Views/OfficialWindowView.swift")
        receive = section(official, "struct OfficialWindowReceiveButtonStyle: ButtonStyle {", "\n}\n")
        for part in (".background(Color.accentColor, in: Capsule())", ".foregroundStyle(.white)",
                     ".frame(minHeight: 32)", ".frame(minHeight: 44)", ".contentShape(Rectangle())"):
            self.assertIn(part, receive)
        self.assertIn(".frame(width: 48, height: 48)", official)
        self.assertIn(".colorMultiply(Self.rowTileCream)", official)
        self.assertIn('.accessibilityIdentifier("window-list-widget-guide")', tab)
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
        self.assertIn('ToolMemoPage.drawHeader(kind: "診察メモ", name: name, date: made, face: face,', exporter)
        self.assertIn('confirmationDialog("診察メモを渡しますか？"', vet)
        # 11/12: the three memos share one sheet; the screen is 「できあがり」.
        self.assertIn('ToolMemoSheet(kind: "診察メモ", name: displayName ?? visit.catName, date: Date(), face: face)', vet)
        self.assertIn('.navigationTitle("できあがり")', vet)
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
        self.assertIn("receiveFamilyChanges(project: FamilyNotebookToolSharing.visitsReceived)", self.store)
        self.assertIn("Self.keepingLocalResults(try project(state.visits), from: state.visits)", self.store)
        verifier = (ROOT / "ci/verify-veterinary-visits.swift").read_text(encoding="utf-8")
        for case in ("A memo saved before the results fields became unreadable", "A finished memo was rewritten",
                     "Saving results changed what was shown", "A received result clear was overwritten or changed local dates"):
            self.assertIn(case, verifier)
        # The screen: three fields, written before or after the memo is finished.
        for text in ('title: "先生の話"', 'title: "出た薬"', 'Toggle("次に行く日を記録"', 'Text("診察のあと")',
                     'textRow("先生の話・出た薬", "stethoscope", [doctorNote, prescription])',
                     "adopt(try await store.saveResults(draft,"):
            self.assertIn(text, self.view)
        # 11/12: starting a new memo says where the current one goes and
        # what stays fixed (it was 「診察を終える」, 349).
        finishing = section(self.view, '.confirmationDialog("新しい診察メモを始めますか？", isPresented: $finishing',
                            '.confirmationDialog("この診察メモを削除しますか？"')
        self.assertIn('Button("新しいメモを始める") { Task { await save(completing: true) } }', finishing)
        self.assertIn('Button("キャンセル", role: .cancel) {}', finishing)
        self.assertIn('Text("いまのメモは「これまでの診察メモ」に入り、家で気付いたこと・写真・聞きたいことは変えられなくなります。")',
                      finishing)
        for old in ("診察を終える\"", "この診察メモを終えますか？", "あとからも書けます"):
            self.assertNotIn(old, self.view)
        # Nothing on screen after it; VoiceOver hears where the memo went.
        self.assertIn("Task { await reload(); await open(cat); announceNewMemo() }", self.view)
        self.assertIn('AccessibilityNotification.Announcement("いまのメモは、これまでの診察メモに入りました").post()', self.view)
        for old in ("診察済みにする", "診察済みにしますか？", "診察済みにすると"):
            self.assertNotIn(old, self.view)
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
        self.assertIn('Label("「\\(longRowTitle ?? "")」を短くしてください"', self.view)
        self.assertIn("保存できると、先生に見せられます", self.view)
        # 11/12: only the shown memo is 「できあがり」, as the other tools' memos.
        self.assertEqual(self.view.count("できあがり"), 1)
        self.assertIn('.navigationTitle("できあがり")', section(self.view, "private struct VeterinaryReadView: View {",
                                                              "@ViewBuilder private var exportButtons"))
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
        # 11/12: the past memos are a page of their own, opened from one row.
        past = section(self.view, "private var pastPage: some View {", "private func pastVisitRow(")
        self.assertIn('pushed("これまでの診察メモ")', past)
        self.assertIn("ForEach(pastVisits) { past in pastVisitRow(past) }", past)
        self.assertIn("DetachedToolPhotoRow(", past)
        self.assertIn(".sheet(item: $pastOpened, onDismiss: { pastClosed?() }) { past in", past)
        row = section(self.view, "private func pastVisitRow(", "\n    }\n")
        self.assertIn("Button { pastOpened = past } label:", row)
        self.assertIn("Text(pastTitle(past))", row)
        self.assertIn('"vet-past-\\(past.id.uuidString)"', row)
        self.assertIn('[past.doctorNote ?? "", past.observations', self.view)
        dates = section(self.view, "private struct VeterinaryEntryDates: View {", "\n}\n")
        self.assertIn("entry.weight?.measuredOn ?? entry.capturedAt.map(VeterinaryVisit.day) ?? entry.writtenAt.map(VeterinaryVisit.day)", dates)
        self.assertNotIn("不明", dates)

    def test_page_is_a_list_of_rows_that_open_their_pages(self) -> None:
        # 11/12 (build 360): 病院で見せる is the trial of a list of rows, as in
        # 設定: what the page makes, 「診察の前に」 and 「診察のあと」 as rows that
        # each open a page, 「診察メモ」, この子のこと, then the note last. No numbered
        # steps on this page; the other tools keep theirs.
        view = self.view
        page = section(view, "@ViewBuilder private var formContent: some View {", "private func lifecycle<")
        content = section(page, "@ViewBuilder private var formContent: some View {", "@ViewBuilder private var errorSection")
        order = [content.index("headerSections(visit)"), content.index("beforeSection(visit)"),
                 content.index("afterSection(visit)"), content.index("errorSection"),
                 content.index("memoSection(visit)"), content.index("recordSection(visit)"), content.index("noteSection")]
        self.assertEqual(order, sorted(order))
        for old in ("ToolStepHeader", "ToolStepState", "stepStates", "stepSections", "noticedStep(", "recordsStep(",
                    "questionsStep(", "resultsStep(", "closingSections", "ToolCatStrip"):
            self.assertNotIn(old, view, old)
        header = section(page, "@ViewBuilder private func headerSections(", "// MARK: Rows (11/12)")
        self.assertIn('ToolPurpose(text: "先生に見せる診察メモを作ります。")', header)
        self.assertLess(header.index("ToolPurpose("), header.index('"vet-started-day"'))
        self.assertLess(header.index('"vet-started-day"'), header.index('Text("前の診察は終わりましたか？")'))
        self.assertLess(header.index('Text("前の診察は終わりましたか？")'), header.index('finishButton("vet-finish-previous")'))
        # 「診察の前に」: four rows in this order, each a link to its own page.
        before = section(view, "private func beforeSection(", "private func recordsLabel(")
        rows = ['NavigationLink { noticedPage } label:', 'textRow("家で気付いたこと", "square.and.pencil", [observations])',
                '"vet-step-noticed"', "if visit.completedAt == nil { weightRow(visit) }",
                "NavigationLink { recordsPage } label: { recordsLabel(visit) }", '"vet-step-records"',
                "NavigationLink { questionsPage } label:", 'textRow("先生に聞きたいこと", "questionmark.circle", [questions])',
                '"vet-step-questions"', 'Text("診察の前に")']
        self.assertEqual([before.index(row) for row in rows], sorted(before.index(row) for row in rows))
        records = section(view, "private func recordsLabel(", "/// 「診察のあと」")
        self.assertIn('ToolValueRow(title: "見せる写真・記録", systemImage: "photo.on.rectangle",', records)
        self.assertIn('value: count == 0 ? ToolEmptyValue.none : "\\(count)件", filled: count > 0)', records)
        # 「診察のあと」: 先生の話・出た薬, 次に行く日; no finishing here (11/12).
        after = section(view, "private func afterSection(", "private var nextVisitLabel")
        rows = ["NavigationLink { resultsPage } label:", 'textRow("先生の話・出た薬", "stethoscope", [doctorNote, prescription])',
                '"vet-step-results"', "NavigationLink { nextVisitPage } label: { nextVisitLabel }", '"vet-row-next-visit"',
                'Text("診察のあと")']
        self.assertEqual([after.index(row) for row in rows], sorted(after.index(row) for row in rows))
        for old in ("finishing", "finishButton", "vet-finish"):
            self.assertNotIn(old, after, old)
        next_visit = section(view, "private var nextVisitLabel: ToolValueRow {", "/// その日の体重")
        self.assertIn('value: hasNextVisit ? DayText.japanese(VeterinaryVisit.day(nextVisitDay)) : ToolEmptyValue.unset', next_visit)
        # A text row: first words, 「未記入」, or in red where something is too long.
        text_row = section(view, "private func textRow(", "/// 「診察の前に」")
        self.assertIn("let long = texts.contains { $0.count > 500 }", text_row)
        self.assertIn('value: long ? "長すぎます" : (words ?? ToolEmptyValue.unwritten)', text_row)
        self.assertIn("problem: long)", text_row)
        parts = source("NekoWidget/Views/ToolRowParts.swift")
        row = section(parts, "struct ToolValueRow: View {", "\n}\n")
        self.assertIn("LabeledContent {", row)
        self.assertIn(".foregroundStyle(problem ? Color.red : (filled ? Color.primary : Color.secondary))", row)
        self.assertIn(".lineLimit(1)", row)
        self.assertIn(".truncationMode(.tail)", row)
        self.assertIn("Image(systemName: systemImage).foregroundStyle(Color.accentColor)", row)
        # 11/12: 「診察メモ」: これまでの診察メモ (when there are any), then
        # 「新しい診察メモを始める」, an action row with the conditions
        # 「診察を終える」 had, and a footer only when it is there.
        memo = section(view, "@ViewBuilder private func memoSection(", "/// 「この子のこと」 folded")
        self.assertIn("let starts = startsNewMemo(visit)", memo)
        self.assertIn("if starts || hasPast {", memo)
        self.assertLess(memo.index("pastRow"), memo.index("if starts { newMemoRow }"))
        self.assertIn('Text("診察メモ")', memo)
        self.assertIn('if starts { Text("始めると、いまのメモは「これまでの診察メモ」に入ります。") }', memo)
        new_row = section(memo, "private var newMemoRow: some View {", "private var hasPast")
        self.assertIn('Label("新しい診察メモを始める", systemImage: "plus.circle")', new_row)
        self.assertIn('.disabled(changes).accessibilityIdentifier("vet-finish")', new_row)
        self.assertIn("Button { finishing = true } label:", new_row)
        self.assertNotIn("NavigationLink", new_row)
        self.assertNotIn("ToolValueRow", new_row)
        self.assertIn("private var hasPast: Bool { !pastVisits.isEmpty || !detachedPhotos.isEmpty }", memo)
        starts = section(view, "private func startsNewMemo(", "\n    }\n")
        self.assertIn("isPage && visit.completedAt == nil && !looksFinished(visit)", starts)
        # この子のこと folded, in a section of its own.
        care = section(view, "/// 「この子のこと」 folded", "/// The note, last")
        self.assertIn('editIdentifier: "vet-open-cat-care", profiles: profiles,\n            folded: true)\n', care)
        self.assertIn("if hasPast {", care)
        self.assertIn("NavigationLink { pastPage } label:", care)
        self.assertIn('ToolValueRow(title: "これまでの診察メモ", systemImage: "clock",', care)
        self.assertIn('"vet-row-past"', care)
        # The note last, a quiet footnote on the page ground (11/12).
        note = section(view, "private var noteSection: some View {", "// MARK: Pages each row opens")
        self.assertIn('ToolImportantInformation(text: "飼い主の記録をまとめたもので、医療の判断ではありません。'
                      '様子がおかしいときは、迷わず動物病院に連絡してください。")\n                .quietRow()', note)
        self.assertNotIn("Button", note)
        # Each page holds the controls that part had, with the same bindings.
        noticed = section(view, "private var noticedPage: some View {", "private var recordsPage: some View {")
        self.assertIn('pushed("家で気付いたこと", focuses: visit?.completedAt == nil) { focus in', noticed)
        self.assertIn('title: "家で気付いたこと", example: "例：1日2回吐く・食欲が半分"', noticed)
        self.assertIn("text: $observations, lines: 3...8, identifier: \"vet-observations\"", noticed)
        self.assertIn('Toggle("いつからかを記録", isOn: $hasStartedDay)', noticed)
        self.assertIn('DatePicker("気付いた日", selection: $startedDay, displayedComponents: .date)', noticed)
        self.assertIn("pageNotes([observations])", noticed)
        self.assertNotIn('"vet-questions"', noticed)
        records = section(view, "private var recordsPage: some View {", "private func entryRow(")
        self.assertIn('pushed("見せる写真・記録")', records)
        self.assertIn("ForEach(visit.orderedEntries) { entry in entryRow(entry, visit: visit) }", records)
        self.assertIn('Button("写真を選ぶ", systemImage: "plus") { picking = true }', records)
        self.assertIn('"vet-pick-records"', records)
        self.assertNotIn("写真・メモを選ぶ", view)
        # The picker and 「外す」 are presented from the page that opens them.
        self.assertIn(".sheet(isPresented: $picking) {", records)
        self.assertIn('.confirmationDialog("診察メモから外しますか？", isPresented: removingEntryPresented', records)
        self.assertEqual(view.count(".sheet(isPresented: $picking)"), 1)
        entry = section(view, "private func entryRow(", "private var questionsPage: some View {")
        self.assertIn('Button("診察メモから外す", role: .destructive) { removingEntry = entry }', entry)
        questions = section(view, "private var questionsPage: some View {", "/// What came after the consultation")
        self.assertIn('pushed("先生に聞きたいこと", focuses: visit?.completedAt == nil) { focus in', questions)
        self.assertIn('title: "先生に聞きたいこと", example: "例：ごはんを変えたほうがいいですか"', questions)
        self.assertIn('identifier: "vet-questions"', questions)
        results = section(view, "private var resultsPage: some View {", "private var nextVisitPage: some View {")
        self.assertIn('pushed("先生の話・出た薬", focuses: true) { focus in', results)
        for name in ("vet-doctor-note", "vet-prescription"):
            self.assertIn(f'"{name}"', results)
        self.assertIn("pageNotes([doctorNote, prescription])", results)
        next_page = section(view, "private var nextVisitPage: some View {", "/// This cat's past memos")
        self.assertIn('pushed("次に行く日")', next_page)
        self.assertIn('Toggle("次に行く日を記録", isOn: $hasNextVisit).accessibilityIdentifier("vet-next-visit-toggle")', next_page)
        self.assertIn('DatePicker("次に行く日", selection: $nextVisitDay, displayedComponents: .date)', next_page)
        # A finished memo keeps only 「診察のあと」 editable, read only elsewhere.
        for part in (noticed, section(view, "private func questionsRows(", "/// What came after the consultation"),
                     section(view, "@ViewBuilder private var recordsRows: some View {", "private func entryRow(")):
            self.assertIn("if visit.completedAt == nil {", part)
            self.assertIn("nothingWritten", part)
        self.assertNotIn('Section("伝えたこと")', view)
        self.assertNotIn('Text("今回伝えること")', view)
        # The page every row opens: its title, the tool's frame, the field
        # focused once it has slid in, and what is pending saved on leaving.
        pushed = section(parts, "struct ToolPushedPage<Content: View>: View {", "\n}\n")
        self.assertIn(".navigationTitle(title).navigationBarTitleDisplayMode(.inline)", pushed)
        self.assertIn(".toolChrome()", pushed)
        self.assertIn(".toolBottomBar { EmptyView() }", pushed)
        self.assertIn("focused = true", pushed)
        self.assertIn(".onDisappear { leave() }", pushed)
        helper = section(view, "private func pushed<Content: View>(", "/// Shown in a page of a finished memo")
        self.assertIn("leave: { flushSave() }", helper)
        self.assertIn(".disabled(busy)", helper)
        flush = section(view, "private func flushSave() {", "private func scheduleSave() {")
        self.assertIn("autosaveTask?.cancel()", flush)
        self.assertIn("if changes { Task { await save() } }", flush)
        lifecycle = section(view, "private func lifecycle<", "private func dialogs<")
        self.assertIn(".onDisappear {\n            // Leaving another way than 「閉じる」 still saves what was written.\n            flushSave()\n        }", lifecycle)
        for name in ("observations", "questions", "hasStartedDay", "startedDay", "doctorNote", "prescription",
                     "hasNextVisit", "nextVisitDay"):
            self.assertIn(f".onChange(of: {name}) {{ _, _ in scheduleSave() }}", lifecycle)
        field = section(view, "private struct VeterinaryLabeledField: View {", "/// A chosen photo on the page")
        self.assertIn("var focus: FocusState<Bool>.Binding? = nil", field)
        self.assertIn(".focused(focus)", field)
        # The answer to 「前の診察は終わりましたか？」: a bordered button the row's
        # width, not prominent (「先生に見せる」 is the one prominent button),
        # with the same dialog as the row in 「診察メモ」.
        finish = section(view, "private func finishButton(_ identifier: String) -> some View {", "\n    }\n")
        self.assertIn('Button { finishing = true } label: { Text("新しい診察メモを始める").frame(maxWidth: .infinity) }', finish)
        self.assertIn(".buttonStyle(.bordered)", finish)
        self.assertIn(".disabled(changes).accessibilityIdentifier(identifier)", finish)
        self.assertNotIn("borderedProminent", finish)
        self.assertNotIn(".controlSize(", finish)
        self.assertEqual(view.count("Button { finishing = true }"), 2)
        self.assertEqual(view.count('finishButton("vet-finish'), 1)
        self.assertEqual(view.count('"vet-finish"'), 1)
        self.assertIn('finishButton("vet-finish-previous")', view)
        self.assertNotIn('Text("診察を終える")', view)
        # Delete sits in 「…」 in the bar, with the same confirmation; no red card.
        more = section(view, "private var moreMenu: some View {", "/// The one way forward")
        self.assertIn('ToolMoreMenu(destructiveTitle: "この診察メモを削除", itemIdentifier: "vet-delete",\n'
                      '                     menuIdentifier: "vet-more-menu") { deletesVisit = true }', more)
        # The 「…」 menu keeps the delete item only (the owner wants the new
        # memo's row on the page, where it shows where the memo goes).
        self.assertNotIn("vet-finish", more)
        self.assertIn(".disabled(visit == nil)", more)
        shared_more = section(parts, "struct ToolMoreMenu<Extra: View>: View {", "\n}\n")
        self.assertIn("Button(destructiveTitle, role: .destructive) { action() }\n                .accessibilityIdentifier(itemIdentifier)", shared_more)
        self.assertIn('Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)', shared_more)
        self.assertIn('.accessibilityLabel("その他")', shared_more)
        self.assertIn(".accessibilityIdentifier(menuIdentifier)", shared_more)
        bar = section(view, "    private var page: some View {", "/// 11/12: delete is not part of writing the memo")
        self.assertIn("ToolbarItem(placement: .topBarTrailing) { moreMenu }", bar)
        self.assertIn('ToolbarItem(placement: .cancellationAction) { Button("閉じる") { close() }.disabled(busy) }', bar)
        self.assertEqual(view.count('"この診察メモを削除"'), 1)
        self.assertIn('.confirmationDialog("この診察メモを削除しますか？", isPresented: $deletesVisit', view)
        # The cat: a small menu in the bar in place of the row of faces,
        # switching in place as the row did; none with one cat.
        visits = section(view, "struct VeterinaryVisitsView: View {", "private struct VeterinaryConsultationView: View {")
        self.assertNotIn("safeAreaInset(edge: .top", visits)
        self.assertIn("ToolbarItem(placement: .topBarTrailing) { catMenu }", visits)
        menu = section(visits, "@ViewBuilder private var catMenu: some View {", "private var menuName: String {")
        # 11/12: opened from a cat's page on この子, the cat is chosen there.
        self.assertIn("if ready, fixedStripCat == nil {", menu)
        self.assertIn('ToolCatMenu(cats: stripCats, selectedID: current?.catID.uuidString, title: menuName,\n'
                      '                        identifier: "vet-cat-menu") { cat in\n                Task { await open(cat) }', menu)
        shared_menu = section(parts, "struct ToolCatMenu: View {", "\n}\n")
        self.assertIn("if cats.count > 1 {", shared_menu)
        self.assertIn("ForEach(cats) { cat in item(cat) }", shared_menu)
        self.assertIn('Image(systemName: "chevron.down")', shared_menu)
        self.assertIn(".accessibilityIdentifier(identifier)", shared_menu)
        self.assertIn("cats.filter { $0.id == selectedID || !$0.isDeparted(farewellJSON) }", shared_menu)
        self.assertIn("Button { select(cat) } label:", shared_menu)
        self.assertIn(".accessibilityIdentifier(cat.accessibilityIdentifier)", shared_menu)
        for name in ("menuCats", "catMenuItem", "Menu {"):
            self.assertNotIn(name, visits, name)
        # The bar: save status on top, then the one button.
        bar = section(view, "private var bottomBar: some View {", "@ViewBuilder private var formContent")
        self.assertIn("ToolMakeBar(top: { saveStatus }) {", bar)
        self.assertIn('Label("先生に見せる", systemImage: "stethoscope")', bar)
        self.assertIn('.accessibilityIdentifier("vet-show").disabled(changes || busy)', bar)
        self.assertIn('Button("もう一度保存する") { Task { await save() } }.accessibilityIdentifier("vet-save")', bar)
        # 11/12: 「保存中…」 only while saving; once saved, nothing stays (the
        # enabled 「先生に見せる」 says so). Both red failures stay as they were.
        status = section(view, "@ViewBuilder private var saveStatus: some View {", "@ViewBuilder private var formContent")
        self.assertNotIn("保存しました", view)
        self.assertIn("} else if changes {", status)
        self.assertIn('Text("保存中…")', status)
        self.assertNotIn("} else {", status)
        self.assertIn('Label("「\\(longRowTitle ?? "")」を短くしてください", systemImage: "exclamationmark.triangle.fill")', status)
        self.assertIn('Label("保存できませんでした。保存できると、先生に見せられます",', status)
        self.assertLess(status.index("if tooLong {"), status.index("} else if changes, error != nil {"))
        self.assertLess(status.index("} else if changes, error != nil {"), status.index("} else if changes {"))
        self.assertIn(".toolBottomBar { bottomBar }", view)
        # A field under a page of the same name hides its own; VoiceOver keeps it.
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
        self.assertIn(".sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }", picker)
        self.assertIn("profile?.confirmedPhotos", picker)
        self.assertIn(".assignedProfileIdentifiers == [profile.identifier]", picker)

    def test_picker_offers_recent_photos_first_and_takes_several(self) -> None:
        """349: photos often have no cat, so every recent photo is offered first;
        several are added before 「完了」, each through the same confirmation."""
        picker = section(self.view, "private struct VeterinaryRecordPicker: View {", "private struct VeterinaryRecordConfirmation")
        self.assertIn('.navigationTitle("見せる写真を選ぶ")', picker)
        self.assertNotIn("写真・メモを選ぶ", self.view)
        body = section(picker, "var body: some View {", "private func recordRow(")
        order = [body.index('Section("最近の写真")'), body.index('Toggle("この子の写真だけ", isOn: $onlyMine)'),
                 body.index("ForEach(gridRows"), body.index('Section("写真に付けたメモ")'),
                 body.index("ForEach(records) { record in recordRow(record) }")]
        self.assertEqual(order, sorted(order))
        # Every photo by default; this cat's page photos only when asked.
        self.assertIn("@State private var onlyMine = false", picker)
        self.assertIn("if !mine.isEmpty {", body)
        # 11/9: recent videos are offered too, in the same grid.
        self.assertIn("return (photos + mine + videos).filter { seen.insert($0.localIdentifier).inserted }", picker)
        self.assertIn("(onlyMine ? mine : everyPhoto).filter { access.photo(for: $0.localIdentifier) != nil }", picker)
        self.assertIn(".sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }", picker)
        self.assertNotIn("guard let mine = profile?.confirmedPhotos, !mine.isEmpty else { return photos }", picker)
        self.assertIn("access.start(photos: everyPhoto)", body)
        # Three to a row, one list row per three so only rows on screen are made.
        self.assertIn("stride(from: 0, to: grid.count, by: 3)", picker)
        self.assertIn("ForEach(row.count..<3, id: \\.self)", body)
        self.assertIn("targetPixelSize: CGSize(width: 360, height: 360)", picker)
        # Several picks: the list stays open, each pick confirmed over it, then 「完了」.
        self.assertIn('Button("完了") { dismiss() }.accessibilityIdentifier("vet-pick-done")', body)
        self.assertIn("ToolbarItem(placement: .confirmationAction)", body)
        self.assertNotIn('Button("閉じる")', picker)
        self.assertIn(".sheet(item: $chosen) { source in", body)
        self.assertIn("VeterinaryRecordConfirmation(source: source, visit: visit, photos: everyPhoto,", body)
        self.assertIn("added(updated); chosen = nil", body)
        self.assertNotIn("dismiss()", body.replace('Button("完了") { dismiss() }', ""))
        self.assertIn("chosen = PhotoMemoryNoteRecord(photoIdentifier: photo.localIdentifier, note: note)", picker)
        self.assertIn("Button { chosen = record } label:", picker)
        # What is already added is marked, on photos and on memos.
        cell = section(picker, "private func photoCell(", "\n    }\n")
        self.assertIn('Image(systemName: "checkmark.circle.fill")', cell)
        self.assertIn('.accessibilityValue(added ? "追加済み" : "")', cell)
        row = section(picker, "private func recordRow(", "private func photoCell(")
        self.assertIn('Image(systemName: "checkmark.circle.fill")', row)
        self.assertIn('Text(current ? "追加済み" : "元のメモが書き直されています。選ぶと新しい内容にできます")', row)
        # The page keeps its memo current after every addition.
        self.assertIn("store: store) { self.visit = $0 }", self.view)
        self.assertNotIn("pendingSource", self.view)
        # The memo choices still leave out another cat's measurement.
        self.assertIn("$0.note.weight?.catID == nil || $0.note.weight?.catID == visit.catID", picker)

    def test_record_photos_on_the_page_are_small_copies(self) -> None:
        """349: each record row showed a decode of up to 4096 px; the page now
        shows a kept copy of at most 900 px, the full photo only when opened."""
        photo = section(self.view, "private struct VeterinaryEntryPhoto: View {", "private struct VeterinaryEntryFullPhoto: View {")
        self.assertIn("static let maxPixel: CGFloat = 900", photo)
        self.assertIn("ToolPhotoThumbnail.cached(key, maxPixel: Self.maxPixel)", photo)
        self.assertIn("let small = await ToolPhotoThumbnail.load(bytes, key: key, maxPixel: Self.maxPixel)", photo)
        self.assertIn("try await store.image(for: entry, visitID: visitID)", photo)
        self.assertIn("VeterinaryEntryFullPhoto(entry: entry, visitID: visitID, store: store)", photo)
        self.assertNotIn("4096", photo)
        self.assertNotIn("MemoArchivePhoto", self.view)
        full_route = section(self.view, "private struct VeterinaryEntryFullPhoto: View {", "private struct VeterinaryReadView: View {")
        self.assertIn("ToolRecordFullPhoto { try await store.image(for: entry, visitID: visitID) }", full_route)
        full = section(source("NekoWidget/Views/PhotoDetailComponents.swift"), "struct ToolRecordFullPhoto: View {", "struct MomentZoomablePhoto:")
        self.assertIn("ToolPhotoThumbnail.decode(bytes, maxPixel: 4096)", full)
        self.assertIn("Task.detached(priority: .userInitiated)", full)
        loader = source("NekoWidget/Services/ToolPhotoThumbnail.swift")
        made = section(loader, "static func load(_ data: Data, key: String, maxPixel: CGFloat) async -> UIImage? {", "private static func decode(_ url: URL")
        self.assertIn("Task.detached(priority: .userInitiated)", made)
        self.assertIn("CGImageSourceCreateThumbnailAtIndex", made)
        self.assertIn("kCGImageSourceThumbnailMaxPixelSize: maxPixel", made)
        self.assertIn("cache.setObject(image", made)
        # The PDF and images still read each photo from the store themselves.
        export = section(self.view, "private func makeExport(pdf: Bool) async {", "private enum VeterinaryCareOrder")
        self.assertIn("let data = try? await store.image(for: entry, visitID: visit.id)", export)
        self.assertIn("VeterinaryMemoExporter.image(data)", export)
        self.assertNotIn("ToolPhotoThumbnail", export)


class VeterinaryRoundTwoTests(unittest.TestCase):
    """病院で見せる, round 2 (11/9): 「撮る」 inside the tool, videos, and the
    day's weight read from and written into 「この子のこと」."""

    def setUp(self) -> None:
        self.view = source("NekoWidget/Views/VeterinaryVisitView.swift")
        self.capture = source("NekoWidget/Views/VeterinaryCapture.swift")
        self.store = source("NekoWidget/Services/VeterinaryVisitStore.swift")

    def test_taking_a_photo_or_video_saves_it_to_photos_then_adds_it(self) -> None:
        picker = section(self.view, "private struct VeterinaryRecordPicker: View {", "private struct VeterinaryRecordConfirmation")
        rows = section(picker, "@ViewBuilder private var captureRows: some View {", "var body: some View {")
        # No camera (the simulator): no button. Turned off: one sentence and Settings.
        self.assertIn("if VeterinaryCapture.cameraAvailable {", rows)
        self.assertIn('Button("撮る", systemImage: "camera") { Task { await openCamera() } }', rows)
        self.assertIn('Button("設定を開く")', rows)
        self.assertIn("UIApplication.openSettingsURLString", rows)
        opening = section(picker, "private func openCamera() async {", "/// The shot goes to the photo library")
        self.assertLess(opening.index("await VeterinaryCapture.blockedReason()"), opening.index("capturing = true"))
        self.assertIn("if captureBlocked == nil { capturing = true }", opening)
        body = section(picker, "var body: some View {", "private func recordRow(")
        self.assertLess(body.index('Section("最近の写真")'), body.index("captureRows"))
        self.assertLess(body.index("captureRows"), body.index('Toggle("この子の写真だけ", isOn: $onlyMine)'))
        self.assertIn(".fullScreenCover(isPresented: $capturing) {", body)
        self.assertIn("VeterinaryCameraView { shot in", body)
        # Saved to the photo library first, then added to this cat's memo only,
        # by the same ownership rule as a chosen photo.
        shot = section(picker, "private func addShot(_ shot: VeterinaryCapture.Shot) async {", "@ViewBuilder private var captureRows")
        self.assertLess(shot.index("try await VeterinaryCapture.save(shot)"), shot.index("try await store.add("))
        self.assertIn("cats: [PhotoMemoryNoteCat(id: visit.catID, name: visit.catName)]", shot)
        self.assertIn("confirmedTarget: VeterinaryRecordConfirmation.belongsOnly(to: visit.catID, source)", shot)
        self.assertIn("videoSeconds: saved.seconds", shot)
        self.assertNotIn("confirmedTarget: true", self.view)
        camera = section(self.capture, "struct VeterinaryCameraView: UIViewControllerRepresentable {", "/// A video in the memo")
        self.assertIn("picker.sourceType = .camera", camera)
        self.assertIn("picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]", camera)
        self.assertIn("picker.videoMaximumDuration = VeterinaryCapture.maximumVideoSeconds", camera)
        self.assertIn("FileManager.default.copyItem(at: movie, to: copy)", camera)
        save = section(self.capture, "static func save(_ shot: Shot) async throws -> Saved {", "/// The memo's copy")
        self.assertIn("request.addResource(with: .photo, data: original, options: nil)", save)
        self.assertIn("request.addResource(with: .video, fileURL: url, options: options)", save)
        self.assertIn("defer { try? FileManager.default.removeItem(at: url) }", save)
        self.assertIn("PHAssetCreationRequest.forAsset()", self.capture)
        self.assertIn("kCGImageSourceCreateThumbnailWithTransform: true", self.capture)
        blocked = section(self.capture, "static func blockedReason() async -> String? {", "/// Saves the shot")
        self.assertIn("AVCaptureDevice.requestAccess(for: .video)", blocked)
        self.assertIn("PHPhotoLibrary.requestAuthorization(for: .addOnly)", blocked)
        # 「この子のこと」's document camera still keeps its shots in the app.
        care = source("NekoWidget/Views/CatCareView.swift")
        self.assertNotIn("PHPhotoLibrary", care)
        plist = source("NekoWidget/Info.plist")
        camera_text = section(plist, "<key>NSCameraUsageDescription</key>", "<key>NSPhotoLibraryAddUsageDescription</key>")
        self.assertIn("写真アプリには追加しません", camera_text)
        self.assertIn("病院で見せる写真と動画は、写真アプリに保存します。", camera_text)
        add_text = section(plist, "<key>NSPhotoLibraryAddUsageDescription</key>", "<key>NSMicrophoneUsageDescription</key>")
        self.assertIn("「病院で見せる」で撮った写真と動画", add_text)
        self.assertIn("写真を自動で追加することはありません", add_text)
        self.assertIn("<key>NSMicrophoneUsageDescription</key>\n\t<string>「病院で見せる」で猫の様子を動画に撮るとき", plist)
        project = source("NekoWidget.xcodeproj/project.pbxproj")
        self.assertEqual(project.count("VeterinaryCapture.swift in Sources */,"), 1)
        self.assertEqual(project.count("path = VeterinaryCapture.swift;"), 1)

    def test_videos_are_chosen_marked_and_played_only_after_a_tap(self) -> None:
        picker = section(self.view, "private struct VeterinaryRecordPicker: View {", "private struct VeterinaryRecordConfirmation")
        self.assertIn("let recent = VeterinaryCapture.recentVideos()", picker)
        self.assertIn("return (photos + mine + videos).filter { seen.insert($0.localIdentifier).inserted }", picker)
        self.assertIn("videoSeconds: videoSeconds[source.photoIdentifier]) { updated in", picker)
        cell = section(picker, "private func photoCell(", "\n    }\n")
        self.assertIn("if let seconds { VeterinaryVideoBadge(seconds: seconds) }", cell)
        self.assertIn("let seconds = videoSeconds[photo.localIdentifier]", cell)
        confirm = section(self.view, "private struct VeterinaryRecordConfirmation: View {", "/// One day per record")
        self.assertIn("videoSeconds: bytes == nil ? nil : videoSeconds)", confirm)
        recent = section(self.capture, "static func recentVideos(", "/// The video to play")
        self.assertIn("PHAsset.fetchAssets(with: .video, options: options)", recent)
        self.assertIn("guard status == .authorized || status == .limited else { return [] }", recent)
        # The memo row and the show screen: the first frame with a mark; a tap plays it there.
        photo = section(self.view, "private struct VeterinaryEntryPhoto: View {", "private struct VeterinaryEntryFullPhoto: View {")
        self.assertIn("if playing, let identifier = entry.sourcePhotoIdentifier {", photo)
        self.assertIn("Button { if videoSeconds != nil { playing = true } else { expanded = true } } label: {", photo)
        self.assertEqual(photo.count("playing = true"), 1)
        self.assertIn("VeterinaryEntryVideo(identifier: identifier)", photo)
        self.assertIn('Image(systemName: "play.circle.fill")', photo)
        video = section(self.capture, "struct VeterinaryEntryVideo: View {", "/// The mark on a video's first frame")
        self.assertIn("VideoPlayer(player: player)", video)
        self.assertIn(".onDisappear { player?.pause() }", video)
        self.assertNotIn("isMuted", video)
        self.assertEqual(self.capture.count("player.play()"), 1)
        self.assertIn("VeterinaryEntryPhoto(entry: entry, visitID: visit.id, store: store, videoSeconds: videos[entry.id])", self.view)
        self.assertEqual(self.view.count("videoSeconds: videos[entry.id]"), 2)
        self.assertIn("videos: videos).environment(", self.view)
        export = section(self.view, "private func makeExport(pdf: Bool) async {", "private enum VeterinaryCareOrder")
        self.assertIn('lines.append("動画 " + VeterinaryVisitEntry.durationText(seconds))', export)

    def test_video_lengths_stay_beside_the_memos_for_older_versions_and_the_family(self) -> None:
        # Not in the visit or entry: older versions read the memo as before, and
        # the family notebook's receive path (being changed elsewhere) is untouched.
        model = section(self.store, "struct VeterinaryVisitEntry: Codable", "extension VeterinaryVisitEntry {")
        self.assertNotIn("video", model.lower())
        state = section(self.store, "private struct State: Codable {", "private let directory: URL")
        self.assertIn("var videoSeconds: [String: Double]? = nil", state)
        self.assertIn("receiveFamilyChanges(project: FamilyNotebookToolSharing.visitsReceived)", self.store)
        self.assertIn("Self.keepingLocalResults(try project(state.visits), from: state.visits)", self.store)
        keeping = section(self.store, "static func keepingLocalResults(", "/// The UI supplies a live membership boundary")
        self.assertNotIn("video", keeping)
        add = section(self.store, "func add(source: PhotoMemoryNoteRecord", "func remove(entryID:")
        self.assertIn("guard VeterinaryVisitEntry.validVideoSeconds(videoSeconds), jpeg != nil,", add)
        self.assertIn("videos[entry.id.uuidString] = videoSeconds", add)
        load = section(self.store, "private func load() throws -> State {", "private static func canInitializeMissingManifest(")
        self.assertIn("UUID(uuidString: $0.key) != nil && VeterinaryVisitEntry.validVideoSeconds($0.value)", load)
        commit = section(self.store, "private func commit(_ state: State, familyProjection: Bool = false,", "private func write(")
        self.assertIn("let kept = videos.filter { live.contains($0.key) }", commit)
        verifier = (ROOT / "ci/verify-veterinary-visits.swift").read_text(encoding="utf-8")
        for case in ("An incomplete video was accepted", "An older version could not read a memo with a video",
                     "A removed video kept its length", "An impossible video length was read",
                     "A memo without video lengths did not read as before", "A past memo showed a weight measured later"):
            self.assertIn(case, verifier)
        self.assertIn("try await verifiesVideosAndDayWeight(", verifier)

    def test_the_days_weight_has_one_place_in_cat_care(self) -> None:
        # No second weight form: the row shows 「この子のこと」's newest weight
        # and opens 「この子のこと」's own weight form, which writes there.
        self.assertNotIn(".decimalPad", self.view)
        self.assertNotIn("体重（kg）", self.view)
        model = section(self.store, "struct VeterinaryVisit: Codable", "var orderedEntries")
        self.assertNotIn("weight", model.lower())
        # 11/12: 体重 is its own row in 「診察の前に」, right after 家で気付いたこと,
        # shown while the memo is open (it was inside step 1's open branch).
        before = section(self.view, "private func beforeSection(", "private func recordsLabel(")
        self.assertIn("if visit.completedAt == nil { weightRow(visit) }", before)
        self.assertLess(before.index('"vet-step-noticed"'), before.index("weightRow(visit)"))
        self.assertLess(before.index("weightRow(visit)"), before.index('"vet-step-records"'))
        weight_row = section(self.view, "private func weightRow(", "private func recordWeight(")
        # 11/12 (round 2): a row that opens a form has the same chevron as the others.
        self.assertIn('return ToolSheetRow(row: ToolValueRow(title: "体重", systemImage: "scalemass",', weight_row)
        self.assertIn("value: weight ?? ToolEmptyValue.unwritten, filled: weight != nil)) {\n            weighing = true", weight_row)
        self.assertIn('"vet-row-weight"', weight_row)
        self.assertIn("CatCareListEntrySheet(editor: CatCareListEditor(kind: .weight), catID: nil) { result in", self.view)
        record = section(self.view, "private func recordWeight(", "private func recordSection(")
        self.assertIn("CatCareSummary.record(toolCatID: visit.catID, profileIdentifier: visit.catID.uuidString)", record)
        self.assertIn("catCareStore.ensureRecord(profileID: visit.catID, name: profile?.displayName)", record)
        self.assertIn("result.apply(to: &state.cats[index], by: state.deviceID, now: Date())", record)
        weight = section(self.view, "private enum VeterinaryDayWeight {", "\n}\n")
        self.assertIn("record.activeWeights", weight)
        self.assertIn("VeterinaryVisitWeight.latest(weights, onOrBefore: VeterinaryVisit.day(visit.completedAt ?? Date()))", weight)
        # Near the top of the show screen and the paper, before what was noticed.
        read = section(self.view, "private struct VeterinaryReadView: View {", "@ViewBuilder private var exportButtons")
        self.assertLess(read.index("ToolMemoSheet(kind: \"診察メモ\", name: displayName ?? visit.catName"),
                        read.index('Text("体重").toolMemoLabel()'))
        self.assertLess(read.index('Text("体重").toolMemoLabel()'), read.index('Text("家で気付いたこと")'))
        export = section(self.view, "private func makeExport(pdf: Bool) async {", "private enum VeterinaryCareOrder")
        self.assertLess(export.index('noticed.append(("体重"'), export.index('("家で気付いたこと"'))


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
        # 11/7: one place to write 「この子のこと」 — the cat's page in この子 (was ツール).
        # The notebook lists the shared cats and leads nowhere else.
        self.assertNotIn("CatCareDetailView(", notebook)
        self.assertNotIn("NavigationLink(cat.name)", notebook)
        row = source("NekoWidget/Views/FamilyNotebookSharedCatRow.swift")
        self.assertNotIn("NavigationLink", row)
        home = source("NekoWidget/Views/CatHomeView.swift")
        self.assertIn("for cat in familyOnlyCats where seen.insert(cat.toolID.uuidString.uppercased()).inserted {", home)
        self.assertNotIn("CatCareDetailView(toolCatID: cat.toolID, name: cat.name)", notebook)
        self.assertIn("if joined == .joined { onJoined?(); dismiss() }", notebook)
        care = source("NekoWidget/Views/CatCareView.swift")
        self.assertIn("if !insideFamilyNotebook, Version1.familyNotebook || familyNotebook.hasFamily {", care)
        root_view = source("NekoWidget/App/AppRootView.swift")
        self.assertIn("FamilyNotebookJoinView(link: $0.url, onJoined: { joinedFamilyFromLink = true })", root_view)
        self.assertIn(".sheet(isPresented: $showsFamilyNotebook) { FamilyNotebookView() }", root_view)

    def test_account_page_returns_to_auto_save_after_sign_out(self) -> None:
        view = source("NekoWidget/Views/ManagedPreservationView.swift")
        self.assertIn("returnsWhenDone = isAccountEntry\n                                coordinator.signOut()", view)
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
        # 11/10: only for someone already in a family; starting one is in この子のこと.
        self.assertIn("private var showsFamilyNotebookRow: Bool { familyNotebook.hasFamily }", settings)
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
        self.assertIn('Label("Plusなしで猫の名前と日付だけ移す"', transfer)
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
        self.assertEqual(choices.count("} footer: {"), 3, "each choice says what it deletes, then the one Plus note")
        # 11/8 (29): 「Plusは解約されません」 once in the deletion flow, here.
        self.assertIn('"account-deletion-subscriptions"', choices)
        self.assertIn("Plusは、ここで消しても解約されません。", choices)
        self.assertNotIn("サブスクリプション", source("NekoWidget/Views/GroupWindowView.swift"))
        # 11/8 (2): no ID or server in the words.
        self.assertIn('Label("まどと家族の手帳から抜ける"', choices)
        for word in ("のID", "とID", "サーバー"):
            self.assertNotIn(word, choices)
        self.assertIn("GroupWindowClientProvider.production != nil || ManagedPreservationConfiguration.current.isEnabled", choices)
        saving = source("NekoWidget/Services/AppRecordPersistence.swift")
        self.assertNotIn("アカウント（削除・サインアウト）", saving)
        self.assertIn('NavigationLink("自動保存のアカウント") { ManagedPreservationView() }', saving)
        # The delete button and its confirmation exist only on the deletion entry.
        view = source("NekoWidget/Views/ManagedPreservationView.swift")
        self.assertEqual(view.count('"preservation-account-delete"'), 1)
        self.assertIn('Button("アカウントと保存したものを削除", role: .destructive) { coordinator.deleteServiceAccount() }', view)
        # 11/8 (28): the deletion entry is one sentence and the button, not the account screen again.
        self.assertIn("if deletesAccount { deletionContent }", view)
        deletion = section(view, "@ViewBuilder private var deletionContent: some View {", "private func accountDeletionSection(")
        self.assertIn('"preservation-account-delete"', deletion)
        self.assertEqual(deletion.count("Text("), 1)
        for other in ("noticeContactSection", "retentionSection", "usageSection", "membershipSection", "サインアウト"):
            self.assertNotIn(other, deletion)
        sign_out = section(view, "if !deletesAccount && coordinator.isSignedIn && coordinator.accountDeletionState == nil {",
                           "private var deletionContent")
        self.assertIn('Button("サインアウト", role: .destructive)', sign_out)
        self.assertIn('message: { Text("記録は残ります。") }', sign_out)
        # 11/8 (29): the Plus note is not repeated on the account or deletion screens.
        for old in ("Plusの解約は", "解約されない", "サブスクリプション"):
            self.assertNotIn(old, view)
        group = source("NekoWidget/Views/GroupWindowView.swift")
        identity = section(group, "struct GroupIdentityDeletionView: View {", "private func refresh() async {")
        self.assertIn('Text("まどと家族の手帳から抜けて、あなたが届けた写真・ひとこと・ハートを消します。")', identity)
        for word in ("のID", "の ID", "IDを", "サーバー", "解約"):
            self.assertNotIn(word, identity)

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
        # 11/12: still offered after a purchase from every entry, but later and
        # once, from the app's root (PlusMomentOfBuying1112Tests).
        offer = source("NekoWidget/Services/MembershipOfferModel.swift")
        sheet = section(offer, "struct MembershipOfferSheet: View {", "struct PlusOfferPrompt: View {")
        purchase = section(sheet, "    private func purchase() {", "    private func openNextStep()")
        self.assertIn("AutoSaveAfterPurchase.noteBought(from: context)", purchase)
        self.assertIn(".interactiveDismissDisabled(model.isWorking)", sheet)
        prompt = section(offer, "enum AutoSaveAfterPurchase {", "@MainActor\n/// The one Plus screen.")
        self.assertIn("context != .preservation && ManagedPreservationConfiguration.current.isEnabled", prompt)
        self.assertIn("!AppRecordPersistence.shared.enabled", prompt)
        self.assertIn("AppRecordSettingsView(startsOnOpen: true)", prompt)
        self.assertEqual(offer.count('"自動保存も始めますか？"'), 1, "one prompt for every entry")
        root = source("NekoWidget/App/AppRootView.swift")
        self.assertIn(".autoSaveOfferAfterOnboarding(ended: !OnboardingPresentationPersistence.requiresPresentation(", root)

    def test_tool_ui_fixtures_name_the_failed_check_and_follow_free_tools(self) -> None:
        # 11/8: the in-app checks of the tool UI tests said only 「境界検証失敗」
        # or "failed"; a UI run must say which check broke.
        care = source("NekoWidget/Views/CareHandoffFixtureView.swift")
        self.assertIn('checks = "境界検証失敗：" + check', care)
        self.assertIn("if case let .assertion(name)? = error as? FixtureCheckFailure { check = name }", care)
        self.assertNotIn('catch { checks = "境界検証失敗" }', care)
        self.assertIn('FixtureCheckFailure.assertion("refresh failure check, line \(line)")', care)
        profile = source("NekoWidget/App/AppStoreScreenshotFixture.swift")
        self.assertIn('"failed: \\(failureMessage)"', profile)
        # ADR-027: the tools are free. The fixture must not expect an expired
        # membership to block a new care memo while the policy allows it.
        policy = source("Shared/MembershipAccessPolicy.swift")
        allowed = section(policy, "switch operation {", "return .allowed")
        self.assertIn(".createCareMemo", allowed)
        self.assertNotIn("expiry blocks", care)
        self.assertIn('expired.decision(for: .createCareMemo) == .allowed, "tools stay free after expiry"', care)
        # An empty-records UI harness is DEBUG only and only by its own argument.
        persistence = source("NekoWidget/Services/AppRecordPersistence.swift")
        fixture = section(persistence, "#if DEBUG\n    private static var fixtureSupport: URL? = {", "#endif")
        self.assertIn('CommandLine.arguments.contains("--isolated-app-records")', fixture)
        self.assertEqual(persistence.count("--isolated-app-records"), 2)
        # The repeated photo interruption ends each round like an app exit;
        # setActive(false) would start a background save that races the next round.
        probe = section(persistence, "verifyRepeatedPhotoInterruption", "guard persistence.title == \"保存済み\"")
        self.assertIn("persistence.stopLoopForFixture()", probe)
        self.assertNotIn("persistence.setActive(false)", probe)


class ToolOpenWasteTests(unittest.TestCase):
    """11/8: opening a tool does no needless work while it is scrolled."""

    def test_lost_cat_opening_saves_nothing_unchanged(self) -> None:
        store = source("NekoWidget/Services/CatPreparednessStore.swift")
        persist = section(store, "private func persistDraft(_", "/// Text-only refresh")
        # The checks still come first; an unchanged draft then writes and wakes nothing.
        skip = persist.index("if var unchanged = drafts[key] {")
        self.assertLess(persist.index("try AppRecordDataset.requireWritable(manifest)"), skip)
        self.assertLess(persist.index("try requireReadableManifest(allowingNewFiles: allowingNewFiles)"), skip)
        self.assertIn("unchanged.updatedAt = draft.updatedAt\n            if unchanged == draft { return }", persist)
        early = persist.index("if unchanged == draft { return }")
        for effect in ("value.updatedAt = Date()", "write(to: manifest", "AppRecordDataset.committed(manifest)"):
            self.assertLess(early, persist.index(effect), effect)
        view = source("NekoWidget/Views/CatPreparednessView.swift")
        editor = section(view, "struct LostCatDraftView: View {", "private struct LostCatPhotoChoiceView")
        self.assertIn("@State private var savedDraft: LostCatDraft?", editor)
        # Editing still saves on its own, 350 ms later.
        on_change = section(editor, ".onChange(of: draft) { _, _ in", ".onDisappear")
        self.assertIn("guard loaded, draft != savedDraft else { return }", on_change)
        self.assertIn("try? await Task.sleep(for: .milliseconds(350))", on_change)
        self.assertIn("saveNow()", on_change)
        save = section(editor, "private func saveNow() {", "private func load(_ identity:")
        self.assertIn("if !saveError, draft == savedDraft { return }", save)
        self.assertIn("try store.save(draft, for: key); savedDraft = draft; saveError = false", save)
        load = section(editor, "private func load(_ identity:", "private func switchTo(")
        self.assertLess(load.index("savedDraft = saved"), load.index("draft = saved\n"))
        commit = section(editor, "private func commitPhoto(", "private func removeSecondPhoto(")
        self.assertIn("savedDraft = draft", commit)
        remove = section(editor, "private func removeSecondPhoto(", "private func cancelPhotoLoad(")
        self.assertIn("savedDraft = draft", remove)

    def test_lost_cat_flyer_issues_are_measured_once_per_drawing(self) -> None:
        view = source("NekoWidget/Views/CatPreparednessView.swift")
        editor = section(view, "struct LostCatDraftView: View {", "private struct LostCatPhotoChoiceView")
        self.assertEqual(editor.count("flyerIssues"), 2, "declared once, read once in body")
        body = section(editor, "    var body: some View {", "        Form {")
        self.assertIn("let issues = flyerIssues", body)
        self.assertNotIn("private var issues:", editor)
        flyer = section(editor, "private var flyerIssues: [String: String] {", "private var requiredFields")
        self.assertIn("LostCatFlyerRenderer.validationIssues(publicDraft)", flyer)
        # An empty place or contact is named by 「あと：…」, not shown as a red
        # issue before anything is written (11/8 型; the UI check expects
        # 「あと：場所・連絡先」 on a fresh draft). Text that does not fit stays.
        self.assertIn('!(field == "place" && publicDraft.lastSeenNear.isEmpty)', flyer)
        self.assertIn('!(field == "contact" && publicDraft.contact.isEmpty)', flyer)
        self.assertIn("@ViewBuilder private func fieldIssue(_ field: String, _ issues: [String: String]) -> some View {", editor)
        for field in ('"name"', '"place"', '"contact"', "String(describing: field)"):
            self.assertIn(f"fieldIssue({field}, issues)", editor)
        # Every call is handed the one dictionary.
        calls = re.findall(r"fieldIssue\(([^()]*(?:\([^()]*\))?[^()]*)\)", editor)
        self.assertEqual([c for c in calls if not c.endswith(", issues") and "_ field: String" not in c], [])
        self.assertEqual(editor.count("textEntry(") - 1, editor.count("issues: issues, focus: focus)"))
        # 11/12: each row's page is handed the same dictionary, not its own.
        for name in ("flyerSection", "namePage", "featuresPage", "collarPage", "placePage", "contactPage", "advicePage"):
            self.assertIn(f"private func {name}(_ issues: [String: String]) -> some View {{", editor)

    def test_tool_photos_on_screen_are_small_copies_made_off_the_main_thread(self) -> None:
        loader = source("NekoWidget/Services/ToolPhotoThumbnail.swift")
        self.assertIn("static let tileMaxPixel: CGFloat = 600", loader)
        self.assertIn("NSCache<NSString, UIImage>", loader)
        self.assertIn("Task.detached(priority: .userInitiated)", loader)
        self.assertIn(".contentModificationDateKey", loader)
        self.assertIn("GroupPhotoDecoder.image(at: url, maxPixel: maxPixel)", loader)
        self.assertNotIn("UIImage(contentsOfFile", loader)
        decoder = section(source("NekoWidget/Views/GroupWindowView.swift"), "enum GroupPhotoDecoder {", "private struct GroupPhotoTile")
        self.assertIn("CGImageSourceCreateThumbnailAtIndex", decoder)
        project = source("NekoWidget.xcodeproj/project.pbxproj")
        self.assertEqual(project.count("/* ToolPhotoThumbnail.swift in Sources */"), 2)
        self.assertEqual(project.count("path = ToolPhotoThumbnail.swift;"), 1)

        # The shared slot shows a kept file from a small copy, loaded in @State.
        shared = source("NekoWidget/Views/CatCareView.swift")
        slot = section(shared, "struct ToolPhotoSlot<Actions: View>: View {", "struct ToolPhotoGrid<Content: View>: View {")
        self.assertIn("var file: URL?", slot)
        self.assertIn("@State private var thumbnail: UIImage?", slot)
        self.assertIn("private var shown: UIImage? { file == nil ? image : thumbnail }", slot)
        self.assertIn("if let shown { Image(uiImage: shown).resizable().scaledToFit() }", slot)
        self.assertNotIn("Image(uiImage: image)", slot)
        self.assertIn("if hasPhoto && !chooseOnly {\n                        actionsMenu", slot)
        self.assertIn("Menu { actions } label: {", slot)
        self.assertIn(".task(id: file) { thumbnail = await ToolPhotoThumbnail.load(file) }", slot)

        evacuation = source("NekoWidget/Views/EvacuationPreparationView.swift")
        care = source("NekoWidget/Views/CareHandoffView.swift")
        for view in (evacuation, care):
            self.assertNotIn("store.image(", view)
        # 11/9: 「この子のこと」's photos are shown through the same slot, by file.
        self.assertIn("ToolIdentifyingPhotos(faceFile: photo, bodyFile: nil, subject: subject(cat), profiles: profiles,", care)
        self.assertIn('showsBody: false, identifier: "care-photo-open")', care)
        self.assertIn("ToolPhotoSlot(role.title, image: nil, file: store.imageURL(cat.photos[role.rawValue]),", evacuation)
        self.assertIn('identifier: "evacuation-photo-\\(role.rawValue)"', evacuation)
        # 猫の情報 shows both photos small, from their files.
        self.assertIn("ToolIdentifyingPhotos(faceFile: cat.identifyingPhoto(.face, store: store),", evacuation)
        self.assertIn("bodyFile: cat.identifyingPhoto(.body, store: store),", evacuation)
        self.assertNotIn("private struct EvacuationPhoto: View {", evacuation)
        identifying = section(shared, "struct ToolIdentifyingPhotos: View {", "extension ToolMakeBar where Top == EmptyView {")
        self.assertIn('ToolPhotoSlot(readOnly: "顔の写真", file: faceFile, identifier: identifier + "-face")', identifying)
        self.assertIn('ToolPhotoSlot(readOnly: "全身の写真", file: bodyFile, identifier: identifier + "-body")', identifying)
        self.assertNotIn("UIImage(contentsOfFile", identifying)

        lost = source("NekoWidget/Views/CatPreparednessView.swift")
        editor = section(lost, "struct LostCatDraftView: View {", "private struct LostCatPhotoChoiceView")
        self.assertIn('file: faceImage == nil ? nil : tileFile(draft.faceFileName, draft.bodyFileName))', editor)
        self.assertIn('file: bodyImage == nil || draft.faceFileName == nil ? nil : tileFile(draft.bodyFileName))', editor)
        files = section(editor, "private func tileFile(_ names: String?...) -> URL? {", "private func photoTile(")
        self.assertIn("store.imageURL($0)", files)
        self.assertNotIn("store.image(", files)
        tile = section(editor, "private func photoTile(", "private func saveNow()")
        self.assertIn("ToolPhotoSlot(title, image: image, file: file,", tile)
        self.assertIn('identifier: role == .face ? "lost-cat-face-photo" : "lost-cat-body-photo"', tile)
        # The flyer and 切り取る keep the full photos.
        self.assertIn("faceImage: faceImage, bodyImage: bodyImage)", editor)
        self.assertIn("cropRequest = LostCatCropRequest(role: role, image: image)", tile)
        # No full photo is read while a tool page is drawn.
        for body in (section(editor, "    var body: some View {", "    // MARK: Rows (11/12)"),
                     section(editor, "    // MARK: Rows (11/12)", "private func loadPicked(")):
            self.assertNotIn("store.image(", body)
        # 「この子のこと」's photo is only looked for while drawing, never read.
        cat_section = section(editor, "@ViewBuilder private var photoRows: some View {", "private func loadPicked(")
        self.assertIn("if catCareSubject == nil, faceImage == nil, catCarePhotoURL(.face) != nil {", cat_section)
        self.assertNotIn("catCarePhoto(", cat_section)
        self.assertNotIn("Data(contentsOf", section(editor, "private func catCarePhotoURL(", "private func catCarePhoto("))
        for path in ("NekoWidget/Services/EvacuationStore.swift", "NekoWidget/Services/CareHandoffStore.swift",
                     "NekoWidget/Services/CatPreparednessStore.swift"):
            self.assertIn("func imageURL(_ name: String?) -> URL? {", source(path))

    def test_family_tool_sync_writes_the_binding_only_when_it_changes(self) -> None:
        view = source("NekoWidget/Views/FamilyNotebookView.swift")
        attach = section(view, "func attachReal(_ service:", "    /// Explicit personal-to-family boundary.")
        self.assertEqual(attach.count("UserDefaults.standard.set("), 1)
        self.assertLess(attach.index("UserDefaults.standard.data(forKey: Self.bindingKey) != bytes {"),
                        attach.index("UserDefaults.standard.set(bytes, forKey: Self.bindingKey)"))
        sync = section(view, "private struct FamilyNotebookToolSyncModifier: ViewModifier {", "extension View {")
        self.assertIn("try await Task.sleep(for: .seconds(5))", sync)



class ToolConsistency1108Tests(unittest.TestCase):
    """The same rules as 病院で見せる (11/8) in 預ける・迷子・避難・写真を見せる."""

    def setUp(self) -> None:
        self.care = source("NekoWidget/Views/CareHandoffView.swift")
        self.lost = source("NekoWidget/Views/CatPreparednessView.swift")
        self.evacuation = source("NekoWidget/Views/EvacuationPreparationView.swift")
        self.showcase = source("NekoWidget/Views/ShowcasePhotoView.swift")
        self.recent = source("NekoWidget/Views/ToolRecentPhotos.swift")

    def test_pickers_show_recent_photos_first_and_never_hide_unassigned_ones(self) -> None:
        project = source("NekoWidget.xcodeproj/project.pbxproj")
        self.assertEqual(project.count("/* ToolRecentPhotos.swift in Sources */"), 2)
        self.assertEqual(project.count("path = ToolRecentPhotos.swift;"), 1)
        # 11/12: the row-list parts every tool uses, registered the same way.
        self.assertEqual(project.count("/* ToolRowParts.swift in Sources */"), 2)
        self.assertEqual(project.count("path = ToolRowParts.swift;"), 1)
        self.assertIn("\t\t7A11120C0000000000000001 /* ToolRowParts.swift in Sources */ = {isa = PBXBuildFile; "
                      "fileRef = 7A11120C0000000000000002 /* ToolRowParts.swift */; };", project)
        self.assertIn("\t\t7A11120C0000000000000002 /* ToolRowParts.swift */ = {isa = PBXFileReference; "
                      "lastKnownFileType = sourcecode.swift; path = ToolRowParts.swift; sourceTree = \"<group>\"; };", project)
        self.assertIn("\t\t\t\t7A11080F0000000000000002 /* ToolRecentPhotos.swift */,\n"
                      "\t\t\t\t7A11120C0000000000000002 /* ToolRowParts.swift */,\n", project)
        self.assertIn("\t\t\t\t7A11080F0000000000000001 /* ToolRecentPhotos.swift in Sources */,\n"
                      "\t\t\t\t7A11120C0000000000000001 /* ToolRowParts.swift in Sources */,\n", project)
        self.assertEqual(project.count("7A11120C0000000000000001"), 2)
        self.assertEqual(project.count("7A11120C0000000000000002"), 3)
        # Every offered photo once, newest first.
        self.assertIn("photos.filter { seen.insert($0.localIdentifier).inserted }", self.recent)
        self.assertIn(".sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }", self.recent)
        section_view = section(self.recent, "struct ToolRecentPhotoSection: View {", "    private func cell(")
        self.assertIn('header: { Text("最近の写真") }', section_view)
        self.assertIn('Toggle("この子の写真だけ", isOn: $onlyThisCat)', section_view)
        self.assertIn("@State private var onlyThisCat = false", section_view)
        self.assertIn("let shown = onlyThisCat && canNarrow ? recent.filter { own.contains($0.localIdentifier) } : recent",
                      section_view)
        # Three photos per List row, so only the rows on screen are built. One
        # grid inside a single row asked for every photo at once (11/11).
        self.assertIn("ForEach(rows(shown), id: \.first?.localIdentifier) { row in", section_view)
        self.assertIn("stride(from: 0, to: photos.count, by: 3)", section_view)
        self.assertNotIn("LazyVGrid", self.recent)
        # Tiles are small copies from Photos, never a full decode.
        cell = self.recent[self.recent.index("    private func cell("):]
        self.assertIn("targetPixelSize: CGSize(width: 300, height: 300)", cell)
        for full in ("Data(contentsOf", "UIImage(contentsOfFile", "UIImage(data"):
            self.assertNotIn(full, self.recent)
        # 避難 (the photo with the owner) and 「この子のこと」 (11/9: 見分ける写真,
        # chosen there only) use it; nothing is sorted away under another cat's heading.
        # 預ける has no picker of its own any more.
        self.assertNotIn("struct CarePhotoPicker", self.care)
        self.assertNotIn("PhotosPicker(", self.care)
        evacuation_picker = section(self.evacuation, "private struct EvacuationPhotoPicker: View {",
                                    "private struct EvacuationPreviewItem")
        cat_care_picker = section(source("NekoWidget/Views/CatCareView.swift"),
                                  "private struct CatCareIdentifyingPhotoPicker: View {",
                                  "/// ② of every tool:")
        self.assertIn('identifierPrefix: "evacuation-candidate-") { use($0) }', evacuation_picker)
        self.assertIn("ToolRecentPhotoSection(photos: ownPhotos + otherPhotos, own: Set(ownPhotos.map(\\.localIdentifier)),",
                      evacuation_picker)
        self.assertIn('identifierPrefix: "cat-care-photo-candidate-") { use($0) }', cat_care_picker)
        self.assertIn("ToolRecentPhotoSection(photos: photos, own: Set(photos.map(\\.localIdentifier)), disabled: busy,",
                      cat_care_picker)
        self.assertIn('Label("写真アプリから選ぶ", systemImage: "photo.on.rectangle")', cat_care_picker)
        for picker in (evacuation_picker, cat_care_picker):
            self.assertNotIn('"ほかの猫の写真"', picker)
            self.assertNotIn('"この子の写真"', picker)
            self.assertNotIn("GridItem(.adaptive", picker)
        # 迷子 keeps this cat first; every recent photo is one tap away and named so.
        choice = section(self.lost, "private struct LostCatPhotoChoiceView: View {", "struct LostCatPhotoCropView: View {")
        self.assertIn("@State private var showsAllCats = false", choice)
        self.assertIn('Text("最近の写真").tag(true)', choice)
        self.assertIn("allPhotos.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }", self.lost)
        # One name for the system picker in every place a photo is chosen.
        for view in (source("NekoWidget/Views/CatCareView.swift"), self.lost, self.evacuation):
            self.assertIn('"写真アプリから選ぶ"', view)
        # 写真を見せる (11/13): a cat's own photos first, then 「ほかの猫の
        # 写真」, as in the key photo picker; 「最近の写真」 for すべての猫.
        # Pinned in ci/test-album-link-followups.py.
        picker = section(self.showcase, "private struct ShowcaseCandidatePicker: View {", "struct ShowcaseToolCatPicker: View {")
        self.assertIn('heading("最近の写真")', picker)
        self.assertNotIn("この子の写真だけ", picker)
        self.assertIn("candidates.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }", picker)
        self.assertNotIn('"ほかの写真"', picker)
        self.assertNotIn("leadingTitle", self.showcase)
        self.assertIn("own: knownIdentifiers,", self.showcase)

    def test_one_review_date_and_delete_alone_1108(self) -> None:
        # 11/8 (C): the cat page has no date of its own; delete stays alone, last.
        page = section(self.evacuation, "private struct EvacuationCatView: View {", "private struct EvacuationCatEditor: View {")
        note = page.index('ToolImportantInformation(text: "病歴・連絡先')
        delete = page.index('Button("この子の避難用の記録を削除", role: .destructive)')
        self.assertLess(note, delete)
        self.assertIn("}\n                Section {", page[note:delete])
        for gone in ('Button("内容を確かめた")', '"evacuation-mark-reviewed"', "内容を確かめた日", "押した日が、避難メモに載ります。"):
            self.assertNotIn(gone, self.evacuation)
        # The memo and the PDF carry the plan's one 「最後に見直した日」.
        store = source("NekoWidget/Services/EvacuationStore.swift")
        self.assertIn("fields: fields, reviewedAt: plan.lastReadyDate,", store)
        self.assertNotIn("reviewedAt: cat.reviewedAt", store)
        self.assertNotIn('"確かめた日："', store)
        exporter = source("NekoWidget/Services/EvacuationExporter.swift")
        self.assertIn('"最後に見直した日："', exporter)
        self.assertNotIn("内容を確かめた日", exporter)

    def test_delete_sits_alone_at_the_bottom_in_plain_red(self) -> None:
        editor = section(self.care, "private struct CareCatEditor: View {", "private struct CarePreview: Identifiable, Hashable {")
        # 11/12: delete is not part of writing the memo; it sits in 「…」, with
        # the same question first. The family note is the last thing on the page.
        more = section(editor, "private var moreMenu: some View {", "private var bottomBar: some View {")
        self.assertIn('ToolMoreMenu(destructiveTitle: "このお世話メモを削除", itemIdentifier: "care-delete",', more)
        self.assertIn('menuIdentifier: "care-more-menu") { deleteRequested = true }', more)
        self.assertNotIn('Button("このお世話メモを削除", role: .destructive)', self.care)
        self.assertIn('confirmationDialog("この子のお世話メモを削除しますか？", isPresented: $deleteRequested', editor)
        content = section(editor, "@ViewBuilder private var formContent: some View {", "private func headerSection(")
        self.assertLess(content.index("catCareSection(cat)"), content.index("footnoteSection(cat)"))
        self.assertLess(content.index("errorSection"), content.index("footnoteSection(cat)"))
        self.assertIn('ToolImportantInformation(text: "このメモは、家族の手帳には入っていません。")\n                    .quietRow()', editor)
        self.assertNotIn("前に入れた内容", content)
        page = section(self.evacuation, "private struct EvacuationCatView: View {", '}.navigationTitle("猫の情報")')
        self.assertIn('Button("この子の避難用の記録を削除", role: .destructive) { deleteRequested = true }\n                }', page)
        for view in (self.care, self.evacuation):
            for line in view.splitlines():
                if "role: .destructive) { deleteRequested = true }" in line:
                    self.assertNotIn("systemImage", line)
            self.assertNotIn('role: .destructive) { deleteRequested = true }\n                        .font(.footnote)', view)
        # Every delete asks first, 写真を見せる's former sets too.
        cats = self.showcase[self.showcase.index("struct ShowcaseToolCatPicker: View {"):]
        self.assertIn('.confirmationDialog("前に選んだ写真を削除しますか？"', cats)
        self.assertIn('message: { _ in Text("写真アプリの写真は消えません。") }', cats)
        self.assertNotIn("{ remove(scope) }", cats)
        # The note in the photo editor sits after the photos, not above them.
        photos = section(self.evacuation, "private struct EvacuationCatEditor: View {", "private struct EvacuationPhotoPicker: View {")
        self.assertLess(photos.index('Section("写真と名前")'), photos.index("前に入れた内容を読み込めませんでした。"))

    def test_plain_actions_carry_no_decorative_icons(self) -> None:
        for gone in ('Button("「この子のこと」の写真を使う", systemImage:', 'Button("「この子のこと」の連絡先を使う", systemImage:',
                     'systemImage: "arrow.clockwise"', 'Button("まとめてコピー", systemImage:', 'systemImage: "plus.circle"'):
            self.assertNotIn(gone, self.lost)
        # Adds keep 「+」.
        self.assertIn('Button("「\\(line)」を特徴に足す", systemImage: "plus")', self.lost)
        self.assertIn('Button("おすすめの持ち物を足す", systemImage: "plus")', self.evacuation)
        self.assertIn('Button("持ち物を追加", systemImage: "plus")', self.evacuation)
        hub = section(self.evacuation, "struct EvacuationPreparationView: View {", "private func makeBook()")
        self.assertIn('Button("\\(name(of: cat))を見せる") { show(cat) }', hub)
        self.assertNotIn('"rectangle.portrait.on.rectangle.portrait")\n', hub)
        self.assertIn('LabeledContent(isGuest ? "名前と飼い主と一緒の写真" : "飼い主と一緒の写真",', self.evacuation)
        self.assertNotIn("避難用の写真を選ぶ", self.evacuation)
        self.assertNotIn('Label(profile.displayName, systemImage: "cat")', self.showcase)
        # The make button looks the same in every tool.
        self.assertIn('Label("チラシを作る", systemImage: "doc.richtext")', self.lost)
        # 11/8: the tool says the same word as the screen (11/12: the button
        # on the この子 tab names the tool; the screen says チラシを作る).
        main_tab = source("NekoWidget/Views/MainTabView.swift")
        home = source("NekoWidget/Views/CatHomeView.swift")
        self.assertIn('case .lost: "迷子のとき"', home)
        self.assertNotIn("探すための画像を作る", main_tab)
        self.assertNotIn("探すための画像を作る", home)
        self.assertIn('Label("お世話メモを作る", systemImage: "doc.text")', self.care)
        self.assertIn('Label("避難メモを見せる", systemImage:', self.evacuation)

    def test_buttons_say_what_happened_and_no_mechanism_is_a_task(self) -> None:
        # まとめてコピー says it copied, as 「投稿する文章をコピー」 does.
        self.assertIn('Button(reportCopied ? "コピーしました" : "まとめてコピー") {', self.lost)
        self.assertIn("reportCopied = true", self.lost)
        self.assertIn(".sheet(isPresented: $showsGuide, onDismiss: { reportCopied = false })", self.lost)
        self.assertIn('.accessibilityIdentifier("lost-cat-copy-report")', self.lost)
        # A leftover photo copy is removed in the background in 避難 too.
        self.assertNotIn("使わなくなった写真のコピーが残っています", self.evacuation)
        self.assertNotIn("もう一度消す", self.evacuation)
        self.assertIn("store.retryPhotoCleanup()", self.evacuation)
        store = source("NekoWidget/Services/EvacuationStore.swift")
        self.assertIn("func retryPhotoCleanup() {\n        guard pendingPhotoCleanup, let repository else { return }", store)
        plan = source("NekoWidget/Services/EvacuationPlan.swift")
        retry = section(plan, "    func retryPhotoCleanup() {", "    private func reconcileOwnedPhotos()")
        self.assertIn("AppRecordDataset.writeLock.lock(); defer { AppRecordDataset.writeLock.unlock() }", retry)
        self.assertIn("reconcileOwnedPhotos()", retry)


class ScreenTextTrimTests(unittest.TestCase):
    """11/8 audit: text the screens do not need, one door per action."""

    def test_messages_carry_no_codes_or_mechanisms(self) -> None:
        lines = source("NekoWidget/Services/CatCareOutputLines.swift")
        self.assertNotIn("（前にここに書いた内容）", lines)
        offer = source("NekoWidget/Services/MembershipOfferModel.swift")
        self.assertIn('reason = "購入を確かめられませんでした。"', offer)
        for gone in ("同期できませんでした", "読み書き", "サービスに通信"):
            self.assertNotIn(gone, offer)
        for path in ("NekoWidget/Services/ToolPreservation.swift",
                     "NekoWidget/Services/AppRecordPersistence.swift",
                     "NekoWidget/Services/ManagedPreservationCoordinator.swift"):
            self.assertNotIn("確認コード", source(path), path)
        self.assertIn('"途中の片づけを確かめられませんでしたが、記録は残っています。"',
                      source("NekoWidget/Services/ToolPreservation.swift"))
        archive = source("NekoWidget/Services/SeasonalMovieArchiveStore.swift")
        self.assertIn('"これまでのムービーは新しい形式で保存されています。App Storeでアプリを最新にしてください。"', archive)

    def test_photo_screens_say_less(self) -> None:
        for path in ("NekoWidget/Views/OnboardingView.swift", "NekoWidget/Views/ScanStatusView.swift"):
            view = source(path)
            self.assertNotIn("「ツール」右上の設定", view, path)
            self.assertIn("枚あります。", view, path)
        self.assertNotIn("あとからいつでも写真を追加できます。", source("NekoWidget/Views/PhotoPermissionView.swift"))
        self.assertNotIn("お気に入りの写真を表示するには", source("NekoWidget/Views/LikedPhotosView.swift"))
        self.assertNotIn("長押しして「ウィジェットを編集」", source("NekoWidget/Views/CatCareView.swift"))
        onboarding = source("NekoWidget/Views/OnboardingPresentation.swift")
        for gone in ("permissionPrivacyLines", "homePermissionBody", "permissionLimitedAccessNote"):
            self.assertNotIn(gone, onboarding)
        self.assertIn("Text(OnboardingPresentationCopy.purposeBody)", source("NekoWidget/Views/HomeView.swift"))

    def test_album_words(self) -> None:
        album = source("NekoWidget/Views/AlbumPrototypeView.swift")
        self.assertNotIn("作品が届きました。", album)
        self.assertEqual(album.count("作品がとどきました。"), 3)
        self.assertNotIn('"1 年の作品"', album)
        # The test-only reset is compiled out of the product; the keys keep their names.
        guarded = album.split("#if DEBUG || INTERNAL_PRESENTATION\n    /// Test only: the newest finished month", 1)
        self.assertEqual(len(guarded), 2)
        self.assertIn("static func cloudLatestAgain(", guarded[1].split("#endif", 1)[0])
        self.assertIn('static let openedKey = "debug.albumPrototype.opened.v1"', album)
        # 11/10: 「まだ作品はありません」 only with no cat photos; with photos, one
        # line that matches the shelf (this month's arrival, or what a work needs).
        no_work = section(album, "private var noWorkYet: some View {", "/// This year's twelve books")
        self.assertIn("if catPhotos.isEmpty {", no_work)
        self.assertEqual(album.count('"まだ作品はありません"'), 1)
        self.assertIn("if letters.isEmpty && lettersAreFinal { noWorkYet }", album)
        self.assertIn('return "\(month)月の作品は、\(nextMonth)月1日にとどきます。"', album)
        self.assertIn("Calendar(identifier: .gregorian)", section(album, "static func noWorkLine(", "static func cover("))
        self.assertIn('"この月は写真が少なく、作品はありません。"', album)

    def test_one_door_each(self) -> None:
        home = source("NekoWidget/Views/HomeView.swift")
        empty = home.split("private var emptyPhotoState: some View {", 1)[1]
        self.assertNotIn('Button("写真を追加で選ぶ"', empty)
        self.assertIn("LimitedAccessBanner(chooseMorePhotos: chooseMorePhotos)", home)
        liked = source("NekoWidget/Views/LikedPhotosView.swift")
        self.assertIn('if rediscoveryEnabled, navigationTitleText != "この1枚",', liked)
        self.assertEqual(liked.count('.accessibilityIdentifier("photo-browser-same-day")'), 1)
        self.assertEqual(liked.count('.accessibilityIdentifier("cloudy-photo-same-day")'), 1)


class LostCatRoundTwoTests(unittest.TestCase):
    """迷子のとき, round 2 (11/8): offices contacted, 「見つかりました」, the small
    flyer and the story. The rules run in ci/verify-tool-outputs.swift; these
    check that the screens and the renderer use them."""

    def setUp(self) -> None:
        self.model = source("NekoWidget/Services/LostCatIncident.swift")
        self.store = source("NekoWidget/Services/CatPreparednessStore.swift")
        self.renderer = section(self.store, "enum LostCatFlyerRenderer {", "/// 11/12: the gap between the two photos.")
        self.view = source("NekoWidget/Views/CatPreparednessView.swift")
        self.form = section(self.view, "struct LostCatDraftView: View {", "    // MARK: Rows (11/12)")
        self.editor = section(self.view, "struct LostCatDraftView: View {", "private struct LostCatPhotoChoiceView")
        self.guide = section(self.view, "private struct LostCatGuideView<Report: View>: View {", "#if DEBUG")
        self.found = section(self.view, "private struct LostCatFoundView: View {", "#if DEBUG")
        self.verify = source("ci/verify-tool-outputs.swift")

    def test_logic_is_run_in_ci_and_built_into_the_app(self) -> None:
        for name in ("lostCatOldDraftDecodes", "lostCatContactedOffices", "lostCatFoundPost",
                     "lostCatEndingKeepsTheCat", "lostCatOutputSizes"):
            self.assertIn("try %s()" % name, self.verify)
            self.assertIn("static func %s() throws" % name, self.verify)
        checks = source("ci/run-quick-ios-checks.sh")
        tool_outputs = section(checks, "NekoWidget/Services/CatCareCore.swift NekoWidget/Services/CareHandoffPlan.swift", '"$RUNNER_TEMP/tool-output-tests"\n')
        self.assertIn("NekoWidget/Services/LostCatIncident.swift", tool_outputs)
        # Foundation only, so it compiles on macOS without UIKit.
        self.assertNotIn("import UIKit", self.model)
        self.assertNotIn("import SwiftUI", self.model)
        project = source("NekoWidget.xcodeproj/project.pbxproj")
        self.assertIn("C10811090000000000000001 /* LostCatIncident.swift in Sources */,", project)
        self.assertIn("path = LostCatIncident.swift;", project)
        # The draft moved here; it is defined once.
        self.assertIn("struct LostCatDraft: Codable, Equatable {", self.model)
        self.assertNotIn("struct LostCatDraft:", self.store)

    def test_saved_drafts_stay_readable(self) -> None:
        draft = section(self.model, "struct LostCatDraft: Codable, Equatable {", "/// The offices step 2")
        self.assertIn("static let schemaVersion = 1", draft)
        self.assertIn("var incident: LostCatIncidentLog? = nil", draft)
        log = section(self.model, "struct LostCatIncidentLog: Codable, Equatable, Sendable {", "enum LostCatText {")
        for field in ("var contactedOffices: [LostCatContactedOffice]? = nil", "var nextCheckAt: Date? = nil",
                      "var foundMessage: String? = nil"):
            self.assertIn(field, log)
        self.assertNotIn("init(from decoder", self.model)
        # The readable backup names every new field in Japanese, and the offices as words.
        readable = source("NekoWidget/Services/ReadablePreservationExport.swift")
        for key in ("incident", "contactedOffices", "office", "contactedAt", "nextCheckAt", "foundMessage"):
            self.assertIn(f'"{key}": "', readable)
        self.assertIn('"lastCheckedAt", "contactedAt", "nextCheckAt"].contains(key)', readable)
        for code, word in (("animalCenter", "動物愛護センター"), ("healthCenter", "保健所"), ("police", "警察"), ("nearbyVet", "近くの動物病院")):
            self.assertIn(f'"{code}": "{word}"', readable)
            self.assertIn(f'return "{word}"', self.model)

    def test_offices_are_marked_in_step_two_of_the_guide(self) -> None:
        step2 = section(self.guide, 'Section("2  届け出て、保護されていないか確かめる")', 'Section("3  写真で周囲に知らせる")')
        self.assertIn('Section("連絡したところ") {', step2)
        self.assertIn("ForEach(LostCatOffice.allCases) { office in officeRow(office) }", step2)
        self.assertIn("nextCheckRow", step2)
        self.assertIn(".disabled(!editable)", step2)
        self.assertLess(step2.index('Section("連絡したところ")'), step2.index("report()"))
        row = section(self.guide, "private func officeRow(", "@ViewBuilder private var nextCheckRow")
        self.assertIn("log.setContacted(office, on: day == nil ? Date() : nil, now: Date())", row)
        self.assertIn('DatePicker("連絡した日"', row)
        self.assertIn("in: ...Date(), displayedComponents: .date", row)
        nxt = section(self.guide, "@ViewBuilder private var nextCheckRow", "\n}\n")
        self.assertIn('DatePicker("次に確かめる日"', nxt)
        self.assertIn("log.nextCheckAt = nil", nxt)
        self.assertIn('Button("次に確かめる日を決める（任意）") { log.nextCheckAt = LostCatIncidentLog.nextDay(after: Date()) }', nxt)
        # Saved with the draft through the page's own autosave.
        self.assertIn("@Binding var log: LostCatIncidentLog", self.guide)
        self.assertIn("LostCatGuideView(log: $draft.incidentLog, editable: loaded) { reportSection }", self.editor)
        # One line on the guide row.
        self.assertIn("let state = loaded ? draft.incident?.stateLine(now: Date()) : nil", self.form)
        self.assertIn("if let state {", self.form)
        self.assertIn('.accessibilityValue(state ?? "")', self.form)
        self.assertIn('parts.append("連絡済み \\(contactedCount)/\\(LostCatOffice.allCases.count)")', self.model)
        self.assertIn('parts.append("次に確かめる日 \\(day)")', self.model)

    def test_found_is_quiet_and_never_deletes_by_itself(self) -> None:
        entry = section(self.form, "if loaded, draft.hasIncident {", "if saveError {")
        self.assertIn("Button { openFound() } label: {", entry)
        self.assertIn('.accessibilityIdentifier("lost-cat-found")', entry)
        for loud in ("role: .destructive", ".red", ".borderedProminent"):
            self.assertNotIn(loud, entry)
        self.assertIn("LostCatFoundView(name: publicName, faceImage: faceImage,", self.editor)
        self.assertIn("message: $draft.foundMessage, end: endIncident)", self.editor)
        end = section(self.editor, "private func endIncident() {", "private func openPreview() {")
        self.assertIn("draft = draft.endingIncident()", end)
        self.assertIn("saveNow()", end)
        for gone in ("store.delete", "removePhoto", "faceFileName", "bodyFileName"):
            self.assertNotIn(gone, end)
        ending = section(self.model, "func endingIncident() -> LostCatDraft {", "\n    }\n")
        self.assertIn('next.lastSeenNear = ""', ending)
        self.assertIn("next.lastSeenAt = nil", ending)
        self.assertIn("next.incident = nil", ending)
        for kept in ("faceFileName", "bodyFileName", "features", "name", "contact"):
            self.assertNotIn("next.%s" % kept, ending)
        # Ending is offered in the flow and asks first.
        self.assertIn('Button("この迷子の記録を終える") { confirmsEnd = true }', self.found)
        self.assertEqual(self.found.count("end()"), 1)
        dialog = section(self.found, '.confirmationDialog("この迷子の記録を終えますか？"', "\n    }\n}")
        self.assertIn('Button("記録を終える", role: .destructive) { end() }', dialog)
        self.assertIn('Text("場所・日時・連絡したところを消します。写真と特徴は残ります。")', dialog)

    def test_found_image_post_and_take_down_line(self) -> None:
        self.assertIn('.navigationTitle(LostCatText.foundTitle)', self.found)
        # 11/11: the input pages' bottom bar, still hidden while the message is typed.
        self.assertRegex(self.found, r"if !editing \{\s*ToolMakeBar\(top: \{")
        self.assertIn('Label("保存・共有する", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)', self.found)
        self.assertIn("share = LostCatFoundShare(url: url, text: found.post)", self.found)
        self.assertIn(".disabled(issue != nil)", self.found)
        # The reminder only after a share or save finished.
        self.assertIn("LostCatActivitySheet(items: item.items) { completed in if completed { shared = true } }", self.found)
        self.assertIn("if shared {", self.found)
        self.assertIn("Label(LostCatText.takeDownFlyers", self.found)
        self.assertIn("controller.completionWithItemsHandler = { _, completed, _, _ in finished(completed) }", self.view)
        self.assertIn("LostCatFlyerRenderer.removeExport(url)", self.found)
        self.assertIn('static let takeDownFlyers = "貼ったチラシをはがしに行きましょう"', self.model)
        self.assertIn('Text("ひとこと（任意）")', self.found)
        # The frame of the SNS image: green band, face, name, thanks, message. No contact, place or day.
        layout = section(self.renderer, "private static func foundLayout(", "private static func drawFound(")
        self.assertIn("let canvas = socialSize", layout)
        self.assertIn("LostCatText.foundTitle, size: 78, weight: .black", layout)
        self.assertIn("LostCatText.foundThanks", layout)
        # The found frame only reads its own draft, which has no contact, place or day.
        self.assertIn("contactBackground: .zero", layout)
        self.assertNotIn("draft.", layout)
        for private in ("contactValue", "lastSeen", "features", "collar"):
            self.assertNotIn(private, layout)
        found_draft = section(self.store, "struct LostCatFoundDraft {", "enum LostCatFlyerRenderer {")
        for private in ("contact", "lastSeen", "features"):
            self.assertNotIn(private, found_draft)
        draw = section(self.renderer, "private static func drawFound(", "\n    }\n")
        self.assertIn("UIColor(red: 0.10, green: 0.52, blue: 0.27, alpha: 1).setFill()", draw)
        self.assertIn("context.fill(plan.titleBand)", draw)
        self.assertIn('static let foundTitle = "見つかりました"', self.model)
        self.assertIn('static let foundThanks = "ご協力ありがとうございました"', self.model)
        self.assertIn("parts.append(hashtags)", section(self.model, "static func foundPost(", "\n    }\n"))
        create = section(self.renderer, "static func createFoundImage(", "private enum ProtectionVerification")
        self.assertIn("guard found.faceImage != nil, foundIssue(found) == nil,", create)
        self.assertIn("return try writeExport(data, fileName: LostCatOutput.foundFileName)", create)

    def test_small_flyer_and_story(self) -> None:
        preview = section(self.view, "private struct LostCatPreviewView", "private struct LostCatActivitySheet")
        self.assertIn("ForEach(LostCatOutput.allCases) { Text($0.title).tag($0) }", preview)
        self.assertIn("LostCatFlyerRenderer.create(draft, output: format)", preview)
        self.assertIn("LostCatFlyerRenderer.createFixture(draft, output: format, verify: verify)", preview)
        self.assertIn(".accessibilityIdentifier(format.accessibilityIdentifier)", preview)
        self.assertIn("LostCatFlyerRenderer.previewImage(draft, output: format)", preview)
        create = section(self.renderer, "static func create(_ draft: LostCatPublicDraft, output: LostCatOutput)", "private static func outputData(")
        self.assertIn("case .social: return try createImage(draft)", create)
        self.assertIn("case .paper: return try createPDF(draft)", create)
        data = section(self.renderer, "private static func outputData(", "// MARK: 見つかりました")
        self.assertIn("guard fits(draft, output: output) else { throw CocoaError(.fileWriteUnknown) }", data)
        # The small flyer: photo, name, place and day, the contact large; four on a page.
        small = section(self.renderer, "private static func smallLayout(", "private static func drawSmall(")
        for field in ('id: "name"', 'id: "place"', 'id: "date"', 'id: "contact"'):
            self.assertIn(field, small)
        for left_out in ("features", "collar", "approachAdvice", "bodyImage"):
            self.assertNotIn(left_out, small)
        self.assertIn('id: "contact", maxSize: compact ? 18 : 22, minSize: 16,', small)
        self.assertIn("if !compact { return smallLayout(draft, compact: true) }", small)
        self.assertIn('"\\(LostCatOutput.smallPaper.issueName)に入りきりません。\\(label)を短くしてください。"', small)
        self.assertIn('if contactValue.isEmpty { issues["contact"] =', small)
        self.assertIn('if placeValue.isEmpty { issues["place"] =', small)
        self.assertIn("if let lastSeen = draft.lastSeenDescription {", small)
        draw_small = section(self.renderer, "private static func drawSmall(", "private static func foundLayout(")
        self.assertIn("for cell in LostCatSmallFlyer.cells(page: paperSize) {", draw_small)
        self.assertIn("context.translateBy(x: cell.minX, y: cell.minY)", draw_small)
        self.assertIn("context.setLineDash(phase: 0, lengths: [4, 4])", draw_small)
        self.assertIn("if format == .smallPaper { drawSmall(draft, context: context); return }", self.store)
        self.assertIn("if output == .smallPaper { return smallLayout(draft).1 }", self.renderer)
        # The story: the SNS layout, more room for the photo, clear of Instagram's bars.
        self.assertIn("let insets = format.safeInsets", self.store)
        self.assertIn("let titleBand = CGRect(x: margin, y: margin + insets.top,", self.store)
        self.assertIn("var bottom = canvas.height - margin - insets.bottom", self.store)
        self.assertIn(": (compact ? 300 : 455) + (format == .story ? 200 : 0)", self.store)
        self.assertIn('self == .story ? (top: 160, bottom: 200) : (top: 0, bottom: 0)', self.model)
        # Every written file is removed after sharing, and only those.
        self.assertIn("guard LostCatOutput.exportFileNames.contains(file.lastPathComponent) else { return }", self.store)
        self.assertIn('static var exportFileNames: Set<String> { Set(allCases.map(\\.fileName)).union([foundFileName]) }', self.model)
        # The input page measures the SNS image and the A4 only; the others are judged where they are made.
        valid = section(self.renderer, "static func validationIssues(", "/// One output's own issues.")
        self.assertNotIn("story", valid)
        self.assertNotIn("smallPaper", valid)


class IdentifyingPhotosOnePlace1109Tests(unittest.TestCase):
    """11/9 (ツール見直し 6, 2 回目「共通」): 見分ける写真 are chosen once, in
    「この子のこと」; 迷子・避難・預ける show them and open 「この子のこと」 to change
    them. The rules run in ci/verify-cat-care.swift and ci/verify-tool-outputs.swift;
    these check that the screens, outputs and stores use them."""

    def setUp(self) -> None:
        self.cat_care = source("NekoWidget/Views/CatCareView.swift")
        self.store = source("NekoWidget/Services/CatCareStore.swift")
        self.core = source("NekoWidget/Services/CatCareCore.swift")
        self.lines = source("NekoWidget/Services/CatCareOutputLines.swift")
        self.lost = source("NekoWidget/Views/CatPreparednessView.swift")
        self.evacuation = source("NekoWidget/Views/EvacuationPreparationView.swift")
        self.care = source("NekoWidget/Views/CareHandoffView.swift")
        self.evacuation_store = source("NekoWidget/Services/EvacuationStore.swift")
        self.care_store = source("NekoWidget/Services/CareHandoffStore.swift")

    def test_the_rules_run_in_ci(self) -> None:
        self.assertIn("try identifyingPhotos()", source("ci/verify-cat-care.swift"))
        self.assertIn("try identifyingPhotosMoveToCatCare()", source("ci/verify-tool-outputs.swift"))
        checks = source("ci/run-quick-ios-checks.sh")
        self.assertIn("NekoWidget/Services/CatCareCore.swift ci/verify-cat-care.swift", checks)
        self.assertIn("NekoWidget/Services/LostCatIncident.swift \\\n  ci/verify-tool-outputs.swift", checks)
        self.assertIn('static let adoptionOrder = ["LostCat", "Evacuation", "CareHandoff"]', self.core)

    def test_chosen_in_cat_care_open_on_the_page(self) -> None:
        detail = section(self.cat_care, "struct CatCareDetailView: View {", "/// A written item of 「この子のこと」")
        body = detail[detail.index("    var body: some View {"):]
        # Open, before the four parts, so a tool's link lands on them.
        self.assertLess(body.index("identifyingPhotosSection"), body.index("basicsSection"))
        photos = section(detail, "private var identifyingPhotosSection: some View {", "private func crop(")
        self.assertIn("ForEach(CatCarePhotoRole.allCases) { role in", photos)
        self.assertIn("ToolPhotoSlot(title, image: nil, file: file,", photos)
        self.assertIn('Button("写真を選び直す", systemImage: "photo")', photos)
        self.assertIn('Button("切り取る", systemImage: "crop")', photos)
        # Taking one off sits in the slot's menu (349), and is saved as an answer.
        self.assertIn('Button("\\(title)を外す", systemImage: "minus.circle", role: .destructive) {\n'
                      '                            setPhoto(nil, role)', photos)
        self.assertIn('header: {\n            Text("見分ける写真")', photos)
        self.assertIn('static func photoTitle(_ role: CatCarePhotoRole) -> String { role == .face ? "顔の写真" : "全身の写真" }',
                      detail)
        save = section(detail, "private func setPhoto(", "/// The same count as the ring")
        self.assertIn("let saved = store.setIdentifyingPhoto(ref, role, catID: catID)", save)
        store_write = section(self.cat_care, "func setIdentifyingPhoto(_ ref: CatCarePhotoRef?, _ role: CatCarePhotoRole, catID: UUID) -> Bool {",
                              "/// Choosing one 見分ける写真")
        self.assertIn("state.cats[index].setIdentifyingPhoto(role, ref, editedAt: Date(), editedBy: state.deviceID)", store_write)
        # 11/11: one chooser, the same from 「この子のこと」 and from a tool, and
        # one record lookup, the same as the page's own load.
        self.assertIn("CatCareIdentifyingPhotoSheet(subject: subject, role: role) { photoFailed = !$0 }", detail)
        self.assertIn("guard let record = store.ensureRecord(for: subject) else { catID = nil; return }", detail)
        sheet = section(self.cat_care, "struct CatCareIdentifyingPhotoSheet: View {",
                        "private struct CatCareIdentifyingPhotoPicker: View {")
        self.assertIn("CatCareIdentifyingPhotoPicker(title: CatCareDetailView.photoTitle(role), photos: Self.photos(subject))", sheet)
        self.assertIn("return profile.confirmedPhotos + profile.manualCandidatePhotos", sheet)
        # A chosen or cropped photo is a clean copy kept by 「この子のこと」.
        self.assertIn("guard let ref = store.savePhoto(jpeg, sourceAssetID: assetID, origin: .photos) else { return false }",
                      sheet)
        self.assertIn("guard let catID = store.ensureRecord(for: subject)?.catID else { onSaved(false); return false }", sheet)
        self.assertIn("let saved = store.setIdentifyingPhoto(ref, role, catID: catID)", sheet)
        self.assertIn("LostCatPhotoCropView(image: request.image) { data in", detail)
        self.assertIn("guard let jpeg = CatCareFormat.cleanJPEG(data),", detail)
        picker = section(self.cat_care, "private struct CatCareIdentifyingPhotoPicker: View {", "/// ② of every tool:")
        self.assertIn("PhotosPicker(selection: $item, matching: .images)", picker)
        self.assertIn("finish(data.flatMap { CatCareFormat.cleanJPEG($0) }, assetID: value.itemIdentifier)", picker)
        self.assertIn(".announcesWhenShown(error)", picker)
        self.assertIn("|| photoRole != nil || cropRequest != nil)", detail)

    def test_tools_show_them_and_open_cat_care(self) -> None:
        shared = section(self.cat_care, "struct ToolIdentifyingPhotos: View {", "extension ToolMakeBar where Top == EmptyView {")
        # 11/11: a photo in a tool opens the same chooser as 「この子のこと」, and the
        # choice is kept there; one quiet link opens 「この子のこと」 for the rest.
        self.assertIn("ToolIdentifyingPhotoChoice(faceFile: faceFile, bodyFile: bodyFile, subject: subject, profiles: profiles,",
                      shared)
        self.assertIn("NavigationLink { CatCareSubjectView(subject: subject, profiles: profiles) } label: {\n"
                      '            Text("「この子のこと」を開く").font(.footnote)', shared)
        self.assertIn('.accessibilityIdentifier(identifier + "-open-cat-care")', shared)
        self.assertNotIn("「この子のこと」で変える", shared)
        self.assertIn("CatCareIdentifyingPhotoSheet(subject: subject, role: role)", shared)
        self.assertIn("ToolPhotoSlot(choosing: CatCareDetailView.photoTitle(role), file: file, disabled: !store.canSave,", shared)
        self.assertIn("identifier: identifier, choose: { photoRole = role })", shared)
        self.assertIn('slot(.face, file: faceFile, identifier: identifier + "-face")', shared)
        self.assertIn('slot(.body, file: bodyFile, identifier: identifier + "-body")', shared)
        # No picker or crop of its own in a tool: the shared sheet only.
        self.assertNotIn("PhotosPicker", shared)
        self.assertNotIn("LostCatPhotoCropView", shared)
        self.assertNotIn("savePhoto(", shared)
        slot = section(self.cat_care, "struct ToolPhotoSlot<Actions: View>: View {", "struct ToolPhotoGrid<Content: View>: View {")
        # Shown only: no button to choose and no menu. Choosing only: no menu.
        self.assertIn("if readOnly {\n                tile\n", slot)
        # The menu sits in the button's branch only, so a read-only slot has none.
        self.assertIn("if hasPhoto && !chooseOnly {\n                        actionsMenu", slot)
        readonly = section(self.cat_care, "extension ToolPhotoSlot where Actions == EmptyView {", "/// 見分ける写真 in a tool: kept")
        self.assertIn("readOnly = true", readonly)
        self.assertIn("chooseOnly = true", readonly)
        # Each tool: 「この子のこと」's photo once set there, else its own older one.
        url = section(self.cat_care, "static func identifyingPhotoURL(", "/// The record for a tool's cat")
        self.assertIn("CatCareIdentifyingPhotos.choice(record?.identifyingPhoto(role), legacy: legacy)", url)
        self.assertIn('ToolIdentifyingPhotos(faceFile: files.face, bodyFile: files.body, subject: catCareSubject,', self.lost)
        self.assertIn("CatCareSummary.identifyingPhotoURL(record, .face, legacy: store.imageURL(draft.faceFileName))", self.lost)
        self.assertIn("CatCareSummary.identifyingPhotoURL(record, .body, legacy: store.imageURL(draft.bodyFileName))", self.lost)
        self.assertIn('identifier: "evacuation-identifying-photos")', self.evacuation)
        self.assertIn('showsBody: false, identifier: "care-photo-open")', self.care)
        # 預ける and 避難 no longer choose a face or body photo themselves.
        self.assertNotIn("CarePhotoPicker", self.care)
        self.assertNotIn("store.replacePhoto(", self.care)
        self.assertIn("ForEach([EvacuationCat.PhotoRole.withOwner]) { role in", self.evacuation)
        self.assertNotIn("EvacuationCat.PhotoRole.allCases", self.evacuation)
        # 迷子: only a cat with no 「この子のこと」 (an unregistered one) chooses here.
        cat_section = section(self.lost, "@ViewBuilder private var photoRows: some View {", "private func loadPicked(")
        self.assertLess(cat_section.index("if let catCareSubject, let files = catCarePhotoFiles {"),
                        cat_section.index('photoTile("顔の写真", role: .face'))
        subject = section(self.lost, "private var catCareSubject: CatCareSubject? {", "/// 「この子のこと」's face and body photos")
        self.assertIn("if let profile = profiles.first(where: { $0.identifier == key }) { return .profile(profile) }", subject)
        self.assertIn("if let catID = LostCatCatCareKey.parse(key)?.catID { return .toolCat(id: catID, name: publicName) }", subject)
        # The flyer follows a photo chosen there; the full photo is read off the drawing.
        self.assertIn(".onChange(of: catCarePhotoKey) { _, _ in readCatCarePhotos() }", self.lost)
        read = section(self.lost, "private func readCatCarePhotos() {", "    private func catCareTarget(for identity: String)")
        self.assertIn("faceImage = face ?? whole", read)
        self.assertIn("bodyImage = face == nil ? nil : whole", read)
        self.assertIn("guard catCareTarget(for: identity) == nil else { return next }", self.lost)

    def test_outputs_read_cat_care(self) -> None:
        care = section(self.care_store, "func shareRecord(_ disclosure: CareHandoffDisclosure)", "private static func normalizedJPEG(")
        self.assertIn("if cat.photoRemoved != true,", care)
        self.assertIn("let url = CatCareSummary.identifyingPhotoURL(care, .face, legacy: imageURL(cat.photoName)) {", care)
        self.assertNotIn("image(name)", care)
        evacuation = section(self.evacuation_store, "func shareRecord(catID: UUID, disclosure: EvacuationDisclosure)",
                             "func bookRecords()")
        self.assertIn("for role in CatCarePhotoRole.allCases {", evacuation)
        self.assertIn("CatCareSummary.identifyingPhotoURL(care, role, legacy: imageURL(cat.legacyIdentifyingPhoto(role)))",
                      evacuation)
        self.assertIn("if disclosure.withOwnerPhoto, let name = cat.photos[EvacuationCat.PhotoRole.withOwner.rawValue] {",
                      evacuation)
        self.assertLess(evacuation.index("for role in CatCarePhotoRole.allCases {"),
                        evacuation.index("if disclosure.withOwnerPhoto"))

    def test_older_photos_are_taken_in_once_and_kept(self) -> None:
        importing = section(self.store, "    func importFromTools() {", "    func importFromTools(\n")
        self.assertIn("adoptToolPhotos()", importing)
        adopt = section(self.store, "    func adoptToolPhotos() {", "    nonisolated static func sources(")
        self.assertIn("CatCareToolPhotos.all(", adopt)
        self.assertIn("lost: lost.drafts,", adopt)
        self.assertIn("guard canSave, let current = state else { return }", adopt)
        self.assertIn("savePhoto(bytes, sourceAssetID: nil, origin: .importedFromTool)", adopt)
        self.assertIn("CatCareIdentifyingPhotos.apply(adoption, ref: ref, to: &state, now: now)", adopt)
        # Nothing of the tools is removed or rewritten by taking a photo in.
        for gone in ("removeValue", "photoName = nil", "faceFileName = nil", "bodyFileName = nil", ".commit(", ".save("):
            self.assertNotIn(gone, adopt)
        # The older fields stay in the saved formats, optional as before.
        self.assertIn("var faceFileName: String?", source("NekoWidget/Services/LostCatIncident.swift"))
        self.assertIn("var bodyFileName: String?", source("NekoWidget/Services/LostCatIncident.swift"))
        self.assertIn("var photos: [String: String] = [:]", source("NekoWidget/Services/EvacuationPlan.swift"))
        self.assertIn("var photoName: String?", source("NekoWidget/Services/CareHandoffPlan.swift"))
        self.assertIn("static let currentSchemaVersion = 1", self.core)
        # The family notebook formats are not touched by this.
        for name in ("CatCareToolPhotos", "identifyingPhoto", "CatCarePhotoRole"):
            for path in ("NekoWidget/Services/FamilyNotebookCatCareBridge.swift",
                         "NekoWidget/Services/FamilyNotebookToolBridge.swift"):
                self.assertNotIn(name, source(path), path)
        # 預ける starts 「この子のこと」 with the cat's key photo only when nothing was set there.
        key_photo = section(self.care, "private static func useKeyPhotoForCatCare(", "\n}\n")
        self.assertIn("return record == nil || record?.facePhoto == nil", key_photo)
        self.assertIn("state.cats[index].facePhoto == nil else { return }", key_photo)
        self.assertIn('editedBy: "import:Profile")', key_photo)


class MemoCaptionOneWayTests(unittest.TestCase):
    """写真のメモ（自分だけ）と、まどのひとことは別の文。行き来させない（11/9）。"""

    def setUp(self) -> None:
        self.screen = source("NekoWidget/Views/GroupWindowView.swift")
        self.browser = source("NekoWidget/Views/LikedPhotosView.swift")
        self.share = source("NekoWidgetShareExtension/GroupShareComposer.swift")
        self.core = source("Shared/Sharing/GroupWindowCore.swift")
        self.memo_page = source("NekoWidget/Views/PhotoMemoryNoteLibraryView.swift")

    def test_the_send_field_never_reads_the_memo(self) -> None:
        for text in (self.screen, self.browser, self.share, self.memo_page):
            self.assertNotIn("メモから入れる", text)
            self.assertNotIn("caption-from-memo", text)
            self.assertNotIn("MemoCaptionBridge", text)
        self.assertFalse((ROOT / "NekoWidget/Services/MemoCaptionBridge.swift").exists())
        field = section(self.screen, "private struct GroupCaptionField: View {", "private struct GroupPhotoDetail: View {")
        self.assertNotIn("PhotoMemoryNoteStore", field)
        self.assertNotIn("text = ", field)
        self.assertEqual(self.screen.count("GroupCaptionField(text: $memo)"), 2)
        self.assertNotIn("GroupCaptionField(text: $memo, photoIdentifier:", self.screen)
        self.assertEqual(self.screen.count('@State private var memo = ""'), 3)

    def test_the_memo_page_sends_its_words_as_the_starting_caption(self) -> None:
        detail = section(self.memo_page, "struct PhotoMemoryNoteDetailView: View {", "struct PhotoMemoryNotePhotoDestination")
        status = section(detail, "} status: {", "} else if loaded {")
        # Only with the photo in the library and まど on this build, like the photo screen.
        self.assertIn("if access.photo(for: record.photoIdentifier) != nil, GroupWindowClientProvider.ui != nil {", status)
        self.assertIn('Button("まどに届ける", systemImage: "paperplane")', status)
        self.assertIn('"memory-note-deliver-group"', status)
        self.assertIn("initialCaption: GroupPhotoCaption.draft(fromMemo: record.note.text))", status)
        # The same delivery sheet (pick step, 届け先 row), starting from the memo's words.
        self.assertIn("GroupLibraryDeliverySheet(client: client, localIdentifier: request.localIdentifier,\n"
                      "                                          initialCaption: request.initialCaption)", detail)
        # Sending from here never writes the memo.
        self.assertNotIn("store.save(", status)
        # The editor stays for writing only: no send button there.
        editor = section(source("NekoWidget/Views/PhotoMemoryNoteView.swift"), "struct PhotoMemoryNoteEditor", "\n}\n")
        self.assertNotIn("まどに届ける", editor)
        self.assertNotIn("GroupLibraryDeliverySheet", editor)
        # The sheet starts from the given words; the photo screen gives none.
        sheet = section(self.screen, "struct GroupLibraryDeliverySheet: View {", "enum GroupLibraryDeliveryMemory {")
        self.assertIn('init(client: any GroupWindowMediaClient, localIdentifier: String, initialCaption: String = "") {', sheet)
        self.assertIn("_memo = State(initialValue: initialCaption)", sheet)
        self.assertIn("GroupLibraryDeliverySheet(client: client, localIdentifier: request.localIdentifier)\n", self.browser)
        self.assertNotIn("initialCaption:", self.browser)
        self.assertIn('var initialCaption = ""', section(self.browser, "struct GroupDeliveryRequest: Identifiable {", "\n}\n"))
        # The cut keeps the ひとこと limits.
        draft = section(self.core, "static func draft(fromMemo memo: String) -> String {", "static func normalized(")
        self.assertIn("maximumCharacters", draft)
        self.assertIn("maximumLineBreaks", draft)
        self.assertIn("validationMessage(for: draft) != nil", draft)

    def test_sending_never_writes_the_memo(self) -> None:
        deliver = section(self.screen, "    func deliver(_ prepared: PreparedPhoto, memo: String) async {",
                          "/// After a failed send:")
        self.assertIn("client.sendPhoto(normalizedJPEG: prepared.jpeg, caption: memo,", deliver)
        self.assertNotIn("PhotoMemoryNoteStore", deliver)
        self.assertNotIn("saveMemo", self.screen)
        self.assertNotIn("MemoKeeping", self.screen)
        # A failed send still keeps its ひとこと for 「もう一度届ける」.
        self.assertIn("FailedDelivery(photo: retry, memo: memo)", deliver)
        self.assertIn("FailedDelivery(photo: prepared, memo: memo, confirmationPhotoID: pending.photoID)", deliver)
        self.assertIn("await deliver(failed.photo, memo: failed.memo)", self.screen)
        self.assertIn('memo: pending.caption ?? "", confirmationPhotoID: pending.confirmationPhotoID)', self.screen)
        # The memo screen no longer reloads after a send: nothing there changed.
        self.assertNotIn("groupDeliverySent", self.browser)
        self.assertNotIn("memoContext", self.screen + self.browser)

    def test_the_field_says_who_sees_it(self) -> None:
        self.assertIn('static let visibilityFooter = "まどのみんなに見えます（\\(maximumCharacters)文字まで）"', self.core)
        field = section(self.screen, "private struct GroupCaptionField: View {", "private struct GroupPhotoDetail: View {")
        self.assertIn('} header: { Text("ひとこと") }', field)
        self.assertIn('TextField("例：おなかを見せて寝ていた", text: $text, axis: .vertical)', field)
        self.assertIn("Text(GroupPhotoCaption.visibilityFooter)", section(field, "footer: {", "\n    }\n"))
        self.assertIn('"group-window-send-caption-footer"', field)
        self.assertIn("GroupPhotoCaption.validationMessage(for: text)", field)
        for old in ("まどのみんなに届きます", "メモにも残ります", "文字・改行"):
            self.assertNotIn(old, self.screen)
        # The share extension says the same, right under its ひとこと field.
        composer = section(self.share, 'TextField("ひとこと", text: $model.caption, axis: .vertical)', 'Button(model.sending')
        self.assertIn("Text(GroupPhotoCaption.visibilityFooter)", composer)
        # The memo button still says the memo is private.
        self.assertIn('.accessibilityHint("自分だけのメモです。相手には送られません")', self.browser)

    def test_a_kept_photo_does_not_copy_the_caption_into_the_memo(self) -> None:
        favorite = section(self.screen, "    func addToFavorites(_ entry: GroupWindowLocalPhotoStore.Entry) async {",
                           "    /// Removes a photo from this iPhone only.")
        self.assertNotIn("PhotoMemoryNoteStore", favorite)
        self.assertNotIn("saveMemo", favorite)
        self.assertNotIn("caption", favorite)
        detail = section(self.screen, "private struct GroupPhotoDetail: View {", "    private func neighbor(of entry:")
        self.assertIn("await model.addToFavorites(current)", detail)
        self.assertIn('Text("写真アプリに保存して、お気に入りに入れます。届けた人には知らせません。")', detail)
        self.assertNotIn("ひとことはメモに残ります", self.screen)

    def test_the_photo_screen_shows_the_received_caption_read_only(self) -> None:
        store = source("NekoWidget/Services/GroupWindowLocalPhotoStore.swift")
        lookup = section(store, "func favoriteEntry(localIdentifier: String)", "\n    }\n")
        # Only photos to show (removed and hidden people left out), matched by the copy's identifier.
        self.assertIn("entries(windowID: window.id)", lookup)
        self.assertIn("!$0.isOwn && $0.favoriteLocalIdentifier == localIdentifier", lookup)
        loader = section(self.browser, "struct GroupFavoriteSource: Equatable {", "struct GroupDeliveryRequest: Identifiable {")
        self.assertIn("GroupWindowLocalPhotoStore.shared.favoriteEntry(localIdentifier: localIdentifier)", loader)
        self.assertIn("GroupDisplayName.from(entry.senderDisplayName)", loader)
        # 11/11: names are self-chosen nicknames, so a まど photo's sender line
        # is 「ママから」 everywhere (app, Widget, favorites, spoken labels).
        cache = source("Shared/Sharing/GroupWidgetCache.swift")
        self.assertIn('static func from(_ name: String) -> String { plain(name) + "から" }', cache)
        for root in ("NekoWidget", "Shared", "NekoWidgetWidget"):
            for path in (ROOT / root).rglob("*.swift"):
                text = path.read_text(encoding="utf-8")
                self.assertIsNone(re.search(r'withSan\([^)]*\)\)?\s*(\+\s*"から"|から(届いた|、|"))', text), str(path))
        # Hidden or reported (or reports that cannot be read): no words.
        self.assertIn(".contains(entry.id) ?? true", loader)
        self.assertIn("let shows = !entry.isHidden && !reported && !words.isEmpty", loader)
        self.assertNotIn("PhotoMemoryNoteStore", loader)
        # Read once per opened photo, and only for photos copied in from a まど.
        task = section(self.browser, "        .task(id: selectedPhotoIdentifier) {\n            // Only photos copied in from a まど",
                       "        .sheet(item: $groupDelivery)")
        self.assertIn("guard receivedPhotoIdentifiers.contains(identifier) else { groupFavoriteSource = nil; return }", task)
        self.assertIn("if groupFavoriteSource?.localIdentifier == identifier { return }", task)
        self.assertIn("await GroupFavoriteSource.load(localIdentifier: identifier)", task)
        self.assertIn("guard !Task.isCancelled, identifier == selectedPhotoIdentifier else { return }", task)
        # Shown under the photo: 「○○から」, then the ひとこと in secondary style. No button, no editing.
        footer = section(self.browser, "    private var browserFooter: some View {", "    private func quickActions(")
        self.assertLess(footer.index("groupFavoriteSourceView(source)"), footer.index("quickActions(selectedPhoto)"))
        self.assertIn("source.localIdentifier == selectedPhoto.localIdentifier", footer)
        view = section(self.browser, "private func groupFavoriteSourceView(_ source: GroupFavoriteSource) -> some View {",
                       "/// The three things people do with a photo")
        self.assertLess(view.index("Text(source.senderLabel)"), view.index("Text(caption)"))
        self.assertIn(".foregroundStyle(.secondary)", view)
        self.assertIn('"photo-browser-group-source"', view)
        for editable in ("Button", "TextField", "onTapGesture", "personalNote"):
            self.assertNotIn(editable, view)

    def test_destination_row_goes_back_to_the_pick_list_keeping_the_words(self) -> None:
        sheet = section(self.screen, "struct GroupLibraryDeliverySheet: View {", "enum GroupLibraryDeliveryMemory {")
        # The pick step stays; it is skipped only with exactly one open まど.
        # 11/10: also from the last list while it reads again (one helper for both).
        choose = section(sheet, "private func chooseOnlyWindow() {", "var body: some View {")
        self.assertIn("if openWindows.count == 1 {\n            let only = openWindows[0].id\n"
                      "            if screen?.windowID != only { screen = GroupWindowScreenModel(", choose)
        self.assertIn("} else if screen != nil {\n            screen = nil", choose)
        self.assertIn("NavigationLink(value: window.id) {", sheet)
        # The ひとこと belongs to the sheet, so going back to the list keeps it.
        self.assertIn("NavigationStack(path: $path) {", sheet)
        self.assertIn('@State private var memo = ""', sheet)
        self.assertIn("GroupLibraryDeliveryStep(model: screen, localIdentifier: localIdentifier, memo: $memo)", sheet)
        self.assertIn("localIdentifier: localIdentifier, memo: $memo,", section(
            sheet, ".navigationDestination(for: String.self) { windowID in", ".navigationTitle("))
        # 「届け先」 only with 2 or more まど, and it only empties the path (no reset of the words).
        self.assertIn("changeWindow: openWindows.count > 1 ? { path.removeAll() } : nil)", sheet)
        self.assertNotIn('memo = ""\n', sheet.replace('@State private var memo = ""\n', ""))
        step = section(self.screen, "private struct GroupLibraryDeliveryStep: View {", "private struct GroupLibraryDeliveryChosenWindow: View {")
        self.assertIn("@Binding var memo: String", step)
        self.assertNotIn("@State private var memo", step)
        form = section(step, "} else if let prepared {\n                Form {", "GroupCaptionField(text: $memo")
        self.assertIn("if let changeWindow, let name = model.window?.name {", form)
        self.assertIn('Text("届け先")', form)
        self.assertIn("Text(name)", form)
        self.assertIn('Image(systemName: "chevron.right")', form)
        self.assertIn("Button(action: changeWindow)", form)
        self.assertIn('"group-library-delivery-destination"', form)
        # The row comes first, above the photo.
        self.assertLess(form.index('Text("届け先")'), form.index('.accessibilityLabel("届ける写真")'))
        chosen = section(self.screen, "private struct GroupLibraryDeliveryChosenWindow: View {", "/// Shown after a photo is picked")
        self.assertIn("pushed: true, changeWindow: changeWindow, close: close)", chosen)
        self.assertIn("@Binding var memo: String", chosen)
        # The last まど chosen is only a highlight, kept in memory (no UserDefaults).
        memory = section(self.screen, "enum GroupLibraryDeliveryMemory {", "\n}\n")
        self.assertIn("static var lastWindowID: String?", memory)
        self.assertIn("_highlightedWindowID = State(initialValue: GroupLibraryDeliveryMemory.lastWindowID)", sheet)
        self.assertIn("GroupLibraryDeliveryMemory.lastWindowID = windowID", sheet)
        self.assertIn(".listRowBackground(last ? Color.accentColor.opacity(0.12) : nil)", sheet)
        self.assertNotIn("UserDefaults", sheet + memory)
        # One entry: the detail's 「まどに届ける」 opens the same delivery sheet.
        self.assertEqual(self.browser.count("GroupLibraryDeliverySheet("), 1)

    def test_the_footer_rule_is_checked_in_ci_and_the_bridge_is_gone(self) -> None:
        project = source("NekoWidget.xcodeproj/project.pbxproj")
        self.assertNotIn("MemoCaptionBridge", project)
        quick = source("ci/run-quick-ios-checks.sh")
        self.assertNotIn("MemoCaptionBridge", quick)
        compile_line = section(quick, "Shared/Sharing/GroupWindowCore.swift \\\n  NekoWidget/Services/GroupWindowContract.swift \\\n",
                               '-o "$RUNNER_TEMP/group-window-tests"')
        self.assertIn("ci/verify-group-windows.swift", compile_line)
        verify = source("ci/verify-group-windows.swift")
        self.assertIn("try checkCaptionVisibilityFooter()", verify)
        self.assertIn("Caption.draft(fromMemo:", verify)
        self.assertIn('GroupPhotoCaption.visibilityFooter == "まどのみんなに見えます（100文字まで）"', verify)
        self.assertNotIn("MemoCaptionBridge", verify)


class PresubmitFixes1110Tests(unittest.TestCase):
    """11/10 通し点検: the small fixes before submission."""

    def test_plus_values_name_the_family_notebook(self) -> None:
        offer = source("NekoWidget/Views/MembershipOfferView.swift")
        values = section(offer, "static let values = [", "    ]\n")
        rows = ['("まどを作って、家族と写真を届け合う", "person.2")',
                '("家族の手帳を作って、家族と一緒に書く", "book.closed")',
                '("猫のこと・メモ・ツールの記録を保存して、新しいiPhoneに戻せる", "icloud")']
        for row in rows:
            self.assertIn(row, values)
        # 11/11: the daily Widget photo is free; 11/13: a new memo too. Exactly these four rows.
        self.assertEqual(
            re.findall(r'\("([^"]+)", "[^"]+"\)', values),
            ["月の作品、季節のムービー",
             "まどを作って、家族と写真を届け合う", "家族の手帳を作って、家族と一緒に書く",
             "猫のこと・メモ・ツールの記録を保存して、新しいiPhoneに戻せる"])
        self.assertLess(values.index(rows[0]), values.index(rows[1]))
        self.assertLess(values.index(rows[1]), values.index(rows[2]))

    def test_new_memo_reason_promises_free_days_only_from_storekit(self) -> None:
        model = source("NekoWidget/Services/MembershipOfferModel.swift")
        # 11/12 (review 5): the benefit first; the free days are the button's
        # words only (StoreKit's), never repeated in the reason.
        # 11/13: a new memo is free, so no Plus reason names it.
        self.assertNotIn("case .newMemo", model)
        self.assertNotIn("メモを書くのはPlus", model)
        self.assertNotIn("新しいメモはPlusで書けます", model)
        self.assertNotIn("func reason(trialPeriod:", model)
        self.assertNotIn("は無料です。", model)
        monthly = section(model, "static func monthly(", "enum MembershipRestoreFailure")
        no_trial = section(monthly, "guard let trialPeriod else {", "\n        }\n")
        self.assertNotIn("trialPeriod:", no_trial)
        self.assertIn("trialPeriod: trialPeriod)", monthly)
        offer = source("NekoWidget/Views/MembershipOfferView.swift")
        self.assertIn("if let reason = reasonOverride ?? context.reason {", offer)
        self.assertNotIn("trialPeriod", section(offer, "    private var photoHeader: some View {", "    private static func photoBox"))
        note = source("NekoWidget/Views/PhotoMemoryNoteView.swift")
        self.assertNotIn("メモを書くのはPlusの機能です", note)
        self.assertNotIn(".createPersonalMemo", note)
        self.assertNotIn("PlusOfferPrompt", note)

    def test_family_notebook_test_tools_are_compiled_out(self) -> None:
        notebook = source("NekoWidget/Views/FamilyNotebookView.swift")
        gate = "#if DEBUG || INTERNAL_PRESENTATION"
        for marker in ('DisclosureGroup("テスト用")', 'Button("招待を受けたときを試す（テスト用）")',
                       "return { triesInvitation = true }"):
            at = notebook.index(marker)
            opened = notebook.rindex(gate, 0, at)
            self.assertNotIn("#endif", notebook[opened:at], marker)
            self.assertIn("#endif", notebook[at:], marker)
        action = section(notebook, "private var prototypeInvitationAction:", "@ToolbarContentBuilder")
        self.assertIn("#else\n        return nil\n#endif", action)

    def test_limits_and_waiting_purchase_say_what_happens(self) -> None:
        setup = source("NekoWidget/Views/GroupWindowSetupView.swift")
        self.assertIn("static let ownedWindowLimit = 5", setup)
        self.assertIn('return "自分で作れるまどは\\(ownedWindowLimit)つまでです。"', setup)
        migration = source("SharingService/migrations/0063_group_environment_policy.sql")
        self.assertIn("role='owner' AND state='active')>5", migration)
        model = source("NekoWidget/Services/MembershipOfferModel.swift")
        auto = "\\nApp Store で手続きが終わると、自動で使えるようになります。"
        state = section(model, "        } else if isWaiting {", "        } else {\n            purchaseTitle = nil")
        self.assertIn("もう一度購入しないでください。" + auto + '"', state)
        self.assertIn("お支払い方法を確認してください。" + auto + '"', state)
        checking = state[state.index("} else if verificationRequired {"):]
        self.assertNotIn(auto, checking)
        # The server-side check is waited out with 「購入を復元」, not automatically.
        self.assertIn('もう一度購入せずに、「購入を復元」を押してください。"', state)
        self.assertEqual(model.count(auto), 3)

    def test_showcase_without_recommendation_offers_picking(self) -> None:
        showcase = source("NekoWidget/Views/ShowcasePhotoView.swift")
        failed = section(showcase, "} else if failedScopes.contains(scopeID) {", '"showcase-gallery-select"')
        self.assertIn('ContentUnavailableView("猫の写真が見つかると、おすすめを出します", systemImage: "photo")', failed)
        self.assertIn('Button("写真を選ぶ") { showsPreparation = true }', failed)
        self.assertNotIn('"おすすめで選べませんでした"', showcase)

class DesignPolish1111Tests(unittest.TestCase):
    """デザインと UI の点検 (11/11): what the fixes must keep."""

    def test_widget_photo_stays_full_color_on_tinted_home_screens(self) -> None:
        widget = source("NekoWidgetWidget/NekoWidgetView.swift")
        photo = section(widget, "    private var photoContent: some View {", ".id(entry.cacheFilename)")
        self.assertIn("Image(uiImage: image)", photo)
        self.assertLess(photo.index("Image(uiImage: image)"), photo.index(".widgetFullColorPhoto()"))
        self.assertLess(photo.index(".widgetFullColorPhoto()"), photo.index(".scaledToFill()"))
        helper = section(widget, "@ViewBuilder func widgetFullColorPhoto() -> some View {", "\n    }\n")
        self.assertIn("if #available(iOS 18.0, *) {", helper)
        self.assertIn("self.widgetAccentedRenderingMode(.fullColor)", helper)
        # Every photo drawn by a Widget goes through it.
        for name in ("NekoWidgetView.swift", "ShowcaseWidget.swift"):
            text = source(f"NekoWidgetWidget/{name}")
            self.assertEqual(text.count("Image(uiImage:"), text.count(".widgetFullColorPhoto()"), name)
        # 「もう一枚」 is not the app's 「読み込み直す」 symbol.
        mark = section(widget, "private func dailyPersonalPhotoMark(isUsed: Bool) -> some View {", ".frame(width: 44, height: 44)")
        self.assertIn('isUsed ? "checkmark" : "shuffle"', mark)
        self.assertNotIn('"arrow.clockwise"', mark)

    def test_group_photo_tile_keeps_the_photo_shape_within_three_four_and_four_three(self) -> None:
        screen = source("NekoWidget/Views/GroupWindowView.swift")
        tile = section(screen, "private struct GroupPhotoTile: View {", "    var body: some View {")
        self.assertIn("GroupPhotoTileShape.clamped(image.size)", tile)
        self.assertIn("GroupPhotoTileShape.remembered[entry.id] ?? GroupPhotoTileShape.wide", tile)
        shape = section(screen, "enum GroupPhotoTileShape {", "private struct GroupPhotoTile: View {")
        self.assertIn("static let wide: CGFloat = 4.0 / 3.0", shape)
        self.assertIn("static let tall: CGFloat = 3.0 / 4.0", shape)
        self.assertIn("return min(max(size.width / size.height, tall), wide)", shape)
        body = section(screen, "private struct GroupPhotoTile: View {", "\n}\n")
        self.assertIn(".aspectRatio(tileAspectRatio, contentMode: .fit)", body)
        self.assertNotIn("aspectRatio(4 / 3", body)
        # In memory only: the saved photo index is unchanged.
        store = source("NekoWidget/Services/GroupWindowLocalPhotoStore.swift")
        entry = section(store, "struct Entry: Codable", "\n    }\n")
        self.assertNotIn("aspect", entry.lower())
        self.assertNotIn("UserDefaults", shape)
        # The list's heart is filled only for this iPhone's own heart.
        self.assertIn('Image(systemName: mine ? "heart.fill" : "heart")', body)
        self.assertNotIn("|| heartCount > 0 ? \"heart.fill\"", body)

    def test_photo_tab_cards_keep_the_screen_margin(self) -> None:
        home = source("NekoWidget/Views/HomeView.swift")
        self.assertIn("private var cardMargin: CGFloat { isEmbedded ? NekoSpacing.screenMargin : 0 }", home)
        tokens = source("NekoWidget/Views/DesignTokens.swift")
        self.assertIn("static let screenMargin: CGFloat = 16", tokens)
        body = section(home, "    var body: some View {", ".accessibilityIdentifier(\"photo-library-all-scroll\")")
        for card in ("LimitedAccessBanner(chooseMorePhotos: chooseMorePhotos)", "photoSourceRecoveryLink",
                     "widgetPlacementCard", "emptyPhotoState", "photoAccessCard"):
            after = body[body.index(card):]
            self.assertTrue(after.split("\n", 2)[1].strip() == ".padding(.horizontal, cardMargin)", card)
        # The grid itself still runs edge to edge in the tab.
        self.assertIn(".padding(.horizontal, isEmbedded ? 0 : 16)", body)
        # The banner's button is at least 44pt tall.
        banner = section(source("NekoWidget/Views/PhotoPermissionView.swift"), "struct LimitedAccessBanner: View {", "\n}\n")
        self.assertIn('Button("写真を追加で選ぶ", action: chooseMorePhotos)\n                .font(.subheadline.weight(.semibold))\n                .frame(minHeight: 44)', banner)

    def test_photo_tab_reaches_the_first_photo_sooner(self) -> None:
        main = source("NekoWidget/Views/MainTabView.swift")
        library = section(main, "private var photoLibrary: some View {", "private var albumRoot: some View {")
        self.assertIn("photoLibraryCatRow", library)
        row = section(main, "private struct PhotoLibraryCatRow<", "private struct PhotoThemeTile: View {")
        for part in ("picker()", '.accessibilityIdentifier("photo-hub-detected-grid")', "PhotoLibraryMonthJumpMenu(", "addPhotos()"):
            self.assertIn(part, row)
        # The count and 日付 belong to すべて only.
        self.assertIn("photoLibrarySelection.selection == .all && hasPhotoAccess ? photoLibraryCatPhotos : []",
                      section(main, "private var photoLibraryCatRow: some View {", "private var photoLibraryCatPicker: some View {"))
        self.assertIn("tabRowMonthJump: catProfilesPresentation.profiles.isEmpty ? nil : $photoLibraryMonthJump", main)
        home = source("NekoWidget/Views/HomeView.swift")
        self.assertIn("if tabRowMonthJump == nil {", section(home, "@ViewBuilder private var detectedPhotosSection: some View {",
                                                             '.id("photo-library-all-heading")'))
        # Themes: 64pt photos with the name under the photo (11/12), capped for large text.
        tile = section(main, "private struct PhotoThemeTile: View {", "\n}\n")
        self.assertIn(".frame(width: 64, height: 64)", tile)
        self.assertIn(".dynamicTypeSize(...DynamicTypeSize.xLarge)", tile)
        self.assertNotIn(".overlay(alignment: .bottomLeading)", tile)
        self.assertNotIn("frame(width: 88", main)
        # MainTabView.body stays small: the row and tile are their own views.
        self.assertNotIn("PhotoLibraryCatRow(", section(main, "    var body: some View {", "    private var photoLibrary: some View {"))

    def test_grouped_cards_and_empty_states(self) -> None:
        home = source("NekoWidget/Views/HomeView.swift")
        self.assertNotIn("secondarySystemBackground", home)
        empty = section(home, "private var emptyPhotoState: some View {", "\n    }\n\n}")
        self.assertNotIn(".background(", empty)
        for relative in ("NekoWidget/Views/ScanStatusView.swift",):
            self.assertNotIn("Color(.secondarySystemBackground)", source(relative))
        liked = source("NekoWidget/Views/LikedPhotosView.swift")
        card = section(liked, "private struct CuratedAlbumCard: View {", "struct CuratedAlbumDetailView: View {")
        self.assertIn(".background(NekoPalette.groupedCard)", card)
        # Favorites answer like the まど heart, only when one is added.
        quick = section(liked, "private func quickActions(_ photo: PhotoPresentation) -> some View {", 'quickAction("square.and.pencil"')
        self.assertLess(quick.index("favoriteAddedTaps += 1"), quick.index("setMemorySaved(photo.localIdentifier, true)"))
        self.assertIn(".symbolEffect(.bounce, value: favoriteAddedTaps)", liked)
        self.assertIn(".sensoryFeedback(.impact(weight: .light), trigger: favoriteAddedTaps)", liked)

    def test_accent_color_is_named_in_the_asset_catalog(self) -> None:
        colorset = ROOT / "NekoWidget/Assets.xcassets/AccentColor.colorset/Contents.json"
        self.assertTrue(colorset.exists())
        project = source("NekoWidget.xcodeproj/project.pbxproj")
        self.assertEqual(project.count("ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;"), 2)
        self.assertIn("DesignTokens.swift in Sources", project)


class ToolBottomChromeTests(unittest.TestCase):
    """11/11: inside a tool the tab bar is hidden, the tool's bar is the page's
    colour with the rows fading out above it, and its button is the app's one
    primary button (not a taller capsule)."""

    def setUp(self) -> None:
        self.shared = source("NekoWidget/Views/CatCareView.swift")
        self.bar = section(self.shared, "struct ToolMakeBar<Top: View, Action: View>: View {", "/// The frame around every tool page")

    def test_tab_bar_is_hidden_on_every_tool_page(self) -> None:
        chrome = section(self.shared, "func toolChrome(ground: Color = NekoPalette.groupedGround) -> some View {", "\n    }\n")
        self.assertIn("toolbar(.hidden, for: .tabBar)", chrome)
        main = source("NekoWidget/Views/MainTabView.swift")
        lazy = section(main, "private struct LazyToolDestination<Content: View>: View {", "private struct PhotoThemeCatKey")
        self.assertIn("content().toolChrome()", lazy)
        # The この子 page itself keeps the tab bar.
        tools = section(main, "private var toolsView: some View {", "private var catHomeTools: CatHomeTools {")
        home = source("NekoWidget/Views/CatHomeView.swift")
        for text in (tools, home):
            self.assertNotIn(".toolbar(.hidden, for: .tabBar)", text)
            self.assertNotIn(".toolChrome()", text)
        # A pushed page without it would bring the tab bar back, so each
        # page a tool pushes sets it.
        pages = {
            "NekoWidget/Views/CareHandoffView.swift": ["private struct CareDisplayView"],
            "NekoWidget/Views/CatPreparednessView.swift": ["private struct LostCatPreviewView", "private struct LostCatFoundView"],
            "NekoWidget/Views/EvacuationPreparationView.swift": [
                "private struct EvacuationPackingView", "private struct EvacuationNowView",
                "private struct EvacuationSuppliesEditor", "private struct EvacuationSupplyEditor",
                "private struct EvacuationCatsView", "private struct EvacuationCatEditor",
                "private struct EvacuationDisplayView", "private struct EvacuationDestinationsView",
                "private struct EvacuationDestinationEditor"],
        }
        for path, names in pages.items():
            text = source(path)
            for name in names:
                start = text.index(name)
                following = text.find("\nprivate struct ", start + 1)
                following = len(text) if following < 0 else following
                # The lost-cat flyer preview passes its own plain ground.
                self.assertIn(".toolChrome(", text[start:following], name)
        # 11/12: every page a row of a row-list tool opens is this one
        # shared page, and 病院で見せる makes its pages with it.
        parts = source("NekoWidget/Views/ToolRowParts.swift")
        self.assertIn(".toolChrome()", section(parts, "struct ToolPushedPage<Content: View>: View {", "\n}\n"))
        for path in ("NekoWidget/Views/VeterinaryVisitView.swift", "NekoWidget/Views/CareHandoffView.swift",
                     "NekoWidget/Views/CatPreparednessView.swift"):
            self.assertIn("ToolPushedPage(title: title,", source(path), path)
        self.assertNotIn("struct VeterinaryPushedPage", source("NekoWidget/Views/VeterinaryVisitView.swift"))
        # 「この子のこと」 opened from a tool keeps the tool's frame.
        subject = section(self.shared, "struct CatCareSubjectView: View {", "private struct CatCareInsideCatPageKey")
        self.assertIn(".toolChrome()", subject)

    def test_bar_takes_the_page_colour_and_fades_above(self) -> None:
        self.assertNotIn("regularMaterial", self.bar)
        self.assertIn("ground: Color = NekoPalette.groupedGround", self.bar)
        self.assertIn(".background(ground)", self.bar)
        self.assertIn("LinearGradient(colors: [ground.opacity(0), ground], startPoint: .top, endPoint: .bottom)", self.bar)
        self.assertIn(".offset(y: -ToolChrome.fade)", self.bar)
        self.assertIn(".allowsHitTesting(false)", self.bar)
        self.assertIn(".accessibilityHidden(true)", self.bar)
        self.assertIn("static let fade: CGFloat = 28", self.shared)
        tokens = source("NekoWidget/Views/DesignTokens.swift")
        self.assertIn("static let groupedGround = Color(uiColor: .systemGroupedBackground)", tokens)
        self.assertIn("static let plainGround = Color(uiColor: .systemBackground)", tokens)
        # The last row can be scrolled clear of the fade.
        room = section(self.shared, "func toolBarFadeRoom() -> some View {", "\n    }\n")
        self.assertIn("contentMargins(.bottom, ToolChrome.fade, for: .scrollContent)", room)
        bottom = section(self.shared, "private struct ToolBottomBar<Bar: View>: ViewModifier {", "/// A photo beside its text")
        self.assertIn(".toolBarFadeRoom()", bottom)
        for path, count in (("NekoWidget/Views/CareHandoffView.swift", 1), ("NekoWidget/Views/CatPreparednessView.swift", 2),
                            ("NekoWidget/Views/EvacuationPreparationView.swift", 1), ("NekoWidget/Views/VeterinaryVisitView.swift", 1)):
            self.assertEqual(source(path).count(".toolBarFadeRoom()"), count, path)

    def test_button_is_the_shared_primary_button(self) -> None:
        self.assertIn(".nekoPrimaryButton()", self.bar)
        self.assertNotIn(".controlSize(.large)", self.bar)
        self.assertNotIn(".buttonStyle(.borderedProminent)", self.bar)
        for path in ("NekoWidget/Views/CareHandoffView.swift", "NekoWidget/Views/EvacuationPreparationView.swift",
                     "NekoWidget/Views/VeterinaryVisitView.swift"):
            self.assertNotIn(".frame(maxWidth: .infinity, minHeight: 44)\n        }", source(path), path)
        self.assertIn('Label("先生に見せる", systemImage: "stethoscope").frame(maxWidth: .infinity)\n', source("NekoWidget/Views/VeterinaryVisitView.swift"))


class PlusMomentOfBuying1112Tests(unittest.TestCase):
    """11/12 点検「買う瞬間」: what the person bought Plus for comes first."""

    def setUp(self) -> None:
        self.model = source("NekoWidget/Services/MembershipOfferModel.swift")
        self.view = source("NekoWidget/Views/MembershipOfferView.swift")
        self.sheet = section(self.model, "struct MembershipOfferSheet: View {", "struct PlusOfferPrompt: View {")

    def test_purchase_resumes_the_pending_action_at_once(self) -> None:
        purchase = section(self.sheet, "    private func purchase() {", "    private func openNextStep()")
        resumes = section(purchase, "if context.hasPendingAction(showsClose: showsClose) {", "} else {")
        self.assertIn("onFinish(result)", resumes)
        self.assertNotIn("asksAutoSave", self.sheet)
        self.assertNotIn("AutoSaveOfferAlert", self.sheet)
        self.assertNotIn("AppRecordSettingsView", self.sheet)
        pending = section(self.model, "func hasPendingAction(showsClose: Bool) -> Bool {", "\n    }\n")
        self.assertIn("case .settings: false", pending)
        self.assertIn("case .onboarding: !showsClose", pending)
        self.assertIn("default: true", pending)
        # Nothing waiting: one line and one button, inside the same sheet.
        started = section(purchase, "} else {", "\n        }\n")
        self.assertIn("nextStep = nextStepSource?.resolve()", started)
        self.assertIn("showsStarted = true", started)
        self.assertIn("if showsStarted {", self.sheet)
        self.assertIn('static let line = "Plusが始まりました。"', self.view)
        self.assertIn('.accessibilityIdentifier("membership-offer-next-step")', self.view)
        tab = source("NekoWidget/Views/MainTabView.swift")
        step = section(tab, "private func plusStartedNextStep() -> PlusStartedNextStep? {", "private func afterSettingsCloses(")
        self.assertIn('"\\(latest.monthNumber)月の作品を開く"', step)
        self.assertIn('PlusStartedNextStep(title: "まどを作る")', step)
        self.assertLess(step.index("月の作品を開く"), step.index('"まどを作る"'))
        self.assertIn(".environment(\\.plusStartedNextStep, plusStartedNextStepSource)", tab)
        # The album's work opens once Plus is confirmed: a purchase never closes the gate.
        prompt = section(self.model, "struct PlusOfferPrompt: View {", "struct PlusSettingsSection: View {")
        self.assertIn("finishedWithPlus = result == .completed", prompt)
        self.assertIn("if !finishedWithPlus { onDeclined?() }", prompt)

    def test_auto_save_question_is_deferred_and_asked_once(self) -> None:
        purchase = section(self.sheet, "    private func purchase() {", "    private func openNextStep()")
        self.assertIn("AutoSaveAfterPurchase.noteBought(from: context)", purchase)
        later = section(self.model, "enum AutoSaveAfterPurchase {", "private struct AutoSaveOfferAlert")
        self.assertIn('static let askedKey = "plusAutoSaveQuestionAsked"', later)
        self.assertIn("guard applies(after: context), !defaults.bool(forKey: askedKey) else { return }", later)
        self.assertIn("defaults.bool(forKey: pendingKey) && !defaults.bool(forKey: askedKey) && !boughtThisActivation", later)
        self.assertIn("context != .preservation && ManagedPreservationConfiguration.current.isEnabled", later)
        self.assertIn("!AppRecordPersistence.shared.enabled", later)
        root = section(self.model, "private struct AutoSaveOfferLater: ViewModifier {", "extension View {")
        self.assertIn("if phase == .background { AutoSaveAfterPurchase.boughtThisActivation = false }", root)
        self.assertLess(root.index("AutoSaveAfterPurchase.noteAsked()"), root.index("asks = true"))
        self.assertIn("!AutoSaveAfterPurchase.isPresentingOverApp", root)
        self.assertIn("if AutoSaveAfterPurchase.applies(after: .settings) { asks = true }", root)
        self.assertEqual(self.model.count('"自動保存も始めますか？"'), 1, "one question for every entry")
        self.assertIn('Button("保存を始める", action: start)', self.model)
        self.assertIn('Button("あとで", role: .cancel, action: later)', self.model)

    def test_price_read_failure_offers_a_retry(self) -> None:
        details = section(self.view, "    private var offerDetails: some View {", "    private var actions: some View {")
        self.assertIn('Button("もう一度読み込む", action: reloadAction)', details)
        self.assertIn("if canReloadOffer, let onReloadOffer { return onReloadOffer }", details)
        reload = section(self.model, "var canReloadOffer: Bool {", "func refresh() async {")
        self.assertIn("displayedOffer == nil && offerLoadFinishedWithoutOffer", reload)
        self.assertIn("await prepareOfferAction()", reload)
        self.assertNotIn("purchaseAction", reload)
        self.assertNotIn("restoreAction", reload)
        self.assertIn("onReloadOffer: { Task { await model.reloadOffer() } },", self.sheet)
        # 「サブスクリプションを管理」 stays with the member and the unknown states only.
        self.assertIn("if let onManageSubscription, isMember || canRefresh {", self.view)

    def test_headline_reasons_and_links(self) -> None:
        self.assertIn('static let heading = "うちの子との毎日を、もっと残す"', self.view)
        for path in sorted((ROOT / "NekoWidget").rglob("*.swift")):
            self.assertNotIn("うちの子との毎日を、続ける", path.read_text(encoding="utf-8"), str(path))
        self.assertIn('static let staysFreeLine = "Plusにしなくても、このまま無料で使えます。"', self.view)
        self.assertIn("context == .onboarding && showsClose && !isMember", self.view)
        reasons = section(self.model, "    var reason: String? {", "func hasPendingAction(")
        for line in ('"\\(month)月の作品ができています。Plusで開けます。"',
                     '"季節のムービーができています。Plusで見られます。"',
                     '"まどを作ると、家族のホーム画面に写真を届けられます。Plusがいるのは作る人だけです。"',
                     '"お世話の記録を、家族で一緒に書けます。Plusがいるのは作る人だけです。"',
                     '"猫のこと・メモ・ツールの記録を保存して、新しいiPhoneに戻せます。"'):
            self.assertIn(line, reasons)
        for gone in ("写真やメモの保存", "は無料です", "trialPeriod", "メモを書くのはPlus"):
            self.assertNotIn(gone, reasons)
        self.assertIn('Link("プライバシーポリシー", destination: privacyURL)', self.view)
        self.assertIn('.accessibilityIdentifier("membership-offer-privacy")', self.view)
        # The work's own cover on the Plus screen, and one × back to the album.
        album = source("NekoWidget/Views/AlbumPrototypeView.swift")
        gate = section(album, "struct AlbumWorkGate<Content: View>: View {", "private extension View {")
        self.assertIn("reasonOverride: yearReason, onDeclined: { dismiss() })", gate)
        self.assertIn(".environment(\\.plusOfferPhoto, coverPhoto)", gate)
        self.assertEqual(album.count("AlbumWorkGate(month: letter.monthNumber, arrival: letter.workArrivalDate, cover: letter.coverPhoto) {"), 2)

    def test_memo_is_free_with_no_plus_mark_or_offer(self) -> None:
        # 11/13: a new memo is free, so the 「メモ」 button carries no Plus mark
        # or 「Plusで書けます」, and no memo-originated Plus offer remains.
        photos = source("NekoWidget/Views/LikedPhotosView.swift")
        self.assertNotIn("newMemoNeedsPlus", photos)
        self.assertNotIn("Plusで書けます", photos)
        self.assertNotIn(".createPersonalMemo", photos)
        self.assertIn('identifier: "photo-memory-note-open") {', photos)
        prompt = section(self.model, "struct PlusOfferPrompt: View {", "struct PlusSettingsSection: View {")
        once = section(prompt, "private func openByItselfIfDue() {", "\n    }\n")
        self.assertNotIn("newMemoAutoOpenedKey", self.model)
        self.assertIn("showsOffer = true", once)
        self.assertNotIn("case newMemo", self.model)
        self.assertIn('"Plusで\\(month)月の作品を見る"', self.model)

    def test_billing_issue_has_its_own_settings_state(self) -> None:
        settings = section(self.model, "struct PlusSettingsSection: View {", "#if DEBUG || INTERNAL_PRESENTATION")
        self.assertIn("private var billingIssue: Bool { status == .notMember && purchases.hasBillingIssue }", settings)
        self.assertIn('billingIssue ? "Plus（お支払いの確認が必要です）" : "Plus"', settings)
        issue = section(settings, "case .notMember where billingIssue:", "case .notMember:")
        self.assertIn('SettingsActionRow("サブスクリプションを管理"', issue)
        self.assertIn("showsManagement = true", issue)


class HandoverOutputsLook1112Tests(unittest.TestCase):
    """11/12: what a cat owner hands to others. The lost-cat flyer fills its
    sheet (equal photo tiles, filled; larger type before white space), and the
    three memos (診察・お世話・避難) share one light paper sheet."""

    def setUp(self) -> None:
        self.sheet = source("NekoWidget/Views/ToolMemoSheet.swift")
        self.store = source("NekoWidget/Services/CatPreparednessStore.swift")
        self.renderer = section(self.store, "enum LostCatFlyerRenderer {", "\n}\n")
        self.lost = source("NekoWidget/Views/CatPreparednessView.swift")
        self.care = source("NekoWidget/Views/CareHandoffView.swift")
        self.vet = source("NekoWidget/Views/VeterinaryVisitView.swift")
        self.evacuation = source("NekoWidget/Views/EvacuationPreparationView.swift")

    def test_memo_sheet_is_registered_like_the_row_parts(self) -> None:
        project = source("NekoWidget.xcodeproj/project.pbxproj")
        self.assertEqual(project.count("/* ToolMemoSheet.swift in Sources */"), 2)
        self.assertEqual(project.count("path = ToolMemoSheet.swift;"), 1)
        self.assertIn("\t\t7A11121C0000000000000001 /* ToolMemoSheet.swift in Sources */ = {isa = PBXBuildFile; "
                      "fileRef = 7A11121C0000000000000002 /* ToolMemoSheet.swift */; };", project)
        self.assertIn("\t\t7A11121C0000000000000002 /* ToolMemoSheet.swift */ = {isa = PBXFileReference; "
                      "lastKnownFileType = sourcecode.swift; path = ToolMemoSheet.swift; sourceTree = \"<group>\"; };", project)
        self.assertIn("\t\t\t\t7A11121C0000000000000002 /* ToolMemoSheet.swift */,\n", project)
        self.assertIn("\t\t\t\t7A11121C0000000000000001 /* ToolMemoSheet.swift in Sources */,\n", project)
        self.assertEqual(project.count("7A11121C0000000000000001"), 2)
        self.assertEqual(project.count("7A11121C0000000000000002"), 3)

    def test_the_sheet_is_paper_in_both_modes(self) -> None:
        sheet = section(self.sheet, "struct ToolMemoSheet<Content: View>: View {", "struct ToolMemoField: View {")
        self.assertIn(".environment(\\.colorScheme, .light)", sheet)
        self.assertIn(".background(ToolMemoPaper.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))", sheet)
        self.assertIn(".strokeBorder(ToolMemoPaper.edge, lineWidth: 0.5)", sheet)
        self.assertIn(".shadow(", sheet)
        self.assertIn("static let paper = Color.white", self.sheet)
        # The header: the memo's name small, the cat's large, the day, the face.
        self.assertLess(sheet.index("Text(kind)"), sheet.index("Text(name)"))
        self.assertLess(sheet.index("Text(name)"), sheet.index("Text(ToolMemoDate.text(date))"))
        self.assertIn("if let face {", sheet)
        self.assertIn("Calendar.nekoGregorian.dateComponents([.year, .month, .day], from: date)", self.sheet)
        self.assertIn('return "\\(parts.year ?? 0)年\\(parts.month ?? 0)月\\(parts.day ?? 0)日"', self.sheet)
        # Photos fill their frame with rounded corners and keep their labels.
        photo = section(self.sheet, "struct ToolMemoPhoto: View {", "struct ToolMemoNotice: View {")
        self.assertIn("Image(uiImage: image).resizable().scaledToFill()", photo)
        self.assertIn(".accessibilityLabel(label)", photo)

    def test_three_memos_use_the_sheet_and_the_same_chrome(self) -> None:
        care = section(self.care, "private struct CareDisplayView: View {", "private struct CareActivitySheet")
        vet = section(self.vet, "private struct VeterinaryReadView: View {", "private enum VeterinaryDayWeight {")
        evacuation = section(self.evacuation, "private struct EvacuationDisplayView: View {", "private struct EvacuationActivitySheet")
        self.assertIn("ToolMemoSheet(kind: record.heading, name: record.cats.map(\\.name).joined(separator: \"・\"),", care)
        self.assertIn('ToolMemoSheet(kind: "診察メモ", name: displayName ?? visit.catName, date: Date(), face: face)', vet)
        self.assertIn('ToolMemoSheet(kind: "避難メモ", name: record.name, date: made)', evacuation)
        for page in (care, vet, evacuation):
            self.assertIn('.navigationTitle("できあがり")', page)
            self.assertIn(".background(NekoPalette.groupedGround)", page)
            self.assertIn("ToolMakeBar {", page)
        # Pushed pages keep the back chevron; the vet memo, a sheet, keeps 「閉じる」.
        self.assertIn('ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }', vet)
        self.assertNotIn("toolbar {", care)
        # Notices stay above the sheet as quiet footnotes.
        self.assertLess(care.index('ToolMemoNotice(text: "薬・持病・アレルギーは載せていません")'), care.index("ToolMemoSheet("))
        self.assertLess(care.index('ToolMemoNotice(text: "連絡先・動物病院は載せていません")'), care.index("ToolMemoSheet("))
        # Identifiers and labels are kept.
        for kept in ('"care-share-pdf"', '"care-share-images"', 'faceLabel: "渡す猫の写真"'):
            self.assertIn(kept, care)
        for kept in ('"vet-reading"', '"vet-reading-weight"', '"vet-export-pdf"', '"vet-export-images"'):
            self.assertIn(kept, vet)
        for kept in ('"evacuation-share-preview"', '"evacuation-share-pdf"', '"evacuation-share-images"',
                     'label: "載せる写真"', ".accessibilityLabel(attachment.0)"):
            self.assertIn(kept, evacuation)
        # No sentence on the sheet when there is no photo.
        self.assertNotIn("見分けるための写真はまだありません", evacuation)

    def test_exported_memos_draw_the_same_header(self) -> None:
        page = section(self.sheet, "enum ToolMemoPage {", "\n}\n")
        self.assertIn("static func drawHeader(kind: String, name: String, date: Date, face: UIImage?,", page)
        self.assertIn("ToolMemoDate.text(date)", page)
        care = source("NekoWidget/Services/CareHandoffExporter.swift")
        evacuation = source("NekoWidget/Services/EvacuationExporter.swift")
        vet = section(self.vet, "private enum VeterinaryMemoExporter {", "\n}\n")
        for exporter in (care, evacuation, vet):
            self.assertIn("ToolMemoPage.drawHeader(", exporter)
            self.assertIn("ToolMemoPage.headerHeight(pdf:", exporter)
            self.assertIn(".foregroundColor: ToolMemoPage.labelColor", exporter)
        # Page sizes and file names stay as they were.
        for exporter in (care, vet):
            self.assertIn("CGSize(width: 595.28, height: 841.89) : CGSize(width: 390, height: 900)", exporter)
        self.assertIn("printCopy ? CGSize(width: 595.28, height: 841.89) : CGSize(width: 390, height: 900)", evacuation)
        self.assertIn('"診察メモ.pdf"', vet)
        self.assertIn('"cat-care.pdf"', care)
        # The evacuation photos fill rounded tiles; papers stay whole.
        self.assertIn("ToolMemoPage.drawFilled(image, in: tile, radius: 10)", evacuation)
        self.assertIn("draw(image, in: CGRect(x: margin, y: top,", evacuation)

    def test_flyer_photos_fill_equal_tiles_and_the_sheet_has_an_edge(self) -> None:
        tiles = section(self.renderer, "private static func photoTiles(", "/// The tallest the photo block")
        self.assertIn("let tile = (bounds.width - gap) / 2", tiles)
        draw = section(self.renderer, "private static func drawPhoto(", "private static func text(")
        self.assertIn("let scale = max(rect.width / image.size.width, rect.height / image.size.height)", draw)
        self.assertIn("context.clip(to: rect)", draw)
        self.assertNotIn("photoFrames", self.renderer)
        # What is drawn is filled: larger type first, then the space shared out.
        self.assertIn("let plan = filledLayout(draft, format: format)", self.renderer)
        self.assertIn("for boost: CGFloat in [1.35, 1.25, 1.15, 1.08] {", self.renderer)
        self.assertIn("return spread(plan, cap: cap, gap: format.isPDF ? 9 : 16)", self.renderer)
        self.assertIn("let plan = spread(small, cap: small.photoRect.width * 1.1, gap: 6)", self.renderer)
        # Issues are judged by layout(), never by the filled one.
        issues = section(self.renderer, "static func issues(_ draft: LostCatPublicDraft, output: LostCatOutput)", "static func inputIssue(")
        self.assertIn("return layout(draft, format: output).1", issues)
        self.assertNotIn("filledLayout", issues)
        # The made image on the screen shows its edge; the file has none.
        preview = section(self.lost, "private struct LostCatPreviewView", "private struct LostCatActivitySheet")
        self.assertIn(".lostCatSheetEdge()", preview)
        self.assertIn('.accessibilityLabel("共有する迷子の猫の画像")', preview)
        edge = section(self.lost, "func lostCatSheetEdge() -> some View {", "\n    }\n")
        self.assertIn("strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5)", edge)
        self.assertNotIn("shadow", section(self.renderer, "private static func draw(", "/// The largest size"))


class ToolsLookRoundTwo1112Tests(unittest.TestCase):
    """11/12 見た目の点検 (round 2), tools and 「この子のこと」: one top bar for
    every tool page, no tab bar on 「この子のこと」, 避難 on the shared rows,
    three words for 「nothing yet」, a chevron on every row that opens
    something. Source contracts only: the screens are checked on captures."""

    def setUp(self) -> None:
        self.care = source("NekoWidget/Views/CatCareView.swift")
        self.parts = source("NekoWidget/Views/ToolRowParts.swift")
        self.vet = source("NekoWidget/Views/VeterinaryVisitView.swift")
        self.lost = source("NekoWidget/Views/CatPreparednessView.swift")
        self.handoff = source("NekoWidget/Views/CareHandoffView.swift")
        self.evacuation = source("NekoWidget/Views/EvacuationPreparationView.swift")
        self.tab = source("NekoWidget/Views/MainTabView.swift")

    def test_one_shared_top_bar_for_every_tool_page(self) -> None:
        chrome = section(self.care, "func toolChrome(ground: Color = NekoPalette.groupedGround) -> some View {", "\n    }\n")
        self.assertIn("toolbar(.hidden, for: .tabBar)", chrome)
        self.assertIn(".modifier(ToolChromeTopBar(ground: ground))", chrome)
        bar = section(self.care, "private struct ToolChromeTopBar: ViewModifier {", "\n}\n")
        self.assertIn("if #available(iOS 26.0, *) {", bar)
        self.assertEqual(bar.count(".toolbarBackground(ground, for: .navigationBar)"), 2)
        self.assertIn(".toolbarBackground(.visible, for: .navigationBar)", bar)
        self.assertIn(".scrollEdgeEffectStyle(.hard, for: .top)", bar)
        # The one place: no tool page sets its own bar background.
        for name, text in (("vet", self.vet), ("lost", self.lost), ("care", self.handoff),
                           ("evacuation", self.evacuation), ("parts", self.parts)):
            self.assertNotIn("toolbarBackground", text, name)
            self.assertNotIn("scrollEdgeEffect", text, name)
        self.assertEqual(self.care.count("toolbarBackground("), 3)
        # Every page a row opens, and every tool, wears it.
        self.assertIn(".toolChrome()", section(self.parts, "struct ToolPushedPage<Content: View>: View {", "\n}\n"))
        self.assertIn("var body: some View { content().toolChrome() }", self.tab)
        # The flyer preview sits on the plain ground, and its bar matches it.
        preview = section(self.lost, "private struct LostCatPreviewView", "private struct LostCatActivitySheet")
        self.assertIn(".toolChrome(ground: Color(.systemBackground))", preview)

    def test_cat_page_hides_the_tab_bar_and_says_its_name_once(self) -> None:
        detail = section(self.care, "struct CatCareDetailView: View {", "/// A written item of 「この子のこと」")
        body = section(detail, "    var body: some View {", ".onChange(of: draft)")
        self.assertIn(".toolChrome()", body)
        # Wherever it opens: 「この子のこと」 on the この子 tab opens
        # CatProfileDetailView, which shows this same CatCareDetailView.
        page = section(source("NekoWidget/Views/CatProfilePhotoCurationViews.swift"),
                       "struct CatProfileDetailView: View {", "struct CatProfileAddPhotosButton: View {")
        self.assertIn("CatCareDetailView(profile: profile,", page)
        self.assertIn('.navigationTitle("この子のこと")', page)
        self.assertNotIn(".navigationTitle(profile.displayName)", page)
        home = source("NekoWidget/Views/CatHomeView.swift")
        strip = section(home, "    private func profilePage(_ profile: CatProfilePresentation) -> some View {", "// MARK: Over the photo")
        self.assertIn("CatProfileDetailView(", strip)
        # One name, large, under a smaller photo; one pencil, on the photo.
        heading = section(detail, "private func profileHeading(", "/// An empty name keeps the old one")
        self.assertIn(".frame(width: 64, height: 64)", heading)
        self.assertNotIn("width: 96", heading)
        self.assertEqual(heading.count('Image(systemName: "pencil.circle.fill")'), 1)
        self.assertIn('.accessibilityIdentifier("cat-profile-rename")', heading)
        # The parts close together, as on the tools; delete in 「…」.
        self.assertIn(".toolPageSpacing()", section(detail, "private var form: some View {", "    var body: some View {"))
        self.assertIn('menuIdentifier: "cat-care-more-menu")', detail)
        # The two photo squares share the card's width; the hint is not gray.
        photos = section(detail, "private var identifyingPhotosSection: some View {", "private func crop(")
        self.assertNotIn("maxWidth: 140", photos)
        hint = section(detail, "@ViewBuilder private var progressSection: some View {", "static func photoTitle(")
        self.assertIn(".foregroundStyle(.primary)", hint)

    def test_evacuation_uses_the_shared_rows_and_an_enabled_button(self) -> None:
        hub = section(self.evacuation, "struct EvacuationPreparationView: View {", "private func makeBook() async {")
        for title, identifier in (("持ち出すもの", "evacuation-packing-open"), ("猫の情報", "evacuation-cats-open"),
                                  ("行き先と連絡先", "evacuation-destinations-open")):
            self.assertIn(f'ToolValueRow(title: "{title}"', hub)
            self.assertIn(f'.accessibilityIdentifier("{identifier}")', hub)
        self.assertNotIn("ToolStepHeader", hub)
        # 「いま避難する」 stays first and red.
        self.assertLess(hub.index('"evacuation-now-open"'), hub.index('ToolValueRow(title: "持ち出すもの"'))
        self.assertIn('.font(.headline).foregroundStyle(Color.red)', hub)
        book = section(self.evacuation, "private var bookButton: some View {", "private struct EvacuationSaveNotice")
        self.assertNotIn(".bordered", book)
        # 持ち出すもの: the place only when written, never the same gray sentence.
        packing = section(self.evacuation, "private struct EvacuationPackingView", "private struct EvacuationExpiryLine")
        self.assertIn("let detail = [item.quantity, item.location].filter { !$0.isEmpty }.joined(separator: \"・\")", packing)
        self.assertIn("if !detail.isEmpty {", packing)
        self.assertNotIn("未記入", packing)

    def test_three_words_for_nothing_yet(self) -> None:
        words = section(self.parts, "enum ToolEmptyValue {", "\n}\n")
        self.assertIn('static let unwritten = "未記入"', words)
        self.assertIn('static let unset = "未設定"', words)
        self.assertIn('static let none = "なし"', words)
        # 「未記入」: what the owner writes.
        for name, text, needle in (
                ("vet text", self.vet, "(words ?? ToolEmptyValue.unwritten)"),
                ("vet weight", self.vet, "value: weight ?? ToolEmptyValue.unwritten"),
                ("lost text", self.lost, "value: issue ?? words ?? ToolEmptyValue.unwritten"),
                ("care text", self.handoff, "value: words ?? ToolEmptyValue.unwritten"),
                ("cat care text", self.care, "value: words ?? ToolEmptyValue.unwritten"),
                ("evac cats", self.evacuation, "if cats.isEmpty { return ToolEmptyValue.unwritten }"),
                ("evac places", self.evacuation, 'count == 0 ? ToolEmptyValue.unwritten : "\\(count)件"')):
            self.assertIn(needle, text, name)
        # 「未設定」: dates and choices.
        for name, text, needle in (
                ("vet next visit", self.vet, ": ToolEmptyValue.unset,"),
                ("lost date", self.lost, "?? ToolEmptyValue.unset,"),
                ("lost collar", self.lost, 'case unknown = "未設定", none = "なし", present = "あり"')):
            self.assertIn(needle, text, name)
        for status in ("CatCareSex", "CatCareMicrochipStatus", "CatCareConditionsStatus", "CatCareVetStatus",
                       "CatCareAllergy.Status"):
            self.assertIn(f"Text(ToolEmptyValue.unset).tag({status}.unknown)", self.care, status)
        self.assertEqual(self.care.count("Text(ToolEmptyValue.unset).tag(CatCareTriState.unknown)"), 2)
        self.assertNotIn('Text("未記入").tag(', self.care)
        self.assertNotIn('Text("未確認").tag(', self.care)
        # 「なし」: counts and explicit 「none」 answers.
        for name, text, needle in (
                ("vet records", self.vet, 'count == 0 ? ToolEmptyValue.none : "\\(count)件"'),
                ("lost photo", self.lost, "faceImage == nil ? ToolEmptyValue.none :"),
                ("care photo", self.handoff, '"載せる" : ToolEmptyValue.none'),
                ("care cats", self.handoff, "chosen.isEmpty ? ToolEmptyValue.none :"),
                ("evac items", self.evacuation, "if needed.isEmpty { return (ToolEmptyValue.none, false, false) }")):
            self.assertIn(needle, text, name)
        # The old words are gone from the rows.
        self.assertNotIn('?? "不明"', self.lost)
        self.assertNotIn('"まだありません"', self.evacuation)
        self.assertNotIn('"行き先 \\(', self.evacuation)

    def test_every_tappable_row_has_a_chevron(self) -> None:
        sheet = section(self.parts, "struct ToolSheetRow: View {", "\n}\n")
        self.assertIn("ToolChevron()", sheet)
        chevron = section(self.parts, "struct ToolChevron: View {", "\n}\n")
        self.assertIn('Image(systemName: "chevron.right")', chevron)
        self.assertIn(".accessibilityHidden(true)", chevron)
        # Rows that open a sheet or a form instead of a page.
        self.assertIn('ToolSheetRow(row: ToolValueRow(title: "体重"', self.vet)
        self.assertIn('ToolSheetRow(row: ToolValueRow(title: "日時"', self.lost)
        self.assertIn("ToolSheetRow(row: ToolValueRow(title: title, systemImage: systemImage, value: value, filled: filled),",
                      self.care)
        # No ToolValueRow sits in a plain Button without the chevron.
        for name, text in (("vet", self.vet), ("lost", self.lost), ("care", self.care)):
            self.assertNotIn("Button { weighing = true } label: {\n            ToolValueRow", text, name)
            self.assertNotIn("showsDatePicker = true } label: {\n            ToolValueRow", text, name)
        # The row to 「この子のこと」 is the same row as the others.
        folded = section(self.care, "private func foldedLabel(", "@ViewBuilder")
        self.assertIn('ToolValueRow(title: title, systemImage: "pawprint",', folded)

    def test_over_limit_counter_and_field_pages(self) -> None:
        counter = section(self.parts, "struct ToolFieldCounter: View {", "\n}\n")
        self.assertIn("let over = count > limit", counter)
        self.assertIn("Color.red", counter)
        self.assertIn('"長すぎます', counter)
        field = section(self.vet, "private struct VeterinaryLabeledField: View {", "/// A chosen photo on the page")
        self.assertIn("ToolFieldCounter(count: text.count, limit: 500)", field)
        self.assertEqual(self.vet.count("counts: true"), 4)
        self.assertNotIn('Label("500文字を超えています"', self.vet)
        self.assertIn("ToolFieldCounter(count: draft[keyPath: item.path].count, limit: CatCareLimits.textCharacters)", self.care)
        self.assertIn("lines: 3...8)", self.handoff)

    def test_tools_tab_tiles_fit_their_content(self) -> None:
        # 11/12 (案D): the tiles became round buttons as tall as their content;
        # the page leaves room under the last card above the tab bar.
        home = source("NekoWidget/Views/CatHomeView.swift")
        button = section(home, "private struct CatHomeToolButton: View {", "/// The accessibility-size form of a tool")
        self.assertNotIn("minHeight: 120", button)
        self.assertIn(".frame(width: circle, height: circle)", button)
        page = section(home, "private struct CatHomePage: View {", "/// The cat's key photo from the very top")
        # 11/13: 32 (was 24), so the last row clears the floating tab bar.
        self.assertIn(".padding(.bottom, 32)", page)
        # 11/14: no 「あと○つ」/「そろっています」 on the page; the count stays
        # inside この子のこと (pinned in ci/test-cat-home-care.py).
        facts = section(home, "struct CatHomeFacts {", "/// The five tools, in the order of the page.")
        self.assertNotIn('"そろっています"', facts)
        # The bottom button is as wide as the cards above it.
        self.assertIn(".padding(.horizontal, ToolChrome.sideMargin)",
                      section(self.care, "struct ToolMakeBar<Top: View, Action: View>: View {", "/// The frame around every tool page"))
        # 写真を見せる, empty: のわ above the sentence, the button right under it.
        empty = section(source("NekoWidget/Views/ShowcasePhotoView.swift"), "private struct ShowcaseNothingChosen: View {", "\n}\n")
        self.assertIn('Image("Nowa-peek")', empty)
        self.assertIn(".nekoPrimaryButton()", empty)
        self.assertIn('.accessibilityIdentifier("showcase-gallery-select")', empty)



class MainTabsLook1112Tests(unittest.TestCase):
    """11/12: the 写真, まど, アルバム and 設定 tabs after the designer's review.
    A received まど photo reads as a small gift, cards never look empty, the
    photo viewer's bottom is one band, and buttons do not vanish in the dark."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.window = source("NekoWidget/Views/GroupWindowView.swift")
        cls.browser = source("NekoWidget/Views/LikedPhotosView.swift")
        cls.tab = source("NekoWidget/Views/MainTabView.swift")
        cls.settings = source("NekoWidget/Views/SettingsView.swift")

    def test_empty_window_card_shows_nowa_not_a_small_icon(self) -> None:
        cover = section(self.window, "private struct WindowCardEmptyCover: View {", "\n}\n")
        self.assertIn("NekoPalette.cream", cover)
        self.assertIn('Image("Nowa-peek")', cover)
        self.assertIn(".accessibilityHidden(true)", cover)
        self.assertNotIn('"ToolCat-snug"', self.window)
        for name, end in (("private struct GroupWindowCard: View {", "private struct WindowCardEmptyCover: View {"),
                          ("private struct KnownWindowCard: View {", "struct GroupHiddenMembersView: View {")):
            card = section(self.window, name, end)
            self.assertIn("WindowCardEmptyCover()", card)
            # The name over the cream is ink, in light and dark.
            self.assertIn("NekoPalette.ink)", card)
            # Nothing is fetched for the cover: only what this iPhone keeps.
            self.assertNotIn("fetchPhoto", card)

    def test_received_photo_row_is_a_gift(self) -> None:
        tile = section(self.window, "private struct GroupPhotoTile: View {", "\n}\n")
        self.assertIn('GroupMemberAvatar(name: entry.isOwn ? "あなた" : entry.senderDisplayName, size: 30)', tile)
        self.assertIn(".font(.body.weight(.semibold))", tile)
        self.assertIn("GroupPhotoTileDate.text(entry.createdAt)", tile)
        self.assertIn(".font(.title3.weight(.semibold))", tile)
        self.assertIn(".frame(minWidth: 44, minHeight: 44)", tile)
        self.assertIn('.accessibilityIdentifier("group-photo-tile-heart")', tile)
        date = section(self.window, "enum GroupPhotoTileDate {", "\n}\n")
        for part in ('"今日"', '"昨日"', '"\\(days)日前"', "Calendar.nekoGregorian",
                     "date.formatted(.dateTime.month().day())"):
            self.assertIn(part, date)
        self.assertNotIn("UserDefaults", date)
        avatar = section(source("NekoWidget/Views/GroupWindowSetupView.swift"),
                         "struct GroupMemberAvatar: View {", "\n}\n")
        self.assertIn("Text(verbatim: initial)", avatar)
        self.assertIn('Image(systemName: "person.fill")', avatar)
        self.assertIn(".accessibilityHidden(true)", avatar)

    def test_window_page_bars_match_the_page(self) -> None:
        screen = section(self.window, "struct GroupWindowScreen: View {", "private struct GroupWindowContinueSheets")
        self.assertIn(".toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)", screen)
        self.assertIn(".toolbarBackground(.visible, for: .navigationBar)", screen)
        bar = section(screen, "    private var sendBar: some View {", "\n    }\n}")
        self.assertNotIn(".background(.bar)", bar)
        self.assertIn(".background(Color(uiColor: .systemGroupedBackground))", bar)
        self.assertNotIn("minHeight: 50", bar)
        self.assertEqual(bar.count('.accessibilityIdentifier("group-window-send-photo")'), 2)
        picker = section(self.window, "private struct GroupCatPhotoPickerSheet: View {",
                         "private struct GroupLibraryDeliveryRequest")
        self.assertIn(".tint(Color.primary)", picker)
        self.assertNotIn(".background(.bar)", picker)

    def test_photo_viewer_title_is_the_date_and_bottom_is_one_band(self) -> None:
        self.assertIn('private var showsDateAsTitle: Bool { navigationTitleText == "写真" }', self.browser)
        title = section(self.browser, "private func titleDate(_ photo: PhotoPresentation) -> some View {", "\n    }\n")
        self.assertIn('.accessibilityIdentifier("photo-browser-date")', title)
        self.assertIn(".accessibilityValue(spokenDate)", title)
        # 「2 / 8」 stays readable on its own (VoiceOver and UI tests), as the row's was.
        self.assertIn('.accessibilityLabel(position ?? "")', title)
        self.assertIn('.accessibilityIdentifier("photo-browser-position")', title)
        self.assertIn(".accessibilityElement(children: .contain)", title)
        self.assertIn("ToolbarItem(placement: .principal) { titleDate(selectedPhoto) }", self.browser)
        # The bar keeps 「写真」 as its name for back buttons and UI tests.
        self.assertIn(".navigationTitle(navigationTitleText)", self.browser)
        viewer = section(self.browser, "    private var browserContent: some View {", "    /// 「○○から」 and, under it")
        self.assertEqual(viewer.count(".background(Self.controlsBand)"), 2)
        self.assertNotIn(".background(.bar)", viewer)
        self.assertNotIn(".background(.ultraThinMaterial)", viewer)
        deliver = section(self.browser, "private struct DeliverButtonEmphasis: ViewModifier {", "\n}\n")
        self.assertIn("content.buttonStyle(.bordered).tint(Color.primary)", deliver)

    def test_memo_hint_sits_where_writing_starts(self) -> None:
        note = source("NekoWidget/Views/PhotoNoteInput.swift")
        body = section(note, "struct PhotoNoteInput: View {", "#if DEBUG")
        self.assertLess(body.index("TextEditor(text: $text)"), body.index('Text("このあと、どうなった？")'))
        self.assertIn(".overlay(alignment: .topLeading) {", body)
        self.assertIn(".allowsHitTesting(false)", body)
        self.assertLess(body.index('Text("このあと、どうなった？")'), body.index("Text(audience)"))
        self.assertLess(body.index("Text(audience)"), body.index('文字")'))
        # The CI photo fixtures are still filled into this file.
        for name in ("GRAY", "ORANGE", "TUXEDO"):
            self.assertEqual(note.count(f"__MOMENT_EXPERIENCE_{name}_PNG_BASE64__"), 1)

    def test_settings_actions_are_rows_and_autosave_starts_with_a_button(self) -> None:
        row = section(self.settings, "struct SettingsActionRow: View {", "\n}\n")
        self.assertNotIn(".buttonStyle(.bordered)", row)
        self.assertNotIn(".listRowBackground(Color.clear)", row)
        records = source("NekoWidget/Services/AppRecordPersistence.swift")
        start = section(records, "@ViewBuilder private var startAction: some View {",
                        "@ViewBuilder private var signedOutSections")
        self.assertIn('Text("保存を始める")', start)
        self.assertIn(".buttonStyle(.borderedProminent)", start)
        self.assertIn('.accessibilityIdentifier("app-record-enable")', start)
        view = section(records, "struct AppRecordSettingsView: View {", "@ViewBuilder private var settingsSections")
        self.assertIn('.navigationTitle("自動保存")\n        // 11/12', view)
        self.assertIn(".navigationBarTitleDisplayMode(.inline)", view)

    def test_nowa_on_the_family_notebook_and_album_plus_mark_says_what_it_does(self) -> None:
        intro = section(source("NekoWidget/Views/FamilyNotebookView.swift"),
                        "struct FamilyNotebookIntroView: View {", "struct FamilyNotebookPlusMark: View {")
        self.assertIn('Image("Nowa-peek")', intro)
        self.assertIn("NekoPalette.cream", intro)
        self.assertNotIn('Image(systemName: "person.2.fill")', intro)
        album = source("NekoWidget/Views/AlbumPrototypeView.swift")
        card = section(album, "private func arrivalCard(", "struct AlbumPlusMark: View {")
        self.assertIn('Text("Plusでひらく")', card)
        self.assertIn('"、Plusでひらく"', card)
        self.assertIn('.accessibilityIdentifier("album-prototype-plus-mark")', card)
        for banned in ("ずっと無料", "永久に"):
            for text in (self.window, self.browser, album):
                self.assertNotIn(banned, text)


class CatHomeTab1112Tests(unittest.TestCase):
    """11/12 (案D 「写真が主役」): the ツール tab is now 「この子」, one page per
    cat: the key photo with the name and one line, a row of five round tool
    buttons, then 「この子のこと」. Tools opened from a page open for its cat."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.home = source("NekoWidget/Views/CatHomeView.swift")
        cls.tab = source("NekoWidget/Views/MainTabView.swift")
        cls.vet = source("NekoWidget/Views/VeterinaryVisitView.swift")
        cls.care = source("NekoWidget/Views/CareHandoffView.swift")
        cls.lost = source("NekoWidget/Views/CatPreparednessView.swift")

    def test_tab_is_called_kono_ko_and_keeps_its_identifiers(self) -> None:
        tools_tab = section(self.tab, "    private var toolsTab: some View {", "    private var presentedTabContent: some View {")
        self.assertIn('Label("この子", systemImage: "pawprint")', tools_tab)
        self.assertIn('.accessibilityIdentifier("main-tab-tools")', tools_tab)
        self.assertIn(".tag(AppTab.tools)", tools_tab)
        self.assertNotIn('Label("ツール"', self.tab)
        self.assertNotIn('.navigationTitle("ツール")', self.tab)
        # In-app sentences name the tab by its new name.
        self.assertIn("「この子」右上の設定", source("NekoWidget/Views/LikedPhotosView.swift"))
        self.assertIn("「この子」タブの「この子を追加」で猫を増やすと", source("NekoWidget/Views/FamilyNotebookView.swift"))
        self.assertNotIn("ツールの「＋」で猫を増やすと", source("NekoWidget/Views/FamilyNotebookView.swift"))

    def test_main_tab_only_swaps_in_the_page(self) -> None:
        view = section(self.tab, "    private var toolsView: some View {", "    private var catHomeTools: CatHomeTools {")
        self.assertIn("CatHomeView(presentation: catProfilesPresentation, actions: catProfilesActions,", view)
        self.assertIn("tools: catHomeTools, openSettings: { showsSettings = true })", view)
        # What the page replaced is gone.
        for gone in ("struct CatChip", "struct ToolTile", "enum ToolTint", "ToolCardButtonStyle", "toolSection(",
                     "private var catStrip", "showcaseToolCard", '"ふだん"', '"もしものとき"', "addsCatFromTools",
                     "private var familyOnlyCats", "func careProgress("):
            self.assertNotIn(gone, self.tab, gone)
        self.assertNotIn("fullTint", source("NekoWidget/Views/CatCareView.swift"))

    def test_new_file_is_in_the_app_target(self) -> None:
        project = source("NekoWidget.xcodeproj/project.pbxproj")
        self.assertEqual(project.count("/* CatHomeView.swift in Sources */"), 2)
        self.assertEqual(project.count("path = CatHomeView.swift;"), 1)
        self.assertIn("\t\t7A11120D0000000000000001 /* CatHomeView.swift in Sources */ = {isa = PBXBuildFile; "
                      "fileRef = 7A11120D0000000000000002 /* CatHomeView.swift */; };", project)
        self.assertIn("\t\t7A11120D0000000000000002 /* CatHomeView.swift */ = {isa = PBXFileReference; "
                      "lastKnownFileType = sourcecode.swift; path = CatHomeView.swift; sourceTree = \"<group>\"; };", project)
        self.assertIn("\t\t\t\t7A11120C0000000000000002 /* ToolRowParts.swift */,\n"
                      "\t\t\t\t7A11120D0000000000000002 /* CatHomeView.swift */,\n", project)
        self.assertIn("\t\t\t\t7A11120C0000000000000001 /* ToolRowParts.swift in Sources */,\n"
                      "\t\t\t\t7A11120D0000000000000001 /* CatHomeView.swift in Sources */,\n", project)

    def test_hero_is_the_key_photo_at_screen_size_from_the_top(self) -> None:
        hero = section(self.home, "private struct CatHomeHero: View {", "/// The tools under the photo:")
        self.assertIn("if let photo = cat.profile?.coverPhoto {", hero)
        self.assertIn("PhotoAssetImageView(", hero)
        self.assertIn("targetPixelSize: pixelSize,", hero)
        self.assertNotIn("showsFullImage: true", hero)
        # As many pixels as the screen shows across, never the original; a
        # rounded shape so the shared cache finds the same image again.
        self.assertIn("min((metrics.width * displayScale).rounded(), 1_290)", hero)
        self.assertIn("(metrics.width / metrics.heroHeight * 100).rounded() / 100", hero)
        # Faces: the crop centres on the top third of the cat.
        self.assertIn("catBoundingBox: Self.faceBiased(photo.catBoundingBox),", hero)
        self.assertIn("y: box.maxY - box.height / 3", hero)
        # A scrim for the white name in both colour schemes, then a fade into the page.
        # 11/13: the scrim's stops are pinned in CatHomePolish1113Tests (lighter).
        self.assertIn("LinearGradient(stops: [.init(color: .black.opacity(0), location: 0.5),", hero)
        self.assertIn("Color(.systemGroupedBackground).opacity(0)", hero)
        # The name: large and heavy, scaling with a cap, two lines at accessibility sizes.
        self.assertIn("@ScaledMetric(relativeTo: .largeTitle) private var nameSize: CGFloat = 56", hero)
        self.assertIn(".font(.system(size: min(nameSize, 84), weight: .heavy))", hero)
        self.assertIn(".lineLimit(typeSize.isAccessibilitySize ? 2 : 1)", hero)
        self.assertIn(".minimumScaleFactor(0.5)", hero)
        self.assertIn(".accessibilityLabel(facts.spoken)", hero)
        # About 46% of the screen, less on short screens (iPhone SE).
        metrics = section(self.home, "struct CatHomeMetrics {", "/// One cat's page:")
        self.assertIn("heroHeight = (screen * (screen < 700 ? 0.40 : 0.46)).rounded()", metrics)
        # The photo runs under the status bar; no title; the tab bar stays.
        self.assertIn(".toolbar(.hidden, for: .navigationBar)", self.home)
        self.assertGreaterEqual(self.home.count(".ignoresSafeArea(.container, edges: .top)"), 3)
        self.assertNotIn(".toolbar(.hidden, for: .tabBar)", self.home)

    def test_name_line_says_only_what_is_known(self) -> None:
        facts = section(self.home, "struct CatHomeFacts {", "/// The five tools, in the order of the page.")
        self.assertIn('case .male: "オス"', facts)
        self.assertIn('case .female: "メス"', facts)
        self.assertIn('[sex, age].compactMap { $0 }.joined(separator: "・")', facts)
        self.assertIn('days.map { "うちに来て \\($0.formatted())日" }', facts)
        self.assertIn('parts.joined(separator: "　／　")', facts)
        # No line when nothing is known; never a count of days without the day.
        self.assertIn("line: parts.isEmpty ? nil : parts.joined", facts)
        self.assertIn("let adoption: Date? = profile?.lifeDates.adoptionDay?.date", facts)
        self.assertIn('"\\(years)歳\\(months)か月"', facts)
        # VoiceOver: 「むぎ、オス、4歳2か月、うちに来て1204日」.
        self.assertIn('[cat.name, sex, age, days.map { "うちに来て\\($0)日" }].compactMap { $0 }.joined(separator: "、")', facts)
        # A departed cat: the existing 旅立った日 wording as its one line.
        self.assertIn('line: "旅立った日　" + day', facts)
        self.assertIn("CatFarewell.text(farewell)", facts)

    def test_cat_menu_lists_every_cat_and_adds_one(self) -> None:
        menu = section(self.home, "    private func catMenuItems(", "    private func show(")
        self.assertIn("ForEach(cats) { cat in", menu)
        self.assertIn('.accessibilityIdentifier("tools-cat-menu-\\(cat.id)")', menu)
        self.assertIn('Button { addsCat = true } label: { Label("この子を追加", systemImage: "plus") }', menu)
        self.assertIn('.accessibilityIdentifier("tools-cat-profiles")', menu)
        # 11/14: the name on the photo opens these items.
        hero = section(self.home, "private struct CatHomeHero: View {", "/// The tools under the photo:")
        self.assertIn('.accessibilityLabel("猫を切り替える")', hero)
        self.assertIn(".accessibilityValue(cat.name)", hero)
        self.assertIn('.accessibilityIdentifier("tools-cat-menu")', hero)
        # Profiles, family cats without a profile here, then cats known only from the tools.
        cats = section(self.home, "    private var cats: [CatHomeCat] {", "    private func currentCat(")
        self.assertLess(cats.index("presentation.profiles.map"), cats.index("for cat in familyOnlyCats"))
        self.assertLess(cats.index("for cat in familyOnlyCats"), cats.index("for cat in states.toolCats"))
        self.assertIn("SavedToolCatChoices.cats(care: .shared, evacuation: .shared)", self.home)
        # 設定 top right, as before.
        bar = section(self.home, "    private var topBar: some View {", "    private func catMenuItems(")
        self.assertIn("SettingsGearIcon()", bar)
        self.assertIn('.accessibilityIdentifier("tools-settings-button")', bar)
        self.assertIn("Button(action: openSettings)", bar)

    def test_pages_swipe_and_remember_the_cat_once_they_rest(self) -> None:
        pager = section(self.home, "    private func pager(", "    /// The page 「この子のこと」 opens")
        self.assertIn(".scrollTargetBehavior(.paging)", pager)
        self.assertIn(".scrollPosition(id: $pageID)", pager)
        self.assertIn(".scrollDisabled(cats.count < 2)", pager)
        self.assertIn(".accessibilityHidden(cat.id != current.id)", pager)
        self.assertEqual(self.home.count("@AppStorage(\"catHome.selectedCat.v1\")"), 1)
        # Written after the pages rest, never mid-swipe.
        task = section(self.home, ".task(id: pageID) {", "    // MARK: Cats")
        self.assertLess(task.index("try? await Task.sleep(for: .milliseconds(700))"), task.index("storedCatID = pageID"))
        hero = section(self.home, "private struct CatHomeHero: View {", "/// The tools under the photo:")
        self.assertIn("if pageCount > 1 {", hero)

    def test_about_card_shows_progress_weight_and_birthday(self) -> None:
        # 11/14 (「猫を大切にできるページ」): 「この子のこと」 is the last row
        # of the care card, the name and a chevron, no count. The birthday
        # and the weight are rows of the same card (CatHomeCare*), pinned in
        # ci/test-cat-home-care.py.
        card = section(source("NekoWidget/Views/CatHomeCareView.swift"), "struct CatHomeCareCard: View {",
                       "    private struct Entry {")
        self.assertIn('CatHomeCareRow(title: "この子のこと", value: nil)', card)
        self.assertIn("NavigationLink { links.carePage } label: {", card)
        self.assertNotIn("CatHomeAboutCard", self.home)
        for gone in (".scaleEffect(x: facts.progressShare", 'CatHomeLine(title: "体重"', 'title: "誕生日まで"',
                     "progressText"):
            self.assertNotIn(gone, card)
        self.assertNotIn("progressShare", self.home)
        self.assertNotIn("static func weightText(", self.home)
        core = source("NekoWidget/Views/CatHomeCareCore.swift")
        self.assertIn('if days == 0 { return Value(text: "きょう", tone: .soon) }', core)
        self.assertIn('"\\(birthday.month)月\\(birthday.day)日（あと\\(days)日）"', core)

    def test_five_round_buttons_with_short_names_and_state_dots(self) -> None:
        tool = section(self.home, "enum CatHomeTool: CaseIterable {", "struct CatHomeView: View {")
        self.assertIn("case vet, care, lost, evacuation, showcase", tool)
        short = section(tool, "var shortTitle: String {", "var title: String {")
        names = ['"病院"', '"預ける"', '"迷子"', '"避難"', '"見せる"']
        self.assertEqual([short.index(name) for name in names], sorted(short.index(name) for name in names))
        for symbol in ('"cross.case"', '"hand.raised"', '"magnifyingglass"', '"backpack"', '"square.grid.3x3"'):
            self.assertIn(symbol, tool)
        for identifier in ("tools-vet-open", "tools-care-open", "tools-lost-cat-open",
                           "tools-evacuation-open", "tools-showcase-open"):
            self.assertIn(f'"{identifier}"', tool)
        button = section(self.home, "private struct CatHomeToolButton: View {", "/// The accessibility-size form of a tool")
        self.assertIn(".background(Color(.secondarySystemGroupedBackground), in: Circle())", button)
        self.assertIn("Circle().strokeBorder(Color(.separator), lineWidth: 1 / max(displayScale, 1))", button)
        # 11/14: no dot; 「書きかけ」 is on the 病院 row of 「これからのこと」.
        self.assertNotIn(".fill(state.color)", button)
        self.assertIn(".lineLimit(1)", button)
        self.assertIn(".minimumScaleFactor(0.7)", button)
        self.assertIn('.accessibilityLabel(state.map { "\\(tool.title)、\\($0.text)" } ?? tool.title)', button)
        bar = section(self.home, "private struct CatHomeToolBar: View {", "/// A round button:")
        self.assertIn('if tool == .vet && vetUnfinished { return (text: "書きかけ", color: Color.orange) }', bar)
        self.assertIn('if tool == .lost && searching { return (text: "探しています", color: Color.red) }', bar)
        # Accessibility sizes: the rows with the full name and the state.
        self.assertIn("if typeSize.isAccessibilitySize {", bar)
        self.assertIn("CatHomeToolRow(tool: tool, state: state(tool))", bar)
        self.assertIn(".accessibilityIdentifier(tool.identifier)", bar)
        # The page passes all five, in order, under the photo.
        page = section(self.home, "private struct CatHomePage: View {", "/// The cat's key photo from the very top")
        self.assertIn("CatHomeToolBar(cat: cat, toolsShown: CatHomeTool.allCases,", page)

    def test_tool_states_are_read_after_drawing(self) -> None:
        states = section(self.home, "final class CatHomeToolStates: ObservableObject {", "/// What the page says about a cat")
        self.assertIn("await Task.yield()", states)
        self.assertIn("try? await VeterinaryVisitStore.shared.visits()", states)
        self.assertIn(".mapValues { $0.map { CatHomeCareCore.VetMemo($0) } }", states)
        self.assertIn("completedAt == nil && hasContent", source("NekoWidget/Views/CatHomeCareCore.swift"))
        self.assertIn("LostCatDraftStore.shared.drafts.filter { $0.value.isSearching }", states)
        self.assertIn('searchingKeys.contains("guest-tool-" + cat.id)', states)
        self.assertIn(".onAppear { Task { await states.refresh() } }", self.home)

    def test_the_four_states(self) -> None:
        # No cat: のわ, one sentence, one button; the two household tools only.
        empty = section(self.home, "private struct CatHomeNoCatPage: View {", "private struct CatHomePressStyle")
        self.assertIn('Image("Nowa-sit-up")', empty)
        self.assertIn('Text("この子を追加すると、ここに出ます。")', empty)
        self.assertIn('Text("この子を追加")', empty)
        self.assertIn(".nekoPrimaryButton()", empty)
        self.assertIn("toolsShown: CatHomeTool.household", empty)
        self.assertIn("static let household: [CatHomeTool] = [.evacuation, .showcase]", self.home)
        # 11/13: 設定 scrolls with the no-cat page too (was a bar pinned over it).
        self.assertIn("CatHomeNoCatPage(metrics: metrics, tools: tools, topBar: AnyView(topBar)) {\n"
                      "                        addsCat = true", self.home)
        # No key photo: a calm gradient, no placeholder icon.
        hero = section(self.home, "private struct CatHomeHero: View {", "/// The tools under the photo:")
        self.assertIn("LinearGradient(colors: [Color(red: 0.56, green: 0.57, blue: 0.60)", hero)
        self.assertNotIn("cat.fill", hero)
        # Departed: name and the farewell line, この子のこと, no tools.
        page = section(self.home, "private struct CatHomePage: View {", "/// The cat's key photo from the very top")
        self.assertIn("if !facts.departed {", page)
        self.assertLess(page.index("if !facts.departed {"), page.index("CatHomeToolBar("))
        self.assertIn("CatHomeCareCard(rows: care, links: careLinks)", page)
        self.assertNotIn("if let care {", page)
        # A cat without a profile: a page under its name, its この子のこと by its household ID.
        self.assertIn("CatCareDetailView(toolCatID: toolID, name: cat.name)", self.home)

    def test_tools_open_for_the_page_cat_without_their_own_menu(self) -> None:
        tools = section(self.tab, "private var catHomeTools: CatHomeTools {", "private func openShowcaseTool(")
        self.assertEqual(tools.count("fixedCatKey: key)"), 3)
        self.assertIn("openShowcaseTool(scopeID: profileID.flatMap { canOpenShowcase($0) ? $0 : nil } ?? showcaseCardScopeID)", tools)
        # Each tool defaults to today's behaviour (restored tools, links, tests).
        for text in (self.vet, self.care, self.lost):
            self.assertIn("var fixedCatKey: String? = nil", text)
        self.assertIn("let first = fixedStripCat ?? openable.first(where: { $0.id == lastCatID }) ?? openable.first", self.vet)
        self.assertIn("if ready, fixedStripCat == nil {", self.vet)
        self.assertIn("if store.loadError == nil, !stripCats.isEmpty, fixedStripCat == nil {", self.care)
        self.assertIn("if let fixed = fixedStripCat { select(fixed) } else { openFirst() }", self.care)
        self.assertIn("if fixedStripCat != nil { return true }", self.care)
        # 預けるとき keeps お願いする猫 (several cats for one memo).
        self.assertIn("profilesWithoutMemo", self.care)
        self.assertIn('editor(fixed.id, fixed.profile?.displayName ?? "", cats: [])', self.lost)
        self.assertIn('$0.id.uppercased() == "GUEST-TOOL-" + key', self.lost)
        # 写真を見せる opens on the page's cat; 避難に備える is the same from every page.
        self.assertIn("Button { tools.showcase(cat?.profile?.identifier) } label: { content }", self.home)
        self.assertIn("guard let catID = route.catID else { return tools.evacuation() }", self.home)
        self.assertIn("case .care: return tools.care(catID)", self.home)


class CatHomePolish1113Tests(unittest.TestCase):
    """11/13, after the owner's look on device: a lighter scrim, live-looking
    controls over the photo, 「誕生日まで」 only when near, 迷子 in words, and
    a key photo from any cat photo (added to the cat first)."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.home = source("NekoWidget/Views/CatHomeView.swift")
        cls.care = source("NekoWidget/Views/CatCareView.swift")
        cls.curation = source("NekoWidget/Views/CatProfilePhotoCurationViews.swift")
        cls.presentation = source("NekoWidget/Views/CatProfilesPresentation.swift")
        cls.root = source("NekoWidget/App/AppRootView.swift")

    def test_scrim_leaves_the_upper_half_untouched(self) -> None:
        hero = section(self.home, "private struct CatHomeHero: View {", "/// The tools under the photo:")
        # Replaces the 0.3 -> 0.72 pin: nothing above half, about 0.6 at the bottom.
        self.assertIn(".init(color: .black.opacity(0), location: 0.5),", hero)
        self.assertIn(".init(color: .black.opacity(0.6), location: 1)]", hero)
        self.assertNotIn("opacity(0.72)", hero)
        self.assertNotIn("location: 0.3)", hero)
        # The fade into the page and the text shadow stay.
        self.assertIn("Color(.systemGroupedBackground).opacity(0)", hero)
        self.assertIn(".shadow(color: .black.opacity(0.45), radius: 8, y: 1)", hero)

    def test_cat_menu_and_settings_read_as_live_controls(self) -> None:
        # 11/14: the capsule is gone; the name on the photo is the cat menu
        # (pinned in ci/test-cat-home-care.py), 設定 stays top right.
        self.assertNotIn("in: Capsule())", self.home)
        hero = section(self.home, "private struct CatHomeHero: View {", "/// The tools under the photo:")
        self.assertIn(".frame(minHeight: 44)", hero)
        self.assertIn('.accessibilityIdentifier("tools-cat-menu")', hero)
        bar = section(self.home, "    private var topBar: some View {", "    private func catMenuItems(")
        self.assertIn(".background(.ultraThinMaterial, in: Circle())", bar)
        self.assertIn(".frame(width: 40, height: 40)", bar)
        self.assertIn(".frame(minWidth: 44, minHeight: 44)", bar)
        self.assertIn('.accessibilityIdentifier("tools-settings-button")', bar)
        self.assertNotIn("Color.black.opacity(0.32)", self.home)

    def test_birthday_line_only_within_thirty_days(self) -> None:
        # 11/14: the birthday card left the page; the birthday is always the
        # first row of 「これからのこと」, in the text colour within 7 days,
        # and on the day the hero's line says 「きょうで5歳」.
        facts = section(self.home, "struct CatHomeFacts {", "/// The five tools, in the order of the page.")
        self.assertNotIn("birthdaySoonDays", facts)
        self.assertIn("CatHomeCareCore.heroDayLine(", facts)
        core = source("NekoWidget/Views/CatHomeCareCore.swift")
        self.assertIn("static let soonDays = 7", core)
        self.assertIn("tone: days <= soonDays ? .soon : .quiet", core)
        self.assertNotIn("CatHomeBirthdayCard", source("NekoWidget/Views/CatHomeCareView.swift"))

    def test_searching_is_a_line_not_a_red_dot(self) -> None:
        button = section(self.home, "private struct CatHomeToolButton: View {", "/// The accessibility-size form of a tool")
        # 11/14: no dot at all; 迷子 is this line, 「書きかけ」 the 病院 row.
        self.assertNotIn("if let state, tool != .lost {", button)
        self.assertNotIn(".fill(state.color)", button)
        # VoiceOver on the button still says 「迷子のとき、探しています」.
        self.assertIn('.accessibilityLabel(state.map { "\\(tool.title)、\\($0.text)" } ?? tool.title)', button)
        bar = section(self.home, "private struct CatHomeToolBar: View {", "/// A round button:")
        self.assertIn('if tool == .lost && searching { return (text: "探しています", color: Color.red) }', bar)
        line = section(self.home, "private struct CatHomeSearchingLine: View {", "/// A round button:")
        self.assertIn("NavigationLink(value: CatHomeRoute(tool: .lost, catID: cat.id)) {", line)
        self.assertIn('Text("\\(cat.name)を探しています")', line)
        self.assertIn("ToolChevron()", line)
        self.assertIn('.accessibilityIdentifier("cat-home-searching")', line)
        page = section(self.home, "private struct CatHomePage: View {", "/// The cat's key photo from the very top")
        self.assertIn("if searching { CatHomeSearchingLine(cat: cat) }", page)
        self.assertLess(page.index("CatHomeToolBar("), page.index("CatHomeSearchingLine(cat: cat)"))
        self.assertLess(page.index("CatHomeSearchingLine(cat: cat)"), page.index("CatHomeCareCard("))
        # It ends with 「この迷子の記録を終える」: hasIncident goes false.
        incident = source("NekoWidget/Services/LostCatIncident.swift")
        ending = section(incident, "func endingIncident() -> LostCatDraft {", "/// The offices step 2")
        for cleared in ('next.lastSeenNear = ""', "next.lastSeenAt = nil", "next.incident = nil"):
            self.assertIn(cleared, ending)
        self.assertIn(".onAppear { Task { await states.refresh() } }", self.home)

    def test_key_photo_from_any_cat_photo_is_added_first(self) -> None:
        # Replaces the 「写真タブでこの子の写真を追加すると選べます」 pin.
        self.assertNotIn("写真タブでこの子の写真を追加すると選べます", self.care)
        heading = section(self.care, "private func profileHeading(", "private var isProfile: Bool {")
        self.assertIn("let hasPhotos = profile.hasKeyPhotoChoices", heading)
        self.assertIn(".disabled(!hasPhotos)", heading)
        self.assertIn('Text("猫の写真が見つかると選べます")', heading)
        sheet = section(self.care, ".sheet(isPresented: $showsKeyPhotoPicker) {", ".task(id: subject.key) {")
        self.assertIn("photos: profile.confirmedPhotos,", sheet)
        self.assertIn("choose: { await chooseKeyPhoto($0, for: profile) },", sheet)
        self.assertIn("otherPhotos: profile.otherKeyPhotoCandidates,", sheet)
        self.assertIn('otherHeading: "ほかの猫の写真"', sheet)
        choose = section(self.care, "private func chooseKeyPhoto(", "private var isProfile: Bool {")
        self.assertIn("guard await profileActions.confirmProfileMembership(profile.identifier, [identifier]) else { return false }",
                      choose)
        self.assertLess(choose.index("confirmProfileMembership"), choose.index("setKeyPhoto"))
        # The model rule stays: a key photo must be this cat's photo.
        model = source("Shared/Models/CatHouseholdIdentity.swift")
        self.assertIn("confirmsAsset(assetLocalIdentifier, for: profileID) else { return }", model)
        # Excluded for this cat stays out; household exclusions are never candidates.
        self.assertIn("var excludedPhotoIdentifiers: Set<String> = []", self.presentation)
        self.assertIn("manualCandidatePhotos.filter { !excludedPhotoIdentifiers.contains($0.localIdentifier) }",
                      self.presentation)
        self.assertIn(".filter { $0.decision == .excluded }", self.root)
        # One lazy grid for both parts.
        grid = section(self.curation, "private struct CatSelectablePhotoGrid: View {", "private func toggle(")
        self.assertIn("LazyVGrid(columns: columns, spacing: 3) {", grid)
        self.assertIn("ForEach(otherPhotos) { photo in cell(photo) }", grid)
        picker = section(self.curation, "struct CatProfilePhotoPicker: View {", "private struct CatSelectablePhotoGrid")
        self.assertIn("if photos.isEmpty && otherPhotos.isEmpty {", picker)
        self.assertIn("otherPhotos: otherPhotos,", picker)

    def test_album_link_has_one_entry_beside_adding_photos(self) -> None:
        main = source("NekoWidget/Views/MainTabView.swift")
        row = section(main, "private var photoLibraryCatRow: some View {", "private var photoLibraryCatPicker: some View {")
        self.assertIn("CatProfilePhotoAlbumLinkButton(profile: profile, albums: catProfilesPresentation.photoAlbumOptions,", row)
        self.assertLess(row.index("CatProfileAddPhotosButton("), row.index("CatProfilePhotoAlbumLinkButton("))
        button = section(self.curation, "struct CatProfilePhotoAlbumLinkButton: View {",
                         "private struct CatProfilePhotoAlbumLinkSheet: View {")
        self.assertIn('Label(profile.photoAlbumLink?.displayTitle ?? "写真アプリのアルバムをつなぐ",', button)
        self.assertIn('.accessibilityIdentifier("cat-photo-album-link")', button)
        sheet = section(self.curation, "private struct CatProfilePhotoAlbumLinkSheet: View {", "extension CatProfilePresentation {")
        self.assertIn('Text("このアルバムの写真を、\\(profile.displayName)の写真として扱います。")', sheet)
        self.assertIn('.accessibilityIdentifier("cat-photo-album-link-row-\\(index)")', sheet)
        self.assertIn('Button("つなぐのをやめる", role: .destructive) { link(nil) }', sheet)
        self.assertIn('.accessibilityIdentifier("cat-photo-album-unlink")', sheet)
        self.assertIn("await actions.refreshPhotoAlbums()", sheet)
        self.assertIn("let saved = await actions.setProfilePhotoAlbum(profile.identifier, albumIdentifier)", sheet)
        # A refusal (the app's own source album included) is said, not swallowed.
        self.assertIn("failure = actions.currentErrorMessage()", sheet)
        self.assertIn("currentErrorMessage: { viewModel.errorMessage }", self.root)
        model = source("NekoWidget/ViewModels/AppViewModel.swift")
        self.assertIn("guard localIdentifier != snapshot.albumLocalIdentifier,", model)


class CatIdentityMeasure1113Tests(unittest.TestCase):
    """11/13: measuring how well cheap on-device signals tell two cats apart.
    Owner test builds only; nothing leaves the phone; the copy is numbers only."""

    SERVICE = "NekoWidget/Services/CatIdentityMeasurement.swift"
    VIEW = "NekoWidget/Views/CatIdentityMeasureView.swift"
    TEST = "NekoWidgetTests/CatIdentityMeasurementTests.swift"
    GATE = "#if DEBUG || INTERNAL_PRESENTATION\n"

    def setUp(self) -> None:
        self.service = source(self.SERVICE)
        self.view = source(self.VIEW)
        self.project = source("NekoWidget.xcodeproj/project.pbxproj")

    def test_new_files_are_registered_once(self) -> None:
        for name, number in (("CatIdentityMeasurement.swift", "1"), ("CatIdentityMeasureView.swift", "3")):
            file_id = "C1D3A911000000000000000" + str(int(number) + 1)
            build_id = "C1D3A911000000000000000" + number
            self.assertEqual(self.project.count(f"path = {name};"), 1, name)
            self.assertEqual(self.project.count(f"/* {name} in Sources */"), 2, name)
            self.assertIn(f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; "
                          f"fileRef = {file_id} /* {name} */; }};", self.project)
            self.assertEqual(self.project.count(f"\t\t\t\t{file_id} /* {name} */,\n"), 1, name)
        app = self.project.index("A00000000000000000000021 /* Sources */ = {")
        app_sources = self.project[app:self.project.index("};", self.project.index("files = (", app))]
        self.assertIn("/* CatIdentityMeasurement.swift in Sources */", app_sources)
        self.assertIn("/* CatIdentityMeasureView.swift in Sources */", app_sources)
        services = self.project.index("C1D3A9110000000000000002 /* CatIdentityMeasurement.swift */,\n")
        self.assertLess(self.project.index("path = Services;", services) - services, 120)
        self.assertIn("path = CatIdentityMeasurementTests.swift;", self.project)
        # 11/13: SingleCatPhotosTests (C15C0A7E…) and AlbumLinkFollowupsTests
        # (C1A1BF10…) joined the same test target, then CatThresholdTests
        # (C1CA7050…, the 0.5 cat line and its migration), then
        # CatHomeCareTests (C1E0A7E0…, the この子 page's 「これからのこと」).
        self.assertIn("children = (C1108C000000000000000002,C1D3A9110000000000000006,"
                      "C15C0A7E0000000000000002,C1A1BF100000000000000002,C1CA70500000000000000002,"
                      "C1E0A7E00000000000000002,); path = NekoWidgetTests;", self.project)
        self.assertIn("files = (C1108C000000000000000003,C1D3A9110000000000000005,"
                      "C15C0A7E0000000000000001,C1A1BF100000000000000001,C1CA70500000000000000001,"
                      "C1E0A7E00000000000000001,);", self.project)
        self.assertEqual(len(set(re.findall(r"C1D3A911000000000000000\d", self.project))), 6)

    def test_store_product_compiles_none_of_it(self) -> None:
        for relative in (self.SERVICE, self.VIEW, self.TEST):
            text = source(relative)
            self.assertTrue(text.startswith(self.GATE) or text.split("\n", 1)[0] == self.GATE.strip(), relative)
            self.assertTrue(text.rstrip().endswith("#endif"), relative)
            self.assertEqual(text.count("#if "), 1, relative)
        # The one entry: a row inside 設定 → テスト用, only where test tools show.
        settings = source("NekoWidget/Views/SettingsView.swift")
        row = 'NavigationLink("猫の見分けを測る（テスト用）") { CatIdentityMeasureView() }'
        self.assertEqual(settings.count("CatIdentityMeasureView"), 1)
        gate = settings.rindex("#if DEBUG || INTERNAL_PRESENTATION", 0, settings.index(row))
        self.assertLess(settings.index("if InternalBuildPresentationAvailability.isAvailable {", gate), settings.index(row))
        self.assertLess(settings.index(row), settings.index("#endif", gate))
        for folder in ("NekoWidget", "Shared", "NekoWidgetWidget", "NekoWidgetShareExtension"):
            for path in (ROOT / folder).rglob("*.swift"):
                if path.name in ("CatIdentityMeasurement.swift", "CatIdentityMeasureView.swift", "SettingsView.swift"):
                    continue
                self.assertNotIn("CatIdentityMeasure", path.read_text(encoding="utf-8"), str(path))
        # The App Store candidate refuses both compile conditions outright.
        candidate = source("ci/production_candidate.py")
        self.assertIn('forbidden = {"DEBUG", "INTERNAL_PRESENTATION", "WIDGET_SCREENSHOT_FIXTURE"}', candidate)
        self.assertIn('"INTERNAL_PRESENTATION_CONDITION": ""', candidate)

    def test_photos_stay_on_the_phone(self) -> None:
        self.assertIn("options.isNetworkAccessAllowed = false", self.service)
        self.assertNotIn("isNetworkAccessAllowed = true", self.service)
        for gone in ("URLSession", "URLRequest", "SharedLog", "print(", "Logger", "os_log", "NSLog",
                     "jpegData", "pngData", "heicData", "UserDefaults", "PHAssetChangeRequest",
                     "PHAssetCollectionChangeRequest", "systemUptime", "mach_absolute_time"):
            self.assertNotIn(gone, self.service, gone)
            self.assertNotIn(gone, self.view, gone)
        # Read only: the stores are loaded, never saved.
        self.assertIn("try await LibraryStore().load().assets", self.service)
        self.assertIn("try await CatHouseholdIdentityStore().load()", self.service)
        # The only file written is the result text, in this app's caches.
        self.assertEqual(self.service.count(".write(to:"), 1)
        self.assertIn("try? Data(text.utf8).write(to: url, options: .atomic)", self.service)
        self.assertIn(".cachesDirectory", self.service)
        self.assertIn("UIApplication.shared.isIdleTimerDisabled = false", self.view)
        self.assertIn("if phase == .background {", self.view)
        self.assertIn("static let concurrentPhotos = 2", self.service)

    def test_copied_text_has_no_identifiers_names_or_dates(self) -> None:
        summary = section(self.service, "    static func summaryText(", "    /// One sentence for the empty / blocked state.")
        for gone in ("localIdentifier", "displayName", "name:", "creationDate", "Date()", "URL", "path",
                     "profile.id", "uuid", "UUID", "box"):
            self.assertNotIn(gone, summary, gone)
        facts = section(self.service, "struct CatIdentityRunFacts", "enum CatIdentityMeasurementCore {")
        self.assertNotIn("String]", facts)
        self.assertEqual(facts.count(": String") + facts.count(' = ""'), 2)  # model and OS only
        self.assertIn("plainToken(facts.deviceModel)", summary)
        self.assertIn("plainToken(facts.systemVersion)", summary)
        self.assertIn('"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789,._"', self.service)
        self.assertIn("UIPasteboard.general.string = resultText", self.view)
        self.assertIn('"結果をコピー"', self.view)

    def test_protocol_is_fixed(self) -> None:
        for pinned in ("static let referenceCounts = [3, 10, 30, 100]", "static let repeats = 3",
                       "static let testCapPerCat = 300", "static let minimumTruthPerCat = 40",
                       "static let neighbourCount = 5", "static let cropPadding = 0.10",
                       "static let requestPixels = 512",
                       "request.revision = VNGenerateImageFeaturePrintRequestRevision2"):
            self.assertIn(pinned, self.service)
        truth = section(self.service, "    static func select(records:", "// MARK: - On-device run")
        self.assertIn("identity.confirmedAssetIdentifiers(for: $0.id)", truth)
        self.assertIn("guard profiles.count == 1", truth)
        self.assertIn("guard boxes.count == 1, record.cat.catCount <= 1", truth)


class CatPhotoCoverage1113Tests(unittest.TestCase):
    """11/13: 「出てこない写真の内訳」 on the same internal screen. Every photo in
    the linked albums lands in one bucket; misses are rechecked on the phone
    only; the copy is numbers and bucket names only."""

    SERVICE = "NekoWidget/Services/CatPhotoCoverageMeasurement.swift"
    VIEW = "NekoWidget/Views/CatIdentityMeasureView.swift"
    TEST = "NekoWidgetTests/CatIdentityMeasurementTests.swift"
    GATE = "#if DEBUG || INTERNAL_PRESENTATION\n"

    def setUp(self) -> None:
        self.service = source(self.SERVICE)
        self.view = source(self.VIEW)
        self.project = source("NekoWidget.xcodeproj/project.pbxproj")

    def test_file_is_registered_once_in_the_app_target(self) -> None:
        name = "CatPhotoCoverageMeasurement.swift"
        self.assertEqual(self.project.count(f"path = {name};"), 1)
        self.assertIn(f"\t\tC1D3C0E70000000000000001 /* {name} in Sources */ = {{isa = PBXBuildFile; "
                      f"fileRef = C1D3C0E70000000000000002 /* {name} */; }};", self.project)
        self.assertEqual(self.project.count(f"\t\t\t\tC1D3C0E70000000000000002 /* {name} */,\n"), 1)
        app = self.project.index("A00000000000000000000021 /* Sources */ = {")
        app_sources = self.project[app:self.project.index("};", self.project.index("files = (", app))]
        self.assertIn(f"/* {name} in Sources */", app_sources)
        self.assertEqual(len(set(re.findall(r"C1D3C0E7\d{16}", self.project))), 2)
        # Tests live beside the identity tests (no new test file to register).
        self.assertIn("final class CatPhotoCoverageMeasurementTests: XCTestCase {", source(self.TEST))

    def test_store_product_compiles_none_of_it(self) -> None:
        self.assertTrue(self.service.startswith(self.GATE))
        self.assertTrue(self.service.rstrip().endswith("#endif"))
        self.assertEqual(self.service.count("#if "), 2)  # the gate + the simulator CPU switch
        self.assertIn("#if targetEnvironment(simulator)", self.service)
        for folder in ("NekoWidget", "Shared", "NekoWidgetWidget", "NekoWidgetShareExtension"):
            for path in (ROOT / folder).rglob("*.swift"):
                if path.name in ("CatPhotoCoverageMeasurement.swift", "CatIdentityMeasureView.swift"):
                    continue
                self.assertNotIn("CatPhotoCoverage", path.read_text(encoding="utf-8"), str(path))

    def test_photos_stay_on_the_phone(self) -> None:
        self.assertEqual(self.service.count("options.isNetworkAccessAllowed = false"), 1)
        self.assertNotIn("isNetworkAccessAllowed = true", self.service)
        for gone in ("URLSession", "URLRequest", "SharedLog", "print(", "Logger", "os_log", "NSLog",
                     "jpegData", "pngData", "heicData", "UserDefaults", "PHAssetChangeRequest",
                     "PHAssetCollectionChangeRequest", ".save(", "AtomicJSON.write"):
            if gone == ".save(":
                self.assertEqual(self.service.count(gone), 0, gone)
                continue
            self.assertNotIn(gone, self.service, gone)
        # Read only: stores are loaded, the curation file is decoded directly.
        self.assertIn("snapshot = try await LibraryStore().load()", self.service)
        self.assertIn("try await CatHouseholdIdentityStore().load()", self.service)
        self.assertIn("try AtomicJSON.read(CatCandidateCurationState.self, from: url)", self.service)
        self.assertNotIn("CatCandidateCurationStore()", self.service)
        self.assertEqual(self.service.count(".write(to:"), 1)
        self.assertIn("try? Data(text.utf8).write(to: url, options: .atomic)", self.service)
        self.assertIn('"cat-photo-coverage-last.txt"', self.service)
        self.assertIn("static let concurrentPhotos = 2", self.service)
        self.assertIn("static let requestPixels = 1_024", self.service)
        # Same fetch as the scanner, so "not in the scan fetch" is exact.
        self.assertIn("PhotoSourceAlbumCatalog.fetchImageAssets(", self.service)
        model = section(self.view, "final class CatPhotoCoverageModel", "struct CatIdentityMeasureView: View {")
        self.assertIn("UIApplication.shared.isIdleTimerDisabled = true", model)
        self.assertIn("UIApplication.shared.isIdleTimerDisabled = false", model)
        self.assertIn('coverage.stop("アプリが裏に回ったので止めました。もう一度押してください。")', self.view)
        self.assertIn('Button("出てこない写真を数える") { coverage.start() }', self.view)
        self.assertIn("CatPhotoCoverageResultCache.load()", model)

    def test_copied_text_has_no_identifiers_names_or_dates(self) -> None:
        summary = section(self.service, "    static func summaryText(", "// MARK: - On-device run")
        for gone in ("localIdentifier", "displayName", "name", "creationDate", "Date()", "URL", "path",
                     "profile", "uuid", "UUID", "title", "identifier"):
            self.assertNotIn(gone, summary, gone)
        # 11/13 v2: two numbers-only lines on the stored best cat confidence.
        self.assertIn('lines.append("cat-photo-coverage v2")', summary)
        self.assertNotIn('"cat-photo-coverage v1"', summary)
        self.assertIn('lines.append("stored best cat, in linked albums: "', summary)
        self.assertIn('lines.append("stored best cat, elsewhere: "', summary)
        self.assertIn("plainToken(facts.deviceModel)", summary)
        self.assertIn("plainToken(facts.systemVersion)", summary)
        for struct in ("struct CatPhotoCoverageRunFacts", "struct CatPhotoCoverageLibraryFacts",
                       "struct CatPhotoCoverageFacts", "struct CatPhotoRecognitionSample"):
            body = section(self.service, struct, "\n}\n")
            self.assertNotIn("[String", body, struct)
            self.assertNotIn("Date", body, struct)
        facts = section(self.service, "struct CatPhotoCoverageRunFacts", "\n}\n")
        self.assertEqual(facts.count(' = ""'), 2)  # model and OS only
        self.assertIn("UIPasteboard.general.string = resultText", self.view)

    def test_each_photo_lands_in_one_bucket(self) -> None:
        core = section(self.service, "    static func bucket(", "    /// Index into")
        self.assertIn("guard facts.foundInPhotoKit else { return .notInPhotoKit }", core)
        for bucket in ("shown", "judgedNotCat", "notImage", "hiddenInPhotos", "burstNotPick", "burstDuplicate",
                       "screenshot", "outsideScanSource", "notInScanFetchOther", "notYetScanned", "onlyInCloud",
                       "loadFailed", "householdExcluded", "hiddenBySourceAlbum", "olderSettings"):
            self.assertIn(f".{bucket}", core, bucket)
        # Linked albums only; household exclusions stay in so they can be counted.
        self.assertIn("profile.photoAlbumLink", self.service)
        self.assertNotIn("confirmedAssetIdentifiers", self.service)
        self.assertIn("fetchOptions.includeHiddenAssets = true", self.service)
        self.assertIn("fetchOptions.includeAllBurstAssets = true", self.service)


if __name__ == "__main__":
    unittest.main()
