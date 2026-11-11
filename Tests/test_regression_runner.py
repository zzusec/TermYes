#!/usr/bin/env python3
"""Regression orchestration tests; subprocesses are mocked, no app or Agent runs."""
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('termyes_regression_runner', ROOT / 'Tools/run-regression.py')
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class RegressionRunnerTests(unittest.TestCase):
    def invoke(self, command_result=None, release=False):
        calls = []

        def run(command, **kwargs):
            calls.append(command)
            if command_result:
                code = command_result(command)
            else:
                code = 0
            return subprocess.CompletedProcess(command, code)

        output = io.StringIO()
        argv = ['run-regression.py'] + (['--release'] if release else [])
        with mock.patch.object(runner.subprocess, 'run', side_effect=run), \
                mock.patch('sys.argv', argv), contextlib.redirect_stdout(output):
            result = runner.main()
        return result, calls, output.getvalue()

    def test_compile_failure_skips_its_binary_but_runs_independent_suites(self):
        def result(command):
            if command[0] == 'swiftc' and 'Tests/main.swift' in command:
                return 1
            if len(command) == 1 and Path(command[0]).name == 'grid':
                raise FileNotFoundError('failed compilation produced no grid binary')
            return 0

        failed, calls, output = self.invoke(result)
        self.assertTrue(failed)
        self.assertFalse(any(len(command) == 1 and Path(command[0]).name == 'grid' for command in calls))
        self.assertTrue(any('Tests/VersionTests.swift' in command for command in calls))
        self.assertIn(['node', 'Tests/test_guard_plugins.mjs'], calls)
        self.assertIn('FAILED: grid build (exit 1)', output)
        self.assertIn('SKIPPED: grid', output)
        self.assertIn('1 skipped', output)

    def test_missing_tool_is_reported_and_does_not_abort_release_checks(self):
        def result(command):
            if command[0] == 'node':
                raise FileNotFoundError(2, 'No such file or directory', 'node')
            return 0

        failed, calls, output = self.invoke(result, release=True)
        self.assertTrue(failed)
        self.assertIn(['bash', 'Tests/test_update_installer.sh'], calls)
        self.assertIn(['/usr/bin/python3', '-B', 'Tests/test_release.py'], calls)
        self.assertIn('FAILED: plugins', output)
        self.assertIn('node', output)
        self.assertIn('No such file or directory', output)

    def test_missing_compiler_skips_all_swift_binaries_and_keeps_other_tests(self):
        def result(command):
            if command[0] == 'swiftc':
                raise FileNotFoundError(2, 'No such file or directory', 'swiftc')
            return 0

        failed, calls, output = self.invoke(result)
        self.assertTrue(failed)
        builds = [command for command in calls if command[0] == 'swiftc']
        self.assertTrue(builds)
        self.assertFalse(any(len(command) == 1 for command in calls))
        self.assertEqual(output.count('SKIPPED:'), len(builds))
        self.assertIn(['/usr/bin/python3', '-B', 'Tests/test_agent_guard.py'], calls)
        self.assertIn(['node', 'Tests/test_guard_plugins.mjs'], calls)

    def test_test_failure_does_not_skip_unrelated_steps(self):
        def result(command):
            return 7 if 'Tests/test_agent_guard.py' in command else 0

        failed, calls, output = self.invoke(result)
        self.assertTrue(failed)
        self.assertIn(['/usr/bin/python3', '-B', 'Tests/test_permission_modes.py'], calls)
        self.assertIn(['node', 'Tests/test_guard_plugins.mjs'], calls)
        self.assertIn('FAILED: test_agent_guard.py (exit 7)', output)
        self.assertNotIn('SKIPPED:', output)

    def test_all_successes_return_success_and_include_runner_regressions(self):
        failed, calls, output = self.invoke()
        self.assertFalse(failed)
        self.assertIn(['/usr/bin/python3', '-B', 'Tests/test_regression_runner.py'], calls)
        self.assertIn(f'Passed: {len(calls)}/{len(calls)} automated steps', output)
        self.assertNotIn('FAILED:', output)
        self.assertNotIn('SKIPPED:', output)


if __name__ == '__main__':
    unittest.main()
