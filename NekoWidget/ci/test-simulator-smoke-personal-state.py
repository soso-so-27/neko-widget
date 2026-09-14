#!/usr/bin/env python3
"""Focused artifact-validator boundaries; native Swift checks exercise JPEG decode."""

from __future__ import annotations

import copy
import importlib.util
import json
import tempfile
import unittest
import uuid
from pathlib import Path


CI_DIRECTORY = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "simulator_smoke_validator", CI_DIRECTORY / "validate-simulator-smoke.py"
)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
RENDERER = "cat-aware-full-bleed-v6"
NOW = 811_000_000.0


def jpeg_header(width: int, height: int) -> bytes:
    # SOF fixture for the dependency-free dimension/framing reader. Production
    # ImageIO decode is covered by verify-personal-rediscovery.swift and UI runs.
    return (b"\xff\xd8\xff\xc0\x00\x0b\x08" + height.to_bytes(2, "big")
            + width.to_bytes(2, "big") + b"\x01\x01\x11\x00\xff\xd9")


class PersonalStateArtifactTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.cache = self.root / "widget-cache"
        self.cache.mkdir()
        self.path = self.root / "personal-rediscovery.v1" / "state.json"
        self.path.parent.mkdir()
        self.state = {
            "schemaVersion": 1, "sourceID": "personal-library",
            "eligibilityRevision": str(uuid.uuid4()), "isAuthorized": True,
            "scopeIdentifier": "fixture|20", "updatedAt": NOW,
            "eligiblePhotoIDs": ["photo-0", "photo-1"], "modificationDates": {},
            "candidates": [self.candidate(0), self.candidate(1)],
            "issues": [], "grants": [], "operations": [],
            "plan": {"id": str(uuid.uuid4()), "anchor": NOW, "interval": 1200,
                     "seed": 123, "cycles": [{"index": 0, "startSlot": 0,
                                               "order": ["photo-0", "photo-1"]}]},
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def candidate(self, index: int) -> dict:
        names = {variant: f"photo-{index}-{variant}.jpg" for variant in MODULE.EXPECTED_CACHE_DIMENSIONS}
        for variant, name in names.items():
            (self.cache / name).write_bytes(jpeg_header(*MODULE.EXPECTED_CACHE_DIMENSIONS[variant]))
        return {"preparedAt": NOW, "item": {
            "localIdentifier": f"photo-{index}", "cacheFilename": names["small"],
            "cacheFilenames": names, "scheduledDate": NOW,
            "sourceModificationDate": NOW, "rendererVersion": RENDERER,
            "renderPlans": {variant: {"compositionMode": "cat-full-bleed"}
                            for variant in MODULE.EXPECTED_CACHE_DIMENSIONS},
        }}

    def validate(self, **kwargs):
        self.path.write_text(json.dumps(self.state), encoding="utf-8")
        failures = []
        result = MODULE.validate_personal_state(self.root, RENDERER, failures, **kwargs)
        return failures, result

    def assert_failure(self, phrase: str, **kwargs):
        failures, _ = self.validate(**kwargs)
        self.assertTrue(any(phrase in failure for failure in failures), failures)

    def grant(self) -> dict:
        result, previous = self.candidate(2)["item"], self.candidate(3)["item"]
        self.state["eligiblePhotoIDs"].extend(["photo-2", "photo-3"])
        grant = {"id": str(uuid.uuid4()), "photoID": "photo-2", "previousPhotoID": "photo-3",
                 "committedAt": NOW - 60, "overrideUntil": NOW + 1140,
                 "resultExpiresAt": NOW - 60 + 48 * 3600,
                 "resultItem": result, "previousItem": previous,
                 "resultInvalidated": False, "previousInvalidated": False}
        self.state["grants"] = [grant]
        self.state["nextAvailableAt"] = NOW + 3600
        return grant

    def test_valid_pool_requires_no_obsolete_history_and_no_headless_issues(self):
        failures, (report, _, _) = self.validate(
            snapshot_photo_ids={"photo-0", "photo-1"}, detected_fixture_ids={"photo-1"})
        self.assertEqual([], failures)
        self.assertEqual(2, report["candidateCount"])
        self.assertEqual(6, report["actualJPEGCount"])
        self.assertEqual(6, report["liveReferenceCount"])
        self.assertFalse((self.root / "widget-cache-history.json").exists())

    def test_missing_canonical_state_cannot_fall_back_to_legacy_history(self):
        (self.root / "widget-cache-history.json").write_text('{"generations": []}')
        failures = []
        MODULE.validate_personal_state(self.root, RENDERER, failures)
        self.assertTrue(any("state.json is missing" in failure for failure in failures))

    def test_source_authority_and_revision_are_required(self):
        original = copy.deepcopy(self.state)
        for key, value, expected in [
            ("sourceID", "family-private", "nonpersonal"),
            ("schemaVersion", 2, "unsupported schema"),
            ("isAuthorized", False, "authority is not ready"),
            ("eligibilityRevision", "", "authority revision"),
            ("eligiblePhotoIDs", ["photo-1"], "outside the current"),
        ]:
            with self.subTest(key=key):
                self.state = copy.deepcopy(original)
                self.state[key] = value
                self.assert_failure(expected)

    def test_candidate_cap_and_uniqueness(self):
        self.state["candidates"] = [self.candidate(index) for index in range(100)]
        self.state["eligiblePhotoIDs"] = [f"photo-{index}" for index in range(101)]
        self.assertEqual([], self.validate()[0])
        self.state["candidates"].append(self.candidate(100))
        self.assert_failure("expected 1-100")
        self.state["candidates"] = [self.state["candidates"][0]] * 2
        self.assert_failure("repeats a photo ID")

    def test_empty_or_unusable_plan_cannot_pass(self):
        original = copy.deepcopy(self.state["plan"])
        for plan in [None, {}, {**original, "cycles": []}, {**original, "seed": -1}]:
            with self.subTest(plan=plan):
                self.state["plan"] = plan
                self.assertTrue(self.validate()[0])
        self.state["plan"] = original
        self.state["plan"]["cycles"][0]["order"] = ["not-in-pool"]
        self.assert_failure("future slot outside")

    def test_candidate_must_bind_snapshot_fixture_renderer_and_source_revision(self):
        self.assert_failure("no PhotoKit snapshot", snapshot_photo_ids={"photo-0"})
        self.assert_failure("no detected imported fixture", detected_fixture_ids={"unrelated"})
        self.state["candidates"][0]["item"]["rendererVersion"] = "obsolete-renderer"
        self.assert_failure("unexpected renderer")
        self.state["modificationDates"] = {"photo-1": NOW + 1}
        self.assert_failure("obsolete photo revision")

    def test_all_pool_images_are_checked_beyond_legacy_twenty(self):
        self.state["candidates"] = [self.candidate(index) for index in range(21)]
        self.state["eligiblePhotoIDs"] = [f"photo-{index}" for index in range(21)]
        (self.cache / "photo-20-large.jpg").unlink()
        self.assert_failure("missing JPEG")

    def test_referenced_dimensions_bytes_and_framing_remain_enforced(self):
        path = self.cache / "photo-0-small.jpg"
        path.write_bytes(jpeg_header(1050, 1100))
        self.assert_failure("bound small canvas")
        path.write_bytes(jpeg_header(500, 500)[:-2] + b"x" * (100 * 1024) + b"\xff\xd9")
        self.assert_failure("small byte budget")
        path.write_bytes(jpeg_header(500, 500)[:-2])
        self.assert_failure("unreadable")

    def test_unsafe_paths_reject_both_posix_and_windows_forms(self):
        for filename in ["../other.jpg", "..\\other.jpg", "C:\\other.jpg", "folder/other.jpg"]:
            with self.subTest(filename=filename):
                self.state["candidates"][0]["item"]["cacheFilenames"]["small"] = filename
                self.assert_failure("unsafe cache filename")

    def test_unreferenced_actual_files_still_count_toward_four_hundred(self):
        for index in range(395):
            (self.cache / f"orphan-{index}.jpg").write_bytes(jpeg_header(500, 500))
        self.assert_failure("401 JPEGs; cap is 400")

    def test_live_leases_remain_required_even_when_usage_was_canceled(self):
        issue = {"photoID": "photo-0", "slotID": "old-plan-1", "scheduledAt": NOW + 1200,
                 "issuedAt": NOW, "leaseUntil": NOW + 12 * 3600,
                 "invalidated": True, "cacheFilenames": ["missing-old-small.jpg"]}
        self.state["issues"] = [issue]
        self.assert_failure("missing JPEG")
        issue["scheduledAt"] = NOW - 13 * 3600
        issue["leaseUntil"] = NOW - 1
        self.assertEqual([], self.validate()[0])

    def test_live_reference_cap_includes_leases_outside_active_pool(self):
        self.state["issues"] = [{"photoID": "photo-0", "slotID": "old-plan-1",
            "scheduledAt": NOW, "issuedAt": NOW, "leaseUntil": NOW + 1200,
            "cacheFilenames": [f"old-{index}.jpg" for index in range(395)]}]
        self.assert_failure("401 live JPEG references")

    def test_manual_result_and_previous_images_are_protected_independently(self):
        grant = self.grant()
        self.assertEqual([], self.validate()[0])
        for variant in MODULE.EXPECTED_CACHE_DIMENSIONS:
            (self.cache / f"photo-2-{variant}.jpg").unlink()
        self.assert_failure("missing JPEG")
        grant["resultInvalidated"] = True
        self.assertEqual([], self.validate()[0])
        (self.cache / "photo-3-medium.jpg").unlink()
        self.assert_failure("missing JPEG")
        after_expiry = MODULE.SWIFT_REFERENCE_EPOCH + grant["resultExpiresAt"]
        self.assertEqual([], self.validate(observed_at=after_expiry)[0])

    def test_malformed_fields_fail_with_report_instead_of_crashing(self):
        original = copy.deepcopy(self.state)
        for field, value in [("candidates", [None]), ("eligiblePhotoIDs", {}), ("issues", [None]),
                             ("operations", [{}]), ("grants", [{}]), ("updatedAt", float("nan"))]:
            with self.subTest(field=field):
                self.state = copy.deepcopy(original)
                self.state[field] = value
                self.assertTrue(self.validate()[0])
        self.state = original
        self.state["candidates"][0]["item"]["localIdentifier"] = []
        self.assertTrue(self.validate()[0])

    def test_provider_cap_covers_new_plan_in_addition_to_legacy(self):
        provider = CI_DIRECTORY.parent / "NekoWidgetWidget" / "NekoWidgetTimelineProvider.swift"
        failures = []
        limit, checks = MODULE.timeline_entry_limit(provider, failures)
        self.assertEqual([], failures)
        self.assertEqual(2, limit)
        self.assertTrue(checks["personalPlanTwoEntryPrefix"])
        altered = self.root / "provider.swift"
        altered.write_text(provider.read_text(encoding="utf-8").replace(
            "plan.entries.prefix(Self.maximumTimelineEntryCount)", "plan.entries"), encoding="utf-8")
        MODULE.timeline_entry_limit(altered, failures)
        self.assertTrue(any("Personal plan output" in failure for failure in failures))


if __name__ == "__main__":
    unittest.main()
