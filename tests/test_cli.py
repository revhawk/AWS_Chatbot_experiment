"""Unit and contract tests for chat_cli.py (zero external dependencies)."""

import io
import json
import os
import runpy
import unittest
import urllib.error
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import MagicMock, patch

REPO_ROOT = Path(__file__).resolve().parent.parent
CLI_PATH = str(REPO_ROOT / "chat_cli.py")


def _fake_http_response(payload):
    resp = MagicMock()
    resp.read.return_value = json.dumps(payload).encode("utf-8")
    resp.__enter__.return_value = resp
    resp.__exit__.return_value = False
    return resp


class TestChatCli(unittest.TestCase):
    def test_exits_when_env_vars_missing(self):
        buf = io.StringIO()
        with patch.dict(os.environ, {}, clear=True), redirect_stdout(buf):
            with self.assertRaises(SystemExit) as ctx:
                runpy.run_path(CLI_PATH, run_name="__main__")
        self.assertEqual(ctx.exception.code, 1)
        self.assertIn("RAG_API_URL", buf.getvalue())

    def test_sends_prompt_tracks_session_id_and_prints_sources(self):
        responses = [
            _fake_http_response(
                {
                    "session_id": "sess-42",
                    "answer": "First reply",
                    "guardrail_action": "NONE",
                    "sources": ["s3://bucket/doc.pdf"],
                }
            ),
            _fake_http_response(
                {
                    "session_id": "sess-42",
                    "answer": "Second reply",
                    "guardrail_action": "INTERVENED",
                    "sources": [],
                }
            ),
        ]
        captured_requests = []

        def fake_urlopen(req, timeout=None):
            captured_requests.append((req, timeout))
            return responses.pop(0)

        inputs = iter(["", "Hello", "Follow up", "quit"])
        buf = io.StringIO()
        with (
            patch.dict(os.environ, {"RAG_API_URL": "https://api.example/chat", "RAG_API_KEY": "secret-key"}),
            patch("builtins.input", side_effect=inputs),
            patch("urllib.request.urlopen", side_effect=fake_urlopen),
            redirect_stdout(buf),
        ):
            runpy.run_path(CLI_PATH, run_name="__main__")

        self.assertEqual(len(captured_requests), 2)
        req1, timeout1 = captured_requests[0]
        self.assertEqual(req1.full_url, "https://api.example/chat")
        self.assertEqual(req1.get_method(), "POST")
        self.assertEqual(req1.get_header("X-api-key"), "secret-key")
        self.assertEqual(req1.get_header("Content-type"), "application/json")
        self.assertEqual(timeout1, 30)
        self.assertEqual(json.loads(req1.data.decode("utf-8")), {"prompt": "Hello"})

        req2, _ = captured_requests[1]
        self.assertEqual(
            json.loads(req2.data.decode("utf-8")), {"prompt": "Follow up", "session_id": "sess-42"}
        )

        out = buf.getvalue()
        self.assertIn("Assistant [NONE]: First reply", out)
        self.assertIn("Sources: s3://bucket/doc.pdf", out)
        self.assertIn("Assistant [INTERVENED]: Second reply", out)

    def test_handles_http_network_and_json_errors_gracefully(self):
        bad_json_resp = MagicMock()
        bad_json_resp.read.return_value = b"not-json"
        bad_json_resp.__enter__.return_value = bad_json_resp
        bad_json_resp.__exit__.return_value = False

        http_err = urllib.error.HTTPError(
            "https://api.example/chat", 403, "Forbidden", {}, io.BytesIO(b"Forbidden")
        )
        side_effects = [
            http_err,
            urllib.error.URLError("offline"),
            bad_json_resp,
        ]
        inputs = iter(["q1", "q2", "q3", "exit"])
        buf = io.StringIO()
        with (
            patch.dict(os.environ, {"RAG_API_URL": "https://api.example/chat", "RAG_API_KEY": "k"}),
            patch("builtins.input", side_effect=inputs),
            patch("urllib.request.urlopen", side_effect=side_effects),
            redirect_stdout(buf),
        ):
            runpy.run_path(CLI_PATH, run_name="__main__")

        out = buf.getvalue()
        self.assertIn("HTTP Error 403", out)
        self.assertIn("Network/Timeout Error", out)
        self.assertIn("non-JSON", out)

    def test_handles_eof_cleanly(self):
        buf = io.StringIO()
        with (
            patch.dict(os.environ, {"RAG_API_URL": "https://api.example/chat", "RAG_API_KEY": "k"}),
            patch("builtins.input", side_effect=EOFError),
            redirect_stdout(buf),
        ):
            runpy.run_path(CLI_PATH, run_name="__main__")
        self.assertIn("Exiting.", buf.getvalue())


if __name__ == "__main__":
    unittest.main()
