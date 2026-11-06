import copy
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Backend"))
import source_bound_map as maps


class BoundedBranchTest(unittest.TestCase):
    def fixture(self, count=8):
        spans = [{"id": str(uuid.uuid4()), "sequence": i, "startTime": i * 3, "endTime": i * 3 + 2,
                  "originalText": f"第{i}项说明实际行动，还需要保留相应限制。", "speakerID": "same-speaker"}
                 for i in range(count)]
        ids = [s["id"] for s in spans]
        units = maps._make_units(spans)
        nodes = [{"nodeID": "root", "navigationRoot": True, "parentID": None},
                 {"nodeID": "method", "parentID": "root", "kind": "主线", "sourceBoundStatus": "summarized",
                  "sourceSpanIDs": ids, "coveredSourceSpanIDs": ids, "navigationLabel": "按条件执行",
                  "summary": "按实际条件组织行动并检查结果。", "argumentSummary": "原方法完整描述保持不变。",
                  "conditionOriginals": [{"text": units[-1]["text"], "parts": units[-1]["parts"]}]}]
        return spans, nodes

    def fits(self, llm, system, prompt, schema, reply):
        data = json.loads(prompt.split("输入：", 1)[1])
        return len(data["units"]) <= 2 if "units" in data else len(data["notes"]) <= 4

    def complete(self, seen, merge_calls, malformed=False):
        def invoke(llm, system, prompt, schema, **kwargs):
            self.assertTrue(self.fits(llm, system, prompt, schema, kwargs["max_tokens"]))
            data = json.loads(prompt.split("输入：", 1)[1])
            if "units" in data:
                keys = [u["key"] for u in data["units"]]
                seen.extend(keys)
                return {"branches": [{"navigationLabel": f"具体行动{keys[0]}",
                    "summary": "根据原文确认实际条件，执行行动后继续检查结果是否适合。", "sourceKeys": [keys[0]]}]}
            self.assertIn("不是原话或独立核实的事实", prompt)
            self.assertTrue(all("aiInterpretation" in note and "sourceScopes" in note for note in data["notes"]))
            self.assertNotIn("sourceKeys", data["notes"][0])
            merge_calls.append(data)
            refs = list(range(len(data["notes"])))
            return {"branches": [{"navigationLabel": f"结合实际条件{len(merge_calls)}",
                "summary": "在实际条件允许的范围内行动，保留相关限制并检查结果，不作额外保证。",
                "members": refs[:-1] if malformed else refs}]}
        return invoke

    def test_all_raw_pages_read_protected_tail_and_union_preserved_without_rewriting_parent(self):
        spans, nodes = self.fixture(24)
        before = copy.deepcopy((spans, nodes))
        seen, merges = [], []
        with patch.object(maps, "_fits", side_effect=self.fits):
            result, warnings = maps.expand_method_branches(None, nodes, spans, self.complete(seen, merges))
        self.assertFalse(warnings)
        self.assertEqual(seen, list(range(24)))
        self.assertGreater(len(merges), 1)
        self.assertLessEqual(len(result) - 2, 5)
        self.assertEqual(result[:2], nodes)
        self.assertEqual((spans, nodes), before)
        evidence = {part["sourceID"] for child in result[2:] for quote in child["coreOriginals"] for part in quote["parts"]}
        expected = {spans[i]["id"] for i in range(0, 24, 2)} | {spans[-1]["id"]}
        self.assertEqual(evidence, expected)
        self.assertTrue(all(child["parentID"] == "method" for child in result[2:]))

    def test_missing_merge_member_cannot_publish_partial_children(self):
        spans, nodes = self.fixture()
        seen, merges = [], []
        with patch.object(maps, "_fits", side_effect=self.fits):
            result, warnings = maps.expand_method_branches(None, nodes, spans, self.complete(seen, merges, malformed=True))
        self.assertEqual(result, nodes)
        self.assertTrue(warnings)
        self.assertEqual(seen, list(range(8)))
        self.assertEqual(len(merges), 1)

    def test_invalid_chunk_source_cannot_be_laundered_by_merge(self):
        spans, nodes = self.fixture()
        calls = []
        def invalid(*args, **kwargs):
            calls.append(1)
            return {"branches": [{"navigationLabel": "具体行动", "summary": "根据实际条件行动，并保留必要限制和检查步骤。", "sourceKeys": [999]}]}
        with patch.object(maps, "_fits", side_effect=self.fits):
            result, warnings = maps.expand_method_branches(None, nodes, spans, invalid)
        self.assertEqual(result, nodes)
        self.assertTrue(warnings)
        self.assertEqual(len(calls), 1)


if __name__ == "__main__":
    unittest.main()
