"""Source contracts for the cat line 0.7 -> 0.5 (11/13).

On the owner's iPhone, 269 of 402 photos that Photos groups as the owner's
cats but the app judged "not a cat" had a best cat label of 0.5-0.7, so the
default line is now 0.5.

1. The default line is 0.5; a box whose dog label is more confident than its
   cat label is not a cat. Screenshots, burst duplicates and people detection
   are unchanged.
2. Stored settings with the old default (0.7) move to 0.5 once, on load, off
   the main thread (LibraryStore is an actor). Cat records found at the old
   line move with it, so photos already shown stay; "no cat" records stay
   stale and the normal background scan (newest first, resumable) analyses
   them again. The fingerprint format and snapshot schema are unchanged, so
   older builds still read the file.
3. The 写真 tab's paused / failed search continues instead of starting over.
4. (11/14) The scanner hands fresh analyses to the app at least once a second,
   not only every 100 photos, so a short visit keeps its work and the next
   pass reuses it. The internal coverage text counts what is still pending.

Native behaviour: NekoWidgetTests CatThresholdTests.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def section(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


SETTINGS = read("Shared/Models/AppSettings.swift")
DETECTION = read("Shared/Models/CatDetection.swift")
RECORD = read("Shared/Models/AssetRecord.swift")
SCANNER = read("NekoWidget/Services/PhotoLibraryScanner.swift")
STORE = read("NekoWidget/Services/LibraryStore.swift")
VIEW_MODEL = read("NekoWidget/ViewModels/AppViewModel.swift")
HOME = read("NekoWidget/Views/HomeView.swift")
MAIN = read("NekoWidget/Views/MainTabView.swift")
ROOT_VIEW = read("NekoWidget/App/AppRootView.swift")
PRESENTATION = read("NekoWidget/Views/AppPresentationModels.swift")
SNAPSHOT = read("Shared/Models/LibrarySnapshot.swift")


class CatThresholdTests(unittest.TestCase):
    def test_default_line_is_half(self):
        # Replaces the old `confidenceThreshold: 0.7` default.
        self.assertIn("static let defaultConfidenceThreshold: Float = 0.5", SETTINGS)
        self.assertIn("static let legacyDefaultConfidenceThreshold: Float = 0.7", SETTINGS)
        default = section(SETTINGS, "static let `default` = AppSettings(", ")\n")
        self.assertIn("confidenceThreshold: defaultConfidenceThreshold,", default)
        self.assertIn("detectorPolicyVersion: currentDetectorPolicyVersion", default)
        self.assertNotIn("confidenceThreshold: 0.7", SETTINGS)
        self.assertIn("var confidenceThreshold = Double(AppSettings.defaultConfidenceThreshold)", PRESENTATION)
        self.assertNotIn("var confidenceThreshold = 0.7", PRESENTATION)
        # Old builds compute the same fingerprint from the same settings.
        self.assertIn('"cat-v3:\\(confidenceThreshold.bitPattern):\\(analysisRevision)"', SETTINGS)

    def test_scanner_uses_the_rule_with_the_dog_check(self):
        rule = section(DETECTION, "enum CatRecognitionRule {", "\n}\n")
        self.assertIn('caseInsensitiveCompare("cat")', rule)
        self.assertIn('caseInsensitiveCompare("dog")', rule)
        self.assertIn("guard let cat, cat >= threshold else { return nil }", rule)
        self.assertIn("if let dog, dog > cat { return nil }", rule)
        recognise = section(SCANNER, "private static func recognizeCats(", "private static func visionFailureResult(")
        self.assertIn("CatRecognitionRule.catConfidence(", recognise)
        self.assertIn("threshold: confidenceThreshold", recognise)
        self.assertNotIn("label.confidence >= confidenceThreshold", recognise)
        # Everything else in the scan stays: screenshots, bursts, the 2048px retry.
        self.assertIn("status: .excludedScreenshot,", SCANNER)
        self.assertIn("status: .excludedBurstDuplicate,", SCANNER)
        self.assertIn("profile: .highResolution2048", SCANNER)

    def test_settings_move_once_and_keep_the_revision(self):
        self.assertIn("var detectorPolicyVersion: Int? = nil", SETTINGS)
        self.assertIn("static let currentDetectorPolicyVersion = 2", SETTINGS)
        migrate = section(SETTINGS, "func migratedToCurrentDetectorPolicy() -> AppSettings {", "\n    }\n")
        self.assertIn("(detectorPolicyVersion ?? 1) < Self.currentDetectorPolicyVersion", migrate)
        self.assertIn("value.confidenceThreshold == Self.legacyDefaultConfidenceThreshold", migrate)
        self.assertNotIn("analysisRevision", migrate)

    def test_load_migrates_settings_then_records_without_a_full_rescan(self):
        migration = section(STORE, "private static func migratedGroupedAlbumSnapshot(", "\n    }\n}\n")
        settings = migration.index("value.settings.migratedToCurrentDetectorPolicy()")
        self.assertLess(settings, migration.index("let activeSettings = value.settings"))
        self.assertIn(".migratedToLowerConfidenceThreshold(settings: activeSettings)", migration)
        self.assertNotIn("requiresFullRescan = true\n                value.scanState.purpose = .manualRescan", migration)
        save = section(STORE, "func save(_ snapshot: LibrarySnapshot) throws {", "\n    }\n")
        self.assertIn(".migratedToLowerConfidenceThreshold(settings: activeSettings)", save)
        reuse = section(SCANNER, "private static func canReusePrimaryAnalysis(", "\n    }\n")
        self.assertIn(".migratedToLowerConfidenceThreshold(settings: settings)", reuse)
        # Snapshot schema unchanged: older builds still read the file.
        self.assertIn("private static let boundingBoxPostureSnapshotSchemaVersion = 3", STORE)
        self.assertIn("schemaVersion: 3,", SNAPSHOT)

    def test_only_positive_records_from_a_higher_line_move(self):
        record = section(RECORD, "func migratedToLowerConfidenceThreshold(", "\n    }\n")
        self.assertIn("guard isCatCandidate,", record)
        self.assertIn('parts[0] == "cat-v3"', record)
        self.assertIn("Float(bitPattern: bits) >= settings.confidenceThreshold", record)
        self.assertIn("parts[2] == Substring(String(settings.analysisRevision))", record)

    def test_paused_or_failed_search_continues(self):
        resume = section(VIEW_MODEL, "func resumeScan() async {", "\n    }\n")
        self.assertIn("await launchScan(forceFullAnalysis: scanState.requiresFullRescan)", resume)
        self.assertNotIn("analysisRevision", resume)
        status = section(HOME, "private var partialScanStatus: some View {", "private var monthDestinations")
        self.assertIn('Button(scan.isPaused ? "続きを探す" : "もう一度探す", action: resumeScan ?? rescan)', status)
        self.assertIn("} else if scan.hasDeferredAssets {\n                    Button(\"もう一度探す\", action: rescan)", status)
        self.assertIn("var resumeScan: (() async -> Void)? = nil", MAIN)
        self.assertIn("await viewModel.resumeScan()", ROOT_VIEW)

    def test_fresh_analyses_are_handed_over_within_a_second(self):
        policy = section(SCANNER, "enum ScanProgressEventPolicy {", "\n}\n")
        self.assertIn("static let maximumUnreportedSeconds: TimeInterval = 1", policy)
        self.assertIn("if isFirstQuickBatch || batchEnd == rangeEnd || batchEnd.isMultiple(of: 100) {", policy)
        self.assertIn("return analyzedSinceLastReport > 0\n            && secondsSinceLastReport >= maximumUnreportedSeconds", policy)
        process = section(SCANNER, "    private func process(", "    private func makeState(")
        self.assertIn("analyzedSinceLastReport += pending.count", process)
        self.assertIn("if ScanProgressEventPolicy.shouldReport(", process)
        self.assertNotIn("if isFirstQuickBatch || batchEnd == range.upperBound || batchEnd.isMultiple(of: 100) {", process)
        report = process[process.index("if ScanProgressEventPolicy.shouldReport("):process.index("await Task.yield()")]
        self.assertIn("lastPublishedIndex = batchEnd\n                analyzedSinceLastReport = 0", report)
        # The 1,000-photo save checkpoint and the newest-first order stay.
        self.assertIn('NSSortDescriptor(key: "creationDate", ascending: false)', SCANNER)
        self.assertIn("scannedAssets > 0 && scannedAssets.isMultiple(of: 1_000)", read("NekoWidget/Services/PhotoSelectors.swift"))
        # Nothing the app saves changes: same stamp, same record shape.
        self.assertIn("analysisFingerprint: settings.analysisFingerprint,", SCANNER)

    def test_internal_coverage_counts_pending_rescan(self):
        coverage = read("NekoWidget/Services/CatPhotoCoverageMeasurement.swift")
        reason = section(coverage, "static func rescanPendingReason(", "\n    }\n")
        self.assertIn(".migratedToLowerConfidenceThreshold(settings: settings)", reason)
        self.assertIn("if record.analysisStatus == .failed { return 4 }", reason)
        self.assertIn('lines.append("rescan pending \(library.rescanPending.reduce(0, +)): "', coverage)
        self.assertIn("let scanSettings = snapshot.settings.normalized()", coverage)
        self.assertTrue(coverage.startswith("#if DEBUG || INTERNAL_PRESENTATION\n"))

    def test_unit_tests_are_in_the_test_target(self):
        project = read("NekoWidget.xcodeproj/project.pbxproj")
        self.assertEqual(project.count("path = CatThresholdTests.swift;"), 1)
        self.assertIn("C1CA70500000000000000001 /* CatThresholdTests.swift in Sources */ = "
                      "{ isa = PBXBuildFile; fileRef = C1CA70500000000000000002; };", project)
        sources = project.index("C1108C000000000000000006 = { isa = PBXSourcesBuildPhase;")
        self.assertIn("C1CA70500000000000000001,", project[sources:project.index("};", sources)])
        tests = read("NekoWidgetTests/CatThresholdTests.swift")
        self.assertNotIn("#if ", tests)
        self.assertIn("python3 ci/test-cat-threshold.py", read("ci/run-quick-ios-checks.sh"))


if __name__ == "__main__":
    unittest.main()
