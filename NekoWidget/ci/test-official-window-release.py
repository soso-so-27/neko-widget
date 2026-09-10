#!/usr/bin/env python3
"""Focused allowlist, archive, and workflow wiring checks; no signing/network."""

import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("validate-official-window-release.py")
WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/testflight.yml"
spec = importlib.util.spec_from_file_location("official_release", SCRIPT)
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)
URL = validator.PREVIEW_FEED_URL


class OfficialWindowReleaseTests(unittest.TestCase):
    def test_empty_default_is_allowed_for_every_known_mode(self):
        for mode in validator.RELEASE_MODES:
            with self.subTest(mode=mode):
                self.assertEqual(validator.validated_url(mode, ""), "")

    def test_fixed_preview_is_media_staging_only(self):
        self.assertEqual(validator.validated_url("media-staging", URL), URL)
        for mode in ("disabled", "review-preview", "pairing-only", "app-store", "", "unknown"):
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                validator.validated_url(mode, URL)
        with self.assertRaises(ValueError):
            validator.validated_url("unknown", "")

    def test_url_variants_and_shell_payloads_are_rejected(self):
        for url in (
            "https://example.com/catalog.json", URL + "?v=1", URL + "#photo",
            URL + "/", URL.replace("https:", "http:"), URL.replace("https:", "HTTPS:"),
            URL.replace("/catalog.json", ":443/catalog.json"),
            URL.replace("https://", "https://user@"), URL.replace("catalog.json", "%63atalog.json"),
            " " + URL, URL + "\n", URL + "\nOTHER_VARIABLE=YES", "$(touch unwanted)",
            "`touch unwanted`", "\"; echo unwanted", None,
        ):
            with self.subTest(url=url), self.assertRaises(ValueError):
                validator.validated_url("media-staging", url)

    def test_processed_plists_match_for_preview_and_disabled(self):
        for mode, url in (("media-staging", URL), ("media-staging", ""), ("disabled", "")):
            with self.subTest(mode=mode, url=url):
                info = {"SharingReleaseMode": mode, "OfficialWindowFeedURL": url}
                validator.validate_archive(info, info.copy(), mode, url)

    def test_either_target_mismatch_missing_or_placeholder_fails(self):
        good = {"SharingReleaseMode": "media-staging", "OfficialWindowFeedURL": URL}
        for replacement in (None, "", "$(OFFICIAL_WINDOW_FEED_URL)", "https://other.invalid/catalog.json", False):
            broken = dict(good)
            if replacement is None:
                del broken["OfficialWindowFeedURL"]
            else:
                broken["OfficialWindowFeedURL"] = replacement
            for app, widget in ((good, broken), (broken, good)):
                with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                    validator.validate_archive(app, widget, "media-staging", URL)

    def test_disabled_rejects_nonempty_even_when_both_targets_match(self):
        enabled = {"SharingReleaseMode": "disabled", "OfficialWindowFeedURL": URL}
        with self.assertRaises(ValueError):
            validator.validate_archive(enabled, enabled, "disabled", "")
        with self.assertRaises(ValueError):
            validator.validate_archive(enabled, enabled, "disabled", URL)
        missing = {"SharingReleaseMode": "disabled"}
        with self.assertRaises(ValueError):
            validator.validate_archive(missing, missing, "disabled", "")

    def test_archive_mode_cannot_be_substituted(self):
        good = {"SharingReleaseMode": "media-staging", "OfficialWindowFeedURL": URL}
        broken = {**good, "SharingReleaseMode": "disabled"}
        for app, widget in ((good, broken), (broken, good)):
            with self.assertRaises(ValueError):
                validator.validate_archive(app, widget, "media-staging", URL)

    def test_input_cli_writes_only_validated_single_line(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "github-env"
            environment = {**os.environ, "SELECTED_RELEASE_MODE": "media-staging",
                           "SELECTED_OFFICIAL_WINDOW_FEED_URL": URL, "GITHUB_ENV": str(target)}
            completed = subprocess.run([sys.executable, "-B", str(SCRIPT), "input"],
                                       env=environment, capture_output=True, text=True)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            expected = f"RELEASE_OFFICIAL_WINDOW_FEED_URL={URL}\n"
            self.assertEqual(target.read_text(encoding="utf-8"), expected)
            for mode, value in (("disabled", URL), ("media-staging", "\nINJECTED=YES")):
                environment.update(SELECTED_RELEASE_MODE=mode, SELECTED_OFFICIAL_WINDOW_FEED_URL=value)
                rejected = subprocess.run([sys.executable, "-B", str(SCRIPT), "input"],
                                          env=environment, capture_output=True, text=True)
                self.assertNotEqual(rejected.returncode, 0)
                self.assertNotIn("INJECTED", rejected.stderr)
                self.assertEqual(target.read_text(encoding="utf-8"), expected)

    def test_archive_cli_reads_binary_and_xml_plists(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "app.plist"
            widget = Path(temporary) / "widget.plist"
            info = {"SharingReleaseMode": "media-staging", "OfficialWindowFeedURL": URL}
            app.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
            widget.write_bytes(plistlib.dumps(info))
            environment = {**os.environ, "SHARING_EXPECTED_MODE": "media-staging",
                           "RELEASE_OFFICIAL_WINDOW_FEED_URL": URL}
            args = [sys.executable, "-B", str(SCRIPT), "archive", "--app-info-plist", str(app),
                    "--widget-info-plist", str(widget)]
            completed = subprocess.run(args, env=environment, capture_output=True, text=True)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            widget.write_bytes(plistlib.dumps({**info, "OfficialWindowFeedURL": ""}))
            self.assertNotEqual(subprocess.run(args, env=environment, capture_output=True).returncode, 0)
            widget.write_bytes(b"not a plist")
            self.assertNotEqual(subprocess.run(args, env=environment, capture_output=True).returncode, 0)

    def test_omitted_optional_input_exports_explicit_empty_override(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "github-env"
            environment = {**os.environ, "SELECTED_RELEASE_MODE": "disabled", "GITHUB_ENV": str(target)}
            environment.pop("SELECTED_OFFICIAL_WINDOW_FEED_URL", None)
            result = subprocess.run([sys.executable, "-B", str(SCRIPT), "input"],
                                    env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(target.read_text(encoding="utf-8"), "RELEASE_OFFICIAL_WINDOW_FEED_URL=\n")

    def test_workflow_raw_input_is_env_only_and_archive_is_checked_before_export(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        definition = text.split("      official_window_feed_url:", 1)[1].split("      upload_to_testflight:", 1)[0]
        self.assertIn('default: ""', definition)
        self.assertIn("required: false", definition)
        self.assertIn("type: string", definition)
        self.assertEqual(text.count("${{ inputs.official_window_feed_url }}"), 1)
        step = text.split("- name: Validate official window feed input", 1)[1].split("\n      - name:", 1)[0]
        environment, shell = step.split("        run: |", 1)
        self.assertIn("SELECTED_OFFICIAL_WINDOW_FEED_URL: ${{ inputs.official_window_feed_url }}", environment)
        self.assertNotIn("${{", shell)
        self.assertIn('validate-official-window-release.py" input', shell)
        archive = text.split("- name: Archive app and widget", 1)[1].split("\n      - name:", 1)[0]
        self.assertIn('OFFICIAL_WINDOW_FEED_URL="$RELEASE_OFFICIAL_WINDOW_FEED_URL"', archive)
        checks = text.split("- name: Validate sharing privacy and export gates", 1)[1].split("\n      - name:", 1)[0]
        self.assertIn('validate-official-window-release.py" archive', checks)
        self.assertIn('--app-info-plist "$app_path/Info.plist"', checks)
        self.assertIn('--widget-info-plist "$widget_path/Info.plist"', checks)
        self.assertLess(text.index("- name: Validate official window feed input"),
                        text.index("- name: Archive app and widget"))
        self.assertLess(text.index('validate-official-window-release.py" archive'),
                        text.index("-exportArchive"))


if __name__ == "__main__":
    unittest.main()
