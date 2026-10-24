#!/usr/bin/env python3
"""Offline checks that the README, skill and --help list the same exit codes."""

from pathlib import Path
import re
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
EXIT_CODES = (0, 2, 3, 4, 5, 130, 143)


class DocsContractTests(unittest.TestCase):
    def test_readme_exit_table_lists_every_code(self):
        readme = (REPO_ROOT / "README.md").read_text(encoding="utf-8")
        for code in EXIT_CODES:
            with self.subTest(code=code):
                self.assertRegex(readme, rf"(?m)^\| {code} \|")

    def test_help_text_lists_every_code(self):
        options = (REPO_ROOT / "Sources" / "Scholar" / "Options.swift").read_text(encoding="utf-8")
        for code in EXIT_CODES:
            with self.subTest(code=code):
                self.assertRegex(options, rf"(?m)^  {code}\s+\S")

    def test_skill_lists_every_code_and_relays_steps(self):
        skill = (REPO_ROOT / "skills" / "scholar-search" / "SKILL.md").read_text(encoding="utf-8")
        for code in EXIT_CODES + (127,):
            with self.subTest(code=code):
                self.assertRegex(skill, rf"\bExit {code}\b")
        self.assertIn("word for word", skill)
        self.assertIn("Do not run the steps yourself", skill)


if __name__ == "__main__":
    unittest.main()
