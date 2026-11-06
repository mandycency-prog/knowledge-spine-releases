import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Backend"))
import local_pipeline as pipeline
from quote_test_support import quote_response


class DiscourseMapTest(unittest.TestCase):
    def test_unselected_manuscript_counterevidence_reaches_audit_and_repair(self):
        spans = [{"id": "chosen", "sequence": 1, "originalText": "这个练习让我愿意继续执行。"},
                 {"id": "unselected", "sequence": 2, "originalText": "但这不意味着练习变有趣，过程仍然无趣。"}]
        before = copy.deepcopy(spans)
        notes = [{"sourceSpanIDs": ["chosen"], "sourceText": spans[0]["originalText"]}]
        node = {"summary": "练习过程变得有趣", "argumentSummary": "", "sourceSpanIDs": ["chosen"], "coveredSourceSpanIDs": ["chosen"]}
        seen = []
        def model(llm, system, prompt, schema, **kwargs):
            seen.append(prompt)
            self.assertIn(spans[1]["originalText"], prompt)
            if "summary" in schema["properties"]:
                return {"summary": "练习过程仍然无趣", "argumentSummary": ""}
            return quote_response(prompt, schema, lambda claim, sources: [spans[1]["originalText"]],
                                  "contradicted" if "变得有趣" in prompt else "supported")
        with patch.object(pipeline, "structured_completion", side_effect=model):
            pipeline.verify_discourse_semantics(None, [node], notes, [[0]], transcript_spans=spans)
        self.assertEqual(len(seen), 5)
        self.assertEqual(spans, before)
        self.assertEqual(node["sourceSpanIDs"], ["unselected"])
        self.assertEqual(node["coveredSourceSpanIDs"], ["chosen", "unselected"])

    def test_full_manuscript_budget_pages_every_span_and_refuses_truncated_repair(self):
        import types
        spans = [{"id": f"s{i}", "sequence": i, "originalText": f"第{i}部分，" + "原文详细说明条件改变时方法可能不适用。" * 20} for i in range(20)]
        notes = [{"sourceSpanIDs": ["s0"], "sourceText": spans[0]["originalText"]}]
        node = {"summary": "该方法适用于所有条件", "argumentSummary": "", "coveredSourceSpanIDs": ["s0"]}
        before = copy.deepcopy(node)
        seen = []
        llm = types.SimpleNamespace(tokenize=lambda b: range(len(b) // 3), n_ctx=lambda: 4000)
        def model(llm, system, prompt, schema, **kwargs):
            self.assertIn("evidence", schema["properties"], "oversize repair must not invoke a model on truncated text")
            data = json.loads(prompt.split("输入：", 1)[1])
            seen.extend(data["originalSentences"])
            self.assertTrue(pipeline.quote_evidence._fits(llm, system, prompt, schema, kwargs["max_tokens"]))
            return {"evidence": []}
        with patch.object(pipeline, "structured_completion", side_effect=model):
            with self.assertRaises(pipeline.DiscourseSemanticError):
                pipeline.verify_discourse_semantics(llm, [node], notes, [[0]], transcript_spans=spans)
        self.assertEqual("".join(seen), "".join(s["originalText"] for s in spans))
        self.assertEqual(node, before)

    def test_semantic_contradiction_requires_valid_evidence_and_conflict(self):
        notes = [{"sourceSpanIDs": ["s"], "sourceText": "条件改变时方法可能不适用。"}]
        node = {"summary": "方法受适用条件限制", "argumentSummary": "", "coveredSourceSpanIDs": ["s"]}
        for change in ({"evidenceQuotes": []}, {"evidenceQuotes": ["编造反证。"]},
                       {"claimQuote": "模型自行增加了前提"}, {"reason": ""}):
            def model(llm, system, prompt, schema, **kwargs):
                value = quote_response(prompt, schema, verdict="contradicted")
                if "verdict" in schema["properties"]:
                    value.update(change)
                return value
            with patch.object(pipeline, "structured_completion", side_effect=model):
                with self.assertRaises(pipeline.DiscourseSemanticError):
                    pipeline.verify_discourse_semantics(None, [dict(node)], notes, [[0]])

    def test_semantic_context_uses_full_source_when_token_budget_fits(self):
        import types
        notes = [{"sourceSpanIDs": [f"s{i}"], "sourceText": f"第{i}部分先澄清目标，再观察实际结果。"} for i in range(12)]
        node = {"summary": "先澄清目标再观察结果", "argumentSummary": "", "coveredSourceSpanIDs": [f"s{i}" for i in range(12)]}
        seen = []
        def model(llm, system, prompt, schema, **kwargs):
            if "evidence" in schema["properties"]:
                seen.append(json.loads(prompt.split("输入：", 1)[1])["originalSentences"])
            return quote_response(prompt, schema)
        llm = types.SimpleNamespace(tokenize=lambda b: range(len(b) // 3), n_ctx=lambda: 8192)
        with patch.object(pipeline, "structured_completion", side_effect=model):
            pipeline.verify_discourse_semantics(llm, [node], notes, [list(range(12))])
        self.assertEqual(len(seen), 1)
        self.assertEqual(len(seen[0]), 12)
        seen.clear()
        small = types.SimpleNamespace(tokenize=lambda b: range(len(b) // 3), n_ctx=lambda: 3200)
        with patch.object(pipeline, "structured_completion", side_effect=model):
            pipeline.verify_discourse_semantics(small, [node], notes, [list(range(12))])
        self.assertEqual(sum(len(page) for page in seen), 12)

    def test_semantic_repair_is_once_per_failed_node_and_keeps_valid_peer(self):
        notes = [{"sourceSpanIDs": ["first"], "sourceText": "先确定目标再做小实验。"},
                 {"sourceSpanIDs": ["second"], "sourceText": "方法只在条件稳定时适用。"}]
        nodes = [{"summary": "先确定目标再做小实验", "argumentSummary": "", "coveredSourceSpanIDs": ["first"]},
                 {"summary": "方法在所有条件下都适用", "argumentSummary": "", "coveredSourceSpanIDs": ["second"]}]
        calls, repairs = [], []
        def model(llm, system, prompt, schema, **kwargs):
            calls.append(prompt)
            if "summary" in schema["properties"]:
                repairs.append(prompt)
                return {"summary": "方法只在稳定条件下适用", "argumentSummary": ""}
            return quote_response(prompt, schema, verdict="contradicted" if "所有条件" in prompt else "supported")
        with patch.object(pipeline, "structured_completion", side_effect=model):
            pipeline.verify_discourse_semantics(None, nodes, notes, [[0], [1]])
        self.assertEqual(len(calls), 7)
        self.assertEqual(len(repairs), 1)
        self.assertEqual(nodes[0]["sourceSpanIDs"], ["first"])
        self.assertEqual(nodes[1]["sourceSpanIDs"], ["second"])
        self.assertEqual(nodes[1]["summary"], "方法只在稳定条件下适用")
        self.assertIn("validationFeedback", repairs[0])
        self.assertNotIn(notes[0]["sourceText"], repairs[0])

    def test_semantic_failed_repair_does_not_loop_or_change_original_node(self):
        notes = [{"sourceSpanIDs": ["s"], "sourceText": "不适用于变化的条件。"}]
        nodes = [{"summary": "只有条件稳定才可能有效", "argumentSummary": "", "coveredSourceSpanIDs": ["s"]},
                 {"summary": "任何条件下方法都有效", "argumentSummary": "", "coveredSourceSpanIDs": ["s"]}]
        before = copy.deepcopy(nodes)
        calls = []
        def model(llm, system, prompt, schema, **kwargs):
            calls.append(prompt)
            if "summary" in schema["properties"]:
                return {"summary": "该方法总是稳定有效", "argumentSummary": ""}
            return quote_response(prompt, schema, verdict="supported" if "只有条件" in prompt else "contradicted")
        with patch.object(pipeline, "structured_completion", side_effect=model):
            with self.assertRaises(pipeline.DiscourseSemanticError):
                pipeline.verify_discourse_semantics(None, nodes, notes, [[0], [0]])
        self.assertEqual(nodes, before, "a failed later node must not update earlier nodes")
        self.assertEqual(len(calls), 7)

    def test_note_repair_keeps_valid_siblings_and_reports_unresolved(self):
        notes = [self.note(0), self.note(1)]
        notes[1]["sourceText"] = "我的目标已经达到，体重是131.8。"
        good = {"noteIndex": 0, "usable": True, "summary": "先提出问题再检验方法", "argumentSummary": "", "reason": ""}
        bad = {"noteIndex": 1, "usable": True, "summary": "体重已经达到131.8斤", "argumentSummary": "", "reason": ""}
        with patch.object(pipeline, "structured_completion", side_effect=[{"revisions": [good, bad]}, {"revisions": [bad]}]) as model:
            kept, unresolved = pipeline.review_discourse_notes(None, notes)
        self.assertEqual([n["sourceSpanIDs"] for n in kept], [["source-0"]])
        self.assertEqual(unresolved[0]["sourceSpanIDs"], ["source-1"])
        self.assertIn("单位", unresolved[0]["reviewReason"])
        self.assertEqual(model.call_count, 2)
        retry_prompt = model.call_args_list[1].args[2]
        self.assertIn("validationError", retry_prompt)
        self.assertNotIn(notes[0]["sourceText"], retry_prompt)

    def test_note_repair_can_remove_unsupported_numeric_detail(self):
        note = self.note(0)
        note["sourceText"] = "这次目标已达成，我现在是131.8。"
        bad = {"noteIndex": 0, "usable": True, "summary": "已经减到了131.8斤", "argumentSummary": "", "reason": ""}
        fixed = dict(bad, summary="这次目标已经达成")
        with patch.object(pipeline, "structured_completion", side_effect=[{"revisions": [bad]}, {"revisions": [fixed]}]):
            kept, unresolved = pipeline.review_discourse_notes(None, [note])
        self.assertEqual(kept[0]["summary"], "这次目标已经达成")
        self.assertEqual(unresolved, [])
        self.assertEqual(kept[0]["sourceText"], note["sourceText"])

    def test_partial_structure_emits_user_visible_warning(self):
        warnings = []
        note = self.note(0)
        node = {"sourceSpanIDs": ["source-0"], "coveredSourceSpanIDs": ["source-0"]}
        with patch.object(pipeline, "load_structure_model", return_value=None), \
             patch.object(pipeline, "classify_nonlesson_text"), \
             patch.object(pipeline, "structured_completion", return_value={"nodes": [{"summary": note["summary"], "sourceSequenceIDs": [1], "confidence": 0.9}]}), \
             patch.object(pipeline, "review_discourse_notes", return_value=([note], [dict(note, reviewReason="单位不明")])), \
             patch.object(pipeline, "consolidate_thematic_mind_map", return_value=[node]):
            pipeline.structure({"structure_strategy": "legacy-discourse"}, [{"id": "source-0", "sequence": 1, "originalText": note["sourceText"],
                                     "startTime": 125, "endTime": 137}], processing_warnings=warnings)
        self.assertEqual(len(warnings), 1)
        self.assertIn("1 条", warnings[0])
        self.assertIn("可能未覆盖全部思路", warnings[0])
        self.assertIn("2:05–2:17", warnings[0])

    def note(self, index, title="先提出问题再检验方法"):
        return {"sourceSpanIDs": [f"source-{index}"], "summary": title,
                "sourceText": f"第{index}段：" + title + "，不要忽视方法的适用条件。", "confidence": 0.8}

    def response(self, records, groups=None):
        groups = groups or [list(range(len(records)))]
        stages = [{"summary": records[g[-1]]["summary"], "argumentSummary": "",
                   "memberIndices": g, "evidenceIndex": g[-1], "relationToPrevious": "进一步展开"}
                  for g in groups]
        return {"center": {"summary": records[0]["summary"], "argumentSummary": "", "evidenceIndex": 0}, "stages": stages}

    def test_two_hundred_repeated_sentences_never_become_two_hundred_nodes(self):
        notes = [self.note(i) for i in range(199)] + [self.note(199, "结尾指出方法只适用于稳定条件")]
        before = copy.deepcopy(notes)
        seen = []
        def model(llm, system, prompt, schema, **kwargs):
            if set(schema["properties"]) == {"assignments"}:
                data = json.loads(prompt.split("映射：", 1)[1])
                assignments = {}
                for note in data["notes"]:
                    match = next((s for s in data["stages"] if ("结尾" in s["summary"]) == ("结尾" in note["summary"])), data["stages"][0])
                    assignments[str(note["noteIndex"])] = match["stageIndex"]
                return {"assignments": assignments}
            if "evidence" in schema["properties"] or "verdict" in schema["properties"]:
                def pick(claim, sources):
                    return [text for text in sources if ("结尾" in text) == ("结尾" in claim)][:1]
                return quote_response(prompt, schema, pick)
            records = json.loads(prompt.split("笔记：", 1)[1])
            seen.extend(record["summary"] for record in records)
            if len({r["summary"] for r in records}) == 1:
                return self.response(records)
            ordinary = [i for i, r in enumerate(records) if "结尾" not in r["summary"]]
            tail = [i for i, r in enumerate(records) if "结尾" in r["summary"]]
            # The one mixed reducer batch may produce two distinct concepts.
            return self.response(records, [g for g in (ordinary, tail) if g])
        with patch.object(pipeline, "structured_completion", side_effect=model):
            nodes = pipeline.consolidate_thematic_mind_map(None, notes)
        self.assertEqual(notes, before)
        self.assertLessEqual(len(nodes), 8)
        self.assertTrue(any("结尾" in n["summary"] for n in nodes))
        self.assertIn("source-199", {s for n in nodes for s in n["sourceSpanIDs"]})
        self.assertGreaterEqual(seen.count(notes[-1]["summary"]), 2)
        self.assertFalse(any(n["kind"] == "证据" for n in nodes))
        self.assertTrue(all(len(n["sourceSpanIDs"]) <= 3 for n in nodes))
        known = {s for note in notes for s in note["sourceSpanIDs"]}
        self.assertEqual(set(nodes[0]["coveredSourceSpanIDs"]), known)
        self.assertTrue(all(set(n["coveredSourceSpanIDs"]) <= known for n in nodes))
        self.assertTrue(all(set(n["sourceSpanIDs"]) <= set(n["coveredSourceSpanIDs"]) for n in nodes))
        root = nodes[0]["nodeID"]
        self.assertTrue(all(n["parentID"] == root for n in nodes[1:]))

    def test_no_tail_omission_duplicate_or_boolean_ids_can_pass(self):
        items = [dict(self.note(i), _coverage=[i]) for i in range(2)]
        records = [pipeline.discourse_record(i, item) for i, item in enumerate(items)]
        for members in ([0], [0, 0, 1], [False, 1], [0, 1, 5]):
            value = self.response(records)
            value["stages"][0]["memberIndices"] = members
            with self.assertRaises(ValueError):
                pipeline.validate_discourse_groups(value, items, 7)

    def test_ungrounded_model_fails_safely_without_sentence_fallback(self):
        notes = [self.note(0)]
        before = copy.deepcopy(notes)
        response = {"stages": [{"summary": "太阳上发现了生命", "argumentSummary": "",
                     "evidenceIndex": 0, "memberIndices": [0], "relationToPrevious": "得出结论"}]}
        def answer(llm, system, prompt, schema, **kwargs):
            return {"assignments": {"0": 0}} if set(schema["properties"]) == {"assignments"} else response
        with patch.object(pipeline, "structured_completion", side_effect=answer) as model:
            with self.assertRaisesRegex(ValueError, "已有导图保留"):
                pipeline.consolidate_thematic_mind_map(None, notes)
        self.assertEqual(model.call_count, 3, "malformed quote protocol fails without blind identical retry")
        self.assertEqual(notes, before)

    def test_invalid_evidence_fails_before_model_call(self):
        for invalid in ([], ["a", "a"], ["a", "b", "c", "d"], [1]):
            note = self.note(0)
            note["sourceSpanIDs"] = invalid
            with patch.object(pipeline, "structured_completion") as model:
                with self.assertRaises(ValueError):
                    pipeline.consolidate_thematic_mind_map(None, [note])
                model.assert_not_called()

    def test_excerpt_is_original_and_can_reach_tail(self):
        text = "普通讨论内容。" * 200 + "尾部结论指出必须检验长期维护成本。"
        excerpt = pipeline.excerpt_for_summary(text, "检验长期维护成本")
        self.assertIn("检验长期维护成本", excerpt)
        self.assertIn(excerpt, text)
        self.assertLessEqual(len(excerpt), 260)

    def test_optional_argument_rejects_new_numbers(self):
        self.assertEqual(pipeline.grounded_argument("只花30分钟", "只花20分钟"), "")
        self.assertEqual(pipeline.grounded_argument("只花20分钟", "只花20分钟"), "只花20分钟")
        self.assertEqual(pipeline.grounded_argument("只花三十分钟", "只花二十分钟"), "")
        self.assertTrue(pipeline.summary_numbers_are_grounded("四五十天减重二三十斤", "在四五十天减重二三十斤"))
        self.assertFalse(pipeline.summary_numbers_are_grounded("长度160cm", "160个记录"))
        self.assertFalse(pipeline.summary_numbers_are_grounded("重量20kg", "20厘米"))
        self.assertTrue(pipeline.summary_numbers_are_grounded("长度160 cm", "长度160cm"))

    def test_extraction_rejects_bad_citations_instead_of_silently_losing_notes(self):
        record = [{"sequence": 1, "text": "先检验方法效果，最后计算维护成本。"}]
        valid = {"summary": "先检验方法效果", "sourceSequenceIDs": [1], "confidence": 0.9}
        self.assertEqual(pipeline.validate_discourse_notes({"nodes": [valid]}, record), [valid])
        for invalid in ([1, 999], [True], [1, 1], [], [1, 2, 3, 4]):
            bad = dict(valid, sourceSequenceIDs=invalid)
            with self.assertRaises(ValueError):
                pipeline.validate_discourse_notes({"nodes": [valid, bad]}, record)
        with self.assertRaises(ValueError):
            pipeline.validate_discourse_notes({"nodes": [dict(valid, summary="只需要30分钟")]}, record)

    def test_semantic_audit_accepts_paraphrase_but_rejects_negation_flip(self):
        notes = [{"sourceText": "如果条件不同，之前有效的做法也未必适用。", "sourceSpanIDs": ["s"]}]
        paraphrase = {"summary": "方法的适用性取决于条件", "argumentSummary": "", "coveredSourceSpanIDs": ["s"]}
        self.assertFalse(pipeline.summary_is_lexically_grounded(paraphrase["summary"], notes[0]["sourceText"], 0.28))
        def answer(llm, system, prompt, schema, **kwargs):
            return quote_response(prompt, schema, verdict="contradicted" if "任何条件" in prompt else "supported")
        with patch.object(pipeline, "structured_completion", side_effect=answer):
            pipeline.verify_discourse_semantics(None, [paraphrase], notes, [[0]])
        wrong = {"summary": "任何条件下方法都能适用", "argumentSummary": "", "coveredSourceSpanIDs": ["s"]}
        before = copy.deepcopy(wrong)
        with patch.object(pipeline, "structured_completion", side_effect=answer):
            with self.assertRaisesRegex(ValueError, "完整原话语义支持"):
                pipeline.verify_discourse_semantics(None, [wrong], notes, [[0]])
        self.assertEqual(wrong, before)

    def test_semantic_audit_reads_covered_evidence_tail_beyond_representative(self):
        notes = [{"sourceText": "普通介绍。" * 50, "sourceSpanIDs": [f"s{i}"]} for i in range(20)]
        notes.append({"sourceText": "结尾限制决定能否复用。", "sourceSpanIDs": ["tail"]})
        nodes = [{"summary": "结尾限制决定能否复用", "argumentSummary": "", "coveredSourceSpanIDs": [s for n in notes for s in n["sourceSpanIDs"]]}]
        pages = []
        def model(llm, system, prompt, schema, **kwargs):
            if "evidence" in schema["properties"]:
                pages.append(json.loads(prompt.split("输入：", 1)[1])["originalSentences"])
            return quote_response(prompt, schema, lambda claim, texts: [t for t in texts if "结尾限制" in t][:1])
        with patch.object(pipeline, "structured_completion", side_effect=model):
            pipeline.verify_discourse_semantics(None, nodes, notes, [list(range(len(notes)))])
        self.assertGreater(len(pages), 1)
        self.assertIn("结尾限制决定能否复用。", pages[-1])
        self.assertEqual(nodes[0]["sourceSpanIDs"], ["tail"])

    def test_effective_text_preserves_negation_correction_and_empty_fallback(self):
        span = {"originalText": "这个方法一定有效", "correctedText": "这个方法不一定有效"}
        before = copy.deepcopy(span)
        self.assertEqual(pipeline.effective_text(span), "这个方法不一定有效")
        self.assertEqual(span, before)
        self.assertEqual(pipeline.effective_text(dict(span, correctedText="  ")), "这个方法一定有效")

    def test_click_through_sources_follow_actual_proof_not_initial_representative(self):
        notes = [{"sourceSpanIDs": ["unrelated"], "sourceText": "只是开场问候。"},
                 {"sourceSpanIDs": ["actual"], "sourceText": "确定目标以后还需要检验结果。"}]
        node = {"summary": "确定目标后检验结果", "argumentSummary": "", "sourceSpanIDs": ["unrelated"],
                "coveredSourceSpanIDs": ["unrelated", "actual"]}
        def model(llm, system, prompt, schema, **kwargs):
            return quote_response(prompt, schema, lambda claim, texts: [t for t in texts if "检验结果" in t][:1])
        with patch.object(pipeline, "structured_completion", side_effect=model):
            pipeline.verify_discourse_semantics(None, [node], notes, [[0, 1]])
        self.assertEqual(node["sourceSpanIDs"], ["actual"])
        # Source indexes/IDs from a model are not accepted as quotes. Repeated
        # and boolean claim indices remain invalid under the new protocol.
        for entries in ([{"claimIndex": True, "quotes": [notes[1]["sourceText"]]}],
                        [{"claimIndex": 0, "quotes": [notes[1]["sourceText"]]}] * 2,
                        [{"claimIndex": -1, "quotes": []}],
                        [{"claimIndex": 0, "quotes": [1]}],
                        [{"claimIndex": 0, "sourceIndexes": [1]}]):
            with patch.object(pipeline, "structured_completion", return_value={"evidence": entries}):
                with self.assertRaises(ValueError):
                    pipeline.verify_discourse_semantics(None, [dict(node)], notes, [[0, 1]])

    def test_clauses_preserve_conditions_negation_and_complete_argument(self):
        node = {"summary": "目标决定检验方式", "argumentSummary": "先确定目标，再检验结果。"}
        for argument in ("先确定目标，再检验结果。", "不是增加努力，而是改变方法。",
                         "如果条件改变，就重新验证。", "他说方法有效，能够提高效率，但仅适用于稳定条件。"):
            self.assertEqual(pipeline.discourse_claims(dict(node, argumentSummary=argument)),
                             [node["summary"], argument])

    def test_more_than_eight_claims_fail_explicitly_without_model_or_changes(self):
        notes = [self.note(0)]
        node = {"summary": "先提出问题", "coveredSourceSpanIDs": ["source-0"]}
        before = copy.deepcopy(node)
        with patch.object(pipeline, "discourse_claims", return_value=["不能截掉的观点"] * 9), \
             patch.object(pipeline, "structured_completion") as model:
            with self.assertRaisesRegex(ValueError, "one to eight"):
                pipeline.verify_discourse_semantics(None, [node], notes, [[0]])
        model.assert_not_called()
        self.assertEqual(node, before)

    def test_production_entry_preserves_corrected_text_and_real_source_gaps(self):
        spans = [{"id": "a", "sequence": 1, "originalText": "这不是"},
                 {"id": "filtered", "sequence": 2, "originalText": "背景音乐。", "isBackgroundAudio": True},
                 {"id": "c", "sequence": 3, "originalText": "条件满足就一定有效。", "correctedText": "条件满足也未必有效。"}]
        notes = [{"sourceSpanIDs": ["c"], "sourceText": spans[2]["correctedText"]}]
        node = {"summary": "条件满足不保证效果", "coveredSourceSpanIDs": ["c"]}
        seen = []
        def model(llm, system, prompt, schema, **kwargs):
            seen.append(prompt)
            return quote_response(prompt, schema, lambda claim, texts: [t for t in texts if "未必" in t][:1])
        before = copy.deepcopy(spans)
        with patch.object(pipeline, "structured_completion", side_effect=model):
            pipeline.verify_discourse_semantics(None, [node], notes, [[0]], transcript_spans=spans)
        self.assertIn("这不是", seen[0])
        self.assertNotIn("这不是", seen[1], "short semantic context cannot cross filtered source")
        self.assertTrue(all("一定有效" not in p and "背景音乐" not in p for p in seen))
        self.assertEqual(node["sourceSpanIDs"], ["c"])
        self.assertEqual(spans, before)

    def test_complete_composite_argument_missing_tail_fails_without_dropping_it(self):
        notes = [{"sourceSpanIDs": ["s"], "sourceText": "先确定目标，再做实验。"}]
        argument = "先确定目标，再做实验，并证明长期维护成本已经降低。"
        node = {"summary": "先定目标再做实验", "argumentSummary": argument, "coveredSourceSpanIDs": ["s"]}
        before = copy.deepcopy(node)
        claims_seen = []
        def model(llm, system, prompt, schema, **kwargs):
            if "summary" in schema["properties"]:
                return {"summary": node["summary"], "argumentSummary": argument}
            if "verdict" in schema["properties"]:
                claims_seen.append(json.loads(prompt.split("输入：", 1)[1])["claimQuote"])
            return quote_response(prompt, schema, verdict="unknown" if argument in prompt else "supported")
        with patch.object(pipeline, "structured_completion", side_effect=model):
            with self.assertRaises(pipeline.DiscourseSemanticError):
                pipeline.verify_discourse_semantics(None, [node], notes, [[0]])
        self.assertEqual(claims_seen.count(argument), 2)
        self.assertEqual(node, before)

    def test_missing_node_coverage_cannot_skip_audit(self):
        nodes = [{"summary": "第一个观点"}, {"summary": "不能跳过的观点"}]
        with patch.object(pipeline, "structured_completion") as model:
            with self.assertRaisesRegex(ValueError, "不能跳过"):
                pipeline.verify_discourse_semantics(None, nodes, [], [[]])
        model.assert_not_called()

    def test_annotation_originals_unchanged_and_result_ids_whitelisted(self):
        annotations = [{"id": "thought-1", "kind": "thought", "text": "我希望先检验方法的效果，再扩大使用。", "sourceSpanIDs": []}]
        before = copy.deepcopy(annotations)
        proposals = {"annotationSummaries": [{"id": "foreign", "summary": "先检验方法的效果"},
            {"id": "thought-1", "summary": "先检验方法的效果"}, {"id": "thought-1", "summary": "先检验方法的效果"}]}
        def model(llm, system, prompt, schema, **kwargs):
            return {"supportedIDs": ["thought-1", "foreign"]} if "supportedIDs" in schema["properties"] else proposals
        with patch.object(pipeline, "structured_completion", side_effect=model):
            result = pipeline.summarize_annotations(None, annotations, [])
        self.assertEqual(result, [{"id": "thought-1", "summary": "先检验方法的效果"}])
        self.assertEqual(annotations, before)

    def test_time_only_important_mark_resolves_this_manuscript_not_text_hint(self):
        spans = [{"id": "near", "sequence": 1, "startTime": 10, "endTime": 20,
                  "originalText": "比较之前要确定想改善什么。"},
                 {"id": "far", "sequence": 2, "startTime": 200, "endTime": 210,
                  "originalText": "这是另一个很远的话题。"}]
        annotations = [{"id": "mark-1", "kind": "important", "text": "不能拿这个假文本作证据",
                        "sourceSpanIDs": ["foreign"], "anchorTime": 16}]
        def model(llm, system, prompt, schema, **kwargs):
            if "supportedIDs" in schema["properties"]:
                return {"supportedIDs": ["mark-1"]}
            self.assertIn(spans[0]["originalText"], prompt)
            self.assertNotIn(spans[1]["originalText"], prompt)
            self.assertNotIn("假文本", prompt)
            return {"annotationSummaries": [{"id": "mark-1", "summary": "比较之前确定改善目标"}]}
        with patch.object(pipeline, "structured_completion", side_effect=model):
            result = pipeline.summarize_annotations(None, annotations, spans)
        self.assertEqual(len(result), 1)

    def test_annotation_failure_and_missing_audio_context_are_safe(self):
        thought = [{"id": "thought-1", "kind": "thought", "text": "把维护成本一起计算。"}]
        with patch.object(pipeline, "structured_completion", side_effect=RuntimeError("model unavailable")):
            self.assertEqual(pipeline.summarize_annotations(None, thought, []), [])
        with patch.object(pipeline, "structured_completion") as model:
            self.assertEqual(pipeline.summarize_annotations(None,
                [{"id": "m", "kind": "important", "text": "这是不可信的提示", "anchorTime": 3}], []), [])
            model.assert_not_called()

    def test_mark_with_many_valid_ids_keeps_the_anchor_not_the_first_three(self):
        spans = [{"id": f"s{i}", "sequence": i, "startTime": start, "endTime": start + 2,
                  "originalText": "真正标记的核心观点" if start == 30 else f"周边上下文第{i}段"}
                 for i, start in enumerate(range(18, 44, 2))]
        annotations = [{"id": "mark", "kind": "important", "sourceSpanIDs": [s["id"] for s in spans], "anchorTime": 31}]
        def model(llm, system, prompt, schema, **kwargs):
            records = json.loads(prompt.split("标注：", 1)[1])
            self.assertIn("真正标记的核心观点", records[0]["text"])
            self.assertIn("周边上下文第0段", records[0]["text"])
            self.assertIn("周边上下文第12段", records[0]["text"])
            return {"annotationSummaries": []}
        with patch.object(pipeline, "structured_completion", side_effect=model):
            pipeline.summarize_annotations(None, annotations, spans)

    def test_authored_annotation_paraphrase_uses_semantics_not_word_overlap(self):
        annotations = [{"id": "t", "kind": "thought", "text": "我想把每天要做的事情坚持下去，不用你提醒。"}]
        summary = "希望建立自主维持的习惯"
        self.assertFalse(pipeline.summary_is_lexically_grounded(summary, annotations[0]["text"], 0.22))
        def model(llm, system, prompt, schema, **kwargs):
            if "supportedIDs" in schema["properties"]:
                return {"supportedIDs": ["t"]}
            return {"annotationSummaries": [{"id": "t", "summary": summary}]}
        with patch.object(pipeline, "structured_completion", side_effect=model):
            self.assertEqual(pipeline.summarize_annotations(None, annotations, []), [{"id": "t", "summary": summary}])

    def test_annotations_only_cli_never_calls_asr_or_structure_or_overwrites_input(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.json"
            manifest = root / "manifest.json"
            output = root / "labels.json"
            original = {"spans": [{"id": "s1", "originalText": "原话不可改"}], "speakers": [],
                        "candidates": [{"nodeID": "existing-node"}], "warnings": []}
            pipeline.write_result(source, original)
            pipeline.write_result(manifest, {"structure_model_path": "stub", "annotations": []})
            arguments = ["pipeline", "--manifest", str(manifest), "--output", str(output),
                         "--structure-from", str(source), "--annotations-only"]
            with patch.object(sys, "argv", arguments), patch.object(pipeline, "load_structure_model", return_value=object()) as loader, \
                    patch.object(pipeline, "summarize_annotations", return_value=[{"id": "t", "summary": "用户标注的概括"}]), \
                    patch.object(pipeline, "transcribe") as asr, patch.object(pipeline, "structure") as structure:
                pipeline.main()
            asr.assert_not_called()
            structure.assert_not_called()
            loader.assert_called_once()
            self.assertEqual(json.loads(source.read_text()), original)
            result = json.loads(output.read_text())
            self.assertEqual(result["candidates"], [])
            self.assertEqual(result["spans"], original["spans"])
            self.assertEqual(result["annotationSummaries"][0]["id"], "t")
            arguments[4] = str(source)
            with patch.object(sys, "argv", arguments):
                with self.assertRaisesRegex(ValueError, "不能覆盖"):
                    pipeline.main()
            self.assertEqual(json.loads(source.read_text()), original)


if __name__ == "__main__":
    unittest.main()
