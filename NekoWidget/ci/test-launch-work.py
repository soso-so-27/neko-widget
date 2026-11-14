"""Source contracts for the light first seconds after opening the app (11/14).

On the owner's iPhone (9,700 photos, 2,400 cats, 2 cats with linked albums)
the この子 swipe trailed the finger for ~20 s after opening the app. These
pins keep the fixes in place:

1. No full pass over Photos when its change history shows nothing the scan
   keeps has changed since the last completed pass; any doubt is a pass.
   The receipt is written only after a pass completes, with the token taken
   before it began.
2. A pass after a completed one starts after the screen settles, below its
   priority, and publishes nothing while it changes no record.
3. The Widget authority sync reuses its last result for the same inputs,
   looks up cats per photo through one index, and is not run for a scan's
   resume checkpoints.
4. Failed and iCloud-only photos go back to Vision at most once a day.
5. The snapshot file is not rewritten with an equal value; its format is
   unchanged.
6. The Widget refill waits for the screen to settle and reloads once.
7. The main-thread meter and the large-library fixture exist only in DEBUG.

Native behaviour: NekoWidgetTests LaunchWorkTests; measurement:
NekoWidgetUITests LaunchWorkUITests (native-tests route=speed).
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def block(text, start):
    begin = text.index(start)
    depth = 0
    for index in range(text.index("{", begin), len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[begin:index + 1]
    raise AssertionError(start)


MODEL = read("NekoWidget/ViewModels/AppViewModel.swift")
SCANNER = read("NekoWidget/Services/PhotoLibraryScanner.swift")
VERIFY = read("NekoWidget/Services/LibraryVerification.swift")
STORE = read("NekoWidget/Services/LibraryStore.swift")
ATOMIC = read("Shared/Storage/AtomicJSON.swift")
METER = read("NekoWidget/Services/LaunchWorkMeter.swift")
FIXTURE = read("NekoWidget/Services/LaunchWorkFixture.swift")
APP = read("NekoWidget/App/NekoWidgetApp.swift")
AUTH = read("NekoWidget/Services/PhotoAuthorizationService.swift")
IDENTITY = read("Shared/Models/CatHouseholdIdentity.swift")
TESTS = read("NekoWidgetTests/LaunchWorkTests.swift")
UI_TESTS = read("NekoWidgetUITests/LaunchWorkUITests.swift")
INVENTORY = read("ci/native-ui-inventory.py")
PROJECT = read("NekoWidget.xcodeproj/project.pbxproj")


class LaunchWork(unittest.TestCase):
    def test_unchanged_library_skips_the_pass(self):
        active = block(MODEL, "private func synchronizeOnActive(")
        self.assertLess(active.index("await libraryIsUnchangedSinceLastPass()"),
                        active.index("await launchScan(forceFullAnalysis: forceFullAnalysis"))
        self.assertIn("if !forceFullAnalysis, await libraryIsUnchangedSinceLastPass()", active)
        check = block(MODEL, "private func libraryIsUnchangedSinceLastPass()")
        self.assertIn("Task.detached(priority: .utility)", check)
        self.assertIn("guard decision == .skip, let token else", check)
        decide = block(VERIFY, "static func decide(")
        for reason in ['"full-rescan"', '"limited-access"', '"no-completed-pass"', '"no-receipt"',
                       '"settings"', '"source"', '"other-snapshot"', '"daily"', '"no-history"',
                       '"inserted"', '"deleted"', '"many-updates"', '"updated"']:
            self.assertIn(reason, decide)
        tokens = block(VERIFY, "struct PhotoKitChangeTokenSource")
        self.assertIn("fetchPersistentChanges(since: token)", tokens)
        self.assertIn("return .unavailable", tokens)

    def test_receipt_only_after_a_completed_pass(self):
        scan = block(MODEL, "private func performScan(")
        self.assertLess(scan.index("tokens.currentToken()"), scan.index("try await scanner.scan("))
        self.assertLess(scan.index("await saveSnapshot(reportErrors: true)"),
                        scan.index("verificationStore.saveReceipt("))
        self.assertEqual(scan.count("verificationStore.saveReceipt("), 1)

    def test_later_passes_wait_and_stay_quiet(self):
        active = block(MODEL, "private func synchronizeOnActive(")
        self.assertIn("Task.sleep(for: .milliseconds(1_500))", active)
        launch = block(MODEL, "private func launchScan(")
        self.assertIn("Task(priority: isVerification ? .utility : nil)", launch)
        publish = block(MODEL, "private func performPublishPendingScanProgress(")
        self.assertLess(publish.index("if isVerificationPass, !publication.changedRecords {"),
                        publish.index("snapshot = publication.snapshot"))
        checkpoint = block(MODEL, "private func savePendingScanCheckpoint(")
        self.assertIn("if isVerificationPass, !checkpoint.changedRecords {", checkpoint)
        events = block(MODEL, "private func applyScanEvent(")
        self.assertIn("if isVerificationPass, provisional.assets == snapshot.assets {", events)
        today = block(MODEL, "private func performChooseCurrentAssetIfNeeded(")
        self.assertIn("if currentAsset != resolution.asset { currentAsset = resolution.asset }", today)
        self.assertNotIn("\n        currentAsset = resolution.asset", today)

    def test_widget_authority_sync_is_reused_and_indexed(self):
        sync = block(MODEL, "private func synchronizePersonalWidgetAuthorityReportingReuse(")
        self.assertIn("widgetAuthoritySync.reusable(for: key, uptime: uptime)", sync)
        self.assertIn("let key = input == nil ? widgetAuthorityKey : nil", sync)
        for name in ["private func suspendPersonalWidgetAuthority(", "private func performClearWidgetOutput("]:
            self.assertIn("forgetWidgetAuthoritySync()", block(MODEL, name))
        metadata = block(MODEL, "private func makeCloudyWindowMetadata(")
        self.assertIn("CatProfileConfirmationIndex", metadata)
        self.assertNotIn("catHouseholdIdentity?.confirmedProfileIDs(", metadata)
        self.assertIn("struct CatProfileConfirmationIndex", IDENTITY)
        checkpoint = block(MODEL, "private func savePendingScanCheckpoint(")
        self.assertIn("synchronizesWidgetAuthority: false", checkpoint)
        self.assertIn("synchronizesWidgetAuthority: true", block(MODEL, "private func saveSnapshot(reportErrors: Bool)"))

    def test_failed_and_icloud_only_photos_retry_once_a_day(self):
        self.assertIn("ScanRetryPolicy.retriesFailedPhoto(", SCANNER)
        self.assertIn("ScanRetryPolicy.retriesMissingAlbumTraits(", SCANNER)
        self.assertIn("} else if retriesAlbumTraits {", SCANNER)
        self.assertNotIn("previous.analysisStatus != .failed {", SCANNER)
        self.assertIn("let retriesAlbumTraits = forceFullAnalysis ||", SCANNER)
        self.assertIn("static let interval: TimeInterval = 24 * 60 * 60", VERIFY)

    def test_snapshot_written_only_when_changed_in_the_same_format(self):
        save = block(STORE, "func save(_ snapshot: LibrarySnapshot)")
        self.assertIn("if let lastSaved, lastSaved == snapshot { return false }", save)
        self.assertLess(save.index("try AtomicJSON.write(value, to: snapshotURL)"), save.index("lastSaved = snapshot"))
        self.assertIn("encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]", ATOMIC)

    def test_widget_refill_waits_and_reloads_once(self):
        rebuild = block(MODEL, "private func performRebuildWidgetCache(")
        self.assertIn("personalReplenishmentTask = Task(priority: .utility)", rebuild)
        self.assertIn("try await Task.sleep(for: .seconds(2))", rebuild)
        self.assertIn("defer { if added { self.reloadAllWidgetTimelines() } }", rebuild)
        self.assertNotIn("if batch.addedCount > 0 { reloadAllWidgetTimelines() }", rebuild)
        catalog = block(MODEL, "func refreshPhotoSourceAlbums()")
        self.assertIn("Task.detached(priority: .utility) {\n            PhotoSourceAlbumCatalog.availableAlbums(", catalog)

    def test_meter_and_fixture_are_debug_only(self):
        debug, release = METER.split("#else", 1)
        self.assertTrue(debug.lstrip().startswith("import Foundation") and "#if DEBUG" in debug)
        for word in ["os_signpost", "CADisplayLink", "launch-work-meter", "LaunchWorkMeter"]:
            self.assertNotIn(word, release)
        self.assertIn("static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T { try body() }", release)
        self.assertTrue(FIXTURE.startswith("#if DEBUG") and FIXTURE.rstrip().endswith("#endif"))
        self.assertRegex(APP, r"#if DEBUG\n        LaunchWorkMeter\.shared\.startIfRequested\(\)\n#endif")
        debug_root = APP[APP.index("WindowGroup {"):APP.index("#else", APP.index("WindowGroup {"))]
        self.assertIn("LaunchWorkFixtureRoot()", debug_root)
        self.assertRegex(AUTH, r"#if DEBUG\n[^#]*LaunchWorkFixture\.isOn[^#]*#endif")

    def test_tests_and_measurement_are_registered(self):
        for name in ["testUnchangedLibrarySkipsThePass", "testNewPhotoTakenWhileClosedMakesAPass",
                     "testPhotoDeletedInPhotosMakesAPass", "testExpiredTokenMakesAFullPass",
                     "testDetectorSettingsChangeMakesAPass", "testSyncIsReusedOnlyForTheSameInputsAndForAWhile",
                     "testMergingKnownRecordsChangesNothing", "testConfirmationIndexAnswersLikeTheLedger"]:
            self.assertIn(f"func {name}(", TESTS)
        self.assertIn("if 'LaunchWorkUITests/' in test: return 'speed'", INVENTORY)
        self.assertIn('"--launch-work-fixture", "--launch-work-meter"', UI_TESTS)
        for name in ["LaunchWorkMeter.swift", "LaunchWorkFixture.swift", "LibraryVerification.swift",
                     "LaunchWorkTests.swift", "LaunchWorkUITests.swift"]:
            self.assertEqual(len(re.findall(re.escape(name) + r" in Sources \*/ = ", PROJECT)), 1, name)


if __name__ == "__main__":
    unittest.main()
