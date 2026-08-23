#!/usr/bin/env python3
"""Static privacy boundary for user-initiated temporary exports."""

from __future__ import annotations

import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class TemporaryExportLifecycleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.store = (ROOT / "NekoWidget/Services/AppLogStore.swift").read_text(
            encoding="utf-8"
        )
        self.json = (ROOT / "NekoWidget/Services/JSONExporter.swift").read_text(
            encoding="utf-8"
        )
        self.app = (ROOT / "NekoWidget/App/NekoWidgetApp.swift").read_text(
            encoding="utf-8"
        )
        self.settings = (ROOT / "NekoWidget/Views/SettingsView.swift").read_text(
            encoding="utf-8"
        )
        self.log_view = (ROOT / "NekoWidget/Views/LogView.swift").read_text(
            encoding="utf-8"
        )

    def test_cleanup_is_limited_to_exact_app_export_names_in_tmp(self) -> None:
        for value in (
            'case .verificationJSON: "neko-widget-"',
            'case .diagnosticLog: "neko-widget-diagnostics-"',
            'case .verificationJSON: ".json"',
            'case .diagnosticLog: ".txt"',
            "candidate.deletingLastPathComponent() == temporaryDirectory",
            "values?.isRegularFile == true",
            "fileManager.contentsOfDirectory(",
            "options: [.skipsSubdirectoryDescendants]",
        ):
            self.assertIn(value, self.store)
        self.assertNotIn("removeItem(at: temporaryDirectory)", self.store)

    def test_each_export_removes_older_files_and_cleans_failure(self) -> None:
        json_export = self.json.split("func export(", 1)[1].split("\n    }\n}", 1)[0]
        self.assertLess(
            json_export.index("removeManagedFiles(kinds: [.verificationJSON])"),
            json_export.index("AtomicJSON.write("),
        )
        self.assertIn("removeManagedFile(at: url)", json_export)

        log_export = self.store.split("func makeExportFile()", 1)[1]
        self.assertLess(
            log_export.index("removeManagedFiles(kinds: [.diagnosticLog])"),
            log_export.index("data.write(to: url"),
        )
        self.assertIn("removeManagedFile(at: url)", log_export)

    def test_share_sheets_delete_on_dismiss_and_view_exit(self) -> None:
        self.assertIn(
            ".sheet(item: $exportedFile, onDismiss: cleanupVerificationExport)",
            self.settings,
        )
        self.assertIn(".onDisappear(perform: cleanupVerificationExport)", self.settings)
        self.assertIn(
            "TemporaryExportFileLifecycle.removeManagedFile(at: exportedFile?.url)",
            self.settings,
        )
        self.assertIn(
            ".sheet(item: $exportFile, onDismiss: cleanupDiagnosticExport)",
            self.log_view,
        )
        self.assertIn(".onDisappear(perform: cleanupDiagnosticExport)", self.log_view)
        self.assertIn(
            "TemporaryExportFileLifecycle.removeManagedFile(at: exportFile?.url)",
            self.log_view,
        )

    def test_relaunch_removes_only_stale_managed_exports(self) -> None:
        init = self.app.split("init() {", 1)[1].split("\n    }", 1)[0]
        self.assertIn("TemporaryExportFileLifecycle.removeManagedFiles()", init)

    def test_ci_runs_this_boundary(self) -> None:
        workflow = (ROOT.parent / ".github/workflows/ios-build.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("python3 ci/test-export-temp-file-lifecycle.py", workflow)


if __name__ == "__main__":
    unittest.main()
