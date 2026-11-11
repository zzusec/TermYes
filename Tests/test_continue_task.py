#!/usr/bin/env python3
"""Exercise the production continue helper with isolated fake agents only."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "AgentGuard"


class ContinueTaskTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="termyes-continue-test-")
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name).resolve()
        self.bin = self.home / ".local/bin"
        self.bin.mkdir(parents=True)
        self.results = self.home / "results"
        self.results.mkdir(mode=0o700)
        self.manager = self.home / "manage.py"
        self.manager.write_text("import sys\nassert sys.argv[1:] == ['ensure', 'claude']\n")
        self.agent = self.bin / "claude"

    def run_helper(self, script, timeout=2):
        self.agent.write_text("#!" + sys.executable + "\n" + script)
        self.agent.chmod(0o700)
        driver = "\n".join([
            "import sys, pathlib, signal",
            "sys.path.insert(0, sys.argv[1])",
            "import continue_task as helper",
            "home = pathlib.Path(sys.argv[2])",
            # Never resolve an installed client or mutate the user's config.
            "helper.permission_modes._default_search_dirs = lambda _: [home / '.local/bin']",
            "signal.signal(signal.SIGTERM, helper.cancel_continue)",
            "helper.continue_task('claude', home / 'results', home, home / 'manage.py', timeout=float(sys.argv[3]))",
        ])
        environment = dict(os.environ, HOME=str(self.home), PATH=str(self.bin), PYTHONDONTWRITEBYTECODE="1")
        result = subprocess.run([sys.executable, "-I", "-B", "-c", driver, str(SOURCE), str(self.home), str(timeout)],
                                env=environment, cwd=str(self.home), capture_output=True, timeout=8)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        return json.loads((self.results / "claude.json").read_text()), result

    def test_success_runs_cli_and_forwards_actual_reply(self):
        record, result = self.run_helper("import sys\nprint('实际模型回复')\nprint('diagnostic', file=sys.stderr)\n")
        self.assertEqual(record, {"code": 0, "hasReply": True, "detail": None})
        self.assertIn("实际模型回复".encode(), result.stdout)
        self.assertIn(b"diagnostic", result.stderr)
        self.assertEqual((self.results / "claude.json").stat().st_mode & 0o777, 0o600)

    def test_nonzero_exit_is_not_hidden_by_stdout(self):
        record, result = self.run_helper("import sys\nprint('partial reply')\nprint('auth failed', file=sys.stderr)\nsys.exit(7)\n")
        self.assertEqual(record["code"], 7)
        self.assertTrue(record["hasReply"])
        self.assertEqual(record["detail"], "auth failed")
        self.assertIn(b"partial reply", result.stdout)

    def test_stderr_only_does_not_count_as_reply(self):
        record, _ = self.run_helper("import sys\nprint('warning only', file=sys.stderr)\n")
        self.assertEqual(record["code"], 0)
        self.assertFalse(record["hasReply"])
        self.assertEqual(record["detail"], "模型未返回内容")

    def test_drains_both_pipes_beyond_the_pipe_buffer(self):
        record, result = self.run_helper("import sys\nsys.stdout.write('x' * 150000)\nsys.stderr.write('y' * 150000)\n")
        self.assertEqual(record["code"], 0)
        self.assertTrue(record["hasReply"])
        self.assertIn(b"x" * 150000, result.stdout)
        self.assertEqual(result.stderr, b"y" * 150000)

    def test_closed_output_still_waits_for_process_exit(self):
        record, _ = self.run_helper("import os,time\nos.close(1)\nos.close(2)\ntime.sleep(0.1)\nraise SystemExit(9)\n")
        self.assertEqual(record["code"], 9)
        self.assertFalse(record["hasReply"])

    def assert_stopped(self, pid):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True)
            if result.returncode or result.stdout.strip().startswith("Z"):
                return
            time.sleep(0.02)
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.fail("continue helper left its request process alive")

    def process_script(self, ending):
        return "\n".join([
            "import os,pathlib,signal,subprocess,sys,time",
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)",
            "child = subprocess.Popen([sys.executable, '-c', 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)'])",
            "pathlib.Path(os.environ['HOME'], 'pids').write_text(str(os.getpid()) + ' ' + str(child.pid))",
            ending,
        ])

    def test_timeout_kills_agent_and_descendants(self):
        started = time.monotonic()
        record, _ = self.run_helper(self.process_script("time.sleep(30)"), timeout=2)
        self.assertEqual(record["code"], 124)
        self.assertEqual(record["detail"], "模型请求超时")
        self.assertLess(time.monotonic() - started, 5)
        for pid in (self.home / "pids").read_text().split():
            self.assert_stopped(int(pid))

    def test_timeout_kills_descendant_after_launcher_exits(self):
        record, _ = self.run_helper(self.process_script("sys.exit(0)"), timeout=2)
        self.assertEqual(record["code"], 124)
        for pid in (self.home / "pids").read_text().split():
            self.assert_stopped(int(pid))

    def test_window_cancellation_kills_the_request(self):
        record, _ = self.run_helper(self.process_script("time.sleep(0.1)\nos.kill(os.getppid(), signal.SIGTERM)\ntime.sleep(30)"))
        self.assertNotEqual(record["code"], 0)
        self.assertIn("请求已取消", record["detail"])
        for pid in (self.home / "pids").read_text().split():
            self.assert_stopped(int(pid))

    def test_failed_guard_never_launches_agent(self):
        self.manager.write_text("import sys\nprint('guard rejected', file=sys.stderr)\nsys.exit(5)\n")
        record, _ = self.run_helper("raise RuntimeError('must not launch')\n")
        self.assertEqual(record["code"], 1)
        self.assertFalse(record["hasReply"])
        self.assertIn("guard rejected", record["detail"])


if __name__ == "__main__":
    unittest.main()
