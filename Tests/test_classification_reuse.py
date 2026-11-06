import copy
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Backend"))
import local_pipeline as pipeline


class ClassificationReuseTest(unittest.TestCase):
    def setUp(self):
        punctuation = patch("punctuation_formatter.punctuate_transcript", return_value=[])
        punctuation.start()
        self.addCleanup(punctuation.stop)

    def test_saved_attempt_resumes_map_without_repeating_uncertain_batch(self):
        spans = [{"id": "s", "originalText": "完成任物", "proofreadBasis": "完成任物",
                  "proofreadText": "完成任物", "proofreadUncertainties": ["校订未完成，保留原稿"]}]
        with patch.object(pipeline, "load_structure_model"), \
             patch.object(pipeline, "prepare_structure_classification"), \
             patch("transcript_proofreader.proofread_transcript") as proof, \
             patch("source_bound_map.build_map", return_value=([], [])) as build:
            pipeline.structure({"reuse_existing_proofreading": True}, spans)
        proof.assert_not_called()
        build.assert_called_once()

    def test_stale_or_partial_attempt_is_not_reused(self):
        from transcript_proofreader import reusable_attempt
        span = {"id": "s", "originalText": "原稿", "proofreadBasis": "原稿",
                "proofreadText": "原稿", "proofreadUncertainties": []}
        self.assertTrue(reusable_attempt([span]))
        self.assertFalse(reusable_attempt([dict(span, originalText="新稿")]))
        self.assertFalse(reusable_attempt([dict(span, proofreadUncertainties=None)]))
        self.assertFalse(reusable_attempt([]))
        self.assertTrue(reusable_attempt([span, {"id": "user", "originalText": "思考", "origin": {"authoredByUser": True}}]))

    def test_proofreading_precedes_map_and_reuses_loaded_model(self):
        spans = [{"id": "s", "sequence": 0, "originalText": "完成任物", "isBackgroundAudio": False}]
        llm = object()
        def proofread(model, source, completion, **kwargs):
            self.assertIs(model, llm)
            source[0].update(proofreadText="完成任务", proofreadBasis="完成任物")
            return ["局部疑点"]
        def build(model, source, completion, title, **kwargs):
            self.assertIs(model, llm)
            self.assertEqual(source[0]["proofreadText"], "完成任务")
            self.assertEqual(source[0]["originalText"], "完成任物")
            return [], []
        warnings = []
        with patch.object(pipeline, "load_structure_model", return_value=llm) as load, \
             patch.object(pipeline, "prepare_structure_classification"), \
             patch("transcript_proofreader.proofread_transcript", side_effect=proofread) as proof, \
             patch("source_bound_map.build_map", side_effect=build) as map_call:
            pipeline.structure({}, spans, processing_warnings=warnings)
        load.assert_called_once(); proof.assert_called_once(); map_call.assert_called_once()
        self.assertEqual(warnings, ["局部疑点"])

    def spans(self):
        return [{"id": str(i), "sequence": i, "startTime": i * 30, "endTime": i * 30 + 10,
                 "originalText": f"合成原话{i}", "correctedText": None, "isBackgroundAudio": True}
                for i in range(4)]

    def test_explicit_reuse_preserves_filters_but_protects_marks_and_corrections(self):
        spans = self.spans(); spans[2]["correctedText"] = "用户原样修正"; spans[3]["isImportant"] = True
        before = copy.deepcopy(spans)
        manifest = {"reuse_transcript_classification": True, "annotations": [{"kind": "important", "sourceSpanIDs": ["1"]}]}
        with patch.object(pipeline, "classify_nonlesson_text") as classify, patch.object(pipeline, "emit_progress") as progress:
            pipeline.prepare_structure_classification(manifest, object(), spans)
        classify.assert_not_called()
        self.assertTrue(spans[0]["isBackgroundAudio"])
        self.assertTrue(all(not s["isBackgroundAudio"] for s in spans[1:]))
        self.assertEqual([s["originalText"] for s in spans], [s["originalText"] for s in before])
        self.assertIn("复用", progress.call_args[0][0])

    def test_default_false_and_retranscribe_reevaluate(self):
        for manifest in [{}, {"reuse_transcript_classification": False},
                         {"reuse_transcript_classification": True, "retranscribe": True}]:
            spans = self.spans()
            def reevaluate(_, source):
                for span in source: span["isBackgroundAudio"] = False
            with patch.object(pipeline, "classify_nonlesson_text", side_effect=reevaluate) as classify:
                pipeline.prepare_structure_classification(manifest, object(), spans)
            classify.assert_called_once()
            self.assertTrue(all(not span["isBackgroundAudio"] for span in spans))

    def test_fresh_asr_entry_point_vetoes_reuse_even_if_requested(self):
        for asr_only in [False, True]:
            args = SimpleNamespace(manifest="not-opened", output="not-written", structure_from=None,
                                   asr_only=asr_only, annotations_only=False, provisional_output=None, provisional_from=None)
            manifest = {"reuse_transcript_classification": True, "reuse_existing_proofreading": True}
            with patch.object(pipeline, "parse_args", return_value=args), \
                 patch.object(pipeline, "load_manifest", return_value=manifest), \
                 patch.object(pipeline, "transcribe", return_value=([], self.spans(), "")) as transcribe, \
                 patch.object(pipeline, "structure", return_value=[]) as structure, \
                 patch.object(pipeline, "write_result") as write, \
                 patch.object(pipeline, "emit_progress"), patch.object(pipeline.threading, "Thread"):
                pipeline.main()
            transcribe.assert_called_once()
            self.assertFalse(manifest["reuse_transcript_classification"])
            self.assertFalse(manifest["reuse_existing_proofreading"])
            self.assertFalse(write.call_args[0][1]["reuseTranscriptClassification"])
            self.assertEqual(structure.call_count, 0 if asr_only else 1)


if __name__ == "__main__":
    unittest.main()
