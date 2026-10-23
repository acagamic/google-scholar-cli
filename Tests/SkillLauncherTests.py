#!/usr/bin/env python3
"""Offline behavior tests for the portable Scholar Search launcher."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCE_LAUNCHER = REPO_ROOT / "skills" / "scholar-search" / "scripts" / "run-scholar"


class SkillLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)

    def tearDown(self):
        self.temp_dir.cleanup()

    def _stage_launcher(self, name="stage"):
        stage = self.root / name
        launcher = stage / "skills" / "scholar-search" / "scripts" / "run-scholar"
        launcher.parent.mkdir(parents=True)
        shutil.copy2(SOURCE_LAUNCHER, launcher)
        launcher.chmod(launcher.stat().st_mode | 0o111)
        return stage, launcher

    def _fake(self, path, source, exit_code=0, stderr=None, stdout=None):
        path.parent.mkdir(parents=True, exist_ok=True)
        stderr_line = "" if stderr is None else f"printf '%s\\n' '{stderr}' >&2\n"
        stdout_line = "" if stdout is None else f"printf '%s\\n' '{stdout}'\n"
        path.write_text(
            "#!/bin/sh\n"
            f"printf 'source={source}\\n'\n"
            "for arg do\n"
            "    printf 'arg=%s\\n' \"$arg\"\n"
            "done\n"
            f"{stdout_line}"
            f"{stderr_line}"
            f"exit {exit_code}\n",
            encoding="utf-8",
        )
        path.chmod(path.stat().st_mode | 0o111)
        return path

    @staticmethod
    def _environment(path_value):
        environment = os.environ.copy()
        environment["PATH"] = path_value
        environment.pop("SCHOLAR_BIN", None)
        return environment

    @staticmethod
    def _run(launcher, args, environment, cwd=None):
        return subprocess.run(
            [str(launcher), *args],
            cwd=cwd,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_explicit_override_preserves_argv_and_status(self):
        stage, launcher = self._stage_launcher()
        fake = self._fake(self.root / "override" / "scholar", "override", exit_code=37)
        environment = self._environment("/usr/bin:/bin")
        environment["SCHOLAR_BIN"] = str(fake)
        args = [
            "search",
            "--format",
            "json",
            "--",
            "-leading query",
            "space name",
            "literal;$(touch should-not-exist)",
        ]

        result = self._run(launcher, args, environment, cwd=stage)

        self.assertEqual(result.returncode, 37)
        self.assertEqual(result.stderr, "")
        self.assertEqual(
            result.stdout.splitlines(),
            [
                "source=override",
                "arg=search",
                "arg=--format",
                "arg=json",
                "arg=--",
                "arg=-leading query",
                "arg=space name",
                "arg=literal;$(touch should-not-exist)",
            ],
        )
        self.assertFalse((stage / "should-not-exist").exists())

    def test_invalid_override_fails_without_fallback(self):
        stage, launcher = self._stage_launcher()
        path_fake = self._fake(self.root / "path" / "scholar", "path")
        environment = self._environment(str(path_fake.parent))
        environment["SCHOLAR_BIN"] = str(self.root / "missing" / "scholar")

        result = self._run(launcher, ["search", "--", "query"], environment, cwd=stage)

        self.assertEqual(result.returncode, 127)
        self.assertIn("SCHOLAR_BIN", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_non_executable_override_fails_without_fallback(self):
        stage, launcher = self._stage_launcher()
        invalid = self.root / "override" / "scholar"
        invalid.parent.mkdir(parents=True)
        invalid.write_text("not executable\n", encoding="utf-8")
        path_fake = self._fake(self.root / "path" / "scholar", "path")
        environment = self._environment(str(path_fake.parent))
        environment["SCHOLAR_BIN"] = str(invalid)

        result = self._run(launcher, ["search", "--", "query"], environment, cwd=stage)

        self.assertEqual(result.returncode, 127)
        self.assertIn("SCHOLAR_BIN", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_bundled_executable_wins_over_path(self):
        stage, launcher = self._stage_launcher()
        self._fake(stage / "skills" / "scholar-search" / "bin" / "scholar", "bundled")
        path_fake = self._fake(self.root / "path" / "scholar", "path")
        environment = self._environment(str(path_fake.parent))

        result = self._run(launcher, ["search", "--", "query"], environment, cwd=stage)

        self.assertEqual(result.returncode, 0)
        self.assertTrue(result.stdout.startswith("source=bundled\n"))

    def test_path_executable_is_used_when_bundle_is_absent(self):
        stage, launcher = self._stage_launcher()
        path_fake = self._fake(self.root / "path" / "scholar", "path")
        environment = self._environment(str(path_fake.parent))

        result = self._run(launcher, ["search", "--", "query"], environment, cwd=stage)

        self.assertEqual(result.returncode, 0)
        self.assertTrue(result.stdout.startswith("source=path\n"))

    def test_repo_dist_fallback_is_used_after_path(self):
        stage, launcher = self._stage_launcher()
        self._fake(stage / "dist" / "scholar", "repo")
        environment = self._environment("/usr/bin:/bin")

        result = self._run(launcher, ["search", "--", "query"], environment, cwd=stage)

        self.assertEqual(result.returncode, 0)
        self.assertTrue(result.stdout.startswith("source=repo\n"))

    def test_missing_executable_reports_127(self):
        stage, launcher = self._stage_launcher()
        environment = self._environment(str(self.root / "empty-path"))

        result = self._run(launcher, [], environment, cwd=stage)

        self.assertEqual(result.returncode, 127)
        self.assertEqual(result.stdout, "")
        self.assertIn("Could not find the scholar executable", result.stderr)

    def test_bare_invocation_delegates_without_added_arguments(self):
        stage, launcher = self._stage_launcher()
        fake = self._fake(self.root / "override" / "scholar", "override")
        environment = self._environment("/usr/bin:/bin")
        environment["SCHOLAR_BIN"] = str(fake)

        result = self._run(launcher, [], environment, cwd=stage)

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "source=override\n")

    def test_launcher_works_from_arbitrary_cwd_and_path_with_spaces(self):
        stage, launcher = self._stage_launcher("stage with spaces")
        self._fake(stage / "skills" / "scholar-search" / "bin" / "scholar", "bundled")
        other_directory = self.root / "unrelated directory"
        other_directory.mkdir()
        environment = self._environment("/usr/bin:/bin")

        result = self._run(
            launcher,
            ["search", "--", "-query with spaces"],
            environment,
            cwd=other_directory,
        )

        self.assertEqual(result.returncode, 0)
        self.assertIn("arg=-query with spaces\n", result.stdout)

    def test_stdout_stderr_and_exit_code_are_unchanged(self):
        stage, launcher = self._stage_launcher()
        fake = self._fake(
            self.root / "override" / "scholar",
            "override",
            exit_code=23,
            stdout="fake stdout",
            stderr="fake stderr",
        )
        environment = self._environment("/usr/bin:/bin")
        environment["SCHOLAR_BIN"] = str(fake)

        result = self._run(launcher, ["--help"], environment, cwd=stage)

        self.assertEqual(result.returncode, 23)
        self.assertEqual(result.stdout, "source=override\narg=--help\nfake stdout\n")
        self.assertEqual(result.stderr, "fake stderr\n")


if __name__ == "__main__":
    unittest.main()
