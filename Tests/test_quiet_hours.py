#!/usr/bin/env python3
"""Quiet-hours schedule tests for AgentGuard sounds."""

import datetime
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "AgentGuard"))
import core


class QuietHoursTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="termosaic-quiet-hours-")
        self.config = Path(self.temporary.name) / "quiet-hours.json"
        self.config.write_text(json.dumps({
            "enabled": True,
            "start": "22:00",
            "end": "08:00",
        }))
        self.old = os.environ.get(core.QUIET_HOURS_CONFIG_ENV)
        os.environ[core.QUIET_HOURS_CONFIG_ENV] = str(self.config)

    def tearDown(self):
        if self.old is None:
            os.environ.pop(core.QUIET_HOURS_CONFIG_ENV, None)
        else:
            os.environ[core.QUIET_HOURS_CONFIG_ENV] = self.old
        self.temporary.cleanup()

    def test_quiet_period_wraps_midnight(self):
        self.assertTrue(core.in_quiet_hours(datetime.datetime(2026, 1, 1, 22, 0)))
        self.assertTrue(core.in_quiet_hours(datetime.datetime(2026, 1, 1, 23, 59)))
        self.assertTrue(core.in_quiet_hours(datetime.datetime(2026, 1, 2, 0, 0)))
        self.assertTrue(core.in_quiet_hours(datetime.datetime(2026, 1, 2, 7, 59)))
        self.assertFalse(core.in_quiet_hours(datetime.datetime(2026, 1, 2, 8, 0)))
        self.assertFalse(core.in_quiet_hours(datetime.datetime(2026, 1, 1, 21, 59)))

    def test_invalid_or_disabled_config_does_not_suppress_sound(self):
        self.config.write_text("{broken")
        self.assertFalse(core.in_quiet_hours(datetime.datetime(2026, 1, 1, 23, 0)))
        self.config.write_text(json.dumps({
            "enabled": False,
            "start": "22:00",
            "end": "08:00",
        }))
        self.assertFalse(core.in_quiet_hours(datetime.datetime(2026, 1, 1, 23, 0)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
