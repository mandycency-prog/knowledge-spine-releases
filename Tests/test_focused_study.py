import copy
import json
from pathlib import Path
import sys
import unittest
import uuid
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Backend"))
import focused_study as study


def span(i, text="参加活动须先报名。"):
    return {"id": str(uuid.uuid4()), "sequence": i, "startTime": i * 2,
            "endTime": i * 2 + 1, "originalText": text, "isBackgroundAudio": True}


def plan(key=0, name="如何报名？"):
    return {"heading": name, "subquestion": name, "sourceKeys": [key]}


class FocusedStudyTests(unittest.TestCase):
    def generate(self, llm, source, question, model):
        # Existing retrieval/validation cases use a transparent final editor;
        # editor repair and rejection behavior is covered separately below.
        def completion(llm, system, prompt, schema, **kwargs):
            if "answers" in schema["properties"]:
                drafts = json.loads(prompt.split("输入：", 1)[1])["drafts"]
                return {"answers": [{k: v for k, v in d.items() if k != "subquestion"} for d in drafts]}
            return model(llm, system, prompt, schema, **kwargs)
        return study.generate(llm, source, question, completion)

    def test_complete_reading_independent_answers_source_unchanged(self):
        source = [span(i, f"第{i}项原文") for i in range(10)]
        before = copy.deepcopy(source)
        model = Mock(side_effect=[{"questions": [plan(0), plan(9, "如何认证？")]},
                                  {"explanation": "报名条件。", "sourceKeys": [0]},
                                  {"explanation": "认证条件。", "sourceKeys": [9]}])
        report = self.generate(None, source, "报名和认证", model)
        self.assertEqual(source, before)
        self.assertEqual(len(report["sections"]), 2)
        first = model.call_args_list[0].args[2]
        for s in source:
            self.assertIn(s["originalText"], first)
        self.assertNotIn("第9项原文", model.call_args_list[1].args[2])
        self.assertNotIn("第0项原文", model.call_args_list[2].args[2])
        self.assertEqual(report["sections"][1]["sourceSpanIDs"], [source[9]["id"]])
        self.assertEqual([c.kwargs["reasoning_tokens"] for c in model.call_args_list], [512, 512, 512])
        self.assertEqual([c.kwargs["max_tokens"] for c in model.call_args_list], [1800, 1536, 1536])

    def test_neighbors_four_each_side_and_disjoint_regions_marked(self):
        source = [span(i) for i in range(20)]
        selected = plan(2)
        selected["sourceKeys"] = [2, 17]
        model = Mock(side_effect=[{"questions": [selected]}, {"explanation": "条件", "sourceKeys": [0, 19]}])
        self.generate(None, source, "条件", model)
        prompt = model.call_args.args[2]
        self.assertIn("[0]", prompt)
        self.assertIn("[19]", prompt)
        self.assertIn("不与上一段直接相接", prompt)
        self.assertNotIn("[9]", prompt)

    def test_capture_chunks_do_not_interrupt_words_or_self_corrections(self):
        records = study._records([span(0, "需要志"), span(1, "愿服务。不过新生例外。")])
        text = study._passages(records)
        self.assertIn("需要志愿服务。不过新生例外。", text)
        self.assertIn("[0][1]", text)
        records[1]["speakerKey"] = "other"
        separated = study._passages(records)
        self.assertIn("不与上一段直接相接", separated)
        self.assertNotIn("需要志愿服务", separated)

    def test_invalid_and_cross_context_ids_rejected(self):
        source = [span(i) for i in range(10)]
        for keys in ([99], [True], [0, 0], [9]):
            model = Mock(side_effect=[{"questions": [plan(0)]}, {"explanation": "条件", "sourceKeys": keys}])
            with self.assertRaisesRegex(ValueError, "原文"):
                self.generate(None, source, "条件", model)

    def test_later_failure_returns_no_partial_report(self):
        source = [span(i) for i in range(10)]
        model = Mock(side_effect=[{"questions": [plan(0), plan(9, "另一问")]},
                                 {"explanation": "已完成一节", "sourceKeys": [0]}, ValueError("原生失败")])
        with self.assertRaisesRegex(ValueError, "原生失败"):
            self.generate(None, source, "条件", model)

    def test_more_than_twelve_short_sources_preserved_within_token_budget(self):
        source = [span(i, f"条件{i}") for i in range(20)]
        selected = plan()
        selected["sourceKeys"] = list(range(20))
        model = Mock(side_effect=[{"questions": [selected]},
                                  {"explanation": "完整条件", "sourceKeys": list(range(20))}])
        report = self.generate(None, source, "全部条件", model)
        self.assertEqual(report["sections"][0]["sourceSpanIDs"], [s["id"] for s in source])
        for s in source:
            self.assertIn(s["originalText"], model.call_args.args[2])

    def test_no_evidence_and_missing_answer_are_explicit(self):
        report = self.generate(None, [span(0)], "退货", Mock(return_value={"questions": []}))
        self.assertFalse(report["sections"])
        self.assertIn("未找到", report["gaps"][0])
        model = Mock(side_effect=[{"questions": [plan()]}, {"explanation": "", "sourceKeys": []}])
        report = self.generate(None, [span(0)], "退货", model)
        self.assertFalse(report["sections"])
        self.assertIn("不足以", report["gaps"][0])

    def test_multiple_pages_not_silently_dropped(self):
        source = [span(i) for i in range(8)]
        records = study._records(source)
        model = Mock(side_effect=[{"questions": [plan(i, f"问题{i}") for i in range(4)]},
                                 {"questions": [plan(i, f"问题{i}") for i in range(4, 8)]}])
        with patch.object(study, "_plan_pages", return_value=[records[:4], records[4:]]):
            with self.assertRaisesRegex(ValueError, "超过6项"):
                self.generate(None, source, "条件", model)
        self.assertEqual(model.call_count, 2)

    def test_identical_question_merge_preserves_both_sources(self):
        source = [span(i) for i in range(2)]
        records = study._records(source)
        model = Mock(side_effect=[{"questions": [plan(0)]}, {"questions": [plan(1)]},
                                 {"explanation": "综合条件", "sourceKeys": [0, 1]}])
        with patch.object(study, "_plan_pages", return_value=[[records[0]], [records[1]]]):
            report = self.generate(None, source, "条件", model)
        self.assertEqual(len(report["sections"]), 1)
        self.assertEqual(report["sections"][0]["sourceSpanIDs"], [s["id"] for s in source])

    def test_budget_preflight_failure_never_truncates(self):
        model = Mock()
        with patch.object(study, "_fits", return_value=False):
            with self.assertRaisesRegex(ValueError, "未截断"):
                self.generate(None, [span(0)], "问题", model)
        model.assert_not_called()
        model = Mock(return_value={"questions": [plan()]})
        with patch.object(study, "_plan_pages", return_value=[study._records([span(0)])]), patch.object(study, "_fits", return_value=False):
            with self.assertRaisesRegex(ValueError, "完整证据"):
                self.generate(None, [span(0)], "问题", model)
        self.assertEqual(model.call_count, 1)

    def test_manual_text_reading_aid_and_compact_preserve_raw(self):
        a, b = span(0, "原始错词"), span(1, "其他原文")
        a.update(isBackgroundAudio=False, proofreadingVersion="context-v1", proofreadBasis="原始错词",
                 proofreadText="建议改词", proofreadUncertainties=["待核实"])
        b["correctedText"] = "人工修正"
        records = study._records([a, b])
        self.assertEqual(records[0]["text"], "原始错词")
        self.assertEqual(records[0]["readingAid"], "建议改词")
        compact = study._compact(records)
        self.assertIn("人工修正", compact)
        self.assertNotIn("其他原文", compact)
        self.assertEqual(compact.count("说话人="), 1)

    def test_recovery_only_rebuilds_once(self):
        llm = Mock(spec=["recover_after_decode_failure"])
        llm.recover_after_decode_failure.return_value = True
        model = Mock(side_effect=[RuntimeError("llama_decode returned -3"), {"questions": []}])
        self.generate(llm, [span(0)], "问题", model)
        llm.recover_after_decode_failure.assert_called_once()
        self.assertEqual(model.call_count, 2)
        model = Mock(side_effect=RuntimeError("llama_decode returned -3"))
        with self.assertRaises(RuntimeError):
            self.generate(llm, [span(0)], "问题", model)
        self.assertEqual(model.call_count, 2)

    def test_question_bound(self):
        for question in (None, "", " " * 2, "长" * 601):
            with self.assertRaises(ValueError):
                study.generate(None, [span(0)], question, Mock())

    def test_final_editor_repair_is_used_and_receives_canonical_evidence(self):
        source = [span(0, "会员三十天。")]
        model = Mock(side_effect=[{"questions": [plan()]},
                                 {"explanation": "会员七天。", "sourceKeys": [0]},
                                 {"answers": [{"index": 0, "explanation": "会员三十天。", "sourceKeys": [0]}]}])
        report = study.generate(None, source, "期限", model)
        self.assertEqual(report["sections"][0]["explanation"], "会员三十天。")
        self.assertIn(source[0]["originalText"], model.call_args.args[2])
        self.assertEqual(model.call_count, 3)

    def test_final_editor_omission_foreign_source_and_failure_never_publish(self):
        for answer in ({"answers": []},
                       {"answers": [{"index": 0, "explanation": "条件", "sourceKeys": [999]}]},
                       {"answers": [{"index": True, "explanation": "条件", "sourceKeys": [0]}]},
                       ValueError("核对失败")):
            model = Mock(side_effect=[{"questions": [plan()]},
                                     {"explanation": "草稿", "sourceKeys": [0]}, answer])
            with self.assertRaises(ValueError):
                study.generate(None, [span(0)], "条件", model)


if __name__ == "__main__":
    unittest.main()
