import copy
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Backend"))
import local_pipeline as pipeline
from quote_test_support import quote_response


class SingleThemeTest(unittest.TestCase):
    def test_verified_single_theme_survives_rejected_center_without_sentence_expansion(self):
        candidates = [
            {"sourceSpanIDs": ["source-a"], "summary": "一次只改变一个关键因素", "sourceText": "一次只改变一个关键因素，才能知道改变的效果。", "confidence": 0.8},
            {"sourceSpanIDs": ["source-b"], "summary": "保留没有改变方法的对照", "sourceText": "保留没有改变方法的对照，帮助排除题目难度的影响。", "confidence": 0.8},
        ]
        original = copy.deepcopy(candidates)
        response = {"center": {"summary": "", "evidenceIndex": 999}, "stages": [{
            "summary": "改变方法的效果", "argumentSummary": "", "memberIndices": [0, 1],
            "evidenceIndex": 0, "relationToPrevious": "给出方法"}]}
        def model(llm, system, prompt, schema, **kwargs):
            if set(schema["properties"]) == {"assignments"}:
                return {"assignments": {"0": 0, "1": 0}}
            if "evidence" in schema["properties"] or "verdict" in schema["properties"]:
                return quote_response(prompt, schema)
            return response
        with patch.object(pipeline, "structured_completion", side_effect=model):
            nodes = pipeline.consolidate_thematic_mind_map(None, candidates)
        self.assertEqual(candidates, original)
        self.assertEqual(len(nodes), 1)
        self.assertEqual(nodes[0]["summary"], "改变方法的效果")
        self.assertIsNone(nodes[0]["parentID"])
        self.assertEqual(nodes[0]["sourceSpanIDs"], ["source-a"])

    @unittest.skipUnless(sys.platform == "darwin", "Uses the built-in macOS transform")
    def test_script_variants_are_not_false_source_failures(self):
        original = "重複檢驗並計算維護成本，觀察學習時間是否減少了20分鐘。"
        self.assertTrue(pipeline.summary_is_lexically_grounded("重复检验并计算维护成本", original, 1.0))
        self.assertTrue(pipeline.summary_numbers_are_grounded("减少了20分钟", original))
        self.assertFalse(pipeline.summary_numbers_are_grounded("减少了30分钟", original))
        self.assertFalse(pipeline.summary_is_lexically_grounded("火星上发现了生命", original))
        self.assertEqual(original, "重複檢驗並計算維護成本，觀察學習時間是否減少了20分鐘。")
