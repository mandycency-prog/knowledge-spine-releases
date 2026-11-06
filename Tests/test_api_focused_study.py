"""Behavioral regression: one complete API answer, evidence and recovery."""
import copy
import json
from pathlib import Path
from types import SimpleNamespace
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Backend"))
import focused_study as study
import remote_model as remote


def sources():
    return [{"id": str(uuid.uuid4()), "sequence": i, "originalText": text,
             "startTime": i * 10, "endTime": i * 10 + 10, "isBackgroundAudio": True}
            for i, text in enumerate(["活动先报名。", "参加后须评价才能计学分。", "新生本学期二十小时。"])]


def answer():
    return {"sections": [{"heading": "报名与认定", "explanation": "先报名，参加活动后完成评价才能计学分。", "sourceKeys": [0, 1]},
                         {"heading": "时长", "explanation": "本段讲述要求新生本学期二十小时。", "sourceKeys": [2]}],
            "gaps": ["本段没有明确其他年级的时长。"]}


class APIFocusedStudyTests(unittest.TestCase):
    def model(self, **changes):
        values = dict(is_remote=True, model="synthetic", config={}, focus_checkpoint_path=None)
        values.update(changes)
        return SimpleNamespace(**values)

    def test_one_request_reads_all_material_and_preserves_sources(self):
        spans = sources()
        original = copy.deepcopy(spans)
        completion = Mock(return_value=answer())
        report = study.generate(self.model(), spans, "报名、认定和时长", completion)
        completion.assert_called_once()
        for s in spans:
            self.assertIn(s["originalText"], completion.call_args.args[2])
        self.assertEqual(completion.call_args.kwargs, {"api_task": "focused-study"})
        self.assertEqual(len(report["sections"]), 2)
        self.assertEqual(report["sections"][0]["sourceSpanIDs"], [s["id"] for s in spans[:2]])
        self.assertEqual(spans, original)

    def test_success_checkpoint_prevents_rebilling_but_stale_source_does_not(self):
        with tempfile.TemporaryDirectory() as directory:
            model = self.model(focus_checkpoint_path=str(Path(directory) / "checkpoint.json"))
            completion = Mock(return_value=answer())
            spans = sources()
            study.generate(model, spans, "时长", completion)
            report = study.generate(model, spans, "时长", completion)
            self.assertEqual(completion.call_count, 1)
            self.assertEqual(len(report["sections"]), 2)
            reordered = [dict(reversed(list(s.items()))) for s in spans]
            study.generate(model, reordered, "时长", completion)
            self.assertEqual(completion.call_count, 1)
            spans[2]["correctedText"] = "人工修正"
            study.generate(model, spans, "时长", completion)
            self.assertEqual(completion.call_count, 2)
            model.model = "different-model"
            study.generate(model, spans, "时长", completion)
            self.assertEqual(completion.call_count, 3)

    def test_cache_revalidates_source_ids(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "checkpoint.json"
            model = self.model(focus_checkpoint_path=str(path))
            completion = Mock(return_value=answer())
            spans = sources()
            study.generate(model, spans, "条件", completion)
            bad = json.loads(path.read_text())
            bad["answer"]["sections"][0]["sourceKeys"] = [999]
            path.write_text(json.dumps(bad))
            report = study.generate(model, spans, "条件", completion)
            self.assertEqual(completion.call_count, 2)
            self.assertEqual(len(report["sections"]), 2)

    def test_foreign_boolean_duplicate_and_empty_evidence_never_publish(self):
        for keys in ([999], [True], [0, 0], []):
            value = answer()
            value["sections"][0]["sourceKeys"] = keys
            with self.subTest(keys=keys), self.assertRaises((ValueError, remote.RemoteAPIError)):
                study.generate(self.model(), sources(), "条件", Mock(return_value=value))

    def test_oversized_input_preflight_no_request_or_truncation(self):
        completion = Mock()
        with patch.object(study, "_fits", return_value=False):
            with self.assertRaisesRegex(ValueError, "没有截断"):
                study.generate(self.model(), sources(), "条件", completion)
        completion.assert_not_called()

    def test_api_failure_is_not_retried_or_replaced_by_a_fake_report(self):
        completion = Mock(side_effect=remote.RemoteAPIError("API 达到输出上限"))
        with self.assertRaises(remote.RemoteAPIError):
            study.generate(self.model(), sources(), "条件", completion)
        completion.assert_called_once()

    def test_no_relevant_source_is_explicit(self):
        result = study.generate(self.model(), sources(), "无关问题", Mock(return_value={
            "sections": [], "gaps": ["全文没有相关说明。"]}))
        self.assertEqual(result["sections"], [])
        self.assertIn("全文没有相关说明", result["gaps"][0])


if __name__ == "__main__":
    unittest.main()
