#!/usr/bin/env python3
"""Fail-closed tests for the optional Codex AI permission reviewer."""

import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock
import urllib.error


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "AgentGuard"))
import ai_review


class FakeResponse:
    def __init__(self, value):
        self.body = json.dumps(value).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False

    def read(self, limit=-1):
        return self.body if limit < 0 else self.body[:limit]


def completion(decision, confidence="high", reason="test"):
    content = json.dumps({
        "decision": decision,
        "confidence": confidence,
        "reason": reason,
    })
    return {"choices": [{"message": {"content": content}}]}


class AIReviewTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="termosaic-ai-review-")
        self.root = Path(self.temporary.name)
        self.config = self.root / "ai-review.json"
        self.config.write_text(json.dumps({
            "enabled": True,
            "endpoint": "http://127.0.0.1:15722/v1/chat/completions",
            "model": "reviewer-model",
            "timeout_seconds": 5,
            "max_command_chars": 12000,
            "api_key_env": "",
            "require_high_confidence": True,
            "log_path": str(self.root / "review.log"),
        }))
        self.old_config = os.environ.get(ai_review.CONFIG_ENV)
        self.old_disable = os.environ.get(ai_review.DISABLE_ENV)
        os.environ[ai_review.CONFIG_ENV] = str(self.config)
        os.environ.pop(ai_review.DISABLE_ENV, None)

    def tearDown(self):
        if self.old_config is None:
            os.environ.pop(ai_review.CONFIG_ENV, None)
        else:
            os.environ[ai_review.CONFIG_ENV] = self.old_config
        if self.old_disable is None:
            os.environ.pop(ai_review.DISABLE_ENV, None)
        else:
            os.environ[ai_review.DISABLE_ENV] = self.old_disable
        self.temporary.cleanup()

    def review(self, command="git status"):
        return ai_review.review(command, str(ROOT), "test request")

    def test_high_confidence_allow(self):
        with mock.patch.object(ai_review.urllib.request, "urlopen", return_value=FakeResponse(completion("allow"))):
            decision = self.review()
        self.assertEqual(decision["behavior"], "allow")
        self.assertTrue(self.config.with_name("review.log").is_file())

    def test_medium_confidence_allow_is_denied(self):
        with mock.patch.object(
            ai_review.urllib.request,
            "urlopen",
            return_value=FakeResponse(completion("allow", confidence="medium")),
        ):
            decision = self.review()
        self.assertEqual(decision["behavior"], "deny")

    def test_invalid_response_is_denied(self):
        with mock.patch.object(
            ai_review.urllib.request,
            "urlopen",
            return_value=FakeResponse({"choices": [{"message": {"content": "not json"}}]}),
        ):
            decision = self.review()
        self.assertEqual(decision["behavior"], "deny")

    def test_reviewer_error_is_denied(self):
        with mock.patch.object(
            ai_review.urllib.request,
            "urlopen",
            side_effect=urllib.error.URLError("offline"),
        ):
            decision = self.review()
        self.assertEqual(decision["behavior"], "deny")

    def test_deterministic_preflight_skips_model(self):
        with mock.patch.object(ai_review.urllib.request, "urlopen") as request:
            decision = self.review("sudo git status")
        self.assertEqual(decision["behavior"], "deny")
        request.assert_not_called()

    def test_disabled_config_preserves_native_prompt(self):
        value = json.loads(self.config.read_text())
        value["enabled"] = False
        self.config.write_text(json.dumps(value))
        self.assertIsNone(self.review())

    def test_script_preview_stays_inside_workspace(self):
        script = self.root / "check.sh"
        script.write_text("#!/bin/sh\ngit status --short\n")
        previews = ai_review._script_previews(
            "bash check.sh",
            str(self.root),
            12000,
            [str(self.root)],
        )
        self.assertEqual(previews[0]["path"], "check.sh")
        self.assertIn("git status", previews[0]["content"])

        outside = ai_review._script_previews(
            "bash /etc/hosts",
            str(self.root),
            12000,
            [str(self.root)],
        )
        self.assertEqual(outside, [])

    def test_script_preview_uses_allowed_root(self):
        project = self.root / "project"
        project.mkdir()
        (project / "check.sh").write_text("git status --short\n")
        previews = ai_review._script_previews(
            "bash check.sh",
            str(self.root),
            12000,
            [str(project)],
        )
        self.assertIn("git status", previews[0]["content"])

    def test_temp_root_is_allowed_context(self):
        temp_script = Path(tempfile.mkdtemp(prefix="termosaic-review-temp-")) / "check.sh"
        temp_script.write_text("git status --short\n")
        self.addCleanup(lambda: shutil.rmtree(temp_script.parent, ignore_errors=True))
        previews = ai_review._script_previews(
            f"bash {temp_script}",
            str(ROOT),
            12000,
            [str(temp_script.parent)],
        )
        self.assertIn("git status", previews[0]["content"])
        self.assertIsNone(ai_review._preflight("rm -rf /tmp/termosaic-build", str(ROOT)))

    def test_selected_model_overrides_flat_config(self):
        value = json.loads(self.config.read_text())
        value["models"] = [
            {
                "id": "first",
                "name": "First",
                "endpoint": "http://127.0.0.1:1111/v1/chat/completions",
                "model": "model-first",
            },
            {
                "id": "second",
                "name": "Second",
                "endpoint": "http://127.0.0.1:2222/v1/chat/completions",
                "model": "model-second",
            },
        ]
        value["selected_model_id"] = "second"
        self.config.write_text(json.dumps(value))

        with mock.patch.object(
            ai_review.urllib.request,
            "urlopen",
            return_value=FakeResponse(completion("allow")),
        ) as request:
            decision = self.review()

        self.assertEqual(decision["behavior"], "allow")
        sent = json.loads(request.call_args.args[0].data.decode("utf-8"))
        self.assertEqual(sent["model"], "model-second")


if __name__ == "__main__":
    unittest.main(verbosity=2)
