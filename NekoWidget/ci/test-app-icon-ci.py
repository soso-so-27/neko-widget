#!/usr/bin/env python3
"""Image-only selection, fail-closed boundaries and executed evidence."""

import importlib.util
from pathlib import Path
import struct
import unittest
from unittest.mock import patch
import zlib

import app_icon_ci as icons
import ios_ci_scope as scope

CI = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("icon_planner", CI / "plan-ios-ci.py")
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)


def chunk(tag, payload):
    return struct.pack(">I", len(payload)) + tag + payload + struct.pack(">I", zlib.crc32(tag + payload) & 0xffffffff)


def png(size=1024, color=2, pixels=None):
    raw = pixels if pixels is not None else b"\0" * ((size * 3 + 1) * size)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, color, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


class IconTests(unittest.TestCase):
    def test_only_complete_opaque_rgb_pixels_are_accepted(self):
        good = png()
        icons.validate_png(good)
        for bad in (b"not png", good[:-1], good + b"extra", png(60), png(color=6),
                    png(pixels=b""), png(pixels=b"\0" * (1024 * 3073 + 1)),
                    good[:50] + bytes([good[50] ^ 1]) + good[51:],
                    good[:-12] + chunk(b"tRNS", b"\0" * 6) + good[-12:]):
            with self.subTest(size=len(bad)), self.assertRaises(ValueError):
                icons.validate_png(bad)

    def selected(self, records, *, image=None, manual=False):
        paths = [p for _, _, _, p in records]
        raw = "".join(f":{old} {new} {'a'*40} {'b'*40} {status}\0{path}\0" for old, new, status, path in records)
        def git(*args):
            if args[0] == "diff":
                return raw
            if args[0] == "show":
                self.fail("Binary icons must not use text git reads")
            return "a" * 40
        env = {"GITHUB_EVENT_NAME": "workflow_dispatch" if manual else "push",
               "GITHUB_REF": "refs/heads/codex/icons", "GITHUB_SHA": "a"*40}
        with patch.object(planner, "git", side_effect=git), patch.object(planner.subprocess, "check_output", return_value=png() if image is None else image):
            return planner.runtime_scope(paths, {}, env)

    def test_image_changes_and_exact_artwork_docs_use_one_mac_job(self):
        records = [("100644", "100644", "M", p) for p in icons.ICON_PATHS]
        for extra in ([], [("000000", "100644", "A", p) for p in icons.ICON_DOC_PATHS],
                      [("000000", "100644", "A", "handoffs/icon.md")]):
            self.assertEqual(self.selected(records + extra), icons.ICON_SCOPE)
        self.assertEqual(planner.required_jobs([records[0][3]], icons.ICON_SCOPE), (planner.ICON_BUILD,))
        self.assertEqual(scope.lanes(icons.ICON_SCOPE), ())
        self.assertEqual(scope.native_tests(icons.ICON_SCOPE), ())

    def test_unknown_mixed_catalog_signing_and_manual_changes_stay_full(self):
        image = sorted(icons.ICON_PATHS)[0]
        record = ("100644", "100644", "M", image)
        for extra in (image.replace("AppIcon.png", "Contents.json"), "NekoWidget/App.swift",
                      "NekoWidget/NekoWidget/NekoWidget.entitlements", "unknown.png", "AGENTS.md"):
            self.assertEqual(self.selected([record, ("100644", "100644", "M", extra)]), scope.FULL_SCOPE)
        for old, new, status in (("000000", "100644", "A"), ("100644", "000000", "D"),
                                 ("100644", "120000", "M"), ("100644", "100755", "M")):
            self.assertEqual(self.selected([(old, new, status, image)]), scope.FULL_SCOPE)
        self.assertEqual(self.selected([record], manual=True), scope.FULL_SCOPE)
        self.assertEqual(self.selected([record], image=b"bad PNG"), scope.FULL_SCOPE)

    def test_icon_evidence_never_substitutes_for_full_or_plain_build(self):
        sha = "a" * 40
        job = dict(name=planner.ICON_BUILD, status="completed", conclusion="success", head_sha=sha)
        self.assertTrue(planner.covers_jobs([job], (planner.ICON_BUILD,), sha))
        self.assertFalse(planner.covers_jobs([job], planner.FULL, sha))
        self.assertFalse(planner.covers_jobs([dict(job, name=planner.BUILD)], (planner.ICON_BUILD,), sha))
        for key, value in (("conclusion", "skipped"), ("conclusion", "failure"), ("head_sha", "b" * 40)):
            self.assertFalse(planner.covers_jobs([dict(job, **{key: value})], (planner.ICON_BUILD,), sha))

    def test_rollout_preserves_existing_workflow_execution(self):
        workflow = (CI.parents[1] / ".github/workflows/ios-build.yml").read_text(encoding="utf-8")
        self.assertEqual(workflow.count(icons.ICON_WORKFLOW_STEPS), 1)
        before = workflow.replace(icons.ICON_WORKFLOW_STEPS, "")
        self.assertTrue(scope.ci_selection_only({scope.CI_WORKFLOW: (before, workflow)}))
        self.assertFalse(scope.ci_selection_only({scope.CI_WORKFLOW: (workflow, before)}))
        moved = before.replace("      - name: Test CI selection and evidence boundaries\n",
            icons.ICON_WORKFLOW_STEPS + "      - name: Test CI selection and evidence boundaries\n")
        self.assertFalse(scope.ci_selection_only({scope.CI_WORKFLOW: (workflow, moved)}))
        self.assertFalse(scope.ci_selection_only({scope.CI_WORKFLOW: (workflow, workflow + icons.ICON_WORKFLOW_STEPS)}))
        for old, new in (("verify-app-icon.py", "skip-icon.py"), ("codesign", "skip-signing")):
            if old in workflow:
                self.assertFalse(scope.ci_selection_only({scope.CI_WORKFLOW: (before, workflow.replace(old, new))}))
        self.assertFalse(scope.ci_selection_only({scope.CI_WORKFLOW: (workflow, workflow.replace("CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_ALLOWED=YES"))}))


if __name__ == "__main__":
    unittest.main()
