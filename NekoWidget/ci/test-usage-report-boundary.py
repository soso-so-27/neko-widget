#!/usr/bin/env python3
"""Usage counts (spec 11/7): one sender, one Info.plist key, spec fields only.

The app may send anonymous daily counts from exactly one file
(UsageCounter.swift) to exactly one key (UsageReportURL). The payload types
hold only the spec's fields; the random per-day `batch` is the only ID.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
REPORT = "NekoWidget/Services/UsageReport.swift"
COUNTER = "NekoWidget/Services/UsageCounter.swift"


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def block(value: str, declaration: str) -> str:
    start = value.index(declaration)
    depth = 0
    for index in range(value.index("{", start), len(value)):
        if value[index] == "{":
            depth += 1
        elif value[index] == "}":
            depth -= 1
            if depth == 0:
                return value[start:index + 1]
    raise ValueError(declaration)


def stored_properties(body: str) -> set[str]:
    # Stored `let`/`var` of the type only (four-space indent, no body), not locals.
    return set(re.findall(r"(?m)^    (?:private\(set\) )?(?:let|var) ([A-Za-z_]+)\s*:[^{\n]*$", body))


class UsageReportBoundaryTests(unittest.TestCase):
    def test_payload_types_hold_only_the_spec_fields(self) -> None:
        report = source(REPORT)
        payload = block(report, "struct UsageReportPayload: Encodable, Equatable {")
        self.assertEqual(stored_properties(payload), {"schema", "day", "batch", "app", "os", "state", "counts"})
        self.assertNotIn("CodingKeys", payload)
        self.assertNotIn("func encode(", payload)
        self.assertIn("schema = 1", payload)
        self.assertIn("batch = record.batch.uuidString.lowercased()", payload)
        self.assertIn("UsageEvent.allNames.contains($0.key)", payload)
        state = block(report, "struct UsageState: Codable, Equatable, Sendable {")
        self.assertEqual(stored_properties(state), {"plus", "widget", "cats", "windows", "family", "photoAccess"})
        self.assertNotIn("func encode(", state)
        record = block(report, "struct UsageDayRecord: Codable, Equatable, Sendable {")
        self.assertEqual(stored_properties(record), {"day", "batch", "counts", "state"})
        ledger = block(report, "struct UsageLedger: Codable, Equatable, Sendable {")
        self.assertEqual(stored_properties(ledger), {"days"})
        # Counts are keyed only by the closed event list.
        self.assertEqual(len(re.findall(r"\.counts\[", report)), 2)
        self.assertIn("days[position].counts[event.name, default: 0]", report)
        self.assertIn("days[position].counts[UsageEvent.appOpened.name] = 1", report)
        self.assertEqual(report.count("UUID()"), 1, "one random batch per new day, nothing else")

    def test_no_identifier_or_content_reaches_the_report(self) -> None:
        for relative in (REPORT, COUNTER):
            value = source(relative)
            for forbidden in ("identifierForVendor", "advertisingIdentifier", "ASIdentifierManager",
                              "AdSupport", "AppTrackingTransparency", "UIDevice", "CoreLocation", "CLLocation",
                              "localIdentifier", "windowID", "personID", "displayName", "catName",
                              "SharedLog", "print(", "Logger", "localizedDescription"):
                self.assertNotIn(forbidden, value, f"{relative}: {forbidden}")
        self.assertEqual(re.findall(r"(?m)^import (\w+)", source(REPORT)), ["Foundation"])
        self.assertEqual(sorted(re.findall(r"(?m)^import (\w+)", source(COUNTER))),
                         ["Foundation", "Photos", "WidgetKit"])

    def test_one_sender_one_key_https_only(self) -> None:
        counter = source(COUNTER)
        self.assertEqual(counter.count('"UsageReportURL"'), 1)
        self.assertIn('url.scheme?.lowercased() == "https"', counter)
        self.assertEqual(counter.count("URLSession("), 1)
        sender = block(counter, "private final class UsageReportSender: Sendable {")
        for required in ("URLSessionConfiguration.ephemeral", "httpCookieStorage = nil",
                         "httpCookieAcceptPolicy = .never", "httpShouldSetCookies = false", "urlCache = nil",
                         ".reloadIgnoringLocalAndRemoteCacheData", "timeoutIntervalForRequest = 15",
                         "timeoutIntervalForResource = 15", 'request.httpMethod = "POST"',
                         "request.httpShouldHandleCookies = false", "UsageReportNoRedirect()",
                         "status == 200 || status == 204"):
            self.assertIn(required, sender)
        self.assertIn("completionHandler(nil)", block(counter, "private final class UsageReportNoRedirect"))
        # The body is the payload type alone.
        self.assertIn("let payload = UsageReportPayload(record: record", counter)
        self.assertIn("payload.body()", counter)
        self.assertNotIn("JSONSerialization", counter)
        self.assertNotIn("setValue(", counter.replace(
            'request.setValue("application/json", forHTTPHeaderField: "Content-Type")', ""))
        # No other product file reads the key or posts usage.
        for folder in ("NekoWidget", "Shared", "NekoWidgetWidget", "NekoWidgetShareExtension"):
            for path in (ROOT / folder).rglob("*.swift"):
                relative = str(path.relative_to(ROOT)).replace("\\", "/")
                if relative == COUNTER:
                    continue
                value = path.read_text(encoding="utf-8")
                self.assertNotIn("UsageReportURL", value, relative)
                self.assertNotIn("UsageReportSender", value, relative)
                if relative != REPORT:
                    self.assertNotIn("UsageReportPayload", value, relative)

    def test_counts_are_not_kept_in_user_defaults_or_written_per_tap(self) -> None:
        counter = source(COUNTER)
        self.assertEqual(counter.count("UserDefaults.standard.set("), 1)
        self.assertIn('let key = "usageReporting.first." + event.name', counter)
        self.assertNotIn("UserDefaults.standard.set(ledger", counter)
        self.assertIn(".applicationSupportDirectory", counter)
        self.assertIn("isExcludedFromBackup = true", counter)
        count = block(counter, "    func count(_ event: UsageEvent) {")
        self.assertNotIn("writeLocked()", count)
        self.assertIn("noteDayLocked(today)", count)
        day = block(counter, "    private func noteDayLocked(_ today: String) {")
        self.assertIn("if let lastDay, lastDay != today { writeLocked() }", day)
        self.assertEqual(counter.count("writeLocked()"), 3)  # definition, background, day change

    def test_main_app_only(self) -> None:
        project = source("NekoWidget.xcodeproj/project.pbxproj")
        start = project.index("A00000000000000000000021 /* Sources */ = {")
        app_sources = project[start:project.index("};", project.index("files = (", start))]
        for name in ("UsageReport.swift", "UsageCounter.swift"):
            self.assertEqual(project.count(f"/* {name} in Sources */ = {{isa = PBXBuildFile;"), 1, name)
            self.assertIn(f"/* {name} in Sources */", app_sources)
        for folder in ("Shared", "NekoWidgetWidget", "NekoWidgetShareExtension"):
            for path in (ROOT / folder).rglob("*.swift"):
                self.assertNotIn("UsageCounter", path.read_text(encoding="utf-8"), str(path))

    def test_settings_switch_and_lifecycle(self) -> None:
        settings = source("NekoWidget/Views/SettingsView.swift")
        self.assertIn("@AppStorage(UsageCounter.enabledKey) private var usageReportingEnabled = true", settings)
        self.assertIn('Label("利用状況を送る", systemImage: "chart.bar")', settings)
        self.assertIn('Text("使った機能の回数だけを送ります。写真や書いた内容は送りません。")', settings)
        self.assertIn("UsageCounter.shared.setEnabled(isOn)", settings)
        counter = source(COUNTER)
        disable = block(counter, "    func setEnabled(_ value: Bool) {")
        self.assertIn("removeItem(at: url)", disable)
        self.assertIn("enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true", counter)
        app = source("NekoWidget/App/NekoWidgetApp.swift")
        self.assertIn("await UsageCounter.shared.appBecameActive(viewModel: viewModel,", app)
        self.assertIn("UsageCounter.shared.appEnteredBackground(viewModel: viewModel,", app)

    def test_every_plus_entry_has_a_usage_name(self) -> None:
        model = source("NekoWidget/Services/MembershipOfferModel.swift")
        cases = re.findall(r"(?m)^    case (\w+)", block(model, "enum PlusOfferContext: Equatable, Sendable {"))
        mapping = block(source(COUNTER), "    init(_ context: PlusOfferContext) {")
        for case in cases:
            self.assertIn(f"case .{case}: self = .{case}", mapping)


if __name__ == "__main__":
    unittest.main()
