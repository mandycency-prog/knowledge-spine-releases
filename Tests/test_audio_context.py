import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Backend"))
from audio_context import RATE, context_windows, owned_segments
import local_pipeline as pipeline


class AudioContextTests(unittest.TestCase):
    def test_four_hours_bounded_windows_and_complete_ownership(self):
        count, previous = 0, 0
        for audio, origin, start, end in context_windows(np.zeros(RATE * 10, dtype=np.float32) for _ in range(1440)):
            self.assertEqual(start, previous)
            self.assertLessEqual(audio.nbytes, 100 * RATE * 4)
            self.assertLessEqual(start - origin, 5)
            previous, count = end, count + 1
        self.assertEqual(previous, 4 * 3600)
        self.assertEqual(count, 160)

    def test_file_boundaries_do_not_become_recognition_boundaries(self):
        windows = list(context_windows(np.ones(15 * RATE, dtype=np.float32) * i for i in range(7)))
        audio, origin, start, end = windows[0]
        self.assertEqual((origin, start, end), (0, 0, 90))
        self.assertEqual(len(audio), 95 * RATE)
        self.assertEqual(audio[90 * RATE], 6)
        self.assertEqual(windows[-1][2:], (90, 105))
        # A phrase split across the old 15-second files is now heard together.
        self.assertEqual(audio[45 * RATE - 1], 2)
        self.assertEqual(audio[45 * RATE], 3)

    def test_overlap_words_belong_to_exactly_one_window(self):
        words = [{"word": "维护", "start": 89, "end": 89.4},
                 {"word": "成本", "start": 89.8, "end": 90.4},
                 {"word": "一起计算。", "start": 90.5, "end": 91.3}]
        first = {"segments": [{"words": words}]}
        second = {"segments": [{"words": [{**word, "start": word["start"] - 85, "end": word["end"] - 85} for word in words]}]}
        locations = [("recording", 0, 105)]
        output = list(owned_segments(first, 0, 0, 90, locations)) + list(owned_segments(second, 85, 90, 105, locations))
        self.assertEqual("".join(item["text"] for item in output), "维护成本一起计算。")
        self.assertTrue(all(item["end"] > item["start"] for item in output))

    def test_continuous_checkpoint_resumes_without_reloading_committed_window(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("model", "audio"):
                (root / name).write_bytes(b"test")
            manifest = {"whisper_model_path": str(root / "model"), "audio_paths": [str(root / "audio")],
                        "ffmpeg_path": "unused", "asr_checkpoint_path": str(root / "checkpoint.json")}
            fail, calls = [True], []
            def decode(paths, ffmpeg, locations):
                locations.append((paths[0], 0, 200))
                for index in range(20):
                    if index == 10 and fail[0]:
                        raise ValueError("interrupted decoder")
                    yield np.zeros(10 * RATE, dtype=np.float32)
            def recognize(audio, **kwargs):
                calls.append(len(audio))
                return {"segments": [{"start": 6, "end": 7, "text": "有效原话"}]}
            fake = types.SimpleNamespace(load_model=lambda *args, **kwargs: types.SimpleNamespace(transcribe=recognize))
            with patch.dict(sys.modules, {"whisper": fake}), patch.object(pipeline, "decoded_blocks", side_effect=decode), \
                    patch.object(pipeline, "cluster_speakers", side_effect=lambda spans: ([0] * len(spans), "test")):
                with self.assertRaises(ValueError):
                    pipeline.transcribe(manifest)
                fail[0] = False
                _, spans, _ = pipeline.transcribe(manifest)
                self.assertEqual(len(calls), 3)
                self.assertEqual(len(spans), 3)
                self.assertEqual([item["startTime"] for item in spans], [6, 91, 181])


if __name__ == "__main__":
    unittest.main()
