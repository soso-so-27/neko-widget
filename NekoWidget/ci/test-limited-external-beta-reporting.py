#!/usr/bin/env python3
"""Source contract for the fail-closed one-person external beta boundary."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = ROOT.parent


class LimitedExternalBetaReportingTests(unittest.TestCase):
    def source(self, relative: str) -> str:
        return (ROOT / relative).read_text(encoding="utf-8")

    def test_encrypted_reporting_is_centrally_fail_closed(self) -> None:
        configuration = self.source(
            "Shared/Sharing/SharingAPIConfiguration.swift"
        )
        self.assertIn(
            "var isEncryptedReportAvailable: Bool { false }",
            configuration,
        )
        self.assertNotIn(
            "var isEncryptedReportAvailable: Bool { true }",
            configuration,
        )

        workflow = (REPOSITORY / ".github/workflows/testflight.yml").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("ENCRYPTED_REPORT_ENABLED", workflow)
        self.assertNotIn("REPORTING_ENABLED", workflow)
        self.assertIn(
            'python3 "$PROJECT_DIRECTORY/ci/test-limited-external-beta-reporting.py"',
            workflow,
        )
        self.assertIn(
            "media-stagingは内部またはBuild 71候補の外部1人限定",
            workflow,
        )
        for expected in (
            'expected_media_origin="https://neko-window-sharing-staging.nakanishisoya.workers.dev"',
            'expected_media_privacy_url="https://soso-so-27.github.io/neko-widget/privacy/"',
            'expected_media_support_url="https://soso-so-27.github.io/neko-widget/support/"',
            'expected_media_community_url="https://soso-so-27.github.io/neko-widget/community/"',
            'NEKO_STAGING_API_ORIGIN="$RELEASE_SHARING_API_ORIGIN"',
            "node scripts/check-staging-runtime.mjs --expected limited-external-beta",
        ):
            self.assertIn(expected, workflow)

    def test_view_model_refuses_report_submission(self) -> None:
        model = self.source("NekoWidget/ViewModels/MomentSharingViewModel.swift")
        self.assertIn(
            "guard configuration.isEncryptedReportAvailable,",
            model,
        )
        self.assertIn(
            "configuration.isEncryptedReportAvailable\n"
            "            && !isShowingLastKnownState",
            model,
        )

        coordinator = self.source(
            "NekoWidget/Services/MomentSharingCoordinator.swift"
        )
        self.assertIn(
            "guard configuration.isEncryptedReportAvailable,\n"
            "              configuration.isMediaAvailable,",
            coordinator,
        )
        self.assertIn(
            "guard configuration.isEncryptedReportAvailable else { return 0 }",
            coordinator,
        )
        self.assertLess(
            coordinator.index(
                "guard configuration.isEncryptedReportAvailable else { return 0 }"
            ),
            coordinator.index(
                "let snapshot = try MomentSharingStateStore.load().reportOutbox"
            ),
        )

    def test_ui_hides_report_and_exposes_beta_safety_fallback(self) -> None:
        family = self.source("NekoWidget/Views/FamilyWindowView.swift")
        self.assertGreaterEqual(
            family.count("if model.isEncryptedReportAvailable"),
            4,
        )
        for phrase in (
            "TestFlightのベータ版フィードバック",
            "この相手をブロック",
            "サポートを開く",
            "写真・招待コード・確認フレーズ・鍵を添付せず",
        ):
            self.assertIn(phrase, family)

        settings = self.source("NekoWidget/Views/SettingsView.swift")
        self.assertIn(
            "if SharingAPIConfiguration.current.isEncryptedReportAvailable",
            settings,
        )
        self.assertIn("TestFlightから問題を連絡", settings)

    def test_app_store_pack_limits_the_only_exception_to_one_report_off_tester(self) -> None:
        pack = self.source("docs/App-Store-提出パック.md")
        for phrase in (
            "唯一の例外は、第8節のBuild 71候補",
            "暗号化通報受付をserver／clientの両方でOFFに固定",
            "public link OFF、信頼できる外部tester 1人",
            "この例外を2人目以降、別build、App Store Reviewまたは一般公開の承認として流用しない",
        ):
            self.assertIn(phrase, pack)

        media_guide = self.source("docs/Media-Staging-TestFlight手順.md")
        actions_guide = self.source("docs/GitHub-Actions-TestFlight設定.md")
        for source in (media_guide, actions_guide):
            self.assertIn("Build 71候補", source)
            self.assertIn("外部1人限定", source)
        self.assertIn("report-ingestion=OFF", media_guide)
        self.assertIn("public linkはOFF", media_guide)
        self.assertIn("Build 71専用の新しいexternal group", media_guide)
        self.assertIn("既存の`友人テスト`groupを使わない", pack)

        operations = (
            ROOT / "SharingService" / "PERSONAL_STAGING_OPERATIONS.md"
        ).read_text(encoding="utf-8")
        for phrase in (
            "Build 71候補を既知で信頼できる外部tester 1人だけ",
            "reportをclient／serverともOFF",
            "staging:runtime:limited-external-beta:check",
            "report 3経路を省略しない",
        ):
            self.assertIn(phrase, operations)
        self.assertNotIn(
            "check-staging-runtime.mjs --expected on",
            operations,
        )


if __name__ == "__main__":
    unittest.main()
