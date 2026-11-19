import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import ordinary_ci_scope as scope


class OrdinaryCIScopeTests(unittest.TestCase):
    def test_only_verified_site_and_worker_inputs_skip_mac(self):
        self.assertEqual(scope.select_checks({"docs/privacy/index.html", scope.PUBLIC_SITE_TEST}),
                         {"mac": False, "docs": True, "sharing": False})
        self.assertEqual(scope.select_checks({"NekoWidget/SharingService/src/group-api.ts",
                                              "NekoWidget/SharingService/migrations/0001_base.sql"}),
                         {"mac": False, "docs": False, "sharing": True})
        self.assertEqual(scope.select_checks({"docs/join.html", "NekoWidget/SharingService/src/index.ts"}),
                         {"mac": False, "docs": True, "sharing": True})

        for path in ("NekoWidget/NekoWidget/App.swift", ".github/workflows/ios-build.yml",
                     "NekoWidget/SharingService/wrangler.toml", "NekoWidget/ci/fixtures/protocol.json",
                     "NekoWidget/SharingService/scripts/group-moderation-report-lib.mjs"):
            with self.subTest(path=path):
                self.assertTrue(scope.select_checks({"docs/index.html", path})["mac"])
        self.assertTrue(scope.select_checks(set())["mac"])

    def test_uses_full_branch_diff_and_keeps_both_sides_of_a_rename(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)

            def git(*args):
                return subprocess.check_output(["git", "-C", temp, *args], stderr=subprocess.DEVNULL).decode("utf-8")

            def commit(message):
                git("add", "--all")
                git("commit", "-qm", message)
                return git("rev-parse", "HEAD").strip()

            git("init", "-q")
            git("config", "user.name", "CI test")
            git("config", "user.email", "ci@example.invalid")
            (root / "App.swift").write_text("// old app\n", encoding="utf-8")
            main = commit("initial")
            git("update-ref", "refs/remotes/origin/main", main)

            doc = root / "docs" / "案内.md"
            doc.parent.mkdir()
            doc.write_text("guide\n", encoding="utf-8")
            docs_head = commit("docs only")
            with patch.object(scope, "git", git):
                self.assertFalse(scope.select_checks(scope.changed_paths("push", "refs/heads/main", main))["mac"])
                self.assertFalse(scope.select_checks(scope.changed_paths("push", "refs/heads/new", "0" * 40))["mac"])
                self.assertFalse(scope.select_checks(scope.changed_paths("pull_request", "refs/pull/1/merge", main))["mac"])
                for event, before in (("schedule", main), ("workflow_dispatch", main), ("push", "f" * 40)):
                    self.assertTrue(scope.select_checks(scope.changed_paths(event, "refs/heads/main", before))["mac"])

                (root / "App.swift").rename(root / "docs" / "moved.swift")
                app_head = commit("move app file into docs")
                self.assertEqual(scope.changed_paths("push", "refs/heads/main", docs_head),
                                 {"App.swift", "docs/moved.swift"})
                doc.write_text("new guide\n", encoding="utf-8")
                commit("follow-up docs only")
                self.assertTrue(scope.select_checks(scope.changed_paths("push", "refs/heads/topic", app_head))["mac"])


if __name__ == "__main__":
    unittest.main()
