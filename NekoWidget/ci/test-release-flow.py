"""Regression cases for the repeated release delays; no network or native CI."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from unittest.mock import patch

CI = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("planner", CI / "plan-ios-ci.py")
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)
import ios_ci_scope as scope


class ReleaseFlowTests(unittest.TestCase):
    def test_control_plane_changes_are_plan_only_and_not_release_evidence(self):
        paths = ["NekoWidget/ci/ios_ci_scope.py", "NekoWidget/ci/release-testflight.py"]
        with patch.object(planner, "comparison_base", return_value="base"), \
                patch.object(planner, "orchestration_only", return_value=True):
            selected = planner.runtime_scope(paths, {}, {"GITHUB_SHA": "head"})
        self.assertEqual(selected, planner.ORCHESTRATION_SCOPE)
        self.assertEqual(planner.required_jobs(paths, selected), (planner.PLAN_JOB,))
        with self.assertRaises(ValueError):
            planner.required_jobs_from_scope(selected)

    def test_real_git_diff_rejects_product_mix_and_executable_modes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args], text=True,
                                               encoding="utf-8").rstrip("\n")
            git("init", "-q")
            git("config", "user.email", "ci@example.invalid")
            git("config", "user.name", "CI test")
            paths = ["NekoWidget/ci/ios_ci_scope.py", "NekoWidget/Shared/Model.swift"]
            for path in paths:
                file = root / path
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text("before\n", encoding="utf-8")
            git("add", ".")
            git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD")
            (root / paths[0]).write_text("after\n", encoding="utf-8")
            git("add", ".")
            git("commit", "-qm", "control plane")
            with patch.object(planner, "git", side_effect=git):
                self.assertTrue(planner.orchestration_only(paths[:1], base, "HEAD"))
                self.assertFalse(planner.orchestration_only(paths, base, "HEAD"))
                git("update-index", "--chmod=+x", paths[0])
                git("commit", "-qm", "mode change")
                self.assertFalse(planner.orchestration_only(paths[:1], base, "HEAD"))

    def test_workflow_native_changes_cannot_hide_in_control_plane_scope(self):
        path = ".github/workflows/ios-build.yml"
        before = "old trigger\n  build-without-signing:\n    run: xcodebuild\n"
        for after, expected in (
            (before.replace("old trigger", "new trigger"), True),
            (before.replace("xcodebuild", "skip build"), False),
        ):
            with patch.object(planner, "development_tools_only", return_value=True), \
                    patch.object(planner, "git", side_effect=[before, after]):
                self.assertEqual(planner.orchestration_only([path], "old", "new"), expected)

    def test_app_views_without_widget_inputs_never_select_gallery(self):
        for name in ("SettingsView.swift", "CatProfilesView.swift", "PhotoMemoryNoteView.swift"):
            path = "NekoWidget/NekoWidget/Views/" + name
            with self.subTest(path=path):
                selected = scope.select_scope({path: ("old action", "new action")})
                self.assertEqual(selected, scope.APP_VIEW_SCOPE)
                self.assertFalse(any("gallery" in job for job in planner.required_jobs([path], selected)))
                mixed = {path: ("old", "new"), "NekoWidget/Shared/Storage/AtomicJSON.swift": ("old", "new")}
                self.assertEqual(scope.select_scope(mixed), scope.FULL_SCOPE)

    def test_same_repo_pr_does_not_duplicate_push_and_main_run_is_not_cancelled(self):
        workflow = (CI.parents[1] / ".github/workflows/ios-build.yml").read_text(encoding="utf-8")
        self.assertIn("if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name != github.repository", workflow)
        self.assertIn("cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}", workflow)

    def test_actual_pre_signing_shell_guard_accepts_pinned_main_ancestor_only(self):
        bash = ("C:/Program Files/Git/bin/bash.exe" if os.name == "nt" else shutil.which("bash"))
        if not bash or not Path(bash).is_file():
            self.skipTest("Bash is not installed")
        path = ".github/workflows/testflight.yml"
        workflow = (CI.parents[1] / path).read_text(encoding="utf-8")
        guard = workflow.split("      - name: Verify the requested main commit before signing", 1)[1]
        script = textwrap.dedent(guard.split("        run: |\n", 1)[1].split("      - name:", 1)[0])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args], text=True,
                                               encoding="utf-8").strip()
            git("init", "-q")
            git("config", "user.email", "ci@example.invalid")
            git("config", "user.name", "CI test")
            file = root / path
            file.parent.mkdir(parents=True)
            file.write_text(workflow, encoding="utf-8")
            git("add", ".")
            git("commit", "-qm", "tested candidate")
            candidate = git("rev-parse", "HEAD")
            (root / "unrelated.txt").write_text("other work", encoding="utf-8")
            git("add", ".")
            git("commit", "-qm", "main advances")
            main = git("rev-parse", "HEAD")
            git("update-ref", "refs/remotes/origin/main", main)
            git("checkout", "-q", "--detach", candidate)
            def check(expected, dispatch_sha):
                env = dict(os.environ, EXPECTED_MAIN_SHA=expected, GITHUB_SHA=dispatch_sha)
                return subprocess.run([bash], input=script, cwd=root, env=env,
                                      text=True, capture_output=True, timeout=15).returncode
            self.assertEqual(check(candidate, main), 0)
            self.assertNotEqual(check(main, main), 0)  # Wrong checkout.
            git("checkout", "-q", "--detach", main)
            git("update-ref", "refs/remotes/origin/main", candidate)
            self.assertNotEqual(check(main, main), 0)  # Not merged.
            file.write_text(workflow + "\n# changed signing workflow\n", encoding="utf-8")
            git("add", ".")
            git("commit", "-qm", "workflow changes")
            changed = git("rev-parse", "HEAD")
            git("update-ref", "refs/remotes/origin/main", changed)
            git("checkout", "-q", "--detach", candidate)
            self.assertNotEqual(check(candidate, changed), 0)


if __name__ == "__main__":
    unittest.main()
