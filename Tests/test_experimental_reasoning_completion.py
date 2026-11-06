import unittest
from experimental_reasoning_completion import EndThinking, THINKING_SAMPLING, reasoning_completion


class FakeLLM:
    metadata = {"tokenizer.chat_template": "enable_thinking <think>"}
    last_n_tokens_size = 64

    def __init__(self, responses, context=8192):
        self.responses, self.calls, self.context = list(responses), [], context

    def n_ctx(self):
        return self.context

    def tokenize(self, text, add_bos=True, special=False):
        # Deliberately count every UTF-8 byte to make oversize tests strict.
        return ([256] if add_bos else []) + list(text)

    def create_completion(self, **kwargs):
        self.calls.append(kwargs)
        return {"choices": [self.responses.pop(0)]}


class NativeThinkingExperimentTest(unittest.TestCase):
    schema = {"type": "object", "properties": {"verdict": {"type": "string"}}, "required": ["verdict"]}

    def run_fake(self, llm, **kwargs):
        return reasoning_completion(llm, "保留原文条件", "原文：必须满足条件。", self.schema,
                                    grammar_factory=lambda schema: "fake-grammar", **kwargs)

    def test_complete_reasoning_stays_in_same_assistant_and_final_gets_grammar(self):
        thinking = "先核对主体和条件，不能额外加前提。\n</think>"
        llm = FakeLLM([{"text": thinking, "finish_reason": "stop"},
                       {"text": '{"verdict":"unknown"}', "finish_reason": "stop"}])
        report = self.run_fake(llm)
        self.assertEqual(report["status"], "completed")
        self.assertEqual(report["value"], {"verdict": "unknown"})
        self.assertEqual(len(llm.calls), 2)
        first, final = report["calls"]
        self.assertEqual(final["prompt"], first["prompt"] + thinking + "\n\n")
        self.assertEqual(final["prompt"].count("<|im_start|>user"), 1)
        self.assertEqual(final["prompt"].count("<|im_start|>assistant"), 1)
        self.assertNotIn("grammar", llm.calls[0])
        self.assertEqual(llm.calls[0]["stop"], [])
        self.assertEqual(llm.calls[1]["grammar"], "fake-grammar")
        self.assertEqual(report["penaltyHistoryTokens"], 64)
        for call in llm.calls:
            for key, value in THINKING_SAMPLING.items():
                self.assertEqual(call[key], value)
            self.assertEqual(call["seed"], 20260911)
            self.assertLessEqual(len(call["prompt"]) + call["max_tokens"] + 512, 8192)

    def test_stop_criterion_ignores_prompt_delimiter_and_keeps_generated_closure(self):
        stop = EndThinking(4, [10, 11])
        self.assertFalse(stop([0, 1, 10, 11], None))
        self.assertFalse(stop([0, 1, 10, 11, 12, 10], None))
        self.assertTrue(stop([0, 1, 10, 11, 12, 10, 11], None))
        self.assertTrue(stop([0], None))

    def test_missing_closure_never_forces_json_or_invents_think_end(self):
        for finish in ("length", "stop"):
            llm = FakeLLM([{"text": "仍在核对条件", "finish_reason": finish}])
            report = self.run_fake(llm)
            self.assertEqual(report["status"], "budget_exhausted")
            self.assertIsNone(report["value"])
            self.assertEqual(report["thinkingText"], "仍在核对条件")
            self.assertEqual(len(llm.calls), 1)

    def test_source_over_budget_is_not_truncated_and_makes_no_call(self):
        llm = FakeLLM([])
        report = reasoning_completion(llm, "系统", "原文" * 2000, self.schema)
        self.assertEqual(report["status"], "context_budget_exhausted")
        self.assertEqual(llm.calls, [])

    def test_second_stage_rechecks_actual_complete_reasoning_capacity(self):
        # A deliberately noncompliant fake overproduces: the driver must still
        # refuse rather than truncate that reasoning to manufacture capacity.
        thinking = "x" * 7300 + "</think>"
        llm = FakeLLM([{"text": thinking, "finish_reason": "stop"}])
        report = self.run_fake(llm)
        self.assertEqual(report["status"], "context_budget_exhausted")
        self.assertEqual(report["stage"], "final")
        self.assertEqual(report["thinkingText"], thinking)
        self.assertEqual(len(llm.calls), 1)

    def test_final_budget_or_invalid_json_is_not_a_completed_answer(self):
        for text, finish, status in (("{}", "length", "budget_exhausted"),
                                      ("不是JSON", "stop", "protocol_error"),
                                      ("[]", "stop", "protocol_error")):
            llm = FakeLLM([{"text": "核对完毕</think>", "finish_reason": "stop"},
                           {"text": text, "finish_reason": finish}])
            report = self.run_fake(llm)
            self.assertEqual(report["status"], status)
            self.assertIsNone(report["value"])

    def test_unexpected_answer_after_closure_is_not_silently_discarded(self):
        llm = FakeLLM([{"text": "完毕</think>偷偷生成答案", "finish_reason": "stop"}])
        self.assertEqual(self.run_fake(llm)["status"], "protocol_error")
        self.assertEqual(len(llm.calls), 1)

    def test_runtime_without_parameter_support_or_wrong_template_is_rejected(self):
        class OldRuntime(FakeLLM):
            def create_completion(self, prompt):
                self.fail("must reject unsupported runtime")
        with self.assertRaisesRegex(ValueError, "support"):
            self.run_fake(OldRuntime([]))
        wrong = FakeLLM([])
        wrong.metadata = {}
        with self.assertRaisesRegex(ValueError, "template"):
            self.run_fake(wrong)

    def test_configuration_cannot_increase_thinking_budget_or_shrink_margin(self):
        for kwargs in ({"thinking_budget": 3073}, {"thinking_budget": True}, {"margin": 100}, {"seed": True}):
            with self.assertRaises(ValueError):
                self.run_fake(FakeLLM([]), **kwargs)


if __name__ == "__main__":
    unittest.main()
