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
        self.assertIn('"いま届いた・家族から"', home)
        self.assertIn('Text("ほか \\(familyWindowPresentation.safeCount - 1)枚")', home)
        self.assertIn('accessibilityIdentifier("window-latest-family-photo")', home)
        self.assertIn("showsFamilyWindow = true", home)


if __name__ == "__main__":
    unittest.main()
