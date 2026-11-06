import io
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Backend"))
from live_worker import serve
from apple_speech import AppleSpeechUnavailable


class WorkerProtocolTest(unittest.TestCase):
    def test_native_unavailable_falls_back_to_one_cached_whisper(self):
        loads, probes = [], []
        def load(*args, **kwargs):
            loads.append(1)
            return object()
        def native(manifest):
            probes.append(1)
            raise AppleSpeechUnavailable()
        requests = [{"whisper_model_path": "model", "apple_speech_path": "native", "audio_paths": [str(i)]} for i in range(3)]
        output = io.StringIO()
        serve(io.StringIO("\n".join(map(json.dumps, requests))), output, load,
              lambda *args, **kwargs: ([], [], "fallback"), native)
        results = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len(loads), 1)
        self.assertEqual(len(probes), 1)
        self.assertTrue(all(item["modelLoads"] == 1 for item in results))

    def test_native_does_not_load_whisper_and_context_resets_after_gap(self):
        seen = []
        def native(manifest):
            seen.append(dict(manifest))
            return [], [], "native"
        requests = [{"whisper_model_path": "model", "apple_speech_path": "native", "audio_paths": [str(i)],
                     "preview_time_offset": offset} for i, offset in enumerate([0, 15, 60])]
        serve(io.StringIO("\n".join(map(json.dumps, requests))), io.StringIO(),
              lambda *args, **kwargs: self.fail("Native path loaded Whisper"), lambda *args, **kwargs: self.fail(), native)
        self.assertEqual(seen[1]["preview_previous_audio_path"], "0")
        self.assertNotIn("preview_previous_audio_path", seen[2])

    def test_model_reused_and_failure_does_not_break_next_request(self):
        loaded = []
        def load(path, **kwargs):
            model = object()
            loaded.append(model)
            return model
        def transcribe(manifest, cached_model):
            self.assertIs(cached_model, loaded[-1])
            if manifest.get("fail"):
                raise ValueError("bad audio")
            return [], [], "preview"
        # Four hours worth of chunks, including a failed chunk.
        requests = [{"whisper_model_path": "model", "fail": i == 100} for i in range(960)]
        output = io.StringIO()
        serve(io.StringIO("\n".join(map(json.dumps, requests))), output, load, transcribe)
        results = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len(loaded), 1)
        self.assertEqual(len(results), 960)
        self.assertEqual(results[100]["error"], "bad audio")
        self.assertIn("spans", results[101])
        self.assertEqual(results[-1]["modelLoads"], 1)


if __name__ == "__main__":
    unittest.main()
