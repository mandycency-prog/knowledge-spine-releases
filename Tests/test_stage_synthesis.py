import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Backend"))
import source_bound_map as maps
from stage_synthesis import synthesize_overflow_stage
from test_source_bound_map import span


class StageSynthesisTest(unittest.TestCase):
    def fixture(self):
        units = maps._make_units([span(i, f"材料{i}提出方法及其适用条件，不能忽视相反情况。") for i in range(7)])
        group = {"members": list(range(len(units))), "core": [0], "conditions": [len(units)-1],
                 "label": "验证方法", "role": "执行动作"}
        return units, group

    @staticmethod
    def fits(llm, system, prompt, schema, reply):
        data = json.loads(prompt.split("输入：", 1)[1])
        return len(data.get("units", data.get("notes", []))) <= 2

    def test_reads_every_source_then_bounded_interpretation_merge(self):
        units, group = self.fixture()
        calls, read_keys = [], []
        def completion(llm, system, prompt, schema, **kwargs):
            self.assertTrue(self.fits(llm, system, prompt, schema, kwargs["max_tokens"]))
            data = json.loads(prompt.split("输入：", 1)[1]); calls.append(data)
            if "units" in data:
                read_keys.extend(record["key"] for record in data["units"])
            else:
                self.assertIn("notes不是原话", prompt)
                self.assertTrue(all("aiInterpretation" in note and "attribution" in note for note in data["notes"]))
            return {"navigationLabel": "验证条件", "summary": "验证方法时保留适用条件与例外。", "argumentSummary": "先看实际条件，再理解不同情况下的限制。"}
        with patch.object(maps, "_fits", self.fits):
            result = synthesize_overflow_stage(None, group, units, completion)
        self.assertEqual(read_keys, maps._stage_context_keys(group, units))
        self.assertLess(len(calls), len(units) * 2)
        self.assertEqual(result["navigationLabel"], "验证条件")

    def test_indivisible_unit_fails_before_any_call(self):
        units, group = self.fixture()
        with patch.object(maps, "_fits", return_value=False):
            with self.assertRaisesRegex(ValueError, "单个完整证据"):
                synthesize_overflow_stage(None, group, units, lambda *a, **k: self.fail("must preflight"))

    def test_bad_partial_does_not_publish_partial_map(self):
        units, group = self.fixture()
        with patch.object(maps, "_fits", self.fits):
            with self.assertRaisesRegex(ValueError, "字段不完整"):
                synthesize_overflow_stage(None, group, units, lambda *a, **k: {"summary": "missing fields"})


if __name__ == "__main__":
    unittest.main()
