"""Synthetic transport tests: no real credentials, network, model, or user data."""
import io
import json
import socket
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import urllib.error

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Backend"))
import remote_model as remote
import local_pipeline as pipeline

FAKE_KEY = "synthetic-test-key-never-real"
SCHEMA = {"type": "object", "properties": {"ok": {"type": "boolean", "enum": [True]}},
          "required": ["ok"], "additionalProperties": False}


def config(**changes):
    value = {"baseURL": "https://example.invalid/v1", "approvedEndpoint": "https://example.invalid/v1",
             "model": "synthetic-model", "contextWindow": 32768, "maxOutputTokens": 4096}
    value.update(changes)
    return value


def envelope(content='{"ok":true}', finish="stop", **message):
    return {"choices": [{"finish_reason": finish, "message": {"content": content, **message}}]}


class RemoteModelTests(unittest.TestCase):
    def setUp(self):
        p = patch.dict(remote.os.environ, {"KNOWLEDGE_SPINE_API_KEY": FAKE_KEY})
        p.start()
        self.addCleanup(p.stop)
        self.opener = Mock()
        p = patch.object(remote.urllib.request, "build_opener", return_value=self.opener)
        self.builder = p.start()
        self.addCleanup(p.stop)
        self.respond(envelope())

    def respond(self, value, raw=False):
        self.opener.open.side_effect = None
        data = value if raw else json.dumps(value).encode()
        self.opener.open.return_value.__enter__ = Mock(return_value=SimpleNamespace(read=lambda maximum: data[:maximum]))
        self.opener.open.return_value.__exit__ = Mock(return_value=False)

    def call(self, model=None, schema=SCHEMA, **sampling):
        return (model or remote.RemoteModel(config())).structured("合成系统提示", "合成文字", schema, **sampling)

    def test_https_and_loopback_only(self):
        for base in ("https://example.invalid/v1", "http://127.0.0.1:8000/v1", "http://localhost:8000/v1", "http://[::1]:8000/v1"):
            self.assertTrue(remote.endpoint_url(base).endswith("/chat/completions"))
        for base in ("http://example.invalid", "http://127.0.0.2", "file:///tmp/x", "https://a@b/v1",
                     "https://a:b@host/v1", "https://host/v1?key=x", "https://host/v1#x", "https://host:wrong", "https:// host"):
            with self.subTest(base=base), self.assertRaises(remote.RemoteAPIError):
                remote.endpoint_url(base)
        self.assertEqual(remote.endpoint_url("https://example.invalid/chat/completions/"),
                         "https://example.invalid/chat/completions")

    def test_changed_address_requires_approval_before_network(self):
        with self.assertRaises(remote.RemoteAPIError):
            remote.RemoteModel(config(baseURL="https://different.invalid/v1"))
        self.opener.open.assert_not_called()

    def test_manifest_key_cannot_replace_environment_key(self):
        with patch.dict(remote.os.environ, {"KNOWLEDGE_SPINE_API_KEY": ""}):
            with self.assertRaises(remote.RemoteAPIError):
                remote.RemoteModel(config(apiKey="manifest-secret", key="manifest-secret"))
        self.assertEqual(remote.RemoteModel(config(apiKey="ignored")).key, FAKE_KEY)
        self.opener.open.assert_not_called()

    def test_api_route_does_not_require_or_load_gguf(self):
        fake_llama = Mock(side_effect=AssertionError("must not load local model"))
        with patch.dict(sys.modules, {"llama_cpp": SimpleNamespace(Llama=fake_llama)}), patch("model_lease.acquire_model_lease") as lease:
            model = pipeline.load_structure_model({"analysis_provider": "api", "api_configuration": config(),
                                                   "structure_model_path": "/not/a/model.gguf"})
        self.assertTrue(model.is_remote)
        fake_llama.assert_not_called()
        lease.assert_not_called()
        self.opener.open.assert_not_called()
        self.assertEqual(pipeline.structured_completion(model, "s", "p", SCHEMA, reasoned_json=True), {"ok": True})

    def test_default_local_never_constructs_or_requests_remote(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "synthetic.gguf"
            with path.open("wb") as f:
                f.write(b"GGUF")
                f.truncate(1_000_000_001)
            fake_llama = Mock(return_value=Mock())
            with patch.dict(sys.modules, {"llama_cpp": SimpleNamespace(Llama=fake_llama)}), patch("model_lease.acquire_model_lease"), patch.object(remote, "RemoteModel") as api:
                model = pipeline.load_structure_model({"structure_model_path": str(path)})
                model.close()
            fake_llama.assert_called_once()
            api.assert_not_called()
        self.opener.open.assert_not_called()

    def test_bearer_text_schema_mimo_parameters_and_no_llama_fields(self):
        model = remote.RemoteModel(config(tokenLimitField="max_completion_tokens", thinkingMode="disabled",
                                         audio_paths=["/private/synthetic-audio.wav"]))
        self.assertEqual(self.call(model, max_tokens=99, reasoning_tokens=8, reasoned_json=True,
                                   temperature=0.1, grammar="do-not-send", audio_paths=["secret.wav"]), {"ok": True})
        request = self.opener.open.call_args.args[0]
        payload = json.loads(request.data)
        self.assertEqual(request.get_header("Authorization"), "Bearer " + FAKE_KEY)
        self.assertEqual(self.opener.open.call_args.kwargs["timeout"], 120)
        self.assertEqual(payload["max_completion_tokens"], 4096)
        self.assertEqual(payload["thinking"], {"type": "disabled"})
        self.assertEqual(payload["response_format"], {"type": "json_object"})
        self.assertIn('"required":["ok"]', payload["messages"][1]["content"])
        for name in ("reasoning_tokens", "temperature", "grammar", "max_tokens", "audio_paths", "reasoned_json"):
            self.assertNotIn(name, payload)
        self.assertNotIn(".wav", request.data.decode())
        self.assertNotIn(FAKE_KEY, request.data.decode())

    def test_http_errors_and_timeouts_never_echo_provider_secrets_or_retry(self):
        for error in (urllib.error.HTTPError("https://example.invalid/" + FAKE_KEY, 401, FAKE_KEY, {}, io.BytesIO(FAKE_KEY.encode())),
                      urllib.error.HTTPError("https://example.invalid", 429, FAKE_KEY, {}, io.BytesIO(FAKE_KEY.encode())),
                      socket.timeout(FAKE_KEY), urllib.error.URLError(FAKE_KEY)):
            self.opener.open.reset_mock()
            self.opener.open.side_effect = error
            with self.assertRaises(remote.RemoteAPIError) as caught:
                self.call()
            self.assertNotIn(FAKE_KEY, str(caught.exception))
            self.assertEqual(self.opener.open.call_count, 1)

    def test_redirect_blocked_without_following(self):
        model = remote.RemoteModel(config())
        handler = self.builder.call_args.args[0]
        self.assertIsInstance(handler, remote.NoRedirect)
        with self.assertRaises(remote.RemoteAPIError):
            handler.redirect_request(None, None, 302, "redirect", {}, "https://attacker.invalid")
        self.opener.open.side_effect = remote.RemoteAPIError("重定向已阻止")
        with self.assertRaises(remote.RemoteAPIError):
            self.call(model)
        self.assertEqual(self.opener.open.call_count, 1)

    def test_bad_results_rejected(self):
        cases = [envelope(finish="length"), envelope(finish="content_filter"),
                 envelope(tool_calls=[{"id": "x"}]), envelope(refusal="refused"),
                 envelope("not json"), envelope('{"ok":false}'), envelope('{"ok":1}'),
                 envelope('{"ok":true,"extra":1}'), envelope('{}'), {"choices": []}]
        for value in cases:
            with self.subTest(value=value):
                self.respond(value)
                with self.assertRaises(remote.RemoteAPIError):
                    self.call()

    def test_malformed_provider_envelopes_are_safe_errors(self):
        for value in ([], {"choices": ["bad"]}, {"choices": [{"finish_reason": "stop", "message": []}]}):
            self.respond(value)
            with self.subTest(value=value), self.assertRaises(remote.RemoteAPIError):
                self.call()

    def test_invalid_outer_json_and_large_response_rejected(self):
        for data in (b"not-json", b"x" * 2_000_001):
            self.respond(data, raw=True)
            with self.assertRaises(remote.RemoteAPIError):
                self.call()

    def test_128_call_budget_no_hidden_retry(self):
        model = remote.RemoteModel(config())
        for _ in range(128):
            self.call(model)
        self.assertEqual(self.opener.open.call_count, 128)
        with self.assertRaisesRegex(remote.RemoteAPIError, "128"):
            self.call(model)
        self.assertEqual(self.opener.open.call_count, 128)

    def test_oversized_request_fails_before_network(self):
        model = remote.RemoteModel(config(contextWindow=8192, maxOutputTokens=1024))
        with self.assertRaises(remote.RemoteAPIError):
            model.structured("s", "长" * 4000, SCHEMA)
        self.opener.open.assert_not_called()

    def test_close_clears_key(self):
        model = remote.RemoteModel(config())
        model.close()
        model.close()
        self.assertEqual(model.key, "")

    def test_finish_reason_and_usage_are_explicit_without_content_or_key_in_logs(self):
        value = envelope(finish="length")
        value["usage"] = {"prompt_tokens": 100, "completion_tokens": 4096,
                          "completion_tokens_details": {"reasoning_tokens": 4000}}
        self.respond(value)
        captured = io.StringIO()
        with patch.object(remote.sys, "stderr", captured), self.assertRaisesRegex(remote.RemoteAPIError, "finish_reason=length"):
            self.call()
        record = json.loads(captured.getvalue().split("API_METRICS ")[1])
        self.assertEqual(record["reasoning_tokens"], 4000)
        self.assertNotIn(FAKE_KEY, captured.getvalue())
        self.assertNotIn("合成文字", captured.getvalue())
        self.assertEqual(self.opener.open.call_count, 1)

    def test_truncated_response_checkpoint_survives_and_redacts_echoed_key(self):
        with tempfile.TemporaryDirectory() as directory:
            model = remote.RemoteModel(config())
            path = Path(directory) / "response.json"
            model.response_checkpoint_path = str(path)
            self.respond(envelope('{"partial":"' + FAKE_KEY, finish="length"))
            with self.assertRaisesRegex(remote.RemoteAPIError, "已保存"):
                self.call(model)
            saved = path.read_text()
            self.assertNotIn(FAKE_KEY, saved)
            self.assertIn("partial", saved)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_deepseek_focus_low_effort_only_and_bounded_timeout(self):
        model = remote.RemoteModel(config(baseURL="https://api.deepseek.com", approvedEndpoint="https://api.deepseek.com", thinkingMode="enabled"))
        self.call(model, api_task="focused-study")
        body = json.loads(self.opener.open.call_args.args[0].data)
        self.assertEqual(body["reasoning_effort"], "low")
        self.assertEqual(body["thinking"], {"type": "enabled"})
        self.assertEqual(self.opener.open.call_args.kwargs["timeout"], 300)
        self.call(api_task="focused-study")
        self.assertNotIn("reasoning_effort", json.loads(self.opener.open.call_args.args[0].data))

    def test_shape_subset_mixed_enum_types_and_bounds(self):
        for value in ("主线", None):
            remote.validate_shape(value, {"enum": ["主线", None]})
        for value, schema in ((True, {"type": "integer"}), (True, {"enum": [1]}),
                              (1, {"enum": [True]}), (3, {"type": "number", "maximum": 2}),
                              ([], {"type": "array", "minItems": 1}),
                              ("abc", {"type": "string", "maxLength": 2})):
            with self.assertRaises(remote.RemoteAPIError):
                remote.validate_shape(value, schema)

    def test_existing_stage_label_anyof_is_enforced(self):
        schema = {"anyOf": [{"type": "string", "minLength": 1, "maxLength": 20}, {"type": "null"}]}
        for value in ("有效标签", None):
            remote.validate_shape(value, schema)
        for value in (123, "", "长" * 21, []):
            with self.subTest(value=value), self.assertRaises(remote.RemoteAPIError):
                remote.validate_shape(value, schema)

    def test_nonfinite_json_numbers_are_rejected(self):
        for value in (float("inf"), float("-inf"), float("nan")):
            with self.assertRaises(remote.RemoteAPIError):
                remote.validate_shape(value, {"type": "number"})


class RemoteLoopbackProcessTests(unittest.TestCase):
    def test_real_probe_subprocess_text_only_without_local_model_import(self):
        requests = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                payload = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                requests.append((self.path, self.headers.get("Authorization"), json.loads(payload)))
                parsed = json.loads(payload)
                content = '{"ok":true}' if '请返回 {"ok":true}' in parsed["messages"][1]["content"] else json.dumps({
                    "sections": [{"heading": "报名", "explanation": "先报名，参加后完成评价。", "sourceKeys": [0]}], "gaps": []})
                body = json.dumps(envelope(content)).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix="knowledge-spine-api-loopback-") as temp:
                root = Path(temp)
                # Fail immediately if the actual CLI attempts any model import.
                # This synthetic startup hook reads no model or credential files.
                (root / "sitecustomize.py").write_text(
                    "import sys\n"
                    "class BlockModels:\n"
                    "    def find_spec(self, fullname, path=None, target=None):\n"
                    "        if fullname.split('.')[0] in ('llama_cpp', 'whisper', 'torch'):\n"
                    "            raise RuntimeError('API probe attempted a local model import')\n"
                    "sys.meta_path.insert(0, BlockModels())\n", encoding="utf-8")
                base = f"http://127.0.0.1:{server.server_port}/v1"
                manifest = root / "manifest.json"
                result = root / "result.json"
                manifest.write_text(json.dumps({"analysis_provider": "api", "api_configuration": config(
                    baseURL=base, approvedEndpoint=base, tokenLimitField="max_completion_tokens", thinkingMode="enabled"),
                    "structure_model_path": "/synthetic/missing.gguf",
                    "audio_paths": ["/synthetic/not-for-transmission.wav"]}), encoding="utf-8")
                env = {"KNOWLEDGE_SPINE_API_KEY": FAKE_KEY, "PYTHONPATH": str(root),
                       "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1",
                       "NO_PROXY": "127.0.0.1", "no_proxy": "127.0.0.1"}
                completed = subprocess.run([sys.executable, str(Path(pipeline.__file__).resolve()),
                                            "--api-probe", "--manifest", str(manifest), "--output", str(result)],
                                           env=env, capture_output=True, text=True, timeout=15)
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertEqual(json.loads(result.read_text()), {"ok": True})
                self.assertNotIn(FAKE_KEY, completed.stdout + completed.stderr)
                self.assertEqual(len(requests), 1)
                path, authorization, body = requests[0]
                self.assertEqual(path, "/v1/chat/completions")
                self.assertEqual(authorization, "Bearer " + FAKE_KEY)
                self.assertEqual(body["max_completion_tokens"], 256)
                self.assertEqual(body["thinking"], {"type": "disabled"})
                self.assertEqual(len(body["messages"]), 2)
                serialized = json.dumps(body)
                self.assertNotIn(".wav", serialized)
                self.assertNotIn(".gguf", serialized)
                self.assertNotIn(FAKE_KEY, serialized)
                # Exercise actual full manuscript CLI, not just the probe.
                prior = root / "input.json"
                prior.write_text(json.dumps({"speakers": [], "spans": [{
                    "id": "00000000-0000-4000-8000-000000000001", "sequence": 0,
                    "originalText": "先报名，参加后完成评价。", "startTime": 0, "endTime": 10}],
                    "warnings": []}))
                data = json.loads(manifest.read_text())
                data["focus_question"] = "活动如何报名？"
                manifest.write_text(json.dumps(data))
                command = [sys.executable, str(Path(pipeline.__file__).resolve()),
                           "--manifest", str(manifest), "--output", str(result), "--structure-from", str(prior)]
                generated = subprocess.run(command, env=env, capture_output=True, text=True, timeout=15)
                self.assertEqual(generated.returncode, 0, generated.stderr)
                self.assertEqual(len(requests), 2)  # one probe + one complete answer
                report = json.loads(result.read_text())["focusedReport"]
                self.assertEqual(report["sections"][0]["explanation"], "先报名，参加后完成评价。")
                self.assertTrue((root / "focused-study-api-checkpoint.json").is_file())
                replay = subprocess.run(command, env=env, capture_output=True, text=True, timeout=15)
                self.assertEqual(replay.returncode, 0, replay.stderr)
                self.assertEqual(len(requests), 2)  # cached result: no additional billing
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
