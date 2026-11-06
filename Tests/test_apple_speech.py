import json
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Backend"))
from apple_speech import AppleSpeechUnavailable, native_groups, transcribe_native
from audio_context import RATE, owned_segments


class AppleSpeechTest(unittest.TestCase):
    def test_grouping_keeps_every_recognized_character(self):
        words = [{"word": text, "start": index, "end": index + 0.8}
                 for index, text in enumerate("这是不可以丢失的原话" * 5)]
        event = {"text": "".join(word["word"] for word in words), "words": words}
        groups = list(native_groups(event))
        self.assertGreater(len(groups), 1)
        self.assertEqual("".join(group["text"] for group in groups), event["text"])

    def test_missing_word_attributes_do_not_remove_punctuation_or_text(self):
        event = {"text": "原话，123。", "start": 0, "end": 2,
                 "words": [{"word": "原话", "start": 0, "end": 1}]}
        groups = list(native_groups(event))
        self.assertNotIn("words", groups[0])
        result = list(owned_segments({"segments": groups}, 0, 0, 2, [("a", 0, 2)]))
        self.assertEqual(result[0]["text"], event["text"])

    def run_protocol(self, events, code=0):
        def decode(paths, ffmpeg, locations):
            locations.append(("a", 0, 2))
            yield np.zeros(RATE * 2, dtype=np.float32)
        def run(args, **kwargs):
            if "--probe" in args:
                return subprocess.CompletedProcess(args, 0, json.dumps({"available": True, "installedChinese": True}))
            kwargs["stdout"].write("".join(json.dumps(event) + "\n" for event in events).encode())
            return subprocess.CompletedProcess(args, code)
        with patch("apple_speech.os.access", return_value=True), patch("apple_speech.subprocess.run", side_effect=run), patch("apple_speech.decoded_blocks", side_effect=decode):
            return transcribe_native({"apple_speech_path": "native", "audio_paths": ["a"], "ffmpeg_path": "ffmpeg"})

    @staticmethod
    def valid_events():
        return [{"event": "fileStarted"}, {"event": "segment", "text": "数字123", "start": 0, "end": 1},
                {"event": "fileComplete", "segmentCount": 1},
                {"event": "complete", "fileCount": 1, "segmentCount": 1}]

    def test_success_keeps_raw_and_adds_only_separate_punctuation(self):
        result = self.run_protocol(self.valid_events())
        self.assertEqual(result[0]["text"], "数字123")
        self.assertEqual(result[0]["punctuated_text"], "数字123。")

    def test_artificial_index_cut_does_not_put_a_comma_inside_a_word(self):
        events = [{"event": "segment", "text": "教", "start": 0, "end": 1},
                  {"event": "segment", "text": "材", "start": 1, "end": 2},
                  {"event": "fileComplete", "segmentCount": 2},
                  {"event": "complete", "fileCount": 1, "segmentCount": 2}]
        result = self.run_protocol(events)
        self.assertNotIn("punctuated_text", result[0])
        self.assertEqual(result[1]["punctuated_text"], "材。")

    def test_partial_failed_inconsistent_or_extra_output_is_rejected(self):
        cases = [self.valid_events()[:-1], self.valid_events()[1:2],
                 self.valid_events() + [{"event": "error", "error": "late error"}],
                 [{"event": "error", "error": "early error"}] + self.valid_events()]
        mismatch = self.valid_events()
        mismatch[-2]["segmentCount"] = 2
        cases.append(mismatch)
        for events in cases:
            with self.subTest(events=events), self.assertRaises(ValueError):
                self.run_protocol(events)
        with self.assertRaises(ValueError):
            self.run_protocol(self.valid_events(), 1)

    def test_probe_errors_allow_existing_local_fallback(self):
        for error in [OSError("missing"), subprocess.TimeoutExpired("native", 45)]:
            with patch("apple_speech.os.access", return_value=True), patch("apple_speech.subprocess.run", side_effect=error):
                with self.assertRaises(AppleSpeechUnavailable):
                    transcribe_native({"apple_speech_path": "native"})


if __name__ == "__main__":
    unittest.main()
