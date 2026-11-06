import copy
import json
from pathlib import Path
import sys
import subprocess
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Backend"))
import transcript_proofreader as p


def span(i, text="这段内容可以结合上下文校订。", **kwargs):
    return dict(id=str(uuid.uuid4()), sequence=i, originalText=text, correctedText=None,
                startTime=i, endTime=i + 1, **kwargs)


class TranscriptProofreaderTest(unittest.TestCase):
    def test_equal_numeric_counts_do_not_allow_swapping_quantities_or_units(self):
        for before, after in (("甲等待12分钟，乙等待20分钟。", "甲等待20分钟，乙等待12分钟。"),
                              ("甲长度12厘米，乙长度20厘米。", "甲长度20厘米，乙长度12厘米。"),
                              ("甲有１２个，乙有２０个。", "甲有２０个，乙有１２个。")):
            with self.subTest(before=before):
                self.assertIn("数字", p._edit_issue(before, after, before))

    def test_equal_negation_counts_do_not_allow_swapping_their_subject(self):
        original = "甲不能继续执行，乙可以继续执行。"
        edited = "甲可以继续执行，乙不能继续执行。"
        self.assertIn("否定", p._edit_issue(original, edited, original))

    def test_single_replacement_internally_swapping_protected_tokens_is_rejected(self):
        for before, after in (("甲12分钟乙20分钟。", "甲20分钟乙12分钟。"),
                              ("甲不能执行而乙可以执行。", "甲可以执行而乙不能执行。")):
            source = [span(0, before)]
            value = {"edits": [{"sourceID": "s0", "from": before, "to": after}], "uncertainties": []}
            warnings = p.proofread_transcript(None, source, lambda *a, **kw: value)
            self.assertTrue(warnings)
            self.assertEqual(source[0]["proofreadText"], before)
            self.assertTrue(source[0]["proofreadUncertainties"])

    def test_ordinary_typo_near_unchanged_quantity_and_negation_remains_allowed(self):
        before = "这项任物需要12分钟，不能省略最后核对。"
        after = "这项任务需要12分钟，不能省略最后核对。"
        self.assertIsNone(p._edit_issue(before, after, before))
        self.assertIsNone(p._edit_issue("需要12分钟不能省略。", "需要12分钟，不能省略。", "需要12分钟不能省略。"))

    def test_multiple_replacements_use_original_offsets_even_when_lengths_change(self):
        text = "请把任物写在记路里，然后把其他内容保持完整。"
        edits = [{"from": "任物", "to": "待办任务"}, {"from": "记路", "to": "记录"}]
        self.assertEqual(p._apply_edits(text, edits), "请把待办任务写在记录里，然后把其他内容保持完整。")
        self.assertEqual(p._apply_edits(text, list(reversed(edits))), p._apply_edits(text, edits))

    def test_ambiguous_overlap_duplicate_and_chained_replacements_are_not_applied(self):
        cases = [("重复重复", [{"from": "重复", "to": "内容"}]),
                 ("aaaa", [{"from": "aaa", "to": "b"}]),
                 ("原始内容", [{"from": "原始", "to": "最初"}, {"from": "始内", "to": "甲乙"}]),
                 ("原始内容", [{"from": "原始", "to": "最初"}, {"from": "原始", "to": "开头"}]),
                 ("原始内容", [{"from": "原始", "to": "最初"}, {"from": "最初", "to": "开头"}])]
        for text, edits in cases:
            with self.subTest(text=text, edits=edits):
                with self.assertRaises(ValueError):
                    p._apply_edits(text, edits)

    def test_invalid_local_locator_keeps_one_span_but_good_other_span_survives(self):
        source = [span(0, "任物重复任物。"), span(1, "请把这项任物完成。")]
        response = {"edits": [{"sourceID": "s0", "from": "任物", "to": "任务"},
                               {"sourceID": "s1", "from": "任物", "to": "任务"}], "uncertainties": []}
        warnings = p.proofread_transcript(None, source, lambda *a, **kw: response)
        self.assertEqual(len(warnings), 1)
        self.assertEqual(source[0]["proofreadText"], source[0]["originalText"])
        self.assertEqual(source[1]["proofreadText"], "请把这项任务完成。")

    def test_empty_or_oversize_from_to_is_rejected_before_apply(self):
        for field in ("from", "to"):
            for value in ("", " ", "长" * 81, None, True):
                edit = {"sourceID": "s0", "from": "任物", "to": "任务"}
                edit[field] = value
                with self.assertRaises(ValueError):
                    p._response({"edits": [edit], "uncertainties": []}, {"s0"})

    def test_short_alias_payload_preserves_boundaries_without_structural_uuids(self):
        speaker_a, speaker_b, course_a, course_b = [str(uuid.uuid4()) for _ in range(4)]
        source = [span(0, "请把这项任物完成。", speakerID=speaker_a, origin={"sessionID": course_a, "sessionTitle": "同名课程", "itemID": str(uuid.uuid4())}),
                  span(1, "另一个课程的原话。", speakerID=speaker_b, origin={"sessionID": course_b, "sessionTitle": "同名课程"})]
        context = [span(2, "我自己的想法。", speakerID=speaker_a,
                        origin={"sessionID": course_a, "sessionTitle": "同名课程", "authoredByUser": True})]
        prompt = p._prompt(source, context)
        data = json.loads(prompt.split("输入：", 1)[1])
        self.assertEqual([s["sourceID"] for s in data["targets"]], ["s0", "s1"])
        self.assertEqual(data["context"][0]["sourceID"], "c0")
        self.assertNotEqual(data["targets"][0]["origin"]["courseKey"], data["targets"][1]["origin"]["courseKey"])
        self.assertEqual(data["targets"][0]["origin"]["courseKey"], data["context"][0]["origin"]["courseKey"])
        self.assertTrue(data["context"][0]["origin"]["authoredByUser"])
        self.assertEqual(data["targets"][0]["speakerID"], data["context"][0]["speakerID"])
        for identifier in [speaker_a, speaker_b, course_a, course_b] + [s["id"] for s in source + context]:
            self.assertNotIn(identifier, prompt)
        before_ids = [s["id"] for s in source]
        p.proofread_transcript(None, source, lambda *a, **kw: {"edits": [{"sourceID": "s0", "from": "任物", "to": "任务"}], "uncertainties": []})
        self.assertEqual([s["id"] for s in source], before_ids)
        self.assertEqual(source[0]["proofreadText"], "请把这项任务完成。")
        self.assertNotIn('"sourceID":"s0"', p._json(source))

    def test_context_alias_and_other_batch_real_id_are_rejected(self):
        previous_id = str(uuid.uuid4())
        for bad_alias in ("c0", "s60", previous_id):
            source = [span(0)]
            warnings = p.proofread_transcript(None, source, lambda *a, **kw: {
                "edits": [{"sourceID": bad_alias, "from": "内容", "to": "原文"}], "uncertainties": []})
            self.assertTrue(warnings)
            self.assertEqual(source[0]["proofreadText"], source[0]["originalText"])

    def test_sixty_short_fragments_do_not_split_due_to_uuid_protocol_overhead(self):
        class Budget:
            def tokenize(self, value):
                return range((len(value) + 2) // 3)
            def n_ctx(self):
                return 8192
        source = [span(i, "原始内容需要完整保留。", speakerID=str(uuid.uuid4())) for i in range(60)]
        calls = []
        def complete(llm, system, prompt, schema, **kwargs):
            calls.append(json.loads(prompt.split("输入：", 1)[1]))
            self.assertEqual(kwargs["max_tokens"], 1024)
            return {"edits": [], "uncertainties": []}
        self.assertEqual(p.proofread_transcript(Budget(), source, complete), [])
        self.assertEqual(len(calls), 1)
        self.assertEqual(len(calls[0]["targets"]), 60)

    def test_native_grammar_sixty_ids_builds_in_child_without_loading_model(self):
        # Native segfaults cannot be caught by Python. Isolate the real grammar
        # constructor so a regression is a failed test, not a dead test runner.
        script = ("import sys,uuid; sys.path.insert(0,sys.argv[1]); "
                  "import transcript_proofreader as p; from llama_cpp import LlamaGrammar; "
                  "import json; ids=['s'+str(i) for i in range(60)]; "
                  "g=LlamaGrammar.from_json_schema(json.dumps(p._schema(ids)),verbose=False); "
                  "assert g is not None; print('native grammar ready; no model loaded')")
        result = subprocess.run([sys.executable, "-c", script, str(Path(p.__file__).parent)],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr[-2000:])
        self.assertIn("native grammar ready", result.stdout)

    def test_runtime_bounds_still_reject_grammar_unbounded_overflow(self):
        ids = {"target"}
        for result in ({"edits": [{"sourceID": "target", "from": "原文", "to": "长" * 81}], "uncertainties": []},
                       {"edits": [], "uncertainties": ["target"] * 2},
                       {"edits": [{"sourceID": "target", "from": "原文", "to": "内容"}] * 2, "uncertainties": []}):
            with self.assertRaises(ValueError):
                p._response(result, ids)

    def test_corrects_once_reuses_same_basis_and_never_changes_original_fields(self):
        source = [span(0, "请把这项任物完成。"), span(1, "完成后核对结果。")]
        before = copy.deepcopy(source)
        calls = []
        def complete(llm, system, prompt, schema, **kwargs):
            calls.append(prompt)
            self.assertIn("同音/近音识别错词", prompt)
            self.assertIn("正确词不必事先在原文出现", prompt)
            self.assertIn("不授权猜测具体专名、书名或数值事实", prompt)
            return {"edits": [{"sourceID": "s0", "from": "任物", "to": "任务"}], "uncertainties": []}
        self.assertEqual(p.proofread_transcript(None, source, complete), [])
        self.assertEqual(p.proofread_transcript(None, source, complete), [])
        self.assertEqual(len(calls), 1)
        self.assertEqual(source[0]["proofreadText"], "请把这项任务完成。")
        for original, changed in zip(before, source):
            self.assertEqual({k: changed[k] for k in original}, original)
            self.assertEqual(changed["proofreadBasis"], original["originalText"])
        source[0]["originalText"] = "后来改变的原始识别。"
        self.assertFalse(p.valid_proofread(source[0]))

    def test_handwritten_corrected_and_background_are_never_written(self):
        source = [span(0, origin={"authoredByUser": True}), span(1, isBackgroundAudio=True), span(2)]
        source[2]["correctedText"] = "这是人工修订的内容。"
        before = copy.deepcopy(source)
        calls = []
        p.proofread_transcript(None, source, lambda *a, **kw: calls.append(a))
        self.assertEqual(source, before)
        self.assertEqual(calls, [])

    def test_local_unsafe_changes_rejected_but_other_corrections_survive(self):
        source = [span(0, "等待12分钟后处理。"), span(1, "这次提到了一个名称。"),
                  span(2, "先核对各项条件再处理问题，不能省略前提和最后的验证。"), span(3, "请把这项任物完成。")]
        changed = ["等待2分钟后处理。", "这次提到了《一个名称》。", "处理问题。", "请把这项任务完成。"]
        result = {"edits": [{"sourceID": f"s{i}", "from": source[i]["originalText"], "to": text} for i, text in enumerate(changed)], "uncertainties": []}
        warnings = p.proofread_transcript(None, source, lambda *a, **kw: result)
        self.assertEqual(len(warnings), 3)
        for s in source[:3]:
            self.assertEqual(s["proofreadText"], s["originalText"])
            self.assertTrue(s["proofreadUncertainties"])
        self.assertEqual(source[3]["proofreadText"], changed[3])

    def test_numbers_decimals_fullwidth_and_chinese_cannot_be_silently_changed(self):
        for original, edited in (("数值160厘米。", "数值60厘米。"), ("值为１．２。", "值为１２。"),
                                 ("需要三次确认。", "需要一次确认。"), ("需要12分钟。", "需要12小时。")):
            self.assertIn("数字", p._edit_issue(original, edited, original))

    def test_title_already_explicit_in_context_can_be_kept(self):
        self.assertIsNone(p._edit_issue("这里读到已有名称。", "这里读到《已有名称》。", "前文明确《已有名称》。"))

    def test_uncertainty_is_preserved_without_rewriting(self):
        source = [span(0, "提到了一个听不清的专名。")]
        result = {"edits": [], "uncertainties": ["s0"]}
        warnings = p.proofread_transcript(None, source, lambda *a, **kw: result)
        self.assertTrue(warnings)
        self.assertEqual(source[0]["proofreadText"], source[0]["originalText"])
        self.assertTrue(p.valid_proofread(source[0]))
        self.assertTrue(p.proofread_transcript(None, source, lambda *a, **kw: self.fail("复用不应再调用")))

    def test_negation_cannot_be_lost_as_a_small_edit(self):
        self.assertIn("否定", p._edit_issue("这不是一个问题。", "这是一个问题。", "这不是一个问题。"))

    def test_bad_response_preserves_entire_batch_and_continues_next(self):
        source = [span(i) for i in range(61)]
        calls = []
        def complete(llm, system, prompt, schema, **kwargs):
            data = json.loads(prompt.split("输入：", 1)[1]); calls.append(data)
            if len(calls) == 1:
                return {"edits": [{"sourceID": "foreign", "from": "内容", "to": "文字"}], "uncertainties": []}
            return {"edits": [], "uncertainties": []}
        warnings = p.proofread_transcript(None, source, complete)
        self.assertTrue(warnings)
        self.assertGreaterEqual(len(calls), 2)
        for data in calls:
            self.assertLessEqual(len(data["targets"]), 60)
            self.assertLessEqual(sum(len(s["text"]) for s in data["targets"]), 1800)
        self.assertNotIn("proofreadingVersion", source[0])
        self.assertTrue(p.valid_proofread(source[-1]))
        self.assertTrue(calls[0]["context"])

    def test_call_exception_is_not_fatal_or_retried(self):
        source = [span(0)]; calls = []
        def complete(*a, **kw):
            calls.append(a); raise RuntimeError("failure")
        self.assertTrue(p.proofread_transcript(None, source, complete))
        self.assertEqual(len(calls), 1)
        self.assertEqual(source[0]["proofreadText"], source[0]["originalText"])
        self.assertFalse(p.valid_proofread(source[0]))

    def test_duplicate_or_invalid_edits_do_not_partially_apply(self):
        for kind in ("duplicate", "blank", "truncated"):
            source = [span(0)]
            edit = {"sourceID": "s0", "from": "内容", "to": "文字"}
            result = {"edits": [edit, edit], "uncertainties": []} if kind == "duplicate" else (
                {"edits": [dict(edit, to=" ")], "uncertainties": []} if kind == "blank" else '{"edits":')
            self.assertTrue(p.proofread_transcript(None, source, lambda *a, **kw: result))
            self.assertEqual(source[0]["proofreadText"], source[0]["originalText"])

    def test_single_oversize_source_is_not_truncated_or_sent(self):
        source = [span(0, "原始内容" * 600)]
        calls = []
        self.assertTrue(p.proofread_transcript(None, source, lambda *a, **kw: calls.append(a)))
        self.assertFalse(calls)
        self.assertEqual(source[0]["proofreadText"], source[0]["originalText"])


if __name__ == "__main__":
    unittest.main()
