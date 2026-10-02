#!/usr/bin/env python3
"""Dedicated-window greeting tests use only temporary fake CLIs and fake guards."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'AgentGuard'))
import activate


class ActivationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='termyes-activation-test-')
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        self.results = self.home / 'results'
        self.results.mkdir(mode=0o700)
        self.manager = self.home / 'manage.py'
        self.manager.write_text('print("guard READY; this is not a model reply")\n')
        self.cli = self.home / 'fake-cli.py'
        self.cli.write_text('''#!/usr/bin/python3
import os,sys,json
from pathlib import Path
home=Path(os.environ['HOME'])
(home/'arguments.json').write_text(json.dumps(sys.argv[1:]))
(home/'stdin.txt').write_text(sys.stdin.read())
(home/'path.txt').write_text(os.environ['PATH'])
mode=(home/'mode').read_text()
if mode == 'success': print('Hi! Real fake model response')
elif mode == 'stderr': print('warning only',file=sys.stderr)
elif mode == 'fail': print('some stdout'); print('auth failed',file=sys.stderr); sys.exit(7)
elif mode == 'hang':
 import signal,time
 signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(30)
''')
        self.cli.chmod(0o700)
        (self.home / 'mode').write_text('success')

    def run_activation(self, client='claude', timeout=2):
        with mock.patch.object(activate.permission_modes, 'launcher_path', return_value=self.cli), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return activate.activate(client, self.results, self.home, self.manager, timeout)

    def test_both_client_greeting_arguments_and_private_receipts(self):
        for client in ('claude', 'codex'):
            result = self.run_activation(client)
            self.assertEqual(result, {'code': 0, 'hasReply': True, 'detail': None})
            arguments = json.loads((self.home / 'arguments.json').read_text())
            self.assertEqual(arguments, activate.ARGUMENTS[client])
            self.assertEqual(arguments[-1], 'hi')
            self.assertEqual((self.home / 'stdin.txt').read_text(), '')
            self.assertTrue((self.home / 'path.txt').read_text().startswith(str(self.home / '.local/bin') + ':'))
            receipt = self.results / (client + '.json')
            self.assertEqual(json.loads(receipt.read_text()), result)
            self.assertEqual(receipt.stat().st_mode & 0o777, 0o600)

    def test_guard_stdout_does_not_masquerade_as_reply(self):
        for mode in ('empty', 'stderr'):
            (self.home / 'mode').write_text(mode)
            result = self.run_activation()
            self.assertEqual(result['code'], 0)
            self.assertFalse(result['hasReply'])
            self.assertEqual(result['detail'], '模型未返回内容')

    def test_cli_failure_is_not_masked_by_stdout(self):
        (self.home / 'mode').write_text('fail')
        result = self.run_activation()
        self.assertEqual(result['code'], 7)
        self.assertTrue(result['hasReply'])
        self.assertIn('auth failed', result['detail'])

    def test_failed_guard_does_not_start_client(self):
        self.manager.write_text('import sys\nprint("guard denied",file=sys.stderr)\nsys.exit(1)\n')
        result = self.run_activation()
        self.assertNotEqual(result['code'], 0)
        self.assertFalse((self.home / 'arguments.json').exists())
        self.assertIn('guard denied', result['detail'])

    def test_timeout_kills_child_ignoring_sigterm(self):
        (self.home / 'mode').write_text('hang')
        start = activate.time.monotonic()
        result = self.run_activation(timeout=.1)
        self.assertEqual(result['code'], 124)
        self.assertIn('超时', result['detail'])
        self.assertLess(activate.time.monotonic() - start, 4)

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS Foundation /var/folders alias')
    def test_foundation_temp_directory_system_alias(self):
        self.assertTrue(str(self.results).startswith('/private/var/folders/'))
        alias = Path(str(self.results)[len('/private'):])
        activate.checked_directory(alias)
        with mock.patch.object(activate.permission_modes, 'launcher_path', return_value=self.cli), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            result = activate.activate('claude', alias, self.home, self.manager)
        self.assertEqual(result['code'], 0)
        self.assertTrue((self.results / 'claude.json').exists())
        link = self.home / 'alias-results'
        link.symlink_to(self.results, target_is_directory=True)
        with self.assertRaises(ValueError):
            activate.checked_directory(Path(str(link)[len('/private'):]))

    def test_private_directory_and_symlink_validation(self):
        self.results.chmod(0o755)
        with self.assertRaises(ValueError): self.run_activation()
        self.results.chmod(0o700)
        link = self.home / 'result-link'
        link.symlink_to(self.results, target_is_directory=True)
        with self.assertRaises(ValueError): activate.checked_directory(link)


if __name__ == '__main__':
    unittest.main()
