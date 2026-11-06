import copy
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Backend"))
import local_pipeline as pipeline


class BackgroundSafety(unittest.TestCase):
    def test_fresh_asr_time_mark_protects_twelve_second_context(self):
        spans = [{"id": f"fresh-{i}", "sequence": i + 1, "startTime": t, "endTime": t + 2,
                  "originalText": "这段是用户正在关注的课程原文。"} for i, t in enumerate([16, 18, 30, 42, 44])]
        annotations = [{"id": "mark", "kind": "important", "sourceSpanIDs": ["obsolete-id"], "anchorTime": 31}]
        pipeline.protect_marked_spans(annotations, spans)
        with patch.object(pipeline, "structured_completion", return_value={"exclude": [
            {"sequence": s["sequence"], "reason": "连续歌词"} for s in spans
        ]}):
            pipeline.classify_nonlesson_text(None, spans)
        self.assertEqual([s["id"] for s in spans if not s["isBackgroundAudio"]], ["fresh-1", "fresh-2", "fresh-3"])
        self.assertTrue(all(s["originalText"] == "这段是用户正在关注的课程原文。" for s in spans))

    def test_annotation_only_keeps_explicit_marks_and_user_corrections(self):
        spans = [{"id": "marked", "sequence": 1, "originalText": "先解释原因然后检验方法", "isBackgroundAudio": True, "isImportant": True},
                 {"id": "corrected", "sequence": 2, "originalText": "识别错词", "correctedText": "先解释原因然后检验方法", "isBackgroundAudio": True}]
        annotations = [{"id": i, "kind": "important", "sourceSpanIDs": [i]} for i in ("marked", "corrected")]
        seen = []
        def model(llm, system, prompt, schema, **kwargs):
            seen.append(prompt)
            if "annotationSummaries" in schema["properties"]:
                return {"annotationSummaries": [{"id": i, "summary": "先解释原因再检验方法"} for i in ("marked", "corrected")]}
            return {"supportedIDs": ["marked", "corrected"]}
        with patch.object(pipeline, "structured_completion", side_effect=model):
            result = pipeline.summarize_annotations(None, annotations, spans)
        self.assertEqual(len(result), 2)
        self.assertNotIn("识别错词", seen[0])

    def test_model_repeat_label_cannot_hide_meaningful_speech(self):
        lines = [
            "当我研究这个问题的时候，发现方案太多，先把增肌和减重分开，我这个阶段就一件事，让体重达到目标。",
            "好，先做一个小实验。", "好，先做一个小实验。",
            "这句歌词说‘明天会更好’，我们要分析它为什么表达期待，而不是把它当成事实。",
        ]
        spans = [{"sequence": i + 1, "originalText": text} for i, text in enumerate(lines)]
        with patch.object(pipeline, "structured_completion", return_value={"exclude": [
            {"sequence": i + 1, "reason": "无意义识别重复"} for i in range(len(lines))
        ]}):
            pipeline.classify_nonlesson_text(None, spans)
        self.assertTrue(all(not s["isBackgroundAudio"] for s in spans))
        self.assertEqual([s["originalText"] for s in spans], lines)

    def test_deterministic_mechanical_repetition_still_filtered(self):
        spans = [{"sequence": 1, "originalText": "啊" * 40},
                 {"sequence": 2, "originalText": "不是重复词就应该删除，要先理解这句话。"}]
        with patch.object(pipeline, "structured_completion", return_value={"exclude": []}):
            pipeline.classify_nonlesson_text(None, spans)
        self.assertTrue(spans[0]["isBackgroundAudio"])
        self.assertFalse(spans[1]["isBackgroundAudio"])

    def test_dense_short_teaching_is_not_hidden(self):
        lines = ["今天讲主动回忆", "首先关上笔记", "用自己的话复述", "找出不懂的地方", "再查原来的材料", "修正理解的错误", "不要只反复阅读", "阅读会造成熟悉感", "熟悉不代表能解释", "用新的题目检验", "再间隔一段时间", "重新回忆重点", "逐步延长间隔", "最后应用到新问题"]
        spans = [{"text": text, "start": i * 2, "end": i * 2 + 1.7, "is_background": False} for i, text in enumerate(lines)]
        pipeline.mark_likely_music_windows(spans, 30)
        self.assertFalse(any(item["is_background"] for item in spans))

    def test_repeated_concepts_and_uncertain_text_stay(self):
        spans = [{"sequence": i + 1, "originalText": "边际成本不是总成本，边际成本是多做一单位的成本。", "isBackgroundAudio": False} for i in range(14)]
        before = copy.deepcopy(spans)
        with patch.object(pipeline, "structured_completion", return_value={"exclude": []}):
            pipeline.classify_nonlesson_text(None, spans)
        self.assertEqual(spans, before)

    def test_model_cannot_hide_ids_outside_current_batch(self):
        spans = [{"sequence": 1, "originalText": "这是正常讲解", "isBackgroundAudio": False}]
        with patch.object(pipeline, "structured_completion", return_value={"exclude": [
            {"sequence": True, "reason": "连续歌词"}, {"sequence": 999, "reason": "连续歌词"},
            {"sequence": 1, "reason": "我觉得不重要"},
        ]}):
            pipeline.classify_nonlesson_text(None, spans)
        self.assertFalse(spans[0]["isBackgroundAudio"])

    def test_classification_never_rewrites_original(self):
        spans = [{"sequence": 1, "originalText": "测试歌词原文", "isBackgroundAudio": False},
                 {"sequence": 2, "originalText": "下面讲如何分析歌词", "isBackgroundAudio": False}]
        with patch.object(pipeline, "structured_completion", return_value={"exclude": [{"sequence": 1, "reason": "连续歌词"}]}):
            pipeline.classify_nonlesson_text(None, spans)
        self.assertEqual(spans[0]["originalText"], "测试歌词原文")
        self.assertFalse(spans[1]["isBackgroundAudio"])

    def test_filter_failure_keeps_text_and_user_marks_win(self):
        spans = [{"sequence": 1, "originalText": "这个原理很重要", "isBackgroundAudio": True, "isImportant": True}]
        with patch.object(pipeline, "structured_completion", side_effect=ValueError("bad JSON")):
            pipeline.classify_nonlesson_text(None, spans)
        self.assertFalse(spans[0]["isBackgroundAudio"])
        with patch.object(pipeline, "structured_completion", return_value={"exclude": [{"sequence": 1, "reason": "连续歌词"}]}):
            pipeline.classify_nonlesson_text(None, spans)
        self.assertFalse(spans[0]["isBackgroundAudio"])

    def test_large_course_batches_cover_every_input(self):
        items = [{"candidateIndex": i, "summary": f"第{i}项知识如何应用到实践并检验结果"} for i in range(960)]
        batches = list(pipeline.bounded_batches(items))
        self.assertEqual([item for batch in batches for item in batch], items)
        import json
        self.assertTrue(all(len(json.dumps(batch, ensure_ascii=False).encode("utf-8")) <= 4200 for batch in batches))
        audit_batches = list(pipeline.bounded_batches(items, byte_limit=3800, max_items=6))
        self.assertEqual([item for batch in audit_batches for item in batch], items)
        self.assertTrue(all(len(batch) <= 6 for batch in audit_batches))

    def test_full_structure_input_paging_preserves_long_tail(self):
        import tempfile
        import types
        import json
        calls = []
        def complete(llm, system, prompt, schema, **kwargs):
            if "exclude" in schema.get("properties", {}):
                return {"exclude": []}
            calls.append(prompt)
            return {"nodes": []}
        text = "正常课程解释。" * 200 + "结尾的独立方法不能丢掉。"
        with tempfile.TemporaryDirectory() as temp:
            model = Path(temp) / "fake.gguf"
            with model.open("wb") as handle:
                handle.write(b"GGUF")
                handle.truncate(1_000_000_001)
            with patch.dict(sys.modules, {"llama_cpp": types.SimpleNamespace(Llama=lambda **kwargs: None)}), patch.object(pipeline, "structured_completion", side_effect=complete), patch("model_lease.acquire_model_lease"):
                with self.assertRaises(ValueError):
                    pipeline.structure({"structure_model_path": str(model), "structure_strategy": "legacy-discourse"}, [{"id": "x", "sequence": 1, "originalText": text}])
        self.assertTrue(any("结尾的独立方法不能丢掉" in prompt for prompt in calls))

    def test_tail_evidence_reaches_global_discourse_and_final_node(self):
        import tempfile
        import types
        import json
        title = "结尾独立方法是先验证效果再扩大使用"
        text = "开头介绍和中段讨论。" * 200 + title + "。"
        reviewed_evidence = []
        def complete(llm, system, prompt, schema, **kwargs):
            props = schema["properties"]
            if "exclude" in props:
                return {"exclude": []}
            if "nodes" in props:
                return {"nodes": [{"summary": title, "sourceSequenceIDs": [1], "confidence": 0.9}] if title in prompt else []}
            if "revisions" in props:
                records = json.loads(prompt.split("笔记核验：", 1)[1])
                return {"revisions": [{"noteIndex": r["noteIndex"], "usable": True, "summary": r["summary"], "argumentSummary": "", "reason": ""} for r in records]}
            if set(props) == {"assignments"}:
                return {"assignments": {"0": 0}}
            if "evidence" in props or "verdict" in props:
                from quote_test_support import quote_response
                return quote_response(prompt, schema, lambda claim, texts: [t for t in texts if title in t][:1])
            if "stages" in props:
                records = json.loads(prompt.split("笔记：", 1)[1])
                self.assertIn(title, records[0]["evidenceOriginal"])
                reviewed_evidence.append(records[0]["evidenceOriginal"])
                return {"center": {"summary": title, "argumentSummary": "", "evidenceIndex": 0},
                        "stages": [{"summary": title, "argumentSummary": "", "memberIndices": [0],
                                    "evidenceIndex": 0, "relationToPrevious": "得出结论"}]}
            raise AssertionError("unexpected model call")
        with tempfile.TemporaryDirectory() as temp:
            model = Path(temp) / "fake.gguf"
            with model.open("wb") as handle:
                handle.write(b"GGUF")
                handle.truncate(1_000_000_001)
            with patch.dict(sys.modules, {"llama_cpp": types.SimpleNamespace(Llama=lambda **kwargs: None)}), patch.object(pipeline, "structured_completion", side_effect=complete), patch("model_lease.acquire_model_lease"):
                nodes = pipeline.structure({"structure_model_path": str(model), "structure_strategy": "legacy-discourse"}, [{"id": "tail-source", "sequence": 1, "originalText": text}])
        self.assertEqual(len(reviewed_evidence), 1)
        self.assertTrue(any(node["summary"] == title for node in nodes))
        self.assertTrue(all(node["sourceSpanIDs"] == ["tail-source"] for node in nodes))


if __name__ == "__main__":
    unittest.main()
