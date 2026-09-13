#!/usr/bin/env python3
"""Check selection coverage without a Mac, account or Simulator."""

from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch

import balanced_ui_shards as plan
from ios_ci_scope import FULL_SCOPE, GALLERY_TEST, SCOPES, native_tests

CI = Path(__file__).resolve().parent


def included(test, arguments):
    def matches(selector):
        return test == selector or test.startswith(selector + "/")
    return any(matches(arg.removeprefix("-only-testing:")) for arg in arguments)


class ShardTests(unittest.TestCase):
    def current_tests(self):
        # Current native fixture classes live in this one existing file. These
        # identifiers are only audit evidence: the runner uses whole classes.
        source = (CI.parent / "NekoWidgetUITests/PhotoPermissionUITests.swift").read_text(encoding="utf-8")
        current_class = None
        found = []
        for line in source.splitlines():
            declaration = re.match(r"final class (\w+): XCTestCase", line)
            if declaration:
                current_class = plan.TARGET + declaration.group(1)
            method = re.match(r"    func (test\w+)\(\)", line)
            if method and current_class in plan.APP_CLASSES:
                found.append(current_class + "/" + method.group(1))
        self.assertEqual({test.rsplit("/", 1)[0] for test in found}, plan.APP_CLASSES)
        self.assertIn(plan.OFFICIAL + "/testTwoPublicWindowsKeepSamePhotoIDAndStopSeparate", found)
        return found

    def test_current_and_future_methods_are_selected_exactly_once_for_every_scope(self):
        tests = self.current_tests() + [test + "/testAddedInTheFuture" for test in plan.APP_CLASSES]
        for scope in SCOPES:
            selected = native_tests(scope)
            shards = plan.partition(selected)
            selectors = [arg for arguments in shards.values() for arg in arguments]
            self.assertEqual(set(selectors), {
                "-only-testing:" + test for test in selected if test != GALLERY_TEST
            })
            self.assertEqual(len(selectors), len(set(selectors)))
            for test in tests:
                with self.subTest(scope=scope, test=test):
                    count = sum(included(test, arguments) for arguments in shards.values())
                    self.assertEqual(count, int(test.rsplit("/", 1)[0] in selected))
            self.assertFalse(any(included(GALLERY_TEST, arguments) for arguments in shards.values()))

    def test_whole_suites_use_only_testing_without_skip_precedence(self):
        shards = plan.partition(native_tests(FULL_SCOPE))
        self.assertEqual(set(shards["a"]), {"-only-testing:" + plan.SOLO, "-only-testing:" + plan.OFFICIAL})
        self.assertEqual(set(shards["b"]), {"-only-testing:" + plan.COMPOSER, "-only-testing:" + plan.CAT})
        self.assertTrue(included(plan.COMPOSER + "/testNewComposerOperation", shards["b"]))
        self.assertTrue(included(plan.SOLO + "/testNewSoloOperation", shards["a"]))
        self.assertTrue(included(plan.CAT + "/testNewCatOperation", shards["b"]))
        self.assertTrue(included(plan.OFFICIAL + "/testNewPublicWindow", shards["a"]))

    def test_unknown_duplicate_empty_or_gallery_only_selection_fails_closed(self):
        for selected in ((), (GALLERY_TEST,), (plan.SOLO, plan.SOLO),
                         (plan.TARGET + "NewUITests",), (plan.COMPOSER + "/testOneMethod",)):
            with self.subTest(selected=selected), self.assertRaises(ValueError):
                plan.partition(selected)

    def test_cli_writes_scope_partition_and_preserves_empty_shard(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch("sys.argv", ["plan", "--scope", "official-ui-v1", "--output", directory]):
                plan.main()
            output = Path(directory)
            self.assertEqual((output / "shard-b.txt").read_text(), "")
            self.assertEqual((output / "shard-a.txt").read_text(), "-only-testing:" + plan.OFFICIAL + "\n")
            self.assertTrue((output / "partition.json").is_file())

    def test_harness_joins_both_and_keeps_gallery_on_owned_fresh_devices(self):
        source = (CI / "run-sharing-runtime-matrix.sh").read_text(encoding="utf-8")
        build = source.index('prepare_simulator_and_build "$ui_primary_udid" --fresh')
        start = source.index("App UI shard %s started")
        join = source.index('wait "${UI_PIDS[$ui_index]}" || ui_status=$?')
        summary = source.index('"$runtime_artifacts/ui-shard-results.json"')
        gallery = source.index("for widget_scenario in normal long-white-large no-caption; do")
        self.assertLess(build, start)
        self.assertLess(start, join)
        self.assertLess(join, summary)
        self.assertLess(summary, gallery)
        worker = source[start:join]
        self.assertIn("test-without-building", worker)
        self.assertNotIn("build-for-testing", worker)
        self.assertIn("-parallel-testing-enabled NO", worker)
        self.assertIn('-xctestrun "$ui_test_manifest"', worker)
        self.assertNotIn("-scheme", worker)
        self.assertNotIn("-derivedDataPath", worker)
        self.assertIn('"${ui_arguments[@]}"', worker)
        self.assertIn('discard_test_simulator "${ui_udids[$ui_index]}"', source[summary:gallery])
        self.assertIn('create_test_simulator widget_simulator_udid', source[gallery:])
        self.assertIn('id=$widget_simulator_udid', source[gallery:])
        self.assertIn('if (( composer_status != 0 )); then\n            return "$composer_status"', source[gallery:])


if __name__ == "__main__":
    unittest.main()
