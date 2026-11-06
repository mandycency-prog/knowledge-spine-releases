import copy
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Backend"))
import local_pipeline as pipeline


class ImportantOverviewTest(unittest.TestCase):
    def test_entire_protected_context_one_call_and_no_rewrite(self):
        spans = [dict(id=str(i), sequence=i, originalText=text, startTime=i * 3, endTime=i * 3 + 2)
                 for i, text in enumerate(["先明确要解决的问题。", "再选择能持续的做法。", "执行时记录实际结果。",
                                           "条件变化时重新核对。", "不能把个人经验当成普遍保证。"])]
        annotations = [dict(id="mark", kind="important", sourceSpanIDs=[s["id"] for s in spans])]
        before = copy.deepcopy(spans)
        overview = "围绕实际问题选择并调整方法。\n• 先明确问题，再选择可持续的做法。\n• 根据结果与条件变化复核，个人经验不代表普遍保证。"
        def complete(llm, system, prompt, schema, **kwargs):
            supplied = json.loads(prompt.split("标注：", 1)[1])
            for s in before:
                self.assertIn(s["originalText"], supplied[0]["text"])
            return {"annotationSummaries": [{"id": "mark", "summary": overview}]}
        with patch.object(pipeline, "structured_completion", side_effect=complete) as call:
            output = pipeline.summarize_annotations(None, annotations, spans)
        self.assertEqual(call.call_count, 1)
        self.assertEqual(output, [{"id": "mark", "summary": overview}])
        self.assertEqual([s["originalText"] for s in spans], [s["originalText"] for s in before])

    def test_default_map_path_uses_same_loaded_model_for_overviews(self):
        model = object()
        spans = [dict(id="s", originalText="原稿", sequence=0)]
        summaries = []
        manifest = {"annotations": [{"id": "m", "kind": "important", "sourceSpanIDs": ["s"]}]}
        with patch.object(pipeline, "load_structure_model", return_value=model), \
             patch.object(pipeline, "prepare_structure_classification"), \
             patch("transcript_proofreader.proofread_transcript", return_value=[]), \
             patch("punctuation_formatter.punctuate_transcript", return_value=[]), \
             patch("source_bound_map.build_map", return_value=([], [])), \
             patch.object(pipeline, "summarize_annotations", return_value=[{"id": "m", "summary": "重点概括"}]) as summarize:
            pipeline.structure(manifest, spans, annotation_summaries=summaries)
        summarize.assert_called_once_with(model, manifest["annotations"], spans)
        self.assertEqual(summaries, [{"id": "m", "summary": "重点概括"}])


if __name__ == "__main__":
    unittest.main()
