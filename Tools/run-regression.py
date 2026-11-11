#!/usr/bin/env python3
"""Run automated menu dependencies; live UI/model checks are recorded separately."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release', action='store_true', help='Also verify current built app and DMGs')
    args = parser.parse_args()
    environment = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
    suites = [
        ('grid', ['Sources/GridLayout.swift', 'Tests/main.swift']),
        ('versions', ['Sources/SemanticVersion.swift', 'Tests/VersionTests.swift']),
        ('release-locations', ['Sources/SemanticVersion.swift', 'Sources/GitHubReleaseLocation.swift', 'Tests/ReleaseLocationTests.swift']),
        ('private-release-cli', ['Sources/GitHubCLI.swift', 'Tests/GitHubCLITests.swift']),
        ('update-tools', ['Sources/SemanticVersion.swift', 'Sources/GitHubReleaseLocation.swift', 'Sources/GitHubCLI.swift', 'Sources/UpdateController.swift', 'Tests/UpdateToolTests.swift']),
        ('scheduled-continue', ['Sources/ContinueSchedule.swift', 'Tests/ContinueScheduleTests.swift']),
        ('agent-readiness', ['Sources/AgentGuardController.swift', 'Tests/AgentGuardReadinessTests.swift']),
        ('login-items', ['Sources/LaunchAtLoginController.swift', 'Tests/LoginItemTests.swift']),
        ('agent-update-report', ['Sources/AgentAutoUpdateController.swift', 'Tests/AgentUpdateReportTests.swift']),
        ('menu-presentation', ['Sources/MenuPresentation.swift', 'Tests/MenuPresentationTests.swift']),
        ('menu-continue', ['Sources/GridLayout.swift', 'Sources/ContinueSchedule.swift', 'Sources/TerminalManager.swift', 'Sources/GlobalHotKeyController.swift', 'Sources/ScheduledContinueController.swift', 'Tests/menu_continue_regression.swift']),
    ]
    commands = []
    with tempfile.TemporaryDirectory(prefix='termyes-regression-') as temp:
        for name, sources in suites:
            binary = str(Path(temp) / name)
            commands.extend([(name + ' build', ['swiftc', *sources, '-o', binary]), (name, [binary])])
        for test in ('test_agent_guard.py', 'test_permission_modes.py', 'test_policy_update.py', 'test_quiet_hours.py', 'test_strict_policy.py', 'test_shell_syntax.py', 'test_agent_updates.py', 'test_guard_pause.py', 'test_menu_copy.py', 'test_continue_task.py', 'test_codex_token_guard.py', 'test_regression_runner.py'):
            commands.append((test, ['/usr/bin/python3', '-B', 'Tests/' + test]))
        commands.extend([
            ('danger-list', ['bash', 'AgentGuard/test.sh']),
            ('codex-hooks', ['bash', 'AgentGuard/test-codex.sh']),
            ('plugins', ['node', 'Tests/test_guard_plugins.mjs']),
        ])
        if args.release:
            commands.extend([
                ('update-installer', ['bash', 'Tests/test_update_installer.sh']),
                ('release-images', ['/usr/bin/python3', '-B', 'Tests/test_release.py']),
            ])
        failures = []
        skipped = []
        failed_builds = set()
        for name, command in commands:
            print('\n=== ' + name + ' ===', flush=True)
            if name in failed_builds:
                skipped.append(name)
                print('SKIPPED: %s (compilation failed)' % name, flush=True)
                continue
            try:
                result = subprocess.run(command, cwd=ROOT, env=environment)
                error = 'exit %s' % result.returncode if result.returncode else None
            except OSError as exc:
                error = '%s: %s' % (command[0], exc)
            if error:
                failures.append((name, error))
                if command[0] == 'swiftc':
                    failed_builds.add(name.removesuffix(' build'))
        passed = len(commands) - len(failures) - len(skipped)
        print('\nPassed: %d/%d automated steps (%d failed, %d skipped)' %
              (passed, len(commands), len(failures), len(skipped)), flush=True)
        print('These results do not replace real menu clicks or Agent model requests.', flush=True)
        for name, error in failures:
            print('FAILED: %s (%s)' % (name, error), flush=True)
        return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
