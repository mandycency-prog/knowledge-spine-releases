import sys
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Backend"))
import local_pipeline as pipeline


class FakeModel:
    metadata = {"tokenizer.chat_template": "enable_thinking <think>"}
    def __init__(self, reasoning, answer=None):
        self.reasoning = reasoning
        self.answer = [201, 999] if answer is None else answer
        self.calls, self.counts, self.closed = [], [], []

    def n_ctx(self):
        return 12288

    def token_eos(self):
        return 999

    def tokenize(self, text, add_bos=True, special=False):
        if text in (b"<|im_end|>", b"<|endoftext|>"):
            return [999]
        if text == b"\n</think>\n\n":
            return [102, 103]
        if text == b"\n\n":
            return [103]
        return [10, 11, 12]

    def detokenize(self, tokens, special=False):
        return "".join({101: "秘密草稿", 102: "</think>", 103: "\n\n", 201: '{"points":[]}',
                        202: '{"points":', 999: ""}.get(t, "思") for t in tokens).encode()

    def generate(self, tokens, **kwargs):
        index = len(self.calls)
        self.calls.append((list(tokens), kwargs))
        self.counts.append(0)
        stream = self.reasoning if index == 0 else self.answer
        try:
            for token in stream:
                self.counts[index] += 1
                yield token
        finally:
            self.closed.append(index)


class ReasonedJSONTests(unittest.TestCase):
    def setUp(self):
        self.grammar = Mock()
        p = patch.dict(sys.modules, {"llama_cpp": SimpleNamespace(LlamaGrammar=self.grammar)})
        p.start()
        self.addCleanup(p.stop)

    def run_model(self, model, **kwargs):
        return pipeline.structured_completion(model, "s", "u", {"type": "object"},
                                               reasoned_json=True, max_tokens=520, **kwargs)

    def test_natural_close_continues_only_pending_token_not_full_prompt(self):
        model = FakeModel([101, 102])
        self.assertEqual(self.run_model(model), {"points": []})
        self.assertEqual(len(model.calls), 2)
        self.assertEqual(model.calls[0][0], [10, 11, 12])
        self.assertTrue(model.calls[0][1]["reset"])
        self.assertNotIn("grammar", model.calls[0][1])
        self.assertEqual(model.calls[1][0], [102, 103])
        self.assertFalse(model.calls[1][1]["reset"])
        self.assertIn("grammar", model.calls[1][1])
        self.assertEqual(model.closed, [0, 1])

    def test_reasoning_hard_cap_forces_close_without_replaying_reasoning(self):
        model = FakeModel([101] * 1000)
        self.assertEqual(self.run_model(model), {"points": []})
        self.assertEqual(model.counts[0], 512)
        self.assertEqual(model.calls[1][0], [101, 102, 103])
        self.assertNotIn("max_tokens", model.calls[1][1])

    def test_custom_reasoning_budget_is_hard_and_not_forwarded(self):
        model = FakeModel([101] * 1000)
        self.assertEqual(self.run_model(model, reasoning_tokens=256), {"points": []})
        self.assertEqual(model.counts[0], 256)
        self.assertNotIn("reasoning_tokens", model.calls[0][1])
        for budget in (0, 513, True):
            with self.assertRaises(ValueError):
                self.run_model(FakeModel([102]), reasoning_tokens=budget)

    def test_answer_budget_exhaustion_rejects_even_complete_json(self):
        model = FakeModel([102], [201] + [103] * 100)
        with self.assertRaisesRegex(ValueError, "截断"):
            self.run_model(model)
        self.assertEqual(model.counts[1], 8)

    def test_early_eos_and_unexpected_generator_end_rejected(self):
        for reasoning in ([999], []):
            with self.assertRaises(ValueError):
                self.run_model(FakeModel(reasoning))
        with self.assertRaises(ValueError):
            self.run_model(FakeModel([102], [202]))

    def test_progress_exposes_counts_not_reasoning(self):
        progress = Mock()
        with patch.object(pipeline.time, "monotonic", side_effect=[0, 11, 12, 24]):
            self.run_model(FakeModel([101, 102]), progress_callback=progress)
        self.assertGreaterEqual(progress.call_count, 2)
        self.assertNotIn("秘密草稿", str(progress.call_args_list))

    def test_non_qwen_path_remains_unchanged(self):
        model = Mock()
        model.metadata = {}
        model.create_chat_completion.return_value = {"choices": [{"message": {"content": "{}"}, "finish_reason": "stop"}]}
        self.assertEqual(self.run_model(model), {})
        self.assertNotIn("reasoned_json", model.create_chat_completion.call_args.kwargs)
        model.generate.assert_not_called()


if __name__ == "__main__":
    unittest.main()
