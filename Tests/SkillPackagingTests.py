#!/usr/bin/env python3
"""Offline tests for the Scholar CLI and skill archive layouts."""

import hashlib
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
import zipfile


REPO_ROOT = Path(__file__).resolve().parents[1]
PACKAGER = REPO_ROOT / "scripts" / "package.sh"
RELEASE_SCRIPT = REPO_ROOT / "scripts" / "release.sh"


class SkillPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.fixture_root = Path(self.temp_dir.name) / "fixture repository with spaces"
        self.staging = Path(self.temp_dir.name) / "staging directory with spaces"
        self.skill_source = self.fixture_root / "skills" / "scholar-search"
        self.binary = self.fixture_root / "signed build" / "scholar"
        self.staging.mkdir(parents=True)

        self._write(self.fixture_root / "README.md", "fixture readme\n")
        self._write(self.fixture_root / "LICENSE", "fixture licence\n")
        self._write(self.fixture_root / "NOTICE", "fixture notice\n")
        self._write(self.skill_source / "SKILL.md", "skill instructions\n")
        self._write(self.skill_source / "agents" / "openai.yaml", "interface: {}\n")
        self._write(
            self.skill_source / "scripts" / "run-scholar",
            "#!/bin/sh\nexec \"$(dirname \"$0\")/../bin/scholar\" \"$@\"\n",
            executable=True,
        )
        self._write(self.binary, "signed-binary-fixture\n", executable=True)

        self._write(self.skill_source / "Tests" / "ShouldNotShip.py", "test artifact\n")
        self._write(self.fixture_root / "Sources" / "ShouldNotShip.swift", "source artifact\n")
        self._set_xattr(
            self.skill_source / "SKILL.md",
            "com.apple.ResourceFork",
            "fixture resource fork",
        )
        self._set_xattr(
            self.binary,
            "com.example.scholar-packaging-test",
            "fixture extended attribute",
        )

    def tearDown(self):
        self.temp_dir.cleanup()

    @staticmethod
    def _write(path, content, executable=False):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        if executable:
            path.chmod(path.stat().st_mode | 0o111)

    @staticmethod
    def _set_xattr(path, name, value):
        subprocess.run(
            ["/usr/bin/xattr", "-w", name, value, str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )

    @staticmethod
    def _list_xattrs(path):
        result = subprocess.run(
            ["/usr/bin/xattr", str(path)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        return result.stdout.splitlines()

    def _run_packager(self):
        return subprocess.run(
            [
                str(PACKAGER),
                "--repository-root",
                str(self.fixture_root),
                "--binary",
                str(self.binary),
                "--output-directory",
                str(self.staging),
                "--version",
                "0.1.0",
                "--development",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    @staticmethod
    def _source_snapshot(root):
        snapshot = {}
        for path in sorted(root.rglob("*")):
            if path.is_file():
                snapshot[str(path.relative_to(root))] = (
                    hashlib.sha256(path.read_bytes()).hexdigest(),
                    path.stat().st_mode & 0o777,
                )
        return snapshot

    @staticmethod
    def _archive_files(archive):
        with zipfile.ZipFile(archive) as bundle:
            return {name for name in bundle.namelist() if not name.endswith("/")}

    @staticmethod
    def _read_archive_file(archive, member):
        with zipfile.ZipFile(archive) as bundle:
            return bundle.read(member)

    @staticmethod
    def _archive_mode(archive, member):
        with zipfile.ZipFile(archive) as bundle:
            return bundle.getinfo(member).external_attr >> 16

    def test_archives_have_whitelisted_layouts_and_identical_binaries(self):
        self.assertIn(
            "com.apple.ResourceFork", self._list_xattrs(self.skill_source / "SKILL.md")
        )
        self.assertIn(
            "com.example.scholar-packaging-test", self._list_xattrs(self.binary)
        )
        source_before = self._source_snapshot(self.fixture_root)

        result = self._run_packager()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self._source_snapshot(self.fixture_root), source_before)
        self.assertFalse((self.skill_source / "bin").exists())
        self.assertIn(
            "com.apple.ResourceFork", self._list_xattrs(self.skill_source / "SKILL.md")
        )
        self.assertIn(
            "com.example.scholar-packaging-test", self._list_xattrs(self.binary)
        )

        cli_archive = self.staging / "scholar-0.1.0-macos-universal-dev.zip"
        skill_archive = self.staging / "scholar-search-0.1.0-macos-universal-dev.zip"
        cli_root = "scholar-0.1.0-macos-universal-dev"
        bundled_skill = f"{cli_root}/skills/scholar-search"

        expected_skill_files = {
            "SKILL.md",
            "agents/openai.yaml",
            "scripts/run-scholar",
            "bin/scholar",
            "LICENSE",
            "NOTICE",
        }
        expected_cli_files = {
            f"{cli_root}/scholar",
            f"{cli_root}/README.md",
            f"{cli_root}/LICENSE",
            f"{cli_root}/NOTICE",
            *(f"{bundled_skill}/{name}" for name in expected_skill_files),
        }
        expected_standalone_files = {
            f"scholar-search/{name}" for name in expected_skill_files
        }

        self.assertEqual(self._archive_files(cli_archive), expected_cli_files)
        self.assertEqual(self._archive_files(skill_archive), expected_standalone_files)
        self.assertFalse(
            any(
                name == "__MACOSX" or name.startswith("__MACOSX/")
                for name in self._archive_files(cli_archive)
                | self._archive_files(skill_archive)
            )
        )

        source_bytes = self.binary.read_bytes()
        binary_members = [
            (cli_archive, f"{cli_root}/scholar"),
            (cli_archive, f"{bundled_skill}/bin/scholar"),
            (skill_archive, "scholar-search/bin/scholar"),
        ]
        for archive, member in binary_members:
            self.assertEqual(self._read_archive_file(archive, member), source_bytes)
            self.assertNotEqual(self._archive_mode(archive, member) & 0o111, 0)

        launcher_members = [
            (cli_archive, f"{bundled_skill}/scripts/run-scholar"),
            (skill_archive, "scholar-search/scripts/run-scholar"),
        ]
        for archive, member in launcher_members:
            self.assertNotEqual(self._archive_mode(archive, member) & 0o111, 0)

        legal_members = [
            (cli_archive, f"{cli_root}/LICENSE", b"fixture licence\n"),
            (cli_archive, f"{cli_root}/NOTICE", b"fixture notice\n"),
            (cli_archive, f"{bundled_skill}/LICENSE", b"fixture licence\n"),
            (cli_archive, f"{bundled_skill}/NOTICE", b"fixture notice\n"),
            (skill_archive, "scholar-search/LICENSE", b"fixture licence\n"),
            (skill_archive, "scholar-search/NOTICE", b"fixture notice\n"),
        ]
        for archive, member, expected_content in legal_members:
            self.assertEqual(
                self._read_archive_file(archive, member), expected_content
            )

        for archive in (cli_archive, skill_archive):
            files = self._archive_files(archive)
            self.assertFalse(any("ShouldNotShip" in name for name in files))
            self.assertFalse(any("Sources/" in name or "/Tests/" in name for name in files))

    def test_checksum_files_match_archive_bytes(self):
        result = self._run_packager()
        self.assertEqual(result.returncode, 0, result.stderr)

        archive_names = [
            "scholar-0.1.0-macos-universal-dev.zip",
            "scholar-search-0.1.0-macos-universal-dev.zip",
        ]
        for archive_name in archive_names:
            archive = self.staging / archive_name
            checksum = (self.staging / f"{archive_name}.sha256").read_text(
                encoding="utf-8"
            )
            expected_hash = hashlib.sha256(archive.read_bytes()).hexdigest()
            self.assertEqual(checksum, f"{expected_hash}  {archive_name}\n")

    def test_missing_skill_input_fails_before_creating_outputs(self):
        (self.skill_source / "agents" / "openai.yaml").unlink()

        result = self._run_packager()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Required packaging input is missing", result.stderr)
        self.assertEqual(list(self.staging.iterdir()), [])


class ReleaseWorkflowTests(unittest.TestCase):
    def test_release_publishes_only_after_both_notarization_checks(self):
        source = RELEASE_SCRIPT.read_text(encoding="utf-8")

        sign_position = source.index(
            '/usr/bin/codesign --force --sign "$signing_identity"'
        )
        package_position = source.index('"$script_directory/package.sh"')
        cli_submit_position = source.index(
            'submit_for_notarization "$staged_archive" "$cli_notary_result"'
        )
        skill_submit_position = source.index(
            'submit_for_notarization "$staged_skill_archive" "$skill_notary_result"'
        )
        publication_position = source.index(
            '/bin/mv "$staged_archive" "$public_archive"'
        )

        self.assertLess(sign_position, package_position)
        self.assertLess(package_position, cli_submit_position)
        self.assertLess(cli_submit_position, skill_submit_position)
        self.assertLess(skill_submit_position, publication_position)
        self.assertIn('if [[ "$notary_status" != "Accepted" ]]', source)
        self.assertIn("return 1", source)

    def test_second_notarization_rejection_prevents_publication(self):
        source = RELEASE_SCRIPT.read_text(encoding="utf-8")
        function_start = source.index("submit_for_notarization() {")
        function_end = source.index("\n}\n", function_start) + len("\n}\n")
        function_source = source[function_start:function_end]

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            counter = root / "submission-count"
            mock_xcrun = root / "mock xcrun"
            first_archive = root / "first archive.zip"
            second_archive = root / "second archive.zip"
            publication_marker = root / "published"
            first_result = root / "first result.plist"
            second_result = root / "second result.plist"
            first_archive.write_bytes(b"first")
            second_archive.write_bytes(b"second")
            mock_xcrun.write_text(
                "#!/bin/sh\n"
                f"counter={shlex.quote(str(counter))}\n"
                "count=0\n"
                "if test -f \"$counter\"; then count=$(cat \"$counter\"); fi\n"
                "count=$((count + 1))\n"
                "printf '%s\\n' \"$count\" > \"$counter\"\n"
                "if test \"$count\" -eq 1; then result=Accepted; else result=Invalid; fi\n"
                "printf '%s\\n' '<?xml version=\"1.0\" encoding=\"UTF-8\"?>'\n"
                "printf '%s\\n' '<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">'\n"
                "printf '%s\\n' '<plist version=\"1.0\"><dict><key>status</key><string>'\"$result\"'</string></dict></plist>'\n",
                encoding="utf-8",
            )
            mock_xcrun.chmod(0o755)
            function_source = function_source.replace(
                "/usr/bin/xcrun", shlex.quote(str(mock_xcrun))
            )
            harness = (
                "set -euo pipefail\n"
                "notary_profile=fixture\n"
                f"{function_source}\n"
                f"submit_for_notarization {shlex.quote(str(first_archive))} {shlex.quote(str(first_result))}\n"
                f"submit_for_notarization {shlex.quote(str(second_archive))} {shlex.quote(str(second_result))}\n"
                f": > {shlex.quote(str(publication_marker))}\n"
            )

            result = subprocess.run(
                ["/bin/zsh", "-c", harness],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(counter.read_text(encoding="utf-8"), "2\n")
            self.assertIn("Invalid", result.stderr)
            self.assertFalse(publication_marker.exists())


if __name__ == "__main__":
    unittest.main()
