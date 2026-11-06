import sys
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Backend"))
import local_pipeline as pipeline


class StreamingProgressTests(unittest.TestCase):
    def setUp(self):
        self.grammar = patch.dict(sys.modules, {"llama_cpp": SimpleNamespace(
            LlamaGrammar=SimpleNamespace(from_json_schema=lambda *a, **k: "grammar"))})
        self.grammar.start()
        self.addCleanup(self.grammar.stop)
        self.llm = Mock()
        self.llm.metadata = {"tokenizer.chat_template": "enable_thinking <think>"}

    def test_stream_reassembles_json_and_reports_only_count(self):
        self.llm.create_completion.return_value = iter([
            {"choices": [{"text": '{"secret":', "finish_reason": None}]},
            {"choices": [{"text": '"private"}', "finish_reason": None}]},
            {"choices": [{"text": "", "finish_reason": "stop"}]}])
        progress = Mock()
        with patch.object(pipeline.time, "monotonic", side_effect=[0, 11, 12, 23]):
            result = pipeline.structured_completion(self.llm, "system", "user", {}, progress_callback=progress)
        self.assertEqual(result, {"secret": "private"})
        self.assertTrue(self.llm.create_completion.call_args.kwargs["stream"])
        self.assertEqual(progress.call_count, 2)
        self.assertNotIn("private", str(progress.call_args_list))
        self.assertNotIn("secret", str(progress.call_args_list))
        self.assertNotIn("progress_callback", self.llm.create_completion.call_args.kwargs)

    def test_length_rejected_even_if_json_parses(self):
        self.llm.create_completion.return_value = iter([
            {"choices": [{"text": '{}', "finish_reason": "length"}]}])
        with self.assertRaisesRegex(ValueError, "截断"):
            pipeline.structured_completion(self.llm, "s", "u", {}, progress_callback=lambda _: None)

    def test_stream_missing_finish_event_is_rejected(self):
        self.llm.create_completion.return_value = iter([
            {"choices": [{"text": '{}', "finish_reason": None}]}])
        with self.assertRaisesRegex(ValueError, "意外结束"):
            pipeline.structured_completion(self.llm, "s", "u", {}, progress_callback=lambda _: None)

    def test_without_callback_remains_nonstreaming(self):
        self.llm.create_completion.return_value = {"choices": [{"text": '{}', "finish_reason": "stop"}]}
        self.assertEqual(pipeline.structured_completion(self.llm, "s", "u", {}), {})
        self.assertNotIn("stream", self.llm.create_completion.call_args.kwargs)

    def test_thinking_path_ignores_callback_without_changing_calls(self):
        self.llm.create_completion.side_effect = [
            {"choices": [{"text": "核对", "finish_reason": "stop"}]},
            {"choices": [{"text": '{}', "finish_reason": "stop"}]}]
        progress = Mock()
        self.assertEqual(pipeline.structured_completion(self.llm, "s", "u", {}, thinking=True,
                                                       progress_callback=progress), {})
        self.assertEqual(self.llm.create_completion.call_count, 2)
        progress.assert_not_called()
        for call in self.llm.create_completion.call_args_list:
            self.assertNotIn("stream", call.kwargs)
            self.assertNotIn("progress_callback", call.kwargs)


if __name__ == "__main__":
    unittest.main()
