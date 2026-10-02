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
        ('reviewer-settings', ['Sources/AIReviewSettings.swift', 'Tests/AIReviewSettingsTests.swift']),
        ('five-hour-activation', ['Sources/FiveHourActivation.swift', 'Tests/FiveHourActivationTests.swift']),
        ('agent-readiness', ['Sources/AgentGuardController.swift', 'Tests/AgentGuardReadinessTests.swift']),
        ('menu-activation', ['Sources/GridLayout.swift', 'Sources/FiveHourActivation.swift', 'Sources/TerminalManager.swift', 'Sources/GlobalHotKeyController.swift', 'Sources/ScheduledActivationController.swift', 'Sources/WindowSchedulePicker.swift', 'Tests/menu_activation_regression.swift']),
    ]
    commands = []
    with tempfile.TemporaryDirectory(prefix='termyes-regression-') as temp:
        for name, sources in suites:
            binary = str(Path(temp) / name)
            commands.extend([(name + ' build', ['swiftc', *sources, '-o', binary]), (name, [binary])])
        for test in ('test_agent_guard.py', 'test_permission_modes.py', 'test_activation.py', 'test_policy_update.py', 'test_ai_review.py', 'test_quiet_hours.py'):
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
        for name, command in commands:
            print('\n=== ' + name + ' ===', flush=True)
            result = subprocess.run(command, cwd=ROOT, env=environment)
            if result.returncode:
                failures.append((name, result.returncode))
        print('\nPassed: %d/%d automated steps' % (len(commands) - len(failures), len(commands)), flush=True)
        print('These results do not replace real menu clicks or Agent/reviewer model requests.', flush=True)
        for name, code in failures:
            print('FAILED: %s (exit %s)' % (name, code), flush=True)
        return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
