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


def responses(decision, confidence="high", reason="test"):
    content = json.dumps({
        "decision": decision,
        "confidence": confidence,
        "reason": reason,
    })
    return {"output": [{"type": "message", "content": [
        {"type": "output_text", "text": content},
    ]}]}


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
            "memory_path": str(self.root / "memory.json"),
            "sync_enabled": True,
            "sync_path": str(self.root / "cloud-memory.json"),
            "history_enabled": True,
            "history_path": str(self.root / "history.jsonl"),
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

    def codex_config(self):
        home = self.root / "codex-home"
        home.mkdir(exist_ok=True)
        (home / "config.toml").write_text(
            'model = "synthetic-codex-model"\n'
            'model_provider = "synthetic"\n'
            '[model_providers.synthetic]\n'
            'base_url = "http://127.0.0.1:15722/v1"\n'
            'wire_api = "responses"\n',
            encoding="utf-8",
        )
        (home / "auth.json").write_text(
            json.dumps({"OPENAI_API_KEY": "synthetic-review-token-do-not-use"}),
            encoding="utf-8",
        )
        environment = mock.patch.dict(os.environ, {"CODEX_HOME": str(home)})
        environment.start()
        self.addCleanup(environment.stop)
        history = mock.patch.object(ai_review, "DEFAULT_HISTORY", self.root / "auto-history.jsonl")
        history.start()
        self.addCleanup(history.stop)
        return home

    def test_unconfigured_reviewer_follows_codex_responses(self):
        self.codex_config()
        self.config.unlink()
        with mock.patch.object(
            ai_review.urllib.request, "urlopen", return_value=FakeResponse(responses("allow")),
        ) as request:
            decision = self.review()
            repeated = self.review()

        self.assertEqual(decision["behavior"], "allow")
        self.assertEqual(repeated["behavior"], "allow")
        self.assertEqual(request.call_count, 2)
        sent = request.call_args.args[0]
        body = json.loads(sent.data.decode("utf-8"))
        self.assertEqual(sent.full_url, "http://127.0.0.1:15722/v1/responses")
        self.assertEqual(sent.get_method(), "POST")
        self.assertEqual(body["model"], "synthetic-codex-model")
        self.assertEqual(json.loads(body["input"])["command"], "git status")
        self.assertFalse(body["store"])
        self.assertNotIn("messages", body)
        self.assertEqual(sent.get_header("Authorization"), "Bearer synthetic-review-token-do-not-use")
        self.assertNotIn("synthetic-review-token-do-not-use", sent.data.decode("utf-8"))

    def test_empty_manual_models_fall_back_to_codex(self):
        self.codex_config()
        self.config.write_text(json.dumps({"enabled": True, "models": []}))
        with mock.patch.object(
            ai_review.urllib.request, "urlopen", return_value=FakeResponse(responses("allow")),
        ) as request:
            decision = self.review()
        self.assertEqual(decision["behavior"], "allow")
        self.assertEqual(json.loads(request.call_args.args[0].data)["model"], "synthetic-codex-model")

    def test_auto_reviewer_denial_and_secrets_stay_out_of_records(self):
        self.codex_config()
        self.config.unlink()
        with mock.patch.object(
            ai_review.urllib.request, "urlopen", return_value=FakeResponse(responses("deny", reason="risky")),
        ):
            decision = self.review()
        self.assertEqual(decision["behavior"], "deny")
        records = (self.root / "auto-history.jsonl").read_text() + (self.root / "ai-review.log").read_text()
        self.assertNotIn("synthetic-review-token-do-not-use", json.dumps(decision) + records)

    def test_auto_reviewer_error_does_not_expose_bearer_token(self):
        self.codex_config()
        self.config.unlink()
        with mock.patch.object(
            ai_review.urllib.request, "urlopen",
            side_effect=urllib.error.URLError("transport: synthetic-review-token-do-not-use"),
        ):
            decision = self.review()
        self.assertEqual(decision["behavior"], "deny")
        records = (self.root / "auto-history.jsonl").read_text() + (self.root / "ai-review.log").read_text()
        self.assertNotIn("synthetic-review-token-do-not-use", json.dumps(decision) + records)

    def test_auto_reviewer_offline_or_invalid_response_fails_closed(self):
        self.codex_config()
        self.config.unlink()
        cases = (
            ("offline", urllib.error.URLError("offline")),
            ("missing output", FakeResponse({"output": []})),
            ("low confidence", FakeResponse(responses("allow", confidence="medium"))),
        )
        for name, response in cases:
            with self.subTest(case=name):
                with mock.patch.object(
                    ai_review.urllib.request, "urlopen",
                    side_effect=response if isinstance(response, Exception) else None,
                    return_value=None if isinstance(response, Exception) else response,
                ) as request:
                    decision = self.review()
                self.assertEqual(decision["behavior"], "deny")
                request.assert_called_once()

    def test_missing_codex_model_fails_closed_without_request(self):
        home = self.root / "no-codex-model"
        home.mkdir()
        self.config.unlink()
        with mock.patch.dict(os.environ, {"CODEX_HOME": str(home)}), mock.patch.object(
            ai_review.urllib.request, "urlopen",
        ) as request:
            decision = self.review()
        self.assertEqual(decision["behavior"], "deny")
        request.assert_not_called()

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

    def test_timeout_retries_once_before_denying(self):
        with mock.patch.object(
            ai_review.urllib.request,
            "urlopen",
            side_effect=[TimeoutError("slow"), FakeResponse(completion("allow"))],
        ) as request:
            decision = self.review()
        self.assertEqual(decision["behavior"], "allow")
        self.assertEqual(request.call_count, 2)

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

    def test_allowed_command_is_learned_by_exact_context(self):
        with mock.patch.object(
            ai_review.urllib.request,
            "urlopen",
            return_value=FakeResponse(completion("allow")),
        ) as request:
            first = self.review("git status")
        self.assertEqual(first["behavior"], "allow")
        self.assertEqual(request.call_count, 1)

        with mock.patch.object(ai_review.urllib.request, "urlopen") as second_request:
            learned = self.review("git status")
        self.assertEqual(learned["behavior"], "allow")
        second_request.assert_not_called()

        with mock.patch.object(
            ai_review.urllib.request,
            "urlopen",
            return_value=FakeResponse(completion("allow")),
        ) as changed_request:
            changed = self.review("git status --short")
        self.assertEqual(changed["behavior"], "allow")
        changed_request.assert_called_once()

    def test_repeated_allows_promote_to_bounded_pattern(self):
        for _ in range(3):
            with mock.patch.object(
                ai_review.urllib.request,
                "urlopen",
                return_value=FakeResponse(completion("allow")),
            ):
                decision = self.review("git status")
            self.assertEqual(decision["behavior"], "allow")

        with mock.patch.object(ai_review.urllib.request, "urlopen") as request:
            promoted = self.review("git status --short")
        self.assertEqual(promoted["behavior"], "allow")
        self.assertIn("命令模式", promoted["reason"])
        request.assert_not_called()

    def test_shell_composition_never_promotes_to_pattern(self):
        self.assertIsNone(ai_review._command_signature("git status && rm -rf /tmp/foo"))
        self.assertIsNone(ai_review._command_signature("git status; sudo reboot"))

    def test_command_key_is_portable_across_working_directories(self):
        first = ai_review._command_key("git status", "/Users/one/project")
        second = ai_review._command_key("git status", "/Users/two/project")
        legacy = ai_review._legacy_command_key("git status", "/Users/one/project")
        self.assertEqual(first, second)
        self.assertNotEqual(first, legacy)

    def test_local_and_cloud_memory_are_merged(self):
        local = self.root / "memory.json"
        cloud = self.root / "cloud-memory.json"
        local.write_text(json.dumps({
            "version": 2,
            "commands": {"local": {"count": 1, "last_seen": "2026-09-29T00:00:00Z"}},
            "patterns": {"git status": {"count": 3, "last_seen": "2026-09-29T00:00:00Z"}},
        }))
        cloud.write_text(json.dumps({
            "version": 2,
            "commands": {"cloud": {"count": 2, "last_seen": "2026-09-29T01:00:00Z"}},
            "patterns": {"swift test": {"count": 3, "last_seen": "2026-09-29T01:00:00Z"}},
        }))
        config = json.loads(self.config.read_text())
        merged = ai_review._load_merged_memory(config)
        self.assertEqual(set(merged["commands"]), {"local", "cloud"})
        self.assertEqual(set(merged["patterns"]), {"git status", "swift test"})

    def test_all_decisions_are_stored_locally(self):
        decision = self.review("sudo git status")
        self.assertEqual(decision["behavior"], "deny")
        history = (self.root / "history.jsonl").read_text().strip().splitlines()
        record = json.loads(history[-1])
        self.assertEqual(record["command"], "sudo git status")
        self.assertEqual(record["stage"], "preflight")

    def test_previous_decision_is_sent_back_for_review(self):
        with mock.patch.object(
            ai_review.urllib.request,
            "urlopen",
            return_value=FakeResponse(completion("deny", reason="stale denial")),
        ):
            first = self.review()
        self.assertEqual(first["behavior"], "deny")

        with mock.patch.object(
            ai_review.urllib.request,
            "urlopen",
            return_value=FakeResponse(completion("allow")),
        ) as request:
            second = self.review()
        self.assertEqual(second["behavior"], "allow")
        body = json.loads(request.call_args.args[0].data.decode("utf-8"))
        payload = json.loads(body["messages"][1]["content"])
        self.assertTrue(payload["prior_decisions"])
        self.assertIn("stale denial", payload["prior_decisions"][-1]["reason"])

    def test_window_level_ctrl_c_can_be_reviewed(self):
        prompt = "\n".join([
            "Would you like to send input to terminal 85856?",
            "1. Yes, proceed",
            "2. No",
            'Input: "\\u{3}"',
        ])
        with mock.patch.object(
            ai_review.urllib.request,
            "urlopen",
            return_value=FakeResponse(completion("allow")),
        ):
            decision = ai_review.review_terminal_input(prompt, "\\u{3}")
        self.assertEqual(decision["behavior"], "allow")

    def test_window_level_enter_and_text_are_denied_without_model(self):
        prompt = "\n".join([
            "Would you like to send input to terminal 85856?",
            "1. Yes, proceed",
            "2. No",
            'Input: "\\n"',
        ])
        with mock.patch.object(ai_review.urllib.request, "urlopen") as request:
            newline = ai_review.review_terminal_input(prompt, "\\n")
            text = ai_review.review_terminal_input(prompt, "rm -rf /")
        self.assertEqual(newline["behavior"], "deny")
        self.assertEqual(text["behavior"], "deny")
        request.assert_not_called()

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
