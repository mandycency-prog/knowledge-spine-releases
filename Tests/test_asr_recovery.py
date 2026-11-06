import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Backend"))
import local_pipeline as pipeline


class ASRRecovery(unittest.TestCase):
    def test_retry_skips_committed_audio_and_resets_when_input_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("model", "one", "two"):
                (root / name).write_bytes(b"fixture")
            manifest = {"audio_paths": [str(root / "one"), str(root / "two")], "whisper_model_path": str(root / "model"),
                        "ffmpeg_path": "/unused/ffmpeg", "asr_checkpoint_path": str(root / "checkpoint.json"), "asr_window_mode": "legacy"}
            reads, calls = [], []
            fail = [True]
            def load_audio(path):
                reads.append(Path(path).name)
                if Path(path).name == "two" and fail[0]:
                    raise ValueError("injected decoding interruption")
                return [0] * 16000
            def transcribe(audio, **kwargs):
                calls.append(1)
                return {"segments": [{"start": 0, "end": 1, "text": "这是正常课程解释。"}]}
            whisper = types.SimpleNamespace(load_model=lambda *args, **kwargs: types.SimpleNamespace(transcribe=transcribe),
                                            load_audio=load_audio, audio=types.SimpleNamespace(SAMPLE_RATE=16000))
            with patch.dict(sys.modules, {"whisper": whisper}), patch.object(pipeline, "cluster_speakers", side_effect=lambda spans: ([0] * len(spans), "test")):
                with self.assertRaises(ValueError):
                    pipeline.transcribe(manifest)
                fail[0] = False
                _, spans, _ = pipeline.transcribe(manifest)
                self.assertEqual(reads, ["one", "two", "two"])
                self.assertEqual(len(calls), 2)
                self.assertEqual([span["startTime"] for span in spans], [0, 1])
                (root / "one").write_bytes(b"changed input")
                pipeline.transcribe(manifest)
                self.assertEqual(reads[-2:], ["one", "two"])


if __name__ == "__main__":
    unittest.main()
