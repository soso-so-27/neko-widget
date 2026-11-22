"""11/20 source contracts for the scan pipeline and export defect fixes.

These bind the shipping source to the decisions that a Swift verify script
cannot reach (SwiftUI scene phases, PhotoKit callbacks, AVAssetWriter). The
pure rules themselves are executed in ci/verify-scan-recovery-policy.swift,
ci/verify-seasonal-movie-archive.swift and the XCTest suites.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def block(text: str, start: str, end: str) -> str:
    tail = text[text.index(start):]
    return tail[:tail.index(end)]


VM = source("NekoWidget/ViewModels/AppViewModel.swift")
ROOT_VIEW = source("NekoWidget/App/AppRootView.swift")
SCANNER = source("NekoWidget/Services/PhotoLibraryScanner.swift")


class RescanKeepsResults(unittest.TestCase):
    def test_rescan_supersedes_instead_of_hiding(self):
        rescan = block(VM, "func rescan() async {", "func resumeScan()")
        self.assertIn("settings = settings.startingRescan()", rescan)
        self.assertNotIn("analysisRevision += 1", rescan)
        update = block(VM, "func updateSettings(_ newSettings: AppSettings)", "func exportJSON()")
        self.assertIn("settings.startingRescan()", update)
        self.assertIn("normalized.supersededAnalysisFingerprints = settings.supersededAnalysisFingerprints", update)
        perform = block(VM, "private func performScan(", "private func applyScanEvent(")
        self.assertLess(perform.index("applySnapshot(final)"),
                        perform.index("finishRescanPresentationIfComplete(scannedWith: final.settings)"))

    def test_every_cat_population_uses_the_same_rule(self):
        snapshot = source("Shared/Models/LibrarySnapshot.swift")
        record = source("Shared/Models/AssetRecord.swift")
        selectors = source("NekoWidget/Services/PhotoSelectors.swift")
        for text in (snapshot, record, selectors, ROOT_VIEW):
            self.assertIn("presentsAnalysis(fingerprint:", text)
        self.assertNotIn("$0.analysisFingerprint == fingerprint", snapshot)
        self.assertNotIn("asset.analysisFingerprint == fingerprint", ROOT_VIEW)

    def test_interrupted_rescan_reuses_its_results(self):
        self.assertIn("ScanResumePolicy.mayReuse(", SCANNER)
        self.assertNotIn("(!forceFullAnalysis\n", SCANNER)


class ForegroundAndPower(unittest.TestCase):
    def test_inactive_does_not_stop_the_scan(self):
        phase = block(ROOT_VIEW, ".onChange(of: scenePhase) { _, newPhase in", "@unknown default:")
        inactive = block(phase, "case .inactive:", "case .background:")
        self.assertNotIn("suspendScan", inactive)
        self.assertIn("viewModel.suspendScan()", phase[phase.index("case .background:"):])
        sync = block(VM, "private func synchronizeOnActive(", "private func libraryIsUnchangedSinceLastPass()")
        self.assertIn("if isScanning, !libraryChangePending { return }", sync)

    def test_screen_hold_follows_heat_and_low_power(self):
        self.assertIn(".modifier(ScanScreenHold(isScanning: viewModel.isScanning, scenePhase: scenePhase))", ROOT_VIEW)
        hold = block(ROOT_VIEW, "private struct ScanScreenHold: ViewModifier", "/// One foreground operation")
        self.assertIn("ProcessInfo.thermalStateDidChangeNotification", hold)
        self.assertIn("NSProcessInfoPowerStateDidChange", hold)
        self.assertIn("ScanPowerPolicy.holdsScreenAwake(", hold)
        self.assertNotIn("AppIdleTimer.setPreventSleep(isScanning && scenePhase == .active, for: \"photo-scan\")",
                         ROOT_VIEW)
        self.assertIn("let concurrency = try await Self.currentAnalysisConcurrency()", SCANNER)
        self.assertIn("ScanPowerPolicy.analysisConcurrency(", SCANNER)

    def test_foreground_library_change_starts_a_pass(self):
        observer = block(VM, "private lazy var libraryObserver", "/// `scanner` and `changeTokens`")
        self.assertIn("self.scheduleForegroundLibraryChangeScan()", observer)
        schedule = block(VM, "private func scheduleForegroundLibraryChangeScan()", "/// `scanner` and `changeTokens`")
        self.assertIn("Task.sleep(for: .seconds(3))", schedule)
        self.assertIn("UIApplication.shared.applicationState == .active", schedule)
        self.assertIn("await self.synchronizeOnActive(", schedule)
        picker = block(VM, "func presentLimitedPicker(", "func syncOnActive()")
        self.assertIn("self?.scheduleForegroundLibraryChangeScan()", picker)
        auth = source("NekoWidget/Services/PhotoAuthorizationService.swift")
        self.assertIn("presentLimitedLibraryPicker(from: viewController) { _ in", auth)


class LowFidelityAndStartup(unittest.TestCase):
    def test_preview_only_no_cat_is_retried_quietly(self):
        state = block(SCANNER, "private func makeState(", "private static func outingValue(")
        # 11/22: retried, but not counted as 「読み込めなかった写真」.
        self.assertNotIn("|| record.isLowFidelityNoCat", state)
        self.assertIn("ScanResumePolicy.retriesLowFidelityNoCat(", SCANNER)
        self.assertIn("lowFidelityRetryBudget -= 1", SCANNER)
        self.assertNotIn("isNetworkAccessAllowed = true", SCANNER)

    def test_startup_failure_leaves_photos_alone(self):
        failure = block(VM, "private func clearOutputsAfterStartupFailure()", "private func performClearManagedAlbum(")
        self.assertNotIn("performClearManagedAlbum", failure)
        self.assertNotIn("clearAlbumAndWidgetOutputs", failure)
        self.assertIn("await clearWidgetOutput(reportErrors: false)", failure)

    def test_onboarding_zero_result_says_what_could_not_be_read(self):
        onboarding = source("NekoWidget/Views/OnboardingView.swift")
        zero = block(onboarding, "private var zeroResult: some View {", "private var nowaWindow")
        self.assertIn("if scan.hasDeferredAssets {", zero)
        self.assertIn('Text("読み込めなかった写真が\\(scan.deferredAssets.formatted())枚あります。")', zero)


class ExportsAndRequests(unittest.TestCase):
    def test_pdf_skips_a_missing_photo_with_a_bounded_wait(self):
        pdf = source("NekoWidget/Services/PhotoBookPDFExporter.swift")
        loop = block(pdf, "var omittedPhotoCount = 0", "pdfContext.closePDF()\n        } catch {")
        self.assertNotIn("throw PhotoBookPDFExportError.photoUnavailable", loop)
        self.assertNotIn("throw PhotoBookPDFExportError.imageUnavailable", loop)
        self.assertIn("omittedPhotoCount += 1", loop)
        self.assertIn("static let totalSeconds: TimeInterval = 300", pdf)
        self.assertNotIn("private static let timeoutNanoseconds: UInt64 = 120_000_000_000", pdf)
        liked = source("NekoWidget/Views/LikedPhotosView.swift")
        self.assertIn('"読み込めなかった写真が\\(pendingPhotoBookOmittedCount.formatted())枚あります。"', liked)

    def test_album_and_showcase_requests_are_bounded(self):
        album = source("NekoWidget/Views/AlbumPrototypeView.swift")
        showcase = source("NekoWidget/Views/ShowcasePhotoView.swift")
        for text in (album, showcase):
            self.assertNotIn("withCheckedContinuation", text)
            self.assertIn("PhotoKitTimedRequest.", text)
        bridge = source("NekoWidget/Services/SeasonalMovieCandidateService.swift")
        self.assertIn("enum PhotoKitTimedRequest", bridge)
        self.assertEqual(bridge.count("request.cancel()"), bridge.count("withTaskCancellationHandler"))

    def test_deleted_cat_photos_stay_off_the_remaining_cat(self):
        identity = source("Shared/Models/CatHouseholdIdentity.swift")
        remove = block(identity, "mutating func removeProfile(id: UUID", "/// The 「この子ではない」 decisions")
        self.assertLess(remove.index("let removedCatPhotos = confirmedAssetIdentifiers(for: id)"),
                        remove.index("profiles.removeAll"))
        self.assertIn("Self.membershipsKeepingApart(", remove)
        self.assertIn("decision: .excluded", identity)

    def test_names_follow_one_rule_at_the_model(self):
        create = block(VM, "func createCatProfile(", "private func performCreateCatProfile(")
        self.assertIn("CatNameText.savingInput(displayName)", create)
        rename = block(VM, "func updateCatProfileName(", "func setCatProfileKeyPhoto(")
        self.assertIn("CatNameText.savingInput(displayName, previous: stored)", rename)
        self.assertNotIn("prefix(80)", rename)
        transfer = source("Shared/Models/CatProfileTransfer.swift")
        self.assertIn("return try value.withImportedNames()", transfer)


if __name__ == "__main__":
    unittest.main()
