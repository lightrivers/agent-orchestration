#!/usr/bin/env python3
"""Offline tests for skills/subagent-dispatch/scripts/check_progress.py.

The checker is executed as a subprocess with the current Python interpreter, so
these tests do not depend on bash and can run on Windows as well as POSIX.
"""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


TESTS_DIR = Path(__file__).resolve().parent
CHECKER = TESTS_DIR.parent / "scripts" / "check_progress.py"
FIXTURES = TESTS_DIR / "check_progress_test"


class CheckProgressTests(unittest.TestCase):
    def setUp(self):
        self._temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._temp_dir.cleanup)
        self.temp_path = Path(self._temp_dir.name)

        # Point the checker at a non-existent AGENT_ORCH_HOME so the real user
        # config never affects the tests.
        self.agent_orch_home = self.temp_path / "missing-agent-orch-home"
        self.config_file = self.temp_path / "config.json"
        self.config_file.write_text(
            '{"protected_paths": ["/data/keep"]}\n', encoding="utf-8"
        )

    def run_checker(self, *args):
        env = os.environ.copy()
        env["AGENT_ORCH_HOME"] = str(self.agent_orch_home)
        env["PYTHONIOENCODING"] = "utf-8"
        return subprocess.run(
            [sys.executable, str(CHECKER), *(str(arg) for arg in args)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=env,
            check=False,
        )

    def assert_exit_code(self, result, expected, label):
        if result.returncode != expected:
            self.fail(
                "{}: expected exit {}, got {}\noutput:\n{}".format(
                    label, expected, result.returncode, result.stdout
                )
            )

    def assert_has_line(self, result, predicate, label):
        if not any(predicate(line) for line in result.stdout.splitlines()):
            self.fail("{}\noutput:\n{}".format(label, result.stdout))

    def test_clean_fixture(self):
        result = self.run_checker(FIXTURES / "clean")
        self.assert_exit_code(result, 0, "clean")
        self.assert_has_line(result, lambda line: line == "OK", "clean: missing OK line")

    def test_has_high_fixture(self):
        result = self.run_checker(FIXTURES / "has_high")
        self.assert_exit_code(result, 2, "has_high")
        self.assert_has_line(
            result,
            lambda line: line.startswith("HIGH |"),
            "has_high: missing HIGH alert",
        )

    def test_has_medium_fixture(self):
        result = self.run_checker(FIXTURES / "has_medium")
        self.assert_exit_code(result, 1, "has_medium")
        self.assert_has_line(
            result,
            lambda line: line.startswith("MEDIUM |"),
            "has_medium: missing MEDIUM alert",
        )
        if any(line.startswith("HIGH |") for line in result.stdout.splitlines()):
            self.fail("has_medium: should not contain a HIGH alert\noutput:\n{}".format(
                result.stdout
            ))

    def test_has_protected_without_protected_paths(self):
        result = self.run_checker(FIXTURES / "has_protected")
        self.assert_exit_code(result, 0, "has_protected")
        self.assert_has_line(
            result,
            lambda line: line == "OK",
            "has_protected: missing OK line",
        )

    def test_has_protected_via_cli(self):
        result = self.run_checker(
            FIXTURES / "has_protected", "--protected-path", "/data/keep"
        )
        self.assert_exit_code(result, 2, "protected-cli")
        if "受保护路径写操作" not in result.stdout:
            self.fail(
                "protected-cli: missing protected-path alert\noutput:\n{}".format(
                    result.stdout
                )
            )

    def test_has_protected_via_config(self):
        result = self.run_checker(
            FIXTURES / "has_protected", "--config", self.config_file
        )
        self.assert_exit_code(result, 2, "protected-config")
        if "受保护路径写操作" not in result.stdout:
            self.fail(
                "protected-config: missing protected-path alert\noutput:\n{}".format(
                    result.stdout
                )
            )

    def test_protected_path_after_cd_regression(self):
        task_dir = self.temp_path / "cd-and-remove"
        task_dir.mkdir()
        (task_dir / "progress.md").write_text(
            "时间 | 级别 | 命令 | 目的 | 结果\n"
            "2026-01-01 10:00 | L1 | cd /data/keep && rm x | 清理 | 完成\n",
            encoding="utf-8",
        )
        result = self.run_checker(task_dir, "--protected-path", "/data/keep")
        self.assert_exit_code(result, 2, "cd-and-remove")


if __name__ == "__main__":
    unittest.main()
